import XCTest
import Distributed
@testable import XPCActors

/// The same-process optimization, end to end: a client dialling a service served in this same
/// process is wired to it through ``ServiceRegistry`` and calls it over the `.local` session's
/// direct-invocation path -- **no transport, and nothing encoded**. There is deliberately no
/// listener anywhere here, so a call that returns a result can only have taken the direct path.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class SameProcessOptimizationTests: XCTestCase {

    private func serve(_ service: XPCActorSystem.Service, on serverSystem: XPCActorSystem) {
        let receiver = XPCActorSystem.TransportReceiver(actorSystem: serverSystem) { local in
            let greeter = DirectGreeter(actorSystem: local.session.system)
            local.export(greeter, asServerActorFor: "greeter")
            return await local.activateThenWaitForCancellation()
        }
        ServiceRegistry.shared.register(
            service, receiver: receiver, actorSystem: serverSystem, targetQueue: nil)
    }

    func testASameProcessCallTakesTheDirectPathAndComesBack() async throws {
        let serverSystem = XPCActorSystem("server")
        let service = XPCActorSystem.Service.machService("com.example.sameprocess.call")
        defer { ServiceRegistry.shared.unregister(service) }
        serve(service, on: serverSystem)

        let clientSystem = XPCActorSystem("client")
        let session = try service.connect(from: clientSystem, with: .init(options: []))
        let proxy: DirectGreeter = session.remote.import(clientActorFor: "greeter")

        let result = try await proxy.greet(name: "world")
        XCTAssertEqual(result, "hello, world")
    }

    func testADirectCallCarriesActualArgumentValues() async throws {
        let serverSystem = XPCActorSystem("server")
        let service = XPCActorSystem.Service.machService("com.example.sameprocess.args")
        defer { ServiceRegistry.shared.unregister(service) }
        serve(service, on: serverSystem)

        let session = try service.connect(from: XPCActorSystem("client"), with: .init(options: []))
        let proxy: DirectGreeter = session.remote.import(clientActorFor: "greeter")
        let sum = try await proxy.add(3, 4)
        XCTAssertEqual(sum, 7)
    }

    /// Cancelling the client end tears down the paired server end, so its handler stops
    /// parking rather than living until the receiver unwinds.
    func testCancellingTheClientReleasesTheServerHandler() async throws {
        let released = Released()
        let serverSystem = XPCActorSystem("server")
        let service = XPCActorSystem.Service.machService("com.example.sameprocess.teardown")
        defer { ServiceRegistry.shared.unregister(service) }
        let receiver = XPCActorSystem.TransportReceiver(actorSystem: serverSystem) { local in
            let greeter = DirectGreeter(actorSystem: local.session.system)
            local.export(greeter, asServerActorFor: "greeter")
            let outcome = await local.activateThenWaitForCancellation()
            released.set()   // reached only once the server end is cancelled
            return outcome
        }
        ServiceRegistry.shared.register(
            service, receiver: receiver, actorSystem: serverSystem, targetQueue: nil)

        let session = try service.connect(from: XPCActorSystem("client"), with: .init(options: []))
        let proxy: DirectGreeter = session.remote.import(clientActorFor: "greeter")
        _ = try await proxy.greet(name: "x")   // establish the pair; the server handler parks
        XCTAssertFalse(released.isSet, "the server handler released before the client went away")

        session.cancel(because: "test over")
        let torn = await waitUntil { released.isSet }
        XCTAssertTrue(torn, "cancelling the client never released the paired server handler")
    }

    func testADirectThrowComesBack() async throws {
        let serverSystem = XPCActorSystem("server")
        let service = XPCActorSystem.Service.machService("com.example.sameprocess.throw")
        defer { ServiceRegistry.shared.unregister(service) }
        serve(service, on: serverSystem)

        let session = try service.connect(from: XPCActorSystem("client"), with: .init(options: []))
        let proxy: DirectGreeter = session.remote.import(clientActorFor: "greeter")
        do {
            _ = try await proxy.failing()
            XCTFail("the throwing call did not throw")
        } catch {
            XCTAssertTrue("\(error)".contains("boom"), "\(error)")
        }
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
distributed actor DirectGreeter {
    typealias ActorSystem = XPCActorSystem
    distributed func greet(name: String) -> String { "hello, \(name)" }
    distributed func add(_ a: Int, _ b: Int) -> Int { a + b }
    distributed func failing() throws -> Int { throw DirectGreeterError.boom }
}

enum DirectGreeterError: Error { case boom }

private final class Released: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
