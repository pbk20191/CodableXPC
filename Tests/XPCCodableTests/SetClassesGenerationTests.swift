#if canImport(Darwin)
import XCTest
import XPCCodable

/// A plain NSSecureCoding class, the kind NSXPC exists to carry. It is deliberately
/// unmarked in the protocol below, so it crosses natively rather than as a box.
@objc(Widget) final class Widget: NSObject, NSSecureCoding {
    let serial: Int
    static var supportsSecureCoding: Bool { true }
    init(serial: Int) { self.serial = serial }
    func encode(with coder: NSCoder) { coder.encode(serial, forKey: "serial") }
    required init?(coder: NSCoder) { serial = coder.decodeInteger(forKey: "serial") }
}

struct Manifest: Codable, Equatable { let label: String }

@XPCService
protocol Depot {
    /// `widgets` is a container of a custom class. NSXPC refuses those unless the
    /// interface whitelists both the container and the element, which is exactly
    /// what the generated `interface` does.
    func store(_ widgets: [Widget], manifest: XPCCodableMarker<Manifest>) async throws -> XPCCodableMarker<Int>
}

struct DepotService: Depot {
    func store(_ widgets: [Widget], manifest: XPCCodableMarker<Manifest>) async throws -> XPCCodableMarker<Int> {
        XPCCodableMarker(wrappedValue: widgets.reduce(0) { $0 + $1.serial })
    }
}

private final class DepotDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = DepotXPC.interface
        c.exportedObject = DepotXPC.exported(DepotService())
        c.resume()
        return true
    }
}

final class SetClassesGenerationTests: XCTestCase {

    func testTheInterfaceWhitelistsContainerElements() {
        // Read the registration back off the interface. Without the generated
        // setClasses call this set would hold only the default allowed classes and
        // Widget would be missing, and the call in the next test would fail at
        // runtime rather than at compile time.
        let selector = NSSelectorFromString("store:manifest:reply:")
        let classes = DepotXPC.interface.classes(for: selector, argumentIndex: 0, ofReply: false)
        XCTAssertTrue(classes.contains(where: { ($0 as? AnyClass) === NSArray.self }),
                      "expected NSArray to be whitelisted, got \(classes)")
        XCTAssertTrue(classes.contains(where: { ($0 as? AnyClass) === Widget.self }),
                      "expected Widget to be whitelisted, got \(classes)")
    }

    func testAContainerOfCustomClassesActuallyCrosses() async throws {
        let delegate = DepotDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = DepotXPC.interface
        connection.resume()
        defer { connection.invalidate() }

        let depot = DepotXPC.remote(connection)
        let total = try await depot.store([Widget(serial: 10), Widget(serial: 32)],
                                          manifest: Manifest(label: "spring"))
        XCTAssertEqual(total, 42)
    }
}
#endif
