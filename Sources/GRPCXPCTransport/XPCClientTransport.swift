import Dispatch
import GRPCCore
import Synchronization

/// grpc-swift's `ClientTransport` over one `RPCTransportCore` -- i.e. over one XPC session.
///
/// This type is thin on purpose. Every hard part of a client transport lives one layer down:
/// stream-id allocation, the op grammar, flow control and the deadline timer are all
/// `RPCTransportCore`'s (see `RPCTransportCore.openStream(descriptor:timeout:)`), and the XPC
/// session itself is `XPCPipe`'s. What is left here is exactly three things:
///
/// 1. `connect()`'s lifecycle machine (L7) -- park, and be released by a shutdown or by
///    cancellation of `connect()`'s own task;
/// 2. `withStream`'s obligation to retire the stream on **every** exit path
///    (`clientCallFinished(_:)`, which is also what cancels the deadline timer -- L12);
/// 3. refusing new streams once either side is draining.
///
/// # Ownership (L6)
///
/// `core` is held strongly and is this transport's only stored reference; the core holds the pipe,
/// the pipe holds the `XPCSession`, and libxpc's end of that chain reaches back into the core
/// **weakly** (`RPCTransportCore.init` installs both pipe handlers with `[weak self]`). So nothing
/// outside this transport holds it, and dropping it runs `deinit` all the way down to
/// `session.cancel()`. There is no `deinit` here, and there deliberately is not one: the core's own
/// `deinit` fails every live stream and cancels the pipe, which is the whole of what this type
/// would have to do.
///
/// A `final class`, not a struct, because `state`'s `Synchronization.Mutex` is `~Copyable` and a
/// `Copyable` struct cannot store one.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class XPCClientTransport: ClientTransport {
    public typealias Bytes = GRPCSwiftData

    private let core: RPCTransportCore

    /// `connect()`'s state, made explicit rather than "one optional continuation slot": that
    /// earlier shape let a second concurrent `connect()` silently overwrite the first's
    /// continuation, leaking it (the runtime reports this as "SWIFT TASK CONTINUATION MISUSE")
    /// and stranding the first caller parked forever. With this enum every transition is
    /// explicit: `.idle -> .connected` (first `connect()` parks), `.connected -> .shutDown`
    /// (`beginGracefulShutdown()`, or cancellation of `connect()`'s own task, resumes the parked
    /// caller and retires the slot), and `.idle -> .shutDown` (either of those arriving before
    /// any `connect()` call, so a *later* `connect()` returns immediately instead of parking on
    /// a shutdown that already happened).
    private enum ConnectState {
        case idle
        case connected(CheckedContinuation<Void, any Error>)
        case shutDown
    }
    private let state = Mutex<ConnectState>(.idle)

    /// Adopts an already-live client-role core. The factories below are the ordinary way in; this
    /// exists separately because the in-process pair (`XPCServerTransport.connectingClient()`)
    /// builds its core from an endpoint, which only the XPC-importing file can name.
    init(core: RPCTransportCore) {
        precondition(
            core.role == .client,
            "XPCClientTransport requires a client-role RPCTransportCore: only a client allocates "
                + "stream ids")
        self.core = core
    }

    // =======================================================================================
    // MARK: - Dialling
    // =======================================================================================

    /// How a client names its peer. Deliberately *not* including an `XPCEndpoint` case: naming
    /// that type would mean `import XPC` in this file, and the accept/dial traps documented in
    /// `XPCPipe` are only encapsulated while the set of files that can reach libxpc stays at
    /// `XPCPipe.swift`, `GRPCDispatchData.swift` and `XPCServerTransport.swift`. Endpoint dialling
    /// therefore lives on the server transport, which already owns an `XPCListener`.
    private enum Peer {
        case machService(String)
        case xpcService(String)

        var label: String {
            switch self {
            case .machService(let name): "machService:\(name)"
            case .xpcService(let name): "xpcService:\(name)"
            }
        }
    }

    /// Dials a launchd Mach service by name and returns a transport speaking to it.
    ///
    /// The session is live when this returns -- `XPCPipe`'s dial factory activates it -- so
    /// `connect()` has no connecting work to do. A peer that is not there yet is not an error here:
    /// libxpc will launch or wait for it, and a peer that never appears surfaces as peer death,
    /// which fails every stream with `.unavailable`.
    public static func connecting(toMachService name: String) throws -> XPCClientTransport {
        try dialling(.machService(name))
    }

    /// Dials an XPC service bundle inside the calling application, by bundle identifier.
    public static func connecting(toXPCService name: String) throws -> XPCClientTransport {
        try dialling(.xpcService(name))
    }

    private static func dialling(_ peer: Peer) throws -> XPCClientTransport {
        // One serial queue per connection (Task 5 §6.4). Nothing else may share it: the mux
        // decodes and routes every inbound blob on it, and `XPCPipe.accepting` blocks on the
        // queue it is handed.
        let queue = DispatchSerialQueue(label: "GRPCXPCTransport.client.\(peer.label)")

        // `building` runs synchronously inside the factory, before the session is activated, and
        // `RPCTransportCore.init` installs both pipe handlers itself (weakly). Installing our own
        // here would *replace* the core's and silently disconnect the mux.
        var built: RPCTransportCore?
        let build: (XPCPipe) -> Void = { pipe in
            built = RPCTransportCore(pipe: pipe, codec: CompactWireCodec(), role: .client)
        }
        // The returned pipe is intentionally discarded: `built` holds it strongly, so this is not
        // its last reference. (A dialled pipe must be activate-then-cancelled before release, and
        // `XPCPipe` owns that -- see its disposal matrix.)
        switch peer {
        case .machService(let name):
            _ = try XPCPipe.connecting(toMachService: name, queue: queue, building: build)
        case .xpcService(let name):
            _ = try XPCPipe.connecting(toXPCService: name, queue: queue, building: build)
        }

        guard let core = built else {
            // Unreachable: both factories call `building` synchronously before returning. A trap
            // rather than a thrown error, because the only way here is a broken `XPCPipe`, and
            // recovering would mean handling a pipe with no mux behind it.
            preconditionFailure("XPCPipe.connecting did not run its `building` closure")
        }
        return XPCClientTransport(core: core)
    }

    // =======================================================================================
    // MARK: - ClientTransport
    // =======================================================================================

    /// No throttle: retry policy is a `MethodConfig` concern and this transport supplies none.
    public var retryThrottle: RetryThrottle? { nil }

    /// Blocks until `beginGracefulShutdown()` is called, or until this call's own task is
    /// cancelled -- mirroring `GRPCInProcessTransport`'s reference client, which parks the same
    /// way and also returns (rather than throwing) once its task is cancelled.
    ///
    /// **Returning normally on cancellation, not throwing `CancellationError`, matters beyond
    /// style:** `GRPCClient.runConnections()` calls `transport.connect()` and wraps *any* thrown
    /// error -- cancellation included -- in a `RuntimeError(code: .transportError, ...)`, which
    /// would misreport an ordinary cancelled shutdown as a transport failure.
    ///
    /// There is genuinely no connecting work to do: `XPCPipe`'s dial factory returns an already
    /// activated session, so by the time a transport exists the connection exists.
    ///
    /// A second, concurrent call while one `connect()` is already parked is refused with a thrown
    /// `RPCError(code: .failedPrecondition)` rather than silently clobbering the first -- gRPC's
    /// own client throws (`RuntimeError`) rather than traps when its analogous
    /// `runConnections()` is misused this way, so a thrown error is the precedent this follows; a
    /// caller that never calls `connect()` twice concurrently (the documented, correct usage)
    /// never sees it.
    public func connect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                // L7: take-and-transition under the lock, resume *outside* it.
                let immediate: Result<Void, any Error>? = state.withLock { current in
                    switch current {
                    case .idle:
                        current = .connected(continuation)
                        return nil  // parked; resumed later by shutdown or cancellation
                    case .connected:
                        return .failure(
                            RPCError(
                                code: .failedPrecondition,
                                message: "XPCClientTransport.connect() is already running "
                                    + "-- it must not be called more than once concurrently"))
                    case .shutDown:
                        return .success(())
                    }
                }
                switch immediate {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                case nil: break  // parked above; nothing to resume yet
                }
            }
        } onCancel: {
            self.shutDownAndTakePending()?.resume()
        }
    }

    /// Begins a **graceful** shutdown: sends `goAway`, refuses new streams, and lets the calls
    /// already in flight run to completion. Returns immediately.
    ///
    /// Three things happen, in this order:
    /// 1. `core.beginDraining()` -- `goAway` on the wire, and `openStream` throws `.unavailable`
    ///    from here on, so `withStream` refuses new calls;
    /// 2. this transport's own state moves to `.shutDown`, which is the second, local gate
    ///    `withStream` checks;
    /// 3. a parked `connect()` is resumed and returns normally.
    ///
    /// It deliberately does **not** call `core.failAll(...)` or `core.close()`: failing in-flight
    /// streams is the opposite of draining them. The XPC session is released when this transport
    /// is -- the core's `deinit` fails whatever is left and cancels the pipe.
    ///
    /// Idempotent: a second call finds `.shutDown`, takes no continuation, and `beginDraining()`
    /// is itself a no-op once draining.
    public func beginGracefulShutdown() {
        core.beginDraining()
        shutDownAndTakePending()?.resume()
    }

    /// Moves to `.shutDown` and hands back whatever `connect()` call was parked, if any -- the one
    /// piece of logic `beginGracefulShutdown()` and cancellation of `connect()`'s task share,
    /// since both end `connect()` the same way (resume it to return normally). Called at most once
    /// per parked continuation because the state leaves `.connected` the moment it is taken, so a
    /// second caller (a duplicate `beginGracefulShutdown()`, or shutdown racing cancellation)
    /// finds `.shutDown` and gets `nil` back -- never a second resume of the same continuation,
    /// which would trap.
    ///
    /// The continuation is *returned* rather than resumed here so the resume happens outside the
    /// lock (L7).
    private func shutDownAndTakePending() -> CheckedContinuation<Void, any Error>? {
        state.withLock { current in
            let pending: CheckedContinuation<Void, any Error>?
            if case .connected(let continuation) = current {
                pending = continuation
            } else {
                pending = nil
            }
            current = .shutDown
            return pending
        }
    }

    /// Opens one RPC, runs `closure` against it, and retires it on the way out.
    ///
    /// # The deadline (L12)
    ///
    /// **Exactly one timer is armed per deadline-bearing RPC, and this method arms none of them.**
    /// `options.timeout` is passed to `RPCTransportCore.openStream(descriptor:timeout:)`, which
    /// arms a single `DispatchSourceTimer` on the connection's queue, owned by the stream's
    /// registry entry. On expiry it does exactly what this method's predecessor did by hand: a
    /// `cancel` op to the peer, and the local inbound half failed with
    /// `RPCError(code: .deadlineExceeded)` -- which is what unblocks the closure, since its
    /// `stream.inbound` iteration throws and any writer parked on credit is released.
    ///
    /// The old build armed a `Task { try await Task.sleep(...) }` here as well. That is now a
    /// *second* timer for the same RPC, which is precisely what L12 forbids, so it is gone. The
    /// core's timer is cancelled by every path that removes the stream from the table -- and
    /// `defer { core.clientCallFinished(id) }` below is what guarantees one of those paths runs on
    /// **every** exit from this method: a normal return, a throw from `closure`, and cancellation
    /// of this call's task (the `defer` runs while unwinding either way). After a clean completion
    /// the call is free: the entry is already gone, so `clientCallFinished` finds nothing, sends
    /// nothing, and returns.
    ///
    /// The same `defer` is the "send `cancel` if the stream did not terminate cleanly" rule: the
    /// *presence of a table entry* at that moment is the definition of "did not complete", so
    /// `clientCallFinished` needs no other signal to decide.
    public func withStream<T: Sendable>(
        descriptor: MethodDescriptor,
        options: CallOptions,
        _ closure: (RPCStream<Inbound, Outbound>, ClientContext) async throws -> T
    ) async throws -> T {
        // Refuse to open a stream once either end is shutting down: this transport's own
        // `beginGracefulShutdown()`, or the peer's `goAway` (which sets `core.isDraining`).
        // Failing here is strictly better than opening a stream the peer will immediately refuse
        // -- the caller gets `.unavailable`, which is retryable, instead of waiting out a
        // deadline. `core.openStream` also checks, under its own lock, so this is a clearer error
        // rather than the only gate.
        let isShutDown = state.withLock { current -> Bool in
            if case .shutDown = current { true } else { false }
        }
        if isShutDown || core.isDraining {
            let reason =
                isShutDown
                ? "this transport has shut down"
                : "the connection is draining (the peer sent goAway, or it has been torn down)"
            throw RPCError(code: .unavailable, message: "no new streams: \(reason)")
        }

        // The `openStream` op is not sent here: `RequestOpEncoder` prepends it to whatever the
        // first write produces, so a stream that is opened and abandoned costs the peer nothing.
        let (id, stream) = try core.openStream(descriptor: descriptor, timeout: options.timeout)
        defer { core.clientCallFinished(id) }

        let context = ClientContext(
            descriptor: descriptor,
            remotePeer: "xpc:peer",
            localPeer: "xpc:self")

        // Mirrors `GRPCInProcessTransport`'s client: the closure's own result (success or thrown
        // error) is what this method returns/rethrows, but the stream's outbound side is always
        // closed on the way out -- "the opened stream is closed after the closure is finished" is
        // `ClientTransport.withStream`'s documented contract, not optional cleanup. `finish()` is
        // safe even if `closure` already called it: `OutboundOpWriter` is idempotent there and,
        // once its encoder has thrown, deliberately silent.
        let outcome: Result<T, any Error>
        do {
            outcome = .success(try await closure(stream, context))
        } catch {
            outcome = .failure(error)
        }
        await stream.outbound.finish()
        return try outcome.get()
    }

    /// No per-method configuration: this transport negotiates nothing (§O5) and supplies no
    /// retry or hedging policy.
    public func config(forMethod descriptor: MethodDescriptor) -> MethodConfig? { nil }
}
