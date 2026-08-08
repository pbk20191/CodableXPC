import XCTest
@testable import XPCActors

private final class Dummy {}

@available(macOS 14, *)
final class ActorRegistryTests: XCTestCase {

    private func makeLocal() -> RawActorID.Local {
        RawActorID.Local(systemID: ID64.next(), instanceID: ID64.next())
    }

    func testAnEntryIsFoundAfterRegistering() {
        let registry = ActorRegistry<Int>()
        let object = Dummy()
        let id = makeLocal()
        registry.register(object, id: id, thunk: 42)

        let hit = registry.lookup(id)
        XCTAssertTrue(hit?.instance === object)
        XCTAssertEqual(hit?.thunk, 42)
    }

    func testResignRemovesTheEntry() {
        let registry = ActorRegistry<Int>()
        let object = Dummy()
        let id = makeLocal()
        registry.register(object, id: id, thunk: 1)
        registry.resign(id)
        XCTAssertNil(registry.lookup(id))
        XCTAssertEqual(registry.count, 0)
    }

    /// The registry must never extend an actor's lifetime. This is the whole reason
    /// it holds weak references, and the reason `resignID` is not the only way out.
    func testTheRegistryDoesNotKeepTheActorAlive() {
        let registry = ActorRegistry<Int>()
        let id = makeLocal()
        do {
            let object = Dummy()
            registry.register(object, id: id, thunk: 1)
            XCTAssertNotNil(registry.lookup(id))
        }
        XCTAssertNil(registry.lookup(id), "a deallocated actor must not be reachable")
    }

    /// A dead entry is not merely invisible, it is reclaimed -- otherwise a long-lived
    /// system accumulates one dictionary slot per actor that ever existed.
    func testADeadEntryIsReclaimedOnLookup() {
        let registry = ActorRegistry<Int>()
        let id = makeLocal()
        do {
            let object = Dummy()
            registry.register(object, id: id, thunk: 1)
        }
        _ = registry.lookup(id)
        XCTAssertEqual(registry.count, 0)
    }

    func testDistinctIDsDoNotCollide() {
        let registry = ActorRegistry<Int>()
        let a = Dummy(), b = Dummy()
        let idA = makeLocal(), idB = makeLocal()
        registry.register(a, id: idA, thunk: 1)
        registry.register(b, id: idB, thunk: 2)
        XCTAssertTrue(registry.lookup(idA)?.instance === a)
        XCTAssertTrue(registry.lookup(idB)?.instance === b)
        XCTAssertEqual(registry.count, 2)
    }
}
