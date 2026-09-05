import Dispatch
import GRPCCore

// ===========================================================================================
// MARK: - Field lists
// ===========================================================================================

/// A wire-level header field name/value pair. Shared by name across the module (`GRPCWireHeaders`
/// builds these from gRPC metadata; `CompactWireCodec` encodes and decodes them) --
/// `(String, String)` and `(name: String, value: String)` are structurally the same tuple type,
/// but the labels are what let call sites write `field.name` / `field.value` instead of `.0` /
/// `.1`.
///
/// Lives here, not beside a codec, because it is the op model's own vocabulary: `RPCOp.metadata`
/// and `RPCOp.status` carry field lists whether or not any particular `WireCodec` exists yet.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
typealias HTTPField = (name: String, value: String)

// ===========================================================================================
// MARK: - Stream identity
// ===========================================================================================

/// Identifies one RPC's stream of ops. Client-allocated, odd, monotonically increasing --
/// mirrors HTTP/2's client-initiated stream IDs without being one.
///
/// **Deliberately not named `StreamID`.** The legacy custom-protocol stack this plan replaced
/// owned that name for its own, differently sized identifier, and stayed compiling alongside this
/// file until Task 7 deleted it (`XPCFrame.swift`). `RPCStreamID` avoided the collision then and
/// needed no rename at the swap.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
typealias RPCStreamID = UInt32

// ===========================================================================================
// MARK: - The op model
// ===========================================================================================

/// One gRPC stream operation. This is a sum type on purpose: an op stream is genuinely a tagged
/// union — a struct with seven mutually-exclusive optional fields would be worse, not simpler —
/// and every case below maps to exactly one operation in gRPC core's own op list. Nothing here is
/// invented vocabulary:
///
/// - `openStream` + `metadata` = `send_initial_metadata`
/// - `message` = `send_message` (received/sent, either direction)
/// - `halfClose` = the client's `send_trailing_metadata` (gRPC's half-close signal)
/// - `status` = the server's `send_trailing_metadata` (the final status; terminal)
/// - `cancel` = `cancel_stream`
/// - `credit` and `goAway` are transport-level control, the equivalent of what HTTP/2 spends
///   WINDOW_UPDATE and GOAWAY on — gRPC core's own docs describe this class of op as "operations
///   like pings and statistics that shape transport-level characteristics like flow control."
///
/// **A `message` op carries one whole message.** Unlike HTTP/2, where DATA frames are arbitrary
/// byte ranges and gRPC must add its Length-Prefixed-Message envelope to find message boundaries,
/// an op substrate already delimits — so no `WireCodec` here should add an LPM prefix "for
/// standardness."
///
/// See the per-stream grammar (a stream's ops must arrive as `openStream → metadata? → message* →
/// halfClose` outbound and `metadata? → message* → status` inbound) documented where the core's
/// state machine enforces it — this type only carries the vocabulary, not the rule.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum RPCOp: Sendable {
    /// Client: initial metadata plus the method path. Opens the stream.
    case openStream(RPCStreamID, method: String, timeout: Duration?)
    /// Leading metadata, either direction.
    case metadata(RPCStreamID, fields: [HTTPField])
    /// One whole message, already delimited by this op — no length prefix needed or added.
    case message(RPCStreamID, payload: GRPCSwiftData)
    /// Client: no more messages will be sent on this stream.
    case halfClose(RPCStreamID)
    /// Server: the final status. Terminal — nothing else follows on this stream's response
    /// direction.
    case status(RPCStreamID, code: Int, message: String, trailers: [HTTPField])
    /// Either side aborts one stream.
    case cancel(RPCStreamID, reason: String)
    /// Flow-control replenishment. `streamID == 0` means the connection window, not any stream.
    case credit(RPCStreamID, bytes: UInt32)
    /// Drain signal: no new streams above `lastStreamID` will be accepted.
    case goAway(lastStreamID: RPCStreamID)
}

// ===========================================================================================
// MARK: - Per-op decode results (§O2)
// ===========================================================================================

/// One entry in a decoded blob. §O2 (as amended): `decode(_:)` parses each op's 10-byte header --
/// including its stream id -- before it ever touches the body, so a body-level rejection can
/// always name the stream it belongs to. `WireCodec.decode(_:)` returns an array of these instead
/// of `[RPCOp]` directly so that a body this codec rejects can surface naming that stream, rather
/// than as a thrown error that would hand the core nothing to fail but the whole connection --
/// exactly the hole §O2's amendment closes (a malformed `:path`, a stray-metadata `openStream`,
/// and a non-empty `halfClose` body were each found killing every other stream on the connection).
///
/// Three cases, not the "two, not three" this type started with -- §O2's review found that flat,
/// and split `openStream` out on purpose; see `.streamOpenFailure`'s doc for why it cannot share
/// `.streamFailure`'s silence. What stayed rejected is a *separate failures array*: it would lose
/// each failure's position relative to the ops around it, and the core has to see a stream's
/// failure at the position it occurred -- not batched at the end -- to keep per-connection
/// ordering meaningful. Stopping at the first failure was also rejected: it would hand a hostile
/// peer a cheap truncation lever, since appending one malformed op to a blob would silently
/// discard every op after it, including other streams' legitimate traffic. So `decode(_:)` is
/// skip-and-continue: a rejected op's own header already gave up its `bodyLength`, and the framing
/// stays intact past it, so the codec advances past the rejected body exactly as it already
/// advances past a body whose `kind` it doesn't recognise (§O3's unknown-kind skip), and keeps
/// decoding.
///
/// A **header**-level failure -- a truncated 10-byte header, or a declared body length over the
/// 16 MiB cap or past the bytes actually remaining -- has no representation here: `decode(_:)`
/// still `throw`s for those, unchanged. The header carrying the stream id is the thing that failed
/// to parse, so there is no id to attribute a failure to and no framing left to resynchronise to.
/// A malformed `goAway` body also still `throw`s, by deliberate carve-out (§O2): `goAway` has no
/// stream to fail either, and unlike a header failure this one *could* have kept the decoded
/// prefix, but does not need to -- `failConnection` fails every live stream in the same
/// synchronous call regardless of decode order, so nothing the prefix could have delivered would
/// have survived that call anyway. See `CompactWireCodec.decode(_:)`'s doc for the full argument.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum WireDecodeItem: Sendable {
    /// One op that decoded cleanly.
    case op(RPCOp)
    /// One op whose body this codec rejected, for a kind that never creates state **and is exempt
    /// from flow control**. The `RPCStreamID` comes from the op's own header -- decoded before the
    /// body ever was -- so it is trustworthy even though the body was not.
    ///
    /// **A `message` may not be surfaced here.** This case carries an id and an error and nothing
    /// else -- no kind, no body length -- so the core cannot charge or credit the receive window
    /// for it, and a `message` rejected this way would leak the peer's connection window by its
    /// full charge, permanently. See ``WireCodec``'s conservation requirement for the whole
    /// argument; it is a conformer obligation, and it is not checkable from this payload.
    ///
    /// **A `cancel` op is sent only if `id` names a live stream; otherwise this is silently
    /// dropped.** Both outcomes go through the same removal path a state-machine grammar violation
    /// already uses, and that path already no-ops when there is nothing to remove -- so "does this
    /// id have a table entry" is the only thing that decides which happens, not the kind that
    /// failed. An id with no entry is one of three things: a rejected `.streamOpenFailure` for
    /// some *other* op in the same blob (that kind is handled separately -- see below), the
    /// entirely ordinary race where a legitimate stream was just retired while this op was in
    /// flight, or a forgery -- a peer-chosen id that was never legitimately opened. The core cannot
    /// tell any of those apart, and answering would hand the peer a 1:1 amplification lever for
    /// the price of a single small malformed op regardless of which one it actually was, so all
    /// three stay silent. An id *with* an entry is failed and removed exactly like a grammar
    /// violation; any later op addressed to it then hits the ordinary unknown-stream drop, because
    /// the core has already removed it.
    case streamFailure(RPCStreamID, RPCError)
    /// An `openStream` op whose body this codec rejected. Split out from `.streamFailure` because
    /// `openStream` is the one kind whose semantics *create* state (§O2): the id belongs to the
    /// peer the moment it sends this op, and the peer is definitionally waiting on a reply for it
    /// -- unlike every other kind, where a made-up id might just be an ordinary retirement race,
    /// here there is no such id, and silence would hang the peer to its own deadline for free.
    ///
    /// The core answers with a **fixed literal** `status` -- never the decode error's own text --
    /// because the error can embed up to 16 MiB of peer-chosen bytes (a malformed `:path`, a
    /// malformed `-bin` value): echoing it turns a ~12-byte malformed `openStream` into hundreds of
    /// bytes out, repeatable forever at zero state cost, since rejecting it never creates a table
    /// entry to bound the peer's attempts by (contrast `resourceExhausted`, reachable only after
    /// the peer has paid for a full complement of admitted streams). **The `RPCError` this case
    /// carries is not consulted by the core at all today** -- there is no table entry, no
    /// continuation and no diagnostic-logging facility here for it to reach, so `refuseOpen(_:
    /// dueTo:)` reads only `id` and discards `error` after choosing the fixed literal. It stays in
    /// the case's payload anyway, matching `.streamFailure`'s shape, so a future diagnostic hook
    /// (local logging, a metrics counter keyed on rejection reason) has something to read without
    /// this type needing to change again to grow one.
    case streamOpenFailure(RPCStreamID, RPCError)
}

// ===========================================================================================
// MARK: - The wire-encoding seam
// ===========================================================================================

/// Turns batches of ops into bytes and back. This is the seam a byte-stream encoding (a future
/// HTTP/2 framing, say) would plug into instead of the compact encoding this plan ships first.
///
/// Batching is the codec's business, not the core's: a conformer takes and returns arrays because
/// one XPC message may carry several ops concatenated into a single blob, and only the codec
/// knows how its own framing marks where one op ends and the next begins.
///
/// # Requirement: a flow-controlled op may not be surfaced as a stream failure
///
/// **A `message` op whose header parses must be delivered as `.op`, or the whole `decode(_:)` call
/// must throw. It may never be surfaced as `.streamFailure`.** Same for any future flow-controlled
/// kind. This is a conformer obligation, not an implementation detail of the codec that ships
/// first, and it is the one place where the seam's freedom to reject a body collides with §O4's
/// receive-window conservation.
///
/// The mechanism, stated once so a conformer author does not have to reconstruct it:
/// `RPCTransportCore.deliver(_:toStream:)` records a `message`'s charge against **both** receive
/// windows *before* the state machine sees the op -- bytes the peer spent are owed back whether or
/// not the op turns out to be legal -- and the credit for them is emitted when the message is
/// consumed. The `.streamFailure` path records nothing and credits nothing: the item carries a
/// stream id and an `RPCError`, and the core has no payload to derive a charge from, because the
/// body it would measure is the body this codec just refused to hand over. So a codec that rejected
/// a `message` **body** -- a bad compression envelope, a failed checksum -- would silently leak the
/// peer's *connection* window by the full charge, on every rejection, permanently: the peer keeps
/// deducting, this side never credits back, and the connection wedges once the arrears reach 65 535
/// bytes. Every other stream on it stops with it.
///
/// Only the codec knows the body length the window was charged for, which is why the rule has to
/// live here rather than being enforced downstream. A codec that *can* reject a `message` body must
/// throw, which fails the connection -- a loud, immediate, correctly-attributed death instead of a
/// slow wedge. Rejecting a body of a kind that is exempt from flow control (`metadata`, `halfClose`,
/// `status`, `cancel`, `credit`) is what `.streamFailure` is for and stays fine, and `openStream`
/// has its own case.
///
/// True by accident today: `CompactWireCodec` treats a `message` body as opaque bytes, so kind 3
/// has no body-level rejection to make. That is a property of one conformer, not of the seam, and
/// it is exactly the kind of accident that stops being true the first time someone adds framing.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
protocol WireCodec: Sendable {
    /// Encodes one or more ops into a single blob. The inverse of `decode(_:)`.
    func encode(_ ops: [RPCOp]) throws(RPCError) -> GRPCSwiftData
    /// Decodes a blob produced by `encode(_:)` (this conformer's own, or a wire-compatible peer's)
    /// back into the items it carries, in the order they were encoded -- see `WireDecodeItem` for
    /// why an item, not always an `RPCOp`.
    ///
    /// - Important: a `message` op whose header parses must come back as `.op` or throw -- never as
    ///   `.streamFailure`. See the conservation requirement on the protocol itself; the receive
    ///   window has already been charged for a body only this codec can measure.
    ///
    /// - Throws: for a **header-level** failure (truncated framing, or a declared body length
    ///   this codec cannot trust) -- those leave no stream id to name and no framing left to
    ///   resynchronise past -- and, by §O2's carve-out, for a malformed `goAway` body, which has
    ///   no stream to name either even though the framing around it is fine. See
    ///   `WireDecodeItem`'s doc for why every other kind's body-level rejection does not throw.
    ///   A rejectable `message` body joins this list, for the conservation reason above.
    func decode(_ blob: GRPCSwiftData) throws(RPCError) -> [WireDecodeItem]
}

// ===========================================================================================
// MARK: - The substrate seam
// ===========================================================================================

/// Moves opaque blobs between peers. This is the seam an XPC-backed conformer plugs into; nothing
/// in this file, or in anything built on `RPCOp`, may assume XPC is on the other side of it.
///
/// A `MessagePipe` carries bytes, not ops — `WireCodec` is what gives those bytes meaning. The two
/// seams compose: a blob handed to `send(_:)` is whatever the paired `WireCodec` produced, and a
/// blob delivered to the `onReceive` handler is what that codec's `decode(_:)` expects.
///
/// **Ordering and delivery are contractual, not incidental.** A conformer MUST deliver blobs to
/// the `onReceive` handler in the same order they were handed to the peer's `send(_:)` — there is
/// no sequence number anywhere in the op model, because the core's per-stream state machines are
/// serial and assume in-order delivery outright (O2's grammar has no way to re-sequence an
/// out-of-order `message` against the `metadata`/`status` around it). A conformer MUST also invoke
/// every handler — `onReceive`'s and `onPeerDeath`'s — on `queue`, and only on `queue`: the core
/// schedules its own work against that same serial queue and correctness depends on delivery and
/// core processing never interleaving from two different queues. A substrate that cannot promise
/// either property needs a sequencing adapter in front of it before it can conform here; weakening
/// this contract to fit such a substrate would just move the bug into the core.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
protocol MessagePipe: Sendable {
    /// All delivery — every `onReceive` and `onPeerDeath` invocation — happens serially on this
    /// queue. See the protocol's ordering contract above.
    var queue: DispatchSerialQueue { get }

    /// Hands one blob to the peer. Conformers queue or block as appropriate to their substrate;
    /// callers may call this from any queue.
    func send(_ blob: GRPCSwiftData) throws(RPCError)

    /// Registers the handler that receives blobs from the peer, in send order, on `queue`. Set
    /// once, before the pipe is activated — a conformer is not required to support replacing or
    /// removing the handler afterward.
    func onReceive(_ handler: @escaping @Sendable (GRPCSwiftData) -> Void)

    /// Registers the handler invoked, on `queue`, if the peer process goes away. A conformer with
    /// no way to detect peer death simply never calls this handler.
    func onPeerDeath(_ handler: @escaping @Sendable () -> Void)

    /// Tears the pipe down from this side. Idempotent.
    func cancel()
}
