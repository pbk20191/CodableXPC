#if canImport(Darwin)
import XCTest
import XPC
import Distributed
import XPCOverlayCoder
@testable import XPCActors

/// The whole stack over **real XPC**, not the in-process loopback.
///
/// Every other end-to-end test in this package runs two `XPCActorSystem`s over
/// `InProcessRawTransport`, a queue-based pair that never touches XPC. That exercises
/// the format and the session layer and proves nothing about the transport: the
/// envelope is handed straight from one closure to another, so `xpc_dictionary_*`
/// round-tripping, the overlay coder's `xpc_data` body, and the connection lifecycle
/// are all bypassed.
///
/// Here an anonymous `XPCListener` publishes an endpoint that is dialled from this same
/// process, so every packet is serialised, crosses the kernel, and is reassembled by
/// `libxpc` before our code sees it again. Same process, real transport — which is the
/// most this repository can reach, since a real *peer* refuses us at the entitlement
/// wall before it looks at our bytes (see the wire-format spec).
@available(macOS 26, *)
final class RealXPCEndToEndTests: XCTestCase {

    func testACallCrossesRealXPCAndComesBack() async throws {
        let link = try await RealLink()
        defer { link.tearDown() }

        let greeter = WireGreeter(actorSystem: link.serverSystem)
        let proxy = try link.proxy(WireGreeter.self, at: try link.export(greeter.id))

        let box = Box<String>()
        let task = Task {
            do { box.set(.success(try await proxy.greet(name: "wire"))) }
            catch { box.set(.failure(error)) }
        }
        guard await waitUntil({ box.outcome != nil }) else {
            return XCTFail("the call never came back over real XPC")
        }
        task.cancel()
        XCTAssertEqual(try box.outcome?.get(), "hello wire")
        withExtendedLifetime(greeter) {}
    }

    /// Our packet survives a real XPC crossing with its body still an `xpc_data` blob.
    ///
    /// Separate from the call above on purpose: `XPCRawTransport.accepting` owns the
    /// listener's message handler, so there is no seam to snoop the actor stack's own
    /// traffic without adding production API for a test. This sends the same bytes our
    /// transport would send, through the same machinery, and inspects what arrives —
    /// which is the property the overlay-coder pivot rests on, observed after a crossing
    /// rather than before one.
    func testOurPacketSurvivesARealXPCCrossingWithADataBody() async throws {
        let body = InvocationBody(protocolStub: nil, genericSubsitutions: [],
                                  arguments: [7 as Int], errorType: nil, returnType: nil)
        let request = RemoteInvocationRequest(
            id: ID64(rawValue: 3), basePriority: .high,
            targetedSharedActor: .exportedRawValue("primary"),
            remoteCallIdentifier: "probe", contents: body)
        let sent = Packet(header: .request(ID64(rawValue: 3)),
                          payload: try Packet.Payload(encoding: request, userInfo: [:]))

        let arrived = Arrived()
        let listener = XPCListener(targetQueue: nil, options: .inactive) { request in
            request.accept { (message: XPCDictionary) -> XPCDictionary? in
                message.withUnsafeUnderlyingDictionary { raw in arrived.store(xpc_copy(raw)!) }
                return nil
            }
        }
        try listener.activate()
        defer { listener.cancel() }

        let session = try XPCSession(endpoint: listener.endpoint, options: .inactive)
        try session.activate()
        defer { session.cancel(reason: "done") }
        try session.send(message: XPCDictionary(sent.rawValue))

        guard await waitUntil({ arrived.message != nil }) else {
            return XCTFail("nothing arrived on the far side")
        }
        let seen = try XCTUnwrap(arrived.message)

        // The envelope survived as three native entries.
        XCTAssertNotNil(xpc_dictionary_get_value(seen, EnvelopeKey.headerCategory))
        XCTAssertNotNil(xpc_dictionary_get_value(seen, EnvelopeKey.headerID))
        let payload = try XCTUnwrap(xpc_dictionary_get_value(seen, EnvelopeKey.payload))

        // And the body is still one xpc_data blob, not a native structure.
        let blob = try XCTUnwrap(xpc_dictionary_get_value(payload, OverlayEnvelope.body))
        XCTAssertEqual(xpc_get_type(blob), XPC_TYPE_DATA)

        // It still decodes to what we sent, after the crossing.
        // Decoded through the inbound type -- `RemoteInvocationRequest` is the encode
        // side only, which is itself the asymmetry the arguments container exists for.
        let decoded = try Packet(rawValue: seen).map {
            try $0.payload.decode(as: InboundRequest.self, userInfo: [:])
        }
        XCTAssertEqual(decoded?.remoteCallIdentifier, "probe")
        XCTAssertEqual(decoded?.id, ID64(rawValue: 3))
    }

    /// A throwing target still reports across the real transport, so the failure arm is
    /// not an in-process artefact either.
    func testAThrowCrossesRealXPC() async throws {
        let link = try await RealLink()
        defer { link.tearDown() }

        let greeter = WireGreeter(actorSystem: link.serverSystem)
        let proxy = try link.proxy(WireGreeter.self, at: try link.export(greeter.id))

        let box = Box<String>()
        let task = Task {
            do { box.set(.success(try await proxy.refuse())) }
            catch { box.set(.failure(error)) }
        }
        guard await waitUntil({ box.outcome != nil }) else {
            return XCTFail("the failure never came back")
        }
        task.cancel()
        XCTAssertThrowsError(try box.outcome?.get()) { error in
            XCTAssertTrue("\(error)".contains("no"), "\(error)")
        }
        withExtendedLifetime(greeter) {}
    }

    /// An ``XPCActorSystem/EphemeralService`` dials a peer through the live ``XPCEndpoint`` an
    /// anonymous `XPCListener` vended -- no launchd name anywhere -- and a call crosses real XPC
    /// and comes back. This drives `makeRemoteInterface(to: EphemeralService)`, so it exercises
    /// `EphemeralService.connect` (endpoint dial + activation) end to end.
    func testACallCrossesAnEphemeralServiceEndpoint() async throws {
        let serverSystem = XPCActorSystem("eph-server")
        let receiver = XPCActorSystem.TransportReceiver(actorSystem: serverSystem) { local in
            local.export(WireGreeter(actorSystem: local.session.system),
                         asServerActorFor: "greeter")
            return await local.activateThenWaitForCancellation()
        }
        let listener = XPCListener { request in
            let (decision, raw) = XPCRawTransport.accepting(request)
            receiver.accept(raw, debugName: "ephemeral")
            return decision
        }
        defer { listener.cancel() }

        let ephemeral = XPCActorSystem.EphemeralService(endpoint: listener.endpoint)
        let client = XPCActorSystem("eph-client")
        let remote = try await client.makeRemoteInterface(to: ephemeral, assumingPeerSatisfies: nil)
        let proxy: WireGreeter = remote.import(clientActorFor: "greeter")

        let box = Box<String>()
        let task = Task {
            do { box.set(.success(try await proxy.greet(name: "endpoint"))) }
            catch { box.set(.failure(error)) }
        }
        guard await waitUntil({ box.outcome != nil }) else {
            return XCTFail("the call never came back over the ephemeral endpoint")
        }
        task.cancel()
        XCTAssertEqual(try box.outcome?.get(), "hello endpoint")
    }
}

/// Local, because the one in `InboundInvocationTests` is `private` to that file.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcome: Result<Value, any Error>?
    var outcome: Result<Value, any Error>? { lock.withLock { _outcome } }
    func set(_ value: Result<Value, any Error>) { lock.withLock { _outcome = value } }
}

// MARK: - the actor

@available(macOS 26, *)
distributed actor WireGreeter {
    typealias ActorSystem = XPCActorSystem

    distributed func greet(name: String) -> String { "hello \(name)" }
    distributed func refuse() throws -> String {
        throw SetupError("no")
    }
}

// MARK: - a link over a real anonymous XPC connection

@available(macOS 26, *)
private final class RealLink: @unchecked Sendable {

    let clientSystem = XPCActorSystem("client")
    let serverSystem = XPCActorSystem("server")

    private let listener: XPCListener
    private var clientTransport: Transport!
    private var serverTransport: Transport!
    private var clientSession: Session!
    private var serverSession: Session!

    init() async throws {
        let ready = Ready()
        let system = serverSystem

        listener = try XPCListener { request in
            // Apple's overlay: the accepted session is already live, so there is nothing to
            // activate -- the transport is built `isAlreadyActive: true`.
            let (decision, raw) = XPCRawTransport.accepting(request)
            let transport = Transport(debugName: "server", role: .responder, rawTransport: raw)
            let session = system.makeSession(over: transport)
            ready.publish(transport: transport, session: session, raw: raw)
            return decision
        }

        let raw = try XPCRawTransport.connecting(to: listener.endpoint)
        clientTransport = Transport(debugName: "client", role: .initiator, rawTransport: raw)
        clientSession = clientSystem.makeSession(over: clientTransport)
        try raw.activate()

        // The server side is built inside the listener's handler, which does not run
        // until the peer's first message arrives -- an XPC session is not established by
        // dialling alone. Nudge it with a notification, which needs no reply.
        let nudge = try Packet.Payload(encoding: RemoteNotification.invocationCancelled(
            id: ID64(rawValue: .max)), userInfo: [:])
        try clientTransport.sendNotification(nudge)

        guard await waitUntil({ ready.session != nil }) else {
            throw SetupError("the listener never accepted a session")
        }
        serverTransport = ready.transport
        serverSession = ready.session
    }

    func tearDown() {
        clientTransport?.cancel(reason: "test over")
        serverTransport?.cancel(reason: "test over")
        listener.cancel()
    }

    func export(_ id: ActorID) throws -> SharedActorKey {
        guard case .local(let local) = id.raw else {
            throw SetupError("only a local actor can be exported, got \(id.raw)")
        }
        guard let key = serverSession.shareDynamically(local) else {
            throw SetupError("the server session refused to share \(local)")
        }
        return key
    }

    func proxy<Act: DistributedActor>(
        _ type: Act.Type, at key: SharedActorKey
    ) throws -> Act where Act.ActorSystem == XPCActorSystem {
        try Act.resolve(id: clientSession.remoteID(for: key), using: clientSystem)
    }

    private final class Ready: @unchecked Sendable {
        private let lock = NSLock()
        private var _transport: Transport?
        private var _session: Session?
        private var _raw: XPCRawTransport?
        var transport: Transport? { lock.withLock { _transport } }
        var session: Session? { lock.withLock { _session } }
        var raw: XPCRawTransport? { lock.withLock { _raw } }
        func publish(transport: Transport, session: Session, raw: XPCRawTransport) {
            lock.withLock { _transport = transport; _session = session; _raw = raw }
        }
    }
}

@available(macOS 26, *)
private final class Arrived: @unchecked Sendable {
    private let lock = NSLock()
    private var _message: xpc_object_t?
    var message: xpc_object_t? { lock.withLock { _message } }
    func store(_ m: xpc_object_t) { lock.withLock { if _message == nil { _message = m } } }
}
#endif
