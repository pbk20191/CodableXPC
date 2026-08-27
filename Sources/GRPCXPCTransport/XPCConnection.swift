import Foundation
import GRPCCore
import Synchronization
import XPC
import CodableXPC

/// One inbound `.openStream` frame's result: the server's full side of the RPC, already built.
///
/// Accept is deliberately *one* phase, not two. An earlier shape yielded just `(id, descriptor)`
/// on `acceptedStreams` and left building the `StreamChannel`/`RPCStream` to a second, later call
/// the consumer made after reading it -- which meant either an unbounded window in which frames
/// for `id` (metadata, the first message -- exactly what a real client sends immediately after
/// `openStream`) had nowhere to land, or, if the channel was pre-built to close that window, a
/// second table to hold it pending the later call: which then either leaked (never claimed) or,
/// once cleared on the stream's terminal frame to stop leaking, discarded the very buffer a late
/// claim needed. Handing over the already-built `RPCStream` at accept time removes the second
/// call, and with it every one of those failure modes at once -- there is nothing left pending to
/// leak, lose, or race.
///
/// - Important: this payload is buffered *by the connection* (in `acceptedContinuation`) until a
///   consumer drains it, so nothing reachable from it may own the connection back. That is why
///   `stream.outbound`'s `XPCOutboundWriter` holds its connection weakly -- see that type's doc
///   comment. Writes through a stream whose connection has gone away fail with
///   `RPCError(code: .unavailable)`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct AcceptedStream: Sendable {
    let id: StreamID
    let descriptor: MethodDescriptor
    let stream: RPCStream<RPCAsyncSequence<RPCRequestPart<GRPCSwiftData>, any Error>,
                          RPCWriter<RPCResponsePart<GRPCSwiftData>>.Closable>
}

/// Wraps one `XPCSession`, multiplexing many RPCs over it by `StreamID` and demultiplexing
/// inbound frames to the right stream. Adopts `ActorBackedByDispatchSerialQueue` semantics
/// informally: `queue` is set as the session's target queue, so every inbound message -- and
/// therefore every `route(_:)` call -- runs serially on it. That is what lets
/// `StreamChannel.accept`'s "callers must invoke `accept` serially per stream" precondition hold
/// without a second lock inside `StreamChannel` (see StreamChannel.swift).
///
/// - Important: Ownership contract -- whoever creates streams from this connection
///   (``openClientStream(descriptor:)``, or a consumer draining ``acceptedStreams``) must keep
///   this `XPCConnection` alive for as long as those streams are in use; a stream does not hold
///   its connection back. Release the connection early and a stream's outbound writes fail with
///   `RPCError(code: .unavailable, ...)` while its inbound sequence fails rather than hanging.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class XPCConnection: Sendable {
    enum Role: Sendable { case client, server }

    let role: Role
    private let session: XPCSession
    let queue: DispatchSerialQueue
    private let nextStreamID = Atomic<UInt64>(1)

    /// Initial per-stream credit allowance handed to every ``XPCOutboundWriter`` this connection
    /// creates -- see ``XPCBackpressure/defaultCreditWindow`` for why it must exceed one.
    let creditWindow: Int

    /// Identifies an outstanding credit-bearing send, so its reply (or the connection's death) can
    /// resolve exactly one waiting writer.
    private let nextCreditToken = Atomic<UInt64>(1)

    /// The coarse, connection-wide delivery valve (design section 6). Deliberately inert here:
    /// nothing in this transport ever closes it -- it exists for an owner that needs to pause a
    /// whole connection (memory pressure). See ``ConnectionValve`` for the C1/C2 reasoning, and in
    /// particular why the caller must not be running on ``queue``.
    let deliveryValve: ConnectionValve

    /// Tracks whether `session.activate()` has *succeeded*. Seeded `true` for `.server` (an
    /// accepted session is already live); for `.client` it flips to `true` only inside
    /// ``activate()``, after `session.activate()` returns without throwing. Gates `deinit`'s
    /// cancel -- see the comment there for why.
    private let isActivated: Atomic<Bool>

    /// One credit-bearing send that has not been answered yet.
    ///
    /// Tracked because libxpc will *not* resolve a reply handler whose session has been cancelled
    /// (verified by probe: cancelling a session with an outstanding reply never calls its handler at
    /// all). Without this table, a writer suspended for credit when the connection dies would hang
    /// forever instead of failing -- see ``failAll(_:)`` and
    /// `BackpressureTests.testASuspendedWriterFailsRatherThanHangingWhenTheConnectionGoesAway`.
    private struct PendingCredit {
        let streamID: StreamID
        let complete: @Sendable (Result<Int, any Error>) -> Void
    }

    private struct Registry: Sendable {
        var clientChannels: [StreamID: StreamChannel<RPCResponsePart<GRPCSwiftData>>] = [:]
        var serverChannels: [StreamID: StreamChannel<RPCRequestPart<GRPCSwiftData>>] = [:]
        var pendingCredits: [UInt64: PendingCredit] = [:]
        /// Per-stream "this RPC has been cancelled" callbacks -- see
        /// ``setCancellationObserver(forStream:_:)``.
        var cancellationObservers: [StreamID: @Sendable () -> Void] = [:]
    }
    private let registry = Mutex(Registry())

    /// Set once this connection stops taking *new* streams: either this side began a graceful
    /// shutdown (``stopAcceptingNewStreams()``), or the peer told us it is shutting down by sending
    /// `.goAway`. In-flight streams are deliberately untouched -- draining them is the whole point
    /// of a graceful shutdown (design section 8) -- so this gates only stream *creation*: an
    /// inbound `.openStream` is refused with a `.status(.unavailable)` rather than accepted, and
    /// `XPCClientTransport.withStream` refuses to open one locally.
    private let draining = Atomic<Bool>(false)

    /// Whether new streams are refused -- see ``draining``. Read by `XPCClientTransport.withStream`
    /// so a client that has received `.goAway` fails fast instead of opening a stream the peer will
    /// immediately reject.
    var isDraining: Bool { draining.load(ordering: .acquiring) }

    private let acceptedContinuation: AsyncStream<AcceptedStream>.Continuation
    /// Yields one `AcceptedStream` per inbound `.openStream` frame, each already carrying its
    /// fully built server-side `RPCStream` -- see ``AcceptedStream``'s doc comment for why accept
    /// is one phase, not two.
    ///
    /// - Important: whoever drains this must keep the connection alive for as long as the
    ///   accepted streams stay in use -- see the type's doc comment for the ownership contract
    ///   and its consequence if violated.
    let acceptedStreams: AsyncStream<AcceptedStream>

    /// Wraps `session`.
    ///
    /// - For `.client`: `session` must be inactive (freshly dialled). This installs the
    ///   incoming-message handler, cancellation handler, and target queue but does **not**
    ///   activate it -- call ``activate()`` before use, or prefer ``connecting(to:queue:)``,
    ///   which does both atomically. Prefer this initializer directly only when dialling by a
    ///   means other than an `XPCEndpoint` (e.g. a mach or XPC service name).
    /// - For `.server`: `session` is an already-live session handed back by
    ///   `XPCListener.IncomingSessionRequest.accept`. This still (re-)installs the handlers and
    ///   target queue -- which is safe to call on a live session -- but the session must never be
    ///   passed to ``activate()``.
    init(session: XPCSession,
         role: Role,
         queue: DispatchSerialQueue,
         creditWindow: Int = XPCBackpressure.defaultCreditWindow) {
        self.session = session
        self.role = role
        self.queue = queue
        self.creditWindow = creditWindow
        self.deliveryValve = ConnectionValve(queue: queue)
        self.isActivated = Atomic<Bool>(role == .server)
        (acceptedStreams, acceptedContinuation) = AsyncStream.makeStream()
        // Returning `nil` here does **not** make libxpc synthesize a reply (verified by probe), so
        // a `.message` frame's reply stays ours to send later -- which is exactly what
        // reply-as-credit needs: `route` hands the received message to the target stream's
        // `CreditLedger`, which replies only once a consumer pulls the element it carried.
        session.setIncomingMessageHandler { [weak self] (message: XPCDictionary) -> XPCDictionary? in
            self?.handleInbound(message)
            return nil
        }
        // Peer death (session cancellation, e.g. the other process exiting) fails every live
        // stream locally rather than leaving them hung forever. Deadlines, `.goAway`, and
        // graceful-shutdown *sequencing* stay Task 9/10's job -- this only makes the hook exist.
        session.setCancellationHandler { [weak self] error in
            self?.failAll(RPCError(code: .unavailable, message: "XPC peer session cancelled: \(error)"))
        }
        session.setTargetQueue(queue)
    }

    /// Dials `endpoint` and returns an *activated* client connection in one step. Constructing
    /// and activating separately leaves a window where a caller could drop the `XPCConnection`
    /// before ever calling ``activate()`` (or after it throws) -- harmless with the
    /// ``isActivated`` gate below, but this factory removes the window entirely for the common
    /// endpoint-dialling case.
    static func connecting(to endpoint: XPCEndpoint,
                           queue: DispatchSerialQueue,
                           creditWindow: Int = XPCBackpressure.defaultCreditWindow) throws -> XPCConnection {
        let session = try XPCSession(endpoint: endpoint, options: .inactive)
        let connection = XPCConnection(session: session, role: .client, queue: queue,
                                       creditWindow: creditWindow)
        try connection.activate()
        return connection
    }

    /// Activates the underlying session. The *client* side calls this after construction -- the
    /// harness today (or, more simply, ``connecting(to:queue:)``); `XPCClientTransport.connect()`
    /// in Task 5. An accepted (server) session handed back from `IncomingSessionRequest.accept`
    /// is already live and must **not** be activated again.
    func activate() throws {
        try session.activate()
        isActivated.store(true, ordering: .relaxed)
    }

    /// libxpc traps (`_xpc_api_misuse`, `EXC_BREAKPOINT`) on `xpc_session_cancel` if the session
    /// was never successfully activated -- so an inactive client session whose `activate()` threw
    /// (Task 5's `connect()`-failure path) must **not** be cancelled here, only released. An
    /// activated-but-never-cancelled session traps on release the same way, so every session that
    /// *did* activate (every `.server` session, and every `.client` session past a successful
    /// `activate()`) still must be cancelled. `isActivated` is exactly that distinction. Full
    /// graceful-shutdown sequencing (draining, `.goAway`) is Task 9/10's job; this is just the
    /// RAII teardown of the native resource.
    deinit {
        if isActivated.load(ordering: .relaxed) {
            session.cancel(reason: "XPCConnection deinitialized")
        }
        // Reaching here at all is only possible because nothing the connection owns owns it back
        // -- in particular the `AcceptedStream`s buffered in `acceptedContinuation` hold their
        // outbound writer, which holds this connection *weakly* (see `XPCOutboundWriter`).
        //
        // Fail (rather than merely finish) so that a stream handed out earlier and still held by
        // someone -- an `AcceptedStream` a consumer took, or a client stream from
        // `openClientStream` -- terminates its inbound sequence deterministically instead of
        // awaiting a frame that can no longer arrive. Outbound writes on such a stream
        // symmetrically fail with `.unavailable` from the writer itself. `failAll` also finishes
        // `acceptedContinuation`, so an accept loop iterating `acceptedStreams` still ends.
        failAll(RPCError(code: .unavailable, message: "the XPC connection was deinitialized"))
    }

    /// Serializes `frame` and sends it one-way over the session -- no reply, no flow control.
    ///
    /// This is the path for every frame kind *except* `.message`: `openStream`, `metadata`,
    /// `halfClose`, `status` and `cancel`. Keeping the terminals here is load-bearing -- see
    /// ``XPCBackpressure`` -- because a stream must be closable by a writer that is already starved
    /// of credit. `.message` frames go through ``sendAwaitingCredit(_:onCredit:)``.
    /// Errors are shaped, not passed through: once the peer is gone `session.send` fails with
    /// libxpc's own error (an `XPCRichError` about an invalid connection), and gRPC's machinery --
    /// and every caller in this transport -- expects transport failures as `RPCError`. A send that
    /// failed because the far end is gone is `.unavailable`; a frame that failed to *encode* is
    /// this side's own bug, so it is left to surface as itself rather than mislabelled as a peer
    /// problem.
    func send(_ frame: XPCFrame) throws {
        let object = try frame.encodeToXPC()
        do {
            try session.send(message: XPCDictionary(object))
        } catch {
            throw RPCError(
                code: .unavailable,
                message: "stream \(frame.streamID): the XPC connection is no longer available "
                    + "(sending \(frame.kindDescription) failed: \(error))")
        }
    }

    /// Sends a credit-bearing `.message` frame: an XPC message *expecting a reply*, where the reply
    /// is the flow-control credit (design section 6). `onCredit` is called exactly once -- with the
    /// number of permits the peer granted, or with a failure if the reply failed or the connection
    /// died first.
    ///
    /// This does not itself suspend. The suspension lives in the caller's ``CreditWindow``, which
    /// admits a *window* of unacknowledged messages rather than one at a time: awaiting each reply
    /// inline here would deadlock any pair of handlers that both burst before reading (see
    /// ``XPCBackpressure/defaultCreditWindow``).
    func sendAwaitingCredit(_ frame: XPCFrame,
                            onCredit: @escaping @Sendable (Result<Int, any Error>) -> Void) throws {
        let streamID = frame.streamID
        let object = try frame.encodeToXPC()   // before registering: a throw here owes no credit
        let token = nextCreditToken.wrappingAdd(1, ordering: .relaxed).oldValue
        registry.withLock { $0.pendingCredits[token] = PendingCredit(streamID: streamID, complete: onCredit) }
        session.send(message: XPCDictionary(object)) { [weak self] result in
            // Nothing to do if the connection is already gone: its `deinit` ran `failAll`, which
            // completed this very pending credit with `.unavailable` and took it out of the table.
            guard let pending = self?.takePendingCredit(token) else { return }
            switch result {
            case .success(let reply):
                pending.complete(.success(Self.permits(inCreditReply: reply)))
            case .failure(let error):
                pending.complete(.failure(RPCError(
                    code: .unavailable,
                    message: "stream \(streamID): the flow-control reply failed: \(error)")))
            }
        }
    }

    private func takePendingCredit(_ token: UInt64) -> PendingCredit? {
        registry.withLock { $0.pendingCredits.removeValue(forKey: token) }
    }

    /// How many permits a credit reply grants: **always exactly one**, whatever the reply says.
    ///
    /// This is the boundary the peer's untrusted credit count crosses, and one permit is not a
    /// conservative choice but the only correct one: every credit-bearing send has its *own* XPC
    /// reply (see ``sendAwaitingCredit(_:onCredit:)``), so a reply acknowledges exactly one message
    /// and can only ever be worth exactly one permit. An earlier version honoured the frame's `n`
    /// -- nominally so a future receiver could batch -- which handed an untrusted peer a lever on
    /// this side's window: `n` is a wire `UInt32`, and a single inflated reply both broke the
    /// in-flight bound the window exists to impose and (unclamped) spun `CreditWindow.release` for
    /// ~450 seconds under its own lock. Batching would need the *protocol* to express one reply
    /// covering several messages, which it does not; until it does, `n` is not a number this side
    /// can act on. It stays on the wire (the reply is self-describing, and `n` can gain meaning
    /// without a wire change) but is deliberately not read here.
    ///
    /// A reply that is anything else -- an empty dictionary, a frame from a peer speaking a later
    /// version of this protocol -- also counts as one permit: mis-reading a reply must never
    /// *stall* a writer, since a lost permit is a permanent, silent loss of window.
    static func permits(inCreditReply reply: XPCDictionary) -> Int {
        1
    }

    private func handleInbound(_ message: XPCDictionary) {
        guard let frame = try? message.withUnsafeUnderlyingDictionary({ try XPCFrame.decode(from: $0) })
        else {
            // Undecodable message: not a well-formed `XPCFrame` at all, so there is no `StreamID`
            // to fail against -- drop it. (A peer sending garbage is itself a protocol violation
            // better addressed by Task 9's peer-death/misbehavior handling than by this layer.)
            return
        }
        route(frame, received: message)
    }

    /// Always dispatched on `queue` -- see the type's doc comment.
    ///
    /// `message` is the raw received dictionary the frame was decoded from, carried through because
    /// a `.message` frame's *reply* is this transport's flow-control credit and has to be withheld
    /// (held in the target stream's `CreditLedger`) rather than produced here. It is not `Sendable`
    /// and must not escape this synchronous call except into a `CreditLedger`, which is built for
    /// exactly that (see ``CreditLedger``).
    private func route(_ frame: XPCFrame, received message: XPCDictionary) {
        switch frame {
        case .openStream(let id, let method, _):
            guard let descriptor = Self.methodDescriptor(from: method) else {
                // Malformed "package.Service/Method": no stream is registered for `id` yet
                // (this frame is what would create one), so there is nothing to fail -- drop it.
                return
            }
            // Graceful shutdown: refuse *new* streams while letting in-flight ones drain (design
            // section 8). Answered with a terminal `.status(.unavailable)` rather than dropped, so
            // the peer's client fails its call immediately instead of waiting out a deadline for a
            // stream this side will never accept. A lone `.status` is a legal response stream
            // (`metadata* -> message* -> status`), so the peer's `StreamChannel` terminates cleanly.
            if isDraining {
                try? send(.status(id, code: RPCError.Code.unavailable.rawValue,
                                  message: "the peer is shutting down and is not accepting new streams",
                                  trailers: WireMetadata(Metadata())))
                return
            }
            // Build the server-side channel and the full `RPCStream` *now*, in the same routing
            // call as the `.openStream` frame itself -- not in a later, second call a consumer
            // makes after reading `acceptedStreams`. A real client writes metadata/the first
            // message right after `openStream`, and those frames must have somewhere to land the
            // moment they route (still on this same serial `queue`); a two-phase accept (yield an
            // id here, build the channel later) means either an unbounded window where frames
            // for `id` have nowhere to go, or -- if the channel is pre-built to close that window
            // -- a second table just to hold it until claimed, which itself either leaks (never
            // claimed) or, if cleared on terminal, discards whatever it was holding out from
            // under a still-pending claim. One phase avoids all three failure modes: `serverChannels[id]`
            // is both the only place the channel lives and the only thing `route` ever needs to
            // find to keep delivering frames to it.
            let (channel, inbound) = StreamChannel<RPCRequestPart<GRPCSwiftData>>.serverInbound(streamID: id)
            registry.withLock { $0.serverChannels[id] = channel }
            let outbound = RPCWriter.Closable(wrapping: XPCOutboundWriter<RPCResponsePart<GRPCSwiftData>>(
                streamID: id, connection: self, creditWindow: creditWindow))
            let stream = RPCStream(descriptor: descriptor, inbound: inbound, outbound: outbound)
            acceptedContinuation.yield(AcceptedStream(id: id, descriptor: descriptor, stream: stream))
        case .cancel(let id, let reason):
            // The peer aborted this RPC: fail the local half of it (`.cancelled`, per design
            // section 8) *and* signal the RPC's own cancellation handle if one is registered, so a
            // server handler sitting in `withRPCCancellationHandler` learns about it rather than
            // only discovering it when its inbound sequence throws.
            failStream(id, RPCError(code: .cancelled,
                                    message: "the peer cancelled stream \(id): \(reason)"))
        case .goAway:
            // The peer is shutting down gracefully: stop opening *new* streams on this connection
            // (`XPCClientTransport.withStream` reads `isDraining`), but leave every in-flight
            // stream alone -- letting those finish is exactly what makes the shutdown graceful.
            draining.store(true, ordering: .releasing)
        case .credit:
            // Credit travels on the XPC *reply* channel, not as a standalone frame (design section
            // 6 / deviation D1): a `.credit` frame is only ever the *payload of a reply* to a
            // `.message`, decoded by `permits(inCreditReply:)` on the sending side and never routed
            // here. Arriving as a top-level message it is an inert nudge -- which is precisely what
            // `XPCPairHarness` uses `.credit(0, n: 0)` for, to make a listener accept a session.
            break
        default:
            let id = frame.streamID
            let isCreditBearing: Bool = { if case .message = frame { return true } else { return false } }()
            var wasRouted = true
            registry.withLock { reg in
                if let c = reg.clientChannels[id] {
                    // Withheld *before* `accept` yields the part: `accept`'s yield can be picked up
                    // by a consumer on another thread immediately, and that consumer's pull is what
                    // grants the credit -- so the reply has to already be in the ledger by then, or
                    // the grant would find it empty and the peer's writer would lose a permit.
                    if isCreditBearing { c.credit.hold(message) }
                    do {
                        try c.accept(frame)
                        // `.status` is the response direction's sole terminator (see
                        // StreamChannel.swift) -- drop the entry so a long-lived connection
                        // doesn't grow one registry entry per completed RPC forever.
                        if case .status = frame { reg.clientChannels[id] = nil }
                    } catch {
                        // A grammar violation (out-of-order seq, frame after terminal, ...):
                        // the channel is already desynced, so fail it locally and stop routing
                        // to it rather than leaving a live-but-broken stream in the registry.
                        reg.clientChannels[id] = nil
                        c.failInbound(error)
                    }
                } else if let s = reg.serverChannels[id] {
                    if isCreditBearing { s.credit.hold(message) }
                    do {
                        try s.accept(frame)
                        // `.halfClose` is the request direction's sole terminator.
                        if case .halfClose = frame { reg.serverChannels[id] = nil }
                    } catch {
                        reg.serverChannels[id] = nil
                        s.failInbound(error)
                    }
                }
                // Else: a frame for a `StreamID` with no registered channel in either table --
                // e.g. it arrived after that stream's entry was already removed above (a
                // straggler after a terminal), or the peer referenced an id this side never
                // opened/accepted. Dropped; there is no local stream left to fail.
                else { wasRouted = false }
            }
            // A credit-bearing frame that reached no stream must still be credited, immediately:
            // there is no ledger holding its reply and no consumer that will ever pull for it, so
            // withholding it would silently shrink the peer's window by one permit per straggler
            // until its writer stalled for good.
            if isCreditBearing && !wasRouted { CreditLedger(streamID: id).hold(message) }
        }
    }

    /// Splits the wire's "pkg.Service/Method" on the *last* "/" into service + method.
    /// `MethodDescriptor` has no `fullyQualifiedMethod:` initializer, only
    /// `fullyQualifiedService:method:` -- confirmed against the resolved grpc-swift-2 2.4.2
    /// source. Returns `nil` for a string with no "/" or an empty service/method half.
    private static func methodDescriptor(from wireMethod: String) -> MethodDescriptor? {
        guard let slash = wireMethod.lastIndex(of: "/") else { return nil }
        let service = String(wireMethod[..<slash])
        let method = String(wireMethod[wireMethod.index(after: slash)...])
        guard !service.isEmpty, !method.isEmpty else { return nil }
        return MethodDescriptor(fullyQualifiedService: service, method: method)
    }

    /// Allocates a `StreamID`, registers its inbound `StreamChannel`, and returns the full
    /// client-side `RPCStream` (inbound responses + outbound requests writer).
    ///
    /// - Important: the caller must keep this connection alive for as long as the returned
    ///   stream is in use -- the stream does not hold it back. If the connection is released
    ///   first, further writes fail with `RPCError(code: .unavailable, ...)` and the inbound
    ///   sequence fails rather than hanging.
    func openClientStream(descriptor: MethodDescriptor)
    -> (StreamID, RPCStream<RPCAsyncSequence<RPCResponsePart<GRPCSwiftData>, any Error>,
                            RPCWriter<RPCRequestPart<GRPCSwiftData>>.Closable>) {
        let id = nextStreamID.wrappingAdd(1, ordering: .relaxed).oldValue
        let (channel, inbound) = StreamChannel<RPCResponsePart<GRPCSwiftData>>.clientInbound(streamID: id)
        registry.withLock { $0.clientChannels[id] = channel }
        let outbound = RPCWriter.Closable(wrapping: XPCOutboundWriter<RPCRequestPart<GRPCSwiftData>>(
            streamID: id, connection: self, creditWindow: creditWindow))
        return (id, RPCStream(descriptor: descriptor, inbound: inbound, outbound: outbound))
    }

    // MARK: - Per-stream RPC cancellation

    /// Registers `body` as "this RPC has been cancelled" for `id`, and reports whether the
    /// connection is *already* draining.
    ///
    /// The table lives here rather than in `XPCServerTransport` (where the reference in-process
    /// transport keeps its equivalent) for one reason: this is the object that routes an inbound
    /// `.cancel` frame and that learns about peer death, so keying the callbacks by `StreamID` is
    /// what lets a cancel for *one* stream reach exactly that stream's handle instead of every
    /// handler on the connection.
    ///
    /// The returned flag closes the same race the reference guards: a shutdown that lands after a
    /// stream was accepted but before its handler task got to run would otherwise never reach that
    /// handler, whose handle did not exist yet when the shutdown swept the table.
    ///
    /// - Important: `body` must be cheap and non-blocking -- it can be called on this connection's
    ///   serial queue (from `route`) or from a session cancellation handler.
    func setCancellationObserver(forStream id: StreamID,
                                 _ body: @escaping @Sendable () -> Void) -> Bool {
        registry.withLock { $0.cancellationObservers[id] = body }
        return isDraining
    }

    /// Signals every live stream's cancellation handle without failing anything.
    ///
    /// This is the *graceful* half of shutdown: it asks in-flight handlers to wind themselves up
    /// (their `withRPCCancellationHandler` bodies fire, `ServerContext.cancellation.isCancelled`
    /// flips) and then leaves them to finish their own streams. Nothing is torn down here -- see
    /// ``failAll(_:)`` for the forceful counterpart.
    func signalCancellationToAllStreams() {
        let observers = registry.withLock { Array($0.cancellationObservers.values) }
        observers.forEach { $0() }
    }

    /// A server-side stream whose handler has *returned*.
    ///
    /// Without this, nothing on the handler-completed path retires the stream: only `halfClose`,
    /// `.cancel`, or the connection's death removed `serverChannels[id]`, and only those flushed
    /// its `CreditLedger`. So a handler that read one message and returned left up to a full
    /// window of withheld credit replies pinned forever, and a peer still writing on that stream
    /// parked in `write` for good (measured before this existed: a 200-message client got 33
    /// through and then hung). Dropping the entry makes later frames for `id` unroutable, and an
    /// unroutable credit-bearing frame is credited immediately by ``route(_:received:)`` -- so the
    /// peer's writer keeps moving instead of stalling. Flushing the ledger releases what was
    /// already held.
    ///
    /// Deliberately does **not** fail the stream: the handler finished, so there is no error to
    /// report, and its outbound writes (a `.status` sent as the very last thing, possibly still
    /// in flight) must not be disturbed.
    func streamHandlerFinished(_ id: StreamID) {
        let channel = registry.withLock { reg -> StreamChannel<RPCRequestPart<GRPCSwiftData>>? in
            reg.cancellationObservers[id] = nil
            return reg.serverChannels.removeValue(forKey: id)
        }
        channel?.credit.flush()
    }

    // MARK: - Failure paths

    func failStream(_ id: StreamID, _ error: any Error) {
        let (orphaned, observer): ([PendingCredit], (@Sendable () -> Void)?) = registry.withLock { reg in
            reg.clientChannels[id]?.failInbound(error); reg.clientChannels[id] = nil
            reg.serverChannels[id]?.failInbound(error); reg.serverChannels[id] = nil
            // A writer on this stream suspended for credit has to be released too, or cancelling an
            // RPC would leave it parked on a reply that is never coming.
            let doomed = reg.pendingCredits.filter { $0.value.streamID == id }
            doomed.keys.forEach { reg.pendingCredits[$0] = nil }
            return (Array(doomed.values), reg.cancellationObservers.removeValue(forKey: id))
        }
        // Completed outside the lock: `complete` resumes a writer's continuation, and `observer`
        // reaches into gRPC's cancellation machinery.
        orphaned.forEach { $0.complete(.failure(error)) }
        observer?()
    }

    /// Begins a graceful shutdown of this connection's *inbound* direction: tells the peer to stop
    /// opening streams (`.goAway`), refuses any that arrive regardless (see `route`'s `.openStream`
    /// arm -- a `.goAway` in flight does not stop a stream the peer already sent), and finishes
    /// ``acceptedStreams`` so an accept loop ends.
    ///
    /// Nothing in flight is failed. That is the difference between this and ``failAll(_:)``, and it
    /// is the whole of "graceful": `XPCServerTransport.listen`'s task group keeps running every
    /// handler that is already going, and `listen()` returns only once the last of them has
    /// finished. A caller that needs the connection gone *now* follows this with ``failAll(_:)``.
    func stopAcceptingNewStreams() {
        draining.store(true, ordering: .releasing)
        // Best effort: a peer that is already gone cannot be told anything, and a `.goAway` that
        // fails to send changes nothing about this side's refusal to accept new streams.
        try? send(.goAway)
        acceptedContinuation.finish()
    }

    /// On peer death / shutdown: fails every live stream's inbound sequence and finishes
    /// ``acceptedStreams``. Wired to the session's cancellation handler in `init` (peer death);
    /// `deinit` separately finishes the accepted-streams continuation (see there) since by then
    /// there may be no error to report and no streams left to fail.
    func failAll(_ error: any Error) {
        draining.store(true, ordering: .releasing)
        let (orphaned, observers): ([PendingCredit], [@Sendable () -> Void]) = registry.withLock { reg in
            reg.clientChannels.values.forEach { $0.failInbound(error) }
            reg.serverChannels.values.forEach { $0.failInbound(error) }
            let doomed = Array(reg.pendingCredits.values)
            let observers = Array(reg.cancellationObservers.values)
            reg = Registry()
            return (doomed, observers)
        }
        // Every live RPC's cancellation handle fires too: a handler that is *not* currently reading
        // its inbound sequence (it may be writing, or awaiting something else entirely) would
        // otherwise not learn that the RPC is over from the inbound failure alone.
        observers.forEach { $0() }
        // Every writer suspended for credit fails here rather than hanging. This is the *only*
        // thing that releases them: libxpc silently drops the reply handlers of a cancelled
        // session (verified by probe), so a dead connection produces no reply, no error, nothing.
        // Completed outside the lock because `complete` resumes a writer's continuation.
        orphaned.forEach { $0.complete(.failure(error)) }
        acceptedContinuation.finish()
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension XPCFrame {
    var streamID: StreamID {
        switch self {
        case .openStream(let id, _, _), .metadata(let id, _), .message(let id, _, _),
             .halfClose(let id), .status(let id, _, _, _), .cancel(let id, _), .credit(let id, _):
            return id
        case .goAway: return 0
        }
    }

    /// The frame's kind alone, for error messages -- deliberately without its payload, which can be
    /// a whole message body.
    var kindDescription: String {
        switch self {
        case .openStream: return "openStream"
        case .metadata: return "metadata"
        case .message: return "message"
        case .halfClose: return "halfClose"
        case .status: return "status"
        case .cancel: return "cancel"
        case .credit: return "credit"
        case .goAway: return "goAway"
        }
    }
}
