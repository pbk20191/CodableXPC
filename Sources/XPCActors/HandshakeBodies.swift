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

/// The chosen version. A responder that finds no overlap cancels instead of
/// replying, so there is no "rejected" case to represent here.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct HelloAckBody: Codable, Equatable, Sendable {
    public let version: UInt64
    public init(version: UInt64) { self.version = version }
}
