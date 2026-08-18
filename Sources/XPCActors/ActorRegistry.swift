import Synchronization

/// The system's table of actors living in this process.
///
/// **Weak on purpose.** A distributed actor's lifetime belongs to whoever created it;
/// a registry that held it strongly would keep every actor that was ever ready alive
/// for the life of the process. The wire-facing table on `Session` is the strong one,
/// because a peer holding a key must not find the actor gone.
///
/// Generic over `Thunk` so this file depends on nothing: the thunk's real type
/// mentions `InvocationDecoder`, `ResultHandler`, and the system itself, none of
/// which identity or registration has any business knowing about.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class ActorRegistry<Thunk>: @unchecked Sendable {

    private struct Entry {
        weak var instance: AnyObject?
        let thunk: Thunk
    }

    /// Apple's `actorTable: Mutex<[RawActorID.Local: WeakActorRef]>` -- the same
    /// `Synchronization.Mutex` over the weak-entry table, now that the floor is macOS 26.
    private let entries = Mutex<[RawActorID.Local: Entry]>([:])

    var count: Int { entries.withLock { $0.count } }

    func register(_ instance: AnyObject, id: RawActorID.Local, thunk: Thunk) {
        entries.withLock { $0[id] = Entry(instance: instance, thunk: thunk) }
    }

    func resign(_ id: RawActorID.Local) {
        entries.withLock { _ = $0.removeValue(forKey: id) }
    }

    /// Look up a live actor. A slot whose actor has gone is removed as it is found,
    /// so the table does not accumulate one dead entry per actor ever created.
    func lookup(_ id: RawActorID.Local) -> (instance: AnyObject, thunk: Thunk)? {
        entries.withLock { entries in
            guard let entry = entries[id] else { return nil }
            guard let instance = entry.instance else {
                entries.removeValue(forKey: id)
                return nil
            }
            return (instance, entry.thunk)
        }
    }
}
