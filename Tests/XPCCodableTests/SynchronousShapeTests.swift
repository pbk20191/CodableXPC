#if canImport(Darwin)
import XCTest
import Foundation
import XPCCodable

struct Receipt: Codable, Equatable { let id: String }
private struct Refused: Error, Equatable { let why: String }

/// `throws` and `throws -> T`, with no `async`. Same wire shape as their async
/// counterparts; the caller blocks instead of suspending.
@XPCService
protocol Till {
    func ring(_ cents: Int) throws -> Int
    func void(_ reason: String) throws
    func issue(_ receipt: XPCCodableMarker<Receipt>) throws -> XPCCodableMarker<Receipt>
    func refuse() throws
}

private final class TillImpl: Till, @unchecked Sendable {
    func ring(_ cents: Int) throws -> Int { cents * 2 }
    func void(_ reason: String) throws {}
    func issue(_ receipt: XPCCodableMarker<Receipt>) throws -> XPCCodableMarker<Receipt> {
        XPCCodableMarker(wrappedValue: Receipt(id: receipt.wrappedValue.id + "-void"))
    }
    func refuse() throws { throw Refused(why: "drawer open") }
}

private final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = TillXPC.interface
        connection.exportedObject = TillXPC.exported(TillImpl())
        connection.resume()
        return true
    }
}

final class SynchronousShapeTests: XCTestCase {

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
        connection.remoteObjectInterface = TillXPC.interface
        connection.resume()
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
        super.tearDown()
    }

    func testAValueComesBackWithoutAwaiting() throws {
        // No `await` on this line: that is the whole feature.
        XCTAssertEqual(try TillXPC.remote(connection).ring(21), 42)
    }

    func testAVoidCallReturnsWhenThePeerIsDone() throws {
        XCTAssertNoThrow(try TillXPC.remote(connection).void("mistake"))
    }

    func testABoxedValueRoundTripsSynchronously() throws {
        let out = try TillXPC.remote(connection).issue(Receipt(id: "A-1"))
        XCTAssertEqual(out, Receipt(id: "A-1-void"))
    }

    func testAPeerErrorArrivesAsAThrow() throws {
        // The peer's own error, not a transport failure.
        XCTAssertThrowsError(try TillXPC.remote(connection).refuse())
    }

    /// The reason a value return must be able to throw: this is the only channel
    /// a dropped connection has. The error handler runs before the proxy call
    /// returns, so it lands as a throw rather than as a hang.
    func testADeadConnectionThrowsRatherThanHanging() throws {
        let dead = NSXPCConnection(listenerEndpoint: listener.endpoint)
        dead.remoteObjectInterface = TillXPC.interface
        dead.resume()
        dead.invalidate()

        XCTAssertThrowsError(try TillXPC.remote(dead).ring(1)) { error in
            XCTAssertEqual((error as NSError).code, NSXPCConnectionInvalid)
        }
    }

    /// A shape that cannot report a dropped connection stays rejected. There is no
    /// test for it here — it does not compile — but the diagnostic is what a caller
    /// meets, so its wording is the contract:
    ///
    ///     func ring(_ cents: Int) -> Int
    ///     // @XPCService cannot express this method. A method that returns a value
    ///     // has to be able to throw…
    func testTheRejectedShapesAreDocumented() {}
}
#endif
