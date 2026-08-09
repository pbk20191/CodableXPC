// Sources/XPCActors/Session.swift
import Distributed
import Foundation

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
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class Session: SessionCoding, OutboundSession, InboundSession, @unchecked Sendable {

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

    /// Where this session speaks. Apple reaches it through `Session.Kind.xpc(Transport)`.
    ///
    /// **Not modelled as a `Kind` enum, deliberately.** Apple's `Kind` is
    /// `xpc(Transport) | local(LocalSessionState)` and every consumer of it is a branch
    /// on the tag bit -- `transport`, `local`, `isCancelled`, `optimizeSelfIPC`,
    /// `updatePeerSession`, `activateTransport`. The `.local` case is an entire
    /// subsystem (a peer session, a direct-invocation path that never encodes anything,
    /// `LocalSessionState`'s own cancellation fuse) and none of it exists here. A
    /// one-case enum would model no choice, give nothing to branch on, and make
    /// `Session.transport` a trapping accessor for a trap that cannot fire. When the
    /// in-process path lands, this becomes the `Kind` it is then actually a case of.
    private let transport: Transport

    /// Which actor system this session belongs to. See ``SessionCoding/systemID``.
    ///
    /// Now derived rather than stored: the previous slice stored an `ID64` beside a
    /// registry and noted that it "becomes `system.id` and stays honest" once a session
    /// is handed a system. It is that now, so the two can no longer disagree.
    var systemID: ID64 { system.id }

    /// Where a local id is turned into the instance behind it -- the system's table, not
    /// one of our own. Apple's `addSharedActor` likewise calls
    /// `XPCSystem.resolve(id: RawActorID.Local)` on `session.actorSystem`.
    private var registry: ActorRegistry<Void> { system.registry }

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
    }

    /// One lock over the whole of the mutable state, taken by both directions of the
    /// table and by the id counter. Apple uses a `Mutex` around `sharedActors` alone and
    /// a separate atomic `ID64.Generator`; folding the counter under the same lock costs
    /// nothing here -- every mint already takes the lock -- and makes "the key is unique
    /// *and* the table records it" a single critical section rather than two.
    ///
    /// `NSLock` rather than `Synchronization.Mutex` to keep the deployment floor where
    /// the rest of the module puts it, and to match `ActorRegistry`.
    private let lock = NSLock()

    /// key -> actor. The direction the decode path reads, so it is a direct lookup.
    private var byKey: [SharedActorKey: SharedActor] = [:]

    /// actor -> key. Apple has no such map -- which is exactly why Apple cannot dedupe.
    /// See ``shareDynamically(_:)``.
    private var keyForLocal: [RawActorID.Local: SharedActorKey] = [:]

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
    private var lastID: UInt64 = 0

    private var isCancelled = false

    /// `fileprivate`: sessions come from ``XPCActorSystem/makeSession(over:)``, which is
    /// at the bottom of this file. (`private` would not reach it -- Swift extends
    /// `private` to extensions of *the same type* in the same file, and the vending
    /// method is an extension of the system.)
    fileprivate init(system: XPCActorSystem, transport: Transport) {
        self.system = system
        self.transport = transport
        // Weakly, as Apple's initialiser does it (`swift_unknownObjectWeakAssign` into
        // `transport+0x10`). We hold the transport; it must not hold us back.
        transport.install(inboundSession: self)
    }

    /// How many actors this session currently exports.
    var sharedActorCount: Int { lock.withLock { byKey.count } }

    /// The next number from the session's generator. Callers hold ``lock``.
    private func nextID() -> ID64 {
        lastID += 1
        return ID64(rawValue: lastID)
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
            let key = SharedActorKey.dynamic(nextID())
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
    /// table holds; the caller that will need the stronger type is the one that also
    /// needs the invocation thunk.
    func resolveSharedActor(at key: SharedActorKey) -> AnyObject? {
        lock.withLock { byKey[key]?.instance }
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
    func sendInvocation<Res: Codable>(
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

        let request = invocation.makeRequest(
            id: lock.withLock { nextID() },
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
    /// Apple's is two entries -- their session key and
    /// `Distributed.CodingUserInfoKey.actorSystemKey`. Ours is one, because our
    /// `ActorID` coding reaches the system *through* the session (`systemID`) and never
    /// looks the system up separately.
    private var userInfo: [CodingUserInfoKey: Any] { [.xpcActorSession: self] }

    // MARK: - Cancellation

    /// The transport died. Apple's `InboundSessionProtocol` witness.
    ///
    /// Apple's is 40 bytes: `cancelAllPendingInvocationExecutionTasks()` then
    /// `cancellationCompleted()`. The first half is the *inbound* execution tasks -- work
    /// this process started on the peer's behalf -- and there is none of that yet, so
    /// only the second half exists here.
    ///
    /// Note what this is not responsible for: the requests *we* have outstanding. The
    /// transport fails those itself, through `RequestTable.failAll`, and it stays failed
    /// so a caller arriving afterwards is refused rather than parked forever.
    func handleTransportCancellation() {
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
        lock.withLock {
            isCancelled = true
            byKey.removeAll()
            keyForLocal.removeAll()
        }
    }
}

// ===========================================================================================
// MARK: - The system vends sessions
// ===========================================================================================

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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
    func makeSession(over transport: Transport) -> Session {
        Session(system: self, transport: transport)
    }
}
