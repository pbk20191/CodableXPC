import Foundation

/// The wire wrapper around a mangled type name.
///
/// Apple never puts a bare mangled name on the wire -- every type reference is wrapped
/// in a struct Apple calls `SwiftType`, `{ mangledTypeName, type }`, where `type` is the
/// resolved `Any.Type` and is deliberately not part of the encoded form: a peer has no
/// way to send us a `Type` value, only the name it was mangled from. This mirrors that
/// split. `mangledTypeName` is what crosses the wire; `type` is resolved on demand
/// through the shared `TypeName` cache -- the same one `TypeName.swift` already
/// maintains, not a second one.
///
/// Resolution failure is not a decoding failure. `init(from:)` only ever reads the
/// string; it never calls into `TypeName`, so a name that does not resolve on this side
/// decodes cleanly. Apple's own decoder works the same way -- `"Unable to resolve
/// type: "` is a distinct, later failure raised by whatever tries to use the type, not
/// by decoding the wrapper.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct SwiftType: Sendable {

    public let mangledTypeName: String

    /// Resolved lazily, on every access, through `TypeName` -- `nil` when the name does
    /// not (yet, or ever) resolve to a loaded type.
    public var type: Any.Type? { TypeName.type(for: mangledTypeName) }

    public init(mangledTypeName: String) {
        self.mangledTypeName = mangledTypeName
    }

    /// Convenience for the common case of already holding the concrete type. Falls back
    /// to `String(reflecting:)` when the runtime cannot mangle it, matching
    /// `InvocationEncoder.recordErrorType`'s tier-3 degradation rather than failing.
    public init(_ type: Any.Type) {
        self.mangledTypeName = TypeName.mangled(for: type) ?? String(reflecting: type)
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension SwiftType: Hashable {
    // Equality and hashing are defined over `mangledTypeName` alone. `type` is a
    // derived, cache-backed lookup -- not additional identity -- and two `SwiftType`s
    // naming the same type must compare equal even when one hasn't resolved yet.
    public static func == (lhs: SwiftType, rhs: SwiftType) -> Bool {
        lhs.mangledTypeName == rhs.mangledTypeName
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(mangledTypeName)
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension SwiftType: Codable {

    private enum CodingKeys: String, CodingKey {
        case mangledTypeName
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mangledTypeName, forKey: .mangledTypeName)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mangledTypeName = try container.decode(String.self, forKey: .mangledTypeName)
    }
}
