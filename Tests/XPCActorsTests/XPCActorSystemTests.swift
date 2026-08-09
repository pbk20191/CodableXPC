// Tests/XPCActorsTests/XPCActorSystemTests.swift
import XCTest
import Distributed
@testable import XPCActors

/// The identity half of `DistributedActorSystem`, plus what is left knowingly stubbed --
/// which is now only the inbound trio: `invokeHandlerOnReturn`, `InvocationDecoder` and
/// `ResultHandler`. The outbound path is real, and is tested in
/// `OutboundInvocationTests`.
///
/// Read the *shape* of the resolve tests as the point: `resolve` has three outcomes and
/// they are not interchangeable. A `.local` id that is not in the table **throws** --
/// returning `nil` there would tell the Swift runtime to synthesise a proxy for an actor
/// that lives in this process, which is a different and much worse thing than a lookup
/// failure. `nil` means exactly one thing: "this id names a peer's actor reached through
/// a session of mine, make me a proxy."
@available(macOS 14, *)
final class XPCActorSystemTests: XCTestCase {

    /// A distributed actor with nothing in it. Everything under test is the system's
    /// side of the lifecycle, so the actor needs no members at all.
    distributed actor Probe {
        typealias ActorSystem = XPCActorSystem
        init(actorSystem: ActorSystem) { self.actorSystem = actorSystem }
    }

    private struct TestError: Error {}

    private func local(_ id: ActorID) throws -> RawActorID.Local {
        guard case .local(let local) = id.raw else {
            throw XCTSkip("expected a .local id, got \(id.raw)")
        }
        return local
    }

    // MARK: - assignID

    /// Two things at once, because they are the same fact: the id is `.local`, and its
    /// `systemID` is *this* system's id rather than anything freshly minted.
    func testAssignIDMintsALocalIDCarryingThisSystemsID() throws {
        let system = XPCActorSystem("assign")
        let a = system.assignID(Probe.self)
        let b = system.assignID(Probe.self)

        let localA = try local(a)
        let localB = try local(b)
        XCTAssertEqual(localA.systemID, system.id)
        XCTAssertEqual(localB.systemID, system.id)
        XCTAssertNotEqual(localA.instanceID, localB.instanceID)
        XCTAssertNotEqual(a, b)
    }

    /// **The ids come from `ID64.next()`, not from a counter of the system's own.**
    ///
    /// Bracketing is the whole test: a value drawn from the process-global generator
    /// before the assignment must be below it, and one drawn after must be above it. A
    /// per-system counter would fail the lower bound almost immediately, and a random or
    /// pid-derived id would fail both.
    ///
    /// This is not cosmetic. `Session`'s dedupe rests on `RawActorID.Local` never being
    /// recycled, and that rests on this generator being the monotonic process-global one.
    func testAssignIDDrawsInstanceIDsFromTheProcessGlobalGenerator() throws {
        let system = XPCActorSystem("global")
        let before = ID64.next()
        let assigned = try local(system.assignID(Probe.self)).instanceID
        let after = ID64.next()

        XCTAssertLessThan(before.rawValue, assigned.rawValue)
        XCTAssertLessThan(assigned.rawValue, after.rawValue)
    }

    /// Monotonic, and monotonic across two systems -- one counter, not one per system.
    func testAssignIDIsMonotonicAcrossSystems() throws {
        let one = XPCActorSystem("one")
        let two = XPCActorSystem("two")
        var last: UInt64 = 0
        for system in [one, two, one, two, one] {
            let next = try local(system.assignID(Probe.self)).instanceID.rawValue
            XCTAssertGreaterThan(next, last)
            last = next
        }
    }

    /// The ledger has carried "`ID64` is tested single-threaded only" as a gap since the
    /// counter went in. Closing it here, where it matters: if two actors could ever be
    /// assigned the same `instanceID`, one would silently displace the other in the
    /// registry and a shared-actor key could come to mean a different actor than the one
    /// it was minted for.
    func testAssignIDNeverRepeatsUnderConcurrency() {
        let system = XPCActorSystem("concurrent")
        let iterations = 500
        let lock = NSLock()
        var minted: [ID64] = []
        minted.reserveCapacity(iterations)

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let id = system.assignID(Probe.self)
            guard case .local(let local) = id.raw else {
                XCTFail("assignID must mint a .local id")
                return
            }
            lock.withLock { minted.append(local.instanceID) }
        }

        XCTAssertEqual(minted.count, iterations)
        XCTAssertEqual(Set(minted).count, iterations, "assignID handed out a duplicate instanceID")
    }

    // MARK: - actorReady / resignID / resolve

    func testAnActorThatIsReadyResolvesToItself() throws {
        let system = XPCActorSystem("ready")
        let probe = Probe(actorSystem: system)
        let resolved = try system.resolve(id: probe.id, as: Probe.self)
        XCTAssertTrue(resolved === probe)
    }

    /// **Pinned: a resigned id throws, it does not return `nil`.**
    ///
    /// Apple's private `resolve(id:as:)` is non-optional and throws `SetupError` with
    /// `"Could not resolve actor ID <id> as <Type>"`; only the `.remote`-belonging-to-us
    /// branch of the public `resolve` produces `nil`. Returning `nil` here would ask the
    /// runtime to build a proxy for a local id, which has no session to talk over.
    func testAResignedIDThrowsRatherThanAskingForAProxy() throws {
        let system = XPCActorSystem("resign")
        let probe = Probe(actorSystem: system)
        let id = probe.id
        system.resignID(id)

        XCTAssertThrowsError(try system.resolve(id: id, as: Probe.self)) { error in
            guard let setup = error as? SetupError else { return XCTFail("expected SetupError, got \(error)") }
            XCTAssertTrue(setup.message.hasPrefix("Could not resolve actor ID"), setup.message)
        }
        withExtendedLifetime(probe) {}
    }

    /// An id this system never assigned is a lookup failure like any other.
    func testAnIDFromAnotherSystemDoesNotResolveLocally() throws {
        let system = XPCActorSystem("mine")
        let other = XPCActorSystem("theirs")
        let strangerID = other.assignID(Probe.self)
        XCTAssertThrowsError(try system.resolve(id: strangerID, as: Probe.self))
    }

    /// The type is checked, not assumed: the id resolves, the cast does not.
    func testResolvingAsTheWrongTypeThrows() throws {
        let system = XPCActorSystem("wrongtype")
        let probe = Probe(actorSystem: system)
        XCTAssertThrowsError(try system.resolve(id: probe.id, as: OtherProbe.self)) { error in
            guard let setup = error as? SetupError else { return XCTFail("expected SetupError, got \(error)") }
            XCTAssertTrue(setup.message.contains("OtherProbe"), setup.message)
        }
        withExtendedLifetime(probe) {}
    }

    // MARK: - resolve: the remote branches

    func testARemoteIDFromOneOfOurOwnSessionsAsksForAProxy() throws {
        let system = XPCActorSystem("proxy")
        let session = system.makeDetachedSession()
        let id = session.remoteID(for: .dynamic(ID64(rawValue: 1)))

        XCTAssertNil(try system.resolve(id: id, as: Probe.self))
    }

    /// The check that stops an id minted against one system from resolving in another.
    /// Apple's message, verbatim.
    func testARemoteIDFromAnotherSystemsSessionThrows() throws {
        let system = XPCActorSystem("mine")
        let other = XPCActorSystem("theirs")
        let theirSession = other.makeDetachedSession()
        let id = theirSession.remoteID(for: .dynamic(ID64(rawValue: 1)))

        XCTAssertThrowsError(try system.resolve(id: id, as: Probe.self)) { error in
            guard let setup = error as? SetupError else { return XCTFail("expected SetupError, got \(error)") }
            XCTAssertEqual(setup.message, "Remote actor does not belong to the actor system.")
        }
    }

    /// **The trap in `resignID` is unreachable, checked rather than argued.**
    ///
    /// `resignID` and `actorReady` `preconditionFailure` on a `.remote` id, which is only
    /// defensible if the runtime never hands them one. It does not: the synthesised
    /// `deinit` of a distributed actor resigns its id *conditionally*, skipping it for a
    /// proxy. This test builds a real proxy through `DistributedActor.resolve(id:using:)`
    /// -- the only path that reaches our `nil` branch -- and drops it. If the guard were
    /// wrong the process would die here rather than a test failing, which is exactly why
    /// it is worth a test.
    func testAProxyIsBornAndDiesWithoutReachingTheResignTrap() throws {
        let system = XPCActorSystem("proxy")
        let session = system.makeDetachedSession()
        let id = session.remoteID(for: .dynamic(ID64(rawValue: 1)))

        do {
            let proxy = try Probe.resolve(id: id, using: system)
            XCTAssertEqual(proxy.id, id)
            XCTAssertEqual(system.registry.count, 0, "a proxy must not enter the actor table")
        }
    }

    /// A session that is nobody's -- the `StubSession` the identity tests use -- is *not*
    /// ours either. The branch is total: it does not depend on the session being one of
    /// our own `Session` objects.
    func testARemoteIDFromAForeignSessionConformerThrows() throws {
        let system = XPCActorSystem("mine")
        let stub = StubSession()
        let id = stub.remoteID(for: .dynamic(ID64(rawValue: 1)))
        XCTAssertThrowsError(try system.resolve(id: id, as: Probe.self))
    }

    // MARK: - the registry is weak

    /// An actor that goes away is not resolvable, and the dead slot does not survive the
    /// lookup that found it. Registered by hand rather than through a real actor so that
    /// **weakness** is what is being observed and not `resignID` running in `deinit`.
    func testAnActorThatWentAwayIsNotResolvableAndLeavesNoDeadEntry() throws {
        let system = XPCActorSystem("weak")
        let id = system.assignID(Probe.self)
        let localID = try local(id)

        do {
            let doomed = NSObject()
            system.registry.register(doomed, id: localID, thunk: ())
            XCTAssertEqual(system.registry.count, 1)
        }

        XCTAssertThrowsError(try system.resolve(id: id, as: Probe.self))
        XCTAssertEqual(system.registry.count, 0, "a dead entry survived the lookup that found it")
    }

    /// The same thing through the real lifecycle: a distributed actor's `deinit` resigns
    /// its own id, so nothing accumulates either way.
    func testADeallocatedActorLeavesTheTableEmpty() throws {
        let system = XPCActorSystem("lifecycle")
        var id: ActorID?
        do {
            let probe = Probe(actorSystem: system)
            id = probe.id
            XCTAssertEqual(system.registry.count, 1)
        }
        XCTAssertEqual(system.registry.count, 0)
        XCTAssertThrowsError(try system.resolve(id: XCTUnwrap(id), as: Probe.self))
    }

    // MARK: - inbound resolution goes through the session, not the registry

    /// **The behaviour we chose, pinned.** An actor a session exported stays reachable
    /// through that session after it has been resigned from the registry, because the
    /// session holds it strongly and the registry does not. Resolving inbound targets
    /// through the registry instead would make it unreachable while our own session is
    /// still keeping it alive -- paying for the strong hold and not getting it.
    func testASharedActorResolvesThroughItsSessionAfterBeingResigned() throws {
        let system = XPCActorSystem("shared")
        let session = system.makeDetachedSession()
        let probe = Probe(actorSystem: system)
        let localID = try local(probe.id)

        let key = try XCTUnwrap(session.shareDynamically(localID))
        system.resignID(probe.id)

        XCTAssertThrowsError(try system.resolve(id: probe.id, as: Probe.self),
                             "the registry must have dropped it")
        XCTAssertTrue(session.resolveSharedActor(at: key) === probe,
                      "the session must still name it")
        withExtendedLifetime(probe) {}
    }

    /// A key the session never minted names nothing, rather than something.
    func testResolveSharedActorReturnsNilForAKeyItNeverMinted() {
        let system = XPCActorSystem("shared")
        let session = system.makeDetachedSession()
        XCTAssertNil(session.resolveSharedActor(at: .dynamic(ID64(rawValue: 7))))
        XCTAssertNil(session.resolveSharedActor(at: .exportedRawValue("nope")))
    }

    // MARK: - the call requirements refuse a local actor

    // These two used to assert that `remoteCall` and `remoteCallVoid` were stubs, by
    // passing a **local** actor -- which is the one argument for which they would have
    // thrown anyway. They pinned the stub, not the path. They now pin the refusal that
    // was always the real answer for a local actor, and the path itself is covered in
    // `OutboundInvocationTests`, over a transport, against bytes a peer wrote.

    func testRemoteCallOnALocalActorThrowsApplesMessage() async throws {
        let system = XPCActorSystem("local")
        let probe = Probe(actorSystem: system)
        var encoder = system.makeInvocationEncoder()
        do {
            let value: Int = try await system.remoteCall(
                on: probe,
                target: RemoteCallTarget("stub"),
                invocation: &encoder,
                throwing: TestError.self,
                returning: Int.self)
            XCTFail("remoteCall returned \(value) instead of throwing")
        } catch {
            XCTAssertEqual(error.reason, .executionFailed)
            XCTAssertTrue(error.message.contains("Remote call on a local actor."), error.message)
        }
    }

    func testRemoteCallVoidOnALocalActorThrowsApplesMessage() async throws {
        let system = XPCActorSystem("local")
        let probe = Probe(actorSystem: system)
        var encoder = system.makeInvocationEncoder()
        do {
            try await system.remoteCallVoid(
                on: probe,
                target: RemoteCallTarget("stub"),
                invocation: &encoder,
                throwing: TestError.self)
            XCTFail("remoteCallVoid returned instead of throwing")
        } catch {
            XCTAssertTrue("\(error)".contains("Remote call on a local actor."), "\(error)")
        }
    }

    // MARK: - the stubs that are left, all inbound

    func testInvokeHandlerOnReturnThrows() async throws {
        let system = XPCActorSystem("stub")
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<Int>.size, alignment: MemoryLayout<Int>.alignment)
        defer { buffer.deallocate() }
        buffer.storeBytes(of: 42, as: Int.self)
        do {
            try await system.invokeHandlerOnReturn(
                handler: ResultHandler(),
                resultBuffer: UnsafeRawPointer(buffer),
                metatype: Int.self)
            XCTFail("invokeHandlerOnReturn returned instead of throwing")
        } catch {
            XCTAssertTrue("\(error)".contains("not wired"), "\(error)")
        }
    }

    func testTheInvocationDecoderAndResultHandlerAreStubsToo() async throws {
        var decoder = InvocationDecoder()
        XCTAssertThrowsError(try decoder.decodeGenericSubstitutions())
        XCTAssertThrowsError(try decoder.decodeErrorType())
        XCTAssertThrowsError(try decoder.decodeReturnType())
        XCTAssertThrowsError(try decoder.decodeNextArgument() as Int)

        let handler = ResultHandler()
        do {
            try await handler.onReturnVoid()
            XCTFail("onReturnVoid returned instead of throwing")
        } catch {
            XCTAssertTrue("\(error)".contains("not wired"), "\(error)")
        }
    }

    func testMakeInvocationEncoderReturnsAFreshEncoder() {
        let system = XPCActorSystem("encoder")
        let encoder = system.makeInvocationEncoder()
        XCTAssertTrue(encoder.arguments.isEmpty)
        XCTAssertNil(encoder.returnType)
        XCTAssertNil(encoder.errorType)
        XCTAssertNil(encoder.protocolStub)
        XCTAssertTrue(encoder.genericSubsitutions.isEmpty)
    }
}

/// A second actor type, so the failing cast in `resolve` has something to fail against.
@available(macOS 14, *)
distributed actor OtherProbe {
    typealias ActorSystem = XPCActorSystem
    init(actorSystem: ActorSystem) { self.actorSystem = actorSystem }
}
