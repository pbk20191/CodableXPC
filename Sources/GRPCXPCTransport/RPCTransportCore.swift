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
//   - `acceptedStreams`' iterator callback captures it weakly for the same reason.
//   - **the one strong edge that remains is `StreamEntry.cancellationObserver`, and it is a
//     caller's obligation, not this file's.** The closure is supplied by Task 7 and stored in the
//     registry, so `core -> registry -> entry -> observer -> core` is a *self*-cycle that no
//     external weak-reference check can see. It cannot be held weakly (it is a closure, not a
//     reference), so the rule is stated instead and repeated on
//     ``setCancellationObserver(forStream:_:)``: the observer must not capture the core. The
//     intended shape, `{ handle.cancel() }` over a `RPCCancellationHandle` from
//     `withServerContextRPCCancellationHandle`, captures nothing that points back here.
//   - a write after the core is gone throws `RPCError(code: .unavailable)`; it never traps and
//     never reports a send that did not happen.
//
// * **L7 -- explicit lifecycle.** `Phase = .running | .draining | .closed` under the one
//   `registry` mutex, taken-and-transitioned atomically. No continuation is ever resumed under a
//   lock, and nothing that can suspend is held across one: every window `grant`/`release`/`fail`
//   and every `AsyncThrowingStream.Continuation` call happens after `withLock` has returned, and
//   §O4's credit is acquired before any lock is taken.
//
// * **Outbound order.** `pipe.send` *is* held under a lock, and deliberately -- the ``submission``
//   mutex, which is what makes a stream's wire order match the order this file decided things in.
//   It is not the registry lock (see that property for why), it guards no state, and nothing that
//   suspends is held across it. An earlier round asserted the opposite -- "every `pipe.send`
//   happens after `withLock` has returned" -- while a `cancel` could still overtake the deferred
//   `openStream` it belonged to; see ``send(_:forStream:)``.
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
// * **A body-level rejection fails only its stream, not the connection** (§O2, amended after a
//   review found the opposite -- a malformed `:path`, a stray-metadata `openStream`, or a
//   non-empty `halfClose` body each used to kill every other stream on the connection).
//   `CompactWireCodec.decode(_:)` parses each op's 10-byte header, including its stream id, before
//   it ever touches the body, so a body it rejects still yields an item naming that stream. Two
//   different outcomes follow, and which one depends only on the *kind* that failed:
//   - Every kind except `openStream` yields `WireDecodeItem.streamFailure`, and `receive(_:)`
//     fails that stream through ``failStream(_:dueTo:)`` -- the same path a state-machine grammar
//     violation already takes (see ``deliver(_:toStream:)``'s `.violation` case), not a parallel
//     one. If the id has no table entry, this is a silent drop, same as the bullet above and for
//     the same anti-amplification reason -- the core cannot tell a forged id from an ordinary
//     retirement race, and answering either would hand the peer a lever.
//   - `openStream` yields `WireDecodeItem.streamOpenFailure` instead, and `receive(_:)` answers it
//     through ``refuseOpen(_:dueTo:)`` with a **fixed-literal** `status`/`cancel` -- never the
//     decode error's own text. `openStream` is the one kind whose semantics *create* state, so the
//     peer is definitionally entitled to, and waiting on, a reply for that id; silence would just
//     hang it to its own deadline. The reply is a fixed literal specifically because it is
//     reachable at zero state cost (no table entry is ever created here, successfully or not), so
//     echoing even a truncated form of the peer's own bytes would still let the peer's input size
//     drive the reply's size, repeatably -- see `WireDecodeItem.streamOpenFailure`'s doc.
//   Only a **header**-level failure (framing this codec cannot parse at all) and a malformed
//   `goAway` body (connection-scoped by its own nature -- there is no stream to name) still fail
//   the whole connection; see `CompactWireCodec.decode(_:)`'s doc for why `goAway` is the one
//   kind that does not get an item at all.
// * **An accept is refused, never trapped.** A stream id of 0, an even id, a draining connection
//   or too many concurrent streams all produce a `status` or `cancel` op for that id and no table
//   entry -- and so, separately, does a malformed `openStream` **body** (the bullet above,
//   `refuseOpen(_:dueTo:)`), which mirrors `openInbound`'s own role-then-id-legality gate order
//   for exactly the checks it can still make without a successfully-decoded `method`. A malformed
//   method **path**, specifically, is caught earlier still, in the codec, and never reaches
//   `openInbound`'s own `methodDescriptor(from:)` guard: that guard re-validates the same shape
//   `GRPCWireHeaders.parseRequest` (via `validateMethodPath`) already enforced upstream, byte for
//   byte, so nothing that reaches it can still fail it. It is unreachable by construction and
//   stays only as defense in depth, not as the thing that rejects a malformed path today.
// * **The receive window is ENFORCED, not merely accounted for** (§O4, amended). Received-but-
//   uncredited bytes are tracked per stream (`StreamEntry.unconsumedCharge`) and for the
//   connection (`Registry.connectionUnconsumed`), and a peer that pushes past either bound is
//   failed at that bound's blast radius: a stream over its 65 535 fails *that stream* and gets a
//   `cancel`; the connection total over its own fails the *connection*. This is what HTTP/2 spends
//   `FLOW_CONTROL_ERROR` on. Without it the inbound `AsyncThrowingStream` is an unbounded buffer
//   and a peer that simply ignores `credit` retains 16 MiB per op, on every admitted stream, until
//   an application that will never read it does. An accountant with no debit side is not flow
//   control. See ``deliver(_:toStream:)`` for the exactness argument -- the counter mirrors the
//   peer's own send-window arithmetic byte for byte, so it can never fail a conforming peer.
// * **A zero-length `message` is not free.** `FlowControl.charge(for:window:)` floors at 1 byte
//   (§O4, amended), so the enforcement above bounds empty-payload floods too. Without the floor a
//   ten-byte wire op bought unbounded buffering and *survived* the enforcement rule, because a
//   correct enforcement still charges a zero-length payload nothing.
// * **Concurrent inbound streams are capped** at ``maxConcurrentInboundStreams``, counting streams
//   in the table **plus accepts yielded but not yet pulled**. §O4's byte credit bounds bytes per
//   stream but says nothing about stream *count*, and §O5 negotiates nothing, so this is a local
//   resource guard rather than protocol surface: an over-limit `openStream` is answered with
//   `status(resourceExhausted)`, which is an ordinary gRPC failure the peer's client already
//   understands. Counting the undrained accepts is not belt-and-braces: one blob carrying
//   `openStream(id) ; cancel(id)` inserts an entry, yields it, and removes the entry again inside a
//   single routing turn, so a table-only cap never engages while the buffer grows without bound at
//   two ops per item.
// * **Peer bytes are never reflected back unbounded.** A `cancel` op's `reason` is built from an
//   error whose message can embed up to 16 MiB of peer-supplied field data (a `-bin` key with a
//   non-base64 value, say), so every reason this file sends goes through
//   ``truncatedForWire(_:)``.
// * **A grammar violation fails one stream** (§O2): the machine's throw is never `try?`-swallowed,
//   the stream is removed, its inbound sequence is failed with the machine's own error, and a
//   `cancel` op goes out. The connection is untouched.
// * **A blob that will not decode fails the connection.** That is the one deliberate exception,
//   and it is not a §O2 violation: a framing error is not attributable to any stream and leaves
//   the remainder of the blob unparseable, so there is nothing to resynchronise to.
// * **An overflowing `credit` fails the connection**, per the plan's contract line 3 -- that one
//   *is* a peer-triggered teardown, and it is one of only three (the others being a framing error
//   and a connection-level receive-window overrun).
// * **An inbound `goAway` cannot stop this side accepting work.** Draining is two *directional*
//   facts, not one state: `localDraining` (we sent `goAway`) gates inbound accepts and ends the
//   accept loop; `peerDraining` (the peer sent one) gates only our own ``openStream``. Collapsing
//   them into a single `Phase` -- which this file did until Task 6's review -- handed a peer a
//   one-op lever that permanently stopped the connection accepting new streams, and contradicted
//   `goAway`'s own directional meaning.

// ===========================================================================================
// MARK: - The accepted-stream payload
// ===========================================================================================

/// One inbound RPC, fully built, as handed to a server transport's accept loop.
///
/// **Deliberately not named `AcceptedStream`.** The legacy custom-protocol stack this plan
/// replaced owned that name in this module and stayed compiling alongside this file until Task 7
/// deleted it (`XPCConnection.swift`). This is the same collision `RPCStreamID` avoided by the
/// same means, for the same reason: no rename churn at the swap.
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
/// defer { core.clientCallFinished(id) }         // MUST run on every withStream exit path
/// core.cancelStream(id, reason: "…")            // an explicit local abandon (deadline, etc.)
///
/// // server
/// for await accepted in core.acceptedStreams {  // iterate ONCE; pulling releases the accept slot
///     … ; core.streamHandlerFinished(accepted.id)   // MUST run on every handler exit path
/// }
/// let alreadyOver = core.setCancellationObserver(forStream: id) { handle.cancel() }
///                                              // the observer MUST NOT capture the core (L6)
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
/// - **Publish the core before returning an accept `Decision`, and do not touch the pipe until
///   `XPCPipe.onWindowProvedClosed(_:)` has fired.** Dropping the core between `building` returning
///   and the `Decision` reaching libxpc used to be a process death; `XPCPipe` closed that span, so
///   `deinit` there now releases the session uncancelled (safe, measured) rather than cancelling
///   into an open window. What has *not* changed is that **sending on the pipe in that span still
///   traps** -- `beginDraining()` and `close()` both reach `pipe`, so neither may be called on a
///   freshly accepted core until the window is proved closed. `XPCServerTransport.Acceptor` is the
///   worked example: it holds such a core untouched in a `pending` table and acts only from the
///   proof.
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

    /// The cap on outstanding *inbound* streams -- a local resource guard, not protocol surface
    /// (§O5 deviation 6). §O4's byte credit bounds a stream's bytes; nothing in the op model bounds
    /// how many streams a peer may open, and §O5 negotiates nothing, so without this a peer can
    /// spend ~40 wire bytes per `openStream` to buy a table entry, two windows and an
    /// `AsyncThrowingStream` each. Over-limit accepts are refused with `status(resourceExhausted)`,
    /// which is an ordinary gRPC failure on the peer's side.
    ///
    /// **"Outstanding" counts the table *plus* accepts yielded but not yet pulled**, and that
    /// second term is load-bearing rather than defensive. A table-only cap does not bound anything:
    /// one blob carrying `openStream(id) ; cancel(id)` inserts an entry, yields the built stream,
    /// and removes the entry again -- all inside one routing turn -- so the table returns to its
    /// previous size while `acceptedStreams`' buffer grows by one, for about sixty wire bytes.
    /// Repeat with 3, 5, 7… and the cap never engages. `Registry.outstandingAccepts` is incremented
    /// at the `yield` and decremented when ``AcceptedStreamSequence``'s iterator actually hands the
    /// item to the accept loop.
    ///
    /// The sum double-counts a stream that is *both* in the table and undrained, so the effective
    /// limit during an accept-loop backlog is lower than 256. That is deliberate and is the safe
    /// direction: it admits fewer streams, never more, and in steady state the accept loop drains
    /// continuously so `outstandingAccepts` sits at 0.
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
    ///
    /// An ``AcceptedStreamSequence`` rather than the bare `AsyncStream` because pulling an item is
    /// what releases its slot against ``maxConcurrentInboundStreams`` -- see that constant's doc
    /// comment for why a table-only cap bounds nothing.
    ///
    /// **Iterate it exactly once.** It is computed rather than stored so that the slot-releasing
    /// callback can capture `self` weakly (L6) -- a stored property cannot, because the capture
    /// would have to happen before `init` has finished initializing it. Each access therefore
    /// returns a fresh wrapper over the *same* underlying `AsyncStream`, whose single-consumer
    /// contract is what makes "iterate once" the rule either way.
    var acceptedStreams: AcceptedStreamSequence {
        AcceptedStreamSequence(base: acceptedBase) { [weak self] in self?.acceptDidDeliver() }
    }

    private let acceptedBase: AsyncStream<AcceptedRPCStream>
    private let acceptedContinuation: AsyncStream<AcceptedRPCStream>.Continuation

    // =======================================================================================
    // MARK: - Outbound submission order
    // =======================================================================================

    /// **The lock that makes this connection's outbound order match its decisions.** Held across
    /// exactly one thing -- `pipe.send` -- plus, on ``send(_:forStream:)``'s path, the registry
    /// lookup that decides whether to send at all.
    ///
    /// It guards **no state**, which is why it lives here and not in the section below: the
    /// registry is still the one lock over this object's mutable state, and this one orders side
    /// effects. Two locks, two jobs, and the nesting is one-way: `submission` may be held while
    /// taking `registry`, never the reverse. Nothing that holds `registry` submits anything --
    /// every send in this file happens after its lock section has ended -- so there is no cycle to
    /// order around. (``OutboundOpWriter`` adds its own encoder lock *outside* this one, giving the
    /// single global order `writer.state` → `submission` → `registry`.)
    ///
    /// # Why a second lock rather than the registry, or the pipe's queue
    ///
    /// The invariant needs decision and submission to be one atomic step against *the other
    /// submitter*. Three mechanisms can supply that, and the two rejected ones each cost something
    /// this one does not:
    ///
    ///   * **hold the registry lock across the send.** Correct, and it would work -- L7 never
    ///     forbade it -- but it puts a libxpc syscall inside the lock that every inbound routing
    ///     turn takes, so outbound sends would serialise inbound routing behind them. That is the
    ///     one real objection to it, and it is enough.
    ///   * **hop every send onto the pipe's serial queue** (the shape proposed as the structural
    ///     answer). The queue *is* a serialisation point, and the fix would be sound if the check
    ///     rode across the hop with the send. But `pipe.send` is synchronous and reports its error
    ///     to the caller, and a writer holds a non-async `Mutex` across it: an `async` hop cannot
    ///     return the error to `write`, and a `sync` hop would deadlock the moment a send is issued
    ///     from the queue itself -- which every inbound-triggered `cancel` and `credit` is. It also
    ///     puts outbound sends behind inbound routing on the same queue for no gain.
    ///   * **this lock.** Same atomicity, no syscall under the registry lock, no hop, no change to
    ///     the error contract, and inbound *routing* never waits on it (only inbound work that
    ///     itself sends does, which is the ordering it needs anyway).
    ///
    /// # What it costs, measured
    ///
    /// Every outbound submission on a connection serialises here, so a `pipe.send` that stalls now
    /// stalls other streams' sends rather than only its own stream's. Nothing that can suspend is
    /// ever held across it -- §O4's credit is acquired *before* the writer's encoder lock, so a
    /// writer parked on credit holds neither this nor the registry.
    ///
    /// Measured on `OrderingStressTests` over two real XPC sessions, 5 runs each side: 10 000
    /// messages across 10 concurrent streams went from a mean of 92.4 ms to 92.6 ms (**+20 ns per
    /// message**, against ~9 µs end to end), and the interleaved-blob case from 104.8 ms to 105.6 ms
    /// -- under its own 9 ms run-to-run spread. One uncontended `Mutex` per submission.
    ///
    /// Inbound *routing* never waits on it: `send(_:forStream:)` releases the registry lock before
    /// `pipe.send`, so a routing turn's table lookups are never behind a syscall. A routing turn
    /// that itself submits -- a `cancel`, a `credit`, an accept refusal -- does wait, for at most one
    /// in-flight send, and that wait *is* the ordering it needs.
    ///
    /// # What it deliberately does not order
    ///
    /// **`credit` ops.** ``messageConsumed(streamID:charge:)`` and ``creditConnection(_:)`` read the
    /// registry, release it, and *then* submit, so a `credit(id)` decided just before a removal can
    /// reach the wire after that stream's `cancel`. That is harmless twice over -- the peer drops a
    /// `credit` for an id it no longer has (``applyCredit(streamID:bytes:)``), and a `credit(0)` is
    /// connection-scoped, always applicable and never dropped -- so no accounting can diverge. It is
    /// named here because it is the one remaining place where this connection's decision order and
    /// its wire order can differ for a single stream, and a reader should not have to re-derive that
    /// it is safe.
    private let submission = Mutex<Void>(())

    // =======================================================================================
    // MARK: - Mutable state (the one lock over this object's state)
    // =======================================================================================

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
        /// not yet credited. Also the per-stream half of §O4's receive-window **enforcement**:
        /// exceeding ``FlowControl/initialWindow`` fails this stream (see
        /// ``RPCTransportCore/deliver(_:toStream:)``).
        ///
        /// Unlike `Registry.connectionUnconsumed` this is decremented on *consumption* rather than
        /// on credit emission, which makes it up to `threshold - 1` bytes **more lenient** than the
        /// peer's real stream entitlement -- never stricter, so it cannot fail a conforming peer.
        /// The looser bound is deliberate: the flush at removal needs the count of bytes the
        /// application never took, which is exactly a consumption-based figure.
        ///
        /// Flushed into the **connection** accountant when the stream is
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
        ///
        /// **Held strongly, and the only strong edge into the core this file cannot break** -- see
        /// the L6 rule on ``RPCTransportCore/setCancellationObserver(forStream:_:)``: the supplier
        /// must not let it capture the core.
        var cancellationObserver: (@Sendable () -> Void)?

        /// L12: at most one per deadline-bearing RPC, cancelled on every removal path.
        var deadlineTimer: DispatchSourceTimer?

        /// Ends this stream's inbound sequence. `error == nil` is the clean end-of-stream.
        ///
        /// `RPCError?` rather than `(any Error)?` even though the `AsyncThrowingStream` beneath is
        /// gRPC's `..., any Error>`: the two callers (``removeStream(_:failingInboundWith:_:)`` and
        /// ``failAll(_:)``) both hold an `RPCError` now, and widening back to the existential here
        /// would only re-open a door nothing walks through. The upcast to the stream's own failure
        /// type happens at `finish(throwing:)`.
        func finishInbound(throwing error: RPCError?) {
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

    /// L7: the connection's lifecycle, explicit and under the one lock.
    ///
    /// **Three flags, not one enum, and that is the fix for a real defect.** A single
    /// `Phase = .running | .draining | .closed` conflated two *directional* facts, so an inbound
    /// `goAway` -- which says only "I will accept no more streams from you" -- also made this side
    /// refuse the peer's own subsequent `openStream` ops with `status(.unavailable)`. That
    /// contradicted `goAway`'s meaning, contradicted this file's own documentation of it, and handed
    /// a peer a one-op lever that permanently stopped the connection accepting work.
    ///
    /// | flag | set by | gates |
    /// |---|---|---|
    /// | `localDraining` | ``beginDraining()`` -- we sent `goAway` | inbound accepts (refused with `status(.unavailable)`), our own ``openStream``, and it finishes `acceptedStreams` |
    /// | `peerDraining` | ``peerBeganDraining()`` -- the peer sent `goAway` | **only** our own ``openStream`` (contract line 8 asks exactly this) |
    /// | `isClosed` | ``failAll(_:)`` -- peer death, a connection-level protocol error, `deinit`, a forceful teardown | everything. Terminal, and never un-set |
    ///
    /// The two draining flags are independent facts about two directions, not states of one
    /// machine; ``isDraining`` is their disjunction with `isClosed` for callers that want the
    /// summary.
    private struct Registry {
        var isClosed = false
        var localDraining = false
        var peerDraining = false

        var streams: [RPCStreamID: StreamEntry] = [:]

        /// Client-allocated stream ids: odd, ascending, never reused. `0` is the sentinel for
        /// "the id space is exhausted" -- 0 is reserved for the connection window (§O4) and so can
        /// never be a real stream id, which makes it a safe marker. Exhaustion throws rather than
        /// wrapping: a wrapped id would silently collide with a live stream.
        var nextClientStreamID: RPCStreamID = 1

        /// §O4's connection-level receive ledger. **One per connection, outliving every stream**
        /// -- a per-stream instance would strand up to `threshold - 1` bytes of the connection
        /// window per RPC. (`WindowAccountant.flush()` exists for the one moment that promise
        /// expires: the stream removal in ``removeStream(_:failingInboundWith:sendingCancel:)``,
        /// where there is no future delivery to carry a remainder.)
        var connectionReceive = WindowAccountant()

        /// §O4's connection-level receive **window**, as opposed to the ledger above: bytes
        /// charged on this connection minus bytes actually credited back to the peer.
        ///
        /// This is the debit side the accountant does not have, and it mirrors the peer's own send
        /// arithmetic exactly -- which is what makes enforcement safe. The peer's available
        /// connection window is `initialWindow - (charged - credited)`, so
        /// `connectionUnconsumed > initialWindow` is precisely "the peer's own window went
        /// negative", something a conforming peer cannot do. Note it is decremented by what is
        /// *emitted*, not by what is consumed: consumption is batched, so a consumption-based
        /// counter would run up to `threshold - 1` bytes more lenient than the peer's real
        /// entitlement.
        var connectionUnconsumed = 0

        /// Accepts yielded into `acceptedStreams` but not yet pulled by the accept loop. Counted
        /// against ``maxConcurrentInboundStreams`` alongside `streams.count` -- see that constant.
        var outstandingAccepts = 0

        /// The highest stream id seen in either direction, for `goAway`'s `lastStreamID`.
        var highestStreamID: RPCStreamID = 0

        /// `acceptedStreams`' continuation may be finished at most once, from three racing places.
        var acceptedFinished = false

        // ---------------------------------------------------------------------------------
        // Connection-ledger helpers. Every emission of connection credit goes through one of
        // these two, so the `connectionUnconsumed` debit can never drift from what went out.
        // ---------------------------------------------------------------------------------

        /// Records `bytes` consumed on the connection and returns the batched credit, if any.
        mutating func creditConnection(consuming bytes: Int) -> UInt32? {
            guard let credit = connectionReceive.consumed(bytes) else { return nil }
            debitConnection([credit])
            return credit
        }

        /// Records `bytes` and then flushes the ledger past its batching threshold, for a stream
        /// removal. Returns **up to two** credits rather than summing them, so no assumption is
        /// made about the total staying inside §O4's 2³¹−1 ceiling.
        ///
        /// **Gated on `bytes > 0`, which is not a micro-optimisation.** Flushing unconditionally
        /// drained residue contributed by *other* streams on every removal, clean completions
        /// included -- and for a unary RPC "one control op per removal" *is* one per message,
        /// precisely what §O4 batches to avoid (traced: roughly one `credit` op per 328 sequential
        /// 100-byte unary RPCs became one per RPC).
        ///
        /// The gate costs none of the three properties the flush was added for, because each has
        /// `bytes > 0` by construction: L3's early-returning handler strands bytes; a
        /// `.streamOverran` recovery has `unconsumedCharge > initialWindow`; and a peer parked on
        /// the connection window is parked *because* bytes were received and not consumed. Only
        /// clean completion changes, and there the residue is carried by the next delivery exactly
        /// as §O4 intends.
        mutating func flushConnection(recording bytes: Int) -> [UInt32] {
            guard bytes > 0 else { return [] }
            var credits: [UInt32] = []
            if let credit = connectionReceive.consumed(bytes) { credits.append(credit) }
            if let credit = connectionReceive.flush() { credits.append(credit) }
            debitConnection(credits)
            return credits
        }

        /// The one place `connectionUnconsumed` is reduced. Clamped at zero for symmetry with
        /// `outstandingAccepts`, and for one reachable reason: ``failAll(_:)`` zeroes the counter,
        /// after which a late `deliver` for an unknown stream can still route residue through
        /// ``creditConnection(consuming:)``. A negative value is harmless in every direction -- it
        /// only makes the bound *more* lenient, on a connection that is already closed -- but an
        /// unexplained asymmetry between two sibling counters is not.
        private mutating func debitConnection(_ credits: [UInt32]) {
            let total = credits.reduce(0) { $0 + Int($1) }
            connectionUnconsumed = max(0, connectionUnconsumed - total)
        }
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

    /// The disjunction of all three lifecycle flags: `true` once this connection has begun
    /// winding down for any reason, in either direction. A summary for callers -- the code below
    /// always tests the specific flag it means.
    var isDraining: Bool {
        registry.withLock { $0.isClosed || $0.localDraining || $0.peerDraining }
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
        self.acceptedBase = stream
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
    /// `codec.decode(_:)` throwing still fails the **connection**, not a stream, and that is
    /// unchanged by `WireDecodeItem`'s introduction -- but what can still throw has narrowed. A
    /// **header**-level failure (truncated framing, an untrustworthy declared body length) is not
    /// attributable to any stream, because the header that would name one is the thing that did
    /// not parse, and every op after it in the same blob is unrecoverable, so there is nothing to
    /// resynchronise to. `CompactWireCodec` also throws for a malformed `goAway` body specifically
    /// (see its `decode(_:)` doc) -- connection-scoped by its own nature, not a per-stream
    /// exception carved out of this rule. Every other **body**-level rejection §O2's amendment
    /// covers now arrives as an item below instead, and splits two ways by kind, not uniformly:
    /// `.streamFailure` for every kind but `openStream`, handled exactly like a state-machine
    /// grammar violation (fail that one stream, leave the rest of the blob routed normally); and
    /// `.streamOpenFailure` for `openStream` itself, answered on the wire through
    /// ``refuseOpen(_:dueTo:)`` because that is the one kind whose rejection cannot be silently
    /// dropped without hanging a peer that is definitionally waiting on this id -- see
    /// `WireDecodeItem`'s doc.
    private func receive(_ blob: GRPCSwiftData) {
        // L4 tripwire. Measured caveat from Task 5: `.onQueue` is target-chain permissive, so this
        // catches "delivered from an unrelated queue" but would not catch "delivered from a child
        // queue targeting this one". It is cheap and it did catch a real inlined-delivery
        // regression, so it stays -- as a tripwire, not as proof.
        dispatchPrecondition(condition: .onQueue(pipe.queue))

        let items: [WireDecodeItem]
        do {
            items = try codec.decode(blob)
        } catch {
            failConnection(
                RPCError(
                    code: .internalError,
                    message: "the peer sent an undecodable blob; the op framing cannot be "
                        + "resynchronised, so the connection is failed",
                    cause: error))
            return
        }

        for item in items {
            switch item {
            case .op(let op):
                route(op)
            case .streamFailure(let streamID, let error):
                // §O2's codec-binding amendment: a body-level rejection fails only the stream the
                // codec already read off the op's own header -- see `WireDecodeItem`. This takes
                // exactly the path `deliver(_:toStream:)`'s `.violation` case already takes, not a
                // parallel one, because it is the same kind of failure caught one layer earlier.
                failStream(streamID, dueTo: error)
            case .streamOpenFailure(let streamID, let error):
                // §O2's carve-out: `openStream` creates state, so a rejection is answered, not
                // dropped -- see `WireDecodeItem.streamOpenFailure`'s doc and `refuseOpen(_:dueTo:)`.
                refuseOpen(streamID, dueTo: error)
            }
        }
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
            //
            // `reason` is the peer's, and the decode path applies no per-field cap to it -- only
            // `CompactWireCodec`'s 16 MiB `maxBodyLength`. Interpolating it whole would hand the
            // application (and every log that prints it) a 16 MiB `RPCError` message, which is the
            // same unbounded in-process allocation `failStream` and `cancelStream` already refuse.
            // This was the one sink that skipped it.
            removeStream(
                streamID,
                failingInboundWith: RPCError(
                    code: .cancelled,
                    message: "the peer cancelled stream \(streamID): "
                        + Self.truncatedForWire(reason)),
                sendingCancel: nil)

        case .openStream(let streamID, let method, let timeout):
            openInbound(streamID: streamID, method: method, timeout: timeout)

        case .metadata(let streamID, _), .message(let streamID, _), .halfClose(let streamID),
            .status(let streamID, _, _, _):
            deliver(op, toStream: streamID)
        }
    }

    /// Fails one stream because of a protocol violation attributed to it -- a state-machine
    /// grammar violation (§O2, `deliver(_:toStream:)`'s `.violation` case) or a codec-level
    /// body-level rejection (§O2's codec-binding amendment, `receive(_:)`'s `.streamFailure`
    /// case). Both callers hand this the same two things -- the stream id and the error that
    /// doomed it -- and both want the same outcome, so they share this one path rather than two
    /// that could drift apart.
    ///
    /// Both the wire reason and the *local* error the application sees are truncated here, and
    /// separately: `removeStream` truncates whatever `String` it is given before it reaches the
    /// wire, but `error` itself is not a `String` -- passing it straight through as
    /// `failingInboundWith` would hand the application an untruncated `RPCError` whose
    /// description can embed a peer-supplied field verbatim (and, through a decoder's `cause`
    /// chain, more than one), up to the 16 MiB body cap. Mirrors ``cancelStream(_:reason:)``'s own
    /// truncation of its local error, for the same reason -- the two should read the same rather
    /// than diverge on this, and applies to **both** of this function's callers, including the
    /// pre-existing state-machine-violation path, not only the codec one added alongside it.
    ///
    /// The rebuilt local error preserves the original error's `code` -- both callers now hand
    /// this an `RPCError` by type, not by convention -- but **not** its `cause` chain: `RPCError`'s own
    /// `description` folds `cause` into the very string this truncates
    /// (`"\(code): \"\(message)\" (cause: \"\(cause)\")"`), so re-wrapping it necessarily flattens a
    /// decoder's live `cause` to text -- an application inspecting `(error as? RPCError)?.cause`
    /// on the *local* error this function hands it now always sees `nil`, where before this
    /// truncation existed it saw the decoder's original cause. Sourced from `error`'s own
    /// `message`, not its full `"\(error)"` description, specifically so the rebuilt `RPCError`
    /// does not end up stating its own `code` twice (`description` already prepends it).
    private func failStream(_ id: RPCStreamID, dueTo error: RPCError) {
        removeStream(
            id,
            failingInboundWith: RPCError(
                code: error.code, message: Self.truncatedForWire(error.message)),
            sendingCancel: "\(error)")
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
            // §O4's floor makes this at least 1 even for an empty payload, so `charge > 0` below
            // reads as "this op is flow-controlled", not "the payload is non-empty".
            charge = FlowControl.charge(for: payload.count)
        } else {
            charge = 0
        }

        enum Delivered {
            case unknownStream
            case streamOverran(Int)
            case connectionOverran(Int)
            case request(
                [RPCRequestPart<GRPCSwiftData>],
                AsyncThrowingStream<RPCRequestPart<GRPCSwiftData>, any Error>.Continuation,
                remoteEnded: Bool)
            case response(
                [RPCResponsePart<GRPCSwiftData>],
                AsyncThrowingStream<RPCResponsePart<GRPCSwiftData>, any Error>.Continuation,
                remoteEnded: Bool)
            case violation(RPCError)
        }

        let outcome: Delivered = registry.withLock { registry in
            // §O4 (amended): ENFORCE the receive window, do not merely account for it.
            //
            // The connection counter is charged whatever the id, because the peer spent its
            // connection window whatever the id. The two bounds are then checked
            // **narrowest-first**: a single stream over its own 65 535 necessarily puts the
            // connection total over too, and failing one stream is the smaller blast radius --
            // HTTP/2's own `FLOW_CONTROL_ERROR` split. Only an overrun that no single stream
            // accounts for is a connection-level violation, and that is reachable exactly when the
            // peer's own connection window went negative, which a conforming peer cannot do.
            registry.connectionUnconsumed += charge
            let connectionOverran = registry.connectionUnconsumed > FlowControl.initialWindow

            guard var entry = registry.streams[id] else {
                // No per-stream ledger to check; the connection bound is the only one there is.
                return connectionOverran
                    ? .connectionOverran(registry.connectionUnconsumed) : .unknownStream
            }
            entry.unconsumedCharge += charge
            // Written back on every exit, including the violation and overrun ones:
            // `removeStream` reads `unconsumedCharge` to flush it, and this op's bytes belong in
            // that flush -- which is also what brings `connectionUnconsumed` back under its bound
            // after a stream-level overrun.
            defer { registry.streams[id] = entry }

            if entry.unconsumedCharge > FlowControl.initialWindow {
                return .streamOverran(entry.unconsumedCharge)
            }
            if connectionOverran { return .connectionOverran(registry.connectionUnconsumed) }

            switch entry.inbound {
            case .request(var decoder, let continuation):
                do throws(RPCError) {
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
                do throws(RPCError) {
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

        case .streamOverran(let outstanding):
            // §O2's blast radius: one stream. `removeStream` flushes this stream's whole
            // outstanding charge back onto the connection window, so the connection recovers.
            removeStream(
                id,
                failingInboundWith: RPCError(
                    code: .internalError,
                    message: "the peer exceeded stream \(id)'s receive window: \(outstanding) "
                        + "byte(s) received and not yet credited, limit "
                        + "\(FlowControl.initialWindow)"),
                sendingCancel: "stream receive-window overrun")

        case .connectionOverran(let outstanding):
            failConnection(
                RPCError(
                    code: .internalError,
                    message: "the peer exceeded the connection's receive window: \(outstanding) "
                        + "byte(s) received and not yet credited, limit "
                        + "\(FlowControl.initialWindow)"))

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
            // Contract line 1. §O2: fails this stream only. See ``failStream(_:dueTo:)``, shared
            // with `receive(_:)`'s `.streamFailure` handling for the codec-level counterpart of
            // this same failure.
            failStream(id, dueTo: error)
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
            // `method` is peer-supplied and can be as long as the codec's 16 MiB body cap allows,
            // so it is truncated before it goes back out on the wire.
            refuseWithStatus(
                id, .unimplemented,
                "malformed method path '\(Self.truncatedForWire(method))'")
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
            // Advanced before the admission decision, so `goAway`'s `lastStreamID` names every id
            // the peer actually used -- including ones this side refused. (Structurally illegal ids
            // -- 0 and even -- are rejected above and deliberately do not advance it: they are not
            // ids the peer could legitimately have opened.)
            registry.highestStreamID = max(registry.highestStreamID, id)

            // Note which flag is tested: `localDraining` only. An inbound `goAway` sets
            // `peerDraining`, which says the peer will accept no more streams *from us* and says
            // nothing about streams it may still open on us -- gating accepts on it handed a peer a
            // one-op lever that permanently stopped this side accepting work.
            if registry.isClosed { return .closed }
            if registry.localDraining { return .draining }

            // §O5 deviation 6. The table alone bounds nothing: `openStream(id) ; cancel(id)` in one
            // blob inserts, yields and removes inside a single routing turn, leaving the table
            // unchanged and the accept buffer one longer. See `maxConcurrentInboundStreams`.
            let outstanding = registry.streams.count + registry.outstandingAccepts
            guard outstanding < Self.maxConcurrentInboundStreams else {
                return .tooMany(outstanding)
            }
            registry.streams[id] = entry
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
        case .tooMany(let outstanding):
            refuseWithStatus(
                id, .resourceExhausted,
                "too many outstanding streams on this connection (\(outstanding), limit "
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

        // The slot this accept occupies against `maxConcurrentInboundStreams` is claimed here and
        // released by `acceptDidDeliver()` when the accept loop pulls the item -- not when the
        // table entry goes away, which can happen while the item is still buffered.
        registry.withLock { $0.outstandingAccepts += 1 }
        let delivery = acceptedContinuation.yield(
            AcceptedRPCStream(id: id, descriptor: descriptor, timeout: timeout, stream: stream))

        switch delivery {
        case .enqueued:
            break
        case .dropped, .terminated:
            // The accept sequence was finished (or, with a bounded policy, full) between this
            // routing turn's admission check and this yield -- a `beginDraining()` or a teardown
            // racing an accept. The item is gone, so nothing will ever pull it, and two pieces of
            // bookkeeping would otherwise be stranded:
            //
            // * the slot claimed above, which no `acceptDidDeliver()` will pair with -- a permanent
            //   reduction of the cap, benign but pointless;
            // * **the table entry**, which no `streamHandlerFinished(_:)` will ever retire because
            //   no handler will ever run for it. That one is contract line 7: an entry outliving
            //   its stream. Unlike `failAll`, `beginDraining` does not sweep the table, so this is
            //   the one path where a built-and-then-undeliverable stream has to clean up after
            //   itself.
            acceptDidDeliver()
            removeStream(
                id,
                failingInboundWith: RPCError(
                    code: .unavailable,
                    message: "stream \(id) was accepted but the connection stopped accepting "
                        + "before it could be delivered to a handler"),
                sendingCancel: "the server stopped accepting new streams")
        @unknown default:
            acceptDidDeliver()
            removeStream(
                id,
                failingInboundWith: RPCError(
                    code: .unavailable,
                    message: "stream \(id) could not be delivered to a handler"),
                sendingCancel: "the server could not deliver the stream to a handler")
        }
    }

    /// Releases one accept's slot. Called by ``AcceptedStreamSequence``'s iterator at the moment
    /// the accept loop actually receives the item, which is the only point at which the value has
    /// left this object's buffer.
    ///
    /// Clamped at zero rather than trusting the pairing: `failAll` resets the counter, so an item
    /// buffered before a teardown and pulled after it would otherwise drive this negative and
    /// silently raise the effective cap.
    ///
    /// **There is no release-on-destruction path**: an accept loop that is abandoned mid-iteration,
    /// or an `AcceptedStreamSequence` dropped without being iterated, leaves its items' slots
    /// claimed until ``failAll(_:)`` zeroes the counter. That is deliberately fail-closed -- the
    /// counter can only ever be too *high*, which refuses accepts and never admits extras -- and a
    /// server that stops draining `acceptedStreams` while still expecting to serve RPCs is a caller
    /// bug that this counter should surface rather than paper over.
    private func acceptDidDeliver() {
        registry.withLock { $0.outstandingAccepts = max(0, $0.outstandingAccepts - 1) }
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

    /// Refuses an `openStream` whose body this codec rejected (`WireDecodeItem.streamOpenFailure`,
    /// §O2's carve-out). `openStream` is the one kind whose body-level rejection is answered
    /// rather than dropped, because it is the one kind whose semantics *create* state -- the id
    /// belongs to the peer the moment it sends this op, so the peer is definitionally waiting on a
    /// reply, unlike a made-up id on any other kind (see `WireDecodeItem.streamOpenFailure`'s doc).
    ///
    /// Deliberately mirrors `openInbound`'s own gate order for the two checks that do not need a
    /// successfully-decoded `method` to evaluate -- role, then id legality -- because skipping
    /// either one here would be exactly as wrong as skipping it there. In particular: **the role
    /// gate must run first.** A malformed `openStream` body reaching a *client* transport must
    /// still get `openInbound`'s treatment (a client never accepts, so `cancel`, not `status`) --
    /// checking id legality or answering with `status` before checking role would have a client
    /// transport answer an `openStream` it must never accept.
    ///
    /// Past those two gates this always answers `status`/`.invalidArgument` with a **fixed
    /// literal** message, never `error`'s own text -- see `WireDecodeItem.streamOpenFailure`'s doc
    /// for why: `error` can embed up to 16 MiB of peer-chosen bytes, and since no table entry is
    /// ever created here (successfully or not), a peer can trigger this reply as many times as it
    /// likes for free -- echoing even a truncated form of `error` would still let the peer's input
    /// size drive the reply's size, repeatably.
    private func refuseOpen(_ id: RPCStreamID, dueTo error: RPCError) {
        guard role == .server else {
            refuseWithCancel(id, "a client transport does not accept streams")
            return
        }
        guard id != 0, id.isMultiple(of: 2) == false else {
            refuseWithCancel(
                id, "stream id \(id) is not a legal client-allocated id (must be odd and non-zero)")
            return
        }
        refuseWithStatus(id, .invalidArgument, "malformed openStream")
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
    func openStream(descriptor: MethodDescriptor, timeout: Duration?) throws(RPCError) -> (
        id: RPCStreamID, stream: ClientRPCStream
    ) {
        precondition(
            role == .client,
            "RPCTransportCore.openStream: only a client-role core allocates streams; a server "
                + "accepts them through `acceptedStreams`")

        let (inbound, continuation) = AsyncThrowingStream.makeStream(
            of: RPCResponsePart<GRPCSwiftData>.self)

        // L7: the lifecycle check and the id allocation are one atomic take-and-transition, so a
        // `beginDraining()` racing this call either loses (the stream is allocated) or wins (this
        // throws) -- never both.
        let id: RPCStreamID = try registry.withLock { registry throws(RPCError) in
            // Contract line 8: **either** direction's drain stops us opening new streams -- ours
            // because we announced we are going away, the peer's because it announced it will not
            // accept any more.
            if registry.isClosed {
                throw RPCError(
                    code: .unavailable, message: "the connection is no longer available")
            }
            if registry.localDraining || registry.peerDraining {
                throw RPCError(
                    code: .unavailable,
                    message: "the connection is draining; no new streams may be opened")
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

    /// The error a send refused because its stream is gone reports. `.unavailable` rather than
    /// `.internalError`: the stream really is gone from under the caller (a deadline, a peer
    /// `cancel`, a teardown), which is not a caller mistake -- and it matches what
    /// ``reserveOutboundWindow(_:forStream:)`` already throws for the same condition.
    private func streamNoLongerOpen(_ id: RPCStreamID) -> RPCError {
        RPCError(code: .unavailable, message: "stream \(id) is no longer open on this connection")
    }

    /// Encodes and submits ops for a stream whose entry must still exist -- every op
    /// ``OutboundOpWriter`` emits, and the only path that takes the submission lock **with a
    /// decision inside it**.
    ///
    /// # What this closes
    ///
    /// `openStream` is deferred to the writer's first `write`/`finish` (see
    /// ``openStream(descriptor:timeout:)``), so between "registered, deadline armed" and "the peer
    /// has heard of this stream" the stream exists locally and nowhere else. A removal inside that
    /// gap -- a fired deadline is the reachable one -- sends `cancel(id)` for an id the peer will
    /// drop, and a first write that reached the wire afterwards would open the stream *behind* it:
    /// the peer then admits a stream whose client has already abandoned it, runs a handler for it,
    /// and (with no deadline of its own) holds a ``maxConcurrentInboundStreams`` slot until the
    /// connection is torn down. The client cannot repair it either -- its own entry is already
    /// gone, so a later `cancelStream` finds nothing and returns `false`.
    ///
    /// An earlier round narrowed that window by asking "is this stream still open?" immediately
    /// before the send, and recorded in this file that the two could not be made atomic because
    /// "nothing short of sending under the registry lock could be, and L7 forbids that". **Both
    /// halves of that were wrong.** L7 is about lifecycle state machines and about resuming
    /// *continuations* outside a lock; `pipe.send` is neither. And the check does not have to be
    /// atomic with the send *against the registry* at all -- it has to be atomic against **the
    /// other submitter**, which is a strictly weaker requirement and needs no registry lock held
    /// across a syscall.
    ///
    /// # Why this is now closed rather than narrowed
    ///
    /// Two facts compose, and neither is about libxpc's message ordering:
    ///
    /// 1. ``removeStream(_:failingInboundWith:sendingCancel:)`` takes the entry **out of the
    ///    registry before it submits anything**. So a `cancel` that has been submitted is a
    ///    `cancel` whose entry was already gone.
    /// 2. This function performs its registry lookup **and** its `pipe.send` inside one
    ///    ``submission`` critical section.
    ///
    /// Therefore: if the lookup here succeeds, the removal had not finished its registry section,
    /// so its `cancel` cannot have been submitted -- and it cannot be submitted before this send
    /// returns, because we hold `submission`. If the removal did finish first, the lookup fails and
    /// nothing is sent. There is no third interleaving, and the ordering does not depend on how
    /// wide the window is.
    ///
    /// What libxpc contributes is only the last link: submission order is delivery order. Measured
    /// rather than assumed -- `docs/xpc-platform-matrix/SendOrderMatrix.swift` row **S1**, 20 000
    /// sends from 8 threads issued under one lock, arrival order identical to submission order 5
    /// runs out of 5. Its control row **S2** moves the send outside the lock and reorders **10 168
    /// of 20 000**, which is what "the remaining window is only `encode` + `pipe.send` wide" is
    /// actually worth under contention.
    ///
    /// - Throws: ``streamNoLongerOpen(_:)`` if the stream is gone (nothing was sent), the codec's
    ///   error, or the substrate's `RPCError(code: .unavailable)`.
    fileprivate func send(_ ops: [RPCOp], forStream id: RPCStreamID) throws(RPCError) {
        guard !ops.isEmpty else { return }
        // Deliberately outside the lock: encoding is pure, and it is the widest part of what used
        // to be the racing window. Wire order is submission order, not encode order.
        let blob = try codec.encode(ops)
        try submission.withLock { _ throws(RPCError) in
            guard registry.withLock({ $0.streams[id] != nil }) else {
                throw streamNoLongerOpen(id)
            }
            try pipe.send(blob)
        }
    }

    /// Encodes and submits ops that answer to no registry entry: credit, `goAway`, an accept
    /// refusal for an id that was never admitted, and the `cancel` of a removal that has *already*
    /// taken its entry out of the table.
    ///
    /// Takes ``submission`` for the same reason as ``send(_:forStream:)`` -- it is the other half
    /// of that function's ordering argument, and a `cancel` submitted outside the lock would make
    /// the check inside it meaningless.
    ///
    /// - Throws: the codec's error, or the substrate's `RPCError(code: .unavailable)`.
    private func sendEncoded(_ ops: [RPCOp]) throws(RPCError) {
        guard !ops.isEmpty else { return }
        let blob = try codec.encode(ops)
        try submission.withLock { _ throws(RPCError) in try pipe.send(blob) }
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
            // Intentionally terminal, for the reasons in this function's own doc comment above.
        }
    }

    /// The cap on any peer-derived text this file puts back on the wire, **in UTF-8 bytes**.
    static let maxWireReasonLength = 512

    /// Bounds what a `cancel` op's `reason` (or a refusal's `message`) can carry back to the peer.
    ///
    /// **This is a hostile-input path, not a formatting nicety.** A decoder's error message embeds
    /// what arrived: a `metadata` op with a `-bin` key and a non-base64 value throws with that value
    /// interpolated into the message, and the value can be as large as `CompactWireCodec`'s 16 MiB
    /// body cap. Interpolating that error into `cancel(id, reason:)` reflects the peer's own payload
    /// straight back at it, at whatever size it chose, on a control op that is exempt from flow
    /// control. A few hundred bytes is all a diagnostic needs.
    ///
    /// # It must bound BYTES, not `Character`s
    ///
    /// This truncated on `text.prefix(512)` until re-review, which bounds **grapheme clusters** --
    /// and a cluster has no length bound. One base character followed by four million combining
    /// marks is a single `Character`, so a 16 MiB peer value made of a handful of enormous clusters
    /// passed `prefix(512)` completely unchanged and went straight back out. The codec validates
    /// only that a field value is UTF-8 (`CompactWireCodec.decodeFieldList`), never what it
    /// normalises to, so the peer chooses the clusters. Slicing `text.utf8` is what makes the cap a
    /// real bound; `String(decoding:as:)` substitutes U+FFFD for a scalar the slice split rather
    /// than failing, so a truncation can never throw or return the untruncated string as a fallback.
    ///
    /// Detection compares `endIndex` rather than counting, so the common short-string case stays
    /// O(1) instead of walking a possibly enormous string.
    ///
    /// **Five uses, of which two are wire-bound.** The count was right before; the
    /// characterisation was not, and a reader would have concluded that every wire-bound peer text
    /// funnels through one place. It does not:
    ///
    ///   * **wire, and the one everything else funnels through** --
    ///     ``removeStream(_:failingInboundWith:sendingCancel:)``. Callers pass their full text and
    ///     must not pre-truncate: stacking two calls clips the first call's own marker.
    ///   * **wire, and separate** -- ``openInbound(streamID:method:timeout:)``'s malformed-method
    ///     refusal, which interpolates the peer's `method` (up to the codec's 16 MiB body cap) into
    ///     a `status` op. It is truncated at that site because it never reaches `removeStream`: no
    ///     table entry is created for a refused open.
    ///   * **local** -- ``cancelStream(_:reason:)``'s error text, ``failStream(_:dueTo:)``'s error
    ///     text, and ``route(_:)``'s `.cancel` case, which interpolates the **peer's** `reason`
    ///     into the `RPCError` the application sees. Bounded not because they cross the wire but
    ///     because an unbounded in-process message is still an unbounded allocation -- and the
    ///     `.cancel` one is peer-chosen, so it is the same hostile input as the wire-bound uses,
    ///     merely pointed inwards.
    ///
    /// When you add a sixth use, say which class it is in as well as updating the count. This
    /// sentence has now gone stale twice: once on the count, once on the classification.
    static func truncatedForWire(_ text: String) -> String {
        let head = text.utf8.prefix(maxWireReasonLength)
        guard head.endIndex != text.utf8.endIndex else { return text }
        return String(decoding: head, as: UTF8.self) + "… [truncated]"
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
            connectionCredit = registry.creditConnection(consuming: charge)
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
        let credit = registry.withLock { $0.creditConnection(consuming: charge) }
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
    /// 4. **Un-consumed receive charge is flushed into the connection accountant, and the
    ///    accountant is then flushed unconditionally.** This is L3 exactly: a handler that returns
    ///    without draining its request half otherwise strands those bytes of the peer's connection
    ///    window forever, and the peer's writer parks on credit that is never coming (the old build
    ///    measured 33 of 200 sent, then a permanent hang). The stream half is not credited -- the
    ///    stream is gone, and an abnormal removal also sends `cancel`, so the peer drops its own
    ///    stream window.
    ///
    ///    **`flushConnection(recording:)`, not `consumed(_:)`.** Handing the bytes to the ledger is
    ///    not the same as emitting them: `consumed(_:)` batches at half the initial window and
    ///    returns `nil` below it, so a removal could hand over 40 000 bytes and emit nothing. That
    ///    is safe for a long-lived ledger that will cross the threshold on a later delivery, and it
    ///    is *not* safe here -- a removal is exactly the moment there is no later delivery for that
    ///    stream. The flush also matters to the receive-window enforcement above: it is what brings
    ///    `connectionUnconsumed` back under its bound after a stream-level overrun.
    ///
    ///    It flushes the ledger's *whole* accumulation, including a residue left by other streams,
    ///    so a removal can emit a `credit` op that pure batching would have deferred. That is the
    ///    intended trade: §O4 batches so that "a stream of small messages does not produce one
    ///    control op each", and at most one extra control op per stream *removal* is nowhere near
    ///    that, while a deferred residue is bytes the peer is owed and cannot get.
    ///
    /// The cancellation observer fires only on abnormal removal: firing it on a clean completion
    /// would tell a server handler it had been cancelled after it had already succeeded.
    ///
    /// Idempotent: the entry is taken out of the table under the registry lock, so exactly one
    /// caller ever performs the teardown. Everything that can block or call out -- window
    /// failures, continuations, `pipe.send` -- happens after that lock is released (L7).
    ///
    /// **The order of the last two statements is load-bearing, not tidiness: the entry leaves the
    /// registry strictly before this function submits anything.** That is one half of the
    /// outbound-ordering invariant -- ``send(_:forStream:)`` is the other half, and it is where the
    /// argument is written out. A refactor that submitted the `cancel` from inside the registry
    /// section, or that removed the entry *after* sending, would let a writer's deferred
    /// `openStream` follow this `cancel` onto the wire again.
    @discardableResult
    private func removeStream(
        _ id: RPCStreamID,
        failingInboundWith error: RPCError?,
        sendingCancel reason: String?
    ) -> Bool {
        var taken: StreamEntry?
        var connectionCredits: [UInt32] = []

        registry.withLock { registry in
            guard let entry = registry.streams.removeValue(forKey: id) else { return }
            taken = entry
            connectionCredits = registry.flushConnection(recording: entry.unconsumedCharge)
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
        if let reason { ops.append(.cancel(id, reason: Self.truncatedForWire(reason))) }
        ops.append(contentsOf: connectionCredits.map { .credit(0, bytes: $0) })
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
        // `removeStream` bounds what reaches the wire. The *local* error is bounded here as well,
        // separately: this is reachable from `RPCWriter.finish(throwing:)`, whose error may be an
        // `RPCError` whose `cause` chain carries peer-supplied field bytes, and an unbounded
        // in-process error message is still an unbounded allocation.
        removeStream(
            id,
            failingInboundWith: RPCError(
                code: .cancelled,
                message: "stream \(id) was cancelled locally: "
                    + Self.truncatedForWire(reason)),
            sendingCancel: reason)
    }

    /// The client-side mirror of ``streamHandlerFinished(_:)``: the `withStream` closure returned.
    ///
    /// **MUST be called on every exit path of that closure**, for the same reason and with the same
    /// force as the server-side call. Contract line 7 otherwise rests entirely on the transport's
    /// discipline on this side while the server side has a named mandatory call, and a client
    /// stream whose peer sent `status` but whose caller never reached `finish()` leaves an entry
    /// behind -- exactly the one-per-RPC leak the old build had.
    ///
    /// Safe and free after a clean completion: both directions closing already retired the entry,
    /// so ``removeStream(_:failingInboundWith:sendingCancel:)`` finds nothing, returns `false`, and
    /// builds no op. The presence of an entry at this point therefore *is* the definition of "the
    /// call did not complete", which is why this needs no `localDone`/`remoteDone` inspection of
    /// its own.
    func clientCallFinished(_ id: RPCStreamID) {
        removeStream(
            id,
            failingInboundWith: RPCError(
                code: .cancelled,
                message: "the client abandoned stream \(id) before the call completed"),
            sendingCancel: "the client abandoned the call before it completed")
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
    /// §O5.3 makes `cancel` the abort op in both directions.
    ///
    /// **Which end's timer fires first, corrected by measurement (Task 8b §4.2).** This comment
    /// used to claim the client's own timer "normally fires first" because the wire deadline is
    /// rounded *up* by `GRPCWireHeaders`. That is right about what the **caller** sees -- the
    /// client's timer is what surfaces `.deadlineExceeded` to it -- and wrong about the **peer**:
    /// both ends arm a timer for the same RPC, and the server's won the race **20 times out of
    /// 20**. Rounding up bounds the server's *deadline*, not the moment its handler is torn down,
    /// and the server has no client-side scheduling to wait for. So a server handler observes its
    /// stream failing on its own timer, not on the client's `cancel` op arriving. Neither is a
    /// defect; both ends independently stop working on a doomed RPC, which is the point.
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
    ///
    /// "Effectively never" was an assumption about Dispatch and is now measured (Task 8b §5.3):
    /// `DispatchTime.now() + .nanoseconds(Int.max)` **does** saturate rather than wrap, so the
    /// clamped timer really does not fire, and it does not fire *immediately* either -- which is
    /// what a wrap would have produced, and would have been the worst possible reading of an
    /// absurd deadline.
    private static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let (seconds, secondsOverflowed) = components.seconds.multipliedReportingOverflow(
            by: 1_000_000_000)
        guard !secondsOverflowed else {
            return .nanoseconds(components.seconds < 0 ? 0 : Int.max)
        }
        let (total, totalOverflowed) = seconds.addingReportingOverflow(
            components.attoseconds / 1_000_000_000)
        guard !totalOverflowed else {
            return .nanoseconds(components.seconds < 0 ? 0 : Int.max)
        }
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
    /// - Important: **The observer must not capture this core** (L6). It is the one strong edge
    ///   into the core that this file cannot make weak -- a closure is not a reference -- so
    ///   `core -> registry -> entry -> observer -> core` would be a *self*-cycle, and a self-cycle
    ///   is invisible to any external weak-reference check: `deinit` simply never runs and the XPC
    ///   session leaks. The intended shape captures nothing that points back here:
    ///
    ///   ```swift
    ///   await withServerContextRPCCancellationHandle { handle in
    ///       core.setCancellationObserver(forStream: accepted.id) { handle.cancel() }   // no core
    ///   }
    ///   ```
    ///
    /// - Returns: `true` if the stream is *already* gone, or this side is closed or locally
    ///   draining -- i.e. the observer will never fire, or fired before it was installed, and the
    ///   caller should cancel immediately. This closes the race where a teardown swept the table
    ///   between the stream being accepted and the handler task being scheduled. `peerDraining` is
    ///   deliberately **not** part of it: the peer announcing it will open no more streams says
    ///   nothing about the streams already running here.
    @discardableResult
    func setCancellationObserver(
        forStream id: RPCStreamID, _ observer: @escaping @Sendable () -> Void
    ) -> Bool {
        registry.withLock { registry in
            guard var entry = registry.streams[id] else { return true }
            entry.cancellationObserver = observer
            registry.streams[id] = entry
            return registry.isClosed || registry.localDraining
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
            guard !registry.isClosed, !registry.localDraining else { return .none }
            registry.localDraining = true
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
    /// It sets `peerDraining` and **nothing else**. `goAway` is directional: the peer is saying it
    /// will accept no more streams *from us*, which says nothing about streams it may still open on
    /// us -- so this does not finish `acceptedStreams`, does not refuse inbound `openStream` ops,
    /// and does not disturb streams already open.
    ///
    /// That separation is a fix, not a nicety. Until Task 6's review this set a single shared
    /// `Phase = .draining`, which also made `openInbound` answer every subsequent inbound
    /// `openStream` with `status(.unavailable)` -- one `goAway` op from a peer permanently stopped
    /// this connection accepting work, contradicting both `goAway`'s meaning and this comment.
    ///
    /// `lastStreamID` is read and discarded: this transport's ids are allocated by one side only,
    /// and the peer's own `status`/`cancel` ops are what actually end its streams, so there is
    /// nothing for a "fail everything above N" rule to do here. Contract line 8 asks only that
    /// ``openStream`` throw.
    private func peerBeganDraining() {
        registry.withLock { registry in
            if !registry.isClosed { registry.peerDraining = true }
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
    func failAll(_ error: RPCError) {
        var taken: [StreamEntry] = []
        var finishAccepted = false

        registry.withLock { registry in
            registry.isClosed = true
            taken = Array(registry.streams.values)
            registry.streams.removeAll()
            // No credit is owed to a peer that is gone, so the receive counters are simply
            // discarded rather than flushed; zeroing them keeps `outstandingAccepts` from being
            // driven negative by an item pulled out of the buffer after this teardown.
            registry.connectionUnconsumed = 0
            registry.outstandingAccepts = 0
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
    private func failConnection(_ error: RPCError) {
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

    mutating func encode(_ part: Part) throws(RPCError) -> [RPCOp]
    mutating func finish() throws(RPCError) -> [RPCOp]
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
    mutating func finish() throws(RPCError) -> [RPCOp] { [] }
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
/// first part), so encode order **is** this stream's wire order. Encoding under a lock and sending
/// outside it would let two concurrent writes swap on the way to the pipe and put a `message` ahead
/// of the `metadata` that must precede it. `pipe.send` is synchronous and does not block on the
/// peer, so holding the lock across it costs a short critical section and buys the ordering
/// outright. Credit, which *does* suspend, is acquired before the lock is taken.
///
/// **``finish()`` obeys this too, and did not always.** It used to encode under the lock and send
/// after releasing it -- the exact shape this section forbids -- so a `write` racing a `finish`
/// could put a `message` on the wire *after* the `halfClose` that the encoder had already placed
/// before it, which is a §O2 grammar violation the peer would fail the stream for. Both methods now
/// submit inside the lock; only `localDirectionDidClose` is deferred past it, because that call can
/// retire the stream and finish continuations (L7).
///
/// # Why there is an `isDead` flag
///
/// `RequestOpEncoder`/`ResponseOpEncoder` **trap** (`precondition`) if called again after one of
/// their calls threw -- their "once thrown, this instance is dead" contract. grpc-swift does call
/// `finish()` on a writer whose `write` has already failed, so without this flag an ordinary
/// grammar error would become a process trap. Once dead, `write` throws without touching the
/// encoder and `finish()` is a no-op.
///
/// It carries a second class of death, added later: a stream that has been **removed from the
/// registry** under the writer. That refusal is now made by `RPCTransportCore.send(_:forStream:)`
/// itself, *inside* the submission lock, rather than by a separate question asked before the send
/// -- see that function for why the separate question could not close the window. A refusal is
/// permanent for this instance either way: nothing reached the wire, but the encoder's position has
/// moved, so this writer can no longer produce a well-formed continuation of the stream.
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
        // hand-inlined clamp.
        //
        // Since §O4's floor, `charge` is `>= 1` for **every** message, including a zero-length one
        // (`google.protobuf.Empty`), so the `charge > 0` test below is "is this part
        // flow-controlled?" and nothing else. It is not a residual guard against
        // `reserve(upTo:)`'s "at least 1 byte" precondition: that precondition is now unreachable
        // from here by construction, and the branch exists solely to send control parts straight
        // through.
        let charge: Int
        if let payload = Encoder.messagePayload(of: element) {
            charge = FlowControl.charge(for: payload.count)
        } else {
            charge = 0
        }
        var reserved: FlowControlWindow?
        if charge > 0 {
            reserved = try await core.reserveOutboundWindow(charge, forStream: streamID)
        }

        do {
            try state.withLock { state in
                guard !state.isDead else { throw streamDead() }
                do {
                    // The stream may have been retired while this write was queued behind the lock
                    // or parked on credit -- a fired deadline, a peer `cancel`, a teardown. Sending
                    // anyway is not merely futile: on the *first* write it would put the deferred
                    // `openStream` on the wire behind the `cancel` the removal sent, and open a
                    // stream on the peer that nothing will ever close. `send(_:forStream:)` refuses
                    // it, atomically with the submission -- which is what asking beforehand could
                    // not be. See that function.
                    try core.send(state.encoder.encode(element), forStream: streamID)
                } catch {
                    // Either the grammar was violated, or the stream is gone, or the op never
                    // reached the wire; the encoder's position has moved in every case, so this
                    // instance is finished.
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
    ///
    /// The encode **and** the submission happen inside the encoder lock, exactly as in
    /// ``write(_:)``: this method used to encode under the lock and send after releasing it, which
    /// is the one shape the type's doc comment forbids -- see it for the reordering that allowed.
    func finish() async {
        guard let core else { return }

        // Same refusal as `write(_:)`, and for the same reason: `finish()` on a request that never
        // wrote anything emits the deferred `openStream` alongside `halfClose`, so a retired stream
        // must not be opened here either. Silent, because this method has no caller to report to.
        //
        // Control ops: no flow control (§O4), so a starved stream can still be closed.
        let closedLocalDirection = state.withLock { state -> Bool in
            guard !state.isDead else { return false }
            do {
                try core.send(state.encoder.finish(), forStream: streamID)
                return true
            } catch {
                state.isDead = true
                return false
            }
        }

        // Outside the lock: this can retire the stream, which finishes continuations (L7).
        if closedLocalDirection, Encoder.finishClosesLocalDirection {
            core.localDirectionDidClose(streamID)
        }
    }

    /// Aborts the stream. Never touches the encoder (it may already be dead, and there is no
    /// `RPCOp` for "the local side failed" other than `cancel`), so this is always safe to call.
    func finish(throwing error: any Error) async {
        state.withLock { $0.isDead = true }
        // `cancelStream` bounds the reason before it reaches the wire; `error` can be an `RPCError`
        // whose `cause` chain carries peer-supplied field bytes.
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

// ===========================================================================================
// MARK: - The accepted-stream sequence (§O5 deviation 6's second counter)
// ===========================================================================================

/// `RPCTransportCore.acceptedStreams`, wrapping the raw `AsyncStream` so that pulling an item is
/// what releases its slot against `RPCTransportCore.maxConcurrentInboundStreams`.
///
/// # Why a wrapper rather than the bare `AsyncStream`
///
/// A table-only cap bounds nothing. `removeStream` is reachable while the `AcceptedRPCStream` is
/// still sitting undrained in the buffer, and one blob carrying `openStream(id) ; cancel(id)` does
/// exactly that inside a single routing turn: insert, yield, remove. The table returns to its
/// previous size and the buffer grows by one, for about sixty wire bytes; repeat with 3, 5, 7… and
/// the cap never engages. Counting the yield and discounting it at the *pull* is what makes the
/// cap mean what its doc comment claims.
///
/// The decrement point has to be here and not anywhere in the core, because the pull is the only
/// moment the value has provably left the core's buffer. This is the same shape ``CreditingInbound``
/// uses to credit a message when the application takes it, for the same reason.
///
/// # What it deliberately does not do
///
/// It does not bound, drop or reorder anything: L5's one-phase accept is untouched, and no accepted
/// stream is ever discarded. Backpressure on accepts is applied at admission (a refusal the peer
/// can see), never by throwing away a stream that was already built.
///
/// `onDeliver` holds the core weakly (L6) -- the closure the core passes in captures `[weak self]`.
/// Iterate once, as with any `AsyncStream`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct AcceptedStreamSequence: AsyncSequence, Sendable {
    typealias Element = AcceptedRPCStream
    typealias Failure = Never

    private let base: AsyncStream<AcceptedRPCStream>
    private let onDeliver: @Sendable () -> Void

    init(base: AsyncStream<AcceptedRPCStream>, onDeliver: @escaping @Sendable () -> Void) {
        self.base = base
        self.onDeliver = onDeliver
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), onDeliver: onDeliver)
    }

    struct Iterator: AsyncIteratorProtocol {
        fileprivate var base: AsyncStream<AcceptedRPCStream>.AsyncIterator
        fileprivate let onDeliver: @Sendable () -> Void

        /// The slot is released **after** the element has been handed over, so an accept loop that
        /// never comes back for the next one has still released the one it took.
        mutating func next(isolation actor: isolated (any Actor)?) async -> AcceptedRPCStream? {
            let element = await base.next(isolation: `actor`)
            if element != nil { onDeliver() }
            return element
        }

        mutating func next() async -> AcceptedRPCStream? {
            await next(isolation: nil)
        }
    }
}
