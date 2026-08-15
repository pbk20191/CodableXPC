import Distributed

// ===========================================================================================
// MARK: - The two faces of a session
// ===========================================================================================

/// Apple splits a `Session` into two one-word structs -- `Session.LocalInterface` and
/// `Session.RemoteInterface` -- and hands callers one or the other rather than the session
/// itself. It is not decoration. The split is a capability boundary:
///
/// - a **local** interface can *export* actors and decide when this side starts answering,
/// - a **remote** interface can *import* actors and ask questions about the peer,
///
/// and no API hands out both at once. A service's peer handler is given a `LocalInterface`
/// (`__owned`, so it is consumed) and gets a `RemoteInterface` only by calling
/// `activateThenWithRemoteInterface`, which is what makes "activate before you call back"
/// structural instead of documented. A client's `makeRemoteInterface(to:)` returns only the
/// remote face, so a client cannot accidentally export.
///
/// [refl] Both are `struct { let session: Session }` -- one field, so a retain.
/// [sym] `LocalInterface.init(session:)` 0x2ad507a70 (`__shared`, i.e. `borrowing`);
///       `RemoteInterface.init(session:)` 0x2ad507a68.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension Session {

    /// [sym] `Session.local.getter` -- "a one-word struct, so this is just a retain".
    public var local: LocalInterface { LocalInterface(session: self) }

    /// [sym] `Session.remote.getter`.
    public var remote: RemoteInterface { RemoteInterface(session: self) }

    // =======================================================================================
    // MARK: LocalInterface
    // =======================================================================================

    /// What this side offers the peer.
    public struct LocalInterface {

        let session: Session

        init(session: Session) { self.session = session }

        // ---------------------------------------------------------------------------------
        // MARK: Exporting
        // ---------------------------------------------------------------------------------

        /// Export `actor` under a well-known name.
        ///
        /// [sym] 0x2ad509878 -- mints `.exportedRawValue(name)`.
        ///
        /// The name is the whole bootstrap. A `.dynamic` key means nothing to a peer that has
        /// not already been handed one, so *something* must be nameable before the first
        /// call; this is that something, and ``RemoteInterface/import(clientActorFor:)`` is
        /// the other end of it.
        ///
        /// **Traps on a proxy, as Apple does.** Both of Apple's `export` overloads read
        /// `actor.id` and trap when it is `.remote`, with `"API violation: Remote proxy
        /// cannot be shared!"` from `Session.swift`. Re-exporting a proxy would offer the
        /// peer an actor that lives in a third process under *our* key, and every later
        /// invocation on it would resolve here and fail. It is a programming error, not a
        /// runtime condition, and it is the caller's own object -- so it traps rather than
        /// throwing.
        public func export<A: DistributedActor>(_ actor: A, asServerActorFor name: String)
        where A.ActorSystem == XPCActorSystem {
            share(actor, at: .exportedRawValue(name), what: "server actor \"\(name)\"")
        }

        /// Export `actor` as the default instance behind a `@Resolvable` protocol's stub.
        ///
        /// [sym] 0x2ad509790 -- mints `.exported(SwiftType(B.self))`.
        ///
        /// The key is the **stub** type's mangled name, not the concrete actor's, which is
        /// what makes the pair work across a process boundary: the service knows the concrete
        /// type and the client does not, but both link the protocol module and so both can
        /// name `$Greeter`. ``RemoteInterface/import(defaultActorFor:)`` mints the same key
        /// from the same type.
        ///
        /// `_DistributedActorStub` is macOS 15+, narrower than this file's macOS-14 floor, so
        /// the stub-keyed overloads carry their own availability rather than raising everyone
        /// else's -- the same split `XPCRawTransport.connecting(to:)` makes for `XPCEndpoint`.
        @available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
        public func export<A: DistributedActor, B: Distributed._DistributedActorStub>(
            _ actor: A, asDefaultActorFor stub: B.Type
        ) where A.ActorSystem == XPCActorSystem, B.ActorSystem == XPCActorSystem {
            guard let type = SwiftType(stub) else {
                // `SwiftType.init?` fails when the mangled name does not round-trip back to
                // the same type -- a local or private type, most often. Such a type cannot be
                // named on the wire at all, so exporting it would produce a key the peer can
                // never mint. Loud, at the export, rather than a call that mysteriously finds
                // nothing later.
                preconditionFailure(
                    "Cannot export as the default actor for \(stub): its mangled name does "
                    + "not round-trip, so no peer could name it. Stub protocols must be "
                    + "declared at file scope or above.")
            }
            share(actor, at: .exported(type), what: "default actor for \(stub)")
        }

        private func share<A: DistributedActor>(
            _ actor: A, at key: SharedActorKey, what: String
        ) where A.ActorSystem == XPCActorSystem {
            guard case .local(let local) = actor.id.raw else {
                preconditionFailure("API violation: Remote proxy cannot be shared!")
            }
            switch session.addSharedActor(local, at: key) {
            case .shared:
                return
            case .notRegistered:
                // API misuse, and the quiet kind: the actor is not in the system's registry,
                // so it was never `actorReady` or is already gone. Exporting it would leave a
                // service that accepts connections and answers nothing -- a failure that
                // otherwise surfaces one process away, at the client's first call, as
                // "nothing is shared at that key". Trap here instead, where the mistake is.
                preconditionFailure(
                    "Cannot export \(what): the actor is not registered with its system. It "
                    + "was either deallocated already or never became ready.")
            case .sessionCancelled:
                // A race, not misuse -- the peer hung up while we were still setting up. There
                // is nobody left to export *to*, so there is nothing to report and nothing to
                // fix; the handler's next step will find the session cancelled anyway.
                return
            }
        }

        // ---------------------------------------------------------------------------------
        // MARK: Activation
        // ---------------------------------------------------------------------------------

        /// Start answering, then park until the peer hangs up.
        ///
        /// [sym] 0x2ad509e54, returning the labelled tuple `(result: (), token:
        /// ActivationToken)`.
        ///
        /// This is the shape a service's peer handler ends in, and the ordering is the point:
        /// every `export` above happens *before* activation, and an inbound request that
        /// arrives first parks in `waitForLocalInterfaceActivation()` rather than failing to
        /// resolve. Without the gate a client that is quick off the mark races the service's
        /// own setup -- an ordering hazard that in-process tests never hit because they
        /// register before they send.
        ///
        /// The returned token is a receipt: `TransportReceiver` types its peer handler to
        /// return one, so a handler that never activated cannot typecheck.
        @discardableResult
        public func activateThenWaitForCancellation() async
        -> (result: (), token: ActivationToken) {
            session.activateLocalInterface()
            await session.waitForCancellation()
            return (result: (), token: ActivationToken(id: session.id))
        }

        /// Activate, run `perform` with the peer-facing half, then hand back both.
        ///
        /// [sym] 0x2ad50a1f4. The bidirectional shape: a service that wants to call *back*
        /// into its client gets the remote interface only here, on the far side of
        /// activation.
        @discardableResult
        public func activateThenWithRemoteInterface<A: Sendable>(
            perform: (RemoteInterface) async -> A
        ) async -> (result: A, token: ActivationToken) {
            session.activateLocalInterface()
            let value = await perform(session.remote)
            return (result: value, token: ActivationToken(id: session.id))
        }

        /// Give up without ever answering.
        ///
        /// [sym] [disasm @0x2ad50af24] -- appends the reason, calls `Session.cancel(because:)`,
        /// and still hands back a token, because the handler's return type demands one.
        @discardableResult
        public func cancelWithoutActivating(because reason: String)
        -> (result: (), token: ActivationToken) {
            session.cancel(because: "Local interface was cancelled without activating: \(reason)")
            return (result: (), token: ActivationToken(id: session.id))
        }

        // ---------------------------------------------------------------------------------
        // MARK: ActivationToken
        // ---------------------------------------------------------------------------------

        /// A receipt that a local interface was activated (or deliberately was not).
        ///
        /// [fieldmd] one field, `id: ID64`. Conformances from their own descriptors:
        /// `Hashable`, `Encodable`, `Decodable`, with keyed coding.
        ///
        /// **It does not cross the wire**, and why it is `Codable` at all is unresolved --
        /// recorded here so the declaration is not misread as a wire type. It is repeated
        /// from the reconstruction rather than re-derived.
        public struct ActivationToken: Hashable, Codable, Sendable {

            public let id: ID64

            private enum CodingKeys: String, CodingKey {
                case id
            }

            public init(id: ID64) { self.id = id }
        }
    }

    // =======================================================================================
    // MARK: RemoteInterface
    // =======================================================================================

    /// What the peer offers this side.
    public struct RemoteInterface {

        let session: Session

        init(session: Session) { self.session = session }

        /// A proxy for the actor the peer exported under `name`.
        ///
        /// [sym] 0x2ad509684 -- key is `.exportedRawValue(name)`, wrapped in
        /// `RawActorID.Remote(session:key:)` and handed to `DistributedActor.resolve(id:using:)`.
        ///
        /// **Nothing is checked here, and nothing can be.** No message is sent: this mints an
        /// id and resolves it, so a name the peer never exported produces a perfectly good
        /// proxy whose first call fails. That is Apple's behaviour and it is forced by the
        /// protocol -- there is no "does this key exist" request on the wire -- so the failure
        /// belongs at the call, where it is answerable, rather than in a lookup that would
        /// have to invent one.
        ///
        /// `try!` is not laziness. ``XPCActorSystem/resolve(id:as:)`` throws on exactly one
        /// condition, a remote id whose session belongs to a *different* system, and the id
        /// here is minted from this session against this session's own system one line above.
        /// Apple's signature is non-throwing for the same reason.
        public func `import`<A: DistributedActor>(clientActorFor name: String) -> A
        where A.ActorSystem == XPCActorSystem {
            proxy(at: .exportedRawValue(name))
        }

        /// A proxy for the actor the peer exported as the default instance behind `stub`.
        ///
        /// [sym] 0x2ad50957c -- key is `.exported(SwiftType(A.self))`, the same type the
        /// exporting side named.
        ///
        /// `_DistributedActorStub` is macOS 15+, narrower than this file's macOS-14 floor, so
        /// the stub-keyed overloads carry their own availability rather than raising everyone
        /// else's -- the same split `XPCRawTransport.connecting(to:)` makes for `XPCEndpoint`.
        @available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
        public func `import`<A: Distributed._DistributedActorStub>(defaultActorFor stub: A.Type) -> A
        where A.ActorSystem == XPCActorSystem {
            guard let type = SwiftType(stub) else {
                preconditionFailure(
                    "Cannot import the default actor for \(stub): its mangled name does not "
                    + "round-trip, so it cannot name anything the peer exported.")
            }
            return proxy(at: .exported(type))
        }

        private func proxy<A: DistributedActor>(at key: SharedActorKey) -> A
        where A.ActorSystem == XPCActorSystem {
            let id = session.remoteID(for: key)
            return try! A.resolve(id: id, using: session.system)
        }

        // ---------------------------------------------------------------------------------
        // MARK: Asking about the peer
        // ---------------------------------------------------------------------------------

        /// Does the peer satisfy `requirement`?
        ///
        /// [sym] [disasm @0x2ad50b298] -- `nil` when the audit token is unavailable, otherwise
        /// the answer.
        ///
        /// **The double optionality is the point**: "we could not tell" is a different answer
        /// from "no", and collapsing them is how a gate comes to fail open. A caller that
        /// treats `nil` as `false` is refusing on ignorance, which is usually right; one that
        /// treats it as `true` has no gate at all.
        public func satisfies(requirement: PeerRequirement) -> Bool? {
            guard let attestation = session.peerAttestation else { return nil }
            return attestation.satisfies(requirement)
        }
    }
}
