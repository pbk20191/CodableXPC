import Foundation

/// The byte pipe, with everything above it abstracted away.
///
/// This seam is why the whole stack is testable without XPC, a second process, or
/// an installed service, and it is where an `xpc_connection_t`-backed transport
/// would slot in later to lower the deployment floor to macOS 13.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public protocol RawTransportProtocol: AnyObject, Sendable {
    /// Install the inbound handler. Must be called before `activate()`; packets
    /// that arrive with no handler installed are dropped.
    func setPacketHandler(_ handler: @escaping @Sendable (Packet) -> Void)

    func activate() throws(RawTransportError)

    func send(packet: Packet) throws(RawTransportError)

    func cancel(reason: String)
}
