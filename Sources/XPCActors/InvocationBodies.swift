import Foundation

// The invocation wire shapes, matched to Apple's shipping `XPCDistributed`.
//
// See `docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md`. Every
// container choice below was resolved with
// `xpcdump/macos27-XPCDistributed/verify-containers.py` rather than inferred from a
// field list -- inferring one is how the previous revision shipped the wrong shape:
//
//     Session.RemoteInvocationRequest.encode(to:)  @0x2ad50dd3c -> container(keyedBy:)
//     Session.RemoteNotification.encode(to:)       @0x2ad510068 -> container(keyedBy:)
//     Session.RemoteInvocationResponse.encode(to:) @0x2ad50f8e0 -> singleValueContainer()
//     RemoteInvocationFailure.encode(to:)          @0x2ad50e818 -> container(keyedBy:)
//     Either.encode(to:)                           @0x2ad4ed7c4 -> unkeyedContainer()

// MARK: - the invocation

/// `XPCSystem.InvocationCodingKeys`, in Apple's declaration order.
///
/// Shared by the encoding and decoding sides on purpose: Apple has one key type for
/// both, and two copies would let them drift. The misspelling of `genericSubsitutions`
/// -- one 's' after "sub" -- **is required**, and is not a transcription slip here. The
/// proof is internal to the shipping binary: `InvocationCodingKeys`, which is what
/// serialises, misspells it, while `DirectInvocationDecoder`, the in-process path that
/// never touches the wire, spells it correctly. Apple fixed the typo only where it was
/// free to.
enum InvocationCodingKeys: String, CodingKey {
    case protocolStub
    case genericSubsitutions
    case arguments
    case errorType
    case returnType
}

/// One invocation, as it appears under a request's `contents` key.
///
/// This is the whole of what a peer sees of an invocation. `InvocationContents`'s
/// `send`/`recv` pair is an in-memory distinction -- which direction this process holds
/// the invocation in -- and never reaches the wire; Apple's
/// `InvocationContents.init(from:)` forwards straight to the invocation decoder without
/// ever looking for a case name. So there is no wrapper here, and no direction tag.
///
/// Arguments are positional and carry no per-argument type tag: the receiver's
/// `executeDistributedTarget` knows each parameter's type statically from the callee
/// signature and asks for them in order, so a tag would be pure overhead. Labels are
/// discarded for the same reason.
public struct InvocationBody: Encodable, @unchecked Sendable {

    /// The `_DistributedActorStub` a call goes through when it targets a distributed
    /// *protocol* rather than a concrete actor type. At most one -- Apple raises
    /// `"Encoding second _DistributedActorStub "` on a second.
    public let protocolStub: SwiftType?
    /// Always written, empty or not.
    public let genericSubsitutions: [SwiftType]
    /// Always written, empty or not. Positional; the labels are already gone.
    public let arguments: [any Codable]
    /// Present exactly when the target can throw -- its presence is the signal.
    public let errorType: SwiftType?
    public let returnType: SwiftType?

    public init(
        protocolStub: SwiftType?, genericSubsitutions: [SwiftType],
        arguments: [any Codable], errorType: SwiftType?, returnType: SwiftType?
    ) {
        self.protocolStub = protocolStub
        self.genericSubsitutions = genericSubsitutions
        self.arguments = arguments
        self.errorType = errorType
        self.returnType = returnType
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: InvocationCodingKeys.self)
        // `encodeIfPresent`, never `encodeNil`. A nil optional means the key is not
        // written; Apple's `InvocationEncoder.encode(to:)` branches on the value before
        // encoding, and a peer reading `{"errorType": null}` would see a present field.
        try container.encodeIfPresent(protocolStub, forKey: .protocolStub)
        try container.encode(genericSubsitutions, forKey: .genericSubsitutions)

        var argumentsContainer = container.nestedUnkeyedContainer(forKey: .arguments)
        for argument in arguments {
            // Implicit existential opening: `encode` is generic, and `argument` is the
            // sole use of the existential, so Swift opens it and calls the concrete
            // `encode`. Do not "fix" this by boxing -- boxing loses the dynamic type,
            // which is exactly what has to reach the coder.
            try argumentsContainer.encode(argument)
        }

        try container.encodeIfPresent(errorType, forKey: .errorType)
        try container.encodeIfPresent(returnType, forKey: .returnType)
    }
}

// The inbound side of an invocation is Apple's `EncodedInvocationDecoder` -- a `Decodable`
// that decodes itself off the request and retains its arguments container unconsumed. It
// lives with the other invocation-decoder types in `XPCActorSystem.swift`.

// MARK: - the request

/// `Session.RemoteInvocationRequest` -- a keyed dictionary.
///
/// `contents` holds the invocation dictionary *directly*: this is a nesting relative to
/// a flattened request, and a flattening relative to what the name `InvocationContents`
/// suggests.
public struct RemoteInvocationRequest: Encodable, @unchecked Sendable {

    /// The correlation id. Coded through `ID64`'s own single-value conformance, so it
    /// lands as a bare `UInt64` under the key -- not a nested one-field dictionary.
    public let id: ID64
    /// A bare `UInt8` when present -- `TaskPriority`'s stdlib conformance comes from
    /// `RawRepresentable` and codes the raw value in a single-value container
    /// (high 25, medium 21, low 17, background 9). Omitted entirely when nil.
    public let basePriority: TaskPriority?
    public let targetedSharedActor: SharedActorKey
    /// `RemoteCallTarget.identifier`.
    public let remoteCallIdentifier: String
    public let contents: InvocationBody

    public init(
        id: ID64, basePriority: TaskPriority?, targetedSharedActor: SharedActorKey,
        remoteCallIdentifier: String, contents: InvocationBody
    ) {
        self.id = id
        self.basePriority = basePriority
        self.targetedSharedActor = targetedSharedActor
        self.remoteCallIdentifier = remoteCallIdentifier
        self.contents = contents
    }

    enum CodingKeys: String, CodingKey {
        case id
        case basePriority
        case targetedSharedActor
        case remoteCallIdentifier
        case contents
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(basePriority, forKey: .basePriority)
        try container.encode(targetedSharedActor, forKey: .targetedSharedActor)
        try container.encode(remoteCallIdentifier, forKey: .remoteCallIdentifier)
        try container.encode(contents, forKey: .contents)
    }
}

/// The inbound side of a request. Splits from `RemoteInvocationRequest` for the reason
/// ``EncodedInvocationDecoder`` splits from `InvocationBody`: the arguments cannot be decoded
/// here. `contents` decodes directly into the ``EncodedInvocationDecoder`` (Apple's
/// `EncodedInvocationDecoder.init(from:)`), which ``Session`` then reads `errorType` off and
/// wraps in an ``InvocationDecoder``.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public struct InboundRequest: Decodable {

    public let id: ID64
    public let basePriority: TaskPriority?
    public let targetedSharedActor: SharedActorKey
    public let remoteCallIdentifier: String
    public var contents: EncodedInvocationDecoder

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(
            keyedBy: RemoteInvocationRequest.CodingKeys.self)
        id = try container.decode(ID64.self, forKey: .id)
        basePriority = try container.decodeIfPresent(TaskPriority.self,
                                                     forKey: .basePriority)
        targetedSharedActor = try container.decode(SharedActorKey.self,
                                                   forKey: .targetedSharedActor)
        remoteCallIdentifier = try container.decode(String.self,
                                                    forKey: .remoteCallIdentifier)
        contents = try container.decode(EncodedInvocationDecoder.self, forKey: .contents)
    }
}

// MARK: - the response

/// `XPCDistributed.Ack` -- Apple's stand-in for `Void` on the return path.
///
/// A field-less struct with synthesized `Codable`, so it writes an empty keyed
/// container: `{}`. That is the entire payload of a void reply, and the reason the
/// wire has a payload there at all -- `Void` is not `Codable`, so something has to
/// occupy the generic parameter.
///
/// **Resolved from the binary, not chosen.** `EncodedResultHandler.onReturnVoid()`
/// (`0x2ad5036f4`) calls its own `onReturn<A>(value:)` with `A` bound to
/// `XPCDistributed.Ack` -- the type metadata (`0x2d9b84470`) and both witness tables
/// are loaded into the argument registers immediately before the tail call, and no
/// value register is passed because `Ack` is zero-sized. `onReturn<A>` (`0x2ad503404`)
/// builds a `Swift.Result` and stores case 0 -- `.success` -- with
/// `swift_storeEnumTagMultiPayload`, then calls the one `ReplyHandler` requirement
/// through its witness table; that call is indirect, so it is identified by signature
/// rather than by symbol, and `encodeReply<A, B>(with: Result<A, B>) -> Payload` is the
/// protocol's only method. `encodeReply`'s success arm then calls
/// `encodeReturn<A>(value:)` as a *direct* call, and `encodeReturn` calls
/// `RemoteInvocationResponse<A>.init(result:)` -- tag 0 -- and
/// `Packet.Payload.init(encoding:userInfo:)`.
///
/// The in-process path agrees independently: `ResultHandler.onReturnVoid()`
/// (`0x2ad5051b4`) stores `.success(Ack())` as an `any Decodable & Encodable` into
/// `DirectResultHandler.capturedResult`. Two unrelated paths, one stand-in type.
///
/// Emptiness is from reflection metadata rather than inference:
/// `field-descriptors.txt` lists `struct XPCDistributed.Ack` with no fields and
/// `enum XPCDistributed.Ack..CodingKeys` with no cases, and `Ack.encode(to:)`
/// (`0x2ad4ebb70`) opens `container(keyedBy:)` and makes no encode call.
///
/// Synthesized here on purpose. Apple's is synthesized -- it has a `CodingKeys` in the
/// shipping reflection metadata -- so writing the conformance by hand could only
/// diverge.
/// Its decode side accepts anything, and that is correct rather than a hole. Apple's
/// `Ack.init(from:)` (`0x2ad4ebcdc`) opens no container at all -- it destroys the boxed
/// decoder existential and returns -- so `[0, 7]`, `[0, "junk"]`, `[0, null]` and
/// `[0, {"surprise": 1}]` all decode as a void success against a real peer. A synthesized
/// conformance over no fields behaves identically, which is why this must stay synthesized:
/// hand-writing it would be the one chance to accidentally start rejecting traffic Apple
/// accepts.
public struct Ack: Codable, Hashable, Sendable {
    public init() {}
}

/// `Session.RemoteInvocationResponse` -- and there is no response dictionary.
///
/// Apple's response struct has one stored field, `_value`, but `_value` is not a wire
/// key: `encode(to:)` opens a *single-value* container, so the response is its payload
/// unwrapped. That payload is `Either<A, RemoteInvocationFailure>`, and `Either` is the
/// thing that carries the discriminator -- as an unkeyed pair, the same shape
/// `SharedActorKey` uses:
///
///     [ <tag : UInt8>, <payload> ]   0 -> the result, 1 -> a failure
///
/// Generic over the success type, as Apple's `RemoteInvocationResponse<A>` is. It held
/// an `XPCNativeObject` until R5, on the reasoning that the transport decodes an
/// envelope before the call site's return type is in scope. That was sound against a
/// native-xpc body and did not survive the body becoming an overlay byte stream: there
/// is no live xpc object to hold, and `XPCNativeObject`'s conformance throws for every
/// coder but `CodableXPC`'s native-xpc one, so a success response could not be encoded
/// at all. Nothing in the transport ever needed the erasure -- `RequestTable.Outcome`
/// is `.reply(Packet.Payload)`, an *undecoded* payload -- so the decode simply moves to
/// whoever knows the return type, which is Apple's arrangement.
///
/// A failure carries no success value, so a failure-only response is spelled
/// `RemoteInvocationResponse<NoSuccess>` -- Apple spells it `<Never>`, and the substitution is
/// argued at ``NoSuccess``: the
/// lazy `Encodable` witness accessor for `RemoteInvocationResponse<Swift.Never>` is a
/// direct call in `encodeReply`'s failure arm (`0x2ad512738`) and in `encodeReturn`'s
/// catch path (`0x2ad512298`). `<Never>` is not the void answer -- ``Ack`` is; a
/// `<Never>` response cannot hold `.result` at all, which is the point of it.
/// The stand-in for `Never` in a failure-only response.
///
/// **`Never` is what Apple instantiates and what this module used, until the floor moved.**
/// `Never`'s `Codable` conformance ships in the macOS 14 runtime; the module now targets macOS
/// 13, and a conformance that is not there is not a compile-time inconvenience but a missing
/// witness record. So the *type* changes and nothing else does.
///
/// **The wire is byte-identical, and that is checked rather than asserted.** `Success` is
/// touched in exactly one place -- the `.result` arm of `encode(to:)` and of `init(from:)`. A
/// failure response writes tag `1` and a ``RemoteInvocationFailure``, and reads the same; the
/// success type is never instantiated, encoded, or decoded. An uninhabited stand-in therefore
/// produces the same bytes as `Never` for every message that can actually exist.
///
/// Uninhabited, so `encode(to:)` is unreachable by construction rather than by convention --
/// there is no value of this type to call it on.
public enum NoSuccess: Codable, Hashable, Sendable {

    /// Reached only by a peer that sent tag `0` -- a *success* -- in a response we are decoding
    /// as failure-only. That is a peer disagreeing with us about the shape of the reply, so it
    /// is a decode failure and not a trap.
    public init(from decoder: any Decoder) throws {
        throw DecodingError.dataCorruptedError(
            in: try decoder.singleValueContainer(),
            debugDescription: "a failure-only response carried a success value")
    }

    /// Unreachable: no value of an uninhabited type exists to encode.
    public func encode(to encoder: any Encoder) throws {}
}

public enum RemoteInvocationResponse<Success: Codable> {

    case result(Success)
    case failure(RemoteInvocationFailure)

    /// `Either.Case`, `RawRepresentable` over `UInt8` with the defaults in declaration
    /// order: `a` is 0 and holds the result, `b` is 1 and holds the failure.
    private enum Tag: UInt8 {
        case result = 0
        case failure = 1
    }

    /// Mirrors Apple's `init(result: A)` (`0x2ad50f7c4`), which has exactly one caller
    /// in the whole image -- `encodeReturn+0x234`. Its value here is inference: a call
    /// site writes `RemoteInvocationResponse(result: 42)` rather than naming `Success`.
    public init(result value: Success) {
        self = .result(value)
    }

    public init(executionFailure message: String) {
        self = .failure(.executionFailed(message))
    }

    public init(resultPropagationFailure message: String) {
        self = .failure(.resultPropagationFailed(message))
    }
}

/// The void reply: `[0, {}]`, tag zero over an ``Ack``.
extension RemoteInvocationResponse where Success == Ack {
    public static var void: RemoteInvocationResponse<Ack> { .result(Ack()) }
}

extension RemoteInvocationResponse: Equatable where Success: Equatable {}

extension RemoteInvocationResponse: Hashable where Success: Hashable {}

extension RemoteInvocationResponse: Sendable where Success: Sendable {}

extension RemoteInvocationResponse: Codable {

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .result(let value):
            try container.encode(Tag.result.rawValue)
            try container.encode(value)
        case .failure(let failure):
            try container.encode(Tag.failure.rawValue)
            try container.encode(failure)
        }
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let raw = try container.decode(UInt8.self)
        guard let tag = Tag(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unknown response tag \(raw)")
        }
        // The tag decides which decode runs next -- the container is unkeyed, so there
        // is no payload key to consult instead. A truncated pair fails on the second
        // read rather than defaulting to a success with no value.
        //
        // Two reads, no count check, so a longer array has its trailing elements
        // ignored rather than rejected. Deliberate, and the same call `SharedActorKey`
        // makes: Apple's decoder is two reads as well, and rejecting here would refuse
        // traffic Apple accepts. Asymmetric with encode, which always writes two.
        switch tag {
        case .result:
            self = .result(try container.decode(Success.self))
        case .failure:
            self = .failure(try container.decode(RemoteInvocationFailure.self))
        }
    }
}

/// `RemoteInvocationResponse.RemoteInvocationFailure` -- a keyed enum in Swift's
/// synthesized shape, exactly two cases, each with one unlabelled `String`.
///
/// **A description string is all a peer can carry.** Apple has no typed error
/// propagation: `", but XPCSystem does not support propagating errors."` Our previous
/// `ReplyBody.Err` carried a six-case kind, a mangled error type name, an encoded error
/// payload, and a text fallback -- three-tier typed propagation. Interop deletes it.
/// Smuggling the extra fields back in would produce a dictionary a real peer cannot
/// decode.
public enum RemoteInvocationFailure: Hashable, Sendable {
    case executionFailed(String)
    case resultPropagationFailed(String)
}

extension RemoteInvocationFailure: Codable {

    private enum CodingKeys: String, CodingKey {
        case executionFailed
        case resultPropagationFailed
    }

    /// Apple has a separate per-case key type for each case
    /// (`ExecutionFailedCodingKeys`, `ResultPropagationFailedCodingKeys`), but both
    /// contain exactly `_0` -- a single unlabelled associated value -- so one type here
    /// is wire-identical.
    private enum PayloadKeys: String, CodingKey {
        case _0
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .executionFailed(let message):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self,
                                                    forKey: .executionFailed)
            try payload.encode(message, forKey: ._0)
        case .resultPropagationFailed(let message):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self,
                                                    forKey: .resultPropagationFailed)
            try payload.encode(message, forKey: ._0)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Exactly one key, which is what Apple's own decoder enforces --
        // `"Invalid number of keys found, expected one."` Picking one of two would
        // invent a failure that was not sent; accepting zero would invent one from
        // nothing. Note `allKeys` only reports keys this enum recognises, which cuts
        // both ways: an unknown case name arrives here as zero keys and is rejected,
        // but a *recognised* key accompanied by arbitrary unknown ones still counts as
        // one and is accepted. That is the single leniency in this decoder, and it is
        // the right one -- Swift's synthesized decoder, and so Apple's, behaves
        // identically, and being stricter would refuse traffic a real peer sends.
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "Invalid number of keys found, expected one."))
        }
        switch key {
        case .executionFailed:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self,
                                                        forKey: .executionFailed)
            self = .executionFailed(try payload.decode(String.self, forKey: ._0))
        case .resultPropagationFailed:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self,
                                                        forKey: .resultPropagationFailed)
            self = .resultPropagationFailed(try payload.decode(String.self, forKey: ._0))
        }
    }
}

// MARK: - the notification

/// `Session.RemoteNotification` -- a keyed enum in the synthesized shape, one top-level
/// key naming the case.
///
/// The field is **`id`**, never `requestSeq`. Our Phase A design renamed it to keep the
/// envelope's own sequence distinguishable from the request being referred to; that
/// rename is not interoperable, and the collision it avoided does not exist here --
/// correlation lives in the request body's `id`, and the envelope has no sequence.
///
/// `priority` belongs to the two escalation cases' key sets. It is not an optional that
/// happens to be nil on `invocationCancelled`.
///
/// The escalation cases are Phase C: nothing sends them yet, but the format is complete.
///
/// `Equatable` rather than `Hashable` only because `TaskPriority` is not `Hashable`.
public enum RemoteNotification: Equatable, Sendable {
    case invocationCancelled(id: ID64)
    case invocationEscalated(id: ID64, priority: TaskPriority)
    case responseEscalated(id: ID64, priority: TaskPriority)
}

extension RemoteNotification: Codable {

    private enum CodingKeys: String, CodingKey {
        case invocationCancelled
        case invocationEscalated
        case responseEscalated
    }

    private enum CancelledKeys: String, CodingKey {
        case id
    }

    private enum EscalatedKeys: String, CodingKey {
        case id
        case priority
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .invocationCancelled(let id):
            var payload = container.nestedContainer(keyedBy: CancelledKeys.self,
                                                    forKey: .invocationCancelled)
            try payload.encode(id, forKey: .id)
        case .invocationEscalated(let id, let priority):
            var payload = container.nestedContainer(keyedBy: EscalatedKeys.self,
                                                    forKey: .invocationEscalated)
            try payload.encode(id, forKey: .id)
            try payload.encode(priority, forKey: .priority)
        case .responseEscalated(let id, let priority):
            var payload = container.nestedContainer(keyedBy: EscalatedKeys.self,
                                                    forKey: .responseEscalated)
            try payload.encode(id, forKey: .id)
            try payload.encode(priority, forKey: .priority)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "Invalid number of keys found, expected one."))
        }
        switch key {
        case .invocationCancelled:
            let payload = try container.nestedContainer(keyedBy: CancelledKeys.self,
                                                        forKey: .invocationCancelled)
            self = .invocationCancelled(id: try payload.decode(ID64.self, forKey: .id))
        case .invocationEscalated:
            let payload = try container.nestedContainer(keyedBy: EscalatedKeys.self,
                                                        forKey: .invocationEscalated)
            self = .invocationEscalated(
                id: try payload.decode(ID64.self, forKey: .id),
                priority: try payload.decode(TaskPriority.self, forKey: .priority))
        case .responseEscalated:
            let payload = try container.nestedContainer(keyedBy: EscalatedKeys.self,
                                                        forKey: .responseEscalated)
            self = .responseEscalated(
                id: try payload.decode(ID64.self, forKey: .id),
                priority: try payload.decode(TaskPriority.self, forKey: .priority))
        }
    }
}
