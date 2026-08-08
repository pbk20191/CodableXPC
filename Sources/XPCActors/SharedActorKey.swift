import Foundation

/// An actor reference on the wire is exactly this and nothing else.
///
/// The coding is written by hand with an explicit `kind` discriminator rather than
/// Swift's synthesized enum coding. Apple's dump build used the synthesized form and
/// its shipping build moved to a `UInt8` discriminator, with nothing detecting the
/// break; an explicit discriminator from the start plus the golden fixtures in
/// `SharedActorKeyTests` is how that failure mode is closed here.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum SharedActorKey: Hashable, Sendable {
    /// The default actor for a type. Pre-agreed: a peer can import it with no round trip.
    case type(String)
    /// An actor exported under a name. Also pre-agreed.
    case name(String)
    /// An actor that crossed the wire as a value during a call.
    case dynamic(UInt64)
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension SharedActorKey: Codable {

    private enum CodingKeys: String, CodingKey {
        case kind, type, name, id
    }

    private enum Kind: UInt64 {
        case type = 0, name = 1, dynamic = 2
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .type(let mangled):
            try container.encode(Kind.type.rawValue, forKey: .kind)
            try container.encode(mangled, forKey: .type)
        case .name(let name):
            try container.encode(Kind.name.rawValue, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .dynamic(let id):
            try container.encode(Kind.dynamic.rawValue, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(UInt64.self, forKey: .kind)
        guard let kind = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown SharedActorKey kind \(raw)")
        }
        // The discriminator decides which key is read. A payload key that does not
        // match the kind is not consulted, so a mismatched pair fails rather than
        // decoding as whatever happens to be present.
        switch kind {
        case .type: self = .type(try container.decode(String.self, forKey: .type))
        case .name: self = .name(try container.decode(String.self, forKey: .name))
        case .dynamic: self = .dynamic(try container.decode(UInt64.self, forKey: .id))
        }
    }
}
