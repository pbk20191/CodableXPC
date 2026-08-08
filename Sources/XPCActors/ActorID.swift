// Sources/XPCActors/ActorID.swift
import Foundation

/// Where an `ActorID` finds the session it needs in order to code itself.
///
/// This exists to break a cycle: `ActorID` needs a session, and `Session` is built on
/// `ActorID`. Naming only the two operations identity needs also keeps `Distributed`
/// out of this file, and lets identity be tested with no transport at all.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public protocol SessionCoding: AnyObject, Sendable {
    /// Make a local actor reachable to the peer and return the key naming it.
    /// `nil` when the actor is not registered -- it was deallocated, or was never ready.
    func shareDynamically(_ local: RawActorID.Local) -> SharedActorKey?

    /// The id our side uses for an actor the peer named.
    func remoteID(for key: SharedActorKey) -> ActorID
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension CodingUserInfoKey {
    /// The `SessionCoding` an `ActorID` codes itself against.
    public static let xpcActorSession = CodingUserInfoKey(rawValue: "XPCActors.session")!
}

/// A process-local identifier.
///
/// Drawn from a process-global monotonic counter -- neither random nor pid-derived,
/// and it never needs to be unique across processes, because it is never transmitted.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct ID64: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Apple's own `ID64` names its stored field `value` on the wire; ours is spelled
    /// `rawValue` in Swift, so the wire key is remapped rather than the property --
    /// renaming the property would ripple through every call site for no wire benefit.
    private enum CodingKeys: String, CodingKey {
        case rawValue = "value"
    }

    private static let counter = ManagedAtomicCounter()
    public static func next() -> ID64 { ID64(rawValue: counter.next()) }

    public var description: String { "\(rawValue)" }
}

/// A monotonic counter. `OSAllocatedUnfairLock` rather than an atomics package so the
/// target keeps its single dependency on `CodableXPC`.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 {
        lock.withLock {
            value += 1
            return value
        }
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct ActorID: Hashable, @unchecked Sendable {
    public let raw: RawActorID
    public init(raw: RawActorID) { self.raw = raw }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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
        case .remote(let remote):
            // Send the peer's own key back. Sharing it into this session would mint a
            // second name for an actor that already has one.
            key = remote.key
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
