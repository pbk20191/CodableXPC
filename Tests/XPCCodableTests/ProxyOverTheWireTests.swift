#if canImport(Darwin)
import XCTest
import Foundation
import XPCCodable

/// A service handed over as a proxy. Its shapes are what decide whether that
/// works, so it declares one of each.
@XPCService
protocol Meter {
    func peek() async throws -> Int
    func reading() throws -> Int
}

@XPCService
protocol Gauge {
    func inspect(_ meter: XPCProxyMarker<Meter>) async throws -> Int
    func inspectSynchronously(_ meter: XPCProxyMarker<Meter>) async throws -> Int
}

private final class MeterImpl: Meter, @unchecked Sendable {
    func peek() async throws -> Int { 7 }
    func reading() throws -> Int { 7 }
}

private final class GaugeImpl: Gauge, @unchecked Sendable {
    func inspect(_ meter: XPCProxyMarker<Meter>) async throws -> Int {
        try await meter.wrappedValue.peek()
    }
    func inspectSynchronously(_ meter: XPCProxyMarker<Meter>) async throws -> Int {
        try meter.wrappedValue.reading()
    }
}

private final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = GaugeXPC.interface
        connection.exportedObject = GaugeXPC.exported(GaugeImpl())
        connection.resume()
        return true
    }
}

/// What a protocol handed to `XPCProxyMarker` may contain.
///
/// The service calls *back* into the client's object here, over the same
/// connection and in the opposite direction — which is the whole point of a
/// proxy, and also where its one restriction comes from.
final class ProxyOverTheWireTests: XCTestCase {

    private var listener: NSXPCListener!
    private var delegate: Delegate!
    private var connection: NSXPCConnection!

    override func setUp() {
        super.setUp()
        listener = NSXPCListener.anonymous()
        delegate = Delegate()
        listener.delegate = delegate
        listener.resume()

        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = GaugeXPC.interface
        connection.resume()
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
        super.tearDown()
    }

    func testAnAsyncMethodWorksThroughAProxy() async throws {
        let got = try await GaugeXPC.remote(connection).inspect(MeterImpl())
        XCTAssertEqual(got, 7, "the service should have called back into our object")
    }

    /// A synchronous method does not, and says so.
    ///
    /// A blocking client reads its result on the line after the call, which holds
    /// for `synchronousRemoteObjectProxyWithErrorHandler` because that runs the
    /// reply first. An object delivered as an argument has no such proxy: the
    /// reply arrives later and there is nothing to read yet.
    func testASynchronousMethodThroughAProxyIsReportedNotGuessed() async throws {
        do {
            _ = try await GaugeXPC.remote(connection).inspectSynchronously(MeterImpl())
            XCTFail("expected the synchronous call over a proxy to be reported")
        } catch {
            // It crossed a connection on the way back, so it arrives bridged: the
            // service threw XPCServiceError and NSXPC delivered an NSError carrying
            // the domain and the case's index.
            let ns = error as NSError
            XCTAssertEqual(ns.domain, "XPCCodable.XPCServiceError")
            XCTAssertEqual(ns.code, XPCServiceError.allCasesForTesting
                .firstIndex(of: .synchronousCallOverProxy))
        }
    }

    /// Not a test, because it cannot be written as one: it hangs.
    ///
    /// Hold a proxy, invalidate the connection it arrived on, then call it. The
    /// call never completes — the continuation is never resumed, no reply arrives,
    /// and there is no error handler to fire, because an error handler belongs to
    /// a connection and this object is not one. Measured: a run blocked past two
    /// minutes with no output.
    ///
    /// So a proxy has no failure channel of its own. Anything awaiting one should
    /// be bounded by the caller, or torn down from the connection's own
    /// invalidation handler, which does still fire.
    func testAProxyHasNoFailureChannel() {}
}
#endif
