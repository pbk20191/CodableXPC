// Tests/XPCActorsTests/InboundInvocationTests.swift
import XCTest
import XPC
import Distributed
@testable import XPCActors

/// The inbound path, and the first end-to-end call.
///
/// Two real `XPCActorSystem`s, two real `Session`s, one `InProcessRawTransport` pair. A
/// `distributed func` called on one side runs on the other and its answer comes back
/// through the same bytes a peer would see.
///
/// **Nothing here awaits the thing under test.** Every failure this file guards against is
/// "the caller is never resumed" -- a missing `reply(...)`, a request whose execution task
/// is never started, a response nobody sends -- and this protocol has no timeout, so
/// `await task.value` would wedge the suite at zero reported failures rather than redden
/// it. `waitUntil` (`TransportTests.swift`) is the only sound wait; see the note on
/// `OutboundInvocationTests.settle(_:_:)`, which records the three times that has already
/// happened in this project.

// ===========================================================================================
// MARK: - The actors under test
// ===========================================================================================

/// Somewhere a callee can leave a mark that a test body can read. Shared by reference into
/// an actor, so it survives the actor's isolation without the test having to enter it.
final class InboundLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func note(_ text: String) { lock.withLock { entries.append(text) } }
    var all: [String] { lock.withLock { entries } }
    func has(_ text: String) -> Bool { all.contains(text) }
}

enum CalleeError: Error, CustomStringConvertible {
    case refused(String)
    var description: String {
        switch self { case .refused(let why): return "refused: \(why)" }
    }
}

@available(macOS 14, *)
distributed actor Callback {
    typealias ActorSystem = XPCActorSystem
    let name: String
    init(name: String, actorSystem: ActorSystem) {
        self.name = name
        self.actorSystem = actorSystem
    }
    distributed func greet() -> String { "hello from \(name)" }
}

@available(macOS 14, *)
distributed actor Calculator {
    typealias ActorSystem = XPCActorSystem
    let log: InboundLog

    init(actorSystem: ActorSystem, log: InboundLog = InboundLog()) {
        self.actorSystem = actorSystem
        self.log = log
    }

    distributed func add(_ a: Int, _ b: Int) -> Int { a + b }
    distributed func shape(_ point: Point) -> Point { Point(x: point.x * 2, y: point.y + "!") }
    distributed func boom() throws -> Int { throw CalleeError.refused("by design") }
    distributed func remember(_ text: String) { log.note(text) }
    distributed func nothing() -> Int { 7 }

    /// What priority the execution actually runs at. `TaskPriority` is not `Codable` in a
    /// shape a test can assert on directly, so the raw value comes back as an `Int`.
    distributed func priorityRawValue() -> Int { Int(Task.currentPriority.rawValue) }

    /// Calls *back* across the same pair, on an actor the caller passed in.
    distributed func introduce(to other: Callback) async throws -> String {
        try await other.greet()
    }

    /// Runs until its task is cancelled, and records that it noticed.
    distributed func park() async -> Bool {
        log.note("parked")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000)
        }
        log.note("cancelled")
        return true
    }
}

/// A concrete actor behind the `Greeter` distributed *protocol* declared in
/// `InvocationEncoderTests.swift`. Calls through `$Greeter` are the only ones that carry a
/// `protocolStub`, and therefore the only ones whose accessor the Swift runtime resolves
/// through `decodeGenericSubstitutions`.
@available(macOS 15, *)
distributed actor Politeness: Greeter {
    typealias ActorSystem = XPCActorSystem
    init(actorSystem: ActorSystem) { self.actorSystem = actorSystem }
    distributed func greet(name: String) -> String { "hello, \(name)" }
}

// ===========================================================================================
// MARK: - What a peer writes and reads
// ===========================================================================================

/// A request written by hand, field by field, in the wire's own types.
///
/// Not `RemoteInvocationRequest`: a hostile request is precisely one our own encoder would
/// never produce, and going through it would only prove we agree with ourselves.
private struct HandBuiltRequest: Encodable {

    enum Argument: Encodable {
        case int(Int)
        case string(String)
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            }
        }
    }

    var id: UInt64 = 1
    /// A bare `UInt8`, which is what `TaskPriority`'s `RawRepresentable` coding puts on the
    /// wire -- and `TaskPriority.init(rawValue:)` is not failable, so a peer is free to
    /// send a value no Swift `TaskPriority` constant has.
    var basePriority: UInt8?
    var targetedSharedActor: SharedActorKey
    var remoteCallIdentifier: String
    var protocolStub: String?
    var genericSubsitutions: [String] = []
    var arguments: [Argument] = []
    /// Leave the `arguments` key out entirely, which is a thing a real peer does for a
    /// zero-argument target.
    var omitArguments = false
    var errorType: String?
    var returnType: String?

    private enum Top: String, CodingKey {
        case id, basePriority, targetedSharedActor, remoteCallIdentifier, contents
    }
    private enum Contents: String, CodingKey {
        case protocolStub, genericSubsitutions, arguments, errorType, returnType
    }

    func encode(to encoder: any Encoder) throws {
        var top = encoder.container(keyedBy: Top.self)
        try top.encode(id, forKey: .id)
        try top.encodeIfPresent(basePriority, forKey: .basePriority)
        try top.encode(targetedSharedActor, forKey: .targetedSharedActor)
        try top.encode(remoteCallIdentifier, forKey: .remoteCallIdentifier)

        var contents = top.nestedContainer(keyedBy: Contents.self, forKey: .contents)
        try contents.encodeIfPresent(protocolStub, forKey: .protocolStub)
        try contents.encode(genericSubsitutions, forKey: .genericSubsitutions)
        if !omitArguments {
            var array = contents.nestedUnkeyedContainer(forKey: .arguments)
            for argument in arguments { try array.encode(argument) }
        }
        try contents.encodeIfPresent(errorType, forKey: .errorType)
        try contents.encodeIfPresent(returnType, forKey: .returnType)
    }
}

/// `[1, {"<case>": {"_0": "<message>"}}]`, read as a peer would read it rather than
/// through `RemoteInvocationResponse`.
private struct PeerFailureResponse: Decodable {
    let tag: UInt8
    let caseName: String
    let message: String

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    private enum Payload: String, CodingKey { case _0 }

    init(from decoder: any Decoder) throws {
        var pair = try decoder.unkeyedContainer()
        tag = try pair.decode(UInt8.self)
        let body = try pair.nestedContainer(keyedBy: AnyKey.self)
        guard let key = body.allKeys.first, body.allKeys.count == 1 else {
            throw SetupError("expected exactly one failure case key, got \(body.allKeys)")
        }
        caseName = key.stringValue
        message = try body.nestedContainer(keyedBy: Payload.self, forKey: key)
            .decode(String.self, forKey: ._0)
    }
}

/// `[0, <Int>]`, read the same way.
private struct PeerIntResponse: Decodable {
    let tag: UInt8
    let value: Int
    init(from decoder: any Decoder) throws {
        var pair = try decoder.unkeyedContainer()
        tag = try pair.decode(UInt8.self)
        value = try pair.decode(Int.self)
    }
}

/// Just enough of a request to read its `remoteCallIdentifier` and `protocolStub` back off
/// the wire. There is no API that returns either, so they are harvested rather than spelled.
private struct PeerRequestIdentifier: Decodable {
    let remoteCallIdentifier: String
    let protocolStub: String?
    private enum Top: String, CodingKey { case remoteCallIdentifier, contents }
    private enum Contents: String, CodingKey { case protocolStub }
    init(from decoder: any Decoder) throws {
        let top = try decoder.container(keyedBy: Top.self)
        remoteCallIdentifier = try top.decode(String.self, forKey: .remoteCallIdentifier)
        protocolStub = try top.nestedContainer(keyedBy: Contents.self, forKey: .contents)
            .decodeIfPresent(String.self, forKey: .protocolStub)
    }
}

// ===========================================================================================
// MARK: - Harnesses
// ===========================================================================================

/// Two systems, two sessions, one pipe. Both ends are real: neither side is a stand-in for
/// the other, and a call travels through `Packet`, the overlay coder and back.
@available(macOS 14, *)
private final class Link: @unchecked Sendable {
    let clientSystem = XPCActorSystem("client")
    let serverSystem = XPCActorSystem("server")
    let clientTransport: Transport
    let serverTransport: Transport
    let clientSession: Session
    let serverSession: Session

    init() throws {
        let (near, far) = InProcessRawTransport.makePair(debugName: "link")
        clientTransport = Transport(debugName: "client", role: .initiator, rawTransport: near)
        serverTransport = Transport(debugName: "server", role: .responder, rawTransport: far)
        clientSession = clientSystem.makeSession(over: clientTransport)
        serverSession = serverSystem.makeSession(over: serverTransport)
        try near.activate()
        try far.activate()
    }

    /// Export a server-side actor into the server's session and hand back the key naming
    /// it. This is what a real `LocalInterface.export` would do; the key travels to the
    /// client by hand because there is no service registry yet.
    func export(_ id: ActorID) throws -> SharedActorKey {
        guard case .local(let local) = id.raw else {
            throw SetupError("only a local actor can be exported, got \(id.raw)")
        }
        guard let key = serverSession.shareDynamically(local) else {
            throw SetupError("could not share \(local)")
        }
        return key
    }

    func proxy<A: DistributedActor>(_ type: A.Type, at key: SharedActorKey) throws -> A
    where A.ActorSystem == XPCActorSystem {
        try A.resolve(id: clientSession.remoteID(for: key), using: clientSystem)
    }

    /// Send a hand-built body as a request and wait for the response payload.
    func request(_ body: some Encodable) async -> RequestTable.Outcome {
        guard let payload = try? Packet.Payload(encoding: body, userInfo: [:]) else {
            return .failed(.transportCancelled(message: "could not encode the hand-built body"))
        }
        return await clientTransport.sendRequest(seq: clientTransport.allocateSeq(), payload)
    }

    func notify(_ notification: RemoteNotification) throws {
        try clientTransport.sendNotification(
            try Packet.Payload(encoding: notification, userInfo: [:]))
    }
}

/// A client whose peer is a raw pipe we read, used only to harvest the mangled accessor
/// identifier the Swift runtime emits for a call.
///
/// There is no API that returns it, and spelling one by hand would pin our guess rather
/// than the compiler's answer -- so it is read off the wire from a real call.
@available(macOS 14, *)
private final class Harvester: @unchecked Sendable {
    let system = XPCActorSystem("harvest")
    let transport: Transport
    let session: Session
    private let lock = NSLock()
    private var _packets: [Packet] = []
    var packets: [Packet] { lock.withLock { _packets } }

    init() throws {
        let (near, far) = InProcessRawTransport.makePair(debugName: "harvest")
        transport = Transport(debugName: "harvest", role: .initiator, rawTransport: near)
        session = system.makeSession(over: transport)
        try near.activate()
        try far.activate()
        far.setPacketHandler { [weak self] packet in
            guard let self, case .request = packet.header else { return }
            self.lock.withLock { self._packets.append(packet) }
        }
    }

    func proxy() throws -> Calculator {
        try Calculator.resolve(id: session.remoteID(for: .exportedRawValue("harvest")),
                               using: system)
    }

    @available(macOS 15, *)
    func stubProxy() throws -> $Greeter<XPCActorSystem> {
        try $Greeter<XPCActorSystem>.resolve(
            id: session.remoteID(for: .exportedRawValue("harvest")), using: system)
    }
}

/// Somewhere a `Task` can leave its outcome that a test body can read without awaiting it.
private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Value, any Error>?
    var outcome: Result<Value, any Error>? { lock.withLock { storage } }
    func set(_ value: Result<Value, any Error>) { lock.withLock { storage = value } }
}

// ===========================================================================================
// MARK: - The tests
// ===========================================================================================

@available(macOS 14, *)
final class InboundInvocationTests: XCTestCase {

    /// Run `body` and poll its box rather than awaiting it. See the file comment.
    @discardableResult
    private func settle<Value>(
        _ task: Task<Void, Never>, _ box: Box<Value>,
        _ message: String = "the call never produced an outcome -- it parked",
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        let settled = await waitUntil { box.outcome != nil }
        task.cancel()
        XCTAssertTrue(settled, message, file: file, line: line)
        return settled
    }

    /// The mangled accessor identifier for one call, read off the wire.
    private func identifier(
        for body: @escaping @Sendable (Calculator) async -> Void
    ) async throws -> String {
        let harvester = try Harvester()
        let proxy = try harvester.proxy()
        let task = Task { await body(proxy) }
        defer { task.cancel() }
        guard await waitUntil({ !harvester.packets.isEmpty }) else {
            throw SetupError("the harvested call never left the process")
        }
        return try harvester.packets[0].payload
            .decode(as: PeerRequestIdentifier.self).remoteCallIdentifier
    }

    /// The `remoteCallIdentifier` and `protocolStub` a call through the `Greeter`
    /// distributed protocol puts on the wire, harvested the same way.
    @available(macOS 15, *)
    private func protocolCallShape() async throws -> (identifier: String, stub: String) {
        let harvester = try Harvester()
        let stub = try harvester.stubProxy()
        let task = Task { _ = try? await stub.greet(name: "harvest") }
        defer { task.cancel() }
        guard await waitUntil({ !harvester.packets.isEmpty }) else {
            throw SetupError("the harvested protocol call never left the process")
        }
        let shape = try harvester.packets[0].payload.decode(as: PeerRequestIdentifier.self)
        guard let name = shape.protocolStub else {
            throw SetupError("a call through a distributed protocol carried no protocolStub")
        }
        return (shape.remoteCallIdentifier, name)
    }

    private func failure(_ outcome: RequestTable.Outcome) throws -> PeerFailureResponse {
        guard case .reply(let payload) = outcome else {
            throw SetupError("expected a reply, got \(outcome)")
        }
        return try payload.decode(as: PeerFailureResponse.self)
    }

    // MARK: - 1. the payoff

    func testADistributedFuncCallCrossesTheTransportAndComesBack() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        let proxy = try link.proxy(Calculator.self, at: try link.export(calculator.id))

        let box = Box<Int>()
        let task = Task {
            do { box.set(.success(try await proxy.add(20, 22))) }
            catch { box.set(.failure(error)) }
        }
        await settle(task, box)
        XCTAssertEqual(try box.outcome?.get(), 42)
        withExtendedLifetime(calculator) {}
    }

    /// A non-primitive argument and return, so both go through the generic witness rather
    /// than a builtin overload on either side.
    func testAStructuredArgumentAndReturnMakeTheRoundTrip() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        let proxy = try link.proxy(Calculator.self, at: try link.export(calculator.id))

        let box = Box<Point>()
        let task = Task {
            do { box.set(.success(try await proxy.shape(Point(x: 3, y: "a")))) }
            catch { box.set(.failure(error)) }
        }
        await settle(task, box)
        XCTAssertEqual(try box.outcome?.get(), Point(x: 6, y: "a!"))
        withExtendedLifetime(calculator) {}
    }

    /// A target that throws fails the caller, and the callee's text is what crosses --
    /// Apple carries no concrete error type, so the description is the whole of it.
    func testAThrowingDistributedFuncFailsTheCallerWithTheCalleesText() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        let proxy = try link.proxy(Calculator.self, at: try link.export(calculator.id))

        let box = Box<Int>()
        let task = Task {
            do { box.set(.success(try await proxy.boom())) }
            catch { box.set(.failure(error)) }
        }
        await settle(task, box)

        guard case .failure(let error) = box.outcome else {
            return XCTFail("expected a failure, got \(String(describing: box.outcome))")
        }
        let cancellation = try XCTUnwrap(error as? RemoteInvocationCancellationError)
        XCTAssertEqual(cancellation.reason, .executionFailed)
        XCTAssertTrue(cancellation.message.contains("refused: by design"), cancellation.message)
        withExtendedLifetime(calculator) {}
    }

    func testAVoidDistributedFuncCallCompletesAndRunsTheTarget() async throws {
        let link = try Link()
        let log = InboundLog()
        let calculator = Calculator(actorSystem: link.serverSystem, log: log)
        let proxy = try link.proxy(Calculator.self, at: try link.export(calculator.id))

        let box = Box<Bool>()
        let task = Task {
            do {
                try await proxy.remember("noted")
                box.set(.success(true))
            } catch { box.set(.failure(error)) }
        }
        await settle(task, box)
        XCTAssertEqual(try box.outcome?.get(), true)
        XCTAssertTrue(log.has("noted"), "the target never ran: \(log.all)")
        withExtendedLifetime(calculator) {}
    }

    /// The void reply is `[0, {}]` on the wire -- tag zero over an `Ack`, because `Void`
    /// is not `Codable` and something has to occupy the generic parameter.
    func testAVoidReplyIsTagZeroOverAnEmptyBody() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        let key = try link.export(calculator.id)
        let identifier = try await self.identifier { _ = try? await $0.remember("x") }

        // Polled, never awaited. This test awaited `link.request` directly until the
        // reply-dropping mutant was run against it: every other test in the file went red
        // in five seconds and this one wedged the whole bundle, which is precisely the
        // failure mode the file comment describes.
        let box = Box<RequestTable.Outcome>()
        let task = Task {
            box.set(.success(await link.request(HandBuiltRequest(
                targetedSharedActor: key, remoteCallIdentifier: identifier,
                arguments: [.string("x")]))))
        }
        guard await settle(task, box, "the peer was never answered") else { return }
        guard case .reply(let payload) = try XCTUnwrap(box.outcome?.get()) else {
            return XCTFail("expected a reply")
        }
        // Read as raw bytes rather than through `RemoteInvocationResponse<Ack>`: `Ack`'s
        // decoder accepts *anything*, deliberately, so decoding one back would assert
        // nothing about what we wrote. The empty dictionary is the assertion.
        var pair = try payload.decode(as: RawResponsePair.self).container
        XCTAssertEqual(try pair.decode(UInt8.self), 0, "a void success is tag 0")
        XCTAssertEqual(try pair.decode([String: String].self), [:],
                       "an Ack is a field-less struct, so it writes {}")
        withExtendedLifetime(calculator) {}
    }

    // MARK: - 2. an actor reference as an argument

    /// The whole point of `SharedActorKey`. A client-side actor is passed *as an argument*,
    /// arrives at the callee as a proxy, and the callee calls back on it -- which means the
    /// call crosses the pipe in the other direction while the first one is still in flight.
    func testAnActorReferenceArgumentRoundTripsAndTheCalleeCallsBack() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        let proxy = try link.proxy(Calculator.self, at: try link.export(calculator.id))
        let callback = Callback(name: "the client", actorSystem: link.clientSystem)

        let box = Box<String>()
        let task = Task {
            do { box.set(.success(try await proxy.introduce(to: callback))) }
            catch { box.set(.failure(error)) }
        }
        await settle(task, box, "the call-back never completed")
        XCTAssertEqual(try box.outcome?.get(), "hello from the client")

        // The callback was shared into the *client's* session on the way out, which is the
        // key space the returning call is interpreted in.
        XCTAssertEqual(link.clientSession.sharedActorCount, 1)
        withExtendedLifetime(calculator) {}
        withExtendedLifetime(callback) {}
    }

    // MARK: - 3. hostile requests

    func testAnUnknownRemoteCallIdentifierProducesAFailureResponse() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        let key = try link.export(calculator.id)

        let box = Box<RequestTable.Outcome>()
        let task = Task {
            box.set(.success(await link.request(HandBuiltRequest(
                targetedSharedActor: key,
                remoteCallIdentifier: "$s7Nothing6AtAllF"))))
        }
        guard await settle(task, box, "the peer was never answered") else { return }

        let response = try failure(try XCTUnwrap(box.outcome?.get()))
        XCTAssertEqual(response.tag, 1)
        XCTAssertEqual(response.caseName, "executionFailed")
        withExtendedLifetime(calculator) {}
    }

    func testARequestNamingNoSharedActorProducesAFailureResponse() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        _ = try link.export(calculator.id)

        let box = Box<RequestTable.Outcome>()
        let task = Task {
            box.set(.success(await link.request(HandBuiltRequest(
                targetedSharedActor: .dynamic(ID64(rawValue: 9999)),
                remoteCallIdentifier: "whatever"))))
        }
        guard await settle(task, box, "the peer was never answered") else { return }

        let response = try failure(try XCTUnwrap(box.outcome?.get()))
        XCTAssertEqual(response.tag, 1)
        XCTAssertEqual(response.caseName, "executionFailed")
        XCTAssertTrue(response.message.contains("9999"), response.message)
        withExtendedLifetime(calculator) {}
    }

    func testAnArgumentsArrayTooShortProducesAFailureResponse() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        let key = try link.export(calculator.id)
        let identifier = try await self.identifier { _ = try? await $0.add(1, 2) }

        let box = Box<RequestTable.Outcome>()
        let task = Task {
            box.set(.success(await link.request(HandBuiltRequest(
                targetedSharedActor: key, remoteCallIdentifier: identifier,
                arguments: [.int(1)], returnType: "Si"))))
        }
        guard await settle(task, box, "the peer was never answered") else { return }

        let response = try failure(try XCTUnwrap(box.outcome?.get()))
        XCTAssertEqual(response.tag, 1)
        XCTAssertEqual(response.caseName, "executionFailed")
        withExtendedLifetime(calculator) {}
    }

    /// **The runtime only asks for substitutions when the accessor needs them**, which for
    /// a concrete non-generic target is never. A bogus `genericSubsitutions` entry against
    /// `add` is therefore not read at all and the call succeeds -- our decoder's refusal is
    /// correct and simply not on this path.
    ///
    /// Written down rather than left as a gap: the brief asked for this case to produce a
    /// failure response, and against a concrete target it cannot. The case that *does*
    /// reach the guard is the one below, through a distributed protocol.
    func testANonStubSubstitutionIsNeverReadWhenTheTargetIsConcrete() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        let key = try link.export(calculator.id)
        let identifier = try await self.identifier { _ = try? await $0.add(1, 2) }

        let box = Box<RequestTable.Outcome>()
        let task = Task {
            box.set(.success(await link.request(HandBuiltRequest(
                targetedSharedActor: key, remoteCallIdentifier: identifier,
                genericSubsitutions: ["Si"],
                arguments: [.int(1), .int(2)], returnType: "Si"))))
        }
        guard await settle(task, box, "the peer was never answered") else { return }

        guard case .reply(let payload) = try XCTUnwrap(box.outcome?.get()) else {
            return XCTFail("expected a reply")
        }
        let response = try payload.decode(as: PeerIntResponse.self)
        XCTAssertEqual(response.tag, 0)
        XCTAssertEqual(response.value, 3)
        withExtendedLifetime(calculator) {}
    }

    /// A call through a distributed **protocol** carries a `protocolStub`, and that is the
    /// one shape whose accessor the runtime resolves *through* the substitutions -- so this
    /// is where a substitution that is not a `_DistributedActorStub` is actually read, and
    /// refused.
    func testACallThroughADistributedProtocolCrossesAndComesBack() async throws {
        guard #available(macOS 15, *) else {
            throw XCTSkip("_DistributedActorStub, and so @Resolvable, is macOS 15+")
        }
        let link = try Link()
        let polite = Politeness(actorSystem: link.serverSystem)
        let stub: $Greeter<XPCActorSystem> =
            try link.proxy($Greeter<XPCActorSystem>.self, at: try link.export(polite.id))

        let box = Box<String>()
        let task = Task {
            do { box.set(.success(try await stub.greet(name: "peer"))) }
            catch { box.set(.failure(error)) }
        }
        await settle(task, box)
        XCTAssertEqual(try box.outcome?.get(), "hello, peer")
        withExtendedLifetime(polite) {}
    }

    func testAGenericSubstitutionThatIsNotAStubProducesAFailureResponse() async throws {
        guard #available(macOS 15, *) else {
            throw XCTSkip("_DistributedActorStub, and so @Resolvable, is macOS 15+")
        }
        let link = try Link()
        let polite = Politeness(actorSystem: link.serverSystem)
        let key = try link.export(polite.id)
        let (identifier, stubName) = try await protocolCallShape()

        let box = Box<RequestTable.Outcome>()
        let task = Task {
            box.set(.success(await link.request(HandBuiltRequest(
                targetedSharedActor: key, remoteCallIdentifier: identifier,
                protocolStub: stubName,
                // The stub is legitimate; `Si` beside it is not, and the merged list is
                // what the runtime asks for.
                genericSubsitutions: ["Si"],
                arguments: [.string("peer")], returnType: "SS"))))
        }
        guard await settle(task, box, "the peer was never answered") else { return }

        let response = try failure(try XCTUnwrap(box.outcome?.get()))
        XCTAssertEqual(response.tag, 1)
        XCTAssertEqual(response.caseName, "executionFailed")
        XCTAssertTrue(response.message.contains("Failed to decode generic substitution"),
                      response.message)
        withExtendedLifetime(polite) {}
    }

    /// A body that is not a request at all. The reply is still a reply: a receiver that
    /// dropped it would park the peer forever.
    func testAnUndecodableBodyStillProducesAFailureResponse() async throws {
        let link = try Link()
        let box = Box<RequestTable.Outcome>()
        let task = Task {
            box.set(.success(await link.request(["not": "a request"])))
        }
        guard await settle(task, box, "the peer was never answered") else { return }

        let response = try failure(try XCTUnwrap(box.outcome?.get()))
        XCTAssertEqual(response.tag, 1)
        XCTAssertEqual(response.caseName, "executionFailed")
    }

    /// A request with **no `arguments` key at all** against a zero-argument target. Apple
    /// accepts it -- `EncodedInvocationDecoder.init(from:)` tests `contains(.arguments)` and
    /// leaves the container nil -- and only fails if an argument is then asked for. Being
    /// stricter here would refuse traffic a real peer sends.
    func testARequestWithNoArgumentsKeyReachesAZeroArgumentTarget() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        let key = try link.export(calculator.id)
        let identifier = try await self.identifier { _ = try? await $0.nothing() }

        let box = Box<RequestTable.Outcome>()
        let task = Task {
            box.set(.success(await link.request(HandBuiltRequest(
                targetedSharedActor: key, remoteCallIdentifier: identifier,
                omitArguments: true, returnType: "Si"))))
        }
        guard await settle(task, box, "the peer was never answered") else { return }

        guard case .reply(let payload) = try XCTUnwrap(box.outcome?.get()) else {
            return XCTFail("expected a reply")
        }
        let response = try payload.decode(as: PeerIntResponse.self)
        XCTAssertEqual(response.tag, 0)
        XCTAssertEqual(response.value, 7)
        withExtendedLifetime(calculator) {}
    }

    /// **A second request reusing an in-flight body `id`.**
    ///
    /// Our own encoder cannot produce this -- request ids come from a monotonic per-session
    /// counter -- so only a misbehaving or hostile peer gets here, which is exactly the
    /// class these tests exist to exclude. Overwriting the table entry would orphan the
    /// first execution: unreachable from `invocationCancelled` *and* from the
    /// transport-death sweep, so it would never terminate, never reply, and keep the
    /// session -- which `ResultHandler.userInfo` holds strongly -- alive for the life of
    /// the process. One leaked session graph, transport and shared-actor table per
    /// duplicate.
    func testASecondRequestReusingAnInFlightIDIsRefusedRatherThanDisplacingIt() async throws {
        let link = try Link()
        let log = InboundLog()
        let calculator = Calculator(actorSystem: link.serverSystem, log: log)
        let key = try link.export(calculator.id)
        let identifier = try await self.identifier { _ = try? await $0.park() }
        let reused = ID64(rawValue: 7)

        func park() -> HandBuiltRequest {
            HandBuiltRequest(id: reused.rawValue, targetedSharedActor: key,
                             remoteCallIdentifier: identifier, returnType: "Sb")
        }

        let firstBox = Box<RequestTable.Outcome>()
        let first = Task { firstBox.set(.success(await link.request(park()))) }
        defer { first.cancel() }
        guard await waitUntil({ log.has("parked") }) else {
            return XCTFail("the first execution never started")
        }

        let secondBox = Box<RequestTable.Outcome>()
        let second = Task { secondBox.set(.success(await link.request(park()))) }
        guard await settle(second, secondBox, "the duplicate was never answered") else {
            return
        }
        let response = try failure(try XCTUnwrap(secondBox.outcome?.get()))
        XCTAssertEqual(response.caseName, "executionFailed")
        XCTAssertTrue(response.message.contains("already in flight"), response.message)

        // The first execution is untouched, is still the only entry, and is still the one
        // a cancellation can reach.
        XCTAssertEqual(link.serverSession.pendingInvocationIDs, [reused])
        XCTAssertEqual(log.all.filter { $0 == "parked" }.count, 1,
                       "the duplicate must not have started a second execution: \(log.all)")

        try link.notify(.invocationCancelled(id: reused))
        guard await waitUntil({ log.has("cancelled") }) else {
            return XCTFail("the surviving execution was not reachable: \(log.all)")
        }
        await settle(first, firstBox, "the surviving execution never replied")
        guard await waitUntil({ link.serverSession.pendingInvocationIDs.isEmpty }) else {
            return XCTFail("the finished execution was never removed")
        }
        withExtendedLifetime(calculator) {}
    }

    /// `basePriority` is a field a **peer** writes, it arrives as a bare `UInt8`, and
    /// `TaskPriority.init(rawValue:)` is not failable -- so a peer can name a priority no
    /// Swift constant has.
    ///
    /// **This is a crash test, not a scheduling test.** Handing 255 to `Task(priority:)`
    /// aborts the process with `invalid job priority 0xff`; the mutant that removes the
    /// clamp does not fail this assertion, it kills the runner. The clamp at
    /// `.userInitiated` -- the ceiling of Apple's own clamp -- is what makes reading the
    /// field safe at all.
    func testAPeerCannotRunItsWorkAboveUserInitiated() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        let key = try link.export(calculator.id)
        let identifier = try await self.identifier { _ = try? await $0.priorityRawValue() }

        let box = Box<RequestTable.Outcome>()
        let task = Task {
            box.set(.success(await link.request(HandBuiltRequest(
                basePriority: 255, targetedSharedActor: key,
                remoteCallIdentifier: identifier, returnType: "Si"))))
        }
        guard await settle(task, box, "the peer was never answered") else { return }

        guard case .reply(let payload) = try XCTUnwrap(box.outcome?.get()) else {
            return XCTFail("expected a reply")
        }
        let response = try payload.decode(as: PeerIntResponse.self)
        XCTAssertEqual(response.tag, 0)
        XCTAssertLessThanOrEqual(response.value, Int(TaskPriority.userInitiated.rawValue),
                                 "a peer asked for priority 255 and got \(response.value)")
        withExtendedLifetime(calculator) {}
    }

    // MARK: - 4. cancellation reaches the callee

    func testAnInvocationCancelledNotificationCancelsTheCalleesTask() async throws {
        let link = try Link()
        let log = InboundLog()
        let calculator = Calculator(actorSystem: link.serverSystem, log: log)
        let proxy = try link.proxy(Calculator.self, at: try link.export(calculator.id))

        let box = Box<Bool>()
        let task = Task {
            do { box.set(.success(try await proxy.park())) }
            catch { box.set(.failure(error)) }
        }
        defer { task.cancel() }

        // The id comes from the callee's own pending table rather than from a guess about
        // the caller's counter: the notification names the *request body's* id.
        guard await waitUntil({ !link.serverSession.pendingInvocationIDs.isEmpty }) else {
            return XCTFail("the callee never registered an execution task")
        }
        let id = try XCTUnwrap(link.serverSession.pendingInvocationIDs.first)
        try link.notify(.invocationCancelled(id: id))

        guard await waitUntil({ log.has("cancelled") }) else {
            return XCTFail("the cancellation never reached the callee: \(log.all)")
        }
        await settle(task, box, "the callee never replied after being cancelled")
        XCTAssertEqual(try box.outcome?.get(), true)
        guard await waitUntil({ link.serverSession.pendingInvocationIDs.isEmpty }) else {
            return XCTFail("the finished execution was never removed from the pending table")
        }
        withExtendedLifetime(calculator) {}
    }

    /// The transport dying cancels every execution this side started for the peer -- Apple's
    /// `handleTransportCancellation` is `cancelAllPendingInvocationExecutionTasks()` then
    /// `cancellationCompleted()`, and only the second half existed before this slice.
    func testTransportDeathCancelsEveryInFlightExecution() async throws {
        let link = try Link()
        let log = InboundLog()
        let calculator = Calculator(actorSystem: link.serverSystem, log: log)
        let proxy = try link.proxy(Calculator.self, at: try link.export(calculator.id))

        let box = Box<Bool>()
        let task = Task {
            do { box.set(.success(try await proxy.park())) }
            catch { box.set(.failure(error)) }
        }
        defer { task.cancel() }
        guard await waitUntil({ log.has("parked") }) else {
            return XCTFail("the callee never started")
        }

        link.serverTransport.cancel(reason: "the pipe died")
        guard await waitUntil({ log.has("cancelled") }) else {
            return XCTFail("the callee was never cancelled: \(log.all)")
        }
        XCTAssertEqual(link.serverSession.sharedActorCount, 0)
        withExtendedLifetime(calculator) {}
    }

    // MARK: - 5. the pieces on their own

    /// `decodeGenericSubstitutions` merges `protocolStub` in **ahead of**
    /// `genericSubsitutions`, and rejects anything that is not a `_DistributedActorStub`.
    func testTheDecoderRejectsANonStubSubstitution() throws {
        var decoder = try Self.decoder(genericSubsitutions: ["Si"])
        XCTAssertThrowsError(try decoder.decodeGenericSubstitutions()) { error in
            XCTAssertTrue("\(error)".contains("Failed to decode generic substitution"),
                          "\(error)")
        }
    }

    /// **Order matters, and it is `protocolStub` first.** Two wire keys become one
    /// `[Any.Type]`, and the Swift runtime consumes it positionally -- so appending the
    /// stub last would hand the substitutions to the wrong parameters. Both entries here
    /// are real stubs, because anything else is rejected before order can be observed.
    func testTheProtocolStubIsMergedAheadOfTheGenericSubstitutions() throws {
        guard #available(macOS 15, *) else {
            throw XCTSkip("_DistributedActorStub is macOS 15+")
        }
        let first = $Greeter<XPCActorSystem>.self
        let second = $Counter<XPCActorSystem>.self
        var decoder = try Self.decoder(
            protocolStub: try XCTUnwrap(SwiftType(first)).mangledTypeName,
            genericSubsitutions: [try XCTUnwrap(SwiftType(second)).mangledTypeName])

        let substitutions = try decoder.decodeGenericSubstitutions()
        XCTAssertEqual(substitutions.count, 2)
        XCTAssertTrue(substitutions[0] == first, "the protocolStub must come first")
        XCTAssertTrue(substitutions[1] == second)
    }

    /// `canThrow` is read off the *request*, not assumed. A peer that names a throwing
    /// target while omitting `errorType` announces a non-throwing call; when the target
    /// then throws, the answer is the API-violation refusal rather than the target's own
    /// text. Hard-coding `canThrow: true` in the dispatch would silently accept it.
    func testARequestWithNoErrorTypeMakesTheHandlerRefuseAThrownError() async throws {
        let link = try Link()
        let calculator = Calculator(actorSystem: link.serverSystem)
        let key = try link.export(calculator.id)
        let identifier = try await self.identifier { _ = try? await $0.boom() }

        let box = Box<RequestTable.Outcome>()
        let task = Task {
            box.set(.success(await link.request(HandBuiltRequest(
                targetedSharedActor: key, remoteCallIdentifier: identifier,
                // No `errorType`, which is the whole point: a real call to `boom` carries
                // one, because `recordErrorType` runs for a throwing target.
                returnType: "Si"))))
        }
        guard await settle(task, box, "the peer was never answered") else { return }

        let response = try failure(try XCTUnwrap(box.outcome?.get()))
        XCTAssertEqual(response.caseName, "executionFailed")
        // Apple's message interpolates the error, so the *text* of the callee's error is
        // present either way; what distinguishes the refusal is the API-violation wording,
        // which a handler built with `canThrow: true` would never produce.
        XCTAssertTrue(response.message.contains("API violation"), response.message)
        XCTAssertTrue(response.message.contains("doesn't throw"), response.message)
        withExtendedLifetime(calculator) {}
    }

    func testTheDecoderResolvesTheErrorAndReturnTypes() throws {
        var decoder = try Self.decoder(errorType: "Si", returnType: "SS")
        XCTAssertTrue(try decoder.decodeErrorType() == Int.self)
        XCTAssertTrue(try decoder.decodeReturnType() == String.self)
    }

    /// A name that does not resolve is a *later* failure, not a decode failure -- so the
    /// decoder hands back `nil` rather than throwing.
    func testAnUnresolvableTypeNameDecodesToNil() throws {
        var decoder = try Self.decoder(errorType: "not a mangled name at all")
        XCTAssertNil(try decoder.decodeErrorType())
    }

    func testTheDecoderConsumesArgumentsPositionally() throws {
        var decoder = try Self.decoder(arguments: [.int(4), .string("four")])
        XCTAssertEqual(try decoder.decodeNextArgument() as Int, 4)
        XCTAssertEqual(try decoder.decodeNextArgument() as String, "four")
        XCTAssertThrowsError(try decoder.decodeNextArgument() as Int)
    }

    /// Apple's message, and the case our `InboundInvocation` used to reject outright.
    func testAskingForAnArgumentWithNoArgumentsKeyThrowsApplesMessage() throws {
        var decoder = try Self.decoder(omitArguments: true)
        XCTAssertThrowsError(try decoder.decodeNextArgument() as Int) { error in
            XCTAssertTrue("\(error)".contains("Found no arguments from decoder."), "\(error)")
        }
    }

    /// `canThrow` is false when the request carries no `errorType`. Apple `fatalError`s
    /// there; we throw, because the signal is a field a peer wrote.
    func testAResultHandlerThatCannotThrowRefusesRatherThanTrapping() async throws {
        let handler = ResultHandler(canThrow: false, userInfo: [:])
        do {
            try await handler.onThrow(error: CalleeError.refused("x"))
            XCTFail("onThrow returned instead of refusing")
        } catch {
            XCTAssertTrue("\(error)".contains("API violation"), "\(error)")
        }
        XCTAssertNil(handler.reply, "nothing may be written for a call that cannot throw")
    }

    func testAResultHandlerThatCanThrowWritesAFailureReply() async throws {
        let handler = ResultHandler(canThrow: true, userInfo: [:])
        try await handler.onThrow(error: CalleeError.refused("politely"))
        let payload = try XCTUnwrap(handler.reply)
        let response = try payload.decode(as: PeerFailureResponse.self)
        XCTAssertEqual(response.tag, 1)
        XCTAssertEqual(response.caseName, "executionFailed")
        XCTAssertTrue(response.message.contains("refused: politely"), response.message)
    }

    // MARK: helpers

    /// Build an `InvocationDecoder` over a hand-built invocation body.
    private static func decoder(
        protocolStub: String? = nil,
        genericSubsitutions: [String] = [],
        arguments: [HandBuiltRequest.Argument] = [],
        omitArguments: Bool = false,
        errorType: String? = nil,
        returnType: String? = nil
    ) throws -> InvocationDecoder {
        let request = HandBuiltRequest(
            targetedSharedActor: .exportedRawValue("x"),
            remoteCallIdentifier: "x",
            protocolStub: protocolStub,
            genericSubsitutions: genericSubsitutions,
            arguments: arguments,
            omitArguments: omitArguments,
            errorType: errorType,
            returnType: returnType)
        let payload = try Packet.Payload(encoding: request, userInfo: [:])
        return InvocationDecoder(try payload.decode(as: InboundRequest.self).contents)
    }
}

/// The raw `[tag, payload]` pair of a response, kept undecoded past the tag.
private struct RawResponsePair: Decodable {
    var container: any UnkeyedDecodingContainer
    init(from decoder: any Decoder) throws {
        container = try decoder.unkeyedContainer()
    }
}
