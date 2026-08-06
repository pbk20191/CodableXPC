import Foundation

/// The wire protocol version.
///
/// Apple's `XPCSystem` ships no version field and no handshake, which is how two
/// observable builds of it came to disagree on `SharedActorKey` coding without
/// anything detecting the break. This type exists so that cannot happen here.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct ProtocolVersion: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Reserved: "no version agreed yet". Valid only on `hello` and `helloAck`,
    /// and never the result of a successful negotiation.
    public static let unnegotiated = ProtocolVersion(rawValue: 0)

    public static let v1 = ProtocolVersion(rawValue: 1)

    public static let minimumSupported = v1
    public static let current = v1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The highest version both ends speak, or `nil` if there is none.
    public static func negotiate(peerMin: UInt64, peerMax: UInt64) -> ProtocolVersion? {
        guard peerMin <= peerMax else { return nil }
        let low = Swift.max(peerMin, minimumSupported.rawValue)
        let high = Swift.min(peerMax, current.rawValue)
        guard low <= high else { return nil }
        return ProtocolVersion(rawValue: high)
    }
}
