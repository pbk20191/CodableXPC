#if canImport(Darwin)
import XCTest
import XPCCodable

struct Visitor: Codable, Equatable {
    let name: String
    let age: Int
}

struct Greeting: Codable, Equatable {
    let text: String
}

enum GreeterFailure: Error {
    case refused
}

/// The whole point: ordinary Swift types, no `CodableBox` in sight.
@XPCService
protocol Greeter {
    func greet(_ person: Visitor) async throws -> Greeting
    func ping() async throws -> Int
    func refuse() async throws
    func note(_ line: String)
}

/// Collects the one-way calls so the test can observe them.
final class Notebook: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

struct GreeterService: Greeter {
    let notebook: Notebook

    func greet(_ person: Visitor) async throws -> Greeting {
        Greeting(text: "Hello \(person.name), age \(person.age)")
    }
    func ping() async throws -> Int { 7 }
    func refuse() async throws { throw GreeterFailure.refused }
    func note(_ line: String) { notebook.append(line) }
}

private final class Delegate: NSObject, NSXPCListenerDelegate {
    let notebook: Notebook
    init(notebook: Notebook) { self.notebook = notebook }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = GreeterXPC.interface
        connection.exportedObject = GreeterXPC.exported(GreeterService(notebook: notebook))
        connection.resume()
        return true
    }
}

/// Drives the generated client and adapter across a real `NSXPCConnection`.
/// An expansion test would only prove the macro emits text; this proves the text works.
final class XPCServiceMacroBehaviourTests: XCTestCase {

    private var listener: NSXPCListener!
    private var delegate: Delegate!
    private var connection: NSXPCConnection!
    private var notebook: Notebook!

    override func setUp() {
        super.setUp()
        notebook = Notebook()
        delegate = Delegate(notebook: notebook)
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = GreeterXPC.interface
        connection.resume()
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
        super.tearDown()
    }

    func testTwoWayCallWithAValue() async throws {
        let greeter = GreeterXPC.remote(connection)
        let greeting = try await greeter.greet(Visitor(name: "Ada", age: 36))
        XCTAssertEqual(greeting, Greeting(text: "Hello Ada, age 36"))
    }

    func testTwoWayCallWithNoArguments() async throws {
        // A zero-parameter method is the case where naive argument joining emits
        // `ping(, reply:)` and fails to compile.
        let greeter = GreeterXPC.remote(connection)
        let pong = try await greeter.ping()
        XCTAssertEqual(pong, 7)
    }

    func testThrownErrorReachesTheCaller() async throws {
        let greeter = GreeterXPC.remote(connection)
        do {
            try await greeter.refuse()
            XCTFail("expected the peer's error to propagate")
        } catch {
            // NSXPC delivers an NSError, so the concrete GreeterFailure does not
            // survive. The documented limitation -- assert the shape we do get.
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    func testOneWayCallArrives() async throws {
        let greeter = GreeterXPC.remote(connection)
        greeter.note("first")
        greeter.note("second")

        // One-way calls have no reply to await, so poll briefly rather than sleeping
        // a fixed amount.
        let deadline = Date().addingTimeInterval(5)
        while notebook.all.count < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(notebook.all, ["first", "second"])
    }

    func testCallOnAnInvalidatedConnectionThrows() async throws {
        let greeter = GreeterXPC.remote(connection)
        connection.invalidate()
        do {
            _ = try await greeter.ping()
            XCTFail("a call on an invalidated connection must not succeed")
        } catch {
            // This is the path that requires XPCOneShot: the error handler and the
            // reply block are independent, and resuming a continuation twice traps.
            XCTAssertFalse("\(error)".isEmpty)
        }
    }
}
#endif
