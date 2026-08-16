import Distributed

// ===========================================================================================
// MARK: - ActorReference
// ===========================================================================================

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCActorSystem {

    /// Apple's `XPCSystem.ActorReference<A>` -- a typed, `Codable` reference to a distributed
    /// actor. Hand one to a peer inside an ordinary `Codable` message and the peer
    /// ``resolve()``s it back to a proxy, without the actor having to be a `remoteCall`
    /// argument. The typed counterpart of encoding a bare ``ActorID``.
    ///
    /// [refl] Two stored fields, `id: ActorID` and `actor: any DistributedActor`; [sym] a
    /// custom `encode(to:)`/`init(from:)` with **no `CodingKeys`**, so the coding is a
    /// *single value* -- the `id`, nothing else (the actor cannot cross). On the wire an
    /// `ActorReference<A>` is therefore byte-identical to an `ActorID`, which is what lets it
    /// interoperate with a peer that resolves the same id.
    public struct ActorReference<A: DistributedActor>: Codable
    where A.ActorSystem == XPCActorSystem {

        /// The referenced actor's id. On the sending side it is the actor's own; decoded on the
        /// receiving side it is the *remote* id ``ActorID/init(from:)`` translates it into.
        public let id: ActorID

        /// The actor itself: the concrete instance on the sending side, the resolved proxy on
        /// the receiving side. [sym] `actor.getter : Distributed.DistributedActor`.
        public let actor: any DistributedActor

        /// Apple's `init<Act>(_: Act, as: A.Type)`: reference `actor`, viewed as `A`. The
        /// concrete `Act` and the reference type `A` can differ (reference a concrete actor as a
        /// protocol it conforms to); both live in an ``XPCActorSystem``.
        public init<Act: DistributedActor>(_ actor: Act, as: A.Type)
        where Act.ActorSystem == XPCActorSystem {
            self.actor = actor
            self.id = actor.id
        }

        /// Single value: the `id`. `ActorID.encode(to:)` does the local-actor bookkeeping
        /// (sharing it on the session in `userInfo`), so a reference sent to a peer names an
        /// actor the peer can reach back to.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(id)
        }

        /// Read the `id` (a single value) and resolve it against the session's system, so
        /// ``resolve()`` hands back a live proxy. The session travels in `userInfo` under
        /// ``CodingUserInfoKey/xpcActorSession``, the same key ``ActorID`` decodes through.
        public init(from decoder: any Decoder) throws {
            guard let session = decoder.userInfo[.xpcActorSession] as? Session else {
                throw SetupError("""
                    decoding an ActorReference needs a Session under \
                    CodingUserInfoKey.xpcActorSession
                    """)
            }
            let id = try decoder.singleValueContainer().decode(ActorID.self)
            self.id = id
            do {
                self.actor = try A.resolve(id: id, using: session.system)
            } catch {
                throw SetupError("could not resolve the referenced actor \(id): \(error)")
            }
        }

        /// The referenced actor as `A`. Apple's `resolve() -> A`. A cast: the stored actor is
        /// the concrete instance (sending side) or the proxy `init(from:)` resolved (receiving
        /// side), and both are an `A`.
        public func resolve() -> A {
            guard let typed = actor as? A else {
                preconditionFailure(
                    "ActorReference<\(A.self)> holds a \(type(of: actor)), which is not \(A.self)")
            }
            return typed
        }
    }
}
