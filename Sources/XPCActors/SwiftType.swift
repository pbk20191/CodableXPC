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
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public struct SwiftType: Sendable {

    public let mangledTypeName: String

    /// Resolved lazily, on every access, through `TypeName` -- `nil` when the name does
    /// not (yet, or ever) resolve to a loaded type.
    public var type: Any.Type? { TypeName.type(for: mangledTypeName) }

    public init(mangledTypeName: String) {
        self.mangledTypeName = mangledTypeName
    }

    /// Convenience for the common case of already holding the concrete type.
    ///
    /// Fails rather than degrading, and checks the round trip rather than trusting the
    /// mangler. `_mangledTypeName` returning non-nil does **not** mean the name is
    /// usable: a function-local type mangles to a name embedding a process address that
    /// `_typeByName` cannot resolve, and an ObjC class created at runtime over a Swift
    /// superclass mangles to the *superclass's* name -- non-nil, resolvable, and wrong.
    /// A nil check catches neither. `_typeByName(name) == type` catches both, at the
    /// cost of one cached lookup per type.
    ///
    /// The point of failing is that the alternative fails somewhere worse. A name that
    /// does not resolve on the far side surfaces there, as an unresolvable type, with no
    /// indication of where it came from.
    ///
    /// Verified not to reject ordinary types: 26 spot checks across structs, classes,
    /// enums, actors, generic instantiations, nested types, stdlib and Foundation types,
    /// collections, optionals, and existentials all round-trip. The only construction
    /// found that fails is the function-local type, which is exactly the case a peer
    /// could not resolve either.
    ///
    /// Degradation is still legitimate in one place: `errorType`'s *presence* is what
    /// tells the receiver the target can throw, so dropping the field changes the
    /// meaning of the call and a useless name beats no name. That trade belongs at the
    /// call site, spelled out -- `SwiftType(E.self) ?? SwiftType(mangledTypeName: "\(E.self)")`
    /// -- not hidden in an initializer that every other caller also goes through.
    public init?(_ type: Any.Type) {
        guard let mangled = TypeName.mangled(for: type),
              TypeName.type(for: mangled) == type
        else { return nil }
        self.mangledTypeName = mangled
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
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

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension SwiftType: Codable {

    // A bare String on the wire, not `{ mangledTypeName: ... }`. The struct has two
    // stored fields, but only the name is transmitted and Apple does not wrap it:
    // `SwiftType.encode(to:)` opens a `singleValueContainer()` and calls the
    // `encode(Swift.String)` thunk, and there is no `SwiftType.CodingKeys` anywhere in
    // the shipping binary, so a keyed container is not even available to it.
    // Reproduce with `xpcdump/macos27-XPCDistributed/verify-containers.py`.

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(mangledTypeName)
    }

    public init(from decoder: any Decoder) throws {
        self.mangledTypeName = try decoder.singleValueContainer().decode(String.self)
    }
}
