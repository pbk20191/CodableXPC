import Foundation
import XPC
import CodableXPC

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
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct InvocationBody: Encodable {

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

/// The inbound side of an invocation.
///
/// Not the mirror of `InvocationBody`, and it cannot be: an argument's type is not known
/// until `executeDistributedTarget` asks for it by static type. So every header field is
/// decoded eagerly and the arguments container is *retained unconsumed*, for the
/// invocation decoder to drive one element at a time.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct InboundInvocation: Decodable {

    public let protocolStub: SwiftType?
    public let genericSubsitutions: [SwiftType]
    public let errorType: SwiftType?
    public let returnType: SwiftType?
    /// `var` because decoding an element advances the container's own cursor -- that
    /// cursor is the decoder's entire state, which is why no index is tracked.
    public var argumentsContainer: any UnkeyedDecodingContainer

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: InvocationCodingKeys.self)
        protocolStub = try container.decodeIfPresent(SwiftType.self, forKey: .protocolStub)
        genericSubsitutions = try container.decode([SwiftType].self,
                                                   forKey: .genericSubsitutions)
        errorType = try container.decodeIfPresent(SwiftType.self, forKey: .errorType)
        returnType = try container.decodeIfPresent(SwiftType.self, forKey: .returnType)
        argumentsContainer = try container.nestedUnkeyedContainer(forKey: .arguments)
    }
}

// MARK: - the request

/// `Session.RemoteInvocationRequest` -- a keyed dictionary.
///
/// `contents` holds the invocation dictionary *directly*: this is a nesting relative to
/// a flattened request, and a flattening relative to what the name `InvocationContents`
/// suggests.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct RemoteInvocationRequest: Encodable {

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
/// `InboundInvocation` splits from `InvocationBody`: the arguments cannot be decoded
/// here.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct InboundRequest: Decodable {

    public let id: ID64
    public let basePriority: TaskPriority?
    public let targetedSharedActor: SharedActorKey
    public let remoteCallIdentifier: String
    public var contents: InboundInvocation

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
        contents = try container.decode(InboundInvocation.self, forKey: .contents)
    }
}

// MARK: - the response

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
/// The success payload is an `XPCNativeObject` rather than a generic parameter because
/// our transport decodes the envelope before the call site's return type is in scope.
/// Apple gets to be generic here because their `sendInvocation<A>` decodes at the call
/// site; at this layer we do not have that.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum RemoteInvocationResponse: Equatable {

    case result(XPCNativeObject)
    case failure(RemoteInvocationFailure)

    /// `Either.Case`, `RawRepresentable` over `UInt8` with the defaults in declaration
    /// order: `a` is 0 and holds the result, `b` is 1 and holds the failure.
    private enum Tag: UInt8 {
        case result = 0
        case failure = 1
    }

    /// A Void success is `[0, {}]` -- an empty dictionary rather than an absent payload,
    /// so "returned nothing" stays distinguishable from "carried no result at all".
    public static var void: RemoteInvocationResponse {
        .result(XPCNativeObject(xpc_dictionary_create(nil, nil, 0)))
    }

    /// `userInfo` is threaded through because a returned value may itself contain an
    /// `ActorID`, which needs the owning session to code itself.
    ///
    /// Deliberately not defaulted. The value is encoded here and now, not at
    /// `Payload(encoding:userInfo:)` time, so this `userInfo` is the only one it will
    /// ever see -- and `ActorID.encode` traps rather than throws when the session is
    /// missing. A default would make the process-trapping spelling the shortest one, on
    /// a return path whose value shape is influenced by which `func` a peer chose to
    /// invoke. Callers with genuinely no session pass `[:]` and say so.
    public init<T: Encodable>(
        result value: T, userInfo: [CodingUserInfoKey: Any]
    ) throws {
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo
        self = .result(XPCNativeObject(try encoder.encode(value)))
    }

    public init(executionFailure message: String) {
        self = .failure(.executionFailed(message))
    }

    public init(resultPropagationFailure message: String) {
        self = .failure(.resultPropagationFailed(message))
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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
            self = .result(try container.decode(XPCNativeObject.self))
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
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum RemoteInvocationFailure: Hashable, Sendable {
    case executionFailed(String)
    case resultPropagationFailed(String)
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum RemoteNotification: Equatable, Sendable {
    case invocationCancelled(id: ID64)
    case invocationEscalated(id: ID64, priority: TaskPriority)
    case responseEscalated(id: ID64, priority: TaskPriority)
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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
