// Sources/XPCActors/ActorID.swift
import Foundation
import Synchronization

/// Where an `ActorID` finds the session it needs in order to code itself.
///
/// This exists to break a cycle: `ActorID` needs a session, and `Session` is built on
/// `ActorID`. Naming only the two operations identity needs also keeps `Distributed`
/// out of this file, and lets identity be tested with no transport at all.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public protocol SessionCoding: AnyObject, Sendable {
    /// Make a local actor reachable to the peer and return the key naming it.
    /// `nil` when the actor is not registered -- it was deallocated, or was never ready.
    func shareDynamically(_ local: RawActorID.Local) -> SharedActorKey?

    /// The id our side uses for an actor the peer named.
    func remoteID(for key: SharedActorKey) -> ActorID

    /// Which actor system this session belongs to.
    ///
    /// This is Apple's `OutboundSessionProtocol.actorSystem` -- one of only *two*
    /// requirements that protocol has, the other being `sendInvocation` -- so adding it
    /// here moves `SessionCoding` towards Apple's shape rather than away from it. It is
    /// the slot `RawActorID.Remote.belongsTo(actorSystem:)` calls through, and its one
    /// job is `XPCActorSystem.resolve(id:as:)`'s third branch: a `.remote` id reached
    /// through a session belonging to some *other* system must not resolve here.
    ///
    /// **An `ID64` rather than the system itself**, where Apple compares object
    /// pointers. Three reasons, in order of weight:
    ///
    /// - The comparison is as strong **for every conformer in this package**. `ID64`
    ///   comes from a monotonic process-global counter that is never recycled, and the
    ///   comparison is always within one process -- a `.remote`'s session is an object
    ///   in *this* process -- so equal ids and identical systems coincide.
    ///
    ///   It is **not** as strong in general, and an earlier revision of this comment
    ///   claimed it was. `ID64.init(rawValue:)` and `XPCActorSystem.id` are both public,
    ///   so a `SessionCoding` conformer outside this package could return a system id it
    ///   guessed, without ever holding the system. Apple's `===` needs the object. This
    ///   costs nothing today -- a `.remote`'s session is an in-process object a peer
    ///   never chooses, so this is not a boundary against a peer -- but it is a weaker
    ///   relation and should be described as one.
    /// - `Session` is generic over its thunk while the system is concrete, so a stored
    ///   `XPCActorSystem` on a `Session<Int>` would be a type-level lie: the session's
    ///   registry need not be that system's registry. The generic collapses when a
    ///   session is handed a system instead of a registry, and at that point this
    ///   becomes `system.id` and stays honest.
    /// - It keeps the identity layer free of the system: this file is deliberately
    ///   buildable and testable with no `Distributed`, no transport and no system at
    ///   all, which is why `SessionCoding` exists in the first place.
    var systemID: ID64 { get }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension CodingUserInfoKey {
    /// The `SessionCoding` an `ActorID` codes itself against.
    ///
    /// The raw value is Apple's own -- `"com.apple.xpc.distributed/Session"`, read out of the
    /// `XPCDistributed` binary's `__cstring` (in the session/userInfo cluster, next to the
    /// `"Bug in XPCDistributed: Session required in user info dictionary"` trap that reads it
    /// back). It never crosses the wire -- it only names the slot the session travels in through
    /// the coder's `userInfo`, exactly as Apple threads it -- so matching the string is
    /// name-fidelity, not interop.
    public static let xpcActorSession =
        CodingUserInfoKey(rawValue: "com.apple.xpc.distributed/Session")!
}

/// A process-local identifier.
///
/// Drawn from a process-global monotonic counter -- neither random nor pid-derived,
/// and it never needs to be unique across processes, because it is never transmitted.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public struct ID64: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    // A bare `UInt64` on the wire -- not `{ "value": n }`, and not the `{ "rawValue": n }`
    // the synthesized conformance would emit. Apple's `ID64.encode(to:)` opens a
    // `singleValueContainer()` and calls the `encode(Swift.UInt64)` thunk; there is no
    // `ID64.CodingKeys` in the shipping binary, so no key name is transmitted at all and
    // the Swift spelling of the property is free to differ. Reproduce with
    // `xpcdump/macos27-XPCDistributed/verify-containers.py`.
    //
    // Written by hand rather than synthesized precisely so that renaming the property
    // can never silently change the wire.

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }

    /// A monotonic id source. `Synchronization.Atomic` now that the floor is macOS 26 --
    /// the increment is a single atomic, no lock.
    private static let counter = Atomic<UInt64>(0)
    public static func next() -> ID64 {
        ID64(rawValue: counter.wrappingAdd(1, ordering: .relaxed).newValue)
    }

    public var description: String { "\(rawValue)" }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public enum RawActorID: Hashable, @unchecked Sendable {

    case local(Local)
    case remote(Remote)

    /// An actor living in this process. Neither field is ever transmitted.
    public struct Local: Hashable, Sendable {
        public let systemID: ID64
        public let instanceID: ID64
        public init(systemID: ID64, instanceID: ID64) {
            self.systemID = systemID
            self.instanceID = instanceID
        }
    }

    /// An actor living in a peer, reachable only through the session that named it.
    public struct Remote: @unchecked Sendable {
        public let session: any SessionCoding
        public let key: SharedActorKey
        public init(session: any SessionCoding, key: SharedActorKey) {
            self.session = session
            self.key = key
        }
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension RawActorID.Remote: Hashable {
    /// The session is compared by identity: the same key reached through two different
    /// sessions names two different actors.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && ObjectIdentifier(lhs.session) == ObjectIdentifier(rhs.session)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(ObjectIdentifier(session))
    }
}

/// The `DistributedActorSystem.ActorID`.
///
/// Its `Codable` conformance is the load-bearing part of the design: what goes on the
/// wire is a `SharedActorKey` in a single-value container, never the id's own contents.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public struct ActorID: Hashable, @unchecked Sendable {
    public let raw: RawActorID
    public init(raw: RawActorID) { self.raw = raw }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension ActorID: Codable {

    public func encode(to encoder: any Encoder) throws {
        // A trap, not a throw. Encoding an actor reference with no session is a
        // programmer error at the call site -- the coder was built without the
        // userInfo this type documents as mandatory -- and reporting it as a decoding
        // failure on the peer would put the diagnosis in the wrong process.
        guard let session = encoder.userInfo[.xpcActorSession] as? any SessionCoding else {
            preconditionFailure("""
                encoding an ActorID needs a session under CodingUserInfoKey.xpcActorSession; \
                coding path \(encoder.codingPath)
                """)
        }
        let key: SharedActorKey
        switch raw {
        case .remote:
            // A proxy cannot be sent. This is Apple's rule -- `ActorID.encode(to:)`
            // in the shipping `XPCDistributed` traps here with "Cannot send remote
            // actor proxies over an session." -- and it is the rule that makes the
            // whole scheme sound, so we keep it.
            //
            // Why it has to be a rule and not a convenience: a `SharedActorKey` is
            // only meaningful in the key space of the side that minted it, and a
            // session's `dynamic` counter starts at 1 on *both* ends, so `.dynamic(1)`
            // names a different actor on each side with nothing on the wire to tell
            // them apart. Writing a proxy's key into any session therefore lies about
            // which actor it names -- whether that session is the one the key came
            // from (the peer would receive its own key back and resolve one of its own
            // actors) or a different one (the first session's key lands in the
            // second's namespace).
            //
            // We throw where Apple traps. This is reachable from a value shape a peer
            // influenced, and a `preconditionFailure` would kill whichever process
            // happens to be holding the proxy rather than reporting a bad call.
            //
            // The cost is real, and it is Apple's cost too: an actor reference
            // obtained from a peer cannot be handed back to that peer, nor forwarded
            // to a third. Lifting that is a feature with a prerequisite -- the two
            // `dynamic` key spaces must first be made attributable, by seeding each
            // session's generator randomly or partitioning it by role -- and not a
            // repair to this line.
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath,
                debugDescription: "cannot send a remote actor proxy over a session"))
        case .local(let local):
            guard let shared = session.shareDynamically(local) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "no live actor is registered for \(local)"))
            }
            key = shared
        }
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }

    public init(from decoder: any Decoder) throws {
        guard let session = decoder.userInfo[.xpcActorSession] as? any SessionCoding else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "decoding an ActorID needs a session under "
                    + "CodingUserInfoKey.xpcActorSession"))
        }
        let container = try decoder.singleValueContainer()
        self = session.remoteID(for: try container.decode(SharedActorKey.self))
    }
}
