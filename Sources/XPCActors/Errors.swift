import Foundation

/// A failure of the byte pipe itself, below any notion of a request.
///
/// These never cross the wire. A failure reported *by the peer* arrives as an
/// `err` reply body instead, and is surfaced in Phase B as `RemoteCallError`.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum RawTransportError: Error, Equatable, Sendable {
    case rawTransportCancelled(message: String)
}

/// A failure of a correlated exchange.
///
/// `taskCancelled` is deliberately distinct from `transportCancelled`: the first
/// means our own caller walked away and the peer is still healthy, the second
/// means the pipe is gone. Only the first should provoke a cancellation
/// notification to the peer.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum TransportError: Error, Equatable, Sendable {
    case transportCancelled(message: String)
    case taskCancelled
}

/// A failure to bring a session up: connecting, activating, or agreeing a version.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct SetupError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "SetupError(\(message))" }
}

/// A packet or body that does not satisfy the wire contract.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum PacketCodingError: Error, Equatable, Sendable {
    /// A body encoded to something other than an xpc dictionary. Every body type
    /// in this protocol is a struct, so this means a programming error.
    case bodyIsNotADictionary
    /// The envelope was absent, mistyped, or violated the presence rules for its kind.
    case malformedEnvelope
}
