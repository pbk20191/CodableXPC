import Foundation

/// Sent by the dialing side before anything else.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct HelloBody: Codable, Equatable, Sendable {
    public let min: UInt64
    public let max: UInt64
    public init(min: UInt64, max: UInt64) {
        self.min = min
        self.max = max
    }
    public static let current = HelloBody(
        min: ProtocolVersion.minimumSupported.rawValue,
        max: ProtocolVersion.current.rawValue
    )
}

/// The chosen version, or a rejection.
///
/// A `version` of `0` -- `ProtocolVersion.unnegotiated` -- is the rejection: it means
/// the responder found no version in common and is about to cancel. It is sent
/// *before* cancelling because this protocol has no timeout, so a responder that
/// merely cancels leaves the initiator's `activate()` suspended forever.
///
/// This body `version: 0` is a distinct thing from the *envelope* `version: 0` that
/// every `hello` and `helloAck` carries; that one only means "not yet negotiated".
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct HelloAckBody: Codable, Equatable, Sendable {
    public let version: UInt64
    public init(version: UInt64) { self.version = version }
}
