#if canImport(Darwin)
import XCTest
import Foundation
import XPCCodable

/// Every width, plus the edges. `NSNumber` is lossless for all of them, but only
/// if the right accessor comes back out — `intValue` on a `UInt64` near its
/// maximum would silently truncate.
@XPCService
protocol Numbers {
    func i() async throws -> Int
    func i8() async throws -> Int8
    func i64() async throws -> Int64
    func u() async throws -> UInt
    func u64() async throws -> UInt64
    func d() async throws -> Double
    func f() async throws -> Float
    func b() async throws -> Bool
    func s() async throws -> String
}

private final class NumbersImpl: Numbers, @unchecked Sendable {
    func i() async throws -> Int { .min }
    func i8() async throws -> Int8 { -128 }
    func i64() async throws -> Int64 { .max }
    func u() async throws -> UInt { .max }
    func u64() async throws -> UInt64 { .max }
    func d() async throws -> Double { .pi }
    func f() async throws -> Float { -0.5 }
    func b() async throws -> Bool { true }
    func s() async throws -> String { "not a number" }
}

private final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NumbersXPC.interface
        connection.exportedObject = NumbersXPC.exported(NumbersImpl())
        connection.resume()
        return true
    }
}

/// A numeric return could not be declared at all before: an `@objc` reply block
/// cannot carry `Int?`, only a class, so the method failed to compile with the
/// error pointing into generated code. They travel as `NSNumber` now.
final class NumericReturnTests: XCTestCase {

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
        connection.remoteObjectInterface = NumbersXPC.interface
        connection.resume()
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
        super.tearDown()
    }

    func testEveryWidthSurvivesTheNSNumberBridge() async throws {
        let remote = NumbersXPC.remote(connection)

        // The edges are the point: a wrong accessor shows up here and nowhere else.
        let ints = try await (remote.i(), remote.i8(), remote.i64())
        XCTAssertEqual(ints.0, .min)
        XCTAssertEqual(ints.1, -128)
        XCTAssertEqual(ints.2, .max)

        let unsigned = try await (remote.u(), remote.u64())
        XCTAssertEqual(unsigned.0, .max)
        XCTAssertEqual(unsigned.1, .max)

        let floats = try await (remote.d(), remote.f())
        XCTAssertEqual(floats.0, .pi)
        XCTAssertEqual(floats.1, -0.5)

        let flag = try await remote.b()
        XCTAssertTrue(flag)
    }

    func testAStringStillTravelsAsItself() async throws {
        // String bridges to a class, so it was always representable and is left
        // alone -- the NSNumber path is only for what cannot be optional in ObjC.
        let value = try await NumbersXPC.remote(connection).s()
        XCTAssertEqual(value, "not a number")
    }
}
#endif
