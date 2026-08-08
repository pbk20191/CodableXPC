// Sources/XPCActors/Session.swift
import Foundation

/// One conversation with one peer, and the table of actors we have exported into it.
///
/// This is the first slice of the session layer: the `SessionCoding` conformer that an
/// `ActorID` codes itself against, plus the shared-actor table behind it. The transport,
/// the invocation paths, cancellation events and the `DistributedActorSystem`
/// conformance are not here.
///
/// Generic over `Thunk` for the same reason `ActorRegistry` is: the thunk's real type
/// mentions the invocation machinery, which does not exist yet and which sharing has no
/// business knowing about. The parameter is a placeholder that collapses when
/// `XPCActorSystem` lands and hands the session a system instead of a registry.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class Session<Thunk>: SessionCoding, @unchecked Sendable {

    /// From the process-global counter, like Apple's `Session.id` -- the same generator
    /// that mints system and instance ids, and deliberately *not* the per-session one
    /// that mints `dynamic` keys below. Never transmitted; it exists so one session can
    /// be told from another in a log.
    let id = ID64.next()

    /// The system this session belongs to, by id.
    ///
    /// Apple's `Session` stores the `XPCSystem` itself (`+0x10`, a `let`, and the first
    /// field), and `resolve` compares that pointer. We store its id instead -- see
    /// ``SessionCoding/systemID`` for why, and for why this becomes `system.id` once the
    /// session is handed a system rather than a registry.
    ///
    /// Nothing about the wire depends on it: it is never transmitted, and it exists so a
    /// `.remote` id can be refused by a system that does not own the session it names.
    let systemID: ID64

    /// Where a local id is turned into the instance behind it. Held strongly: the
    /// registry's entries are weak, so nothing else keeps it alive.
    private let registry: ActorRegistry<Thunk>

    /// What we know about an actor we have exported.
    ///
    /// Apple's table is `[SharedActorKey: any DistributedActor]` and stores no id, so
    /// mapping a key back to an actor id costs a runtime dance through the
    /// associated-type and associated-conformance witnesses (see `TestHook`
    /// `mapToLocalActorID` in the interop document). We do not need any of that: our
    /// `shareDynamically` is *handed* the `RawActorID.Local`, so the answer can simply
    /// be written down at minting time, when it is already in hand. An earlier note of
    /// ours claimed this required storing an `ActorID` beside the instance and that the
    /// id was otherwise unreachable; both halves of that were wrong, and the reason we
    /// keep the id here is convenience, not necessity.
    private struct SharedActor {
        /// Recorded when the key is minted. This is what makes `remoteID(for:)` a
        /// dictionary lookup rather than a reflection problem.
        let local: RawActorID.Local
        /// **Strong, on purpose**, and the one place in this module that is.
        /// `ActorRegistry` holds actors weakly because an actor's lifetime belongs to
        /// whoever created it; the wire-facing table holds them strongly because a peer
        /// holding a key must not find the actor gone. Released wholesale by
        /// ``cancellationCompleted()``.
        let instance: AnyObject
    }

    /// One lock over the whole of the mutable state, taken by both directions of the
    /// table and by the key counter. Apple uses a `Mutex` around `sharedActors` alone
    /// and a separate atomic `ID64.Generator`; folding the counter under the same lock
    /// costs nothing here -- every mint already takes the lock -- and makes "the key is
    /// unique *and* the table records it" a single critical section rather than two.
    ///
    /// `NSLock` rather than `Synchronization.Mutex` to keep the deployment floor where
    /// the rest of the module puts it, and to match `ActorRegistry`.
    private let lock = NSLock()

    /// key -> actor. The direction the decode path reads, so it is a direct lookup.
    private var byKey: [SharedActorKey: SharedActor] = [:]

    /// actor -> key. Apple has no such map -- which is exactly why Apple cannot dedupe.
    /// See ``shareDynamically(_:)``.
    private var keyForLocal: [RawActorID.Local: SharedActorKey] = [:]

    /// The per-session `dynamic` counter, Apple's `Session.idGenerator`. Ids run from 1
    /// and an overflow traps, which `+= 1` on a `UInt64` gives us for free.
    private var lastDynamicKey: UInt64 = 0

    private var isCancelled = false

    init(registry: ActorRegistry<Thunk>, systemID: ID64) {
        self.registry = registry
        self.systemID = systemID
    }

    /// How many actors this session currently exports.
    var sharedActorCount: Int { lock.withLock { byKey.count } }

    // MARK: - SessionCoding

    /// Export a local actor to the peer and name it.
    ///
    /// `nil` when the actor is not registered -- never became ready, was resigned, or
    /// has been deallocated -- and also once the session is cancelled, because a
    /// cancelled session must not keep exporting actors into a table it has just
    /// cleared. `ActorID.encode` turns the `nil` into an `EncodingError` rather than
    /// trapping, so a stale reference in an argument fails that one call.
    ///
    /// **We dedupe; Apple does not.** `Session.(addSharedActor)` in the shipping binary
    /// does no lookup before minting, so sharing the same actor twice yields two keys
    /// mapping to one instance -- resolved from the disassembly, not assumed, and it is
    /// forced on Apple by the missing reverse map rather than chosen. Minting is
    /// entirely ours (a peer only ever echoes keys back, and a key is the same bytes on
    /// the wire either way), so this is a design decision and not a fidelity question,
    /// and we take the other side of it for two reasons:
    ///
    /// - A key space that grows with *how often* a peer happens to receive an actor,
    ///   rather than with how many actors it can reach, is a leak. Every mint pins the
    ///   instance strongly until cancellation, so the entries are not cheap.
    /// - A stable key per actor makes a trace readable: the same actor is the same
    ///   name for the life of the session.
    ///
    /// Reuse is safe because `RawActorID.Local` is never recycled -- its `instanceID`
    /// comes from a monotonic process-global counter -- so a key can never come to mean
    /// a different actor than the one it was minted for.
    ///
    /// **Apple's `isBidirectional` guard is deliberately absent**, not overlooked:
    /// `Session.(addSharedActor)` asserts it (`"API violation: Session must be
    /// bidirectional to share actor references"`), but the flag is written at init from
    /// `InitializationOptions.bidirectional`, and neither the options nor the
    /// initialisers that set them exist yet. A flag with one settable value is a
    /// guard that tests nothing; it goes in with the initialisers.
    func shareDynamically(_ local: RawActorID.Local) -> SharedActorKey? {
        // Outside our lock, deliberately: `lookup` takes the registry's own lock, and
        // taking two locks in one critical section is how lock orders get invented by
        // accident. Nothing between here and the insert can invalidate the answer that
        // matters -- we are about to hold the instance strongly ourselves.
        guard let entry = registry.lookup(local) else { return nil }
        return lock.withLock {
            guard !isCancelled else { return nil }
            if let existing = keyForLocal[local] { return existing }
            lastDynamicKey += 1
            let key = SharedActorKey.dynamic(ID64(rawValue: lastDynamicKey))
            byKey[key] = SharedActor(local: local, instance: entry.instance)
            keyForLocal[local] = key
            return key
        }
    }

    /// Turn a key the peer sent us into the id we use for the actor it names.
    ///
    /// Unconditionally a proxy, exactly as Apple's `ActorID.init(from:)` does it, and
    /// **the local table is deliberately not consulted.** That is correct by
    /// construction rather than by luck, and the construction is
    /// ``ActorID/encode(to:)`` refusing to encode a `.remote` id: a proxy is never
    /// sendable, so a key can only ever travel from the side that minted it to the
    /// side that did not. Every key arriving here was minted by the peer, and
    /// interpreting it in the peer's key space -- which is what a proxy through this
    /// session *is* -- is the only reading available.
    ///
    /// **Do not "improve" this by looking the key up in `byKey` first.** It is the
    /// obvious repair for "an actor that shares itself and gets its own key back
    /// decodes as a proxy pointing at itself", and it is worse than what it fixes:
    ///
    /// - `dynamic` keys come from a *per-session* generator that both ends zero at
    ///   init, so both ends mint `.dynamic(1)` first. The two key spaces are
    ///   numerically identical and nothing on the wire distinguishes them.
    /// - So the moment both sides have shared one actor, a peer sending us its
    ///   `.dynamic(1)` would hit *our* `.dynamic(1)` and resolve **the peer's actor as
    ///   one of ours** -- silently, and under the peer's control, since the peer
    ///   chooses the bytes.
    /// - The invariant that keeps this sound is that a key is only ever interpreted in
    ///   the map of the side that minted it. Consulting the table breaks exactly that.
    ///
    /// The reflect-back case that motivated the lookup cannot occur at all once encode
    /// refuses proxies, which is why the fix belongs on the encode side. That also
    /// explains `TestHook.mapToLocalActorID`'s zero callers in Apple's binary: it is
    /// unnecessary under this protocol, not forgotten.
    ///
    /// `byKey` is still load-bearing -- it is what dedupes a re-share, what holds
    /// exported actors alive, and what the inbound execution path will look an actor up
    /// in. It is simply not something the *decode* path may consult.
    func remoteID(for key: SharedActorKey) -> ActorID {
        ActorID(raw: .remote(.init(session: self, key: key)))
    }

    // MARK: - Inbound resolution

    /// The actor a key the peer sent us names, or `nil`.
    ///
    /// **Inbound invocation targets resolve here, not through `ActorRegistry`**, which is
    /// Apple's arrangement (`Session.resolveSharedActor(at:)`, read by
    /// `handleReceivedRequest`'s `closure #2` and by `executeDirectInvocation` -- the
    /// only two readers of `sharedActors`). It is also the only arrangement that makes
    /// this table's strong hold mean anything: the registry is weak and drops an actor on
    /// `resignID`, so resolving through it would make an actor unreachable to a peer that
    /// holds its key *while this session is still keeping that actor alive*. We would be
    /// paying for the strong hold and not getting it.
    ///
    /// The consequence, stated plainly because it is a real one: an actor that has
    /// resigned can still be called by a peer that already holds its key, until the
    /// session is cancelled. In practice that window is narrow -- the distributed actor
    /// runtime resigns an id from `deinit`, and `deinit` cannot run while this table
    /// holds the instance -- so it is reached by an explicit `resignID`, not by an actor
    /// going away. `cancellationCompleted()` is what ends it.
    ///
    /// Scope is unchanged either way: only actors *this* session exported are reachable,
    /// because only they have keys in this table.
    ///
    /// `AnyObject` rather than Apple's `any DistributedActor` because that is what the
    /// table holds; this file does not import `Distributed`, and the caller that will
    /// need the stronger type is the one that also needs the thunk.
    func resolveSharedActor(at key: SharedActorKey) -> AnyObject? {
        lock.withLock { byKey[key]?.instance }
    }

    // MARK: - Cancellation

    /// The table does not outlive the conversation.
    ///
    /// Apple's `Session.cancellationCompleted()` clears `sharedActors` wholesale under
    /// its mutex and then fulfils two promises; the promises belong with the awaitable
    /// events, in a later slice. Clearing is the part that matters here, and it is the
    /// only release the strongly-held instances ever get.
    ///
    /// The `isCancelled` latch is ours rather than Apple's: it stops a share that races
    /// the clear from repopulating a table nobody will ever read again, and it makes
    /// "a cancelled session exports nothing" true rather than momentarily true.
    ///
    /// **Nothing calls this yet.** Apple's caller is `handleTransportCancellation()`,
    /// the `InboundSessionProtocol` witness the transport invokes when the connection
    /// goes away, and which also cancels the pending invocation execution tasks. Wiring
    /// that up belongs with the transport slice; until it exists, an abandoned session
    /// holds its exported actors until it is itself released.
    func cancellationCompleted() {
        lock.withLock {
            isCancelled = true
            byKey.removeAll()
            keyForLocal.removeAll()
        }
    }
}
