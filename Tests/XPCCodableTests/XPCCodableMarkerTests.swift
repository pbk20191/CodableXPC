#if canImport(Darwin)
import XCTest
import XPCCodable

struct Order: Codable, Equatable {
    let sku: String
    let quantity: Int
}

/// Only the marked parameter is boxed. `count` and `note` are types Objective-C
/// already understands, so they cross as themselves.
@XPCService
protocol Warehouse {
    func submit(_ order: XPCCodableMarker<Order>, count: Int, note: String) async throws -> XPCCodableMarker<Order>
    func audit(_ order: XPCCodableMarker<Order>)
}

final class Ledger: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Order] = []
    func record(_ o: Order) { lock.lock(); seen.append(o); lock.unlock() }
    var all: [Order] { lock.lock(); defer { lock.unlock() }; return seen }
}

struct WarehouseService: Warehouse {
    let ledger: Ledger
    func submit(_ order: XPCCodableMarker<Order>, count: Int, note: String) async throws -> XPCCodableMarker<Order> {
        XPCCodableMarker(wrappedValue:
            Order(sku: order.wrappedValue.sku + note, quantity: order.wrappedValue.quantity * count))
    }
    func audit(_ order: XPCCodableMarker<Order>) { ledger.record(order.wrappedValue) }
}

private final class WarehouseDelegate: NSObject, NSXPCListenerDelegate {
    let ledger: Ledger
    init(ledger: Ledger) { self.ledger = ledger }
    func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = WarehouseXPC.interface
        c.exportedObject = WarehouseXPC.exported(WarehouseService(ledger: ledger))
        c.resume()
        return true
    }
}

final class XPCCodableMarkerTests: XCTestCase {

    private var listener: NSXPCListener!
    private var delegate: WarehouseDelegate!
    private var connection: NSXPCConnection!
    private var ledger: Ledger!

    override func setUp() {
        super.setUp()
        ledger = Ledger()
        delegate = WarehouseDelegate(ledger: ledger)
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = WarehouseXPC.interface
        connection.resume()
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
        super.tearDown()
    }

    func testMixedBoxedAndPassthroughParameters() async throws {
        let warehouse = WarehouseXPC.remote(connection)
        // The convenience overload: a bare Order, not XPCCodableMarker(wrappedValue:).
        // Without the generated protocol extension this line would not compile.
        let result = try await warehouse.submit(Order(sku: "A", quantity: 3), count: 4, note: "-rush")
        XCTAssertEqual(result, Order(sku: "A-rush", quantity: 12))
    }

    func testTheMarkerFormAlsoWorks() async throws {
        // The requirement itself is still callable, for anyone who wants it explicit.
        let warehouse = WarehouseXPC.remote(connection)
        let result = try await warehouse.submit(
            XPCCodableMarker(wrappedValue: Order(sku: "B", quantity: 1)), count: 2, note: "!")
        // The requirement returns the marker; the convenience overload unwraps it.
        XCTAssertEqual(result.wrappedValue, Order(sku: "B!", quantity: 2))
    }

    func testOneWayWithAMarkedParameter() async throws {
        let warehouse = WarehouseXPC.remote(connection)
        warehouse.audit(Order(sku: "C", quantity: 9))
        let deadline = Date().addingTimeInterval(5)
        while ledger.all.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(ledger.all, [Order(sku: "C", quantity: 9)])
    }

    func testOnlyTheMarkedParameterIsBoxed() throws {
        // The decisive check, read off the generated Objective-C method itself.
        // Type encodings: '@' is an object (the box), 'q' a long (Int passed through).
        // A selector name alone would not prove this -- it does not encode types.
        let adapter: AnyObject = WarehouseXPC.exported(WarehouseService(ledger: Ledger()))
        let selector = NSSelectorFromString("submit:count:note:reply:")
        XCTAssertTrue(adapter.responds(to: selector), "expected submit:count:note:reply:")

        let method = try XCTUnwrap(class_getInstanceMethod(type(of: adapter), selector))
        let encoding = String(cString: try XCTUnwrap(method_getTypeEncoding(method)))

        // Layout is: return, self, _cmd, then the four arguments.
        var argumentTypes: [String] = []
        for index in 2..<Int(method_getNumberOfArguments(method)) {
            let raw = method_copyArgumentType(method, UInt32(index))
            defer { free(raw) }
            argumentTypes.append(String(cString: try XCTUnwrap(raw)))
        }
        XCTAssertEqual(argumentTypes.count, 4, "encoding was \(encoding)")
        XCTAssertEqual(argumentTypes[0], "@", "the marked Order must cross as a boxed object")
        XCTAssertEqual(argumentTypes[1], "q", "Int must cross as a long, not a box")
        XCTAssertEqual(argumentTypes[2], "@", "String crosses as NSString, an object")
        XCTAssertEqual(argumentTypes[3], "@?", "the reply block")
    }
}
#endif
