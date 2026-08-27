import Dispatch
import GRPCCore
import Synchronization

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

// The mux. One `RPCTransportCore` per connection: it holds a `MessagePipe` (the substrate) and a
// `WireCodec` (the encoding) and turns a single ordered blob channel into concurrent gRPC
// streams. Everything the earlier tasks built meets here --
//
//   RPCOp                 the eight ops and the two seams
//   CompactWireCodec      ops <-> blobs
//   FlowControl           FlowControlWindow (send side) + WindowAccountant (receive side)
//   StreamStateMachines   the four per-stream grammar machines
//   XPCPipe               the MessagePipe conformer
//
// **This file must not `import XPC`.** It is the seam that keeps the op layer portable; with no
// separate module, the absence of that import is the only compiler-enforced statement of it. If
// something here appears to need an XPC type, the abstraction is wrong -- report it, do not
// import.
//
// ## Where the plan's lessons live, structurally
//
// * **L4 -- serial routing.** Every inbound blob is decoded and routed on `pipe.queue`, the
//   substrate's single serial queue (`MessagePipe`'s ordering contract in `RPCOp.swift` promises
//   that every `onReceive`/`onPeerDeath` invocation happens there, and only there). That is why
//   `RequestOpDecoder`/`ResponseOpDecoder` carry no locks: one op at a time, in order, per
//   connection. `receive(_:)` asserts it with a `dispatchPrecondition` tripwire. Note the
//   precondition is target-chain permissive (measured in Task 5), so it catches "called from
//   somewhere else entirely", not "called from a child queue of the right one".
//
// * **L5 -- one-phase accept.** `openInbound` builds the decoder, the flow-control windows, the
//   inbound sequence, the outbound writer and the whole `RPCStream`, inserts the table entry, and
//   *then* yields a fully built ``AcceptedRPCStream`` -- all inside one routing turn on the
//   queue. There is **no pending table** and no register-later phase, which is what the old build
//   had and what produced dropped ops, a table leak and then silent data loss.
//
// * **L6 -- ownership, in both directions.** The core owns the pipe; nothing that the pipe or
//   libxpc transitively retains owns the core:
//   - the two pipe handlers are installed by `init` itself with `[weak self]` (see
//     ``installPipeHandlers()``) -- a strong capture closes
//     `libxpc -> session handlers -> Delivery -> handler -> core -> pipe -> session`, makes
//     `deinit` unreachable and leaks the XPC session. Task 5 measured exactly that on its first
//     probe run. Installing them here rather than asking the caller to remember `[weak core]` is
//     what makes the rule structural.
//   - every outbound writer holds the core through ``WeakCore``, and every inbound sequence's
//     consumption callback captures it weakly too. Both matter: an accepted stream sits in
//     `acceptedStreams`' buffer *inside* the core until `listen()` drains it, so a strong edge
//     back would make the core immortal.
//   - a write after the core is gone throws `RPCError(code: .unavailable)`; it never traps and
//     never reports a send that did not happen.
//
// * **L7 -- explicit lifecycle.** `Phase = .running | .draining | .closed` under the one
//   `registry` mutex, taken-and-transitioned atomically. No continuation is ever resumed under a
//   lock: every window `grant`/`release`/`fail`, every `AsyncThrowingStream.Continuation` call and
//   every `pipe.send` happens after `withLock` has returned.
//
// * **L12 -- deadline timers.** At most one `DispatchSourceTimer` per deadline-bearing RPC, owned
//   by that RPC's table entry, activated only after the entry is in the table, and cancelled on
//   *every* removal path (``removeStream(_:failingInboundWith:sendingCancel:)`` and ``failAll``).
//
// ## What a hostile peer can and cannot do
//
// The peer controls every stream id, every declared length and every op kind. Consequences that
// are deliberate design, not accidents:
//
// * **Connection-level ops are dispatched by KIND, before any stream lookup.** `credit` and
//   `goAway` never reach a stream machine -- the machines carry a `preconditionFailure` for them
//   precisely because they must never see one, and "find the stream, then hand it the op" would
//   turn that into a remote crash. `cancel` is dispatched by kind too, for a different reason
//   (see ``route(_:)``).
// * **Ops for an unknown or already-removed stream id are dropped**, not answered. Echoing a
//   `cancel` per unknown op would hand the peer a 1:1 amplification lever and would also fire on
//   the entirely ordinary race where a stream was retired while the peer's last ops were in
//   flight. Their flow-control charge is still returned to the connection window, so dropping
//   costs no window (see ``deliver(_:toStream:)``).
// * **An accept is refused, never trapped.** A stream id of 0, an even id, a malformed method
//   path, a draining connection or too many concurrent streams all produce a `status` or `cancel`
//   op for that id and no table entry.
// * **Concurrent inbound streams are capped** at ``maxConcurrentInboundStreams``. §O4's byte
//   credit bounds bytes per stream but says nothing about stream *count*, and §O5 negotiates
//   nothing, so this is a local resource guard rather than protocol surface: an over-limit
//   `openStream` is answered with `status(resourceExhausted)`, which is an ordinary gRPC failure
//   the peer's client already understands.
// * **A grammar violation fails one stream** (§O2): the machine's throw is never `try?`-swallowed,
//   the stream is removed, its inbound sequence is failed with the machine's own error, and a
//   `cancel` op goes out. The connection is untouched.
// * **A blob that will not decode fails the connection.** That is the one deliberate exception,
//   and it is not a §O2 violation: a framing error is not attributable to any stream and leaves
//   the remainder of the blob unparseable, so there is nothing to resynchronise to.
// * **An overflowing `credit` fails the connection**, per the plan's contract line 3 -- that one
//   *is* a peer-triggered teardown, and it is the only one besides a framing error.

// ===========================================================================================
// MARK: - The accepted-stream payload
// ===========================================================================================

/// One inbound RPC, fully built, as handed to a server transport's accept loop.
///
/// **Deliberately not named `AcceptedStream`.** `Sources/GRPCXPCTransport/XPCConnection.swift`
/// (the legacy custom-protocol stack this plan replaces) already owns that name in this module and
/// stays compiling until Task 7 deletes it. This is the same collision `RPCStreamID` avoided by
/// the same means, for the same reason: no rename churn at the swap.
///
/// Every field is final by the time this value exists -- L5. `timeout` is the deadline the client
/// asked for on its `openStream` op, surfaced here because `RPCRequestPart` has no case for it;
/// the core has already armed the matching deadline timer by the time this is yielded, so a
/// consumer does not have to.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct AcceptedRPCStream: Sendable {
    let id: RPCStreamID
    let descriptor: MethodDescriptor
    let timeout: Duration?
    let stream: RPCTransportCore.ServerRPCStream
}

// ===========================================================================================
// MARK: - RPCTransportCore
// ===========================================================================================

/// The multiplexer: a stream table, id allocation, op sequencing through the per-stream state
/// machines, credit-based flow control, and the connection lifecycle (cancel, deadlines, drain,
/// peer death) over one `MessagePipe`.
///
/// # The surface Task 7's two transports are written against
///
/// ```swift
/// // construction -- inside XPCPipe's `building` closure, per Task 5 report §2
/// let core = RPCTransportCore(pipe: pipe, codec: CompactWireCodec(), role: .server)
/// // (no pipe.onReceive/onPeerDeath call: `init` installs both, weakly. See L6 above.)
///
/// // client
/// let (id, stream) = try core.openStream(descriptor: descriptor, timeout: options.timeout)
/// core.cancelStream(id, reason: "…")            // withStream exit / local abandon
///
/// // server
/// for await accepted in core.acceptedStreams { … ; core.streamHandlerFinished(accepted.id) }
/// let alreadyOver = core.setCancellationObserver(forStream: id) { handle.cancel() }
///
/// // both
/// core.beginDraining()                          // goAway + refuse new streams + end accept loop
/// core.signalCancellationToAllStreams()         // ask in-flight RPCs to wind up
/// core.failAll(error)                           // forceful teardown
/// core.close()                                  // failAll(.unavailable) + pipe.cancel()
/// ```
///
/// # Ownership, and the one hazard a caller must respect
///
/// The core owns the pipe strongly and the transport owns the core. Nothing owns the core back
/// (L6). Two consequences a caller has to know:
///
/// - **A stream outlives its core only as a corpse.** Its writer throws `.unavailable` and its
///   inbound sequence has already been failed by `deinit`. Whoever hands `RPCStream`s out must
///   keep the core alive for as long as they are in use -- the reviewed `XPCServerTransport`
///   pattern of holding the connection in the per-stream task is the shape.
/// - **Do not drop the core inside an accept window.** If the core is built inside
///   `XPCPipe.accepting`'s `building` closure, releasing it between `building` returning and the
///   `Decision` reaching libxpc runs `deinit`, which calls `pipe.cancel()` on a session still
///   inside its accept window -- a **process death**, documented on `XPCPipe.accepting`'s
///   `- Important:` and not closable from inside either file. Publish the core (or the pipe)
///   before returning the `Decision`. Dropping it *inside* `building` is safe: an accepted pipe's
///   `sessionIsLive` is still false there, so the `cancel()` is a no-op.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class RPCTransportCore: Sendable {

    // =======================================================================================
    // MARK: - Vocabulary
    // =======================================================================================

    /// Which half of the connection this core is. It decides who allocates stream ids (the
    /// client, odd and ascending), which decoder/encoder pair each stream gets, and whether an
    /// inbound `openStream` is an accept or a protocol error.
    enum Role: Sendable {
        case client
        case server
    }

    /// A client-side RPC: response parts in, request parts out.
    typealias ClientRPCStream = RPCStream<
        RPCAsyncSequence<RPCResponsePart<GRPCSwiftData>, any Error>,
        RPCWriter<RPCRequestPart<GRPCSwiftData>>.Closable>

    /// A server-side RPC: request parts in, response parts out.
    typealias ServerRPCStream = RPCStream<
        RPCAsyncSequence<RPCRequestPart<GRPCSwiftData>, any Error>,
        RPCWriter<RPCResponsePart<GRPCSwiftData>>.Closable>

    /// The cap on simultaneously live *inbound* streams -- a local resource guard, not protocol
    /// surface (see the file overview). §O4's byte credit bounds a stream's bytes; nothing in the
    /// op model bounds how many streams a peer may open, and §O5 negotiates nothing, so without
    /// this a peer can spend ~40 wire bytes per `openStream` to buy a table entry, two windows and
    /// an `AsyncThrowingStream` each. Over-limit accepts are refused with
    /// `status(resourceExhausted)`, which is an ordinary gRPC failure on the peer's side.
    ///
    /// 256 is chosen in the range HTTP/2 servers use for `SETTINGS_MAX_CONCURRENT_STREAMS`
    /// (gRPC's own default is 100, nginx's 128) and is far above anything the test suite needs.
    static let maxConcurrentInboundStreams = 256

    // =======================================================================================
    // MARK: - Immutable state
    // =======================================================================================

    let role: Role
    private let pipe: any MessagePipe
    private let codec: any WireCodec

    /// The serial queue every inbound blob is decoded and routed on -- the pipe's own (L4).
    var queue: DispatchSerialQueue { pipe.queue }

    /// The connection's outbound flow-control window: §O4's second reservation, taken after the
    /// stream's. One per connection, shared by every stream, and the window whose FIFO makes two
    /// oversize senders queue rather than hold-and-wait (§O4).
    private let connectionSendWindow = FlowControlWindow()

    /// Inbound streams, fully built (L5). Finished by ``beginDraining()``, ``failAll(_:)`` and
    /// `deinit`; a client-role core never yields into it.
    let acceptedStreams: AsyncStream<AcceptedRPCStream>
    private let acceptedContinuation: AsyncStream<AcceptedRPCStream>.Continuation

    // =======================================================================================
    // MARK: - Mutable state (one lock)
    // =======================================================================================

    /// L7: explicit, not inferred from side effects.
    ///
    /// - `.running -> .draining`: local ``beginDraining()`` (we sent `goAway`) **or** an inbound
    ///   `goAway` (the peer will accept no more new streams). Either way ``openStream`` throws
    ///   `.unavailable` from here on; streams already open are untouched.
    /// - `.running`/`.draining` `-> .closed`: ``failAll(_:)`` -- peer death, a connection-level
    ///   protocol error, `deinit`, or a forceful teardown. Terminal.
    private enum Phase: Sendable {
        case running
        case draining
        case closed
    }

    /// One live stream's state.
    ///
    /// A struct held in the registry dictionary and mutated in place under the registry lock, per
    /// the repo convention (see `FlowControl.swift`): the synchronisation lives at the container,
    /// and `@unchecked Sendable` is declared at the value type because `DispatchSourceTimer` is a
    /// non-`Sendable` existential. Every field is only ever read or written under that lock, or
    /// after the whole value has been *removed* from the table by exactly one caller.
    private struct StreamEntry: @unchecked Sendable {
        let id: RPCStreamID

        /// This stream's inbound half: the grammar machine plus the continuation its parts are
        /// yielded into. Two cases rather than a generic, because the two decoders produce two
        /// different part types and the four machines are written out by hand (see
        /// `StreamStateMachines.swift`'s own note on why).
        var inbound: InboundMachine

        /// §O4's *stream* window for the outbound direction. Failed -- not released -- on every
        /// removal path: a removed stream's window is genuinely dead, and failing it is what wakes
        /// a writer parked on credit that is never coming.
        let sendWindow: FlowControlWindow

        /// §O4's receive-side ledger for this stream, batching credit at half the initial window.
        /// Discarded with the stream: the stream's window dies with it, and the connection's own
        /// accountant (which must outlive every stream) carries the connection half.
        var receive: WindowAccountant

        /// Charge received on this stream but not yet consumed by the application, and therefore
        /// not yet credited. Flushed into the **connection** accountant when the stream is
        /// removed -- that flush is L3: without it, a handler that returns without draining its
        /// request half strands exactly this many bytes of the peer's connection window forever,
        /// and after a handful of RPCs the connection wedges (measured in the old build: 33 of 200
        /// sent, then a permanent hang).
        var unconsumedCharge: Int = 0

        /// The outbound direction is finished: `halfClose` sent (client) or `status` sent (server).
        var localDone: Bool = false
        /// The inbound direction is finished: `halfClose` decoded (server) or `status` decoded
        /// (client). Set only by a *legitimate* terminator -- a violation or a `cancel` removes
        /// the entry outright instead.
        var remoteDone: Bool = false

        /// Fired when this stream is torn down abnormally, so a server handler's
        /// `ServerContext.cancellation` handle can be cancelled. Never fired on a clean
        /// completion, which would tell a handler it was cancelled after it had already succeeded.
        var cancellationObserver: (@Sendable () -> Void)?

        /// L12: at most one per deadline-bearing RPC, cancelled on every removal path.
        var deadlineTimer: DispatchSourceTimer?

        /// Ends this stream's inbound sequence. `error == nil` is the clean end-of-stream.
        func finishInbound(throwing error: (any Error)?) {
            switch inbound {
            case .request(_, let continuation):
                if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            case .response(_, let continuation):
                if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            }
        }
    }

    private enum InboundMachine {
        case request(
            RequestOpDecoder,
            AsyncThrowingStream<RPCRequestPart<GRPCSwiftData>, any Error>.Continuation)
        case response(
            ResponseOpDecoder,
            AsyncThrowingStream<RPCResponsePart<GRPCSwiftData>, any Error>.Continuation)
    }

    private struct Registry {
        var phase: Phase = .running
        var streams: [RPCStreamID: StreamEntry] = [:]

        /// Client-allocated stream ids: odd, ascending, never reused. `0` is the sentinel for
        /// "the id space is exhausted" -- 0 is reserved for the connection window (§O4) and so can
        /// never be a real stream id, which makes it a safe marker. Exhaustion throws rather than
        /// wrapping: a wrapped id would silently collide with a live stream.
        var nextClientStreamID: RPCStreamID = 1

        /// The highest stream id seen in either direction, for `goAway`'s `lastStreamID`.
        var highestStreamID: RPCStreamID = 0

        /// §O4's connection-level receive ledger. **One per connection, outliving every stream**
        /// -- `WindowAccountant` has no flush, so a per-stream instance would strand up to
        /// `threshold - 1` bytes of the connection window per RPC.
        var connectionReceive = WindowAccountant()

        /// `acceptedStreams`' continuation may be finished at most once, from three racing places.
        var acceptedFinished = false
    }

    private let registry = Mutex(Registry())

    /// How many streams are currently in the table.
    ///
    /// Diagnostics only, and it has to exist for them: contract line 7 ("no entry outlives its
    /// stream") is a claim about a private dictionary, and the old build's one-entry-per-RPC leak
    /// was invisible from every other part of this surface until the process ran out of memory.
    /// Same rationale as `FlowControlWindow.available` / `.waiterCount`. Advisory -- it can be
    /// stale before the getter returns.
    var liveStreamCount: Int { registry.withLock { $0.streams.count } }

    var isDraining: Bool {
        registry.withLock {
            switch $0.phase {
            case .running: return false
            case .draining, .closed: return true
            }
        }
    }

    // =======================================================================================
    // MARK: - Construction
    // =======================================================================================

    /// Builds the mux over `pipe` and installs both of the pipe's handlers.
    ///
    /// - Important: The caller must **not** also call `pipe.onReceive(_:)` or
    ///   `pipe.onPeerDeath(_:)`. `MessagePipe` documents those as set-once, and this initializer
    ///   sets them -- weakly, which is the whole point (L6; see the file overview). Task 5 report
    ///   §2.1's recipe shows the caller wiring `[weak core]` by hand; constructing the core is now
    ///   all that is needed, and the weak capture cannot be forgotten.
    ///
    /// - Parameters:
    ///   - pipe: the substrate. Owned strongly; `deinit` cancels it.
    ///   - codec: the encoding. `CompactWireCodec()` is the only conformer this plan ships.
    ///   - role: which half of the connection this is.
    init(pipe: any MessagePipe, codec: any WireCodec = CompactWireCodec(), role: Role) {
        self.pipe = pipe
        self.codec = codec
        self.role = role
        let (stream, continuation) = AsyncStream.makeStream(of: AcceptedRPCStream.self)
        self.acceptedStreams = stream
        self.acceptedContinuation = continuation
        self.installPipeHandlers()
    }

    /// L6, in one place. `[weak self]` on both handlers is load-bearing: a strong capture closes
    /// `libxpc -> session handlers -> Delivery -> handler -> core -> pipe -> session`, and libxpc
    /// holds its end until the session is cancelled -- which is what `deinit` does. So a strong
    /// capture makes `deinit` unreachable and leaks the XPC session (measured, Task 5 §2.5).
    private func installPipeHandlers() {
        pipe.onReceive { [weak self] blob in self?.receive(blob) }
        pipe.onPeerDeath { [weak self] in self?.peerDied() }
    }

    /// L6 and L10's "prove `deinit` is reachable": fails every stream, ends the accept sequence,
    /// and tears the substrate down. Reachable exactly because both pipe handlers and every writer
    /// and inbound callback hold this object weakly.
    ///
    /// `pipe.cancel()` is idempotent and, on an accepted `XPCPipe` whose accept window is still
    /// open, a documented no-op -- so this is safe even when the core is dropped inside
    /// `XPCPipe.accepting`'s `building` closure. It is *not* safe in the span between `building`
    /// returning and the `Decision` reaching libxpc; see the type's doc comment.
    deinit {
        failAll(
            RPCError(
                code: .unavailable,
                message: "the transport core for this connection was deinitialized"))
        pipe.cancel()
    }

    // =======================================================================================
    // MARK: - Inbound: decode and route (L4)
    // =======================================================================================

    /// One blob from the peer. Installed as the pipe's `onReceive` handler, so it always runs on
    /// `pipe.queue`, serially, in send order -- which is the entire licence for the per-stream
    /// machines to be lock-free (L4) and for the op model to carry no sequence numbers (§O2).
    ///
    /// A blob that will not decode fails the **connection**, not a stream. This is the one place
    /// the file departs from §O2's "a violation fails that stream", and deliberately: a framing
    /// error is not attributable to any stream (the header that would name one is the thing that
    /// did not parse) and every op after it in the same blob is unrecoverable, so there is nothing
    /// to resynchronise to. Contrast a *grammar* violation, which arrives on a well-formed op with
    /// a known stream id and fails only that stream.
    private func receive(_ blob: GRPCSwiftData) {
        // L4 tripwire. Measured caveat from Task 5: `.onQueue` is target-chain permissive, so this
        // catches "delivered from an unrelated queue" but would not catch "delivered from a child
        // queue targeting this one". It is cheap and it did catch a real inlined-delivery
        // regression, so it stays -- as a tripwire, not as proof.
        dispatchPrecondition(condition: .onQueue(pipe.queue))

        let ops: [RPCOp]
        do {
            ops = try codec.decode(blob)
        } catch {
            failConnection(
                RPCError(
                    code: .internalError,
                    message: "the peer sent an undecodable blob; the op framing cannot be "
                        + "resynchronised, so the connection is failed",
                    cause: error))
            return
        }

        for op in ops { route(op) }
    }

    /// Dispatches one op. **Kind first, always.**
    ///
    /// `credit` and `goAway` are connection-level (§O4/§O5) and are matched here, *before* any
    /// stream lookup, because the peer controls the `streamID` field on both: routing "find the
    /// stream, then hand it the op" would deliver a `credit` to a stream machine, and the machines
    /// carry a `preconditionFailure` for exactly that case -- turning a peer-chosen id into a
    /// remote crash.
    ///
    /// `cancel` is matched here too, for a different reason. Both decoders *do* handle `cancel`
    /// (they throw `RPCError(code: .cancelled)`), but the core's response to a machine's throw is
    /// to send a `cancel` op back -- and echoing a `cancel` at the peer that just sent one is both
    /// pointless and a way for two peers to volley. Handling it by kind keeps "fail the stream,
    /// remove it, send nothing" (contract line 6) explicit instead of resting on an error-code
    /// comparison.
    private func route(_ op: RPCOp) {
        switch op {
        case .credit(let streamID, let bytes):
            applyCredit(streamID: streamID, bytes: bytes)

        case .goAway:
            peerBeganDraining()

        case .cancel(let streamID, let reason):
            // Contract line 6. No `cancel` is sent back -- see above.
            removeStream(
                streamID,
                failingInboundWith: RPCError(
                    code: .cancelled, message: "the peer cancelled stream \(streamID): \(reason)"),
                sendingCancel: nil)

        case .openStream(let streamID, let method, let timeout):
            openInbound(streamID: streamID, method: method, timeout: timeout)

        case .metadata(let streamID, _), .message(let streamID, _), .halfClose(let streamID),
            .status(let streamID, _, _, _):
            deliver(op, toStream: streamID)
        }
    }

    /// Feeds one stream-scoped op to its machine and delivers whatever parts come out.
    ///
    /// Contract line 1's two halves both live here: the machine's throw is **not** `try?`-
    /// swallowed -- it fails that stream and sends `cancel` -- and it never touches the
    /// connection or any other stream.
    ///
    /// L4 is what lets this be correct without holding the registry lock across the yields: the
    /// lock is released before any part reaches the continuation, but *routing itself* is serial,
    /// so no second op for this stream can interleave between the decode and the yield.
    private func deliver(_ op: RPCOp, toStream id: RPCStreamID) {
        // §O4: the charge is `FlowControl.charge(for:window:)`, on both sides, never a
        // hand-inlined clamp. Recorded before the machine sees the op: bytes the peer sent are
        // owed back to its connection window whether or not the op turns out to be legal.
        let charge: Int
        if case .message(_, let payload) = op {
            charge = FlowControl.charge(for: payload.count)
        } else {
            charge = 0
        }

        enum Delivered {
            case unknownStream
            case request(
                [RPCRequestPart<GRPCSwiftData>],
                AsyncThrowingStream<RPCRequestPart<GRPCSwiftData>, any Error>.Continuation,
                remoteEnded: Bool)
            case response(
                [RPCResponsePart<GRPCSwiftData>],
                AsyncThrowingStream<RPCResponsePart<GRPCSwiftData>, any Error>.Continuation,
                remoteEnded: Bool)
            case violation(any Error)
        }

        let outcome: Delivered = registry.withLock { registry in
            guard var entry = registry.streams[id] else { return .unknownStream }
            entry.unconsumedCharge += charge
            // Written back on every exit, including the violation one: `removeStream` reads
            // `unconsumedCharge` to flush it, and this op's bytes belong in that flush.
            defer { registry.streams[id] = entry }

            switch entry.inbound {
            case .request(var decoder, let continuation):
                do {
                    let parts = try decoder.accept(op)
                    let ended = decoder.remoteEnded
                    entry.inbound = .request(decoder, continuation)
                    entry.remoteDone = ended
                    return .request(parts, continuation, remoteEnded: ended)
                } catch {
                    entry.inbound = .request(decoder, continuation)
                    return .violation(error)
                }

            case .response(var decoder, let continuation):
                do {
                    let parts = try decoder.accept(op)
                    // `ResponseOpDecoder` has no `remoteEnded`: `status` *is* the terminator, so
                    // the terminal signal is the part itself.
                    let ended = parts.contains { if case .status = $0 { true } else { false } }
                    entry.inbound = .response(decoder, continuation)
                    entry.remoteDone = ended
                    return .response(parts, continuation, remoteEnded: ended)
                } catch {
                    entry.inbound = .response(decoder, continuation)
                    return .violation(error)
                }
            }
        }

        switch outcome {
        case .unknownStream:
            // Dropped, not answered -- see the file overview. The charge still goes back, or a
            // peer could drain our advertised connection window by writing to ids we retired.
            creditConnection(charge)

        case .request(let parts, let continuation, let ended):
            for part in parts { continuation.yield(part) }
            if ended {
                continuation.finish()
                retireIfComplete(id)
            }

        case .response(let parts, let continuation, let ended):
            for part in parts { continuation.yield(part) }
            if ended {
                continuation.finish()
                retireIfComplete(id)
            }

        case .violation(let error):
            // Contract line 1. §O2: fails this stream only.
            removeStream(id, failingInboundWith: error, sendingCancel: "\(error)")
        }
    }

    // =======================================================================================
    // MARK: - Inbound: accept (contract line 2, L5)
    // =======================================================================================

    /// An `openStream` op arrived.
    ///
    /// L5 in one function: the decoder, both windows, the inbound sequence, the outbound writer
    /// and the whole `RPCStream` are built, the table entry is inserted, the deadline timer is
    /// armed, and only then is a **fully built** ``AcceptedRPCStream`` yielded -- all in this one
    /// routing turn, on `pipe.queue`. There is no pending table, and no window in which an op for
    /// this stream could arrive with nothing to route it to (the next op cannot be routed until
    /// this call returns; L4).
    private func openInbound(streamID id: RPCStreamID, method: String, timeout: Duration?) {
        // A second `openStream` for a live id is a §O2 grammar violation, and the stream's own
        // machine is what should say so -- route it and let its "this stream already opened"
        // failure fail exactly one stream.
        let alreadyOpen = registry.withLock { $0.streams[id] != nil }
        if alreadyOpen {
            deliver(.openStream(id, method: method, timeout: timeout), toStream: id)
            return
        }

        guard role == .server else {
            // A client is never asked to accept. Nothing legitimate is waiting on the peer's side
            // for a `status`, so `cancel` is the right shape.
            refuseWithCancel(id, "a client transport does not accept streams")
            return
        }
        // §O4 reserves id 0 for the connection window, and §O1 makes stream ids odd and
        // client-allocated. Refuse anything else before it can confuse the id space.
        guard id != 0, id.isMultiple(of: 2) == false else {
            refuseWithCancel(
                id, "stream id \(id) is not a legal client-allocated id (must be odd and non-zero)")
            return
        }
        guard let descriptor = Self.methodDescriptor(from: method) else {
            refuseWithStatus(id, .unimplemented, "malformed method path '\(method)'")
            return
        }

        let (inbound, continuation) = AsyncThrowingStream.makeStream(
            of: RPCRequestPart<GRPCSwiftData>.self)
        let entry = StreamEntry(
            id: id,
            inbound: .request(
                RequestOpDecoder(method: method, timeout: timeout), continuation),
            sendWindow: FlowControlWindow(),
            receive: WindowAccountant())

        enum Admission {
            case admitted
            case draining
            case closed
            case tooMany(Int)
        }

        let admission: Admission = registry.withLock { registry in
            switch registry.phase {
            case .draining: return .draining
            case .closed: return .closed
            case .running: break
            }
            guard registry.streams.count < Self.maxConcurrentInboundStreams else {
                return .tooMany(registry.streams.count)
            }
            registry.streams[id] = entry
            registry.highestStreamID = max(registry.highestStreamID, id)
            return .admitted
        }

        switch admission {
        case .draining:
            refuseWithStatus(
                id, .unavailable, "the server is draining and is not accepting new streams")
            return
        case .closed:
            // The connection is gone; there is nobody to tell.
            return
        case .tooMany(let live):
            refuseWithStatus(
                id, .resourceExhausted,
                "too many concurrent streams on this connection (\(live) live, limit "
                    + "\(Self.maxConcurrentInboundStreams))")
            return
        case .admitted:
            break
        }

        // L6: both callbacks below hold the core weakly. The value built here sits in
        // `acceptedStreams`' buffer *inside* this object until a server transport drains it, so a
        // strong edge back would make the core immortal and leak the XPC session.
        let credited = CreditingInbound(base: inbound) { [weak self] part in
            guard case .message(let payload) = part else { return }
            self?.messageConsumed(streamID: id, charge: FlowControl.charge(for: payload.count))
        }
        let writer = OutboundOpWriter(core: self, encoder: ResponseOpEncoder(streamID: id))
        let stream = ServerRPCStream(
            descriptor: descriptor,
            inbound: RPCAsyncSequence(wrapping: credited),
            outbound: RPCWriter.Closable(wrapping: writer))

        // L12. Armed after the entry is in the table so the timer can never fire against a
        // missing stream, and activated last so it cannot fire before it is stored.
        if let timeout { installDeadline(timeout, forStream: id) }

        acceptedContinuation.yield(
            AcceptedRPCStream(id: id, descriptor: descriptor, timeout: timeout, stream: stream))
    }

    /// Splits a wire method path (`"pkg.Service/Method"`, no leading slash -- `CompactWireCodec`
    /// strips it on decode) at the **last** `/`, matching `GRPCWireHeaders`' own path handling.
    /// `MethodDescriptor` has no `init(fullyQualifiedMethod:)`, so the split is unavoidable.
    private static func methodDescriptor(from wireMethod: String) -> MethodDescriptor? {
        guard let slash = wireMethod.lastIndex(of: "/") else { return nil }
        let service = String(wireMethod[..<slash])
        let method = String(wireMethod[wireMethod.index(after: slash)...])
        guard !service.isEmpty, !method.isEmpty else { return nil }
        return MethodDescriptor(fullyQualifiedService: service, method: method)
    }

    /// Refuses an accept with a `status` op: the peer has a client waiting for a response, and a
    /// status is what that client already knows how to fail on. No table entry is created, so no
    /// later op for this id has anywhere to go (they are dropped -- see the file overview).
    private func refuseWithStatus(_ id: RPCStreamID, _ code: Status.Code, _ message: String) {
        sendControl([.status(id, code: code.rawValue, message: message, trailers: [])])
    }

    /// Refuses an accept with a `cancel` op, for the cases where no legitimate RPC exists to
    /// answer with a status (a stream id outside the legal space, or an `openStream` at a client).
    private func refuseWithCancel(_ id: RPCStreamID, _ reason: String) {
        sendControl([.cancel(id, reason: reason)])
    }

    // =======================================================================================
    // MARK: - Outbound: opening a stream (client)
    // =======================================================================================

    /// Allocates a client stream and builds it. Contract line 8's other half: once the connection
    /// is draining -- because we sent `goAway` or because the peer did -- this throws
    /// `RPCError(code: .unavailable)`.
    ///
    /// The `openStream` op is **not** sent here. `RequestOpEncoder` prepends it to whatever the
    /// first `write`/`finish` produces (Task 4's design), so the peer learns of the stream with the
    /// first part -- and a stream that is opened and immediately abandoned costs the peer nothing.
    ///
    /// - Returns: the allocated id (needed for ``cancelStream(_:reason:)`` on the way out) and the
    ///   stream.
    /// - Throws: `RPCError(code: .unavailable)` if the connection is draining or closed;
    ///   `RPCError(code: .resourceExhausted)` if the odd-id space is exhausted.
    func openStream(descriptor: MethodDescriptor, timeout: Duration?) throws -> (
        id: RPCStreamID, stream: ClientRPCStream
    ) {
        precondition(
            role == .client,
            "RPCTransportCore.openStream: only a client-role core allocates streams; a server "
                + "accepts them through `acceptedStreams`")

        let (inbound, continuation) = AsyncThrowingStream.makeStream(
            of: RPCResponsePart<GRPCSwiftData>.self)

        // L7: the phase check and the id allocation are one atomic take-and-transition, so a
        // `beginDraining()` racing this call either loses (the stream is allocated) or wins (this
        // throws) -- never both.
        let id: RPCStreamID = try registry.withLock { registry in
            switch registry.phase {
            case .draining:
                throw RPCError(
                    code: .unavailable,
                    message: "the connection is draining; no new streams may be opened")
            case .closed:
                throw RPCError(
                    code: .unavailable, message: "the connection is no longer available")
            case .running:
                break
            }
            guard registry.nextClientStreamID != 0 else {
                throw RPCError(
                    code: .resourceExhausted,
                    message: "this connection's client stream-id space is exhausted; open a new "
                        + "connection")
            }
            let id = registry.nextClientStreamID
            // Odd and ascending, never reused. `0` marks exhaustion rather than wrapping, which
            // would collide with a live stream.
            registry.nextClientStreamID = id > RPCStreamID.max - 2 ? 0 : id + 2
            registry.streams[id] = StreamEntry(
                id: id,
                inbound: .response(ResponseOpDecoder(), continuation),
                sendWindow: FlowControlWindow(),
                receive: WindowAccountant())
            registry.highestStreamID = max(registry.highestStreamID, id)
            return id
        }

        // L6: weak, for the same reason as on the accept side.
        let credited = CreditingInbound(base: inbound) { [weak self] part in
            guard case .message(let payload) = part else { return }
            self?.messageConsumed(streamID: id, charge: FlowControl.charge(for: payload.count))
        }
        let writer = OutboundOpWriter(
            core: self,
            encoder: RequestOpEncoder(
                streamID: id, method: descriptor.fullyQualifiedMethod, timeout: timeout))
        let stream = ClientRPCStream(
            descriptor: descriptor,
            inbound: RPCAsyncSequence(wrapping: credited),
            outbound: RPCWriter.Closable(wrapping: writer))

        if let timeout { installDeadline(timeout, forStream: id) }

        return (id, stream)
    }

    // =======================================================================================
    // MARK: - Outbound: flow control (contract line 4, §O4)
    // =======================================================================================

    /// §O4's reservation order: **the stream window, then the connection window, always**. That
    /// order is what keeps two streams from deadlocking each other -- two oversize senders queue
    /// on the connection window's FIFO rather than each holding one window and waiting for the
    /// other.
    ///
    /// Only `message` bodies come through here. Control ops (`metadata`, `halfClose`, `status`,
    /// `cancel`, `credit`, `goAway`) bypass flow control entirely, which is load-bearing: a
    /// terminal op that had to wait for credit would let a peer that stopped reading make a stream
    /// unclosable.
    ///
    /// - Returns: the stream window the charge was taken from, so the caller can give it back
    ///   without a second table lookup (the stream may be removed in between, and the bytes still
    ///   have to go somewhere).
    /// - Throws: whatever the windows throw -- the connection's `.unavailable` on teardown, or
    ///   `CancellationError`. **If the connection reserve fails after the stream reserve
    ///   succeeded, the stream reservation is stranded and goes back through `release(_:)`**, not
    ///   `fail(_:)`: failing the *connection* window over one stream's send would kill every other
    ///   stream on it, and `grant(_:)` would validate these bytes against §O4's peer-facing
    ///   ceiling they were never subject to.
    fileprivate func reserveOutboundWindow(_ charge: Int, forStream id: RPCStreamID) async throws
        -> FlowControlWindow
    {
        guard let streamWindow = registry.withLock({ $0.streams[id]?.sendWindow }) else {
            throw RPCError(
                code: .unavailable,
                message: "stream \(id) is no longer open on this connection")
        }
        try await Self.reserveFully(charge, from: streamWindow)
        do {
            try await Self.reserveFully(charge, from: connectionSendWindow)
        } catch {
            streamWindow.release(charge)
            throw error
        }
        return streamWindow
    }

    /// Gives a reservation back to both windows. Called when the encode or the send after a
    /// successful reservation fails: nothing reached the wire, so the peer will never credit these
    /// bytes and they would otherwise be gone from both windows for good.
    fileprivate func releaseOutboundWindow(_ charge: Int, stream streamWindow: FlowControlWindow) {
        streamWindow.release(charge)
        connectionSendWindow.release(charge)
    }

    /// `FlowControlWindow.reserve(upTo:)` is deliberately partial, so a charge is assembled in a
    /// loop. A throw or a cancellation part-way through strands whatever was already taken, and
    /// that goes back with `release(_:)` -- including on the `CancellationError` path, because
    /// `reserve` hands bytes even to a task cancelled an instant earlier (that is L1 working, not
    /// a bug to work around).
    private static func reserveFully(_ charge: Int, from window: FlowControlWindow) async throws {
        var acquired = 0
        do {
            while acquired < charge {
                acquired += try await window.reserve(upTo: charge - acquired)
            }
        } catch {
            if acquired > 0 { window.release(acquired) }
            throw error
        }
    }

    /// Encodes and sends ops the caller has already accounted for. The one outbound path; every
    /// op this file emits goes through here or through ``sendControl(_:)``.
    ///
    /// - Throws: the codec's error, or the substrate's `RPCError(code: .unavailable)`.
    fileprivate func sendEncoded(_ ops: [RPCOp]) throws {
        guard !ops.isEmpty else { return }
        try pipe.send(codec.encode(ops))
    }

    /// Sends control ops that have no caller to report a failure to -- credit, `goAway`, teardown
    /// `cancel`s, accept refusals.
    ///
    /// The failure is dropped **here and only here**, so that no call site needs a `try?`: if the
    /// substrate is gone there is no peer to inform, and if the codec refuses one of these
    /// fixed-shape ops the connection is already being torn down by whatever produced it. Nothing
    /// on a stream's grammar path uses this -- a `write` reports its own failures.
    private func sendControl(_ ops: [RPCOp]) {
        do {
            try sendEncoded(ops)
        } catch {
            // Intentionally terminal. See above.
        }
    }

    // =======================================================================================
    // MARK: - Flow control: inbound credit (contract lines 3 and 5, §O4)
    // =======================================================================================

    /// Contract line 3. Routed by kind before any stream lookup (see ``route(_:)``): `streamID ==
    /// 0` means the connection window, anything else a stream's.
    ///
    /// A credit for an unknown or already-removed stream is dropped -- that is the ordinary race
    /// where the peer credited a stream we just retired, and there is no window left to grow.
    ///
    /// An **overflowing** credit is a §O4 protocol error and, per the contract, fails the
    /// connection: it is a statement that the peer's accounting has diverged from ours, which no
    /// per-stream failure can repair. `grant(_:)` validates in `Int64` and leaves the window
    /// untouched when it throws, and it is O(1) arithmetic, never a loop over the peer's count
    /// (L2).
    private func applyCredit(streamID id: RPCStreamID, bytes: UInt32) {
        let window: FlowControlWindow?
        if id == 0 {
            window = connectionSendWindow
        } else {
            window = registry.withLock { $0.streams[id]?.sendWindow }
        }
        guard let window else { return }
        do {
            try window.grant(bytes)
        } catch {
            failConnection(
                RPCError(
                    code: .internalError,
                    message: "the peer sent a credit that would overflow the "
                        + (id == 0 ? "connection" : "stream \(id)") + " flow-control window",
                    cause: error))
        }
    }

    /// Contract line 5. Called by ``CreditingInbound`` when the application's iterator actually
    /// pulls a message -- §O4's "replenish **on consumption**", not on arrival, which is what
    /// makes the window real backpressure rather than a formality.
    ///
    /// Both accountants are fed the same `charge`, and both batch at half the initial window, so
    /// most consumptions emit nothing. The guard on the entry still existing is what keeps
    /// conservation exact: a stream that has been removed already had its outstanding charge
    /// flushed into the connection accountant by ``removeStream(_:failingInboundWith:sendingCancel:)``,
    /// and crediting it again here would invent connection window the peer never authorised.
    private func messageConsumed(streamID id: RPCStreamID, charge: Int) {
        guard charge > 0 else { return }
        var streamCredit: UInt32?
        var connectionCredit: UInt32?

        registry.withLock { registry in
            guard var entry = registry.streams[id] else { return }
            entry.unconsumedCharge = max(0, entry.unconsumedCharge - charge)
            streamCredit = entry.receive.consumed(charge)
            registry.streams[id] = entry
            connectionCredit = registry.connectionReceive.consumed(charge)
        }

        var ops: [RPCOp] = []
        if let streamCredit { ops.append(.credit(id, bytes: streamCredit)) }
        if let connectionCredit { ops.append(.credit(0, bytes: connectionCredit)) }
        sendControl(ops)
    }

    /// Credits the connection window for bytes that never reached an application -- an op for an
    /// unknown stream. Nothing else can return them, and leaving them uncredited shrinks the
    /// connection window permanently.
    private func creditConnection(_ charge: Int) {
        guard charge > 0 else { return }
        let credit = registry.withLock { $0.connectionReceive.consumed(charge) }
        if let credit { sendControl([.credit(0, bytes: credit)]) }
    }

    // =======================================================================================
    // MARK: - Stream teardown (contract lines 6 and 7, L3)
    // =======================================================================================

    /// The single removal path. Contract line 7: **no entry outlives its stream**, and every way a
    /// stream can end routes through here --
    ///
    /// | how the stream ended | `failingInboundWith` | `sendingCancel` |
    /// |---|---|---|
    /// | both directions done (``retireIfComplete(_:)``, ``localDirectionDidClose(_:)``) | `nil` | `nil` |
    /// | a §O2 grammar violation (``deliver(_:toStream:)``) | the machine's error | its description |
    /// | the peer's `cancel` (``route(_:)``, line 6) | `.cancelled` | `nil` -- never echo |
    /// | a local cancel / deadline (``cancelStream(_:reason:)``) | `.cancelled` / `.deadlineExceeded` | the reason |
    /// | a server handler returning (``streamHandlerFinished(_:)``, L3) | `.cancelled` | only if it did not send `status` |
    /// | peer death, `deinit`, forceful teardown | handled by ``failAll(_:)``, which sweeps the whole table |
    ///
    /// Four things are released, and all four have cost a bug before:
    ///
    /// 1. **The deadline timer is cancelled** (L12) -- one per RPC, and this is the only place it
    ///    dies short of ``failAll(_:)``.
    /// 2. **The stream's send window is failed**, not released: a removed stream's window is
    ///    genuinely dead, and `fail` is what wakes a writer parked on credit that will never
    ///    arrive. The **connection** window is deliberately untouched -- failing it because one
    ///    stream ended would kill every other stream on it.
    /// 3. **The inbound sequence is ended**, with the error on abnormal paths so a consumer sees
    ///    why rather than a silent end-of-stream.
    /// 4. **Un-consumed receive charge is flushed into the connection accountant.** This is L3
    ///    exactly: a handler that returns without draining its request half otherwise strands
    ///    those bytes of the peer's connection window forever, and the peer's writer parks on
    ///    credit that is never coming (the old build measured 33 of 200 sent, then a permanent
    ///    hang). The stream half is not credited -- the stream is gone, and an abnormal removal
    ///    also sends `cancel`, so the peer drops its own stream window.
    ///
    /// The cancellation observer fires only on abnormal removal: firing it on a clean completion
    /// would tell a server handler it had been cancelled after it had already succeeded.
    ///
    /// Idempotent: the entry is taken out of the table under the lock, so exactly one caller ever
    /// performs the teardown. Everything that can block or call out -- window failures,
    /// continuations, `pipe.send` -- happens after the lock is released (L7).
    @discardableResult
    private func removeStream(
        _ id: RPCStreamID,
        failingInboundWith error: (any Error)?,
        sendingCancel reason: String?
    ) -> Bool {
        var taken: StreamEntry?
        var connectionCredit: UInt32?

        registry.withLock { registry in
            guard let entry = registry.streams.removeValue(forKey: id) else { return }
            taken = entry
            if entry.unconsumedCharge > 0 {
                connectionCredit = registry.connectionReceive.consumed(entry.unconsumedCharge)
            }
        }
        guard let entry = taken else { return false }

        entry.deadlineTimer?.cancel()
        entry.sendWindow.fail(
            error
                ?? RPCError(
                    code: .unavailable,
                    message: "stream \(id) has completed; no further messages may be written"))
        entry.finishInbound(throwing: error)
        if error != nil { entry.cancellationObserver?() }

        var ops: [RPCOp] = []
        if let reason { ops.append(.cancel(id, reason: reason)) }
        if let connectionCredit { ops.append(.credit(0, bytes: connectionCredit)) }
        sendControl(ops)

        return true
    }

    /// Retires the stream if both directions have finished. Called after a legitimate inbound
    /// terminator; the outbound counterpart is ``localDirectionDidClose(_:)``.
    private func retireIfComplete(_ id: RPCStreamID) {
        let complete = registry.withLock { registry -> Bool in
            guard let entry = registry.streams[id] else { return false }
            return entry.localDone && entry.remoteDone
        }
        if complete { removeStream(id, failingInboundWith: nil, sendingCancel: nil) }
    }

    /// The outbound direction finished cleanly: `halfClose` sent (client) or `status` sent
    /// (server). Called by ``OutboundOpWriter`` after the op is on the wire, never before -- a
    /// stream marked locally done whose terminator did not actually go out would be retired while
    /// the peer still waited.
    fileprivate func localDirectionDidClose(_ id: RPCStreamID) {
        let complete = registry.withLock { registry -> Bool in
            guard var entry = registry.streams[id] else { return false }
            entry.localDone = true
            registry.streams[id] = entry
            return entry.remoteDone
        }
        if complete { removeStream(id, failingInboundWith: nil, sendingCancel: nil) }
    }

    /// Aborts one stream from this side: the client's `withStream` closure exiting without a clean
    /// termination, a fired deadline, or `RPCWriter.finish(throwing:)`.
    func cancelStream(_ id: RPCStreamID, reason: String) {
        removeStream(
            id,
            failingInboundWith: RPCError(
                code: .cancelled, message: "stream \(id) was cancelled locally: \(reason)"),
            sendingCancel: reason)
    }

    /// **L3.** A server's `streamHandler` returned: remove the stream, release its windows, and
    /// send `cancel` if it did not terminate cleanly (i.e. never wrote a `status`).
    ///
    /// This must be called for every accepted stream, on every exit path of the handler. It is not
    /// optional bookkeeping: the old build left the entry behind, and an early-returning handler
    /// -- one that read a message and stopped -- stranded the peer's writer forever.
    func streamHandlerFinished(_ id: RPCStreamID) {
        let sentStatus = registry.withLock { $0.streams[id]?.localDone }
        guard let sentStatus else { return }  // already retired by a terminator or a teardown

        if sentStatus {
            removeStream(id, failingInboundWith: nil, sendingCancel: nil)
        } else {
            removeStream(
                id,
                failingInboundWith: RPCError(
                    code: .cancelled,
                    message: "the server handler for stream \(id) returned without sending a "
                        + "status"),
                sendingCancel: "the server handler returned without completing the RPC")
        }
    }

    // =======================================================================================
    // MARK: - Deadlines (L12)
    // =======================================================================================

    /// Arms this stream's single deadline timer. L12: one per deadline-bearing RPC, owned by the
    /// table entry, cancelled by every removal path.
    ///
    /// Order matters twice. The entry is already in the table when this runs, so the handler can
    /// never fire against a missing stream *because it was armed too early*; and `activate()` is
    /// called only after the source is stored, so it cannot fire before the entry owns it (which
    /// would leak an un-cancelled source).
    ///
    /// Firing sends `cancel` rather than a `status(deadlineExceeded)` even on the server side:
    /// §O5.3 makes `cancel` the abort op in both directions, and the client's own timer -- exact,
    /// where the wire deadline is rounded *up* by `GRPCWireHeaders` -- normally fires first and is
    /// what surfaces `.deadlineExceeded` to the caller.
    private func installDeadline(_ timeout: Duration, forStream id: RPCStreamID) {
        let timer = DispatchSource.makeTimerSource(queue: pipe.queue)
        timer.schedule(deadline: .now() + Self.dispatchInterval(for: timeout))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.removeStream(
                id,
                failingInboundWith: RPCError(
                    code: .deadlineExceeded,
                    message: "stream \(id) exceeded its deadline of \(timeout)"),
                sendingCancel: "deadline exceeded")
        }

        let stored = registry.withLock { registry -> Bool in
            guard var entry = registry.streams[id] else { return false }
            entry.deadlineTimer = timer
            registry.streams[id] = entry
            return true
        }
        // The stream was retired between insertion and here (a peer `cancel` in the same routing
        // turn, say). Cancel rather than activate, so no source is left running.
        guard stored else {
            timer.cancel()
            return
        }
        timer.activate()
    }

    /// `Duration` -> `DispatchTimeInterval`, saturating rather than trapping. A deadline far past
    /// `Int.max` nanoseconds (~292 years) clamps to "effectively never", which is the right
    /// reading of an absurd deadline; a negative one clamps to zero and fires immediately, which
    /// is the right reading of an already-expired one.
    private static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let (seconds, secondsOverflowed) = components.seconds.multipliedReportingOverflow(
            by: 1_000_000_000)
        guard !secondsOverflowed else {
            return .nanoseconds(components.seconds < 0 ? 0 : Int.max)
        }
        let (total, totalOverflowed) = seconds.addingReportingOverflow(
            components.attoseconds / 1_000_000_000)
        guard !totalOverflowed else { return .nanoseconds(seconds < 0 ? 0 : Int.max) }
        return .nanoseconds(Int(clamping: max(0, total)))
    }

    // =======================================================================================
    // MARK: - Per-stream RPC cancellation signalling
    // =======================================================================================

    /// Registers the observer fired when this stream is torn down abnormally -- a peer `cancel`, a
    /// grammar violation, a deadline, a drain signal, peer death. A server transport binds it to
    /// the `RPCCancellationHandle` it obtained from
    /// `withServerContextRPCCancellationHandle(_:)`, which is how an inbound cancel reaches the
    /// handler at all.
    ///
    /// - Returns: `true` if the stream is *already* gone or the connection is no longer running,
    ///   i.e. the observer will never fire and the caller should cancel immediately. This closes
    ///   the race where a teardown swept the table between the stream being accepted and the
    ///   handler task being scheduled.
    @discardableResult
    func setCancellationObserver(
        forStream id: RPCStreamID, _ observer: @escaping @Sendable () -> Void
    ) -> Bool {
        registry.withLock { registry in
            guard var entry = registry.streams[id] else { return true }
            entry.cancellationObserver = observer
            registry.streams[id] = entry
            switch registry.phase {
            case .running: return false
            case .draining, .closed: return true
            }
        }
    }

    /// Asks every in-flight RPC to wind up, without failing anything. This is a *signal*: a
    /// handler that ignores it runs to completion, and no stream is torn down. It is what a
    /// graceful shutdown uses; ``failAll(_:)`` is the forceful counterpart.
    func signalCancellationToAllStreams() {
        let observers = registry.withLock { registry in
            registry.streams.values.compactMap(\.cancellationObserver)
        }
        for observer in observers { observer() }
    }

    // =======================================================================================
    // MARK: - Connection lifecycle (contract lines 8, 9, 10)
    // =======================================================================================

    /// Begins a graceful drain from this side: sends `goAway`, refuses new streams, and finishes
    /// `acceptedStreams` so a server's accept loop ends. Streams already open are **not**
    /// disturbed -- draining them is the transport's job (it stays inside its task group until the
    /// last handler returns).
    ///
    /// Idempotent, and a no-op once closed.
    func beginDraining() {
        enum Action {
            case none
            case drain(lastStreamID: RPCStreamID, finishAccepted: Bool)
        }

        let action: Action = registry.withLock { registry in
            guard case .running = registry.phase else { return .none }
            registry.phase = .draining
            let finishAccepted = !registry.acceptedFinished
            registry.acceptedFinished = true
            return .drain(
                lastStreamID: registry.highestStreamID, finishAccepted: finishAccepted)
        }

        guard case .drain(let lastStreamID, let finishAccepted) = action else { return }
        sendControl([.goAway(lastStreamID: lastStreamID)])
        if finishAccepted { acceptedContinuation.finish() }
    }

    /// Contract line 8: an inbound `goAway` marks this connection draining, so ``openStream``
    /// throws `.unavailable` from here on.
    ///
    /// It does **not** finish `acceptedStreams`. `goAway` is directional: the peer is saying it
    /// will accept no more streams *from us*, which says nothing about streams it may still open
    /// on us. Nor does it disturb streams already open -- `lastStreamID` is advisory here because
    /// this transport's ids are allocated by one side only and the peer's own `status`/`cancel`
    /// ops are what actually end its streams.
    private func peerBeganDraining() {
        registry.withLock { registry in
            if case .running = registry.phase { registry.phase = .draining }
        }
    }

    /// Contract line 9 and line 10's `deinit` half: fails every stream, wakes every parked window
    /// waiter, and ends the accept sequence. Terminal and idempotent.
    ///
    /// **The connection window is failed too, and that is the part that matters.** A sender parked
    /// on the *connection* window is not reachable through any stream's window, so failing only
    /// the per-stream windows would leave it suspended forever waiting for credit that can no
    /// longer arrive. Together the two cover every waiter (`fail` resolves parked and
    /// about-to-park waiters alike -- see `FlowControlWindow.fail(_:)`).
    ///
    /// No `cancel` ops are sent and no credit is flushed: the peer is gone, or is about to be.
    func failAll(_ error: any Error) {
        var taken: [StreamEntry] = []
        var finishAccepted = false

        registry.withLock { registry in
            registry.phase = .closed
            taken = Array(registry.streams.values)
            registry.streams.removeAll()
            finishAccepted = !registry.acceptedFinished
            registry.acceptedFinished = true
        }

        // Outside the lock (L7): every one of these can resume a continuation.
        connectionSendWindow.fail(error)
        for entry in taken {
            entry.deadlineTimer?.cancel()  // L12
            entry.sendWindow.fail(error)
            entry.finishInbound(throwing: error)
            entry.cancellationObserver?()
        }
        if finishAccepted { acceptedContinuation.finish() }
    }

    /// Tears the connection down from this side and releases the substrate. `pipe.cancel()` is
    /// idempotent, so calling this and then dropping the core is fine.
    func close() {
        failAll(RPCError(code: .unavailable, message: "the connection was closed locally"))
        pipe.cancel()
    }

    /// A connection-level protocol error: an undecodable blob, or an overflowing credit (contract
    /// line 3). Both are statements that the peer's framing or accounting has diverged from ours,
    /// which no per-stream failure can repair -- so unlike a §O2 grammar violation, this really
    /// does take the connection with it.
    private func failConnection(_ error: any Error) {
        failAll(error)
        pipe.cancel()
    }

    /// Contract line 9. Installed as the pipe's `onPeerDeath` handler, weakly (L6).
    private func peerDied() {
        failAll(
            RPCError(
                code: .unavailable,
                message: "the peer process is no longer available"))
    }
}

// ===========================================================================================
// MARK: - The outbound writer (contract lines 4 and 10)
// ===========================================================================================

/// A weak, `Sendable` box around the core a writer or an inbound callback reaches back through.
///
/// A `Mutex`-wrapped struct rather than a bare `weak var` stored property because
/// `ClosableRPCWriterProtocol: RPCWriterProtocol: Sendable`, and a `Sendable` class may not have
/// mutable stored properties -- which a `weak var` necessarily is.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private struct WeakCore: Sendable {
    weak var core: RPCTransportCore?
}

/// The three things the two outbound state machines have in common, so ``OutboundOpWriter`` can be
/// written once instead of twice.
///
/// `encode(_:)` / `finish()` are `RequestOpEncoder`'s and `ResponseOpEncoder`'s own methods
/// (`ResponseOpEncoder` gains a `finish()` in the extension below -- the response direction's
/// terminator is the `status` part itself, so there is no op to emit). The two static hooks are
/// what the generic writer cannot ask the part type directly:
///
/// - `messagePayload(of:)` -- flow control applies to `message` bodies only (§O4), and this is how
///   the writer decides whether to reserve. It must be answerable **before** the part is encoded,
///   because a reservation has to be taken before the op exists.
/// - `closesLocalDirection(_:)` / `finishClosesLocalDirection` -- which event ends the outbound
///   direction, and therefore when the stream may be retired. Asymmetric on purpose: the client's
///   terminator is `finish()` (which emits `halfClose`), the server's is writing `.status`. A
///   server's `finish()` must **not** count, or a handler that returned without a status would
///   look like a clean completion and no `cancel` would be sent (L3).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
protocol OutboundOpEncoding: Sendable {
    associatedtype Part: Sendable

    /// The stream these ops belong to. Both conformers already store it; the requirement exists so
    /// the generic writer can read it without knowing which conformer it has.
    var streamID: RPCStreamID { get }

    static var finishClosesLocalDirection: Bool { get }
    static func messagePayload(of part: Part) -> GRPCSwiftData?
    static func closesLocalDirection(_ part: Part) -> Bool

    mutating func encode(_ part: Part) throws -> [RPCOp]
    mutating func finish() throws -> [RPCOp]
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension RequestOpEncoder: OutboundOpEncoding {
    typealias Part = RPCRequestPart<GRPCSwiftData>

    static var finishClosesLocalDirection: Bool { true }

    static func messagePayload(of part: Part) -> GRPCSwiftData? {
        if case .message(let payload) = part { return payload }
        return nil
    }

    static func closesLocalDirection(_ part: Part) -> Bool { false }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension ResponseOpEncoder: OutboundOpEncoding {
    typealias Part = RPCResponsePart<GRPCSwiftData>

    static var finishClosesLocalDirection: Bool { false }

    static func messagePayload(of part: Part) -> GRPCSwiftData? {
        if case .message(let payload) = part { return payload }
        return nil
    }

    static func closesLocalDirection(_ part: Part) -> Bool {
        if case .status = part { return true }
        return false
    }

    /// The response direction has no `halfClose`: `status` is its single terminator and it has
    /// already been written as a part. So there is nothing to emit here, and
    /// ``finishClosesLocalDirection`` is `false` -- see the protocol's doc comment for why that
    /// asymmetry is load-bearing.
    mutating func finish() throws -> [RPCOp] { [] }
}

/// Bridges grpc-swift's outbound `RPCWriter` to the mux: §O4's flow control on `message` parts,
/// the direction's state machine for everything else.
///
/// # Ownership (L6, contract line 10)
///
/// Holds the core **weakly**. That is not a micro-optimisation: an accepted stream sits in
/// `RPCTransportCore.acceptedStreams`' buffer *inside* the core until a server transport drains
/// it, so a strong reference here would close `core -> continuation buffer -> AcceptedRPCStream ->
/// RPCStream.outbound -> writer -> core` and make the core immortal -- `deinit` never runs, the
/// pipe is never cancelled, and the XPC session leaks for the process's lifetime. A write after
/// the core is gone throws `RPCError(code: .unavailable)`; it never traps and never reports a send
/// that did not happen.
///
/// # Why the encoder and the send share one lock
///
/// `encode` assigns each op its place in §O2's grammar (it is what prepends `openStream` to the
/// first part), so encode order **is** wire order. Encoding under a lock and sending outside it
/// would let two concurrent writes swap on the way to the pipe and put a `message` ahead of the
/// `metadata` that must precede it. `pipe.send` is synchronous and does not block on the peer, so
/// holding the lock across it costs a short critical section and buys the ordering outright.
/// Credit, which *does* suspend, is acquired before the lock is taken.
///
/// # Why there is an `isDead` flag
///
/// `RequestOpEncoder`/`ResponseOpEncoder` **trap** (`precondition`) if called again after one of
/// their calls threw -- their "once thrown, this instance is dead" contract. grpc-swift does call
/// `finish()` on a writer whose `write` has already failed, so without this flag an ordinary
/// grammar error would become a process trap. Once dead, `write` throws without touching the
/// encoder and `finish()` is a no-op.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class OutboundOpWriter<Encoder: OutboundOpEncoding>: ClosableRPCWriterProtocol {
    typealias Element = Encoder.Part

    private let streamID: RPCStreamID
    private let weakCore: Mutex<WeakCore>

    private struct EncoderState {
        var encoder: Encoder
        var isDead = false
    }
    private let state: Mutex<EncoderState>

    fileprivate init(core: RPCTransportCore, encoder: Encoder) {
        self.streamID = encoder.streamID
        self.weakCore = Mutex(WeakCore(core: core))
        self.state = Mutex(EncoderState(encoder: encoder))
    }

    /// The core, or `nil` once it has been deinitialized. Deliberately returns the strong
    /// reference *out* of the lock, so no send ever runs under it.
    private var core: RPCTransportCore? { weakCore.withLock { $0.core } }

    private func coreGone() -> RPCError {
        RPCError(
            code: .unavailable,
            message: "stream \(streamID): the transport for this connection is no longer available")
    }

    private func streamDead() -> RPCError {
        RPCError(
            code: .internalError,
            message: "stream \(streamID): the outbound direction already failed; no further parts "
                + "may be written")
    }

    func write(_ element: Element) async throws {
        guard let core else { throw coreGone() }

        // §O4: only `message` bodies consume window, and the charge is
        // `FlowControl.charge(for:window:)` -- the same call the receive side makes, never a
        // hand-inlined clamp. A zero-length message (`google.protobuf.Empty`) is charged nothing
        // and must not reach `reserve(upTo:)`, which traps on 0.
        let charge = Encoder.messagePayload(of: element).map { FlowControl.charge(for: $0.count) } ?? 0
        var reserved: FlowControlWindow?
        if charge > 0 {
            reserved = try await core.reserveOutboundWindow(charge, forStream: streamID)
        }

        do {
            try state.withLock { state in
                guard !state.isDead else { throw streamDead() }
                do {
                    try core.sendEncoded(state.encoder.encode(element))
                } catch {
                    // Either the grammar was violated or the op never reached the wire; the
                    // encoder's position has moved either way, so this instance is finished.
                    state.isDead = true
                    throw error
                }
            }
        } catch {
            // Nothing was sent, so the peer will never credit these bytes back. §O4: they are
            // handed back with `release(_:)`, never `fail(_:)`.
            if let reserved { core.releaseOutboundWindow(charge, stream: reserved) }
            throw error
        }

        if Encoder.closesLocalDirection(element) { core.localDirectionDidClose(streamID) }
    }

    func write(contentsOf elements: some Sequence<Element>) async throws {
        for element in elements { try await write(element) }
    }

    /// Ends the outbound direction. For a request that is `halfClose` (plus the deferred
    /// `openStream`, if this stream never wrote anything at all); for a response it emits nothing,
    /// because `status` was already the terminator.
    ///
    /// Non-throwing by protocol, so a gone core and a dead encoder are both silent: there is no
    /// peer left to half-close to and no caller to report to. ``write(_:)`` is where a lost
    /// connection surfaces.
    func finish() async {
        guard let core else { return }

        let ops: [RPCOp]? = state.withLock { state in
            guard !state.isDead else { return nil }
            do {
                return try state.encoder.finish()
            } catch {
                state.isDead = true
                return nil
            }
        }
        guard let ops else { return }

        // Control ops: no flow control (§O4), so a starved stream can still be closed.
        do {
            try core.sendEncoded(ops)
        } catch {
            state.withLock { $0.isDead = true }
            return
        }

        if Encoder.finishClosesLocalDirection { core.localDirectionDidClose(streamID) }
    }

    /// Aborts the stream. Never touches the encoder (it may already be dead, and there is no
    /// `RPCOp` for "the local side failed" other than `cancel`), so this is always safe to call.
    func finish(throwing error: any Error) async {
        state.withLock { $0.isDead = true }
        core?.cancelStream(streamID, reason: "\(error)")
    }
}

// ===========================================================================================
// MARK: - Credit on consumption (contract line 5)
// ===========================================================================================

/// The inbound sequence handed to gRPC, wrapping the raw part stream so that §O4's credit is
/// emitted **when the application pulls a message**, not when it arrives.
///
/// That distinction is the whole of the receive-side flow control: crediting on arrival would
/// advertise window for bytes still sitting in a buffer, and the peer could then outrun a slow
/// consumer without bound. Crediting on consumption is what makes the window mean "this much is
/// still safe to send me".
///
/// `onConsume` holds the core weakly (L6) -- the closure the core passes in captures `[weak self]`
/// -- so an undrained inbound sequence can never keep a connection alive.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct CreditingInbound<Part: Sendable>: AsyncSequence, Sendable {
    typealias Element = Part
    typealias Failure = any Error

    private let base: AsyncThrowingStream<Part, any Error>
    private let onConsume: @Sendable (Part) -> Void

    init(
        base: AsyncThrowingStream<Part, any Error>,
        onConsume: @escaping @Sendable (Part) -> Void
    ) {
        self.base = base
        self.onConsume = onConsume
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), onConsume: onConsume)
    }

    struct Iterator: AsyncIteratorProtocol {
        fileprivate var base: AsyncThrowingStream<Part, any Error>.AsyncIterator
        fileprivate let onConsume: @Sendable (Part) -> Void

        /// Credit goes out **after** the element has been handed over, so a consumer that never
        /// comes back for the next one has still had its window returned for the one it took.
        mutating func next(isolation actor: isolated (any Actor)?) async throws(any Error) -> Part? {
            let element = try await base.next(isolation: `actor`)
            if let element { onConsume(element) }
            return element
        }

        mutating func next() async throws -> Part? {
            try await next(isolation: nil)
        }
    }
}
