// Tests/XPCActorsTests/SessionTests.swift
import XCTest
import XPC
import CodableXPC
@testable import XPCActors

/// The real `SessionCoding` conformer, with no transport and no actor system.
///
/// `StubSession` stays where it is: it exists so `ActorID` can be tested against a
/// session that does nothing at all.
///
/// **What is deliberately not tested here, because it is deliberately not supported:**
/// sharing an actor into a session and getting the *same* `ActorID` back when the key
/// returns. That round trip cannot happen -- `ActorID.encode` refuses a `.remote` id,
/// so a peer can never send our key back to us -- and if it could, honouring it would
/// be wrong. Both sides' `dynamic` counters start at 1, so `.dynamic(1)` names a
/// different actor on each side and nothing on the wire tells them apart; a session
/// that consulted its own table first would resolve the *peer's* actor as its own, at
/// bytes of the peer's choosing. Apple does not support it either, and traps where we
/// throw. Read the absence of that test as the rule, not as an oversight.
@available(macOS 14, *)
final class SessionTests: XCTestCase {

    /// Stands in for a distributed actor. The registry stores `AnyObject`, so
    /// nothing here needs `Distributed`.
    private final class DummyActor {
        private let onDeinit: () -> Void
        init(onDeinit: @escaping () -> Void = {}) { self.onDeinit = onDeinit }
        deinit { onDeinit() }
    }

    /// A session and the actor table behind it. The table is the *system's* now: a
    /// session is vended by the system that owns it, so there is no longer a way to
    /// hand one a registry that belongs to somebody else. These tests are about the
    /// coding path and never look at `systemID`; the system is here because the
    /// session's table has to live somewhere.
    private func makeSession() -> (Session, ActorRegistry<InboundThunk>) {
        let system = XPCActorSystem("session-tests")
        return (system.makeDetachedSession(), system.registry)
    }

    private func register(_ instance: AnyObject, in registry: ActorRegistry<InboundThunk>) -> RawActorID.Local {
        let local = RawActorID.Local(systemID: ID64.next(), instanceID: ID64.next())
        registry.register(instance, id: local, thunk: XPCActorSystemTests.noThunk)
        return local
    }

    private func userInfo(_ session: Session) -> [CodingUserInfoKey: Any] {
        [.xpcActorSession: session]
    }

    // MARK: - The defect: a proxy is not sendable

    /// The rule that makes everything else sound. A `.remote` id names an actor in
    /// *another* key space; there is no honest way to write it into this one.
    ///
    /// Apple traps here. We throw, because this is reachable from a value shape a peer
    /// influenced, and crashing whichever process happens to be holding the proxy puts
    /// the diagnosis in the wrong place.
    func testAProxyRefusesToBeEncoded() throws {
        let (session, _) = makeSession()
        let proxy = session.remoteID(for: .dynamic(ID64(rawValue: 1)))
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(session)

        XCTAssertThrowsError(try encoder.encode(proxy)) { error in
            guard case EncodingError.invalidValue = error else {
                return XCTFail("expected EncodingError.invalidValue, got \(error)")
            }
        }
    }

    /// The same rule, in the shape that used to be a second, unnamed bug: a proxy
    /// obtained through one session must not be encodable into another, because that
    /// would put the first session's key into the second's namespace, where the same
    /// number means a different actor.
    func testAProxyFromOneSessionCannotBeEncodedIntoAnother() throws {
        let (first, _) = makeSession()
        let (second, _) = makeSession()
        let proxy = first.remoteID(for: .dynamic(ID64(rawValue: 1)))
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(second)

        XCTAssertThrowsError(try encoder.encode(proxy)) { error in
            guard case EncodingError.invalidValue = error else {
                return XCTFail("expected EncodingError.invalidValue, got \(error)")
            }
        }
    }

    /// A local id still encodes to nothing but its key, and a key still decodes to a
    /// proxy -- including one this very session minted. That last part is the point:
    /// `remoteID(for:)` is unconditional, and the encode-side refusal above is what
    /// makes it correct rather than lucky.
    func testALocalIDEncodesToItsKeyAndDecodesBackAsAProxy() throws {
        let (session, registry) = makeSession()
        let actor = DummyActor()
        let local = register(actor, in: registry)

        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(session)
        let object = try encoder.encode(ActorID(raw: .local(local)))

        // Nothing process-local is on the wire: this is the key and only the key.
        XCTAssertEqual(normalizedDescription(object), "[uint64(2),uint64(1)]")

        var decoder = XPCDecoder()
        decoder.userInfo = userInfo(session)
        let decoded = try decoder.decode(ActorID.self, from: object)

        guard case .remote(let remote) = decoded.raw else {
            return XCTFail("a decoded key is always a proxy, got \(decoded.raw)")
        }
        XCTAssertEqual(remote.key, .dynamic(ID64(rawValue: 1)))
        XCTAssertTrue(remote.session === session)
        XCTAssertNotEqual(decoded, ActorID(raw: .local(local)),
                          "identity across a share/return is deliberately not supported")
    }

    /// Keys are never interpreted against the local table, minted here or not.
    func testAKeyThisSessionDidNotMintStaysRemote() throws {
        let (session, registry) = makeSession()
        let actor = DummyActor()
        // Mint one key, so the table is non-empty and a miss is a real miss.
        _ = session.shareDynamically(register(actor, in: registry))

        for key: SharedActorKey in [.dynamic(ID64(rawValue: 9999)),
                                    .exportedRawValue("primary"),
                                    .exported(SwiftType(mangledTypeName: "$s4Peer5ThingC"))] {
            guard case .remote(let remote) = session.remoteID(for: key).raw else {
                XCTFail("\(key) is not ours and must decode as a proxy")
                continue
            }
            XCTAssertEqual(remote.key, key)
            XCTAssertTrue(remote.session === session)
        }
    }

    // MARK: - Sharing what is not there

    func testSharingAnIDThatWasNeverRegisteredReturnsNil() {
        let (session, _) = makeSession()
        let local = RawActorID.Local(systemID: ID64.next(), instanceID: ID64.next())
        XCTAssertNil(session.shareDynamically(local))
    }

    func testSharingAnActorThatHasGoneReturnsNil() {
        let (session, registry) = makeSession()
        var local: RawActorID.Local!
        do {
            let actor = DummyActor()
            local = register(actor, in: registry)
        }
        XCTAssertNil(session.shareDynamically(local))
    }

    /// `ActorID.encode` is written against exactly this contract: `nil` becomes an
    /// `EncodingError`, not a trap.
    func testEncodingAnUnregisteredIDThrowsRatherThanTrapping() {
        let (session, _) = makeSession()
        let local = RawActorID.Local(systemID: ID64.next(), instanceID: ID64.next())
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(session)

        XCTAssertThrowsError(try encoder.encode(ActorID(raw: .local(local)))) { error in
            guard case EncodingError.invalidValue = error else {
                return XCTFail("expected EncodingError.invalidValue, got \(error)")
            }
        }
    }

    // MARK: - Dedupe

    /// We dedupe; Apple does not. Pinned because it is a decision, not an accident.
    func testSharingTheSameActorTwiceMintsOneKey() throws {
        let (session, registry) = makeSession()
        let actor = DummyActor()
        let local = register(actor, in: registry)

        let first = try XCTUnwrap(session.shareDynamically(local))
        let second = try XCTUnwrap(session.shareDynamically(local))

        XCTAssertEqual(first, second)
        XCTAssertEqual(session.sharedActorCount, 1, "a second share must not grow the table")
        // The dedupe requirement in full: one key, and it is the one already issued,
        // so an actor the peer has already been told about keeps the name it was
        // given for the life of the session.
        XCTAssertEqual(first, .dynamic(ID64(rawValue: 1)))
    }

    func testTwoActorsGetTwoKeys() throws {
        let (session, registry) = makeSession()
        let a = DummyActor(), b = DummyActor()
        let localA = register(a, in: registry), localB = register(b, in: registry)

        let keyA = try XCTUnwrap(session.shareDynamically(localA))
        let keyB = try XCTUnwrap(session.shareDynamically(localB))

        XCTAssertEqual(keyA, .dynamic(ID64(rawValue: 1)))
        XCTAssertEqual(keyB, .dynamic(ID64(rawValue: 2)))
        XCTAssertNotEqual(keyA, keyB)
        XCTAssertEqual(session.sharedActorCount, 2)
    }

    /// Keys are minted from a per-session counter, not the process-global one, so a
    /// fresh session starts at 1 however much has happened elsewhere.
    func testDynamicKeysAreMintedPerSessionFromOne() throws {
        let (other, otherRegistry) = makeSession()
        let noise = DummyActor()
        _ = other.shareDynamically(register(noise, in: otherRegistry))

        let (session, registry) = makeSession()
        let actor = DummyActor()
        let key = try XCTUnwrap(session.shareDynamically(register(actor, in: registry)))
        XCTAssertEqual(key, .dynamic(ID64(rawValue: 1)))
    }

    // MARK: - The table holds its actors strongly

    /// The split `ActorRegistry` documents: the registry is weak, the wire-facing
    /// table is strong, because a peer holding a key must not find the actor gone.
    func testASharedActorOutlivesItsLastOtherReference() {
        let (session, registry) = makeSession()
        var deallocated = false
        var local: RawActorID.Local!
        do {
            let actor = DummyActor { deallocated = true }
            local = register(actor, in: registry)
            XCTAssertNotNil(session.shareDynamically(local))
        }

        XCTAssertFalse(deallocated, "the shared-actor table must hold the actor strongly")
        XCTAssertNotNil(registry.lookup(local), "and so keep the weak registry entry alive")

        session.cancellationCompleted()
        XCTAssertTrue(deallocated, "and must release it when the session is cancelled")
    }

    // MARK: - Cancellation

    func testCancellationEmptiesTheTableAndStopsExporting() throws {
        let (session, registry) = makeSession()
        let actor = DummyActor()
        let local = register(actor, in: registry)
        let key = try XCTUnwrap(session.shareDynamically(local))

        session.cancellationCompleted()

        XCTAssertEqual(session.sharedActorCount, 0)
        XCTAssertNil(session.shareDynamically(local),
                     "a cancelled session must not keep exporting actors")
        // And the clear is not a pause: re-sharing after cancellation would otherwise
        // hand the peer key 2 for an actor it knows as key 1.
        XCTAssertEqual(session.sharedActorCount, 0)
        XCTAssertEqual(key, .dynamic(ID64(rawValue: 1)))
    }

    // MARK: - Concurrency

    /// The table is touched from the coder on whatever queue a decode happens on.
    /// An unsynchronised dictionary loses entries or crashes here.
    func testConcurrentSharingIsSafeAndMintsDenseUniqueKeys() {
        let iterations = 500
        let (session, registry) = makeSession()
        var actors: [DummyActor] = []
        var locals: [RawActorID.Local] = []
        for _ in 0..<iterations {
            let actor = DummyActor()
            actors.append(actor)
            locals.append(register(actor, in: registry))
        }

        let collected = Collector()
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            if let key = session.shareDynamically(locals[index]) { collected.add(key) }
        }

        let keys = collected.keys
        XCTAssertEqual(keys.count, iterations)
        XCTAssertEqual(session.sharedActorCount, iterations)
        XCTAssertEqual(Set(keys).count, iterations, "every share must get its own key")

        // Monotonic and dense from 1: the counter is not merely unique, it never
        // skips, which a compare-and-retry that dropped a value would.
        let numbers = keys.compactMap { key -> UInt64? in
            guard case .dynamic(let id) = key else { return nil }
            return id.rawValue
        }
        XCTAssertEqual(numbers.sorted(), Array(1...UInt64(iterations)))
        XCTAssertEqual(actors.count, iterations)  // keep them alive to here
    }

    /// The dedupe path itself, raced. Every share in the test above is of a *distinct*
    /// actor, so the `keyForLocal` hit is never contended there; here N threads share
    /// one actor and must between them mint exactly one key. A check-then-insert
    /// outside the lock issues two.
    func testConcurrentlySharingOneActorMintsExactlyOneKey() {
        let iterations = 500
        let (session, registry) = makeSession()
        let actor = DummyActor()
        let local = register(actor, in: registry)

        let collected = Collector()
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            if let key = session.shareDynamically(local) { collected.add(key) }
        }

        let keys = collected.keys
        XCTAssertEqual(keys.count, iterations, "every caller gets an answer")
        XCTAssertEqual(Set(keys), [.dynamic(ID64(rawValue: 1))], "and it is the same answer")
        XCTAssertEqual(session.sharedActorCount, 1)
    }

    /// Reading the table while it is being written is the decode path's own shape.
    /// The reader's answer is a proxy either way -- what is under test is that reading
    /// during a write neither crashes nor returns something torn.
    func testConcurrentSharingAndResolvingAgree() throws {
        let iterations = 200
        let (session, registry) = makeSession()
        let settled = DummyActor()
        let settledKey = try XCTUnwrap(session.shareDynamically(register(settled, in: registry)))

        var actors: [DummyActor] = []
        var locals: [RawActorID.Local] = []
        for _ in 0..<iterations {
            let actor = DummyActor()
            actors.append(actor)
            locals.append(register(actor, in: registry))
        }

        DispatchQueue.concurrentPerform(iterations: iterations * 2) { index in
            if index % 2 == 0 {
                _ = session.shareDynamically(locals[index / 2])
            } else {
                guard case .remote(let remote) = session.remoteID(for: settledKey).raw else {
                    return XCTFail("a key always decodes as a proxy")
                }
                XCTAssertEqual(remote.key, settledKey)
                XCTAssertTrue(remote.session === session)
            }
        }
        XCTAssertEqual(actors.count, iterations)
    }

    /// Somewhere to put keys from many threads that is not the thing under test.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SharedActorKey] = []
        func add(_ key: SharedActorKey) { lock.withLock { storage.append(key) } }
        var keys: [SharedActorKey] { lock.withLock { storage } }
    }
}
