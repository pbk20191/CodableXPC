#if canImport(Darwin)
import XCTest
import Foundation
import XPCCodable

/// The two unbounded growths a proxy-backed client used to have, pinned shut.
///
/// Both were review findings of the same shape as the peer-controlled negative cache in
/// XPCActors: a structure that only ever grew, fed once per call, cleared only by connection
/// death.
///
/// 1. `XPCProxyLifetime.onFailure` appended a closure per call and nothing removed it, so every
///    *completed* call left its callback -- and the whole `XPCCallResumption` it captured --
///    pinned until the connection died. Generated code now registers through `observe(_:)` and
///    the registration is withdrawn when the call completes.
/// 2. Every proxy-returning call built a fresh `XPCProxyLifetime(watching: connection)`, each
///    chaining one more layer onto the connection's single `invalidationHandler` slot, with no
///    way to unchain. `XPCProxyLifetime.watching(_:)` now shares one lifetime per connection.
@XPCService
protocol GrowthMeter {
    func read() async throws -> Int
    func readSync() throws -> Int
}

private final class GrowthMeterImpl: GrowthMeter, @unchecked Sendable {
    func read() async throws -> Int { 9 }
    func readSync() throws -> Int { 9 }
}

final class ProxyLifetimeGrowthTests: XCTestCase {

    /// Completed calls withdraw their registrations: after N async calls over a proxy-source
    /// client, the lifetime holds zero observations -- not N.
    func testCompletedAsyncCallsWithdrawTheirFailureRegistrations() async throws {
        let lifetime = XPCProxyLifetime()
        let client = GrowthMeterXPCClient(
            proxy: GrowthMeterXPC.exported(GrowthMeterImpl()), lifetime: lifetime)

        for _ in 0..<25 {
            _ = try await client.read()
        }
        XCTAssertEqual(lifetime.observationCountForTesting, 0,
                       "completed calls left their failure registrations behind")
    }

    /// The same for the blocking shape, whose withdrawal path is `XPCSyncOutcome.set`.
    func testCompletedSyncCallsWithdrawTheirFailureRegistrations() throws {
        let lifetime = XPCProxyLifetime()
        let client = GrowthMeterXPCClient(
            proxy: GrowthMeterXPC.exported(GrowthMeterImpl()), lifetime: lifetime)

        for _ in 0..<25 {
            _ = try client.readSync()
        }
        XCTAssertEqual(lifetime.observationCountForTesting, 0)
    }

    /// An in-flight registration is still delivered: withdrawal-on-completion must not have
    /// traded away the reason the registration exists.
    func testAnInFlightCallIsStillResolvedByFailure() async throws {
        let lifetime = XPCProxyLifetime()
        let never = NeverReplies()
        let client = GrowthMeterXPCClient(proxy: never, lifetime: lifetime)

        let outcome = Outcome()
        let task = Task {
            do { _ = try await client.read(); outcome.set("returned") }
            catch { outcome.set("threw: \(error is XPCServiceError)") }
        }
        // Let the call register, then kill the lifetime.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(lifetime.observationCountForTesting, 1, "the in-flight call never registered")
        lifetime.fail(XPCServiceError.proxyConnectionInvalidated)

        let deadline = Date().addingTimeInterval(5)
        while outcome.value == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        task.cancel()
        XCTAssertEqual(outcome.value, "threw: true", "the failure never resolved the in-flight call")
        XCTAssertEqual(lifetime.observationCountForTesting, 0)
    }

    /// One lifetime per connection, however many times it is asked for.
    func testWatchingSharesOneLifetimePerConnection() {
        let listener = NSXPCListener.anonymous()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        defer { connection.invalidate() }

        let first = XPCProxyLifetime.watching(connection)
        let second = XPCProxyLifetime.watching(connection)
        XCTAssertTrue(first === second,
                      "each watching(_:) built a fresh lifetime, i.e. a fresh handler chain layer")
        XCTAssertTrue(XPCProxyLifetime.watching(nil) === XPCProxyLifetime.unbounded)
    }

    /// The shared lifetime still hears invalidation -- sharing must not have unhooked it.
    func testTheSharedLifetimeStillHearsInvalidation() async throws {
        let listener = NSXPCListener.anonymous()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.resume()

        let lifetime = XPCProxyLifetime.watching(connection)
        XCTAssertNil(lifetime.recordedFailure)
        connection.invalidate()

        let deadline = Date().addingTimeInterval(5)
        while lifetime.recordedFailure == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertNotNil(lifetime.recordedFailure, "invalidation never reached the shared lifetime")
    }
}

/// A shim that swallows every call, so a registration stays in flight.
private final class NeverReplies: NSObject, GrowthMeterXPCShim, @unchecked Sendable {
    func read(reply: @Sendable @escaping (NSNumber?, (any Error)?) -> Void) {}
    func readSync(reply: @Sendable @escaping (NSNumber?, (any Error)?) -> Void) {}
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? { lock.withLock { _value } }
    func set(_ v: String) { lock.withLock { if _value == nil { _value = v } } }
}
#endif
