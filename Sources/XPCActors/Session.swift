// Sources/XPCActors/Session.swift
import Distributed
import Foundation
import Synchronization

/// The half of a session an outbound call needs: somewhere to send an invocation.
///
/// Apple splits the same way. `InboundSessionProtocol` carries `handleReceivedRequest`,
/// `handleReceivedNotification`, `handleActorShared`, `handleTransportCancellation`,
/// `actorSystem` and `isBidirectional`; `OutboundSessionProtocol` carries exactly two
/// requirements, `sendInvocation(to:target:invocation:)` and `actorSystem`. And it is the
/// *outbound* one that `RawActorID.Remote.session` is typed against, which is why
/// `remoteCall` can find a sender through nothing but a proxy's id.
///
/// It refines ``SessionCoding`` rather than restating it: `SessionCoding.systemID` is
/// Apple's `actorSystem` requirement at the width our identity layer can state (see the
/// comment there), so `OutboundSession` adds the one thing left.
///
/// Declared here rather than beside `SessionCoding` in `ActorID.swift` on purpose:
/// `sendInvocation` mentions `RemoteCallTarget` and `InvocationEncoder`, and
/// `ActorID.swift` is deliberately buildable with no `Distributed` import at all.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public protocol OutboundSession: SessionCoding {

    /// Send one invocation to `id` and wait for its response.
    ///
    /// `id` is the whole `ActorID` rather than the key it contains, as Apple's is: the
    /// key alone would not say which session's key space it belongs to, and this method
    /// is the one place that can still check.
    ///
    /// `inout` on the encoder is Apple's, and nothing here mutates it; it is threaded
    /// through unchanged from `remoteCall`, whose signature the Swift runtime fixes.
    func sendInvocation<Res: Codable>(
        to id: ActorID,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder
    ) async throws(RemoteInvocationCancellationError) -> Res
}

/// One conversation with one peer, over one transport, and the table of actors we have
/// exported into it.
///
/// **A session is vended by the system that owns it** -- ``XPCActorSystem/makeSession(over:)``
/// is the only way to make one, and the initializer is `fileprivate`. The
/// previous shape took a registry and a system id as independent parameters, so
/// `Session(registry: a.registry, systemID: b.id)` was constructible and meant nothing:
/// a table belonging to one system, claiming another. Taking the system closes that by
/// construction rather than by convention, and it is also Apple's shape --
/// `Session.init(actorSystem:transport:options:)`, with `actorSystem` the first stored
/// property and the actor table reached *through* it.
///
/// **The `Thunk` parameter is gone.** It was a placeholder for a per-actor thunk that the
/// reconstruction says Apple does not have: `actorTable` is
/// `Mutex<[RawActorID.Local: WeakActorRef]>` and `WeakActorRef` is one weak
/// `any DistributedActor`. With the system stored, the registry is `system.registry` --
/// an `ActorRegistry<Void>` -- and a generic parameter that can only ever be `Void` buys
/// nothing but a type argument at every use site. (`ActorRegistry` keeps its own
/// parameter; narrowing that is a separate change to a separate type.)
/// Apple's `LocalSessionState`: a `.local` session's own state. The client end holds the
/// server end here -- **strongly**, so the direct-invocation path can resolve a target in
/// the server's shared-actor table, and so the server stays alive as long as a client can
/// call it -- with the server end's `peer` left `nil` (it is pushed to, not reaching out),
/// which is what keeps the pair from a strong cycle. Plus a one-shot cancellation fuse.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class LocalSessionState: @unchecked Sendable {
    let peer: Session?
    let isCancelled = Atomic<Bool>(false)
    init(peer: Session?) { self.peer = peer }

    /// "The peer is this process" -- Apple's `LocalSessionState.currentProcessAuditToken()`,
    /// `task_info` with `TASK_AUDIT_TOKEN`, which is what a `.local` session attests instead
    /// of reaching through a transport that is not there.
    static func currentProcessAuditToken() -> audit_token_t? {
        #if canImport(Darwin)
        var token = audit_token_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), rebound, &count)
            }
        }
        return status == KERN_SUCCESS ? token : nil
        #else
        return nil
        #endif
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public final class Session: SessionCoding, OutboundSession, InboundSession, @unchecked Sendable {

    /// From the process-global counter, like Apple's `Session.id` -- the same generator
    /// that mints system and instance ids, and deliberately *not* the per-session one
    /// below. Never transmitted; it exists so one session can be told from another in a
    /// log.
    let id = ID64.next()

    /// The system this session belongs to. Apple's `Session.actorSystem` (+0x10, a `let`,
    /// and the first field).
    ///
    /// Strong, as Apple's is. The system does not hold its sessions, so this is not a
    /// cycle; a session outliving the last other reference to its system is exactly what
    /// keeps an in-flight call's `resolve` answerable.
    let system: XPCActorSystem

    /// Where this session speaks. Apple's `Session.Kind`, `xpc(Transport) |
    /// local(LocalSessionState)` -- and now that the same-process path has landed, this is
    /// the enum it always was a case of. `xpc` goes over a real transport; `local` short-
    /// circuits to the direct-invocation path against a peer session in this same process,
    /// never encoding a byte.
    enum Kind {
        case xpc(Transport)
        case local(LocalSessionState)
    }
    private let kind: Kind

    /// The transport, for the `xpc` paths that only ever run on an `xpc` session -- the
    /// inbound wiring in `init`, the reply channel, the wire send. A `.local` session reaches
    /// none of them, so the trap here names a genuine bug (Apple's four accessors trap on a
    /// `.local` session too), not a case that cannot fire.
    private var transport: Transport {
        guard case .xpc(let transport) = kind else {
            preconditionFailure("an xpc-only path was taken on a .local session")
        }
        return transport
    }

    /// Apply an outbound backpressure policy to this session's transport. A `.local`
    /// (same-process, direct-invocation) session has no transport to bound, so this is a no-op
    /// there -- backpressure is a wire concept. Reached through
    /// ``RemoteInterface/setBackpressurePolicy(_:)``.
    func setBackpressurePolicy(_ policy: XPCActorSystem.BackpressurePolicy) {
        if case .xpc(let transport) = kind {
            transport.setBackpressurePolicy(policy)
        }
    }

    /// Which actor system this session belongs to. See ``SessionCoding/systemID``.
    ///
    /// Now derived rather than stored: the previous slice stored an `ID64` beside a
    /// registry and noted that it "becomes `system.id` and stays honest" once a session
    /// is handed a system. It is that now, so the two can no longer disagree.
    public var systemID: ID64 { system.id }

    /// Where a local id is turned into the instance behind it -- the system's table, not
    /// one of our own. Apple's `addSharedActor` likewise calls
    /// `XPCSystem.resolve(id: RawActorID.Local)` on `session.actorSystem`.
    private var registry: ActorRegistry<InboundThunk> { system.registry }

    /// What we know about an actor we have exported.
    ///
    /// Apple's table is `[SharedActorKey: any DistributedActor]` and stores no id, so
    /// mapping a key back to an actor id costs a runtime dance through the
    /// associated-type and associated-conformance witnesses (see `TestHook`
    /// `mapToLocalActorID` in the interop document). We do not need any of that: our
    /// `shareDynamically` is *handed* the `RawActorID.Local`, so the answer can simply
    /// be written down at minting time, when it is already in hand.
    private struct SharedActor {
        /// Recorded when the key is minted. This is what makes the reverse lookup a
        /// dictionary lookup rather than a reflection problem.
        let local: RawActorID.Local
        /// **Strong, on purpose**, and the one place in this module that is.
        /// `ActorRegistry` holds actors weakly because an actor's lifetime belongs to
        /// whoever created it; the wire-facing table holds them strongly because a peer
        /// holding a key must not find the actor gone. Released wholesale by
        /// ``cancellationCompleted()``.
        let instance: AnyObject
        /// How to *call* that instance. Recorded here rather than looked up at execution
        /// time on purpose: the registry is weak and `resignID` empties it, so an actor
        /// this table is still keeping alive could otherwise be reachable but uncallable.
        /// See ``resolveSharedActor(at:)``, which states that window.
        let thunk: InboundThunk
    }

    /// One lock over the whole of the mutable state, taken by both directions of the
    /// table and by the id counter. Apple uses a `Mutex` around `sharedActors` alone and
    /// a separate atomic `ID64.Generator`; folding the counter under the same lock costs
    /// nothing here -- every mint already takes the lock -- and makes "the key is unique
    /// *and* the table records it" a single critical section rather than two.
    ///
    /// The session's mutable shared-actor state, under one `Synchronization.Mutex` now that
    /// the floor is macOS 26 (Apple synchronises the same state on the transport's serial
    /// queue). `isCancelled` lives here rather than in a separate atomic because a share
    /// must observe "not cancelled" **and** register in the same critical section -- see
    /// ``shareDynamically(_:)``.
    /// `@unchecked Sendable`: this state is only ever touched under ``sharedActors``' `Mutex`,
    /// which is the synchronization. Declaring it makes the `Mutex`'s value Sendable -- what it
    /// already is in practice -- so the region checker stops flagging the (correct) stores.
    private struct SharedActorState: @unchecked Sendable {
        /// key -> actor. The direction the decode path reads, so it is a direct lookup.
        var byKey: [SharedActorKey: SharedActor] = [:]

        /// actor -> key. Apple has no such map -- which is exactly why Apple cannot dedupe.
        /// See ``shareDynamically(_:)``.
        var keyForLocal: [RawActorID.Local: SharedActorKey] = [:]

        /// **Apple's `Session.idGenerator` (+0x20), and it mints two different things.**
        ///
        /// The `dynamic` shared-actor keys come from it -- `shareActor` and
        /// `handleActorShared` are byte-identical 96-byte clones that load `Session+0x20`,
        /// `adds #1`, and `b.hs` to a `brk` on overflow -- and so does
        /// `RemoteInvocationRequest.id`, which the spec resolves as "an inlined
        /// `ID64.Generator.next()`, a `cas` loop on `Session+0x20`". One counter, not two.
        ///
        /// That is observable rather than cosmetic: a session that has shared one actor
        /// sends its first request under id 2, and the two number spaces interleave. Both
        /// values are only ever interpreted by their minter's peer, so nothing depends on
        /// which of the two took a given number -- but a peer that logged them would see the
        /// gaps, and reproducing them costs one shared counter instead of two.
        ///
        /// Ids run from 1 and an overflow traps, which `+= 1` on a `UInt64` gives for free.
        var lastID: UInt64 = 0

        /// Ours rather than Apple's: it stops a share that races the clear from
        /// repopulating a table nobody will ever read again, and makes "a cancelled session
        /// exports nothing" true rather than momentarily true. See ``cancellationCompleted()``.
        var isCancelled = false

        /// The next number from the session's generator; from 1, trapping on overflow.
        mutating func nextID() -> ID64 { lastID += 1; return ID64(rawValue: lastID) }
    }
    private let sharedActors = Mutex<SharedActorState>(SharedActorState())

    /// **Keyed by the request body's `ID64`, never by the envelope's `headerID`.** Apple's
    /// `Session.pendingInvocationExecutionTasks` (+0xa0), and the id
    /// `RemoteNotification.invocationCancelled(id:)` names -- which is the whole reason
    /// the request id is minted from this session's own generator rather than taken from
    /// the transport.
    ///
    /// **Under ``lock``, where Apple's is a bare dictionary with none.** Apple's invariant
    /// is "called on the transport's serial queue", asserted with a Dispatch precondition
    /// whose false arm traps. Our `Transport` has no such queue to offer -- packets arrive
    /// on whatever queue the raw transport delivers on, and the execution task's own
    /// completion writes here from the cooperative pool -- so reproducing the design
    /// without the queue would give an unsynchronised dictionary whose invariant nothing
    /// enforces, which is worse than either half. The lock is the same one the shared-actor
    /// table takes; folding them costs nothing, because no path takes one and then wants
    /// the other.
    ///
    /// Apple's four accessors trap on a `.local` session. There is no `.local` session here
    /// -- see ``transport`` -- so there is nothing to trap on.
    private let pendingInvocationExecutionTasks = Mutex<[ID64: ExecutionSlot]>([:])

    /// The three states an inbound execution's table entry moves through, so a
    /// `Task.immediate` execution can be spawned **outside** ``lock`` -- its last act,
    /// `finishPendingInvocationExecutionTask`, re-enters the lock, and a target that
    /// completes without suspending would deadlock if the spawn still held it -- while a
    /// body that finishes *inline*, before its handle is stored, is still reaped exactly
    /// once. Apple's `Slot` is the same machine over an `UnsafeCurrentTask`; ours holds a
    /// retained `Task`, which these executions never await, only cancel.
    private enum ExecutionSlot {
        /// Registered, but the handler task's handle is not stored yet -- it is running
        /// its inline prologue, or about to.
        case reserved
        /// The handle is stored; cancellation can reach it.
        case running(Task<Void, Never>)
        /// The task finished (or was reaped) inline, before its handle was stored.
        case done
    }

    /// **Apple's local-interface activation gate**, and the thing an inbound execution
    /// waits on before it is allowed to resolve a target.
    ///
    /// `Session` has two activation events over there --
    /// `unownedLocalInterfaceActivationEvent` (+0x58, always present) and
    /// `ownedLocalInterfaceActivationEvent` (+0x78, `nil` until `readyToReceive(_:)`
    /// installs one around the passed `Task`) -- and `waitForLocalInterfaceActivation()` is
    /// a `swift_task_switch` prologue onto whichever is in force. One event here, because
    /// the difference between the two is only *whose* priority a waiter escalates, and
    /// ``ActivationEvent`` carries that as an optional owner.
    ///
    /// **Whether it starts posted is now a real choice, as Apple's is.** A session that
    /// exports actors is driven by ``LocalInterface/activateThenWaitForCancellation()`` --
    /// which activates this gate -- so it starts *shut* and opens once its exports are in;
    /// a plain client exports nothing and starts *open*, because an inbound request to it can
    /// only ever be answered "nothing is shared there". The choice is the
    /// `localInterfaceActivated` parameter on
    /// ``XPCActorSystem/makeSession(over:localInterfaceActivated:)`` /
    /// ``XPCActorSystem/makeLocalSession(peer:localInterfaceActivated:)``, set from
    /// ``Service/InitializationOptions/bidirectional`` at connect and `false` for an accepted
    /// peer, which its handler then activates.
    private let activationEvent: ActivationEvent

    /// Apple's `Session.cancellationEvent` -- the second of the two promises
    /// `cancellationCompleted()` fulfils (`ldp x8,x20,[self,#0x48]` is this one; `[self,#0x60]`
    /// is the activation event, and the comment at `cancellationCompleted()` already named
    /// both). It exists now because ``LocalInterface/activateThenWaitForCancellation()`` is
    /// the shape a service process parks in for its whole lifetime, and parking needs
    /// something to park on.
    private let cancellationEvent = ActivationEvent(posted: false)

    /// `fileprivate`: sessions come from ``XPCActorSystem/makeSession(over:)``, which is
    /// at the bottom of this file. (`private` would not reach it -- Swift extends
    /// `private` to extensions of *the same type* in the same file, and the vending
    /// method is an extension of the system.)
    /// Apple's `Session.isBidirectional`, written at init from
    /// ``Service/InitializationOptions/bidirectional``. A session that exports actors must be
    /// bidirectional; a plain client is not, and exporting on it is the API violation
    /// ``shareDynamically(_:)`` / ``addSharedActor(_:at:)`` now trap on. Server sessions --
    /// the ones a peer handler exports through -- are bidirectional by default; only a client
    /// dialled without the option is not.
    let isBidirectional: Bool

    /// A connection-level peer requirement, from a listener's `forPeersSatisfying:`. When set,
    /// a request from a peer that does not satisfy it is refused before the target runs -- the
    /// coarse counterpart of ``RestrictedAccessDistributedActor``'s per-actor requirement.
    ///
    /// **A designed enforcement, not Apple's.** Apple's `forPeersSatisfying` is a libxpc-level
    /// requirement (`XPCPeerRequirement`) applied at the listener, so a non-satisfying peer is
    /// refused before any byte. This side's ``PeerAttestation`` is message-level -- there is no
    /// token before the first request -- so the check is made per request instead, on the first
    /// (and every) call. `nil` on a `.local` session: a same-process peer is not attested and
    /// needs no gate.
    let connectionRequirement: PeerRequirement?

    fileprivate init(system: XPCActorSystem, transport: Transport,
                     localInterfaceActivated: Bool, isBidirectional: Bool,
                     connectionRequirement: PeerRequirement? = nil) {
        self.system = system
        self.kind = .xpc(transport)
        self.isBidirectional = isBidirectional
        self.connectionRequirement = connectionRequirement
        self.activationEvent = ActivationEvent(posted: localInterfaceActivated)
        // Weakly, as Apple's initialiser does it (`swift_unknownObjectWeakAssign` into
        // `transport+0x10`). We hold the transport; it must not hold us back.
        transport.install(inboundSession: self)
        // The receiving half. **Weak captures, and that is the whole point**: a session
        // holds its transport strongly, so a closure that captured `self` strongly would
        // make the pair immortal -- the same hazard `InboundSession`'s weak back-pointer
        // exists to avoid, reappearing one layer up.
        //
        // The envelope id the request handler is given is deliberately dropped. Inbound
        // correlation is the request *body's* id; the envelope's is the transport's own
        // business and the reply closure already carries it.
        transport.inboundRequestHandler = { [weak self] _, payload, reply in
            self?.handleReceivedRequest(payload, replyUsing: reply)
        }
        transport.inboundNotificationHandler = { [weak self] payload in
            self?.handleReceivedNotification(payload)
        }
    }

    /// A `.local` session: no transport, no inbound wiring. It either exports actors that a
    /// same-process peer resolves directly (the server end, `peer == nil`), or originates
    /// direct calls against such a peer (the client end, `peer` set). See ``send`` and the
    /// pairing in ``ServiceRegistry``.
    fileprivate init(system: XPCActorSystem, local: LocalSessionState,
                     localInterfaceActivated: Bool, isBidirectional: Bool) {
        self.system = system
        self.kind = .local(local)
        self.isBidirectional = isBidirectional
        self.connectionRequirement = nil
        self.activationEvent = ActivationEvent(posted: localInterfaceActivated)
    }

    /// How many actors this session currently exports.
    var sharedActorCount: Int { sharedActors.withLock { $0.byKey.count } }

    /// Internal for tests: the request ids of the executions this side is running for the
    /// peer. The set a `RemoteNotification.invocationCancelled(id:)` names into.
    var pendingInvocationIDs: Set<ID64> {
        pendingInvocationExecutionTasks.withLock { Set($0.keys) }
    }

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
    /// **Apple's `isBidirectional` guard, now in.** `Session.(addSharedActor)` asserts it
    /// (`"API violation: Session must be bidirectional to share actor references"`), and so
    /// does this. ``isBidirectional`` is its own axis, distinct from `localInterfaceActivated`
    /// -- a server session, and a client dialled with
    /// ``Service/InitializationOptions/bidirectional``, are bidirectional and may export; a
    /// plain client is not, so exporting on it traps rather than pinning an actor a peer can
    /// never reach.
    public func shareDynamically(_ local: RawActorID.Local) -> SharedActorKey? {
        precondition(isBidirectional,
                     "API violation: Session must be bidirectional to share actor references")
        // Outside our lock, deliberately: `lookup` takes the registry's own lock, and
        // taking two locks in one critical section is how lock orders get invented by
        // accident. Nothing between here and the insert can invalidate the answer that
        // matters -- we are about to hold the instance strongly ourselves.
        guard let entry = registry.lookup(local) else { return nil }
        return sharedActors.withLock { state -> SharedActorKey? in
            guard !state.isCancelled else { return nil }
            if let existing = state.keyForLocal[local] { return existing }
            let key = SharedActorKey.dynamic(state.nextID())
            state.byKey[key] = SharedActor(local: local, instance: entry.instance,
                                           thunk: entry.thunk)
            state.keyForLocal[local] = key
            return key
        }
    }

    /// Share `local` under a key the *caller* chose, rather than a minted one.
    ///
    /// This is the other half of Apple's `Session.(addSharedActor)`: both `export`
    /// overloads on ``LocalInterface`` build a `SharedActorKey` themselves --
    /// `.exportedRawValue(name)` or `.exported(SwiftType(stub))` -- and funnel into the
    /// same table that ``shareDynamically(_:)`` writes. A well-known key is what lets a
    /// client name an actor it has never been handed a reference to, which is the entire
    /// bootstrap problem: `.dynamic` keys are useless to a peer that has not yet received
    /// one.
    ///
    /// **`keyForLocal` is deliberately not written here.** That map exists to dedupe
    /// `shareDynamically`, and it holds one key per actor. An actor can legitimately be
    /// exported under a well-known name *and* handed out dynamically, and if this wrote the
    /// map, the later dynamic share would hand the peer the well-known key instead of
    /// minting one -- a silent aliasing of two different namings. Reading it is likewise
    /// wrong: a name the caller chose must win over whatever was minted earlier.
    ///
    /// Returns `false` when the actor is not registered (deallocated, or never `actorReady`)
    /// or the session is already cancelled, so a caller can fail loudly rather than export
    /// nothing and find out at the first call.
    ///
    /// The two failure reasons are reported apart because they deserve opposite treatment,
    /// and collapsing them into one `false` would force the caller to pick wrongly for one of
    /// them. `notRegistered` is the caller handing us an actor that is not live -- API misuse.
    /// `sessionCancelled` is the peer having hung up during setup -- a race nobody misused.
    enum ShareOutcome {
        case shared
        case notRegistered
        case sessionCancelled
    }

    func addSharedActor(_ local: RawActorID.Local, at key: SharedActorKey) -> ShareOutcome {
        precondition(isBidirectional,
                     "API violation: Session must be bidirectional to share actor references")
        guard let entry = registry.lookup(local) else { return .notRegistered }
        return sharedActors.withLock { state in
            guard !state.isCancelled else { return .sessionCancelled }
            state.byKey[key] = SharedActor(local: local, instance: entry.instance,
                                           thunk: entry.thunk)
            return .shared
        }
    }

    /// What the peer's transport can attest about it, if anything.
    ///
    /// Exposed so ``Session/RemoteInterface/satisfies(requirement:)`` can ask -- `transport`
    /// itself stays private, because a caller holding an interface has no business reaching
    /// the pipe.
    var peerAttestation: (any PeerAttestation)? {
        switch kind {
        case .xpc(let transport): transport.peerAttestation
        // A `.local` peer is this process: it attests its own audit token, exactly as
        // Apple's `LocalSessionState` does, rather than reaching through a transport.
        case .local: LocalSessionState.currentProcessAuditToken().flatMap(AuditTokenAttestation.init)
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
    public func remoteID(for key: SharedActorKey) -> ActorID {
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
    /// table holds.
    ///
    /// **A test seam, and it has no production caller.** The inbound execution path needs
    /// the invocation thunk as well as the instance, so it goes through
    /// ``resolveSharedTarget(at:)``; this is what the tests use to ask "is *that* actor the
    /// one behind this key", which is an identity question the thunk would only get in the
    /// way of. Kept rather than folded in because splitting it is what lets the execution
    /// path take one critical section instead of two.
    func resolveSharedActor(at key: SharedActorKey) -> AnyObject? {
        sharedActors.withLock { $0.byKey[key]?.instance }
    }

    /// The lookup the inbound execution path makes: the instance **and** the invocation
    /// thunk, in one critical section, so the two cannot come from different states of the
    /// table.
    private func resolveSharedTarget(at key: SharedActorKey)
    -> (instance: AnyObject, thunk: InboundThunk)? {
        sharedActors.withLock { state in state.byKey[key].map { ($0.instance, $0.thunk) } }
    }

    // MARK: - Outbound

    /// Assemble one invocation, send it, and decode the response.
    ///
    /// The order is Apple's, read off the inlined `RemoteInvocationRequest.init` in
    /// `Session.sendInvocation`: mint the request id from ``lastID``, copy the key and
    /// the encoder, read `RemoteCallTarget.identifier`, read `Task.basePriority`, then
    /// encode. Everything before the `await` is what makes "a call that cannot be
    /// encoded was never sent" true.
    ///
    /// **The response is decoded here, not in the transport**, because here is where
    /// `Res` is known. `RequestTable.Outcome` is `.reply(Packet.Payload)` -- an
    /// *undecoded* payload -- for exactly this reason, and it is Apple's arrangement
    /// too: their `RemoteInvocationResponse<A>` is generic and instantiated at the call
    /// site.
    ///
    /// **The `userInfo` carries this session in both directions.** An argument holding an
    /// `ActorID` cannot encode itself without one (`ActorID.encode` traps on its
    /// absence), and a key coming back cannot become a proxy without one. Apple threads
    /// the same dictionary through both halves; `Payload.init(encoding:userInfo:)` has no
    /// default parameter precisely so this cannot be forgotten.
    public func sendInvocation<Res: Codable>(
        to id: ActorID,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder
    ) async throws(RemoteInvocationCancellationError) -> Res {

        // A key means nothing outside the key space of the session that minted it, and
        // this is the last point that can still tell. Unreachable through `remoteCall`,
        // which takes the session *from* the id it then passes -- so this guards a
        // direct caller, not the runtime.
        guard case .remote(let remote) = id.raw, remote.session === self else {
            throw RemoteInvocationCancellationError.executionFailed(
                "\(id.raw) cannot be called through this session: a shared-actor key is "
                + "only meaningful to the session that minted it.")
        }

        // Apple's `.local` send: resolve and run the target in the peer's own process,
        // capturing its outcome, and never encoding a byte.
        if case .local(let local) = kind {
            return try await directSend(
                key: remote.key, target: target, invocation: &invocation, peer: local.peer)
        }

        let request = invocation.makeRequest(
            id: sharedActors.withLock { $0.nextID() },
            targetedSharedActor: remote.key,
            remoteCallTarget: target)

        let payload: Packet.Payload
        do {
            payload = try Packet.Payload(encoding: request, userInfo: userInfo)
        } catch {
            // `.executionFailed`, whose default text is "The distributed invocation was
            // not executed" -- which is exactly true here: nothing has left this process.
            throw RemoteInvocationCancellationError.executionFailed(
                "could not encode the invocation for \(target.identifier): \(error)")
        }

        switch await transport.sendRequest(seq: transport.allocateSeq(), payload) {
        case .failed(.taskCancelled):
            // Our own caller walked away. The **session** is fine -- one waiter was
            // cancelled and nothing else -- but the peer is not: it is still executing a
            // target whose result nobody will read, and only we know that. So it is told.
            //
            // This is what `RemoteNotification.invocationCancelled(id:)` is for, and it is
            // also why the request id is minted per session rather than taken from the
            // transport: the notification names the *request body's* `id`, not the
            // envelope's `headerID`, and the receiver looks that id up in its
            // `pendingInvocationExecutionTasks`.
            notifyPeerOfCancellation(of: request.id)
            throw RemoteInvocationCancellationError.callingTaskCancelled()
        case .failed(.transportCancelled(let message)):
            throw RemoteInvocationCancellationError.underlyingSessionCancelled(message)
        case .reply(let reply):
            let response: RemoteInvocationResponse<Res>
            do {
                response = try reply.decode(as: RemoteInvocationResponse<Res>.self,
                                            userInfo: userInfo)
            } catch {
                // Not `.executionFailed`: a body we cannot read says nothing about
                // whether the target ran. `.resultPropagationFailed`'s default text --
                // "Failed to obtain the result of the distributed invocation after it
                // was executed" -- is the one that does not claim more than we know.
                throw RemoteInvocationCancellationError.resultPropagationFailed(
                    "could not decode the response to \(target.identifier): \(error)")
            }
            switch response {
            case .result(let value):
                return value
            // Apple propagates no concrete error: `RemoteInvocationFailure` carries a
            // `String` and nothing else (`", but XPCSystem does not support propagating
            // errors."`). So the text is the whole of what crossed, and the reason is
            // carried across rather than flattened.
            case .failure(.executionFailed(let message)):
                throw RemoteInvocationCancellationError.executionFailed(message)
            case .failure(.resultPropagationFailed(let message)):
                throw RemoteInvocationCancellationError.resultPropagationFailed(message)
            }
        }
    }

    /// The direct-invocation send: the same-process counterpart of the wire path above.
    ///
    /// It mirrors the inbound execution -- park on the peer's activation gate, resolve the
    /// target in the peer's shared-actor table, check its per-actor requirement -- but runs
    /// the target through the **direct** decoder and result handler, so the caller's argument
    /// values go in and the target's return value comes back with nothing encoded.
    private func directSend<Res: Codable>(
        key: SharedActorKey, target: RemoteCallTarget,
        invocation: inout InvocationEncoder, peer: Session?
    ) async throws(RemoteInvocationCancellationError) -> Res {
        guard let peer else {
            throw RemoteInvocationCancellationError.executionFailed(
                "a server-side .local session cannot originate a call")
        }
        // Park until the peer has exported its actors and opened its gate -- the same
        // ordering the wire path gets, so a call that beats the server's setup waits rather
        // than failing to resolve.
        await peer.waitForLocalInterfaceActivation()
        guard let resolved = peer.resolveSharedTarget(at: key) else {
            throw RemoteInvocationCancellationError.executionFailed(
                "no actor is shared at \(key) in the peer session, so \(target.identifier) "
                + "has nothing to run on")
        }
        guard peer.peerSatisfiesRequirement(of: resolved.instance) else {
            throw RemoteInvocationCancellationError.executionFailed(
                "Failed actor's peer requirement check")
        }
        // Apple's shape: the sender's encoder makes the `DirectInvocationDecoder`
        // (`makeDirectInvocationDecoder(senderSession:receiverSession:)`), which the wrapper
        // then holds. `self` is the sender, `peer` the receiver.
        let decoder = InvocationDecoder(
            direct: invocation.makeDirectInvocationDecoder(
                senderSession: self, receiverSession: peer))
        // The direct handler is ungated: Apple's `DirectResultHandler.init()` takes no
        // `canThrow`, and same-process capture has no peer-written request to defend against.
        let handler = ResultHandler.direct()
        do {
            try await resolved.thunk(resolved.instance, peer.system, target, decoder, handler)
        } catch let error as RemoteInvocationCancellationError {
            throw error
        } catch {
            throw RemoteInvocationCancellationError.executionFailed(
                "\(target.identifier) failed on the callee: \(error)")
        }
        switch handler.capturedResult {
        case .success(let value):
            // A void target arrives here as `.success(Ack())`; `Res` is bound to `Ack` for a
            // `remoteCallVoid`, so the same cast covers both a real value and the void
            // stand-in. Apple's `DirectResultHandler.capturedResult` folds void the same way.
            guard let typed = value as? Res else {
                throw RemoteInvocationCancellationError.resultPropagationFailed(
                    "\(target.identifier) returned \(type(of: value)), not \(Res.self)")
            }
            return typed
        case .failure(let error):
            throw RemoteInvocationCancellationError.executionFailed("\(error)")
        case nil:
            throw RemoteInvocationCancellationError.resultPropagationFailed(
                "\(target.identifier) produced no result")
        }
    }

    /// Tell the peer to stop executing a request our caller has abandoned.
    ///
    /// **Best-effort by construction, and that is not a shortcut.** A notification carries
    /// no correlation id in the envelope and nothing acknowledges it -- Apple's
    /// `sendNotification` is one-way too -- so there is no outcome to report and nobody to
    /// report it to: the caller is being failed with `.callingTaskCancelled` either way,
    /// and if the transport has already gone there is no peer left to tell. Both failures
    /// are swallowed for that reason and for no other.
    ///
    /// Synchronous on purpose. It runs on a task that has just been cancelled, so anything
    /// with an `await` in it would be at risk of not running at all; encoding and
    /// `sendNotification` both are.
    private func notifyPeerOfCancellation(of requestID: ID64) {
        let notification = RemoteNotification.invocationCancelled(id: requestID)
        guard let payload = try? Packet.Payload(encoding: notification, userInfo: userInfo)
        else { return }
        try? transport.sendNotification(payload)
    }

    /// The coder `userInfo` for anything coded against this session.
    ///
    /// **Two entries, exactly as Apple's is** -- their session key and
    /// `Distributed.CodingUserInfoKey.actorSystemKey`, resolved out of the dictionary
    /// literal `handleReceivedRequest` builds.
    ///
    /// The second was absent until S4, on the reasoning that our `ActorID` coding reaches
    /// the system *through* the session and never looks it up separately. That was true of
    /// `ActorID` and false of the thing that actually needs it: the stdlib's conditional
    /// `Codable` conformance on `DistributedActor` decodes an actor value by reading
    /// `.actorSystemKey` out of the `userInfo` and calling `resolve(id:using:)`. So a
    /// `distributed func` taking or returning *an actor* -- as opposed to an `ActorID` --
    /// could not decode without it. That is the case ``SharedActorKey`` exists for, so the
    /// omission was load-bearing rather than cosmetic.
    private var userInfo: [CodingUserInfoKey: Any] {
        [.xpcActorSession: self, .actorSystemKey: system]
    }

    // MARK: - Activation

    /// The local interface is up: inbound executions may resolve targets.
    ///
    /// Apple reaches this through `readyToReceive(_:)` (which also installs the owned event)
    /// and through the task that event owns; the two are split here because there is no
    /// `ActivationToken` to hand back and nothing to own it.
    ///
    /// One-shot and idempotent, because Apple's `posted` is a `Fuse`.
    func activateLocalInterface() {
        activationEvent.post()
    }

    /// Internal: the task a waiter's priority should reach -- Apple's
    /// `OwnedAwaitableEvent.owningTask`, which is escalated and **never awaited**.
    ///
    /// Named `escalate` rather than typed `Task<…, Never>` because Apple's is generic over
    /// the owner's `Success` (`Task<LocalInterface.ActivationToken, Never>`) and this module
    /// has no token type to name.
    func setActivationOwner(_ escalate: @escaping @Sendable (TaskPriority) -> Void) {
        activationEvent.setOwner(escalate)
    }

    /// Internal for tests.
    var isLocalInterfaceActivated: Bool { activationEvent.isPosted }

    /// Park until this session's conversation ends.
    ///
    /// One-shot and idempotent, like every other `ActivationEvent`: a session that has
    /// already been cancelled returns immediately rather than parking forever, which is the
    /// difference between a service that exits and one that hangs on shutdown.
    func waitForCancellation() async {
        await cancellationEvent.waitUnlessCancelled()
    }

    /// Apple's `Session.waitForLocalInterfaceActivation() async`, step 3 of the inbound
    /// success path -- before `Task.isCancelled`, before `resolveSharedActor(at:)`, and so
    /// before either the target or its peer requirement is looked at.
    ///
    /// **Escalate-plus-single-await, not a join.** See ``ActivationEvent/wait()``.
    ///
    /// A cancelled session releases every waiter, because ``cancellationCompleted()`` posts
    /// this event -- which is Apple's too: their `cancellationCompleted()` fulfils the
    /// `unownedLocalInterfaceActivationEvent` promise. Without that, an execution parked
    /// here would outlive the transport and never reply.
    func waitForLocalInterfaceActivation() async {
        await activationEvent.wait()
    }

    // MARK: - The two peer gates

    /// **Gate one: does the peer satisfy the *actor system's* requirement?**
    ///
    /// Apple's `Session.remoteSatisfiesActorSystemRequirement() -> Bool` (`0x2ad508ed8`),
    /// which instantiates `XPC.XPCPeerRequirement` metadata and checks the peer against it.
    /// `handleReceivedRequest` calls it at `+0x930`, and the two things around that call are
    /// worth having right because both were misread before:
    ///
    /// - it runs **before** the payload is decoded (the `XPCDictionary.decode(as:
    ///   RemoteInvocationRequest.self, forKey: "payload")` call is at `+0x9a4`, and the
    ///   `"payload"` key literal is built between the two). The interop spec lists the order
    ///   the other way round; the branch targets say otherwise. So an unentitled peer's
    ///   bytes are never parsed;
    /// - it is guarded by `isBidirectional` (`ldrb w8,[x25,#0x70]; cmp #1; b.ne`), whose
    ///   other arm answers `"Session cannot receive requests"` without decoding either.
    ///   That flag is not modelled here -- see ``shareDynamically(_:)`` for why -- so that
    ///   arm has no counterpart.
    ///
    /// `nil` requirement admits everyone, which is the shipping default and the reason
    /// nothing broke while this was missing. A requirement that is set and a peer that
    /// cannot be attested to at all is **refused**: `RemoteInterface.satisfies(requirement:)`
    /// is `Bool?` precisely so that "unknown" is not "no", and this is the one place that
    /// has to collapse the three values into two. Collapsing "unknown" to *admit* would mean
    /// a transport with no attestation silently disabled the gate.
    ///
    /// **Apple does not refuse there; Apple dies there, in three different ways, and this is
    /// the second place in this file where that divergence is taken deliberately** (the other
    /// is ``peerSatisfiesRequirement(of:)``, which is the same call about the per-actor gate).
    /// Read out of `0x2ad508ed8`:
    ///
    /// | condition | Apple | here |
    /// |---|---|---|
    /// | `kind` is `.local` (`tbnz x8,#0x3f` at `+0x17c`) | `brk #1` at `+0x234` | n/a — no `.local` session exists |
    /// | `RemoteInterface.auditToken` is `nil` (`cmp w8,#1; b.eq` at `+0x1bc`) | `_assertionFailure` at `+0x238` | `false` |
    /// | the token exists but `audit_token_t.isValid` is `false` (`tbz w0,#0` at `+0x1dc`) | `_assertionFailure` at `+0x284` | `false` |
    ///
    /// The two assertion literals, decoded from the `adrp`/`add`/`sub #0x20` operands rather
    /// than attributed by adjacency:
    ///
    /// - `0x2ad525e10`, 121 bytes: `"Bug in XPCDistributed: This method should only be
    ///   called once a message from the remote endis known to have been received"` — the
    ///   missing space is in Apple's literal, which is how you can tell it is one string
    ///   built from two source lines.
    /// - `0x2ad525e90`, 77 bytes: `"Bug in XPCDistributed: Expected valid audit token if the
    ///   transport returns one"` — the same literal the reconstruction attributes to
    ///   `RemoteInterface.auditToken`.
    ///
    /// Both wordings say what the trap is *for*: over there this is unreachable unless the
    /// framework called it too early, because an `.xpc` session that has received a message
    /// always has a token. That is exactly the assumption our transport seam does not carry —
    /// ``RawTransportProtocol/peerAttestation`` is `nil` for every transport that cannot
    /// attest, and a conformer outside this module may be such a transport. So the condition
    /// Apple treats as "impossible, therefore fatal" is here "possible, therefore refuse",
    /// and refusing is the only answer that is not either a lie or an abort.
    func remoteSatisfiesActorSystemRequirement() -> Bool {
        guard let requirement = system.peerRequirement else { return true }
        return peerAttestation?.satisfies(requirement) == true
    }

    /// **Gate two: does the peer satisfy *this actor's* requirement?**
    ///
    /// Apple's is inside `handleReceivedRequest`'s `closure #2`, after the target resolves:
    /// `swift_getObjectType` then `swift_conformsToProtocol2` against the
    /// `RestrictedAccessDistributedActor` descriptor at `0x2ad527dd8`; if the actor does not
    /// conform (`cbz x0`) the check is skipped entirely; if it does, the path reads
    /// `RemoteInterface.auditToken`, calls the `peerRequirement` witness at witness-table
    /// slot `+0x10`, and hands both to `audit_token_t.satisfies(requirement:)`.
    ///
    /// **A nil audit token is `brk #1` over there** (`0x2ad514e70`, reached by
    /// `ldrb w8,[x22,#0x218]; cmp #1; b.eq`) -- a force-unwrap, so a restricted actor
    /// exported over a transport that cannot attest kills the process. Ours refuses instead,
    /// on this module's stated criterion: the *peer* chooses which actor a request names, so
    /// the peer chooses whether that trap fires, and a peer-triggerable abort is a denial of
    /// service. The misconfiguration is still an error -- it just gets reported to the peer
    /// that provoked it rather than ending the process for everyone.
    ///
    /// Returns Apple's own failure text on refusal so that a peer sees what a peer would
    /// see: `"Failed actor's peer requirement check"`, read out of `__cstring` at
    /// `0x2ad5262b0` (37 bytes), and distinct from the system-wide gate's wording.
    private func peerSatisfiesRequirement(of instance: AnyObject) -> Bool {
        guard let restricted = instance as? any RestrictedAccessDistributedActor
        else { return true }
        return peerAttestation?.satisfies(restricted.peerRequirement) == true
    }

    /// The connection-level gate: satisfied when no ``connectionRequirement`` is set, otherwise
    /// when the peer attests to satisfying it. An unattested peer (`peerAttestation == nil`)
    /// fails a set requirement -- the same fail-closed stance ``peerSatisfiesRequirement(of:)``
    /// takes, and for the same reason: "we cannot tell" must not read as "allowed".
    private func peerSatisfiesConnectionRequirement() -> Bool {
        guard let connectionRequirement else { return true }
        return peerAttestation?.satisfies(connectionRequirement) == true
    }

    /// Apple's `Session.cancel(because:)`, at the width this module has: tearing the
    /// transport down is what runs `handleTransportCancellation()`, which cancels the
    /// in-flight executions and empties the exported-actor table.
    func cancel(because reason: String) {
        switch kind {
        case .xpc(let transport):
            transport.cancel()
        case .local(let local):
            // A `.local` session has no transport to tear down: trip its own one-shot fuse
            // (Apple's `LocalSessionState`'s) and release the exported actors.
            guard local.isCancelled.compareExchange(
                expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged
            else { return }
            cancellationCompleted()
            // Tear down the paired end too, the way a transport death fails both ends of a
            // wire pair -- so the server end's handler task stops parking rather than living
            // until the receiver unwinds. `peer` is set on the client end and `nil` on the
            // server end, so this propagates once, from client to server.
            local.peer?.cancel(because: "the paired \(reason)")
        }
    }

    /// A dropped `.local` client session tears down the server end it paired with, so that
    /// end's handler task is reaped rather than parking forever. An `xpc` session's lifecycle
    /// is its transport's, so there is nothing to do for it here.
    deinit {
        if case .local(let local) = kind, let peer = local.peer {
            peer.cancel(because: "the local session's client end was released")
        }
    }

    // MARK: - Inbound

    /// One request from the peer: decode it, find the actor, run the target, reply.
    ///
    /// Apple's `Session.handleReceivedRequest(_:replyUsing:)` is a synchronous prologue
    /// that spawns the execution and registers it, and so is this. The order is theirs:
    /// build the `userInfo`; decode; resolve the target actor through
    /// ``resolveSharedTarget(at:)`` -- the strongly held table, not the weak registry;
    /// build a `RemoteCallTarget` from `remoteCallIdentifier`; clamp the priority; spawn;
    /// register.
    ///
    /// **Every arm replies, with exactly two exceptions, and both of them are arms where the
    /// peer is *already* being told.** A receiver that dropped a malformed request would park
    /// the peer forever: there is no timeout in this protocol, and the peer's `RequestTable`
    /// entry is only resolved by a response or by the pipe dying. That is why the decode
    /// failure, the missing-actor failure, the per-actor refusal and the duplicate-id failure
    /// are answers rather than returns, and it is what Apple's six inlined
    /// `RemoteInvocationResponse<NoSuccess>` failure sites are. The exceptions are the
    /// system-wide gate (which cancels the session, so the transport fails the request) and
    /// the post-activation cancellation check (whose caller has already been failed with
    /// `.callingTaskCancelled`). Both are Apple's arms, and both are argued at their sites.
    ///
    /// **The two peer gates are in.** Gate one, ``remoteSatisfiesActorSystemRequirement()``,
    /// runs first and before the decode, as Apple's does, and a failure **cancels the
    /// session** rather than answering -- see the call site. Gate two,
    /// ``peerSatisfiesRequirement(of:)``, runs on the execution task once the target is
    /// resolved, and a failure *is* answered.
    ///
    /// **The target now resolves on the execution task, not here.** Apple's step order is
    /// `waitForLocalInterfaceActivation()` → `Task.isCancelled` → `resolveSharedActor(at:)`,
    /// and the activation wait is an `await`, so everything after it has to be inside the
    /// task -- **including the `Task.isCancelled` check**, which is implemented and not
    /// merely described; see the guard after the wait for the window it closes. The
    /// observable difference is only *when* the "nothing is shared at that key" failure is
    /// written; it is still written.
    func handleReceivedRequest(
        _ payload: Packet.Payload,
        replyUsing reply: @escaping @Sendable (Packet.Payload) -> Void
    ) {
        // Gate one, before the bytes are read, and it does not reply.
        //
        // **Apple cancels the session here** and sends nothing: the failure arm at `+0xba8`
        // is a tail call to `Session.cancel(because:)` carrying the 71-byte literal below,
        // read out of `__cstring` at `0x2ad526220`. That is not a dropped request -- the
        // cancellation fails the peer's outstanding call through the transport, so the peer
        // learns immediately, with `.underlyingSessionCancelled` rather than
        // `.executionFailed`. Answering per-request instead would leave the door open for
        // the *next* request from a peer we have just decided must not talk to us at all.
        guard remoteSatisfiesActorSystemRequirement() else {
            cancel(because:
                "(Internal) Remote peer does not satisfy actor system's peer requirement")
            return
        }

        let request: InboundRequest
        do {
            request = try payload.decode(as: InboundRequest.self, userInfo: userInfo)
        } catch {
            // The id is inside the body we could not read, so this failure cannot be
            // registered as a pending execution -- there is nothing to cancel and nothing
            // to name. It is still answered.
            reply(Self.failure("could not decode the invocation request: \(error)"))
            return
        }

        // Captured as the String it is built from, not as the `RemoteCallTarget` itself.
        // `RemoteCallTarget` is not `Sendable` (it is the runtime's own type), and the
        // execution task below is a `sending` closure, so capturing the value would be a
        // non-Sendable capture -- an error in the Swift 6 language mode. The identifier is a
        // `String`, and the target is reconstructed from it inside the task, where it is used;
        // it is never touched on this delivering context, so nothing is lost.
        let callTargetIdentifier = request.remoteCallIdentifier
        // `canThrow` is the presence of `errorType`, which is the only signal the wire
        // carries. See ``ResultHandler/canThrow``, which records that Apple's own
        // computation of it is unresolved.
        let handler = ResultHandler(canThrow: request.contents.errorType != nil,
                                    userInfo: userInfo)
        let contents = request.contents
        let id = request.id
        let key = request.targetedSharedActor
        let system = self.system
        // Both halves of Apple's clamp, both read **here**, on the delivering context --
        // `Task.currentPriority` is read at `+0x13cc`, before the `Task.immediate` at
        // `+0x1630`, and reading it inside the spawned task would read the priority that is
        // being clamped. See ``executionPriority(requested:)`` and
        // ``executionFloorPriority()``.
        let floor = Self.executionFloorPriority()
        // The floor is applied by escalation *inside* the execution (Apple's way, now that
        // `escalatePriority` is always available at the macOS 26 floor), not folded into the
        // spawn priority -- so the spawn priority is exactly the requested one.
        let priority = Self.executionPriority(requested: request.basePriority)

        // **Registered before the task can complete, and that is what the lock buys.**
        // The execution's last act is to remove itself, which takes this same lock -- so
        // creating the task inside the critical section makes "the task exists" and "the
        // table knows about it" one step. Registering afterwards would let a fast target
        // finish, find nothing to remove, and leave its own entry behind forever, where a
        // later `invocationCancelled` would cancel an execution that had already replied.
        //
        // **This rests on `Task {}` not running inline, and that is not a free assumption.**
        // The spec records Apple spawning with `Task.immediate(name:priority:...)`, which
        // runs the body synchronously up to the first suspension. Substituting it here
        // would run `finishPendingInvocationExecutionTask` -- for a target that completes
        // without suspending -- on *this* thread, re-entering a non-reentrant `NSLock` we
        // are still holding, and deadlocking the transport's delivery. Aligning with Apple
        // on that call means restructuring this first: register, then spawn outside the
        // lock, with the completed-before-registered race handled explicitly.
        //
        // **The `id` must not already be in flight.** Our own encoder never reuses one --
        // it comes from a monotonic per-session counter -- so only a misbehaving or
        // hostile peer gets here. Overwriting would orphan the first execution: the
        // survivor of the two would be unreachable from `cancelPendingInvocationExecutionTask`
        // *and* from `cancelAllPendingInvocationExecutionTasks`, so it would outlive
        // transport death, never reply, and -- because `ResultHandler.userInfo` holds this
        // session strongly -- keep the session, its transport and every strongly held
        // shared actor alive for the life of the process. One leaked session graph per
        // duplicate. Refusing the *new* request is the same call `RequestTable.waitForReply`
        // makes about a duplicate seq, and for the same reason: the parked one must not be
        // displaced by an arrival it cannot see.
        // Reserve the id before the task can exist: registration must precede completion
        // (the execution's last act removes its own entry). With `Task.immediate` the body
        // runs synchronously here, so we reserve now, spawn outside the lock, then store the
        // handle -- and the ``ExecutionSlot`` machine reconciles a body that finished inline
        // before its handle landed.
        let accepted = pendingInvocationExecutionTasks.withLock { table -> Bool in
            guard table[id] == nil else { return false }
            table[id] = .reserved
            return true
        }
        guard accepted else {
            reply(Self.failure("""
                request id \(id) is already in flight on this session; ids are minted from \
                a monotonic per-session counter and are never reused, so \
                \(callTargetIdentifier) was refused rather than displacing the execution \
                already running under that id
                """))
            return
        }
        // Apple's `Task.immediate(priority:)`, the real one -- the body runs to its first
        // suspension right here. Spawned **outside** the lock: its last act,
        // `finishPendingInvocationExecutionTask`, re-enters the lock, and a target that
        // completes without suspending would run it inline and deadlock if we held it.
        let task = Task.immediate(priority: priority) { [weak self] in
            // Rebuilt here rather than captured -- see `callTargetIdentifier` above.
            let callTarget = RemoteCallTarget(callTargetIdentifier)
            // The floor, applied the way Apple applies it: not as the spawn priority but as
            // an escalation of the task that is already running, which is why it can only
            // ever raise. `UnsafeCurrentTask.escalatePriority(to:)` is SE-0462, macOS 26,
            // which is this module's floor. See ``executionFloorPriority()``.
            withUnsafeCurrentTask { $0?.escalatePriority(to: floor) }

            guard let self else {
                // The session went away between registration and the first hop. Nothing
                // can resolve, and the peer is still owed an answer.
                reply(Self.failure("""
                    the session that received \(callTarget.identifier) was released \
                    before the invocation could be executed
                    """))
                return
            }

            // Apple's step 3, and the reason resolution is inside this task at all.
            await self.waitForLocalInterfaceActivation()

            // **Apple's step 4, and it is load-bearing precisely because step 3 is not
            // cancellation-aware.** `closure #2 +0x358` reads `Task.isCancelled`,
            // releases the `os_transaction`, and returns -- no reply, no target.
            //
            // The window it closes is one S5 *opened*. Before the activation gate,
            // nothing suspended unboundedly between registering the execution and
            // running it, so a cancellation that arrived in between had nowhere to land.
            // Now a peer can park a request on a not-yet-activated session, abandon its
            // caller (which sends `invocationCancelled`, so this task really is
            // cancelled), and the target would still run on activation -- side effects
            // and all -- for a call whose caller was already failed.
            //
            // `ActivationEvent.wait()` deliberately does not observe cancellation, which
            // is Apple's shape too (`await future.value` does not either). That is what
            // makes the check here the thing doing the work rather than a second belt.
            //
            // **No reply, and that is Apple's arm rather than an oversight.** The caller
            // has already been failed with `.callingTaskCancelled` -- sending it a
            // response now would be answering a question nobody is still asking, and the
            // only other listener for this id is a `RequestTable` entry that is gone.
            // The pending-table entry still has to be drained.
            guard !Task.isCancelled else {
                self.finishPendingInvocationExecutionTask(withID: id)
                return
            }

            // Gate zero: the connection-level `forPeersSatisfying` requirement -- refuse the
            // peer entirely, ahead of resolving any actor. Designed enforcement (see
            // ``connectionRequirement``): checked per request because this side's attestation is
            // message-level, so there is nothing to gate on before the first call arrives.
            guard self.peerSatisfiesConnectionRequirement() else {
                reply(Self.failure("Failed peer requirement check"))
                self.finishPendingInvocationExecutionTask(withID: id)
                return
            }

            guard let target = self.resolveSharedTarget(at: key) else {
                reply(Self.failure("""
                    no actor is shared at \(key) in this session, so \
                    \(callTarget.identifier) has nothing to run on
                    """))
                self.finishPendingInvocationExecutionTask(withID: id)
                return
            }

            // Gate two. Per resolved target, so a restricted actor and an unrestricted
            // one on the same session are answered differently for the same peer.
            guard self.peerSatisfiesRequirement(of: target.instance) else {
                // Apple's literal, `0x2ad5262b0`, 37 bytes.
                reply(Self.failure("Failed actor's peer requirement check"))
                self.finishPendingInvocationExecutionTask(withID: id)
                return
            }

            do {
                try await target.thunk(target.instance, system, callTarget,
                                       InvocationDecoder(contents), handler)
                // A handler with no reply means the runtime returned without calling
                // any of `onReturn`/`onReturnVoid`/`onThrow`. Nothing in the current
                // runtime does that; if one ever does, the peer is told rather than
                // left waiting.
                if let built = handler.reply {
                    reply(built)
                } else {
                    reply(Self.propagationFailure("""
                        \(callTarget.identifier) returned without producing a result
                        """))
                }
            } catch {
                // Everything the inbound path can go wrong with lands here: an
                // unknown target, an argument that will not decode, a substitution
                // that is not a stub, a target that threw out of a non-throwing
                // signature. All of them are "the invocation was not executed" from
                // the peer's side, which is `.executionFailed`'s own default text.
                reply(Self.failure(
                    "\(callTarget.identifier) failed on the callee: \(error)"))
            }
            // `[weak self]` above is honest about intent but buys nothing on its own:
            // `handler.userInfo` holds this session strongly, the task holds the
            // handler, and the table holds the task -- so session -> task -> handler
            // -> session is live for the duration of every execution. That cycle is
            // closed by this line, which is why the guard above matters so much: an
            // orphaned execution is a leaked session graph, not just a leaked task.
            // (The `[weak self]` on the transport handlers in `init` is a different
            // thing and *is* load-bearing -- the transport outlives nothing there.)
            self.finishPendingInvocationExecutionTask(withID: id)
        }
        // Store the handle unless the body already finished inline. `.reserved` -> the body
        // suspended, so store the handle for cancellation to reach; `.done` -> it finished
        // inline before we got here, so drop the transient entry.
        pendingInvocationExecutionTasks.withLock { table in
            switch table[id] {
            case .reserved: table[id] = .running(task)
            case .done: table[id] = nil
            case .running, .none: break
            }
        }
    }

    /// The priority to run an inbound execution at.
    ///
    /// **RESOLVED, and `Task.currentPriority` is not part of this clamp at all.** The spec
    /// records `handleReceivedRequest` clamping "against `Task.currentPriority` **and**
    /// `TaskPriority.userInitiated` via `Comparable.<`" and leaves the role of the first
    /// operand open. Disassembling `0x2ad512a04` shows two *separate* clamps, not one
    /// three-operand one, and only the second involves `currentPriority`:
    ///
    /// - `+0x11b4 … +0x13bc`, this function. `TaskPriority.userInitiated.getter`, then
    ///   `Comparable.<` with lhs `userInitiated` and rhs the request's `basePriority`
    ///   payload; the true arm takes `userInitiated`, the false arm copies `basePriority`.
    ///   Wrapped in a `getEnumTagSinglePayload` test that preserves `nil` by storing tag 1.
    ///   The buffer this writes is `[x29-0x100]`, and `[x29-0x100]` is the `priority:`
    ///   argument of the `Task.immediate` at `+0x1630`. So the spawn priority is exactly
    ///   `basePriority.map { min($0, .userInitiated) }` -- what this function already was.
    /// - `+0x13c0 … +0x1438`, ``executionFloorPriority()``. A second, independent
    ///   `min(Task.currentPriority, .userInitiated)`, which is *not* combined with the
    ///   first: it is copied into the execution closure's context and applied inside it.
    ///
    /// The brief's candidate reading, `max(currentPriority, min(requested, .userInitiated))`,
    /// is close and wrong in two ways that matter: `currentPriority` is itself capped at
    /// `.userInitiated` before it is used as a floor, and it is applied by escalating a task
    /// that is already running rather than by choosing its base priority.
    ///
    /// **The ceiling is not a scheduling nicety; without it a peer can abort this
    /// process.** `basePriority` arrives as a bare `UInt8` and `TaskPriority.init(rawValue:)`
    /// is not failable, so a peer can name a priority no Swift constant has -- and handing
    /// that to `Task(priority:)` is fatal, not merely odd. Measured, by running the mutant
    /// that removes this `min`: the runner dies on the spot with
    ///
    ///     invalid job priority 0xff
    ///
    /// on a request whose only unusual field is `"basePriority": 255`. So reading the field
    /// at all is only safe *because* of this line. Before this slice the field was decoded
    /// and discarded, which was safe by accident and divergent in silence.
    static func executionPriority(requested: TaskPriority?) -> TaskPriority? {
        guard let requested else { return nil }
        return min(requested, .userInitiated)
    }

    /// The **other** half of Apple's clamp: the floor an inbound execution is escalated to.
    ///
    /// `min(Task.currentPriority, .userInitiated)`, read at `0x2ad513dc0..0x2ad513e38`:
    /// `Task.currentPriority.getter` into one stack buffer, `TaskPriority.userInitiated.getter`
    /// into another, `Comparable.<(userInitiated, currentPriority)`, then a `csel` pair that
    /// keeps one address and destroys the other. Which one survives is not a guess -- the
    /// address in `x0` is passed straight to the value witness at VWT`+0x08`, which is
    /// `destroy`, and the address kept in `x19` is the one `initializeWithTake` (VWT`+0x20`)
    /// then copies into the execution closure's context. The survivor is the **smaller**.
    /// (`TaskPriority` is address-only here because it is resilient, which is why the whole
    /// sequence moves pointers around instead of bytes.)
    ///
    /// Inside the execution closure it is applied at `0x2ad5154b4`:
    /// `withUnsafeCurrentTask { $0!.escalatePriority(to: floor) }`, immediately after
    /// `os_transaction_create` and before `waitForLocalInterfaceActivation()`.
    ///
    /// **Why a floor and not a second ceiling.** `escalatePriority` only ever raises, so the
    /// pair composes to `min(max(requested, currentPriority), .userInitiated)`: a peer can
    /// ask for *less* than the delivering context's priority and not get it, and can ask for
    /// more than `.userInitiated` and not get that either. What it buys concretely is that a
    /// peer cannot make this process do its work at `.background` when the work was
    /// delivered on a `.userInitiated` queue -- priority is the one field a peer chooses
    /// that costs *us* rather than it.
    ///
    /// Read on the delivering context, deliberately: `Task.currentPriority` inside the
    /// spawned task would be the task's own priority, which is the thing being clamped.
    static func executionFloorPriority() -> TaskPriority {
        min(Task.currentPriority, .userInitiated)
    }


    /// Apple's `handleReceivedNotification(_:)`: decode, and dispatch the three cases.
    ///
    /// A body that is not a notification is dropped. That is not leniency for its own
    /// sake -- a notification carries no correlation id and nothing acknowledges it, so
    /// there is no one to report a failure to and no request left waiting on it.
    func handleReceivedNotification(_ payload: Packet.Payload) {
        guard let notification = try? payload.decode(as: RemoteNotification.self,
                                                     userInfo: userInfo)
        else { return }
        switch notification {
        case .invocationCancelled(let id):
            cancelPendingInvocationExecutionTask(withID: id)
        case .invocationEscalated, .responseEscalated:
            // Phase C. The wire format is complete and nothing sends these yet; the
            // handlers are `escalatePendingInvocationExecution` and
            // `verifyEscalatedInvocationResponse`, and both need a priority story this
            // module does not have.
            break
        }
    }

    /// Apple's `cancelPendingInvocationExecutionTask(withID:)`.
    ///
    /// Cancelling is a request, not a kill: the target decides what to do about it, and
    /// the entry stays until the execution actually finishes and removes itself. An
    /// unknown id is silently ignored -- a peer may cancel a call this side has already
    /// answered, which is a race rather than an error.
    private func cancelPendingInvocationExecutionTask(withID id: ID64) {
        let task: Task<Void, Never>? = pendingInvocationExecutionTasks.withLock { table in
            if case .running(let task) = table[id] { return task }
            return nil
        }
        task?.cancel()
    }

    /// Apple's `cancelAllPendingInvocationExecutionTasks()`.
    ///
    /// The tasks are cancelled *outside* the lock: each one's completion takes the same
    /// lock to remove itself, and `Task.cancel()` can run a cancellation handler inline.
    private func cancelAllPendingInvocationExecutionTasks() {
        let tasks: [Task<Void, Never>] = pendingInvocationExecutionTasks.withLock { table in
            table.values.compactMap {
                if case .running(let task) = $0 { return task }
                return nil
            }
        }
        for task in tasks { task.cancel() }
    }

    /// The execution is over, however it ended. Ours; Apple's removal happens inside
    /// `replyToPendingInvocation(withID:replyBlock:)`.
    private func finishPendingInvocationExecutionTask(withID id: ID64) {
        pendingInvocationExecutionTasks.withLock { table in
            switch table[id] {
            // Normal removal once the handle is stored.
            case .running: table[id] = nil
            // Finished inline, before the spawn stored the handle: leave a `.done` marker
            // for the store step to clear, so neither side loses the entry.
            case .reserved: table[id] = .done
            case .done, .none: break
            }
        }
    }

    /// `[1, {"executionFailed": {"_0": message}}]`, over `Never` -- a failure carries no
    /// success value, and `<Never>` is literally the instantiation Apple's eight failure
    /// sites use.
    ///
    /// `userInfo: [:]` because the body is a string: nothing session-bound can reach it,
    /// and the failure path must not itself be able to fail on a missing session.
    private static func failure(_ message: String) -> Packet.Payload {
        payload(RemoteInvocationResponse<NoSuccess>(executionFailure: message))
    }

    private static func propagationFailure(_ message: String) -> Packet.Payload {
        payload(RemoteInvocationResponse<NoSuccess>(resultPropagationFailure: message))
    }

    private static func payload(_ response: RemoteInvocationResponse<NoSuccess>) -> Packet.Payload {
        do {
            return try Packet.Payload(encoding: response, userInfo: [:])
        } catch {
            // Unreachable: the body is a tag and a string. A trap rather than a dropped
            // reply, because dropping one parks the peer forever and this is our own code
            // failing to encode two values, not a message a peer influenced.
            preconditionFailure("a failure response could not be encoded: \(error)")
        }
    }

    // MARK: - Cancellation

    /// The transport died. Apple's `InboundSessionProtocol` witness.
    ///
    /// Apple's is 40 bytes: `cancelAllPendingInvocationExecutionTasks()` then
    /// `cancellationCompleted()`. Both halves exist now -- the first is the *inbound*
    /// execution tasks, work this process started on the peer's behalf, and there is no
    /// point finishing a call whose answer can no longer be delivered.
    ///
    /// Note what this is not responsible for: the requests *we* have outstanding. The
    /// transport fails those itself, through `RequestTable.failAll`, and it stays failed
    /// so a caller arriving afterwards is refused rather than parked forever.
    public func handleTransportCancellation() {
        cancelAllPendingInvocationExecutionTasks()
        cancellationCompleted()
    }

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
    func cancellationCompleted() {
        sharedActors.withLock { state in
            state.isCancelled = true
            state.byKey.removeAll()
            state.keyForLocal.removeAll()
        }
        // **Apple's, and not tidiness.** Their `cancellationCompleted()` fulfils the
        // `cancellationEvent` promise *and* the `unownedLocalInterfaceActivationEvent` one
        // (`ldp x8,x20,[self,#0x48]` then `[self,#0x60]`). Without this an execution parked
        // in `waitForLocalInterfaceActivation()` on a session that is never activated would
        // survive transport death, never reply, and hold the session graph alive -- the
        // same shape as the orphaned-execution leak the duplicate-id guard exists for.
        // Released *after* the table is cleared, so a waker resolves nothing.
        activationEvent.post()
        cancellationEvent.post()
    }
}

// ===========================================================================================
// MARK: - The system vends sessions
// ===========================================================================================

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCActorSystem {

    /// Open a session over `transport`.
    ///
    /// The only way to build a ``Session``, which is the point: the session's actor table
    /// and the system it claims to belong to are now the same fact, so they cannot
    /// disagree. Placed in this file so ``Session``'s initializer can be `fileprivate`.
    ///
    /// **Neither throwing nor activating, where Apple's initializer is both.**
    /// `Session.init(actorSystem:transport:options:)` is `throws(SetupError)` and, unless
    /// `options.contains(.inactive)`, flips the activation fuse and activates the raw
    /// transport inline -- which is precisely why it is the throwing one of their two
    /// initialisers. Here activation stays the caller's, on `Transport.activate()`, and
    /// the split is deliberate: `InitializationOptions` does not exist yet, so there is no
    /// `.inactive` to ask for, and an unconditional activate would leave no way to build a
    /// session without one. The cost is that forgetting `Transport.activate()` surfaces at
    /// send time rather than here. That is a real failure and a loud one -- the raw
    /// transport refuses to send and the call fails with `.executionFailed` -- but it is
    /// later than Apple's, and it is where the option set will move it back.
    ///
    /// The session is *not* retained by the system. Apple's `XPCSystem` does not hold its
    /// sessions either -- the transport holds one weakly, and everything else that keeps
    /// a session alive is a caller. Dropping the returned value drops the session.
    /// - Parameter localInterfaceActivated: whether inbound executions may resolve targets
    ///   straight away. `false` is Apple's own starting state -- both their initialisers
    ///   leave `ownedLocalInterfaceActivationEvent` `nil` and `readyToReceive(_:)` is what
    ///   opens the gate -- and `true` is this module's default because there is no
    ///   `LocalInterface` here to drive it, so defaulting closed would make every session a
    ///   session that never answers. See ``Session/activateLocalInterface()``.
    func makeSession(over transport: Transport,
                     localInterfaceActivated: Bool = true,
                     isBidirectional: Bool = true,
                     connectionRequirement: PeerRequirement? = nil) -> Session {
        Session(system: self, transport: transport,
                localInterfaceActivated: localInterfaceActivated,
                isBidirectional: isBidirectional,
                connectionRequirement: connectionRequirement)
    }

    /// Vend a `.local` session -- no transport. The server end passes `peer: nil` and
    /// exports actors a same-process client resolves directly; the client end passes the
    /// server session as `peer` and originates direct calls against it. See ``ServiceRegistry``.
    func makeLocalSession(peer: Session?, localInterfaceActivated: Bool,
                          isBidirectional: Bool = true) -> Session {
        Session(system: self, local: LocalSessionState(peer: peer),
                localInterfaceActivated: localInterfaceActivated,
                isBidirectional: isBidirectional)
    }
}
