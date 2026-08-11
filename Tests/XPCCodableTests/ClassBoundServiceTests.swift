#if canImport(Darwin)
import XCTest
import Foundation
import XPCCodable

/// A class-bound service protocol, which is a natural thing to write and used not to work.
///
/// `@XPCService` generated a `struct` client, so `protocol P: AnyObject` failed with *"non-class
/// type 'PXPCClient' cannot conform to class protocol 'P'"* -- reported inside macro expansion,
/// pointing at code the author never wrote. The client is now a `final class` when the protocol
/// is class-bound.
///
/// `AnyObject` and `Sendable` are the only two inherited protocols the macro admits. Everything
/// else is refused, because a syntactic macro cannot see an inherited protocol's requirements and
/// would silently not carry them -- see `XPCServiceMacroDiagnosticTests`.
@XPCService
protocol ClassBoundLedger: AnyObject {
    func total() async throws -> Int
    func record(_ amount: Int) async throws
    func note(_ line: String)
}

/// `Sendable` alongside it, since a service protocol that is class-bound is usually also crossing
/// isolation domains. Two harmless names together must stay harmless.
@XPCService
protocol SendableLedger: AnyObject, Sendable {
    func total() async throws -> Int
}

private final class LedgerImpl: ClassBoundLedger, SendableLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var sum = 0
    private var notes: [String] = []

    func total() async throws -> Int { lock.withLock { sum } }
    func record(_ amount: Int) async throws { lock.withLock { sum += amount } }
    func note(_ line: String) { lock.withLock { notes.append(line) } }
    var noteCount: Int { lock.withLock { notes.count } }
}

private final class Delegate: NSObject, NSXPCListenerDelegate {
    let impl = LedgerImpl()
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = ClassBoundLedgerXPC.interface
        connection.exportedObject = ClassBoundLedgerXPC.exported(impl)
        connection.resume()
        return true
    }
}

final class ClassBoundServiceTests: XCTestCase {

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
        connection.remoteObjectInterface = ClassBoundLedgerXPC.interface
        connection.resume()
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
        super.tearDown()
    }

    /// The whole point: it compiles, and every shape still crosses.
    ///
    /// That this file compiles at all is half the test -- a struct client would not satisfy
    /// `ClassBoundLedger`, so a regression is a build failure rather than a red assertion. The
    /// calls are here so the class client is exercised on all three shapes and not merely
    /// declared.
    func testAClassBoundProtocolWorksAcrossAllThreeShapes() async throws {
        let ledger = ClassBoundLedgerXPC.remote(connection)

        try await ledger.record(7)
        try await ledger.record(5)
        let total = try await ledger.total()
        XCTAssertEqual(total, 12)

        // One-way: nothing to await, so poll the far side rather than assume it arrived.
        ledger.note("first")
        let arrived = await waitFor { delegate.impl.noteCount == 1 }
        XCTAssertTrue(arrived, "the one-way call never reached the service")
    }

    /// A class client is a reference, so two `remote(_:)` calls are two objects over one
    /// connection -- and both work.
    ///
    /// Worth pinning because the struct client had value semantics and this is the one
    /// behavioural difference the change introduces. Nothing in the design depends on identity,
    /// which is what this says.
    func testTwoClientsOverOneConnectionBothWork() async throws {
        let a = ClassBoundLedgerXPC.remote(connection)
        let b = ClassBoundLedgerXPC.remote(connection)
        XCTAssertFalse(a === b, "remote(_:) should hand back a fresh client each time")

        try await a.record(3)
        let seen = try await b.total()
        XCTAssertEqual(seen, 3, "the second client saw a different service")
    }

    /// `AnyObject, Sendable` together, which is the shape a real service protocol tends to have.
    func testAClassBoundSendableProtocolAlsoGenerates() async throws {
        // Its own connection, because its interface is a different shim.
        let listener = NSXPCListener.anonymous()
        let delegate = SendableDelegate()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = SendableLedgerXPC.interface
        connection.resume()
        defer { connection.invalidate() }

        let total = try await SendableLedgerXPC.remote(connection).total()
        XCTAssertEqual(total, 0)
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
}

private final class SendableDelegate: NSObject, NSXPCListenerDelegate {
    let impl = LedgerImpl()
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = SendableLedgerXPC.interface
        connection.exportedObject = SendableLedgerXPC.exported(impl)
        connection.resume()
        return true
    }
}
#endif
