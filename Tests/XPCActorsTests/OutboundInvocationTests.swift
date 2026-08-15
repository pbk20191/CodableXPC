// Tests/XPCActorsTests/OutboundInvocationTests.swift
import XCTest
import XPC
import Distributed
@testable import XPCActors

/// The outbound path: a call goes out as a `RemoteInvocationRequest` packet and a
/// response comes back.
///
/// **Every response in this file is built by hand**, by a type that writes the wire
/// shape directly rather than by `RemoteInvocationResponse.encode(to:)`. A response our
/// own encoder produced would only prove we agree with ourselves; the whole question is
/// whether we can read what a peer wrote. The request side is read back the same way --
/// ``PeerRequest`` decodes the header fields as their *wire* types (`UInt64`, `String`,
/// `UInt8`) rather than as `ID64`/`SwiftType`/`TaskPriority`, so it would not follow us
/// if one of those conformances drifted.

// ===========================================================================================
// MARK: - What a peer writes
// ===========================================================================================

/// `[0, <value>]` -- a success response, written without consulting
/// ``RemoteInvocationResponse``.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private struct PeerSuccess<Value: Encodable>: Encodable {
    let value: Value
    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(UInt8(0))
        try container.encode(value)
    }
}

/// `[0, {}]` -- the void reply. The empty dictionary is what a field-less `Ack` encodes
/// to, spelled here as an actually-empty dictionary so nothing about `Ack` is assumed.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private struct PeerVoidSuccess: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(UInt8(0))
        try container.encode([String: String]())
    }
}

/// `[1, {"<case>": {"_0": "<message>"}}]` -- a failure response.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private struct PeerFailure: Encodable {
    enum Kind: String { case executionFailed, resultPropagationFailed }
    let kind: Kind
    let message: String

    private struct Body: Encodable {
        let kind: Kind
        let message: String
        struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        private enum Payload: String, CodingKey { case _0 }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            var payload = container.nestedContainer(
                keyedBy: Payload.self, forKey: Key(stringValue: kind.rawValue)!)
            try payload.encode(message, forKey: ._0)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(UInt8(1))
        try container.encode(Body(kind: kind, message: message))
    }
}

// ===========================================================================================
// MARK: - What a peer reads
// ===========================================================================================

/// A request, read as a peer would read it.
///
/// Header fields are decoded as the types they occupy *on the wire*, not as the Swift
/// types we encoded them from: `id` is a bare `UInt64`, `basePriority` a bare `UInt8`,
/// every type reference a bare `String`. The arguments container is left unconsumed so
/// each test decodes what it expects to be there.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private struct PeerRequest: Decodable {
    let id: UInt64
    let basePriority: UInt8?
    let targetedSharedActor: SharedActorKey
    let remoteCallIdentifier: String
    let protocolStub: String?
    let genericSubsitutions: [String]
    let errorType: String?
    let returnType: String?
    var arguments: any UnkeyedDecodingContainer

    private enum Top: String, CodingKey {
        case id, basePriority, targetedSharedActor, remoteCallIdentifier, contents
    }
    private enum Contents: String, CodingKey {
        case protocolStub, genericSubsitutions, arguments, errorType, returnType
    }

    init(from decoder: any Decoder) throws {
        let top = try decoder.container(keyedBy: Top.self)
        id = try top.decode(UInt64.self, forKey: .id)
        basePriority = try top.decodeIfPresent(UInt8.self, forKey: .basePriority)
        targetedSharedActor = try top.decode(SharedActorKey.self, forKey: .targetedSharedActor)
        remoteCallIdentifier = try top.decode(String.self, forKey: .remoteCallIdentifier)

        let contents = try top.nestedContainer(keyedBy: Contents.self, forKey: .contents)
        protocolStub = try contents.decodeIfPresent(String.self, forKey: .protocolStub)
        genericSubsitutions = try contents.decode([String].self, forKey: .genericSubsitutions)
        errorType = try contents.decodeIfPresent(String.self, forKey: .errorType)
        returnType = try contents.decodeIfPresent(String.self, forKey: .returnType)
        arguments = try contents.nestedUnkeyedContainer(forKey: .arguments)
    }
}

/// `RemoteNotification.invocationCancelled(id:)`, read as a peer would: one top-level key
/// naming the case, and the field spelled **`id`** -- never `requestSeq`.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private struct PeerCancellation: Decodable {
    /// A bare `UInt64`, because `ID64` is single-value on the wire.
    let cancelledID: UInt64
    private enum Top: String, CodingKey { case invocationCancelled }
    private enum Body: String, CodingKey { case id }
    init(from decoder: any Decoder) throws {
        let body = try decoder.container(keyedBy: Top.self)
            .nestedContainer(keyedBy: Body.self, forKey: .invocationCancelled)
        cancelledID = try body.decode(UInt64.self, forKey: .id)
    }
}

/// `targetedSharedActor`, read as the raw unkeyed pair -- `[WireCode, payload]` -- rather
/// than through our own `SharedActorKey: Decodable`. `WireCode` is `RawRepresentable` over
/// `UInt8` with `exported` 0, `exportedRawValue` 1, `dynamic` 2.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private struct PeerRequestKey: Decodable {
    let wireCode: UInt8
    let name: String
    private enum Top: String, CodingKey { case targetedSharedActor }
    init(from decoder: any Decoder) throws {
        var pair = try decoder.container(keyedBy: Top.self)
            .nestedUnkeyedContainer(forKey: .targetedSharedActor)
        wireCode = try pair.decode(UInt8.self)
        name = try pair.decode(String.self)
    }
}

// ===========================================================================================
// MARK: - The actor under test
// ===========================================================================================

@available(macOS 26, *)
distributed actor Echo {
    typealias ActorSystem = XPCActorSystem
    init(actorSystem: ActorSystem) { self.actorSystem = actorSystem }
    distributed func double(_ value: Int) -> Int { value * 2 }
    distributed func note(_ text: String) {}
}

// ===========================================================================================
// MARK: - The harness
// ===========================================================================================

/// One session over one transport, with the far end of the pipe driven by hand.
///
/// The far end has no `Transport` of its own: packets are captured raw and answers are
/// sent raw, so nothing in a test's expectations is produced by the code under test.
@available(macOS 26, *)
private final class Peer: @unchecked Sendable {

    let system: XPCActorSystem
    let transport: Transport
    let session: Session
    /// The far end of the pipe. Ours to drive.
    let far: InProcessRawTransport

    private let lock = NSLock()
    private var _packets: [Packet] = []

    init(_ debugName: String = "peer") throws {
        let (near, far) = InProcessRawTransport.makePair(debugName: debugName)
        self.far = far
        system = XPCActorSystem(debugName)
        transport = Transport(debugName: debugName, role: .initiator, rawTransport: near)
        session = system.makeSession(over: transport)
        // Raw activation rather than `Transport.activate()`, which only forwards to it
        // and is `async`. Nothing is exchanged either way.
        try near.activate()
        try far.activate()
        far.setPacketHandler { [weak self] packet in
            guard let self else { return }
            self.lock.withLock { self._packets.append(packet) }
        }
    }

    var packets: [Packet] { lock.withLock { _packets } }

    func waitForPackets(_ count: Int) async -> Bool {
        await waitUntil { self.packets.count >= count }
    }

    /// A proxy for an actor living in the peer, reached through this session.
    func proxy(_ key: SharedActorKey = .exportedRawValue("primary")) throws -> Echo {
        try Echo.resolve(id: session.remoteID(for: key), using: system)
    }

    /// Answer a captured request with bytes of our choosing.
    func respond(to packet: Packet, with body: some Encodable) throws {
        guard case .request(let id) = packet.header else {
            throw SetupError("not a request: \(packet.header)")
        }
        try far.send(packet: Packet(header: .response(id),
                                    payload: try Packet.Payload(encoding: body, userInfo: [:])))
    }
}

/// Somewhere for a `Task` to leave its outcome that a test body can read.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private final class ResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Value, any Error>?
    var outcome: Result<Value, any Error>? { lock.withLock { storage } }
    func set(_ value: Result<Value, any Error>) { lock.withLock { storage = value } }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private struct CallerError: Error {}

/// A `SessionCoding` that can name actors but cannot send anything, and that claims a
/// system it does not hold.
///
/// Both halves are reachable on purpose. `SessionCoding.systemID` is an `ID64` rather
/// than the system object -- its own comment says so, and says that a conformer outside
/// this package can therefore return an id it merely guessed -- so `resolve` will hand
/// back a proxy through this. `remoteCall` is then the layer that has to notice there is
/// nowhere to send.
@available(macOS 26, *)
private final class ImpostorSession: SessionCoding, @unchecked Sendable {
    let systemID: ID64
    init(claiming system: XPCActorSystem) { systemID = system.id }
    func shareDynamically(_ local: RawActorID.Local) -> SharedActorKey? { nil }
    func remoteID(for key: SharedActorKey) -> ActorID {
        ActorID(raw: .remote(.init(session: self, key: key)))
    }
}

/// A non-primitive return type. **At file scope, not inside the test**: a function-local
/// type mangles to a name embedding a process address, which `SwiftType.init?(_:)`
/// rejects precisely because no peer could resolve it -- so `recordReturnType` would
/// throw and the call would never be sent.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
struct Point: Codable, Equatable, Sendable { let x: Int; let y: String }

// ===========================================================================================
// MARK: - The tests
// ===========================================================================================

@available(macOS 26, *)
final class OutboundInvocationTests: XCTestCase {

    /// Drive one `remoteCall` on a background task, so the test body can inspect and
    /// answer the packet it produces.
    private func call<Res: Codable & Sendable>(
        _ peer: Peer, on proxy: Echo, target: String, returning: Res.Type,
        arguments: @escaping @Sendable (inout InvocationEncoder) throws -> Void = { _ in }
    ) -> (Task<Void, Never>, ResultBox<Res>) {
        let box = ResultBox<Res>()
        let task = Task {
            var encoder = peer.system.makeInvocationEncoder()
            do {
                try arguments(&encoder)
                try encoder.recordReturnType(Res.self)
                try encoder.doneRecording()
                box.set(.success(try await peer.system.remoteCall(
                    on: proxy, target: RemoteCallTarget(target), invocation: &encoder,
                    throwing: CallerError.self, returning: Res.self)))
            } catch {
                box.set(.failure(error))
            }
        }
        return (task, box)
    }

    /// Wait for `count` packets to reach the far end. Not written as
    /// `XCTAssertTrue(await ...)`: `XCTAssert*` takes an autoclosure, which cannot carry
    /// an `await`.
    /// Throws rather than only asserting: every test here indexes `peer.packets`
    /// immediately afterwards, and a soft assertion would turn "nothing was sent" into
    /// an index-out-of-range crash that takes the whole suite with it.
    private func expectPackets(
        _ peer: Peer, _ count: Int, _ message: String = "the expected packets never arrived",
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let arrived = await peer.waitForPackets(count)
        let detail = "\(message) (saw \(peer.packets.count) of \(count))"
        XCTAssertTrue(arrived, detail, file: file, line: line)
        if !arrived { throw SetupError(detail) }
    }

    /// Wait for a call to produce an outcome -- **by polling the outcome, never by
    /// awaiting the task.**
    ///
    /// Read this as the rule for the whole file. Two different regressions here do not
    /// return a wrong answer, they fail to *return at all*: one where the code under test
    /// sends where it should have refused (and then waits for a reply nobody will write),
    /// and one where a resumption is missing (`RequestTable.waitForReply`'s `onCancel`,
    /// `Transport.failEverything`'s `failAll`). This protocol has no timeout, so
    /// `await task.value` in either case does not fail the test -- it wedges the whole
    /// suite and reports **zero** failures. That is worse than a red test, because the
    /// mutation that caused it looks killed-nothing rather than uncaught.
    ///
    /// Not hypothetical, twice over: two mutants survived this file exactly that way
    /// before the two tests below it were converted, and a review found two more that
    /// remove a resumption outright and hung the run for 275s and ~95s.
    ///
    /// `waitUntil` (`TransportTests.swift`) is the sound primitive, and
    /// `RequestTableTerminalTests.withTimeout` is **not** a substitute -- it races a
    /// sleeper inside a `withTaskGroup`, and a task group awaits every child on exit, so a
    /// genuinely parked continuation hangs the timeout too. See its doc comment.
    ///
    /// The task is cancelled either way, so a test that reports a hang does not leave one
    /// running. Callers need not check the result: every assertion downstream reads
    /// `box.outcome`, which is `nil` on a hang and fails on its own.
    @discardableResult
    private func settle<Value>(
        _ task: Task<Void, Never>, _ box: ResultBox<Value>,
        _ message: String = "the call never produced an outcome -- it parked",
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        let settled = await waitUntil { box.outcome != nil }
        task.cancel()
        XCTAssertTrue(settled, message, file: file, line: line)
        return settled
    }

    private func cancellationError(_ outcome: Result<some Any, any Error>?) throws
        -> RemoteInvocationCancellationError {
        guard case .failure(let error) = outcome else {
            throw SetupError("expected a failure, got \(String(describing: outcome))")
        }
        guard let cancellation = error as? RemoteInvocationCancellationError else {
            throw SetupError("expected a RemoteInvocationCancellationError, got \(error)")
        }
        return cancellation
    }

    // MARK: - the system vends sessions

    /// The hazard `makeSession(over:)` closes: a session's table and the system it
    /// claims to belong to cannot disagree, because there is only one parameter.
    func testASessionVendedByASystemAgreesWithIt() throws {
        let peer = try Peer()
        XCTAssertEqual(peer.session.systemID, peer.system.id)
        let id = peer.session.remoteID(for: .dynamic(ID64(rawValue: 1)))
        XCTAssertNil(try peer.system.resolve(id: id, as: Echo.self),
                     "a proxy through our own session is a proxy, not a refusal")
    }

    // MARK: - 1. the request packet

    func testARemoteCallEmitsARequestPacketPinnedFieldByField() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let (task, box) = call(peer, on: proxy, target: "double", returning: Int.self) {
            try $0.recordArgument(RemoteCallArgument(label: nil, name: "value", value: 7))
        }
        defer { task.cancel() }

        try await expectPackets(peer, 1, "nothing was sent")
        let packet = peer.packets[0]

        // The envelope, read off the wire object rather than off the enum we built.
        let raw = packet.rawValue
        XCTAssertEqual(Packet.uint64(raw, EnvelopeKey.headerCategory), 1,
                       "category 1 is a request")
        XCTAssertNotNil(Packet.uint64(raw, EnvelopeKey.headerID),
                        "a request must carry a correlation id")

        let request = try packet.payload.decode(as: PeerRequest.self)
        XCTAssertEqual(request.remoteCallIdentifier, "double")
        // `"Si"` written out, not `SwiftType(Int.self)?.mangledTypeName`: the spec states
        // the mangled name, and comparing against the same mangler that produced it would
        // only be agreeing with ourselves.
        XCTAssertEqual(request.returnType, "Si")
        XCTAssertNil(request.errorType, "a target that cannot throw writes no errorType")
        XCTAssertNil(request.protocolStub)
        XCTAssertEqual(request.genericSubsitutions, [])
        var arguments = request.arguments
        XCTAssertEqual(try arguments.decode(Int.self), 7)
        XCTAssertTrue(arguments.isAtEnd, "one argument was recorded, one must be sent")

        // The key as the raw unkeyed pair Apple writes -- `[WireCode, payload]` -- rather
        // than through our own `SharedActorKey` decoder, which would be self-agreement.
        let key = try packet.payload.decode(as: PeerRequestKey.self)
        XCTAssertEqual(key.wireCode, 1, "WireCode.exportedRawValue")
        XCTAssertEqual(key.name, "primary")

        // `basePriority` is derived from `Task.basePriority`, never passed, and lands as a
        // bare UInt8 rather than `{"rawValue": n}`. Asserted unconditionally: the call is
        // made on a `Task`, so there *is* a base priority, and an `if let` here would let a
        // regression that stopped writing the key pass in silence. (`TaskPriority`'s stdlib
        // coding is `RawRepresentable`'s: high 25, medium 21, low 17, background 9.)
        let basePriority = try XCTUnwrap(request.basePriority,
                                         "a call made on a task must carry its base priority")
        XCTAssertTrue([9, 17, 21, 25].contains(basePriority), "\(basePriority)")

        try peer.respond(to: packet, with: PeerSuccess(value: 14))
        await settle(task, box)
        XCTAssertEqual(try box.outcome?.get(), 14)
    }

    /// **The request id is minted by the session's own counter -- the same one that mints
    /// `dynamic` shared-actor keys.** Sharing an actor first takes 1, so the first
    /// request takes 2. A separate counter would still say 1.
    func testTheRequestIDComesFromTheCounterThatAlsoMintsSharedActorKeys() async throws {
        let peer = try Peer()
        let resident = Echo(actorSystem: peer.system)
        guard case .local(let local) = resident.id.raw else {
            return XCTFail("a resident actor has a local id")
        }
        XCTAssertEqual(peer.session.shareDynamically(local), SharedActorKey.dynamic(ID64(rawValue: 1)))

        let proxy = try peer.proxy()
        let (task, box) = call(peer, on: proxy, target: "double", returning: Int.self)
        defer { task.cancel() }

        try await expectPackets(peer, 1, "nothing was sent")
        let request = try peer.packets[0].payload.decode(as: PeerRequest.self)
        XCTAssertEqual(request.id, 2, "the request id came from a counter of its own")

        try peer.respond(to: peer.packets[0], with: PeerSuccess(value: 1))
        await settle(task, box)
        withExtendedLifetime(resident) {}
    }

    /// A second call takes the next number, and the two are distinct.
    func testConsecutiveRequestsTakeConsecutiveIDs() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let (first, firstBox) = call(peer, on: proxy, target: "a", returning: Int.self)
        try await expectPackets(peer, 1)
        let (second, secondBox) = call(peer, on: proxy, target: "b", returning: Int.self)
        try await expectPackets(peer, 2)
        defer { first.cancel(); second.cancel() }

        let ids = try peer.packets.map { try $0.payload.decode(as: PeerRequest.self).id }
        XCTAssertEqual(ids, [1, 2])

        try peer.respond(to: peer.packets[0], with: PeerSuccess(value: 0))
        try peer.respond(to: peer.packets[1], with: PeerSuccess(value: 0))
        await settle(first, firstBox)
        await settle(second, secondBox)
    }

    // MARK: - 2. responses built by the peer

    func testAHandBuiltSuccessResponseBecomesTheReturnValue() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let (task, box) = call(peer, on: proxy, target: "double", returning: Int.self)
        try await expectPackets(peer, 1)

        try peer.respond(to: peer.packets[0], with: PeerSuccess(value: 42))
        await settle(task, box)
        XCTAssertEqual(try box.outcome?.get(), 42)
    }

    /// A non-primitive success, so the value goes through the generic witness on both
    /// sides rather than a builtin overload.
    func testAHandBuiltStructuredSuccessDecodes() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let (task, box) = call(peer, on: proxy, target: "point", returning: Point.self)
        try await expectPackets(peer, 1)

        try peer.respond(to: peer.packets[0], with: PeerSuccess(value: Point(x: 1, y: "a")))
        await settle(task, box)
        XCTAssertEqual(try box.outcome?.get(), Point(x: 1, y: "a"))
    }

    /// Tag 1 becomes a throw, and the text is the peer's. Apple carries no concrete
    /// error type -- `RemoteInvocationFailure` holds a `String` -- so the text is all
    /// there is and it must survive intact.
    func testAHandBuiltExecutionFailureBecomesAThrowCarryingItsText() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let (task, box) = call(peer, on: proxy, target: "double", returning: Int.self)
        try await expectPackets(peer, 1)

        try peer.respond(to: peer.packets[0],
                         with: PeerFailure(kind: .executionFailed, message: "the callee said no"))
        await settle(task, box)

        let error = try cancellationError(box.outcome)
        XCTAssertEqual(error.reason, .executionFailed)
        XCTAssertTrue(error.message.contains("the callee said no"), error.message)
    }

    /// The other failure case keeps its own reason rather than being flattened.
    func testAHandBuiltResultPropagationFailureKeepsItsReason() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let (task, box) = call(peer, on: proxy, target: "double", returning: Int.self)
        try await expectPackets(peer, 1)

        try peer.respond(to: peer.packets[0],
                         with: PeerFailure(kind: .resultPropagationFailed, message: "lost it"))
        await settle(task, box)

        let error = try cancellationError(box.outcome)
        XCTAssertEqual(error.reason, .resultPropagationFailed)
        XCTAssertTrue(error.message.contains("lost it"), error.message)
    }

    /// A body we cannot read is not an execution failure -- the invocation may well have
    /// run. `.resultPropagationFailed` is the reason whose default text says exactly
    /// that.
    func testAResponseThatCannotBeDecodedIsAResultPropagationFailure() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let (task, box) = call(peer, on: proxy, target: "double", returning: Int.self)
        try await expectPackets(peer, 1)

        // Tag 0 over a value that is not an Int.
        try peer.respond(to: peer.packets[0], with: PeerSuccess(value: "not an int"))
        await settle(task, box)

        let error = try cancellationError(box.outcome)
        XCTAssertEqual(error.reason, .resultPropagationFailed)
    }

    // MARK: - 3. remoteCallVoid

    func testRemoteCallVoidReturnsOnAHandBuiltAck() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let box = ResultBox<Bool>()
        let task = Task {
            var encoder = peer.system.makeInvocationEncoder()
            do {
                try encoder.doneRecording()
                try await peer.system.remoteCallVoid(
                    on: proxy, target: RemoteCallTarget("note"), invocation: &encoder,
                    throwing: CallerError.self)
                box.set(.success(true))
            } catch {
                box.set(.failure(error))
            }
        }
        try await expectPackets(peer, 1)

        try peer.respond(to: peer.packets[0], with: PeerVoidSuccess())
        await settle(task, box)
        XCTAssertEqual(try box.outcome?.get(), true)
    }

    func testRemoteCallVoidThrowsOnAHandBuiltFailure() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let box = ResultBox<Bool>()
        let task = Task {
            var encoder = peer.system.makeInvocationEncoder()
            do {
                try encoder.doneRecording()
                try await peer.system.remoteCallVoid(
                    on: proxy, target: RemoteCallTarget("note"), invocation: &encoder,
                    throwing: CallerError.self)
                box.set(.success(true))
            } catch {
                box.set(.failure(error))
            }
        }
        try await expectPackets(peer, 1)

        try peer.respond(to: peer.packets[0],
                         with: PeerFailure(kind: .executionFailed, message: "void call failed"))
        await settle(task, box)
        let error = try cancellationError(box.outcome)
        XCTAssertTrue(error.message.contains("void call failed"), error.message)
    }

    // MARK: - 4. a local actor

    /// Apple's message, and it is reached **before** any session is involved -- so
    /// nothing goes out.
    func testARemoteCallOnALocalActorThrowsAndSendsNothing() async throws {
        let peer = try Peer()
        let resident = Echo(actorSystem: peer.system)
        var encoder = peer.system.makeInvocationEncoder()
        try encoder.doneRecording()

        do {
            let value = try await peer.system.remoteCall(
                on: resident, target: RemoteCallTarget("double"), invocation: &encoder,
                throwing: CallerError.self, returning: Int.self)
            XCTFail("remoteCall returned \(value) for a local actor")
        } catch {
            XCTAssertEqual(error.reason, .executionFailed)
            XCTAssertTrue(error.message.contains("Remote call on a local actor."), error.message)
        }
        XCTAssertEqual(peer.packets.count, 0, "nothing may be sent for a local actor")
    }

    func testRemoteCallVoidOnALocalActorThrowsAndSendsNothing() async throws {
        let peer = try Peer()
        let resident = Echo(actorSystem: peer.system)
        var encoder = peer.system.makeInvocationEncoder()
        try encoder.doneRecording()

        do {
            try await peer.system.remoteCallVoid(
                on: resident, target: RemoteCallTarget("note"), invocation: &encoder,
                throwing: CallerError.self)
            XCTFail("remoteCallVoid returned for a local actor")
        } catch {
            XCTAssertTrue("\(error)".contains("Remote call on a local actor."), "\(error)")
        }
        XCTAssertEqual(peer.packets.count, 0, "nothing may be sent for a local actor")
    }

    /// The other half of the same guard, and the one with no counterpart in Apple's:
    /// their `Remote.session` is *typed* as the outbound protocol, ours is the narrower
    /// `SessionCoding`, so "a session that can code ids but cannot send" is representable
    /// here and has to be refused by name rather than trapped.
    func testAProxyThroughASessionThatCannotSendIsRefusedByName() async throws {
        let peer = try Peer()
        let impostor = ImpostorSession(claiming: peer.system)
        let proxy = try Echo.resolve(id: impostor.remoteID(for: .exportedRawValue("x")),
                                     using: peer.system)
        var encoder = peer.system.makeInvocationEncoder()
        try encoder.doneRecording()

        do {
            let value: Int = try await peer.system.remoteCall(
                on: proxy, target: RemoteCallTarget("t"), invocation: &encoder,
                throwing: CallerError.self, returning: Int.self)
            XCTFail("remoteCall returned \(value) through a session that cannot send")
        } catch {
            XCTAssertEqual(error.reason, .executionFailed)
            XCTAssertTrue(error.message.contains("cannot send invocations"), error.message)
        }
        XCTAssertEqual(peer.packets.count, 0)
    }

    // MARK: - 5. an argument that is an actor reference

    /// An `ActorID` in an argument is shared into *this* session on the way out, and
    /// what lands on the wire is the key -- nothing process-local.
    func testAnArgumentCarryingAnActorIDIsSharedIntoTheSessionAsAKey() async throws {
        let peer = try Peer()
        let resident = Echo(actorSystem: peer.system)
        let proxy = try peer.proxy()
        let residentID = resident.id

        let (task, box) = call(peer, on: proxy, target: "introduce", returning: Int.self) {
            try $0.recordArgument(RemoteCallArgument(label: nil, name: "other", value: residentID))
        }
        defer { task.cancel() }
        try await expectPackets(peer, 1)

        let request = try peer.packets[0].payload.decode(as: PeerRequest.self)
        var arguments = request.arguments
        // An `ActorID` is a bare `SharedActorKey` on the wire.
        let key = try arguments.decode(SharedActorKey.self)
        XCTAssertEqual(key, .dynamic(ID64(rawValue: 2)),
                       "key 1 would mean the request id did not take a number")
        XCTAssertEqual(peer.session.sharedActorCount, 1,
                       "the argument must have been shared into this session")
        XCTAssertTrue(peer.session.resolveSharedActor(at: key) === resident)

        try peer.respond(to: peer.packets[0], with: PeerSuccess(value: 0))
        await settle(task, box)
        withExtendedLifetime(resident) {}
    }

    /// The refusal that keeps the two key spaces apart still applies on this path: an
    /// argument holding a *proxy* fails the call, and fails it before anything is sent.
    func testAnArgumentCarryingAProxyFailsTheCallBeforeAnythingIsSent() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let proxyID = proxy.id

        let (task, box) = call(peer, on: proxy, target: "introduce", returning: Int.self) {
            try $0.recordArgument(RemoteCallArgument(label: nil, name: "other", value: proxyID))
        }
        // Polled, never awaited -- see ``settle(_:_:)``. This test passed a mutant that
        // swallowed the encoding error, purely by hanging.
        let settled = await settle(task, box, "the call parked instead of refusing")
        XCTAssertEqual(peer.packets.count, 0, "a request that cannot be encoded is not sent")
        guard settled else { return }

        let error = try cancellationError(box.outcome)
        XCTAssertEqual(error.reason, .executionFailed)
    }

    /// The decode half of the same seam. A peer may *return* an actor reference, and a
    /// key coming back cannot become a proxy without the session in the `userInfo` --
    /// which is why the dictionary is threaded through both directions and not just the
    /// encode.
    func testAResponseCarryingAnActorReferenceComesBackAsAProxy() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let (task, box) = call(peer, on: proxy, target: "find", returning: ActorID.self)
        try await expectPackets(peer, 1)

        // An `ActorID` is a bare `SharedActorKey` on the wire, so this is what a peer
        // returning one of *its* actors writes.
        try peer.respond(to: peer.packets[0],
                         with: PeerSuccess(value: SharedActorKey.dynamic(ID64(rawValue: 5))))
        await settle(task, box)

        guard case .remote(let remote) = try XCTUnwrap(box.outcome?.get()).raw else {
            return XCTFail("a key coming back is always a proxy")
        }
        XCTAssertEqual(remote.key, .dynamic(ID64(rawValue: 5)))
        XCTAssertTrue(remote.session === peer.session,
                      "and it is a proxy through the session that received it")
    }

    /// A key means nothing outside the key space of the session that minted it. Reaching
    /// `sendInvocation` directly is the only way to try -- `remoteCall` takes the session
    /// *from* the id -- so this pins the guard rather than the route to it.
    func testASessionRefusesAnIDFromAnotherSessionsKeySpace() async throws {
        let peer = try Peer()
        let other = peer.system.makeDetachedSession()
        let foreign = other.remoteID(for: .dynamic(ID64(rawValue: 1)))

        // On a task, and polled rather than awaited -- see ``settle(_:_:)``: dropping the
        // guard makes this *send*, and a sent request with no answer is a hang.
        let box = ResultBox<Int>()
        let task = Task {
            var encoder = peer.system.makeInvocationEncoder()
            do {
                try encoder.doneRecording()
                box.set(.success(try await peer.session.sendInvocation(
                    to: foreign, target: RemoteCallTarget("x"), invocation: &encoder)))
            } catch {
                box.set(.failure(error))
            }
        }
        let settled = await settle(task, box, "sendInvocation parked instead of refusing")
        XCTAssertEqual(peer.packets.count, 0, "nothing may be sent into the wrong key space")
        guard settled else { return }

        let error = try cancellationError(box.outcome)
        XCTAssertEqual(error.reason, .executionFailed)
    }

    // MARK: - 6. the transport dies

    /// The wiring the last slice left open: `handleTransportCancellation()` now has a
    /// caller, and a completed cancellation empties the exported-actor table.
    func testTransportDeathFailsTheCallerAndEmptiesTheSharedActorTable() async throws {
        let peer = try Peer()
        let resident = Echo(actorSystem: peer.system)
        guard case .local(let local) = resident.id.raw else {
            return XCTFail("a resident actor has a local id")
        }
        XCTAssertNotNil(peer.session.shareDynamically(local))
        XCTAssertEqual(peer.session.sharedActorCount, 1)

        let proxy = try peer.proxy()
        let (task, box) = call(peer, on: proxy, target: "double", returning: Int.self)
        try await expectPackets(peer, 1, "the call never went out")

        peer.far.cancel(reason: "peer went away")
        await settle(task, box)

        let error = try cancellationError(box.outcome)
        XCTAssertEqual(error.reason, .underlyingSessionCancelled)
        XCTAssertTrue(error.message.contains("peer went away"), error.message)
        XCTAssertEqual(peer.session.sharedActorCount, 0,
                       "a cancelled session must not still be exporting actors")
        XCTAssertNil(peer.session.shareDynamically(local),
                     "and must not start exporting again")
        withExtendedLifetime(resident) {}
    }

    /// Our own `cancel` is the same teardown, so it reaches the session too.
    func testCancellingOurOwnTransportAlsoClearsTheSession() async throws {
        let peer = try Peer()
        let resident = Echo(actorSystem: peer.system)
        guard case .local(let local) = resident.id.raw else {
            return XCTFail("a resident actor has a local id")
        }
        XCTAssertNotNil(peer.session.shareDynamically(local))

        peer.transport.cancel(reason: "shutting down")
        XCTAssertEqual(peer.session.sharedActorCount, 0)
        withExtendedLifetime(resident) {}
    }

    // MARK: - 7. cancelling one call

    /// Task cancellation cancels **that request**, not the session. The second call is
    /// still live afterwards and still answerable.
    func testCancellingOneCallLeavesTheOthersAlone() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()

        let (doomed, doomedBox) = call(peer, on: proxy, target: "doomed", returning: Int.self)
        try await expectPackets(peer, 1)
        let (survivor, survivorBox) = call(peer, on: proxy, target: "survivor", returning: Int.self)
        try await expectPackets(peer, 2)

        // Confirm the ordering the rest of the test rests on.
        XCTAssertEqual(try peer.packets[0].payload.decode(as: PeerRequest.self)
                        .remoteCallIdentifier, "doomed")

        doomed.cancel()
        await settle(doomed, doomedBox, "cancelling the calling task did not fail its call")
        let error = try cancellationError(doomedBox.outcome)
        XCTAssertEqual(error.reason, .callingTaskCancelled)

        XCTAssertNil(survivorBox.outcome, "the survivor must still be in flight")

        try peer.respond(to: peer.packets[1], with: PeerSuccess(value: 99))
        await settle(survivor, survivorBox)
        XCTAssertEqual(try survivorBox.outcome?.get(), 99)
    }

    /// **The peer is told to stop.** Failing our own caller is only half of a cancellation:
    /// the peer is still executing a target whose result nobody will read, and only this
    /// side knows that. `RemoteNotification.invocationCancelled(id:)` is what says so, and
    /// the id it carries is the **request body's**, not the envelope's `headerID` -- which
    /// is the reason the request id is minted from the session's own generator.
    func testCancellingACallTellsThePeerToStopExecutingIt() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()

        let (task, box) = call(peer, on: proxy, target: "doomed", returning: Int.self)
        try await expectPackets(peer, 1)
        let requestID = try peer.packets[0].payload.decode(as: PeerRequest.self).id

        task.cancel()
        await settle(task, box, "cancelling the calling task did not fail its call")
        XCTAssertEqual(try cancellationError(box.outcome).reason, .callingTaskCancelled)

        // The notification is a second packet, not a reply: it goes out one-way with no
        // correlation id in the envelope at all.
        try await expectPackets(peer, 2, "the peer was never told to stop")
        let notification = peer.packets[1]
        XCTAssertEqual(notification.header, .notification,
                       "a cancellation is a notification, not a request")
        XCTAssertEqual(Packet.uint64(notification.rawValue, EnvelopeKey.headerCategory), 0)
        XCTAssertNil(Packet.uint64(notification.rawValue, EnvelopeKey.headerID),
                     "a notification header has no id")

        let cancelled = try notification.payload.decode(as: PeerCancellation.self)
        XCTAssertEqual(cancelled.cancelledID, requestID,
                       "the notification must name the request body's id")
    }

    /// A cancellation racing the transport's death is silent rather than a second failure.
    ///
    /// This is what the `try?` around the notification is for, and it is the only thing it
    /// is for: whichever of the two wins, the caller is failed, and if the task-cancelled
    /// arm wins it tries to tell a peer that is no longer reachable. There is nothing to
    /// report and nobody to report it to.
    func testACancellationRacingTransportDeathTellsNobodyAndStillFails() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()

        let (task, box) = call(peer, on: proxy, target: "doomed", returning: Int.self)
        try await expectPackets(peer, 1)

        peer.far.cancel(reason: "peer went away")
        task.cancel()
        await settle(task, box)
        XCTAssertNotNil(box.outcome, "the caller is failed whichever arm won")
        XCTAssertEqual(peer.packets.count, 1, "nothing may be sent down a dead transport")
    }

    // MARK: - end to end

    /// The same path with the Swift runtime driving it, rather than an encoder we filled
    /// in ourselves. This is the only test here that exercises `recordArgument` and
    /// `recordReturnType` as the compiler emits them.
    func testADistributedFuncCallGoesOutAndComesBack() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let box = ResultBox<Int>()
        let task = Task {
            do { box.set(.success(try await proxy.double(21))) }
            catch { box.set(.failure(error)) }
        }
        try await expectPackets(peer, 1)

        let request = try peer.packets[0].payload.decode(as: PeerRequest.self)
        XCTAssertTrue(request.remoteCallIdentifier.contains("double"),
                      request.remoteCallIdentifier)
        var arguments = request.arguments
        XCTAssertEqual(try arguments.decode(Int.self), 21)

        try peer.respond(to: peer.packets[0], with: PeerSuccess(value: 42))
        await settle(task, box)
        XCTAssertEqual(try box.outcome?.get(), 42)
    }

    /// And the void shape, end to end.
    func testADistributedVoidFuncCallGoesOutAndComesBack() async throws {
        let peer = try Peer()
        let proxy = try peer.proxy()
        let box = ResultBox<Bool>()
        let task = Task {
            do {
                try await proxy.note("hello")
                box.set(.success(true))
            } catch { box.set(.failure(error)) }
        }
        try await expectPackets(peer, 1)

        try peer.respond(to: peer.packets[0], with: PeerVoidSuccess())
        await settle(task, box)
        XCTAssertEqual(try box.outcome?.get(), true)
    }
}
