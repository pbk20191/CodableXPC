import Foundation

/// A failure of the byte pipe itself, below any notion of a request.
///
/// These never cross the wire. A failure reported *by the peer* arrives as an
/// `err` reply body instead, and is surfaced in Phase B as `RemoteCallError`.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public enum RawTransportError: Error, Equatable, Sendable {
    case rawTransportCancelled(message: String)
}

/// A failure of a correlated exchange.
///
/// `taskCancelled` is deliberately distinct from `transportCancelled`: the first
/// means our own caller walked away and the peer is still healthy, the second
/// means the pipe is gone. Only the first should provoke a cancellation
/// notification to the peer.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public enum TransportError: Error, Equatable, Sendable {
    case transportCancelled(message: String)
    case taskCancelled
}

/// A failure to bring a session up: connecting or activating.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public struct SetupError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "SetupError(\(message))" }
}

/// A body that does not satisfy the wire contract.
///
/// Envelope violations are deliberately not represented here: `Packet.init?(rawValue:)`
/// returns `nil` rather than throwing, because a malformed envelope is dropped, never
/// surfaced to a caller.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public enum PacketCodingError: Error, Equatable, Sendable {
    /// A `Packet.Payload` with no `"payload"` entry, so there is nothing to decode.
    ///
    /// Unreachable for a payload this package built -- `Payload.init(encoding:)` always
    /// writes the entry -- and reachable for one adopted from elsewhere.
    ///
    /// This replaces `bodyIsNotADictionary`, which described a restriction that no
    /// longer exists: the body is an overlay byte stream, so a top-level array is a
    /// perfectly ordinary body, and a `RemoteInvocationResponse` is exactly that.
    case payloadHasNoBody
}
