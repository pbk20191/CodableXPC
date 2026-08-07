#if canImport(Darwin)
import XCTest
import Foundation
import XPCCodable

@XPCService
protocol Beacon {
    func ping(_ note: String)                  // one-way: cannot throw
    func echo(_ note: String) async throws -> String
}

private final class BeaconImpl: Beacon, @unchecked Sendable {
    func ping(_ note: String) {}
    func echo(_ note: String) async throws -> String { note }
}

/// A one-way method has no reply block and cannot throw, so a failure has
/// nowhere to go but a trap. The alternative — returning quietly — lets a call
/// that never happened look like one that did.
///
/// Only what can be known *at the call* traps. A connection reports
/// asynchronously through its error handler and offers no way to ask now, so a
/// connection dying mid-call stays silent for a one-way method, which is what
/// NSXPC does with such messages anyway. A proxy is different: the adapter that
/// received it recorded its connection, so the client can check.
final class OneWayTrapTests: XCTestCase {

    func testAOneWayCallOnALiveProxySucceeds() {
        let shim = BeaconXPC.exported(BeaconImpl())
        let client = BeaconXPCClient(proxy: shim)
        client.ping("fine")           // no trap
    }

    func testTheLifetimeIsWhatMakesTheDeadCaseKnowable() {
        let lifetime = XPCProxyLifetime()
        XCTAssertNil(lifetime.recordedFailure)

        lifetime.fail(XPCServiceError.proxyConnectionInvalidated)
        XCTAssertEqual(lifetime.recordedFailure as? XPCServiceError,
                       .proxyConnectionInvalidated)

        // First write wins, so the reason a caller sees is the one that happened.
        lifetime.fail(XPCServiceError.missingReply)
        XCTAssertEqual(lifetime.recordedFailure as? XPCServiceError,
                       .proxyConnectionInvalidated)
    }

    /// There is no test calling `ping` on a dead proxy, because it traps and takes
    /// the runner with it. Verified by hand instead:
    ///
    ///     let lifetime = XPCProxyLifetime()
    ///     let client = BeaconXPCClient(proxy: shim, lifetime: lifetime)
    ///     lifetime.fail(XPCServiceError.proxyConnectionInvalidated)
    ///     client.ping("gone")
    ///     // Fatal error: Beacon.ping: one-way call on a dead peer --
    ///     //   proxyConnectionInvalidated
    ///
    /// Trapping is the point. The two-way shapes throw instead, and that is
    /// covered by `ProxyOverTheWireTests`.
    func testTheDeadCaseIsDocumentedRatherThanRun() {}
}
#endif
