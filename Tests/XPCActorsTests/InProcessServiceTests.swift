#if canImport(Darwin)
import XCTest
import Distributed
@testable import XPCActors

/// ``XPCActorSystem/InProcessService`` -- a named service reached over an in-process transport,
/// no launchd and no XPC crossing. `listen(on:executingForEachPeer:)` registers a server under a
/// name; `makeRemoteInterface(to:)` dials it, paired over an ``Transport.InProcessRawTransport``, and a
/// call crosses that transport and comes back.
///
/// The mechanism here is a designed reconstruction (Apple's `InProcessService.connect` does not
/// resolve from the binary); this proves the reconstructed shape end to end.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class InProcessServiceTests: XCTestCase {

    func testAnInProcessServiceCarriesACall() async throws {
        let serverSystem = XPCActorSystem("ip-server")
        let service = XPCActorSystem.InProcessService("test.inprocess.call")
        let listening = Task {
            try await serverSystem.listen(on: service) { local in
                local.export(DirectGreeter(actorSystem: serverSystem), asServerActorFor: "greeter")
                return await local.activateThenWaitForCancellation()
            }
        }
        defer { listening.cancel() }

        guard await waitUntil({
            InProcessListenerRegistry.shared.receiver(for: service.name) != nil
        }) else {
            return XCTFail("the in-process listener never registered")
        }

        let client = XPCActorSystem("ip-client")
        let remote = try await client.makeRemoteInterface(to: service)
        let proxy: DirectGreeter = remote.import(clientActorFor: "greeter")

        let box = ResultBox()
        let call = Task {
            do { box.set(.success(try await proxy.greet(name: "inproc"))) }
            catch { box.set(.failure(error)) }
        }
        guard await waitUntil({ box.outcome != nil }) else {
            return XCTFail("the call never came back over the in-process service")
        }
        call.cancel()
        XCTAssertEqual(try box.outcome?.get(), "hello, inproc")
    }

    /// A dial with no listener registered fails cleanly rather than hanging.
    func testDiallingAnUnservedInProcessServiceThrows() async throws {
        let client = XPCActorSystem("ip-client-miss")
        let service = XPCActorSystem.InProcessService("test.inprocess.absent")
        do {
            _ = try await client.makeRemoteInterface(to: service)
            XCTFail("dialling an unserved in-process service should have thrown")
        } catch {
            XCTAssertTrue("\(error)".contains("no in-process service is listening"), "\(error)")
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcome: Result<String, any Error>?
    var outcome: Result<String, any Error>? { lock.withLock { _outcome } }
    func set(_ value: Result<String, any Error>) { lock.withLock { _outcome = value } }
}
#endif
