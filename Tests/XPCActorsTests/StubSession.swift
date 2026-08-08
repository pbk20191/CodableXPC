@testable import XPCActors

/// Enough of a session for an `ActorID` to code itself against.
///
/// One copy, because there were three and they differed only in how they counted:
/// `ActorIDTests` had a `nextDynamic` counter and a `refuseToShare` switch,
/// `InvocationBodiesTests` derived the key from `shared.count`, and `PacketBodyTests`
/// returned a constant. All three are the same object with different amounts of it
/// exercised, so this is the union and each caller uses the part it needs.
///
/// `@unchecked Sendable` because `SessionCoding` requires `Sendable` and this has mutable
/// state. Tests drive it from one thread; a stub that locked would be pretending to a
/// property nothing here depends on.
@available(macOS 14, *)
final class StubSession: SessionCoding, @unchecked Sendable {

    /// Every actor handed to ``shareDynamically(_:)``, in order.
    var shared: [RawActorID.Local] = []
    /// The next `dynamic` key to mint. Monotonic, so a test can tell one share from
    /// the next rather than only that sharing happened.
    var nextDynamic: UInt64 = 1
    /// Make sharing fail, which is the case where an actor was deallocated or never
    /// became ready. `remoteID(for:)` is unaffected.
    var refuseToShare = false

    /// A system id nobody else has. This stub belongs to no `XPCActorSystem`, and
    /// `ID64.next()` is never recycled, so a proxy reached through it is refused by
    /// every real system -- which is the honest answer and is what
    /// `XPCActorSystemTests.testARemoteIDFromAForeignSessionConformerThrows` pins.
    let systemID = ID64.next()

    func shareDynamically(_ local: RawActorID.Local) -> SharedActorKey? {
        guard !refuseToShare else { return nil }
        shared.append(local)
        defer { nextDynamic += 1 }
        return .dynamic(ID64(rawValue: nextDynamic))
    }

    func remoteID(for key: SharedActorKey) -> ActorID {
        ActorID(raw: .remote(.init(session: self, key: key)))
    }
}
