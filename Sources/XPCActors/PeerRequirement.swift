// Sources/XPCActors/PeerRequirement.swift
import Distributed
import Foundation
#if canImport(XPC)
import XPC
#endif

// ===========================================================================================
// MARK: - What a peer has to prove
// ===========================================================================================

/// Something the process at the far end of a transport must be able to prove about itself.
///
/// Apple's is `XPC.XPCPeerRequirement`, a struct in the *XPC Swift overlay* — not in
/// `XPCDistributed`. It is `macOS 26+` and **unavailable on iOS, tvOS and watchOS**, while
/// this module's floor is macOS 14 / iOS 17, so it cannot be a stored property here and it
/// cannot be the only shape a requirement takes.
///
/// So this type is a two-part thing, and the split is not cosmetic:
///
/// - a `description`, which is what a transport that attests by some other means keys on;
/// - an optional `XPCPeerRequirement`, which is what an *audit-token* attestation evaluates
///   with Apple's own `audit_token_t.satisfies(requirement:)`.
///
/// The evaluation lives on the transport (``PeerAttestation``), because the transport is the
/// only layer that knows who the peer is. That is Apple's arrangement too:
/// `RawTransportProtocol.auditToken` → `Session.RemoteInterface.auditToken` →
/// `audit_token_t.satisfies(requirement:)`.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct PeerRequirement: Sendable, CustomStringConvertible {

    /// What this requirement is, in words. Stable, and the only thing a non-token
    /// attestation has to go on.
    public let description: String

    /// The overlay requirement, boxed because its type is `macOS 26+` and macOS-only and a
    /// stored property cannot carry that availability. `nil` for a requirement built by
    /// ``init(_:)``.
    private let box: (any Sendable)?

    /// A requirement named but not expressed in overlay terms.
    ///
    /// Useful for a transport that attests some other way. An ``AuditTokenAttestation``
    /// **refuses** one of these — it has nothing to evaluate — rather than admitting it,
    /// which is the whole point: a requirement a checker cannot express must not read as
    /// satisfied.
    public init(_ description: String) {
        self.description = description
        self.box = nil
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    /// The real thing: an overlay requirement, evaluated by Apple's own checker.
    @available(macOS 26, macCatalyst 26, *)
    public init(_ requirement: XPCPeerRequirement, describedAs description: String) {
        self.description = description
        self.box = requirement
    }

    /// The overlay requirement this stands for, if it was built from one.
    @available(macOS 26, macCatalyst 26, *)
    public var xpcRequirement: XPCPeerRequirement? { box as? XPCPeerRequirement }
    #endif
}

// ===========================================================================================
// MARK: - Who can answer
// ===========================================================================================

/// What a transport can say about the process on the other end.
///
/// **Three-valued on purpose.** Apple's `Session.RemoteInterface.satisfies(requirement:)`
/// returns `Bool?` and the reconstruction says why in one line: *"The double optionality is
/// the point: 'unknown' is distinct from 'no'."* A transport with no attestation at all
/// returns `nil` from this, and every gate in ``Session`` folds `nil` into **refuse** — but
/// it folds it there, deliberately, rather than losing the distinction here.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public protocol PeerAttestation: Sendable {

    /// `true` / `false` / `nil` — satisfied, not satisfied, cannot tell.
    func satisfies(_ requirement: PeerRequirement) -> Bool?
}

#if os(macOS) || targetEnvironment(macCatalyst)

// ===========================================================================================
// MARK: - The real one
// ===========================================================================================

/// A peer identified by its Mach audit token, checked with Apple's own checker.
///
/// This is Apple's shape exactly: hold the 32-byte token, and answer any number of
/// questions about it later, on whatever task happens to ask. The token is a POD, so
/// unlike a received *message* it can be stored and re-interrogated — which is what the
/// per-actor gate needs, because that gate runs after an `await`.
///
/// **The `@available` below is load-bearing, not documentation.** It is the only thing
/// keeping the bridged `libswiftXPC` symbols off an OS that does not export them: they link
/// *weakly* in this package's artifacts, so a missing one binds to zero rather than failing
/// at launch. See the bridge section at the bottom of this file.
@available(macOS 26, macCatalyst 26, *)
public struct AuditTokenAttestation: PeerAttestation {

    /// The peer's token. `nil` is not representable: an invalid token is not an
    /// attestation, so ``init(_:)`` refuses one.
    public let token: audit_token_t

    /// `nil` when the token is not valid, which is Apple's own test —
    /// `Transport.XPCRawTransport.auditToken` reads `session.auditToken`, applies
    /// `audit_token_t.isValid`, and returns `nil` when it fails.
    ///
    /// The distinction matters: a dictionary that never crossed a connection reports an
    /// all-ones token that `satisfies` cheerfully answers `false` to. Answering `false`
    /// would say "this peer is not entitled"; the truth is "there is no peer here", which
    /// is `nil`.
    public init?(_ token: audit_token_t) {
        guard token.xpcBridgedIsValid() else { return nil }
        self.token = token
    }

    /// Apple's `audit_token_t.satisfies(requirement:)`, reached through the bridge below.
    ///
    /// A ``PeerRequirement`` with no overlay requirement inside it returns `nil` —
    /// "cannot tell" — because this checker genuinely cannot express it. It does **not**
    /// return `true`.
    public func satisfies(_ requirement: PeerRequirement) -> Bool? {
        guard let xpc = requirement.xpcRequirement else { return nil }
        return token.xpcBridgedSatisfies(requirement: xpc)
    }
}

// ===========================================================================================
// MARK: - The bridge to the overlay's unpublished half
// ===========================================================================================
//
// **The overlay has everything the check needs; it just does not declare it.**
//
// `XPC.swiftinterface` publishes exactly one peer-attestation primitive,
// `XPCReceivedMessage.senderSatisfies(_:)`, and that one is useless to us: taking the
// `XPCReceivedMessage` incoming-message-handler variant costs us the raw `XPCDictionary`
// (`XPCReceivedMessage` exposes only `decode<T: Decodable>(as:)`, and `XPCDictionary` is
// not `Decodable`), and `Packet(rawValue:)` needs the raw `xpc_object_t`. It is also
// message-scoped, where the per-actor gate runs after an `await`.
//
// But `libswiftXPC.tbd` — the SDK's own linker stub, not a runtime-only symbol — exports
// all four of the declarations Apple's `XPCDistributed` actually uses:
//
//     XPC.XPCSession.auditToken.getter          : __C.audit_token_t
//     XPC.XPCDictionary.auditToken.getter       : __C.audit_token_t
//     (extension in XPC):__C.audit_token_t.isValid.getter : Swift.Bool
//     (extension in XPC):__C.audit_token_t.satisfies(requirement: XPCPeerRequirement) -> Bool
//
// So the answer to "does the overlay give us what the peer check needs" is **yes**, with
// the same technique `XPCOverlayCoder.AppleCoderBridge` already uses for
// `XPCReceivedMessage.init(dictionary:)`, and on a firmer footing than that one: these are
// in the `.tbd`, so the *linker* binds them and there is no address to guess.
//
// **Why `@_silgen_name` and not `dlsym`.** `dlsym` is not available for these: they are
// methods, so their lowered convention passes `self` in the Swift self register, and
// `@convention(method)` is not spellable in Swift (`error: convention 'method' not
// supported`, measured) — `unsafeBitCast` to `@convention(thin)` would pass `self` in `x0`
// and the call would be wrong. `@_silgen_name` on a body-less method declaration is what
// makes the compiler emit the right convention. That is the whole of the reason.
//
// **What the linkage actually does, measured rather than assumed.** An earlier revision of
// this comment argued that these are security-critical, so a loud launch-time `dyld` failure
// on an OS that dropped them beats silent degradation. That argument is wrong about the
// facts. `nm -m` on this package's own artifacts reports all four as **weak external**
// undefined references, in the per-file objects and in the final linked test bundle:
//
//     (undefined) weak external _$sSo13audit_token_ta3XPCE9satisfies11requirementSbAC…_tF (from libswiftXPC)
//
// so a missing symbol binds to **zero** and the first call branches to null. There is no
// launch-time failure to rely on. And the weakness is not something this source asks for:
// standalone `swiftc` of the identical declarations — with and without `@available`, with
// and without `-wmo -enable-library-evolution` — yields strong `external` every time. It is
// an artifact of how this package is built, which means a build-configuration change could
// silently flip these to strong references in a package whose floor is 10.13. That is the
// exact hazard `Package.swift`'s own `libswiftSystem` comment exists to prevent.
//
// **So what actually keeps this safe is the `#available(macOS 26)` guards, and nothing
// else.** Every call site is behind one, and all four symbols exist in `libswiftXPC.tbd` on
// every OS that satisfies it. The guards are marked as load-bearing at each site. If a loud
// failure is ever wanted here it has to be an explicit runtime null check, not a claim about
// what `dyld` will do.
//
// Each declaration below repeats the demangled signature it binds to, so a mismatch is
// visible without a demangler.

@available(macOS 26, macCatalyst 26, *)
extension audit_token_t {

    /// `(extension in XPC):__C.audit_token_t.satisfies(requirement: XPC.XPCPeerRequirement)
    /// -> Swift.Bool`
    @_silgen_name("$sSo13audit_token_ta3XPCE9satisfies11requirementSbAC18XPCPeerRequirementV_tF")
    func xpcBridgedSatisfies(requirement: XPCPeerRequirement) -> Bool

    /// `(extension in XPC):__C.audit_token_t.isValid.getter : Swift.Bool`
    @_silgen_name("$sSo13audit_token_ta3XPCE7isValidSbvg")
    func xpcBridgedIsValid() -> Bool
}

@available(macOS 26, macCatalyst 26, *)
extension XPCSession {

    /// `XPC.XPCSession.auditToken.getter : __C.audit_token_t`
    @_silgen_name("$s3XPC10XPCSessionC10auditTokenSo0C8_token_tavg")
    func xpcBridgedAuditToken() -> audit_token_t
}

@available(macOS 26, macCatalyst 26, *)
extension XPCDictionary {

    /// `XPC.XPCDictionary.auditToken.getter : __C.audit_token_t`
    ///
    /// The per-*message* token, for a transport that would rather attest to the sender of
    /// the bytes in hand than to the connection. Unused by ``XPCRawTransport``, which takes
    /// the connection-level token as Apple's `XPCRawTransport.auditToken` does; kept
    /// because it is the symbol that makes the two readings distinguishable, and a test
    /// pins that a dictionary which never crossed a connection has **no** valid token.
    @_silgen_name("$s3XPC13XPCDictionaryV10auditTokenSo0C8_token_tavg")
    func xpcBridgedAuditToken() -> audit_token_t
}

#endif

// ===========================================================================================
// MARK: - RestrictedAccessDistributedActor
// ===========================================================================================

/// A distributed actor that will not answer a peer it has not vetted itself.
///
/// Apple's `XPCSystem.RestrictedAccessDistributedActor`, read out of protocol descriptor
/// `0x2ad527dd8`: `NumRequirements = 2`, of which requirement 0 is the base conformance to
/// `DistributedActor` and requirement 1 is a get-only instance property
/// `peerRequirement.getter : XPC.XPCPeerRequirement` — **non-optional**, unlike
/// ``XPCActorSystem/peerRequirement``. The signature carries `Self.ActorSystem == XPCSystem`.
///
/// Two deliberate differences, both forced:
///
/// - **Not nested.** Apple's mangled name is
///   `$s14XPCDistributed9XPCSystemC32RestrictedAccessDistributedActorP`, i.e. nested inside
///   the class. Swift does not allow a protocol nested in a type.
/// - **`nonisolated`.** The inbound path reads this property *synchronously*, out of the
///   witness table `swift_conformsToProtocol2` returns, with no `await` — so Apple's is
///   nonisolated whether or not their source says the word. An isolated one could not be
///   read from the gate at all.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public protocol RestrictedAccessDistributedActor: DistributedActor
where ActorSystem == XPCActorSystem {

    /// What a peer must prove before this actor will run anything for it.
    nonisolated var peerRequirement: PeerRequirement { get }
}
