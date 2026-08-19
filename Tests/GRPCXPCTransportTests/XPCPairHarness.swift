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
///    inert as a *top-level* frame -- credit travels on the XPC reply channel, see
///    `XPCConnection.route`'s `.credit` arm) triggers it.
/// 2. The listener's closure builds the server `XPCConnection` off the calling test's task, so
///    the test must wait for it to be published -- done here with a small lock-protected box,
///    polled the same way `RealXPCEndToEndTests`' `Ready`/`waitUntil` do.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct XPCPairHarness {
    /// - Parameter creditWindow: the per-stream flow-control window both connections are built
    ///   with. Defaults to the production value; `BackpressureTests` overrides it to make the
    ///   window's effect (and its lower bound) observable at small, exact numbers.
    func connectPair(creditWindow: Int = XPCBackpressure.defaultCreditWindow)
    async throws -> (XPCConnection, XPCConnection) {
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
            let connection = XPCConnection(session: session, role: .server, queue: serverQueue,
                                           creditWindow: creditWindow)
            box.connection = connection
            return decision
        }
        try listener.activate()

        let clientQueue = DispatchSerialQueue(label: "XPCPairHarness.client")
        let clientConnection = try XPCConnection.connecting(to: listener.endpoint, queue: clientQueue,
                                                            creditWindow: creditWindow)

        // See hazard (1) above.
        try clientConnection.send(.credit(0, n: 0))

        guard await waitUntilTrue({ box.connection != nil }),
              let serverConnection = box.connection else {
            throw HarnessError("the listener never accepted the client session")
        }
        // Hand the server connection's *sole* ownership to the caller. The listener's incoming-
        // session closure captures `box` strongly and the listener itself may outlive this
        // function (libxpc keeps an activated listener alive), so a strong reference left behind
        // in the box would keep the server `XPCConnection` alive for the whole process -- which
        // would both leak its `XPCSession` and make any test of `deinit` reachability vacuous.
        box.connection = nil
        return (clientConnection, serverConnection)
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

/// Polls `condition` until it holds or `seconds` elapse. Shared with `XPCConnectionTests`, which
/// uses it to wait out the transient strong references (an in-flight routing block on the
/// connection's queue) that can briefly outlive the test's own release of a connection.
func waitUntilTrue(timeout seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return condition()
}
