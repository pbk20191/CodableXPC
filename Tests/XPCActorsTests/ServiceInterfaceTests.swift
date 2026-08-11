#if canImport(Darwin)
import XCTest
import XPC
import Distributed
@testable import XPCActors

/// The front door: `TransportReceiver` serving, `LocalInterface` exporting, `RemoteInterface`
/// importing -- over a real anonymous `XPCListener`, so the same machinery the two-process demo
/// uses is what these exercise.
///
/// The demo proves the whole path works once. These pin the parts of it that can regress
/// silently: the well-known key both sides mint, and the activation gate, whose entire purpose
/// is to be invisible when nothing races.
@available(macOS 13, *)
final class ServiceInterfaceTests: XCTestCase {

    // MARK: Naming

    /// The two prefixes are Swift small strings in Apple's binary, assembled from `movz`/`movk`
    /// immediates -- they appear in no string table, so this is the one place they can be
    /// checked against a re-reading of the disassembly.
    func testServiceDebugNameCarriesTheKindPrefix() {
        XCTAssertEqual(XPCActorSystem.Service.machService("com.example.d").debugName,
                       "mach:com.example.d")
        XCTAssertEqual(XPCActorSystem.Service.xpcService("com.example.s").debugName,
                       "xpc:com.example.s")
        XCTAssertEqual(XPCActorSystem.Service.machService("n").name, "n")
    }

    /// Same name, different kind, different service -- `isMach` is part of the identity, not a
    /// display detail. If it were dropped from `==` a Mach service and an XPC service with one
    /// name would collide in any table keyed by `Service`.
    func testAMachAndAnXPCServiceWithOneNameAreNotEqual() {
        XCTAssertNotEqual(XPCActorSystem.Service.machService("same"),
                          XPCActorSystem.Service.xpcService("same"))
    }

    // MARK: Exporting and importing

    /// A well-known name is enough to reach an actor that was never handed over.
    func testAServerActorIsReachableByName() async throws {
        let served = try await ServedLink { local in
            let greeter = NamedGreeter(actorSystem: local.session.system)
            local.export(greeter, asServerActorFor: "greeter")
            return await local.activateThenWaitForCancellation()
        }
        defer { served.tearDown() }

        let proxy: NamedGreeter = served.client.remote.import(clientActorFor: "greeter")
        let box = Box<String>()
        let task = Task {
            do { box.set(.success(try await proxy.greet())) }
            catch { box.set(.failure(error)) }
        }
        guard await waitUntil({ box.outcome != nil }) else {
            return XCTFail("the named actor never answered")
        }
        task.cancel()
        XCTAssertEqual(try box.outcome?.get(), "hello from the server actor")
    }

    /// A name nobody exported yields a proxy all the same, and the failure lands at the call.
    ///
    /// This is the protocol's shape rather than a shortcoming: there is no "does this key
    /// exist" request on the wire, so a lookup would have to invent one. What matters is that
    /// the call **fails** rather than hanging -- the peer answers "nothing is shared there",
    /// and a receiver that dropped the request instead would park the caller forever.
    func testAnUnexportedNameFailsAtTheCallRatherThanHanging() async throws {
        let served = try await ServedLink { local in
            let greeter = NamedGreeter(actorSystem: local.session.system)
            local.export(greeter, asServerActorFor: "greeter")
            return await local.activateThenWaitForCancellation()
        }
        defer { served.tearDown() }

        let proxy: NamedGreeter = served.client.remote.import(clientActorFor: "nobodyHome")
        let box = Box<String>()
        let task = Task {
            do { box.set(.success(try await proxy.greet())) }
            catch { box.set(.failure(error)) }
        }
        guard await waitUntil({ box.outcome != nil }) else {
            return XCTFail("an unexported name hung instead of failing")
        }
        task.cancel()
        XCTAssertThrowsError(try box.outcome?.get()) { error in
            XCTAssertTrue("\(error)".contains("no actor is shared"), "\(error)")
        }
    }

    // MARK: The activation gate

    /// A request that beats the service's own setup waits, rather than failing to resolve.
    ///
    /// The ordering hazard is real and normally invisible: `TransportReceiver` starts the peer
    /// handler on a plain `Task`, so a quick client can get a request in before the handler has
    /// exported anything. Here the handler is held *open* until the test releases it, which
    /// makes the race deterministic instead of hoping for it.
    ///
    /// Poll rather than `await` the call directly -- if the gate ever fails to open, an `await`
    /// turns this into a hang instead of a failure, and this suite has been wedged that way
    /// before.
    func testARequestArrivingBeforeActivationWaitsAndThenSucceeds() async throws {
        let releaseSetup = ActivationEvent(posted: false)
        let served = try await ServedLink(activateEagerly: false) { local in
            // Nothing is exported and nothing is activated until the test says so.
            await releaseSetup.wait()
            let greeter = NamedGreeter(actorSystem: local.session.system)
            local.export(greeter, asServerActorFor: "greeter")
            return await local.activateThenWaitForCancellation()
        }
        defer { served.tearDown() }

        let proxy: NamedGreeter = served.client.remote.import(clientActorFor: "greeter")
        let box = Box<String>()
        let task = Task {
            do { box.set(.success(try await proxy.greet())) }
            catch { box.set(.failure(error)) }
        }

        // The call is in flight against a service that has exported nothing. It must not have
        // been answered -- neither with a result nor with a failure.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(box.outcome,
                     "the request was answered before the local interface was activated")

        releaseSetup.post()
        guard await waitUntil({ box.outcome != nil }) else {
            return XCTFail("the request never completed after activation")
        }
        task.cancel()
        XCTAssertEqual(try box.outcome?.get(), "hello from the server actor")
    }

    // MARK: Receiver bookkeeping

    /// A served peer is tracked while it lives and gone once it is unwound.
    func testUnwindPeersWaitsForTheHandlersItCancels() async throws {
        let served = try await ServedLink { local in
            let greeter = NamedGreeter(actorSystem: local.session.system)
            local.export(greeter, asServerActorFor: "greeter")
            return await local.activateThenWaitForCancellation()
        }
        defer { served.tearDown() }

        XCTAssertEqual(served.receiver.peerTaskCount, 1)
        await served.receiver.unwindPeers()
        // `unwindPeers` awaits every handler's result, so by the time it returns there is
        // nothing still running -- a signal-and-return would leave this racy.
        XCTAssertEqual(served.receiver.peerTaskCount, 0)
    }
}

// MARK: - the actor

@available(macOS 13, *)
distributed actor NamedGreeter {
    typealias ActorSystem = XPCActorSystem
    distributed func greet() -> String { "hello from the server actor" }
}

// MARK: - a real listener served by a TransportReceiver

/// The service side built the way a service process builds it -- `TransportReceiver` plus a
/// listener -- but on an anonymous endpoint, so no bundle and no launchd are involved.
@available(macOS 13, *)
private final class ServedLink: @unchecked Sendable {

    let serverSystem = XPCActorSystem("served")
    let clientSystem = XPCActorSystem("client")
    let receiver: XPCActorSystem.TransportReceiver

    private let listener: XPCConnectionListener
    private var clientTransport: Transport!
    let client: Session

    /// - Parameter activateEagerly: whether to wait for the server side to be serving before
    ///   returning. `false` is what the activation-gate test needs: it wants the client's first
    ///   request to reach a session whose handler has not run yet.
    init(
        activateEagerly: Bool = true,
        peerHandler: @escaping @Sendable (consuming Session.LocalInterface) async
            -> (result: (), token: Session.LocalInterface.ActivationToken)
    ) async throws {
        let system = serverSystem
        receiver = XPCActorSystem.TransportReceiver(actorSystem: system, peerHandler: peerHandler)

        let receiver = self.receiver
        listener = XPCConnectionListener.anonymous { raw in
            receiver.accept(raw, debugName: "served")
        }
        receiver.setCancellationHandler { [listener] in listener.cancel() }

        let raw = XPCConnectionTransport.connecting(to: listener.endpoint)
        clientTransport = Transport(debugName: "client", role: .initiator, rawTransport: raw)
        client = clientSystem.makeSession(over: clientTransport)
        try raw.activate()

        // The listener's handler does not run until the peer's first message arrives -- dialling
        // alone establishes nothing. A notification needs no reply, so it is the cheapest nudge.
        let nudge = try Packet.Payload(
            encoding: RemoteNotification.invocationCancelled(id: ID64(rawValue: .max)),
            userInfo: [:])
        try clientTransport.sendNotification(nudge)

        guard await waitUntil({ receiver.peerTaskCount == 1 }) else {
            throw SetupError("the receiver never attached a peer")
        }
        if activateEagerly {
            // Give the handler a moment to have exported and activated, so tests that are not
            // *about* the gate do not race it.
            _ = await waitUntil { true }
        }
    }

    func tearDown() {
        clientTransport?.cancel(reason: "test over")
        listener.cancel()
    }
}

@available(macOS 13, *)
private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcome: Result<Value, any Error>?
    var outcome: Result<Value, any Error>? { lock.withLock { _outcome } }
    func set(_ value: Result<Value, any Error>) { lock.withLock { _outcome = value } }
}
#endif
