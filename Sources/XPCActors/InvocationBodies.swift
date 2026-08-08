import Foundation
import XPC
import CodableXPC

// MARK: - request

/// The outbound side of an invocation.
///
/// Arguments are positional and carry no per-argument type tag: the receiver's
/// `executeDistributedTarget` knows each parameter's type statically from the callee
/// signature and asks for them in order, so a tag would be pure overhead. Labels are
/// discarded for the same reason.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct RequestBody: Encodable {

    public let actor: SharedActorKey
    public let target: String
    public let generics: [String]
    public let args: [any Codable]
    public let errorType: String?
    public let returnType: String?
    public let basePriority: UInt64?

    public init(
        actor: SharedActorKey, target: String, generics: [String], args: [any Codable],
        errorType: String?, returnType: String?, basePriority: UInt64?
    ) {
        self.actor = actor
        self.target = target
        self.generics = generics
        self.args = args
        self.errorType = errorType
        self.returnType = returnType
        self.basePriority = basePriority
    }

    enum CodingKeys: String, CodingKey {
        case actor, target, generics, args, errorType, returnType, basePriority
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actor, forKey: .actor)
        try container.encode(target, forKey: .target)
        try container.encode(generics, forKey: .generics)
        try container.encodeIfPresent(errorType, forKey: .errorType)
        try container.encodeIfPresent(returnType, forKey: .returnType)
        try container.encodeIfPresent(basePriority, forKey: .basePriority)

        var arguments = container.nestedUnkeyedContainer(forKey: .args)
        for argument in args {
            // Implicit existential opening: `encode` is generic, and `argument` is the
            // sole use of the existential, so Swift opens it and calls the concrete
            // `encode`. Do not "fix" this by boxing -- boxing loses the dynamic type,
            // which is exactly what has to reach the coder.
            try arguments.encode(argument)
        }
    }
}

/// The inbound side of an invocation.
///
/// Not the mirror of `RequestBody`, and it cannot be: an argument's type is not known
/// until `executeDistributedTarget` asks for it by static type. So every header field
/// is decoded eagerly and the `args` container is *retained unconsumed*, for
/// `InvocationDecoder` to drive one element at a time.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct InboundRequest: Decodable {

    public let actor: SharedActorKey
    public let target: String
    public let generics: [String]
    public let errorType: String?
    public let returnType: String?
    public let basePriority: UInt64?
    /// `var` because decoding an element advances the container's own cursor -- that
    /// cursor is the decoder's entire state, which is why no index is tracked.
    public var argumentsContainer: any UnkeyedDecodingContainer

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RequestBody.CodingKeys.self)
        actor = try container.decode(SharedActorKey.self, forKey: .actor)
        target = try container.decode(String.self, forKey: .target)
        generics = try container.decode([String].self, forKey: .generics)
        errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
        returnType = try container.decodeIfPresent(String.self, forKey: .returnType)
        basePriority = try container.decodeIfPresent(UInt64.self, forKey: .basePriority)
        argumentsContainer = try container.nestedUnkeyedContainer(forKey: .args)
    }
}

// MARK: - reply

/// Exactly one of `ok` and `err`.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct ReplyBody {

    /// A failure the peer is reporting. Never a transport failure -- those do not
    /// cross the wire.
    public struct Err: Codable, Equatable, Sendable {
        public enum Kind: UInt64, Codable, Sendable {
            case targetThrew = 0
            case resultEncodingFailed = 1
            case noSuchActor = 2
            case peerRequirementNotSatisfied = 3
            case notReceiving = 4
            case requestUndecodable = 5
        }
        public let kind: Kind
        /// The mangled name of the thrown error, when it could be recovered.
        public let type: String?
        /// The encoded error, present exactly when `type` is.
        public let value: XPCNativeObject?
        /// Always present. The tier-3 fallback, so an unregistered error is never a
        /// failure -- only a less precise one.
        public let text: String

        public init(kind: Kind, type: String?, value: XPCNativeObject?, text: String) {
            self.kind = kind
            self.type = type
            self.value = value
            self.text = text
        }
    }

    public let ok: XPCNativeObject?
    public let err: Err?

    public init(ok: XPCNativeObject) { self.ok = ok; self.err = nil }
    public init(err: Err) { self.ok = nil; self.err = err }

    /// Void is an empty dictionary rather than an absent `ok`, so "returned nothing"
    /// stays distinguishable from "carried no result at all".
    public static var void: ReplyBody {
        ReplyBody(ok: XPCNativeObject(xpc_dictionary_create(nil, nil, 0)))
    }

    public static func success<T: Encodable>(encoding value: T) throws -> ReplyBody {
        ReplyBody(ok: XPCNativeObject(try XPCEncoder().encode(value)))
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension ReplyBody: Codable {

    private enum CodingKeys: String, CodingKey { case ok, err }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(ok, forKey: .ok)
        try container.encodeIfPresent(err, forKey: .err)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decodeIfPresent(XPCNativeObject.self, forKey: .ok)
        let err = try container.decodeIfPresent(Err.self, forKey: .err)
        switch (ok, err) {
        case (.some(let ok), .none): self = ReplyBody(ok: ok)
        case (.none, .some(let err)): self = ReplyBody(err: err)
        default:
            // Neither, or both. Failing is the only safe answer: preferring `ok` would
            // turn a reported remote failure into a bogus success, and preferring `err`
            // would invent a failure that did not happen.
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "a reply must carry exactly one of ok and err"))
        }
    }
}

// MARK: - notification

/// One-way, and carrying no envelope `seq`.
///
/// The field naming the request is `requestSeq`, never `seq`. Two different sequence
/// numbers would otherwise be spelled the same way in code and in logs: the envelope's
/// own, and the request this refers to.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct NotificationBody: Codable, Equatable, Sendable {

    public enum Kind: UInt64, Codable, Sendable {
        case invocationCancelled = 0
        /// Phase C. Defined here so the format is complete; nothing sends it yet.
        case invocationEscalated = 1
        /// Phase C. Defined here so the format is complete; nothing sends it yet.
        case responseEscalated = 2
    }

    public let kind: Kind
    public let requestSeq: UInt64
    /// Present for the two escalation kinds only.
    public let priority: UInt64?

    public init(kind: Kind, requestSeq: UInt64, priority: UInt64?) {
        self.kind = kind
        self.requestSeq = requestSeq
        self.priority = priority
    }
}
