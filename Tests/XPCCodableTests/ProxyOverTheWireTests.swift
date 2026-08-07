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
    func hold(_ meter: XPCProxyMarker<Meter>)
    func callHeld() async throws -> Int
    func inspect(_ meter: XPCProxyMarker<Meter>) async throws -> Int
    func inspectSynchronously(_ meter: XPCProxyMarker<Meter>) async throws -> Int
}

private final class MeterImpl: Meter, @unchecked Sendable {
    func peek() async throws -> Int { 7 }
    func reading() throws -> Int { 7 }
}

/// Survives the connection, so a held proxy can be called after it dies.
private final class Held: @unchecked Sendable { var meter: (any Meter)? }
private let held = Held()

private final class GaugeImpl: Gauge, @unchecked Sendable {
    func hold(_ meter: XPCProxyMarker<Meter>) { held.meter = meter.wrappedValue }
    func callHeld() async throws -> Int { try await held.meter!.peek() }
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

    /// The case that used to hang forever.
    ///
    /// Hold a proxy, invalidate the connection it arrived over, then call it. A
    /// proxy is not a connection and has no error handler, so nothing replied and
    /// nothing failed -- the continuation was simply never resumed. A run blocked
    /// past two minutes with no output.
    ///
    /// The adapter that received the proxy knows the connection, because
    /// `NSXPCConnection.current()` is set while the call is being handled. It
    /// records invalidation there, and that recording is what this call now fails
    /// with instead of waiting.
    func testAProxyFailsOnceItsConnectionIsGone() async throws {
        held.meter = nil
        GaugeXPC.remote(connection).hold(MeterImpl())
        // hold() is one-way, so wait for it to have landed before tearing down.
        for _ in 0..<50 where held.meter == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let meter = try XCTUnwrap(held.meter, "the proxy never arrived")

        connection.invalidate()
        try await Task.sleep(nanoseconds: 200_000_000)

        do {
            let value = try await meter.peek()
            XCTFail("expected a failure once the connection was gone, got \(value)")
        } catch {
            XCTAssertEqual(error as? XPCServiceError, .proxyConnectionInvalidated)
        }
    }
}
#endif
