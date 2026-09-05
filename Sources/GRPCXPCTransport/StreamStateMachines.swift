import GRPCCore

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

// Four per-stream state machines: the translation layer between grpc-swift's typed
// `RPCRequestPart`/`RPCResponsePart` and this transport's eight wire ops (`RPCOp`), and the
// place §O2's grammar is enforced --
//
// - Request direction: `openStream → metadata? → message* → halfClose`.
// - Response direction: `metadata? → message* → status`.
//
// `RequestOpDecoder` and `ResponseOpEncoder` run on the server (ops in / parts out for the
// client's request; parts in / ops out for the server's response). `RequestOpEncoder` and
// `ResponseOpDecoder` run on the client -- the exact mirror. Every one of the four is a small,
// explicit `struct`; per the plan's own note, a previous build's generic spelling ("one factory
// parameterized over direction and part/op") fought type inference and was abandoned, so this
// file writes the four out by hand instead, at the cost of some duplication between the two
// decoders and between the two encoders.
//
// Every violation fails only the stream it happened on (§O2): it throws
// `RPCError(code: .internalError, …)` naming the rule broken and what arrived instead -- never
// tears down the connection, never touches any other stream. An incoming `cancel` is likewise
// surfaced as a thrown error (`RPCError(code: .cancelled, …)`), not as a part, since neither
// `RPCRequestPart` nor `RPCResponsePart` has a case for it (ruling 3). The mux (Task 6) is what
// turns a thrown violation into an outbound `cancel` op and an incoming `cancel` into whatever
// local bookkeeping it needs -- this file only detects and reports, it never writes to a
// `MessagePipe` itself.
//
// `credit` and `goAway` are connection-level (§O4/§O5 via ruling 3): the mux never routes them
// to a stream, so a decoder receiving one is a *caller* bug, not peer input --
// `preconditionFailure`, not `RPCError`.
//
// L4 -- serial per stream. Every `accept(_:)`/`encode(_:)`/`finish()` here mutates `self` and
// assumes it is only ever called from the owning connection's single serial queue, one op or
// part at a time, in order -- see `MessagePipe`'s ordering contract in `RPCOp.swift`. None of
// these four types carries a lock; that is not an oversight, it is what "serial per stream"
// buys. Adding one would only hide a caller that broke the precondition instead of surfacing it.
//
// Once a call throws, that instance is dead. A thrown violation or an incoming `cancel` both
// terminate the stream; the mux must stop routing ops/parts to this instance afterward. Calling
// it again is a caller (Task 6) bug and traps via `precondition` -- distinct from, and layered
// on top of, the ordinary in-grammar violations these types report by throwing. A caller that
// mis-sequences its *own* ops/parts gets a proper `RPCError` describing the mistake; a caller
// that then ignores that error and calls again gets a hard trap instead of silently corrupting
// state that no longer means anything.

// ===========================================================================================
// MARK: - Shared: `Metadata` <-> the field list an RPCOp.metadata/status.trailers carries
// ===========================================================================================

// `Metadata` <-> the plain (no pseudo-header) field list an `RPCOp.metadata` op or an
// `RPCOp.status` op's `trailers` carries is `GRPCWireHeaders.userMetadataFields(_:)` /
// `.parseUserMetadata(_:)` -- called directly at each of the six sites below.
//
// A `MetadataFieldCoding` wrapper used to stand in front of those two calls. Its reason was that
// the four state machines went through `GRPCWireHeaders`' *response-direction* helpers, because
// `userMetadataFields`/`parseUserMetadata` were `private` -- and those helpers silently prepended
// `:status: 200` and a second `content-type` to every `metadata` op and every `status` op's
// trailers: 50 bytes of stray HTTP/2 pseudo-header on the wire (a §O3 violation -- this op model
// carries no HTTP/2 frames to have pseudo-headers on) that round-tripped away only because the
// decode side's reserved-name filter discarded them again. The fix was to widen
// `userMetadataFields`/`parseUserMetadata` to internal rather than re-derive their
// reserved-name/`-bin`/base64 logic here; the response-direction helpers were then deleted for
// having no callers left, and the wrapper became a pass-through forwarding to the very functions
// it existed to avoid. The note survives; the indirection does not. Do **not** reintroduce a
// direction-specific helper here -- that is the bug, not the wrapper.

// ===========================================================================================
// MARK: - RequestOpDecoder (server: ops → RPCRequestPart)
// ===========================================================================================

/// Decodes one request-direction stream's ops into `RPCRequestPart`s: §O2's server-inbound
/// grammar, `openStream → metadata? → message* → halfClose`.
///
/// **Construction *is* `openStream`.** `RPCOp.openStream` carries the method path and deadline,
/// not a `Metadata` value -- there is no `RPCRequestPart` it decodes to (ruling 1). The mux sees
/// `openStream` arrive and, in the same motion it decides "no stream exists yet for this ID,"
/// constructs this decoder with the method/timeout it just read; by the time any op reaches
/// `accept(_:)`, `openStream` has already happened. Any `RPCOp.openStream` handed to `accept(_:)`
/// after that is therefore definitionally a *second* `openStream` for this stream -- itself the
/// violation §O2 names, not a case this type has to special-case as "the first one, again."
///
/// **Synthesises the leading `.metadata` part (ruling 2).** grpc-swift's own server loop
/// (`ServerRPCExecutor._waitForFirstRequestPart`) requires the inbound sequence's first element
/// to be `.metadata`: a `.message` first is rejected as "received message bytes at start of
/// stream," and a sequence that ends with nothing at all is rejected as "empty inbound server
/// stream." §O2 nonetheless makes the wire's `metadata` op optional. Reconciling the two means
/// this type cannot forward ops 1:1 -- it holds in `.pendingMetadata` until it sees either a real
/// `metadata` op (emit it as-is) or the first op that *proves none is coming* (`message` or
/// `halfClose`), synthesising an empty `Metadata()` part in that case.
///
/// The corollary that makes this safe: the synthesised part is **not** emitted eagerly at
/// construction, on `openStream` itself. A real `metadata` op arriving next would then produce
/// two `.metadata` parts on the same stream -- exactly the violation `ServerRPCExecutor` guards
/// against on its side ("Server received an extra set of metadata"). Holding until the decision
/// is forced is what keeps the count at exactly one either way.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct RequestOpDecoder: Sendable {
    /// The method path from the `openStream` op that constructed this decoder -- `openStream` has
    /// no `RPCRequestPart` counterpart, so it surfaces here instead (ruling 1).
    let method: String
    /// The deadline from the same `openStream` op, if the client set one.
    let timeout: Duration?

    /// `true` once a legitimate `halfClose` has been processed: the client will send no more ops
    /// on this stream's request direction. This is *not* how the mux learns the stream failed --
    /// a violation or an incoming `cancel` also end the stream, but by throwing, not by setting
    /// this flag. The mux distinguishes the two by whether `accept(_:)` threw.
    private(set) var remoteEnded = false

    private enum Position {
        case pendingMetadata
        case open
        case halfClosed
    }

    private var position: Position = .pendingMetadata
    private var isFailed = false

    init(method: String, timeout: Duration?) {
        self.method = method
        self.timeout = timeout
    }

    /// Feeds one op to the decoder, returning the `RPCRequestPart`s it produces -- zero, one, or
    /// two; two only when this call also synthesises the leading metadata alongside the first
    /// message.
    ///
    /// - Throws: `RPCError(code: .internalError)` for a grammar violation, naming the rule broken
    ///   and what arrived instead; `RPCError(code: .cancelled)` if `op` is the peer's own
    ///   `cancel` (§O2: terminal in both directions).
    /// - Precondition: `op` is never `.credit`/`.goAway` (connection-level; a mux bug if routed
    ///   here) and this instance has not previously thrown (dead; a mux bug to call again).
    mutating func accept(_ op: RPCOp) throws(RPCError) -> [RPCRequestPart<GRPCDispatchDataPayload>] {
        precondition(
            !isFailed,
            "RequestOpDecoder.accept: called again after a previous call already threw; the "
                + "stream is dead and the mux must stop routing ops to it")

        switch op {
        case .credit, .goAway:
            preconditionFailure(
                "RequestOpDecoder.accept: \(op) is connection-level (§O2); the mux must never "
                    + "route it to a stream's decoder")

        case .cancel(_, let reason):
            isFailed = true
            throw RPCError(code: .cancelled, message: "peer cancelled the stream: \(reason)")

        case .openStream:
            try fail("received a second 'openStream'; this stream already opened via construction")

        case .status:
            try fail("received a 'status' op, which is response-direction only")

        case .metadata(_, let fields):
            switch position {
            case .pendingMetadata:
                let metadata = try decodeMetadata(fields)
                position = .open
                return [.metadata(metadata)]
            case .open:
                try fail("received a second 'metadata' op; metadata may appear only once, before the first message")
            case .halfClosed:
                try fail("received 'metadata' after 'halfClose'")
            }

        case .message(_, let payload):
            switch position {
            case .pendingMetadata:
                position = .open
                return [.metadata(Metadata()), .message(payload)]
            case .open:
                return [.message(payload)]
            case .halfClosed:
                try fail("received 'message' after 'halfClose'")
            }

        case .halfClose:
            switch position {
            case .pendingMetadata:
                position = .halfClosed
                remoteEnded = true
                return [.metadata(Metadata())]
            case .open:
                position = .halfClosed
                remoteEnded = true
                return []
            case .halfClosed:
                try fail("received a second 'halfClose'")
            }
        }
    }

    /// Converts a `metadata` op's field list to `Metadata`, routing a malformed field list (e.g.
    /// bad `-bin` base64) through `fail(_:)` rather than letting `GRPCWireHeaders`' own thrown
    /// `RPCError` (`.invalidArgument`) escape directly -- §O2 says every violation surfaced by
    /// this type is `.internalError`, and `position` must not have already advanced past
    /// `.pendingMetadata` by the time that error is thrown (see `fail(_:)`'s "once thrown, dead"
    /// contract in the file overview).
    private mutating func decodeMetadata(_ fields: [HTTPField]) throws(RPCError) -> Metadata {
        do {
            return try GRPCWireHeaders.parseUserMetadata(fields)
        } catch {
            try fail("malformed metadata field list", error: error)
        }
    }
    
    /// Fails this stream: marks the decoder terminal and throws. Every violation in this type
    /// routes through here, so the message shape (rule broken; what arrived) stays consistent --
    /// see the type's doc comment for why a violation fails only this stream.
    private mutating func fail(_ reason: String, error:any Error) throws(RPCError) -> Never {
        isFailed = true
        throw RPCError(code: .internalError, message: "RequestOpDecoder: \(reason)", cause: error)
    }

    /// Fails this stream: marks the decoder terminal and throws. Every violation in this type
    /// routes through here, so the message shape (rule broken; what arrived) stays consistent --
    /// see the type's doc comment for why a violation fails only this stream.
    private mutating func fail(_ reason: String) throws(RPCError) -> Never {
        isFailed = true
        throw RPCError(code: .internalError, message: "RequestOpDecoder: \(reason)")
    }
}

// ===========================================================================================
// MARK: - RequestOpEncoder (client: RPCRequestPart → ops)
// ===========================================================================================

/// Encodes one request-direction stream's `RPCRequestPart`s into ops: §O2's client-outbound
/// grammar, `openStream → metadata? → message* → halfClose`.
///
/// **Emits `openStream` itself, on the first call.** Unlike the decoder, this type is
/// constructed *before* the stream opens (the mux allocates a stream ID and builds this encoder
/// to start a call) -- so it is this type's job, not the mux's, to prepend `openStream` to
/// whatever the first `encode(_:)` or `finish()` call produces.
///
/// **No synthesis needed on this side.** grpc-swift's `ClientStreamExecutor._processRequest`
/// unconditionally writes `.metadata(request.metadata)` before running the message producer, so
/// in practice `encode(_:)` never sees `.message` before `.metadata`. The `.message`-first branch
/// below still exists and is still correct (§O2 makes `metadata` optional, and the peer's
/// `RequestOpDecoder` already synthesises on its side per ruling 2) -- it is exercised only if a
/// future caller of this encoder does not go through `ClientStreamExecutor`.
///
/// **`finish()` stands in for `RPCRequestPart`'s missing terminator.** `RPCRequestPart` has no
/// case for "no more messages" -- that signal is `RPCWriter.Closable.finish()` on grpc-swift's
/// side, which the mux must translate into a call to `finish()` here to produce the wire's
/// `halfClose` op (and, if this stream never wrote anything at all, the deferred `openStream` as
/// well -- an immediately-closed request still has to open before it can close).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct RequestOpEncoder: Sendable {
    let streamID: RPCStreamID
    let method: String
    let timeout: Duration?

    private enum Position {
        case beforeOpen
        case open
        case finished
    }

    private var position: Position = .beforeOpen
    private var isFailed = false

    init(streamID: RPCStreamID, method: String, timeout: Duration?) {
        self.streamID = streamID
        self.method = method
        self.timeout = timeout
    }

    /// Encodes one `RPCRequestPart`, returning the op(s) it produces -- one, or two on the very
    /// first call (`openStream` prepended alongside whatever `part` itself becomes).
    ///
    /// - Throws: `RPCError(code: .internalError)` if `part` arrives out of grammar order (a
    ///   second `.metadata`, or anything after `finish()`).
    /// - Precondition: this instance has not previously thrown (dead; a caller bug to call
    ///   again).
    mutating func encode(_ part: RPCRequestPart<GRPCDispatchDataPayload>) throws(RPCError) -> [RPCOp] {
        precondition(
            !isFailed,
            "RequestOpEncoder.encode: called again after a previous call already threw; the "
                + "stream is dead and the caller must stop writing to it")

        switch part {
        case .metadata(let metadata):
            switch position {
            case .beforeOpen:
                position = .open
                return [openStreamOp(), .metadata(streamID, fields: GRPCWireHeaders.userMetadataFields(metadata))]
            case .open:
                try fail("received a second 'metadata' part; only one may be sent per stream")
            case .finished:
                try fail("received 'metadata' after finish() (halfClose already sent)")
            }

        case .message(let payload):
            switch position {
            case .beforeOpen:
                position = .open
                return [openStreamOp(), .message(streamID, payload: payload)]
            case .open:
                return [.message(streamID, payload: payload)]
            case .finished:
                try fail("received 'message' after finish() (halfClose already sent)")
            }
        }
    }

    /// Ends the request direction: emits `halfClose`, plus the deferred `openStream` if this
    /// stream never wrote anything before finishing.
    ///
    /// - Throws: `RPCError(code: .internalError)` if called a second time.
    mutating func finish() throws(RPCError) -> [RPCOp] {
        precondition(
            !isFailed,
            "RequestOpEncoder.finish: called again after a previous call already threw; the "
                + "stream is dead and the caller must stop writing to it")

        switch position {
        case .beforeOpen:
            position = .finished
            return [openStreamOp(), .halfClose(streamID)]
        case .open:
            position = .finished
            return [.halfClose(streamID)]
        case .finished:
            try fail("finish() called twice")
        }
    }

    private func openStreamOp() -> RPCOp {
        .openStream(streamID, method: method, timeout: timeout)
    }

    private mutating func fail(_ reason: String) throws(RPCError) -> Never {
        isFailed = true
        throw RPCError(code: .internalError, message: "RequestOpEncoder(stream \(streamID)): \(reason)")
    }
}

// ===========================================================================================
// MARK: - ResponseOpEncoder (server: RPCResponsePart → ops)
// ===========================================================================================

/// Encodes one response-direction stream's `RPCResponsePart`s into ops: §O2's server-outbound
/// grammar, `metadata? → message* → status`.
///
/// **Synthesises the leading `.metadata` op if a message arrives first.** Symmetric to
/// `RequestOpDecoder`'s synthesis, but on the encode side this time: grpc-swift's client
/// (`ClientStreamExecutor._waitForFirstResponsePart`) rejects `.message` as the first response
/// part ("expected metadata"), but *does* accept `.status` as a valid first part (an immediate
/// rejection with no metadata at all is a normal, spec-legal shape -- `ServerRPCExecutor`'s own
/// failure path writes `.status` with nothing before it). So the synthesis rule here is narrower
/// than the decoder's: only `.message` before any `.metadata` forces synthesis; `.status` before
/// any `.metadata` does not, because the peer's `ResponseOpDecoder` does not need it (there is no
/// "empty response stream" error on that side the way there is an "empty request stream" one).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct ResponseOpEncoder: Sendable {
    let streamID: RPCStreamID

    private enum Position {
        case beforeMetadata
        case open
        case afterStatus
    }

    private var position: Position = .beforeMetadata
    private var isFailed = false

    init(streamID: RPCStreamID) {
        self.streamID = streamID
    }

    /// Encodes one `RPCResponsePart`, returning the op(s) it produces -- one, or two when this
    /// call also synthesises the leading metadata alongside the first message.
    ///
    /// - Throws: `RPCError(code: .internalError)` if `part` arrives out of grammar order (a
    ///   second `.metadata`, or anything after `.status` -- §O2: "status is the single
    ///   terminator; a second terminal, or a message after it, is a violation").
    /// - Precondition: this instance has not previously thrown (dead; a caller bug to call
    ///   again).
    mutating func encode(_ part: RPCResponsePart<GRPCDispatchDataPayload>) throws(RPCError) -> [RPCOp] {
        precondition(
            !isFailed,
            "ResponseOpEncoder.encode: called again after a previous call already threw; the "
                + "stream is dead and the caller must stop writing to it")

        switch part {
        case .metadata(let metadata):
            switch position {
            case .beforeMetadata:
                position = .open
                return [.metadata(streamID, fields: GRPCWireHeaders.userMetadataFields(metadata))]
            case .open:
                try fail("received a second 'metadata' part; only one may be sent per stream")
            case .afterStatus:
                try fail("received 'metadata' after 'status'; status is the terminal part")
            }

        case .message(let payload):
            switch position {
            case .beforeMetadata:
                position = .open
                return [
                    .metadata(streamID, fields: GRPCWireHeaders.userMetadataFields(Metadata())),
                    .message(streamID, payload: payload),
                ]
            case .open:
                return [.message(streamID, payload: payload)]
            case .afterStatus:
                try fail("received 'message' after 'status'; status is the terminal part")
            }

        case .status(let status, let metadata):
            switch position {
            case .beforeMetadata, .open:
                position = .afterStatus
                return [
                    .status(
                        streamID, code: status.code.rawValue, message: status.message,
                        trailers: GRPCWireHeaders.userMetadataFields(metadata))
                ]
            case .afterStatus:
                try fail("received a second 'status'; status is the single terminator")
            }
        }
    }

    private mutating func fail(_ reason: String) throws(RPCError) -> Never {
        isFailed = true
        throw RPCError(code: .internalError, message: "ResponseOpEncoder(stream \(streamID)): \(reason)")
    }
}

// ===========================================================================================
// MARK: - ResponseOpDecoder (client: ops → RPCResponsePart)
// ===========================================================================================

/// Decodes one response-direction stream's ops into `RPCResponsePart`s: §O2's client-inbound
/// grammar, `metadata? → message* → status`. `.status` is itself the terminal signal -- once it
/// is decoded, the mux knows the response direction is done without this type needing a separate
/// flag the way `RequestOpDecoder.remoteEnded` is one (there is no `RPCResponsePart` case a
/// terminating `halfClose`-equivalent could be missing here; `status` already *is* that case).
///
/// **Synthesises leading metadata on `.message`, but not on `.status` -- an asymmetric rule,
/// deliberately.** grpc-swift's client (`ClientStreamExecutor._waitForFirstResponsePart`) accepts
/// *either* `.metadata` or `.status` as a valid first response part, but rejects a bare
/// `.message` as its first part ("expected metadata... likely to be a transport-specific bug").
/// §O2 makes response-direction `metadata` optional, so a `.message`-first response is spec-legal
/// *input* even though this transport's own `ResponseOpEncoder` never produces that shape on the
/// wire (it already synthesises on its side). Trusting that "only our own encoder ever writes
/// these ops" was tried and rejected on review -- this decoder does not get to assume the peer
/// behaved, only that the grammar was followed, and §O2's grammar permits a bare `.message`
/// first. So: `.message` before any `.metadata` synthesises an empty one, exactly like
/// `RequestOpDecoder`. `.status` before any `.metadata` does **not** synthesise -- the client
/// tolerates that shape directly, so there is nothing on the consuming side that needs it.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct ResponseOpDecoder: Sendable {
    private enum Position {
        case pending
        case open
        case afterStatus
    }

    private var position: Position = .pending
    private var isFailed = false

    init() {}

    /// Feeds one op to the decoder, returning the `RPCResponsePart` it produces.
    ///
    /// - Throws: `RPCError(code: .internalError)` for a grammar violation, naming the rule broken
    ///   and what arrived instead; `RPCError(code: .cancelled)` if `op` is the peer's own
    ///   `cancel` (§O2: terminal in both directions). A `status` op whose `code` is not a known
    ///   `Status.Code` is **not** among them -- it decodes to `.unknown`, per gRPC's rule for an
    ///   unrecognized status code (see the `.status` case).
    /// - Precondition: `op` is never `.credit`/`.goAway` (connection-level; a mux bug if routed
    ///   here) and this instance has not previously thrown (dead; a mux bug to call again).
    mutating func accept(_ op: RPCOp) throws(RPCError) -> [RPCResponsePart<GRPCDispatchDataPayload>] {
        precondition(
            !isFailed,
            "ResponseOpDecoder.accept: called again after a previous call already threw; the "
                + "stream is dead and the mux must stop routing ops to it")

        switch op {
        case .credit, .goAway:
            preconditionFailure(
                "ResponseOpDecoder.accept: \(op) is connection-level (§O2); the mux must never "
                    + "route it to a stream's decoder")

        case .cancel(_, let reason):
            isFailed = true
            throw RPCError(code: .cancelled, message: "peer cancelled the stream: \(reason)")

        case .openStream:
            try fail("received 'openStream', which is request-direction only")

        case .halfClose:
            try fail("received 'halfClose', which is request-direction only")

        case .metadata(_, let fields):
            switch position {
            case .pending:
                let metadata = try decodeMetadata(fields)
                position = .open
                return [.metadata(metadata)]
            case .open:
                try fail("received a second 'metadata' op; metadata may appear only once, before the first message")
            case .afterStatus:
                try fail("received 'metadata' after 'status'; status is the single terminator")
            }

        case .message(_, let payload):
            switch position {
            case .pending:
                // §O2 makes response-direction `metadata` optional, and the client
                // (`ClientStreamExecutor._waitForFirstResponsePart`) rejects a bare `.message` as
                // its first response part ("expected metadata"). A real, non-synthesising
                // `ResponseOpEncoder` on the other end already guarantees metadata precedes any
                // message before either reaches the wire -- but this decoder must not assume that
                // guarantee holds, since a `.message`-first response is spec-legal *input* per
                // §O2 even if this transport's own encoder never produces it. Synthesising here,
                // not just trusting the peer, is what keeps spec-legal input from turning into
                // grpc-swift's own "this is likely a transport-specific bug" error.
                position = .open
                return [.metadata(Metadata()), .message(payload)]
            case .open:
                return [.message(payload)]
            case .afterStatus:
                try fail("received 'message' after 'status'; status is the single terminator")
            }

        case .status(_, let code, let message, let trailers):
            switch position {
            case .pending, .open:
                // An unrecognized code is UNKNOWN, not a transport failure. gRPC's own rule
                // (PROTOCOL-HTTP2 / the status-code contract every implementation shares): a
                // client that does not recognise a `grpc-status` value maps it to `UNKNOWN` (2)
                // and completes the RPC. Failing the stream instead would take a peer that
                // terminated *cleanly* -- it sent a status; the grammar was obeyed -- and answer
                // it with an outbound `cancel` plus an `.internalError` the application never
                // asked for. Codes 0...16 have been frozen for years, so this costs nothing
                // today; it is what stops a newer peer sharing this wire format from being
                // mistaken for a broken one tomorrow. `message` and `trailers` are still
                // delivered verbatim, so the peer's own explanation of the code survives the
                // remap.
                let statusCode = Status.Code(rawValue: code) ?? .unknown
                let metadata = try decodeMetadata(trailers)
                position = .afterStatus
                return [.status(Status(code: statusCode, message: message), metadata)]
            case .afterStatus:
                try fail("received a second 'status'; status is the single terminator")
            }
        }
    }

    /// Converts a field list (a `metadata` op's, or a `status` op's `trailers`) to `Metadata`,
    /// routing a malformed field list through `fail(_:)` rather than letting `GRPCWireHeaders`'
    /// own thrown `RPCError` (`.invalidArgument`) escape directly -- see the identically-purposed
    /// helper on `RequestOpDecoder` for the full rationale (§O2 violations are `.internalError`;
    /// `position` must not advance past the state that guarded this call before the throw).
    private mutating func decodeMetadata(_ fields: [HTTPField]) throws(RPCError) -> Metadata {
        do {
            return try GRPCWireHeaders.parseUserMetadata(fields)
        } catch {
            try fail("malformed metadata field list", error: error)
        }
    }

    /// Fails this stream: marks the decoder terminal and throws, carrying the `GRPCWireHeaders`
    /// error that caused it as a real `cause:` rather than interpolated into the message. The
    /// mirror of `RequestOpDecoder`'s overload of the same name, and it exists for the same
    /// reason: `\(error)` in the message would flatten the original error to text at the one
    /// place its structure is still available, and the two decoders must not differ on that.
    private mutating func fail(_ reason: String, error: RPCError) throws(RPCError) -> Never {
        isFailed = true
        throw RPCError(code: .internalError, message: "ResponseOpDecoder: \(reason)", cause: error)
    }

    private mutating func fail(_ reason: String) throws(RPCError) -> Never {
        isFailed = true
        throw RPCError(code: .internalError, message: "ResponseOpDecoder: \(reason)")
    }
}
