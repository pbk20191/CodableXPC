import Dispatch
import GRPCCore
import Synchronization
import XPC

/// grpc-swift's `ServerTransport` over an `XPCListener`: one listener, many connections, one
/// `streamHandler`.
///
/// # Why this file is allowed to `import XPC`
///
/// A server-role `RPCTransportCore` can only be built inside an `XPCListener`'s incoming-session
/// closure -- that is where the session comes from -- so something has to own a listener, and
/// `XPCListener` is the one XPC type this file names. It appears in *neither* of `XPCPipe`'s
/// disposal matrices (create / `activate()` / `endpoint` / `cancel()` are all ordinary), and both
/// trap-bearing primitives stay encapsulated behind ``XPCPipe/accepting(_:queue:building:)`` and
/// ``XPCPipe/rejecting(_:reason:)``. `RPCTransportCore` and the codec still must not, and do not,
/// import XPC.
///
/// # Shape
///
/// - ``Acceptor`` is the object the listener's closure talks to. It admits or refuses a session,
///   builds one core per admitted connection, and publishes it into an `AsyncStream` that
///   ``listen(streamHandler:)`` drains. It exists as a separate object because the listener's
///   closure must be handed to `XPCListener.init`, i.e. *before* a transport exists to capture.
/// - ``listen(streamHandler:)`` is two nested task groups: one child task per connection, and
///   inside it one child task per accepted stream.
/// - The graceful drain has two levels too: refuse new *sessions* at the acceptor, and `goAway`
///   each live connection so it accepts no new *streams*, then wait for the handlers.
///
/// # Ownership (L6)
///
/// `libxpc -> listener -> incoming-session closure -> acceptor -> cores -> pipes -> sessions`, and
/// the sessions' own handlers reach back into their core **weakly** (`RPCTransportCore.init`
/// installs both, with `[weak self]`). Nothing in that chain points at this transport, so nothing
/// keeps it alive: its `deinit` is reachable, and it is what cancels the listener and closes any
/// connection still open. The chain is broken from the top -- cancelling the listener is what makes
/// libxpc drop the closure, and hence the acceptor.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class XPCServerTransport: ServerTransport {
    public typealias Bytes = GRPCSwiftData

    // =======================================================================================
    // MARK: - The acceptor
    // =======================================================================================

    /// The listener's counterparty: everything the incoming-session closure needs, in an object
    /// that can exist before the transport does.
    ///
    /// One lock, and every list of cores is taken out of it before anything is called on them
    /// (L7): `beginDraining`, `close` and `failAll` all send ops, resume continuations or cancel
    /// timers. The one deliberate exception is the `yield` in ``accept(_:)``, which must be paired
    /// atomically with the `admitting` check -- the reason is at that line.
    ///
    /// # No cap on concurrent connections, deliberately
    ///
    /// `RPCTransportCore` caps inbound *streams* at
    /// ``RPCTransportCore/maxConcurrentInboundStreams`` because a stream is cheap to forge: about
    /// sixty wire bytes buys a table entry and two windows. A connection is not comparable. Each
    /// one costs the peer a real Mach port pair and a live `XPCSession`, which libxpc itself
    /// accounts for and rate-limits, and the memory of a buffered entry here is a rounding error
    /// next to the session it names. Adding a limit would also mean choosing what to do at it, and
    /// the only honest answer -- ``XPCPipe/rejecting(_:reason:)`` -- is indistinguishable from a
    /// draining server. Stated rather than assumed, because it is the one bound in this file that a
    /// reader may expect to find and will not.
    private final class Acceptor: Sendable {

        /// A connection whose accept window is **not yet provably closed**: libxpc has admitted
        /// the session, but has not yet delivered anything on it, so nothing may be sent to it,
        /// cancelled on it, or -- as always -- dropped.
        ///
        /// It is held here, strongly and untouched, until ``windowProvedClosed(_:)`` promotes it.
        private struct Pending {
            let core: RPCTransportCore
            /// The strongest teardown that arrived while the window was open. Applied by
            /// ``windowProvedClosed(_:)`` the moment acting is legal.
            var deferred: DeferredTeardown = .none
        }

        /// What a teardown that arrived too early owes a ``Pending`` connection, ordered by force.
        ///
        /// `failAll(_:)` maps to `.close` rather than to a case of its own. A pending connection has
        /// provably had **no op routed to it** (an op requires a delivery, and a delivery is what
        /// promotes it), so it has no streams to fail, and two differences remain rather than one:
        ///
        /// * the `pipe.cancel()` that `close()` adds. Immaterial here: `failAll` is only ever called
        ///   from `listen()`'s `onCancel`, which is followed immediately by `closeAll()`.
        /// * **`failAll` finishes the core's `acceptedStreams` now; a recorded teardown finishes it
        ///   when the proof arrives, or never.** That difference is the one with teeth, and it is
        ///   not specific to `failAll`: it is exactly why a stranded `pending` entry parks
        ///   `listen()` rather than merely leaking, and therefore why ``windowProvedClosed(_:)``
        ///   needs two independent exits. Recorded here rather than left implicit, because an
        ///   enumeration that finds "no effect applies" and drops one is how the last Critical in
        ///   this file survived three reviews.
        private enum DeferredTeardown: Int, Sendable {
            case none = 0
            case drain = 1
            case close = 2

            mutating func escalate(to other: DeferredTeardown) {
                if other.rawValue > rawValue { self = other }
            }
        }

        private struct State {
            /// Raises the recorded teardown of one still-untouchable connection, if it is still
            /// untouchable. A key that has already been promoted is not here, and its connection is
            /// in ``connections`` where the caller acts on it directly.
            mutating func escalatePending(_ key: ObjectIdentifier, to teardown: DeferredTeardown) {
                guard var entry = pending[key] else { return }
                entry.deferred.escalate(to: teardown)
                pending[key] = entry
            }

            /// The same, for every untouchable connection at once -- what the three sweepers do.
            /// `Array(pending.keys)` rather than `pending.keys`: mutating a dictionary while
            /// iterating its own `keys` view is correct under copy-on-write but forces a copy of the
            /// whole dictionary per sweep, and reads like a bug to anyone who has to check.
            mutating func escalateEveryPending(to teardown: DeferredTeardown) {
                for key in Array(pending.keys) { escalatePending(key, to: teardown) }
            }

            /// Whether new *sessions* are admitted. Cleared by the first drain and never set
            /// again; a refused session is turned away with ``XPCPipe/rejecting(_:reason:)``,
            /// which creates no session at all and so cannot trip any accept-window hazard.
            var admitting = true

            /// Admitted, published for ownership, **and untouchable** -- see ``Pending``. Keyed by
            /// core identity. Entries leave only through ``windowProvedClosed(_:)``.
            var pending: [ObjectIdentifier: Pending] = [:]

            /// Connections whose accept window is provably closed, and which every teardown path
            /// may therefore act on. Keyed by core identity.
            ///
            /// **Strong, and that is the point** for both tables: the core returned by
            /// `XPCPipe.accepting` is the only strong reference to its pipe, and dropping it while
            /// the accept window is open runs `deinit`, which cancels the session and kills the
            /// process (matrix row A1). Publishing into a table *before* returning the decision is
            /// what makes that impossible.
            var connections: [ObjectIdentifier: RPCTransportCore] = [:]
        }
        private let state = Mutex(State())

        /// Admitted connections, in accept order. Iterated exactly once, by `listen`.
        let connections: AsyncStream<RPCTransportCore>
        private let continuation: AsyncStream<RPCTransportCore>.Continuation

        init() {
            (self.connections, self.continuation) = AsyncStream.makeStream(
                of: RPCTransportCore.self)
        }

        /// The listener's incoming-session closure, minus the `import XPC` ceremony.
        ///
        /// # Everything happens in one critical section, and that is the fix
        ///
        /// The admission check, the build, the publish and the yield are all inside a single
        /// `state.withLock`. That is not tidiness; it deletes a state that used to exist and used
        /// to kill the process. Previously the check and the publish were two locks, so a
        /// `beginGracefulShutdown()` could land between them and leave this function holding an
        /// admitted connection the server had just decided not to serve -- and the arm that handled
        /// it called `core.beginDraining()`, which **sends** `goAway` on a session whose accept
        /// `Decision` had not yet been returned. libxpc traps on that (row A5): `_xpc_api_misuse`,
        /// exit 133, reproduced from a crash report.
        ///
        /// With one critical section a concurrent drain either **wins** -- `admitting` is already
        /// false, and the peer is refused with ``XPCPipe/rejecting(_:reason:)``, which creates no
        /// session at all -- or **loses**, and the connection is admitted and published like any
        /// other. There is no third state, so there is nothing to do inside the accept window, and
        /// this function does nothing to the session beyond building it.
        ///
        /// Holding the lock across `XPCPipe.accepting` (which itself blocks on the new connection
        /// queue via `queue.sync`) cannot deadlock: the only thing on that queue that takes this
        /// lock is ``windowProvedClosed(_:)``, which runs from a delivery or a cancellation -- a
        /// `queue.async` necessarily enqueued *behind* `accepting`'s `queue.sync` block. That same
        /// ordering is load-bearing a second time: it is why the promotion cannot race the publish,
        /// because it cannot even start until this lock is released.
        ///
        /// - Important: that argument is an enumeration of what runs on a connection queue *today*,
        ///   and anything added to one that takes this lock synchronously invalidates it. Blocking
        ///   this lock is the price of one-phase accept; if a connection queue ever needs to take it
        ///   from a path that can be reached while `accept` holds it, the accept must be restructured
        ///   rather than the lock narrowed.
        func accept(
            _ request: XPCListener.IncomingSessionRequest
        ) -> XPCListener.IncomingSessionRequest.Decision {
            // Carried out of the lock in a local rather than returned from it: `withLock`'s result
            // is `sending`, and `IncomingSessionRequest.Decision` is not `Sendable`. The closure is
            // not `@Sendable` either, so writing the local from inside it is exactly as safe as
            // the lock makes everything else here.
            var outcome: (decision: XPCListener.IncomingSessionRequest.Decision, pipe: XPCPipe)?
            state.withLock { state in
                guard state.admitting else { return }

                // One queue per connection, distinct from the listener's own: `XPCPipe.accepting`
                // blocks on the queue it is handed (`queue.sync`) and trips
                // `dispatchPrecondition(.notOnQueue(queue))` if it is the listener's. The label
                // comes from a process-wide counter so that several transports in one process do
                // not all name their queues alike in a crash log.
                let queue = DispatchSerialQueue(
                    label: ConnectionQueueLabel.mint(role: "server", peer: "accepted"))

                // `building` runs synchronously, before the decision goes back to libxpc and
                // before any blob can be dispatched. Do NOT install `onReceive`/`onPeerDeath`
                // here: `RPCTransportCore.init` installs both itself, weakly, and a second call
                // replaces the core's and silently disconnects the mux.
                var built: RPCTransportCore?
                let (decision, pipe) = XPCPipe.accepting(request, queue: queue) { pipe in
                    let core = RPCTransportCore(
                        pipe: pipe, codec: CompactWireCodec(), role: .server)
                    built = core

                    // The window-closed hook, registered here because here is the only place it
                    // cannot miss the peer's triggering message (see `onWindowProvedClosed`'s doc).
                    // It fires from **either** libxpc-ordered exit -- the first delivery, or the
                    // session's cancellation -- which is what gives `pending` two exits instead of
                    // one and bounds how long an entry can sit in it.
                    //
                    // It captures an `ObjectIdentifier` -- a *value* -- rather than the core, so
                    // there is no `core -> pipe -> Delivery -> handler -> core` self-cycle to get
                    // wrong, and `[weak self]` on the acceptor is mandatory for the same reason
                    // the mux's own handlers are weak: this closure is held at libxpc's end of the
                    // retain path, so a strong acceptor would make its `deinit` unreachable and
                    // leak every session it owns.
                    let key = ObjectIdentifier(core)
                    pipe.onWindowProvedClosed { [weak self] in self?.windowProvedClosed(key) }
                }
                guard let core = built else {
                    // Unreachable: `accepting` calls `building` synchronously. A trap rather than
                    // a thrown error or an early return, because the alternative is releasing
                    // `pipe` inside the accept window -- which is a process death anyway, with a
                    // worse diagnostic.
                    preconditionFailure("XPCPipe.accepting did not run its `building` closure")
                }

                // Published BEFORE the decision is returned, and never dropped in that window.
                // `pending`, not `connections`: until libxpc delivers on this session nobody may
                // touch it, and being in `pending` is exactly what "do not touch" means here.
                state.pending[ObjectIdentifier(core)] = Pending(core: core)

                // Yielded here, inside the lock, so that `admitting` and the yield are decided
                // together -- `beginDraining()` clears `admitting` and finishes this sequence
                // under this same lock, so hoisting the yield out would reintroduce a
                // yield-after-`finish()` race. Safe as written for a narrow, checkable reason:
                // `yield` enqueues (task resumption never runs the consumer inline), and nothing
                // the resumed consumer does re-enters this lock except `retire(_:)`, from a
                // `listen()` child task on another thread.
                //
                // `yield`'s result needs no handling: the sequence can only have finished if
                // `admitting` was already false, and the guard above returned in that case.
                self.continuation.yield(core)
                outcome = (decision, pipe)
            }

            guard let outcome else {
                return XPCPipe.rejecting(
                    request,
                    reason: "this gRPC server is shutting down and is not accepting new "
                        + "connections")
            }

            // `core` is published and holds `pipe` strongly, so releasing this local reference
            // cannot be the last release -- and the last release inside the window is row A1, a
            // measured trap, which is what makes this worth a comment rather than a shrug. The
            // `withExtendedLifetime` is not load-bearing; it is here so that the hazard is
            // documented at the line where a future edit would reintroduce it.
            withExtendedLifetime(outcome.pipe) {}
            return outcome.decision
        }

        /// libxpc has proved this connection's accept window closed -- by delivering its first
        /// message, or by cancelling the session (matrix rows A11/A12 and N8; see
        /// ``XPCPipe/onWindowProvedClosed(_:)`` for why nothing earlier will do).
        ///
        /// Runs on that connection's own serial queue, ahead of the message or the peer-death
        /// notification it is proved by, so the connection is eligible for teardown before its first
        /// op is routed.
        ///
        /// **This is `pending`'s only exit, and it is what keeps `pending` from being the pending
        /// table L5 forbids.** The difference from that table is in kind -- nothing here is
        /// half-built, no frames are buffered, no data path runs through it, ordering is untouched,
        /// and the exit is driven by libxpc rather than by a caller remembering to claim, which is
        /// what made L5's table lose data. But it shared L5's *second* symptom while it had only one
        /// exit: a single contingent path out, resting on an undocumented platform behaviour, with
        /// nothing to detect the failure. The cancellation exit is the second, independent path, and
        /// it is why a stranded entry is now bounded rather than merely unlikely: a stranded entry
        /// would hold a live uncancelled `XPCSession`, its core and its queue for the acceptor's
        /// lifetime -- process lifetime for ``XPCServerTransport/service(named:)`` -- **and** park
        /// `listen()` forever, because a recorded teardown never finishes that core's
        /// `acceptedStreams` and so never lets its child task return.
        ///
        /// Promotes the entry and applies whatever teardown arrived while it was untouchable. A key
        /// with no entry is an ordinary no-op: the connection has already been promoted, or closed
        /// and forgotten.
        private func windowProvedClosed(_ key: ObjectIdentifier) {
            enum Action {
                case none
                case drain(RPCTransportCore)
                case close(RPCTransportCore)
            }

            let action: Action = state.withLock { state in
                guard let entry = state.pending.removeValue(forKey: key) else { return .none }
                switch entry.deferred {
                case .none:
                    state.connections[key] = entry.core
                    return .none
                case .drain:
                    // Still ours to hold: a drained connection is retired by `retire(_:)` or
                    // `closeAll()` once its (now finished) accept loop unwinds.
                    state.connections[key] = entry.core
                    return .drain(entry.core)
                case .close:
                    // Dropped from both tables; the close below is the last thing owed to it.
                    return .close(entry.core)
                }
            }

            switch action {
            case .none:
                break
            case .drain(let core):
                core.beginDraining()
                core.signalCancellationToAllStreams()
            case .close(let core):
                core.close()
            }
        }

        /// Stops admitting new sessions, ends the connection sequence, and puts every live
        /// connection into a graceful drain: `goAway` out, no new streams in either direction,
        /// and every in-flight RPC's cancellation handle fired as a *request* to wind up.
        ///
        /// Nothing is failed and no handler is disturbed -- that is ``failAll(_:)``'s job.
        /// Idempotent.
        ///
        /// A connection still inside its accept window is **not** drained here -- the `goAway`
        /// would be a send into that window, which is row A5, a process death. Its drain is
        /// recorded and applied by ``windowProvedClosed(_:)``.
        func beginDraining() {
            let cores = state.withLock { state -> [RPCTransportCore] in
                state.admitting = false
                state.escalateEveryPending(to: .drain)
                return Array(state.connections.values)
            }
            continuation.finish()  // idempotent; ends `listen`'s connection loop
            for core in cores {
                core.beginDraining()
                core.signalCancellationToAllStreams()
            }
        }

        /// Forceful teardown of every connection, for a cancelled `listen()` task. Fails every
        /// live stream (which wakes every parked flow-control waiter) but leaves the sessions to
        /// ``closeAll()`` / `deinit`.
        ///
        /// A connection still inside its accept window has no streams to fail (an op requires a
        /// delivery, and a delivery would have promoted it), so its recorded teardown is `.close`
        /// -- see ``DeferredTeardown``.
        func failAll(_ error: any Error) {
            let cores = state.withLock { state -> [RPCTransportCore] in
                state.admitting = false
                state.escalateEveryPending(to: .close)
                return Array(state.connections.values)
            }
            continuation.finish()
            for core in cores { core.failAll(error) }
        }

        /// Final teardown: forget every connection and release its XPC session.
        ///
        /// A connection still inside its accept window is again left alone -- `core.close()` reaches
        /// `pipe.cancel()`, and cancelling in that window is row A1. Its close is recorded and
        /// applied by ``windowProvedClosed(_:)``, which fires from the first delivery **or** the
        /// session's cancellation, so "the peer never speaks again" no longer strands it. A peer
        /// that connects without ever sending cannot occur at all: such a peer never reaches the
        /// incoming-session closure (row N2, 40/40), so no `pending` entry exists without a blob
        /// already in flight. A late close is a delayed release; an early one is a trap.
        func closeAll() {
            let cores = state.withLock { state -> [RPCTransportCore] in
                state.admitting = false
                state.escalateEveryPending(to: .close)
                let taken = Array(state.connections.values)
                state.connections.removeAll()
                return taken
            }
            continuation.finish()
            for core in cores { core.close() }
        }

        /// How many admitted connections are still waiting for their accept window to be proved
        /// closed, and how many have been proved. **Diagnostics, and they have to be**, on the same
        /// rationale as `RPCTransportCore.liveStreamCount`: "`pending` empties" is a claim about a
        /// private dictionary with exactly one exit, and until these existed it was invisible from
        /// every other part of the surface -- which is why finding 1 of round 5 arrived as a review
        /// argument instead of a test failure. Nothing in the transport branches on either.
        var pendingCount: Int { state.withLock { $0.pending.count } }
        var provedCount: Int { state.withLock { $0.connections.count } }

        /// One connection is finished -- its accept loop ended and every handler on it has
        /// returned. Drops it and releases its session.
        ///
        /// Without this a long-lived server would accumulate one dead core (and one dead XPC
        /// session) per disconnected peer for as long as `listen()` runs, since `connections` is
        /// otherwise only emptied by ``closeAll()``.
        /// A connection still inside its accept window records `.close` instead: `retire(_:)` is
        /// reachable for one while `listen()`'s task is cancelled (the child task's `for await`
        /// ends on cancellation rather than because the connection finished), and closing it here
        /// would be a cancel in the window.
        func retire(_ core: RPCTransportCore) {
            let key = ObjectIdentifier(core)
            let mayClose: Bool = state.withLock { state in
                if state.connections.removeValue(forKey: key) != nil { return true }
                state.escalatePending(key, to: .close)
                return false
            }
            guard mayClose else { return }
            core.close()
        }
    }

    // =======================================================================================
    // MARK: - State
    // =======================================================================================

    private let acceptor: Acceptor
    private let listener: XPCListener

    /// This listener's endpoint, for the anonymous case only. `XPCEndpoint` is how a peer in the
    /// same process (or one handed the endpoint over an existing session) dials an anonymous
    /// listener; a named-service listener is dialled by name instead and has none.
    let endpoint: XPCEndpoint?

    /// Admitted connections still waiting for libxpc to prove their accept window closed. Should
    /// be 0 in any steady state: the proof arrives with the peer's first blob, which is the blob
    /// that caused the accept. See ``Acceptor/pendingCount``.
    var connectionsAwaitingWindowProof: Int { acceptor.pendingCount }

    /// Connections whose accept window is proved closed and which teardown may act on. See
    /// ``Acceptor/provedCount``.
    var provedConnectionCount: Int { acceptor.provedCount }

    /// `listen()`'s state, made explicit for the same reason `XPCClientTransport.ConnectState`
    /// is: every transition must be unambiguous rather than inferred from side effects.
    ///
    /// - `.idle -> .listening`: the first `listen()` call, which then drains
    ///   `acceptor.connections` until it finishes.
    /// - `.listening -> .draining`: `beginGracefulShutdown()` while `listen()` is running. New
    ///   connections and new streams are refused from here on, but the handlers already running
    ///   are *not* disturbed -- `listen()` stays inside its task groups until the last of them
    ///   returns.
    /// - `.draining -> .shutDown` / `.listening -> .shutDown`: `listen()`'s loops have finished --
    ///   because the drain completed, or because its own task was cancelled. Either way a
    ///   `listen()` that has already run once never runs a second time.
    /// - `.idle -> .shutDown`: `beginGracefulShutdown()` arriving before any `listen()` call, so a
    ///   *later* `listen()` returns immediately instead of accepting anything.
    ///
    /// Unlike `XPCClientTransport.connect()`, no continuation is parked here: the "block until told
    /// to stop" signal is `acceptor.connections` itself, which `beginGracefulShutdown()` finishes
    /// -- so it unblocks a running `listen()` by ending *that* sequence rather than by resuming
    /// anything this type owns.
    private enum ListenState: Sendable {
        case idle
        case listening
        case draining
        case shutDown
    }
    private let state = Mutex<ListenState>(.idle)

    private init(acceptor: Acceptor, listener: XPCListener, endpoint: XPCEndpoint?) {
        self.acceptor = acceptor
        self.listener = listener
        self.endpoint = endpoint
    }

    /// Releases every connection still open, then the listener.
    ///
    /// **This is the only place the listener is cancelled**, and that is a fix rather than a
    /// simplification: doing it at the end of `listen()` made a peer that dialled as the server
    /// drained vanish, never accepted and never refused (round 4 §2). Cancelling here is what makes
    /// libxpc drop the incoming-session closure, and with it the acceptor; until it happens, a late
    /// peer gets a definite answer from ``XPCPipe/rejecting(_:reason:)``.
    ///
    /// Connections are closed first, and the reason has changed with the measurements. It used to be
    /// stated as an invariant -- close them first so the listener never tears down a session the
    /// disposal matrix has no row for -- and **that invariant is no longer kept**: a connection
    /// still in `pending` survives `closeAll()` untouched, so `listener.cancel()` below can and does
    /// reach one. Rows N6/N7 (80/80) measured that case safe -- cancelling *or* releasing an
    /// accepted session after its listener has been cancelled -- so the order is now a preference
    /// (close on the path the matrix covers where we can) rather than a requirement. Recorded this
    /// way because the previous wording claimed a property the code stopped having.
    deinit {
        acceptor.closeAll()
        listener.cancel()
    }

    // =======================================================================================
    // MARK: - Construction
    // =======================================================================================

    /// Listens on a launchd service name. The listener is active when this returns.
    ///
    /// `name` is **either** a Mach service name (a `LaunchAgent`/`LaunchDaemon` plist's
    /// `MachServices` key) **or** the `CFBundleIdentifier` of an `.xpc` service bundle. The same
    /// call covers both: `xpc_listener_create` documents its `service` argument as "the Mach
    /// service or XPC Service name" and performs the launchd check-in itself, so a service inside
    /// an application's `XPCServices/` directory needs no `xpc_main`, no `MachServices` key, and no
    /// separate factory here.
    ///
    /// That second half went undocumented until `GRPCDemo/` ran it, and its absence mattered: the
    /// bundle case is the only server topology a consumer of this package can actually reach, and
    /// this doc read as though it were unsupported.
    ///
    /// Note the contrast with `Demo/`'s `XPCActors` service, which *does* need `xpc_main` -- that
    /// stack speaks to a raw `xpc_connection_t` rather than to the overlay's listener. Both are
    /// correct for what they talk to.
    public static func service(named name: String) throws -> XPCServerTransport {
        let acceptor = Acceptor()
        let listener = try XPCListener(
            service: name, targetQueue: nil, options: .inactive,
            incomingSessionHandler: { request in acceptor.accept(request) })
        try listener.activate()
        return XPCServerTransport(acceptor: acceptor, listener: listener, endpoint: nil)
    }

    /// Listens on an **anonymous** listener and exposes its ``endpoint``, which is how a peer is
    /// connected without a launchd service -- including a peer in this same process.
    ///
    /// Internal rather than public: an anonymous endpoint has to be handed to the peer by some
    /// other channel, so this is a building block (and the in-process pair below), not a
    /// deployment story.
    static func anonymous() throws -> XPCServerTransport {
        let acceptor = Acceptor()
        let listener = XPCListener(
            targetQueue: nil, options: .inactive,
            incomingSessionHandler: { request in acceptor.accept(request) })
        try listener.activate()
        // `endpoint` is only valid after `activate()`.
        return XPCServerTransport(
            acceptor: acceptor, listener: listener, endpoint: listener.endpoint)
    }

    /// Dials this transport's own endpoint and returns a client transport speaking to it over
    /// **real XPC** -- two sessions, two mutexed cores, one process.
    ///
    /// This is the only place an `XPCEndpoint` is dialled, and it lives here because naming that
    /// type is what would otherwise force `import XPC` into a third file.
    ///
    /// - Precondition: this transport was built by ``anonymous()``; a named-service listener has
    ///   no endpoint to dial.
    func connectingClient() throws -> XPCClientTransport {
        guard let endpoint else {
            throw RPCError(
                code: .failedPrecondition,
                message: "only an anonymous XPCServerTransport has an endpoint to dial")
        }
        let queue = DispatchSerialQueue(
            label: ConnectionQueueLabel.mint(role: "client", peer: "endpoint"))
        var built: RPCTransportCore?
        // The returned pipe is discarded: `built` holds it strongly. Handlers are installed by
        // `RPCTransportCore.init`, weakly -- never here.
        _ = try XPCPipe.connecting(to: endpoint, queue: queue) { pipe in
            built = RPCTransportCore(pipe: pipe, codec: CompactWireCodec(), role: .client)
        }
        guard let core = built else {
            preconditionFailure("XPCPipe.connecting did not run its `building` closure")
        }
        return XPCClientTransport(core: core)
    }

    // =======================================================================================
    // MARK: - ServerTransport
    // =======================================================================================

    /// Accepts connections, and on each of them accepts streams, running `streamHandler` for every
    /// one in its own child task.
    ///
    /// - A second, concurrent call while one `listen()` is already running is refused with a
    ///   thrown `RPCError(code: .failedPrecondition)` -- the entry check and the
    ///   `.idle -> .listening` transition happen together under one `state.withLock`, so two
    ///   racing calls can never both see `.idle` and both start accept loops.
    /// - A call made after `beginGracefulShutdown()` (or after a previous `listen()` has already
    ///   ended) finds `.draining`/`.shutDown` and returns immediately, touching nothing.
    /// - Once `beginGracefulShutdown()` has run this method **drains**: both accept loops end (the
    ///   connection sequence is finished by the acceptor, each core's accepted-stream sequence by
    ///   its own `beginDraining()`), but the task groups keep every handler that was already
    ///   running, so `listen()` returns only after the last of them has returned.
    ///   `beginGracefulShutdown()` itself never waits.
    /// - Cancelling this call's own task is *not* graceful: `onCancel` begins the shutdown and then
    ///   tears every stream down with `failAll`, because a cancelled task wants out now. The
    ///   groups' children are cancelled by the runtime too. Nothing in the loops below throws on
    ///   cancellation, so this method **returns normally rather than throwing** -- matching what
    ///   `GRPCServer.serve()` expects, since it wraps *any* thrown error from `listen` in a
    ///   `RuntimeError(code: .transportError, ...)` and would misreport an ordinary cancelled
    ///   shutdown as a transport failure.
    public func listen(
        streamHandler: @escaping @Sendable (RPCStream<Inbound, Outbound>, ServerContext) async ->
            Void
    ) async throws {
        // L7: one atomic take-and-transition decides whether this call runs at all.
        let previous: ListenState = state.withLock { current in
            let previous = current
            if case .idle = current { current = .listening }
            return previous
        }
        switch previous {
        case .listening:
            throw RPCError(
                code: .failedPrecondition,
                message: "XPCServerTransport.listen() is already running "
                    + "-- it must not be called more than once concurrently")
        case .draining, .shutDown:
            return
        case .idle:
            break
        }

        let acceptor = self.acceptor
        await withTaskCancellationHandler {
            await withDiscardingTaskGroup { connectionGroup in
                for await core in acceptor.connections {
                    connectionGroup.addTask {
                        await withDiscardingTaskGroup { streamGroup in
                            for await accepted in core.acceptedStreams {
                                streamGroup.addTask {
                                    await Self.run(
                                        accepted, on: core, with: streamHandler)
                                }
                            }
                        }
                        // Reached once this connection accepts no more streams *and* every
                        // handler on it has returned. Retiring releases its XPC session and
                        // keeps `connections` from growing once per disconnected peer.
                        acceptor.retire(core)
                    }
                }
            }
            // Reached only once the connection loop has ended *and* every connection's child task
            // has drained -- i.e. every handler in flight when the shutdown began has returned.
            // This is the drain; `beginGracefulShutdown()` itself never waits.
        } onCancel: {
            // Not a graceful shutdown -- the caller wants out now -- so this both begins the
            // shutdown and tears the streams down. The groups' children are cancelled by the
            // runtime as well, so a handler that cooperates with cancellation ends promptly and
            // one that does not still finds its streams failed.
            self.beginGracefulShutdown()
            acceptor.failAll(
                RPCError(
                    code: .unavailable, message: "the server's listen() task was cancelled"))
        }

        state.withLock { $0 = .shutDown }
        // The drain is over, so closing the connections can no longer tear down one that someone
        // is still using.
        //
        // **The listener is deliberately NOT cancelled here**, and that is a fix, not an omission.
        // Cancelling it made a peer that dialled as the server drained vanish: its connection was
        // never accepted and never refused, so its RPC waited forever -- measured, see the report's
        // round 4 §2. A live listener whose acceptor has stopped admitting answers such a peer with
        // ``XPCPipe/rejecting(_:reason:)``, which is a definite answer it can act on. The listener
        // is cancelled by `deinit`, which is the point at which this transport is genuinely
        // finished and no peer can be owed a reply.
        acceptor.closeAll()
    }

    /// One accepted stream, start to finish. Static, and taking `core` explicitly, so that the
    /// child task captures the **core** for the handler's whole lifetime without capturing this
    /// transport: the stream's outbound writer and its inbound credit callback both hold the core
    /// weakly (L6), and this is what keeps it alive while a handler is using it.
    private static func run(
        _ accepted: AcceptedRPCStream,
        on core: RPCTransportCore,
        with streamHandler: @escaping @Sendable (RPCStream<Inbound, Outbound>, ServerContext) async
            -> Void
    ) async {
        await withServerContextRPCCancellationHandle { handle in
            // **L3.** Runs on every path the handler can leave by -- a return, a throw, and
            // cancellation of this task -- because a `defer` runs while unwinding either way.
            // Not optional bookkeeping: it is what removes the table entry, cancels the deadline
            // timer, and flushes the connection credit this stream is still withholding. The old
            // build called the equivalent only on the return path, and an early-returning handler
            // stranded the peer's writer forever (measured: 33 of 200 sent, then a permanent
            // hang). It also sends `cancel` if the handler never wrote a `status`.
            defer { core.streamHandlerFinished(accepted.id) }

            // Registered *before* the handler runs, so an inbound `cancel` op, a drain signal, a
            // deadline or peer death can all reach the handler through
            // `withRPCCancellationHandler` / `context.cancellation`. `alreadyOver` closes the race
            // where a teardown swept the table between this stream being accepted and this task
            // being scheduled.
            //
            // The closure captures **only `handle`** -- never `core`. The observer is held
            // strongly by the core's own registry, so capturing the core would close
            // `core -> registry -> entry -> observer -> core`: a *self*-cycle, invisible to any
            // external weak-reference test, whose only symptom is that `deinit` never runs and
            // the XPC session leaks.
            let alreadyOver = core.setCancellationObserver(forStream: accepted.id) {
                handle.cancel()
            }
            if alreadyOver { handle.cancel() }

            let context = ServerContext(
                descriptor: accepted.descriptor,
                remotePeer: "xpc:peer",
                localPeer: "xpc:self",
                cancellation: handle)
            await streamHandler(accepted.stream, context)
        }
    }

    /// Begins a **graceful** shutdown: refuses new connections, sends `goAway` on every live one,
    /// and lets the streams already in flight finish. Returns immediately -- the waiting happens
    /// in ``listen(streamHandler:)``, which stays inside its task groups until the last handler
    /// returns.
    ///
    /// What the acceptor's drain does, in order:
    /// 1. stops admitting sessions (later peers get ``XPCPipe/rejecting(_:reason:)``, which never
    ///    creates a session, rather than an accept-then-cancel);
    /// 2. finishes the connection sequence, so `listen()`'s outer loop ends;
    /// 3. per connection: `goAway` to the peer, later `openStream` ops refused, and that core's
    ///    accepted-stream sequence finished so its inner loop ends;
    /// 4. per connection: every in-flight RPC's `ServerContext.cancellation` fired -- a *request*
    ///    to wind up, not a teardown. Nothing is failed, and a handler that ignores it runs to
    ///    completion.
    ///
    /// It deliberately does **not** fail in-flight streams and does **not** cancel the listener:
    /// failing streams is the opposite of draining them, and cancelling the listener tears down
    /// the very sessions being drained. The forceful teardown still exists for the paths that mean
    /// it -- cancellation of `listen()`'s own task, and peer death.
    ///
    /// Idempotent: a second call finds `.draining`/`.shutDown` and does nothing.
    ///
    /// The one asymmetry: called before any `listen()`, there is no accept loop to drain and no
    /// handler that could be in flight, so this *is* the whole shutdown and it closes the
    /// connections itself. Called while `listen()` is running, that step belongs to `listen()`,
    /// which is the only thing that knows when the last handler returned.
    ///
    /// **Neither arm cancels the listener** -- `deinit` is the only place that happens, so that a
    /// peer mid-dial is refused rather than ignored. A consequence worth naming for
    /// ``XPCServerTransport/service(named:)``: the service name -- Mach service or bundle
    /// identifier -- stays claimed until this transport is released, where it used to be given up at the end of `listen()`. That is
    /// deliberate (a name that answers "shutting down" is more useful than one that answers
    /// nothing), but it means a replacement server cannot claim the name until the old transport is
    /// gone.
    public func beginGracefulShutdown() {
        enum Action { case none, drain, drainAndClose }

        let action: Action = state.withLock { current in
            switch current {
            case .draining, .shutDown:
                return .none
            case .idle:
                // No `listen()` to drain, and none may start later.
                current = .shutDown
                return .drainAndClose
            case .listening:
                current = .draining
                return .drain
            }
        }
        switch action {
        case .none:
            return
        case .drain:
            acceptor.beginDraining()
        case .drainAndClose:
            acceptor.beginDraining()
            acceptor.closeAll()
            // Not `listener.cancel()`, for the same reason as in `listen()`: a peer mid-dial must
            // get a refusal rather than silence. `deinit` cancels it.
        }
    }
}
