// Tests/XPCActorsTests/PeerGateTests.swift
import XCTest
import XPC
import Distributed
@testable import XPCActors

/// Who may invoke, and when.
///
/// Three gates, and two of them are the only thing between a Mach service and any process
/// that can reach it:
///
/// - the **system-wide** peer requirement (`Session.remoteSatisfiesActorSystemRequirement()`),
/// - the **per-actor** one (`RestrictedAccessDistributedActor.peerRequirement`),
/// - the **activation** gate (`Session.waitForLocalInterfaceActivation()`), which is not a
///   security gate but an ordering one.
///
/// **Nothing here awaits the thing under test.** Same discipline as
/// `InboundInvocationTests.swift`: a gate that fails to answer would wedge the bundle at
/// zero reported failures rather than redden it, and the activation tests are *specifically*
/// about a request that is deliberately not answered yet.

// ===========================================================================================
// MARK: - Attesting, and refusing to
// ===========================================================================================

/// A transport-level attestation that answers from a table.
///
/// This stands in for `AuditTokenAttestation` on the in-process pipe, and it is not a
/// weakening of the gate: the production path (`XPCRawTransport.peerAttestation`) builds a
/// real `AuditTokenAttestation` over Apple's own `audit_token_t.satisfies(requirement:)`, and
/// `testTheOverlayBridgeResolvesAndRefusesADictionaryThatNeverCrossedAConnection` exercises
/// that code for real. What a test cannot do is *forge* a peer that satisfies an
/// entitlement, so the answer is injected at the one seam a real transport also fills.
///
/// An unknown requirement answers `nil` -- "cannot tell" -- which is what a real attestation
/// does with a requirement it cannot express.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
struct TableAttestation: PeerAttestation, Sendable {
    let answers: [String: Bool]
    init(_ answers: [String: Bool]) { self.answers = answers }
    func satisfies(_ requirement: PeerRequirement) -> Bool? { answers[requirement.description] }
}

@available(macOS 26, *)
let systemRequirement = PeerRequirement("test.system.requirement")
@available(macOS 26, *)
let vaultRequirement = PeerRequirement("test.vault.requirement")

/// An actor that vets its own callers, over and above whatever the system requires.
///
/// `peerRequirement` is a **computed** `nonisolated` property because Swift does not allow a
/// `nonisolated` *stored* property on a distributed actor -- storage on a distributed actor
/// might not be here at all. Apple's requirement is read synchronously out of the witness
/// table on the inbound path, with no `await`, so nonisolated is not a choice either way.
@available(macOS 26, *)
distributed actor Vault: RestrictedAccessDistributedActor {
    typealias ActorSystem = XPCActorSystem

    nonisolated var peerRequirement: PeerRequirement { vaultRequirement }

    let log: InboundLog

    init(actorSystem: ActorSystem, log: InboundLog) {
        self.actorSystem = actorSystem
        self.log = log
    }

    distributed func secret() -> Int {
        log.note("vault ran")
        return 99
    }
}

// ===========================================================================================
// MARK: - Harness
// ===========================================================================================

/// Two systems, two sessions, one pipe -- with the server end's peer requirement, its
/// attestation and its activation state all under the test's control.
@available(macOS 26, *)
private final class GatedLink: @unchecked Sendable {
    let clientSystem: XPCActorSystem
    let serverSystem: XPCActorSystem
    let near: InProcessRawTransport
    let far: InProcessRawTransport
    let clientTransport: Transport
    let serverTransport: Transport
    let clientSession: Session
    let serverSession: Session

    init(serverRequirement: PeerRequirement? = nil,
         serverAttestation: (any PeerAttestation)? = nil,
         serverActivated: Bool = true,
         qos: DispatchQoS = .unspecified) throws {
        clientSystem = XPCActorSystem("client")
        serverSystem = XPCActorSystem("server", peerRequirement: serverRequirement)
        let pair = InProcessRawTransport.makePair(debugName: "gated", qos: qos)
        near = pair.0
        far = pair.1
        // The *server* end's attestation is what it can prove about the client.
        far.peerAttestation = serverAttestation
        clientTransport = Transport(debugName: "client", role: .initiator, rawTransport: near)
        serverTransport = Transport(debugName: "server", role: .responder, rawTransport: far)
        clientSession = clientSystem.makeSession(over: clientTransport)
        serverSession = serverSystem.makeSession(over: serverTransport,
                                                 localInterfaceActivated: serverActivated)
        try near.activate()
        try far.activate()
    }

    @discardableResult
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
}

/// Somewhere a `Task` can leave its outcome that a test body can read without awaiting it.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private final class Outcome<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Value, any Error>?
    var value: Result<Value, any Error>? { lock.withLock { storage } }
    func set(_ result: Result<Value, any Error>) { lock.withLock { storage = result } }
}

// ===========================================================================================
// MARK: - The tests
// ===========================================================================================

@available(macOS 26, *)
final class PeerGateTests: XCTestCase {

    /// Start `body` detached, filling `box`. Nothing awaits the returned task.
    @discardableResult
    private func fire<Value: Sendable>(
        _ box: Outcome<Value>,
        priority: TaskPriority? = nil,
        _ body: @escaping @Sendable () async throws -> Value
    ) -> Task<Void, Never> {
        Task.detached(priority: priority) {
            do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
        }
    }

    /// Start `body` and poll its box rather than awaiting it. See the file comment.
    @discardableResult
    private func settle<Value: Sendable>(
        _ box: Outcome<Value>,
        _ body: @escaping @Sendable () async throws -> Value,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        let task = fire(box, body)
        let settled = await waitUntil { box.value != nil }
        task.cancel()
        XCTAssertTrue(settled, "the call never produced an outcome -- it parked",
                      file: file, line: line)
        return settled
    }

    // -------------------------------------------------------------------------------------
    // MARK: 1. An unconfigured system admits everyone
    // -------------------------------------------------------------------------------------

    /// `XPCSystem.peerRequirement`'s default is `nil` -- both of the initialisers that do not
    /// take one store the optional's empty case -- so an unconfigured system admits a peer it
    /// cannot attest to at all. This is the behaviour every other test in this suite depends
    /// on, and adding the gate must not have changed it.
    func testAnUnconfiguredSystemAdmitsAPeerItCannotAttestTo() async throws {
        let link = try GatedLink()
        XCTAssertNil(link.serverSystem.peerRequirement)
        XCTAssertNil(link.serverTransport.peerAttestation)
        XCTAssertTrue(link.serverSession.remoteSatisfiesActorSystemRequirement())

        let callee = Calculator(actorSystem: link.serverSystem)
        let key = try link.export(callee.id)
        let proxy = try link.proxy(Calculator.self, at: key)

        let box = Outcome<Int>()
        let settled = await settle(box) { try await proxy.add(20, 22) }
        XCTAssertTrue(settled)
        XCTAssertEqual(try box.value?.get(), 42)
        link.clientTransport.cancel(reason: "done")
    }

    // -------------------------------------------------------------------------------------
    // MARK: 2. The system-wide gate
    // -------------------------------------------------------------------------------------

    func testASystemRequirementThePeerSatisfiesAdmitsIt() async throws {
        let link = try GatedLink(
            serverRequirement: systemRequirement,
            serverAttestation: TableAttestation([systemRequirement.description: true]))
        XCTAssertTrue(link.serverSession.remoteSatisfiesActorSystemRequirement())

        let callee = Calculator(actorSystem: link.serverSystem)
        let proxy = try link.proxy(Calculator.self, at: try link.export(callee.id))

        let box = Outcome<Int>()
        let settled = await settle(box) { try await proxy.add(1, 2) }
        XCTAssertTrue(settled)
        XCTAssertEqual(try box.value?.get(), 3)
        link.clientTransport.cancel(reason: "done")
    }

    /// **The refusal, and it is not a failure response.**
    ///
    /// Apple's arm at `handleReceivedRequest+0xba8` tail-calls
    /// `Session.cancel(because: "(Internal) Remote peer does not satisfy actor system's peer
    /// requirement")` and sends nothing. That is not a dropped request: cancelling fails the
    /// peer's outstanding call through the transport, so the caller is answered -- with
    /// `.underlyingSessionCancelled` rather than `.executionFailed` -- and the door is shut
    /// for the *next* request too.
    func testASystemRequirementThePeerFailsCancelsTheSessionAndNeverRunsTheTarget()
    async throws {
        let log = InboundLog()
        let link = try GatedLink(
            serverRequirement: systemRequirement,
            serverAttestation: TableAttestation([systemRequirement.description: false]))
        XCTAssertFalse(link.serverSession.remoteSatisfiesActorSystemRequirement())

        let callee = Calculator(actorSystem: link.serverSystem, log: log)
        XCTAssertEqual(link.serverSession.sharedActorCount, 0)
        let proxy = try link.proxy(Calculator.self, at: try link.export(callee.id))
        XCTAssertEqual(link.serverSession.sharedActorCount, 1)

        let box = Outcome<Void>()
        let settled = await settle(box) { try await proxy.remember("must not run") }
        XCTAssertTrue(settled)

        guard case .failure(let error) = try XCTUnwrap(box.value) else {
            return XCTFail("the call should not have succeeded")
        }
        let cancellation = try XCTUnwrap(error as? RemoteInvocationCancellationError)
        XCTAssertEqual(cancellation.reason, .underlyingSessionCancelled)

        // The target never ran, and the session took its exported actors down with it.
        XCTAssertFalse(log.has("must not run"))
        let emptied = await waitUntil { link.serverSession.sharedActorCount == 0 }
        XCTAssertTrue(emptied)
        XCTAssertTrue(link.serverTransport.isCancelled)
    }

    /// **Fail closed.** A requirement that is set and a transport that can attest to nothing
    /// refuses. `PeerAttestation` is three-valued precisely so that "unknown" is not "no",
    /// and this is the one place that has to collapse it -- collapsing the other way would
    /// mean a transport with no attestation silently disabled the gate.
    func testASystemRequirementWithNoAttestationAtAllRefuses() async throws {
        let link = try GatedLink(serverRequirement: systemRequirement, serverAttestation: nil)
        XCTAssertFalse(link.serverSession.remoteSatisfiesActorSystemRequirement())

        let callee = Calculator(actorSystem: link.serverSystem)
        let proxy = try link.proxy(Calculator.self, at: try link.export(callee.id))
        let box = Outcome<Int>()
        let settled = await settle(box) { try await proxy.add(1, 1) }
        XCTAssertTrue(settled)
        guard case .failure = try XCTUnwrap(box.value) else {
            return XCTFail("a peer that cannot be attested to must not be admitted")
        }
    }

    /// **The gate runs before the payload is parsed, and this is what pins it.**
    ///
    /// That ordering is the one behavioural correction made to the interop spec on security
    /// grounds -- `remoteSatisfiesActorSystemRequirement` is called at
    /// `handleReceivedRequest+0x930` and `XPCDictionary.decode(as:forKey:withUserInfo:)` at
    /// `+0x9a4`, with the `"payload"` literal built between them -- so an unentitled peer's
    /// bytes are never handed to a decoder.
    ///
    /// A body that is not a request at all is sent by a peer that fails the requirement. The
    /// two orders are distinguishable from outside: gate-first cancels the session with the
    /// peer-requirement reason and never looks at the bytes, decode-first answers
    /// `"could not decode the invocation request"` -- telling a peer we have just decided
    /// must not talk to us something about how our parser reacted to its bytes.
    func testTheGateRunsBeforeTheDecodeSoAnUnentitledPeersBytesAreNeverParsed() async throws {
        let link = try GatedLink(
            serverRequirement: systemRequirement,
            serverAttestation: TableAttestation([systemRequirement.description: false]))

        struct NotARequest: Encodable { let not = "a request" }
        let payload = try Packet.Payload(encoding: NotARequest(), userInfo: [:])

        let box = Outcome<RequestTable.Outcome>()
        fire(box) {
            await link.clientTransport.sendRequest(
                seq: link.clientTransport.allocateSeq(), payload)
        }
        let answered = await waitUntil { box.value != nil }
        XCTAssertTrue(answered)

        guard case .failed(.transportCancelled(let message)) = try XCTUnwrap(box.value).get()
        else {
            return XCTFail("""
                expected the session to be cancelled by the gate; got \
                \(String(describing: box.value)). A `.reply` here means the decode ran first \
                and an unentitled peer's bytes reached the decoder.
                """)
        }
        XCTAssertTrue(message.contains("does not satisfy actor system's peer requirement"),
                      "cancelled for the wrong reason: \(message)")
        XCTAssertFalse(message.contains("could not decode"),
                       "the payload was parsed before the gate ran")
    }

    /// A requirement an attestation cannot *express* is also "cannot tell", and is also
    /// refused. `TableAttestation` returns `nil` for a name it has never heard of, exactly as
    /// `AuditTokenAttestation` returns `nil` for a requirement carrying no
    /// `XPCPeerRequirement`.
    func testARequirementTheAttestationCannotExpressIsRefused() async throws {
        let link = try GatedLink(
            serverRequirement: systemRequirement,
            serverAttestation: TableAttestation(["some.other.requirement": true]))
        XCTAssertNil(link.serverTransport.peerAttestation?.satisfies(systemRequirement))
        XCTAssertFalse(link.serverSession.remoteSatisfiesActorSystemRequirement())
    }

    // -------------------------------------------------------------------------------------
    // MARK: 3. The per-actor gate
    // -------------------------------------------------------------------------------------

    /// **Per resolved target, which is the whole point.** The system-wide gate passed --
    /// there is no system requirement here at all -- and one actor on the session is still
    /// refused while another, on the same session and for the same peer, answers normally.
    func testARestrictedActorIsRefusedWhileAnotherActorOnTheSameSessionStillWorks()
    async throws {
        let vaultLog = InboundLog()
        let link = try GatedLink(
            serverAttestation: TableAttestation([vaultRequirement.description: false]))

        let vault = Vault(actorSystem: link.serverSystem, log: vaultLog)
        let calculator = Calculator(actorSystem: link.serverSystem)
        let vaultProxy = try link.proxy(Vault.self, at: try link.export(vault.id))
        let calculatorProxy = try link.proxy(Calculator.self, at: try link.export(calculator.id))

        let refused = Outcome<Int>()
        let refusedSettled = await settle(refused) { try await vaultProxy.secret() }
        XCTAssertTrue(refusedSettled)
        guard case .failure(let error) = try XCTUnwrap(refused.value) else {
            return XCTFail("the vault should have refused")
        }
        // Apple's own wording, `__cstring` 0x2ad5262b0, 37 bytes.
        XCTAssertTrue("\(error)".contains("Failed actor's peer requirement check"),
                      "unexpected refusal text: \(error)")
        XCTAssertFalse(vaultLog.has("vault ran"))

        // Same session, same peer, unrestricted actor.
        let allowed = Outcome<Int>()
        let allowedSettled = await settle(allowed) { try await calculatorProxy.add(2, 3) }
        XCTAssertTrue(allowedSettled)
        XCTAssertEqual(try allowed.value?.get(), 5)

        // And the session is still up -- unlike the system-wide gate, this one answers.
        XCTAssertFalse(link.serverTransport.isCancelled)
        // A refused execution still has to leave the pending table. It is registered before
        // the gate runs (registration is synchronous, the gate is not), so an arm that
        // returns without removing itself leaves an entry a later `invocationCancelled`
        // would find -- the orphan shape the duplicate-id guard exists for.
        let drained = await waitUntil { link.serverSession.pendingInvocationIDs.isEmpty }
        XCTAssertTrue(drained, "the refused execution left its pending-table entry behind")
        link.clientTransport.cancel(reason: "done")
    }

    func testARestrictedActorAdmitsAPeerThatSatisfiesItsOwnRequirement() async throws {
        let vaultLog = InboundLog()
        let link = try GatedLink(
            serverAttestation: TableAttestation([vaultRequirement.description: true]))
        let vault = Vault(actorSystem: link.serverSystem, log: vaultLog)
        let proxy = try link.proxy(Vault.self, at: try link.export(vault.id))

        let box = Outcome<Int>()
        let settled = await settle(box) { try await proxy.secret() }
        XCTAssertTrue(settled)
        XCTAssertEqual(try box.value?.get(), 99)
        XCTAssertTrue(vaultLog.has("vault ran"))
        link.clientTransport.cancel(reason: "done")
    }

    /// **Apple traps here; we answer.** A restricted actor reached over a transport that
    /// cannot produce an audit token is `brk #1` in `closure #2` (`0x2ad514e70`, reached by
    /// the `cmp w8,#1; b.eq` on the optional's tag byte) -- a force-unwrap. The peer chooses
    /// which actor a request names, so the peer chooses whether that trap fires; a
    /// peer-triggerable abort is a denial of service. Refused, and the process survives.
    func testARestrictedActorRefusesWhenTheTransportCanAttestToNothing() async throws {
        let vaultLog = InboundLog()
        let link = try GatedLink(serverAttestation: nil)
        let vault = Vault(actorSystem: link.serverSystem, log: vaultLog)
        let proxy = try link.proxy(Vault.self, at: try link.export(vault.id))

        let box = Outcome<Int>()
        let settled = await settle(box) { try await proxy.secret() }
        XCTAssertTrue(settled)
        guard case .failure = try XCTUnwrap(box.value) else {
            return XCTFail("an unattestable peer must not reach a restricted actor")
        }
        XCTAssertFalse(vaultLog.has("vault ran"))
    }

    // -------------------------------------------------------------------------------------
    // MARK: 4. The activation gate
    // -------------------------------------------------------------------------------------

    /// **The ordering hazard, made to happen.** The request names a key the server has not
    /// minted yet. Without the gate it resolves nothing and comes back a failure; with it,
    /// it waits, and the answer arrives once the actor is exported and the local interface
    /// is activated.
    ///
    /// `.dynamic(1)` is not a guess: `Session.lastID` starts at zero and the first mint is
    /// `nextID() == 1`, which is Apple's too (`idGenerator` is zeroed by both initialisers,
    /// so its first `next()` yields 1).
    func testARequestArrivingBeforeActivationWaitsAndThenSucceeds() async throws {
        let link = try GatedLink(serverActivated: false)
        XCTAssertFalse(link.serverSession.isLocalInterfaceActivated)

        let key = SharedActorKey.dynamic(ID64(rawValue: 1))
        let proxy = try link.proxy(Calculator.self, at: key)

        let box = Outcome<Int>()
        fire(box) { try await proxy.add(6, 7) }

        // The negative half: it is parked, not answered. If the gate were absent this would
        // already be a failure response, and this assertion is what catches it.
        let answeredEarly = await waitUntil(timeout: 0.4) { box.value != nil }
        XCTAssertFalse(answeredEarly,
                       "the request was answered before the local interface was activated")

        // Now the thing the peer was early for.
        let callee = Calculator(actorSystem: link.serverSystem)
        XCTAssertEqual(try link.export(callee.id), key)
        link.serverSession.activateLocalInterface()

        let answered = await waitUntil { box.value != nil }
        XCTAssertTrue(answered)
        XCTAssertEqual(try box.value?.get(), 13)
        link.clientTransport.cancel(reason: "done")
    }

    /// A parked execution must not outlive the pipe. Apple's `cancellationCompleted()`
    /// fulfils the `unownedLocalInterfaceActivationEvent` promise for exactly this reason;
    /// without it the execution would hold the session graph alive forever and the peer
    /// would never be answered.
    func testCancellationReleasesARequestParkedOnActivation() async throws {
        let link = try GatedLink(serverActivated: false)
        let proxy = try link.proxy(Calculator.self, at: .dynamic(ID64(rawValue: 1)))

        let box = Outcome<Int>()
        fire(box) { try await proxy.add(1, 1) }
        let registered = await waitUntil { link.serverSession.pendingInvocationIDs.count == 1 }
        XCTAssertTrue(registered)
        let answeredEarly = await waitUntil(timeout: 0.2) { box.value != nil }
        XCTAssertFalse(answeredEarly)

        link.serverTransport.cancel(reason: "peer went away")

        let answered = await waitUntil { box.value != nil }
        XCTAssertTrue(answered)
        guard case .failure = try XCTUnwrap(box.value) else {
            return XCTFail("a parked request on a dead session cannot succeed")
        }
        let drained = await waitUntil { link.serverSession.pendingInvocationIDs.isEmpty }
        XCTAssertTrue(drained, "the parked execution never finished")
    }

    /// **A request cancelled while parked on activation must not run when the gate opens.**
    ///
    /// This window did not exist before the activation gate: nothing used to suspend
    /// unboundedly between registering an execution and running it, so a cancellation that
    /// arrived in between had nowhere to land. Now a peer can park a request on a
    /// not-yet-activated session, abandon its caller -- which sends `invocationCancelled`, so
    /// the server-side task really is cancelled -- and without Apple's post-wait
    /// `Task.isCancelled` check the target runs anyway, side effects and all, for a call
    /// whose caller was already failed with `.callingTaskCancelled`.
    ///
    /// `ActivationEvent.wait()` deliberately does not observe cancellation (Apple's
    /// `await future.value` does not either), which is what makes the check after it the
    /// thing doing the work.
    func testARequestCancelledWhileParkedOnActivationNeverRunsTheTarget() async throws {
        let log = InboundLog()
        let link = try GatedLink(serverActivated: false)
        let key = SharedActorKey.dynamic(ID64(rawValue: 1))
        let proxy = try link.proxy(Calculator.self, at: key)

        let box = Outcome<Void>()
        let caller = fire(box) { try await proxy.remember("must not run") }

        // Parked on the server, registered, and not answered.
        let registered = await waitUntil { link.serverSession.pendingInvocationIDs.count == 1 }
        XCTAssertTrue(registered)
        let answeredEarly = await waitUntil(timeout: 0.3) { box.value != nil }
        XCTAssertFalse(answeredEarly)

        // The caller walks away. `sendInvocation`'s `.taskCancelled` arm notifies the peer,
        // which cancels this very execution task.
        caller.cancel()
        let failed = await waitUntil { box.value != nil }
        XCTAssertTrue(failed, "the abandoned caller was never failed")
        guard case .failure(let error) = try XCTUnwrap(box.value) else {
            return XCTFail("an abandoned call cannot succeed")
        }
        XCTAssertEqual((error as? RemoteInvocationCancellationError)?.reason,
                       .callingTaskCancelled)

        // Now open the gate. Everything the execution needs is in place -- so if the check
        // is missing, it resolves and runs.
        let callee = Calculator(actorSystem: link.serverSystem, log: log)
        XCTAssertEqual(try link.export(callee.id), key)
        link.serverSession.activateLocalInterface()

        let drained = await waitUntil { link.serverSession.pendingInvocationIDs.isEmpty }
        XCTAssertTrue(drained, "the cancelled execution never finished")
        XCTAssertFalse(log.has("must not run"),
                       "a peer-cancelled invocation ran the target after activation")
        link.clientTransport.cancel(reason: "done")
    }

    /// The event itself: one-shot, idempotent, and it does not suspend once posted.
    func testTheActivationEventIsAOneShotThatDoesNotSuspendOncePosted() async throws {
        let event = ActivationEvent(posted: false)
        XCTAssertFalse(event.isPosted)
        event.post()
        XCTAssertTrue(event.isPosted)
        event.post()
        await event.wait()   // returns without parking; a hang here is the failure
        XCTAssertTrue(event.isPosted)
    }

    /// Apple's `OwnedAwaitableEvent.owningTask` is **escalated and never awaited**. A waiter
    /// therefore reaches the owner with its own priority and does not wait for the owner to
    /// finish -- which is what makes it a gate rather than a join.
    func testAWaiterEscalatesTheOwnerAndDoesNotJoinIt() async throws {
        let event = ActivationEvent(posted: false)
        let escalated = Outcome<UInt8>()
        event.setOwner { priority in escalated.set(.success(priority.rawValue)) }

        let waited = Outcome<Bool>()
        Task.detached(priority: .userInitiated) {
            await event.wait()
            waited.set(.success(true))
        }

        let sawEscalation = await waitUntil { escalated.value != nil }
        XCTAssertTrue(sawEscalation, "the owner's priority was never escalated")
        XCTAssertEqual(try escalated.value?.get(), TaskPriority.userInitiated.rawValue)
        // Still parked: escalating the owner is not the same as the owner having posted.
        XCTAssertNil(waited.value)

        event.post()
        let released = await waitUntil { waited.value != nil }
        XCTAssertTrue(released)
    }

    // -------------------------------------------------------------------------------------
    // MARK: 5. The priority clamp, both halves
    // -------------------------------------------------------------------------------------

    /// The ceiling, unchanged, and the reason it is not optional: `basePriority` is a bare
    /// `UInt8` on the wire and `TaskPriority.init(rawValue:)` is not failable, so a peer can
    /// name a priority no Swift constant has and `Task(priority:)` aborts on it.
    func testTheRequestedPriorityIsClampedToUserInitiated() {
        XCTAssertEqual(Session.executionPriority(requested: TaskPriority(rawValue: 255)),
                       .userInitiated)
        XCTAssertEqual(Session.executionPriority(requested: .background), .background)
        XCTAssertEqual(Session.executionPriority(requested: .utility), .utility)
        XCTAssertNil(Session.executionPriority(requested: nil))
    }

    /// The **other** half, resolved this slice out of `handleReceivedRequest+0x13c0..0x1438`:
    /// a second, independent `min(Task.currentPriority, .userInitiated)` that Apple copies
    /// into the execution closure and applies with
    /// `withUnsafeCurrentTask { $0!.escalatePriority(to:) }`. It is a floor, and it is itself
    /// capped -- a delivering context above `.userInitiated` does not lift an inbound
    /// execution above `.userInitiated`.
    /// **Detached, and never awaited.** Two ways to accidentally measure the test's own
    /// priority instead of the one under test, both of which this hit before it worked:
    /// a child `Task(priority:)` is raised to its parent's, and `await task.value` escalates
    /// the task being awaited. The XCTest body runs at `.high`, so either mistake reports
    /// `25` for everything and the test passes for the wrong reason. Boxes and polling
    /// avoid both -- which is the same reason the rest of this file never awaits its subject.
    func testTheExecutionFloorIsTheCurrentPriorityClampedToUserInitiated() async {
        func floor(at priority: TaskPriority) async throws -> TaskPriority {
            let box = Outcome<TaskPriority>()
            Task.detached(priority: priority) {
                box.set(.success(Session.executionFloorPriority()))
            }
            let measured = await waitUntil { box.value != nil }
            XCTAssertTrue(measured, "the floor was never measured at \(priority)")
            return try XCTUnwrap(box.value).get()
        }

        await XCTAssertEqualAsync(try await floor(at: .background), .background)
        await XCTAssertEqualAsync(try await floor(at: .utility), .utility)
        // The cap. `0x21` is user-interactive and `.userInitiated` is `0x19`, so this is the
        // one pair that can tell a `min` from a `max`. Spelled by raw value because the
        // named constant is deprecated and this test is about the number, not the name.
        await XCTAssertEqualAsync(try await floor(at: TaskPriority(rawValue: 0x21)),
                                  .userInitiated)
    }

    /// `XCTAssertEqual`'s autoclosure cannot carry an `await`.
    private func XCTAssertEqualAsync<T: Equatable>(
        _ expression: @autoclosure () async throws -> T, _ expected: T,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            let actual = try await expression()
            XCTAssertEqual(actual, expected, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    /// End to end: a peer asks for `.background` and does not get it, because the floor of
    /// the context the request was delivered on is higher.
    ///
    /// The pipe is given an explicit `.userInitiated` QoS, and that is load-bearing rather
    /// than decorative: with the default `.unspecified`, Dispatch propagates the *sender's*
    /// QoS to the delivery block, so a caller at `.background` delivers at `.background`, the
    /// floor is `.background` too, and the escalation has nothing to lift. Measured: the
    /// first version of this test observed `9` against a floor of `9` and would have passed
    /// with the escalation deleted.
    func testAPeerAskingForBackgroundGetsTheDeliveringContextsFloorInstead() async throws {
        let link = try GatedLink(qos: .userInitiated)
        let callee = Calculator(actorSystem: link.serverSystem)
        let proxy = try link.proxy(Calculator.self, at: try link.export(callee.id))

        let box = Outcome<Int>()
        // Detached at `.background` so the request's own `basePriority` is `.background`.
        fire(box, priority: .background) { try await proxy.priorityRawValue() }
        let answered = await waitUntil { box.value != nil }
        XCTAssertTrue(answered)
        let observed = try XCTUnwrap(box.value).get()
        XCTAssertGreaterThan(observed, Int(TaskPriority.background.rawValue),
                             "the execution was not escalated to the delivering floor")
        XCTAssertLessThanOrEqual(observed, Int(TaskPriority.userInitiated.rawValue),
                                 "the execution ran above the ceiling")
        link.clientTransport.cancel(reason: "done")
    }

    /// Where the floor is applied depends on the OS, and both shapes carry the same value.
    /// On macOS 26+ the spawn priority is Apple's exactly -- the ceiling and nothing else --
    /// because the floor arrives as an escalation.
    func testTheSpawnPriorityCarriesTheFloorOnlyWhereEscalationIsUnavailable() {
        let clamped = Session.spawnPriority(requested: .background, floor: .userInitiated)
        let ambient = Session.spawnPriority(requested: nil, floor: .utility)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, *) {
            XCTAssertEqual(clamped, .background)
            XCTAssertNil(ambient)
        } else {
            XCTAssertEqual(clamped, .userInitiated)
            XCTAssertEqual(ambient, .utility)
        }
    }

    // -------------------------------------------------------------------------------------
    // MARK: 6. The overlay, for real
    // -------------------------------------------------------------------------------------

    /// **The bridge links, and it answers the way Apple's own code expects.**
    ///
    /// `XPCDictionary.auditToken`, `audit_token_t.isValid` and
    /// `audit_token_t.satisfies(requirement:)` are exported by `libswiftXPC` and declared in
    /// the SDK's `.tbd`, but none of the three is in the public `.swiftinterface`. This test
    /// is what stops that binding rotting silently.
    ///
    /// A dictionary that never crossed a connection reports an all-ones token whose
    /// `isValid` is `false` -- so `AuditTokenAttestation` refuses to be built from it, and
    /// the gate sees "no peer here" (`nil`) rather than "this peer is not entitled"
    /// (`false`). That distinction is the reason `PeerAttestation` is three-valued.
    func testTheOverlayBridgeResolvesAndRefusesADictionaryThatNeverCrossedAConnection() throws {
        #if os(macOS) || targetEnvironment(macCatalyst)
        guard #available(macOS 26, macCatalyst 26, *) else {
            throw XCTSkip("XPCPeerRequirement and the audit-token accessors are macOS 26+")
        }
        var dictionary = XPCDictionary()
        dictionary["hello"] = "world"
        let token = dictionary.xpcBridgedAuditToken()
        XCTAssertFalse(token.xpcBridgedIsValid())
        XCTAssertNil(AuditTokenAttestation(token))

        // The checker itself runs, and says no to an entitlement nothing here has.
        let requirement = XPCPeerRequirement.hasEntitlement("com.example.definitely-not-granted")
        XCTAssertFalse(token.xpcBridgedSatisfies(requirement: requirement))
        #else
        throw XCTSkip("the overlay's peer requirements are macOS-only")
        #endif
    }

    /// **A real token, a real checker, and the two answers that are not `true`.**
    ///
    /// The token is this process's own, fetched exactly as Apple's
    /// `Session.LocalSessionState.currentProcessAuditToken()` does it -- `task_info` with
    /// `TASK_AUDIT_TOKEN`. It is valid, so `AuditTokenAttestation` accepts it, and from there
    /// the two refusals a gate depends on are exercised against Apple's own code:
    ///
    /// - a requirement the checker **cannot express** (no `XPCPeerRequirement` inside)
    ///   answers `nil`, not `true`. Admitting on "I do not understand the question" is the
    ///   hole this is here to keep shut;
    /// - an entitlement this process does not have answers `false`.
    func testARealAuditTokenAnswersNilForTheInexpressibleAndFalseForTheUngranted() throws {
        #if os(macOS) || targetEnvironment(macCatalyst)
        guard #available(macOS 26, macCatalyst 26, *) else {
            throw XCTSkip("XPCPeerRequirement is macOS 26+")
        }
        let token = try XCTUnwrap(Self.currentProcessAuditToken(),
                                  "task_info(TASK_AUDIT_TOKEN) failed")
        XCTAssertTrue(token.xpcBridgedIsValid())
        let attestation = try XCTUnwrap(AuditTokenAttestation(token))

        XCTAssertNil(systemRequirement.xpcRequirement)
        XCTAssertNil(attestation.satisfies(systemRequirement),
                     "a requirement the checker cannot express must not read as satisfied")

        let overlay = PeerRequirement(.hasEntitlement("com.example.definitely-not-granted"),
                                      describedAs: "no such entitlement")
        XCTAssertNotNil(overlay.xpcRequirement)
        XCTAssertEqual(overlay.description, "no such entitlement")
        XCTAssertEqual(attestation.satisfies(overlay), false)
        #else
        throw XCTSkip("the overlay's peer requirements are macOS-only")
        #endif
    }

    /// Apple's `LocalSessionState.currentProcessAuditToken()`, which is `task_info` on the
    /// current task. The only source of a *valid* token a single-process test can have.
    private static func currentProcessAuditToken() -> audit_token_t? {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), rebound, &count)
            }
        }
        return status == KERN_SUCCESS ? token : nil
    }
}
