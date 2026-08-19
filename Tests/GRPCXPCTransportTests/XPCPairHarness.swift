import Foundation
import XPC
import Dispatch
@testable import GRPCXPCTransport

/// Spins up an anonymous `XPCListener` and dials it in-process, returning a connected
/// (client, server) `XPCConnection` pair over **real XPC** -- not an in-process double.
///
/// Modeled on `Transport.XPCRawTransport.accepting`/`connecting(to:)` and
/// `RealXPCEndToEndTests`' listener+dial pattern (see `Sources/XPCActors/XPCRawTransport.swift`
/// and `Tests/XPCActorsTests/RealXPCEndToEndTests.swift`).
///
/// Two hazards those files ran into, both handled here:
/// 1. The listener's `incomingSessionHandler` runs asynchronously and only once the peer's
///    *first message* arrives -- dialling and even activating the client session is not enough
///    to establish the session server-side. A one-shot inert nudge frame (`.credit(0, n: 0)`,
///    a no-op on the receiving end per Task 4/9) triggers it.
/// 2. The listener's closure builds the server `XPCConnection` off the calling test's task, so
///    the test must wait for it to be published -- done here with a small lock-protected box,
///    polled the same way `RealXPCEndToEndTests`' `Ready`/`waitUntil` do.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct XPCPairHarness {
    func connectPair() async throws -> (XPCConnection, XPCConnection) {
        let box = ServerBox()
        // Not `defer { listener.cancel() }`-ed: unlike an `XPCSession` (which traps on release
        // without a prior `cancel`, see `XPCConnection.deinit`), letting the listener itself
        // fall out of scope here does not crash and cancelling it would tear down the very
        // session the caller is about to use.
        let listener = XPCListener(options: .inactive) { request in
            let (decision, session) = request.accept(
                incomingMessageHandler: { (_: XPCDictionary) -> XPCDictionary? in nil },
                cancellationHandler: { _ in }
            )
            let serverQueue = DispatchSerialQueue(label: "XPCPairHarness.server")
            // `XPCConnection.init` installs its own (real) incoming-message handler and target
            // queue on `session`, replacing the placeholder passed to `accept` above.
            let connection = XPCConnection(session: session, role: .server, queue: serverQueue)
            box.connection = connection
            return decision
        }
        try listener.activate()

        let clientQueue = DispatchSerialQueue(label: "XPCPairHarness.client")
        let clientSession = try XPCSession(endpoint: listener.endpoint, options: .inactive)
        let clientConnection = XPCConnection(session: clientSession, role: .client, queue: clientQueue)
        try clientConnection.activate()

        // See hazard (1) above.
        try clientConnection.send(.credit(0, n: 0))

        guard await waitUntilTrue({ box.connection != nil }) else {
            throw HarnessError("the listener never accepted the client session")
        }
        return (clientConnection, box.connection!)
    }

    /// See hazard (2) above.
    private final class ServerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _connection: XPCConnection?
        var connection: XPCConnection? {
            get { lock.withLock { _connection } }
            set { lock.withLock { _connection = newValue } }
        }
    }
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func waitUntilTrue(timeout seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return condition()
}
