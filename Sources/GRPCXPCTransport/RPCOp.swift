import Dispatch

// ===========================================================================================
// MARK: - Field lists
// ===========================================================================================

/// A wire-level header field name/value pair. Shared by name across the module (`GRPCWireHeaders`
/// builds these from gRPC metadata; a future `WireCodec` consumes the decoded form) --
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
/// **Deliberately not named `StreamID`.** `Sources/GRPCXPCTransport/XPCFrame.swift` (the legacy
/// custom-protocol stack this plan replaces) already owns that name for its own, differently
/// sized identifier, and stays compiling until the swap task deletes it. `RPCStreamID` avoids the
/// collision now and needs no rename later.
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
// MARK: - The wire-encoding seam
// ===========================================================================================

/// Turns batches of ops into bytes and back. This is the seam a byte-stream encoding (a future
/// HTTP/2 framing, say) would plug into instead of the compact encoding this plan ships first.
///
/// Batching is the codec's business, not the core's: a conformer takes and returns arrays because
/// one XPC message may carry several ops concatenated into a single blob, and only the codec
/// knows how its own framing marks where one op ends and the next begins.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
protocol WireCodec: Sendable {
    /// Encodes one or more ops into a single blob. The inverse of `decode(_:)`.
    func encode(_ ops: [RPCOp]) throws -> GRPCSwiftData
    /// Decodes a blob produced by `encode(_:)` (this conformer's own, or a wire-compatible peer's)
    /// back into the ops it carries, in the order they were encoded.
    func decode(_ blob: GRPCSwiftData) throws -> [RPCOp]
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
    func send(_ blob: GRPCSwiftData) throws

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
