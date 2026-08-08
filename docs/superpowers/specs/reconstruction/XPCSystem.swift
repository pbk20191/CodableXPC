// XPCSystem.swift -- reconstruction of Apple's `XPCDistributed` interface.
//
// Subsystem: the actor system and identity.
//
// Covers:
//   XPCSystem (the class, its stored properties, its initialisers, its public API surface,
//              and its full DistributedActorSystem + Internal.Identifiable conformances)
//   XPCSystem.ActorID
//   XPCSystem.RawActorID, .Local, .Remote
//   WeakActorRef                       (top-level, XPCDistributed.WeakActorRef)
//   XPCSystem.ActorReference<Stub>
//   XPCSystem.SetupError
//   XPCSystem.RemoteInvocationCancellationError, .Reason
//   XPCSystem.SharedActorKey, .WireCode
//   XPCSystem.RestrictedAccessDistributedActor
//   XPC.XPCPeerRequirement             (identified, not reconstructed -- it is Apple's XPC
//                                      overlay's type, not XPCDistributed's and not ours)
//
// Provenance vocabulary used in the doc comments below:
//   [SYM]   read out of a demangled Swift symbol's signature (symbols-demangled.txt).
//   [FIELD] read out of the Swift reflection field descriptors -- and, unless it says
//           otherwise, that means the *declared type* of the field, not just its name.
//           `field-descriptors.txt` has only the names because `extract.py` reads the third
//           word of each 12-byte field record and never the second. The second is a relative
//           pointer to the field's mangled type name; handing that address straight to
//           `swift_getTypeByMangledNameInContext` (which is the API those names exist for,
//           symbolic references and all) and then `swift_getTypeName` gives the type. Bit
//           0x2 of the record's flags is `IsVar`, so `let` versus `var` is in there too, and
//           a mangled name ending `Xw` is `weak`. Probe:
//           scratchpad/xpcsystem-fieldtypes.py. Every field type below was re-read that way
//           rather than inferred from a getter symbol.
//           A caveat that applies to every [FIELD] reading here: the field records give types,
//           mutability and ownership, but **not access level**, because the context descriptors
//           they point at carry no private discriminator. A `private` type reads as its bare
//           name. The access-level check is the symbol table, not this.
//
//           Two things about the reader that matter for trusting the types below.
//
//           *The memory guard.* Reads are guarded by `mincore()` + `MINCORE_INCORE`, not by
//           `dladdr()`. `dladdr()` is too strict and its failure mode is worse than a crash --
//           it returns 0 for the shared cache's coalesced `__AUTH_CONST` GOT slots that indirect
//           symbolic references point at, even though those slots read fine, so a rejected read
//           becomes a silent "this type has no fields." `LC_SEGMENT_64` vmaddr ranges fail the
//           same way: those slots sit outside every segment of the image referencing them. And
//           `write("/dev/null", addr, 1) == 1` is actively dangerous -- macOS does not validate
//           the buffer, so it returns 1 for address `0x1` and the guard accepts everything.
//           Measured here, in one differential run: for the GOT slot `0x2f2503b38`, mincore says
//           mapped and dladdr says no; for address `0x1` and for `0xdead000000000000`, mincore
//           says no and the `/dev/null` write says yes.
//
//           *Why that did not change any answer in this file.* This reader was re-run end to end
//           under the corrected guard and the output was **byte-identical** to the run the
//           declarations below were written from (`diff` = 0 lines). The structural reason is
//           worth stating, because it is the reusable lesson: this reader never hand-walks a
//           mangled type name. It hands the name's *original address* to
//           `swift_getTypeByMangledNameInContext` and lets the runtime do the GOT dereferencing
//           internally, so the guard was never in the path that touches those slots -- it only
//           covered the descriptor's own name string. Cross-module field types were therefore
//           never at risk here: `XPC.XPCPeerRequirement`, `Distributed.DistributedActor`,
//           `Synchronization.Mutex<…>` and `Synchronization.Atomic<Bool>` all resolve under
//           either guard. Hand-walking the name is what makes the guard load-bearing; don't.
//
//           The residual unresolvable fields in the full dump are all
//           generic-parameter-dependent manglings (they contain `x`/`q_`, e.g.
//           `BackpressureManager.activeRequests`), which genuinely need a generic context that a
//           bare descriptor walk does not have. None of them is in this subsystem. A field whose
//           type reference is *null* is a different thing and is the positive evidence for a
//           payload-free enum case -- see the [VWT] note.
//   [VWT]   read out of a `value witness table for X` in the loaded image: size at +0x40,
//           stride +0x48, flags +0x50, extraInhabitantCount +0x54. Used here for sizes and
//           strides, which pin field layout. Two traps, both checked before quoting anything:
//             * flags bit `0x00400000` marks the **incomplete-metadata placeholder** for a
//               resilient-layout type, where size and stride are 0 and mean nothing (Apple has
//               such placeholders for `EphemeralService`). Every VWT quoted below was checked and
//               none has that bit, so all the sizes here are real layouts.
//             * the tempting identity `extraInhabitantCount == 256 - caseCount` is necessary but
//               **not sufficient** for payload-freeness -- `Packet.(Header)` reports 253 with
//               three cases and is a two-payload enum whose extra inhabitants come from a spare
//               tag byte, so the numbers coincide. What actually decides it is [FIELD]: a case
//               with no payload has a *null* type reference in its field record, i.e. an empty
//               mangled name. The counts below corroborate; they never carry the claim.
//   [FILE]  the *live* demangler prints the private file discriminator that
//           `symbols-demangled.txt` strips, so two private declarations sharing a discriminator
//           are provably in the same source file. Probe: scratchpad/xpcsystem-discrim.py
//           (dladdr for the mangled name at an unslid address, then `xcrun swift demangle`).
//   [OSLOG] read out of `__TEXT,__oslogstring`, a section our dump does not contain (it is
//           separate from `__cstring`). 24 format strings; two of them name behaviour that no
//           signature carries.
//   [DISA]  resolved by disassembling the named function in the live macOS 27 image
//           (dump-function.py; addresses are unslid).
//   [DESC]  read out of a runtime descriptor in the live image (nominal type descriptor's
//           generic signature, protocol descriptor's requirement list, `direct field
//           offset` globals, realised class metadata).
//   [SCAN]  established by an exhaustive direct-branch scan of the text range spanned by
//           the image's T/t symbols.
//   [SPEC]  already resolved and written up in
//           docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md --
//           cited, not re-derived.
//   [INFER] inferred; the basis is stated.
//
// Bodies are omitted throughout. Apple's spellings, including typos, are preserved.
//
// Four cross-cutting facts that the notes below rely on:
//
//   * **Field-descriptor order is tag order for an enum** (payload cases first, then empty
//     ones), not declaration order. Every enum in this file has its case order corroborated a
//     second time from disassembly, so where the two agree it is stated as resolved.
//   * **None of the types in this file is `private`.** The check is the symbol table: a private
//     type is spelled `XPCDistributed.(Name)` and gets an `anonymous descriptor` symbol.
//     `WeakActorRef`, `ActorReference`, `ActorID`, `RawActorID` (and `.Local`, `.Remote`),
//     `SharedActorKey`, `WireCode`, `SetupError`, `RemoteInvocationCancellationError`,
//     `Reason` and `RestrictedAccessDistributedActor` have neither -- contrast
//     `XPCDistributed.(SwiftTypeCache)`, `XPCSystem.(InvocationCodingKeys)`,
//     `RemoteInvocationRequest.(CodingKeys)`, `ResultHandler.(Mode)`, all of which do. Every
//     stored property named here also has a `property descriptor` symbol, which is emitted for
//     public/resilient properties. So this whole surface is Apple's, and it is the surface a
//     mirror is obliged to reproduce -- `WeakActorRef` and `ActorReference` included.
//     [FILE] The file-discriminator test cannot refine this: it only speaks about *private*
//     declarations, and none of these types is private, so none carries a discriminator. What it
//     does settle is which file the private members live in -- `XPCSystem.(actorTable)`,
//     `XPCSystem.(resolve)` and `XPCSystem.(remoteCall)` all carry the discriminator
//     `_E9DA0CDEE867FDA494FF1CE55468C6EA`, so all three are in one file, which
//     `__cstring` names `XPCDistributed/XPCSystem.swift`. `Session.(addSharedActor)` carries a
//     different one (`_3CEE9BCFA827C3ABA8685D1E56281272`), i.e. `Session.swift` -- so the actor
//     table and the shared-actor map are, as their behaviour suggests, written in two files.
//
//   * **No claim in this file rests on a missing witness-table accessor.** That test is unsafe
//     here: a `merged lazy protocol witness table accessor` names only one of several folded
//     types, so an absent *named* accessor is consistent with one folded under another name.
//     Where this file argues from an absence it is an absence of a **conformance descriptor** or
//     of a **field record**, both of which are per-conformance/per-field and enumerable.
//   * **`Sendable` is invisible here.** It is a marker protocol: it emits no conformance
//     descriptor and it is omitted from a nominal type descriptor's generic requirement list.
//     No `Sendable` constraint in this file was read; none can be ruled out either.

import Distributed
import Foundation
import Synchronization
import XPC

// ===========================================================================================
// MARK: - XPCPeerRequirement is NOT Apple's XPCDistributed type
// ===========================================================================================

/// `XPCPeerRequirement` is **`XPC.XPCPeerRequirement`** -- a struct in Apple's *XPC Swift
/// overlay* (`libswiftXPC.dylib`, module `XPC`). It is not declared in `XPCDistributed` and
/// this reconstruction does not declare it.
///
/// [SYM] Every XPCDistributed signature that mentions it spells it `XPC.XPCPeerRequirement`
///       (e.g. `XPCSystem.peerRequirement.getter : XPC.XPCPeerRequirement?`,
///       `XPCSystem.listen(on:forPeersSatisfying:andExecuteForEachPeer:)`).
/// [DISA] `XPCSystem.init(_:)` at `0x2ad51d79c` calls
///       `type metadata accessor for XPC.XPCPeerRequirement`, which `dladdr` resolves into
///       **libswiftXPC.dylib**, not into XPCDistributed.
/// [DESC] Its exported surface in libswiftXPC (read with `dyld_info -exports`) is:
///       `static func hasEntitlement(_: String) -> Self`,
///       `static func entitlement(_: String, matches: String/Bool/Int) -> Self`,
///       `static func isFromSameTeam(andMatchesSigningIdentifier: String?) -> Self`,
///       `static func isPlatformCode(andMatchesSigningIdentifier: String?) -> Self`,
///       `static func fromLWCRData(_: UnsafeRawBufferPointer) -> Self`,
///       `init(lightweightCodeRequirements: XPCDictionary)`.
/// The repo defines no `XPCPeerRequirement` of its own (grep over `Sources/`, `Tests/`).
//
// (no declaration -- it is `import XPC`)

// ===========================================================================================
// MARK: - XPCSystem
// ===========================================================================================

/// [SYM] `XPCDistributed.XPCSystem`, a **class**.
/// [SYM] Conformances, from the two `protocol conformance descriptor for XPCDistributed.XPCSystem`
///       symbols: `Distributed.DistributedActorSystem` and `XPCDistributed.Internal.Identifiable`.
///       (`Internal.Identifiable` belongs to the Support agent's subsystem; referenced only.)
/// [INFER] **not `final`**: the image has `method lookup function for XPCDistributed.XPCSystem`
///       (`0x2ad5200dc`) and four `method descriptor for XPCDistributed.XPCSystem.__allocating_init…`
///       symbols, i.e. the class has a vtable. Only the initialisers occupy vtable slots; no
///       other member has a method descriptor, so nothing else is overridable.
/// [DESC] Instance layout, read from the `direct field offset` globals after forcing metadata
///       realisation through `$s14XPCDistributed9XPCSystemCMa` (instanceSize = 72):
///         0x10 debugName   0x20 id   0x28 peerRequirement   0x30 preserveSelfIPC   0x38 actorTable
///       Declaration order therefore matches the field-descriptor order exactly. (The last three
///       offsets are runtime-initialised globals -- they read 0 until the metadata is realised,
///       because `Mutex` and `XPCPeerRequirement?` come from resilient modules.)
/// [FIELD] All five records have `flags = 0x0`, i.e. `IsVar` clear: **all five are `let`**.
public class XPCSystem {

    /// [FIELD] `debugName: Swift.String` (mangled `SS`). [DESC] field offset 0x10.
    public let debugName: String

    /// [FIELD] `id: XPCDistributed.ID64`. [DESC] field offset 0x20.
    /// [SYM] Also the witness for `Internal.Identifiable.id`, so `Internal.Identifiable.ID == ID64`.
    /// [DISA] Every initialiser mints it with an inlined **`ID64()`** -- `ID64.init()` is
    ///       `0x2ad4ef1e0`, and what it increments is the private process-global
    ///       `static XPCDistributed.ID64.(default) : ID64.Generator` at `0x2d70d7450` behind the
    ///       `swift_once` token `0x2d70d7a90` (initialiser `0x2ad4ef35c`). The inlined body is
    ///       `adds #1`, `b.hs` to a `brk` on overflow, then a `cas` loop; ids are monotonic
    ///       from 1. So: `self.id = ID64()`.
    public let id: ID64

    /// [FIELD] `peerRequirement: Swift.Optional<XPC.XPCPeerRequirement>`. [DESC] field offset 0x28.
    /// [DISA] `init(_:)` (`0x2ad51d79c`) and `init(_:preserveSelfIPC:)` (`0x2ad51d8f4`) both
    ///       initialise it by calling the optional's `storeEnumTagSinglePayload` witness with
    ///       (whichCase: 1, emptyCases: 1) -- i.e. **nil**. The two `peerRequirement:`-taking
    ///       initialisers store the argument.
    public let peerRequirement: XPCPeerRequirement?

    /// [FIELD] `preserveSelfIPC: Swift.Bool` (mangled `Sb`). [DESC] field offset 0x30.
    /// [DISA] `init(_:)`: `preserveSelfIPC = Environment.preserveSelfIPC`.
    ///       `init(_:preserveSelfIPC:)` (`0x2ad51d8f4+0xc4`): `tbnz w19, #0` skips the environment
    ///       read when the argument is true, so the stored value is
    ///       `argument || Environment.preserveSelfIPC`. Never the argument alone.
    /// [SPEC] `Environment.preserveSelfIPC` reads the `XPCSYSTEM_PRESERVE_SELFIPC` env var.
    /// [OSLOG] What the flag *does* -- which no signature says, and which is why
    ///       `__TEXT,__oslogstring` was worth reading. It carries the pair
    ///       `"Using same-process optimization for service %s"` /
    ///       `"preserveSelfIPC set, forcing XPC for service %s"`, and the same pair again for
    ///       `ephemeral service`. So a connection to a service in the *same process* normally
    ///       takes an in-process shortcut, and `preserveSelfIPC` suppresses that and forces a real
    ///       XPC round trip. It is the switch that makes self-IPC go over the wire.
    ///       [INFER] that the shortcut is `Transport.InProcessRawTransport` -- from the type's
    ///       existence and the message's wording, not from a resolved branch.
    public let preserveSelfIPC: Bool

    /// **What `actorTable` is, resolved twice independently.**
    /// [FIELD] The field record's mangled type name is
    ///       `\x02El\x87*ySDy\x02\xdc\xebe,\x02\xc7\xebe,GG`, which the runtime resolves to
    ///       `Synchronization.Mutex<Swift.Dictionary<XPCDistributed.XPCSystem.RawActorID.Local,
    ///        XPCDistributed.WeakActorRef>>`. `flags = 0x0`, so `let`, and no `Xw`, so the
    ///       `Mutex` itself is held strongly (the weakness is one level down, inside
    ///       `WeakActorRef`).
    /// [SYM] Corroborated by the symbol
    ///       `direct field offset for XPCDistributed.XPCSystem.(actorTable) :
    ///        Synchronization.Mutex<[…RawActorID.Local : …WeakActorRef]>`, which spells the same
    ///       type. So: keyed by `RawActorID.Local`, holding `WeakActorRef` -- **not**
    ///       `ActorReference`, which is a different thing entirely (see below).
    /// [DESC] Field offset 0x38, 16 bytes (lock word + dictionary). Private: it has a field-offset
    ///       global but **no property descriptor**, and the demangler prints it parenthesised.
    /// [DISA] Every initialiser plants an empty dictionary literal and a zeroed lock word.
    /// It is keyed by `RawActorID.Local` only -- there is no entry for a remote id -- and it holds
    /// `WeakActorRef`, i.e. the table never keeps an actor alive. There is no actor -> id map.
    private let actorTable: Mutex<[RawActorID.Local: WeakActorRef]>

    // -- initialisers ------------------------------------------------------------------------
    //
    // [SYM] Four genuine overloads, not one initialiser with defaulted parameters: all four have
    //       their own `init` / `__allocating_init` / `method descriptor` symbols and the image
    //       contains **no** `default argument N of XPCDistributed.XPCSystem.init…` symbol
    //       (contrast `default argument 2 of XPCSystem.Session.init(actorSystem:transport:options:)`,
    //       which does exist -- so the absence here is meaningful).
    // [DISA] All four share the same body shape: store `debugName`, mint `id` from the
    //       process-global generator, plant an empty `actorTable`, set `peerRequirement`,
    //       then compute `preserveSelfIPC`.

    /// [SYM][DISA] `0x2ad51d79c`. `peerRequirement = nil`,
    ///             `preserveSelfIPC = Environment.preserveSelfIPC`.
    public init(_ debugName: String)

    /// [SYM][DISA] `0x2ad51d8f4`. `peerRequirement = nil`,
    ///             `preserveSelfIPC = preserveSelfIPC || Environment.preserveSelfIPC`.
    public init(_ debugName: String, preserveSelfIPC: Bool)

    /// [SYM][DISA] `0x2ad51da64`.
    public init(_ debugName: String, peerRequirement: XPCPeerRequirement)

    /// [SYM][DISA] `0x2ad51dc3c`.
    public init(_ debugName: String, peerRequirement: XPCPeerRequirement, preserveSelfIPC: Bool)

    /// [SYM] `XPCSystem.deinit` / `__deallocating_deinit`.
    deinit

    // -- actor table access ------------------------------------------------------------------

    /// [SYM] `XPCSystem.resolve(id: RawActorID.Local) -> Distributed.DistributedActor?`
    ///       (`0x2ad51d4f0`). No private discriminator on the symbol, so `internal` at the
    ///       loosest -- and it is called from `Session`, so not private.
    /// [DISA] `os_unfair_lock_lock` on `actorTable`, specialised
    ///       `__RawDictionaryStorage.find<RawActorID.Local>`, `outlined init with copy of
    ///       WeakActorRef`, unlock, then `swift_unknownObjectWeakLoadStrong`. It does not prune
    ///       a dead entry.
    /// [SCAN] Two direct call sites in the image: `Session.(addSharedActor)+0x68` (`0x2ad508d70`)
    ///       and `XPCSystem.(resolve)+0x38` (`0x2ad51df20`). The second is new relative to the
    ///       wire-format spec, which named only `addSharedActor`. Scope of that claim: it is a
    ///       direct-branch scan, so it would miss a `blraa` (there is no vtable slot or witness
    ///       for this method, so that avenue is closed) and it would miss a *copy inlined* into
    ///       some third function. "Two call sites" therefore means two surviving calls, not two
    ///       uses.
    internal func resolve(id: RawActorID.Local) -> (any DistributedActor)?

    /// [SYM] `XPCSystem.(resolve)<A>(id: RawActorID.Local, as: A.Type) throws(SetupError) -> A`
    ///       (`0x2ad51dee8`). **`private`** -- the live demangling carries the discriminator
    ///       `(resolve in _E9DA0CDEE867FDA494FF1CE55468C6EA)`.
    /// [DISA] Calls `resolve(id:)` above, then a *conditional* `swift_dynamicCast` to `A`. On
    ///       failure it throws `SetupError` whose message is built as
    ///       `"Could not resolve actor ID " + String(describing: id) + " as " + _typeName(A, qualified: false)`
    ///       -- the 27-byte literal at `0x2ad526970` is `"Could not resolve actor ID "`, and the
    ///       4-byte inline small string built by `mov w0,#0x6120; movk w0,#0x2073,lsl #16` is
    ///       `" as "`.
    private func resolve<Act>(id: RawActorID.Local, as actorType: Act.Type) throws(SetupError) -> Act
        where Act: DistributedActor, Act.ID == ActorID

    // -- the rest of the public surface ------------------------------------------------------
    //
    // These belong to the Session / service subsystems and are listed here only because they are
    // members of `XPCSystem`. Every signature below is [SYM], copied from the demangled symbol.

    public func listen(
        on service: Service,
        executingForEachPeer: @Sendable (__owned Session.LocalInterface) async -> (result: (), token: Session.LocalInterface.ActivationToken)
    ) async throws(SetupError)

    public func listen(
        on service: Service,
        forPeersSatisfying: XPCPeerRequirement,
        andExecuteForEachPeer: @Sendable (__owned Session.LocalInterface) async -> (result: (), token: Session.LocalInterface.ActivationToken)
    ) async throws(SetupError)

    public func listen(
        on service: Service,
        forPeersSatisfying: XPCPeerRequirement?,
        executingForEachPeer: @Sendable (__owned Session.LocalInterface) async -> (result: (), token: Session.LocalInterface.ActivationToken)
    ) async throws(SetupError)

    public func listen(
        on service: InProcessService,
        executingForEachPeer: @Sendable (__owned Session.LocalInterface) async -> (result: (), token: Session.LocalInterface.ActivationToken)
    ) async throws   // note: untyped `throws`, unlike the three above -- as spelled in the symbol

    public func _listen<Key>(
        on listener: XPCListener,
        as key: Key,
        forPeersSatisfying: XPCPeerRequirement?,
        executingForEachPeer: @Sendable (__owned Session.LocalInterface) async -> (result: (), token: Session.LocalInterface.ActivationToken)
    ) async throws(SetupError) where Key: ServiceRegistry.Key

    public func makeRemoteInterface(to service: Service) async throws(SetupError) -> Session.RemoteInterface
    public func makeRemoteInterface(to service: Service, assumingPeerSatisfies: XPCPeerRequirement) async throws(SetupError) -> Session.RemoteInterface
    public func makeRemoteInterface(to service: EphemeralService, assumingPeerSatisfies: XPCPeerRequirement?) async throws(SetupError) -> Session.RemoteInterface
    public func makeRemoteInterface(to service: InProcessService) async throws(SetupError) -> Session.RemoteInterface
    public func makeRemoteInterface<S>(to service: S, assumingPeerSatisfies: XPCPeerRequirement?) async throws(SetupError) -> Session.RemoteInterface where S: ConnectableService
    public func makeRemoteInterface(over session: Session) async throws(SetupError) -> Session.RemoteInterface
    public func makeRemoteInterface(over transport: Transport) async throws(SetupError) -> Session.RemoteInterface

    public func makeBidirectionalInterface(to service: Service, assumeLocalInterfaceActivatedIn: (Session.LocalInterface.UncheckedHandoff) -> Task<Session.LocalInterface.ActivationToken, Never>) async throws(SetupError) -> Session.RemoteInterface
    public func makeBidirectionalInterface(to service: Service, assumingPeerSatisfies: XPCPeerRequirement, assumeLocalInterfaceActivatedIn: (Session.LocalInterface.UncheckedHandoff) -> Task<Session.LocalInterface.ActivationToken, Never>) async throws(SetupError) -> Session.RemoteInterface
    public func makeBidirectionalInterface(to service: EphemeralService, assumingPeerSatisfies: XPCPeerRequirement?, assumeLocalInterfaceActivatedIn: (Session.LocalInterface.UncheckedHandoff) -> Task<Session.LocalInterface.ActivationToken, Never>) async throws(SetupError) -> Session.RemoteInterface
    public func makeBidirectionalInterface(to service: InProcessService, assumeLocalInterfaceActivatedIn: (Session.LocalInterface.UncheckedHandoff) -> Task<Session.LocalInterface.ActivationToken, Never>) async throws(SetupError) -> Session.RemoteInterface
    public func makeBidirectionalInterface<S>(to service: S, assumingPeerSatisfies: XPCPeerRequirement?, assumeLocalInterfaceActivatedIn: (Session.LocalInterface.UncheckedHandoff) -> Task<Session.LocalInterface.ActivationToken, Never>) async throws(SetupError) -> Session.RemoteInterface where S: ConnectableService
    public func makeBidirectionalInterface(over session: Session, assumeLocalInterfaceActivatedIn: (Session.LocalInterface.UncheckedHandoff) -> Task<Session.LocalInterface.ActivationToken, Never>) async throws(SetupError) -> Session.RemoteInterface
    public func makeBidirectionalInterface(over transport: Transport, assumeLocalInterfaceActivatedIn: (Session.LocalInterface.UncheckedHandoff) -> Task<Session.LocalInterface.ActivationToken, Never>) async throws(SetupError) -> Session.RemoteInterface

    // `withRemoteInterface` / `withBidirectionalInterface` each come in a plain and a
    // `throws(E) -> Result<A, E>` flavour, over the same six destinations. [SYM] for all of them;
    // two representative shapes:
    public func withRemoteInterface<A>(to service: Service, perform: (Session.RemoteInterface) async -> A) async throws(SetupError) -> A where A: Sendable
    public func withRemoteInterface<A, E>(to service: Service, perform: (Session.RemoteInterface) async throws(E) -> A) async throws(SetupError) -> Result<A, E> where A: Sendable, E: Error
    public func withBidirectionalInterface<A>(to service: Service, perform: (__owned Session.LocalInterface) async -> (result: A, token: Session.LocalInterface.ActivationToken)) async throws(SetupError) -> A where A: Sendable
    // The generic-over-ConnectableService flavours mark `perform` `@isolated(any)`; the concrete
    // ones do not. [SYM]

    public func makeEphemeralService(_ debugName: String, assumeActivatedIn: (EphemeralService.Receiver) -> Task<EphemeralService.ListeningToken, Never>) -> EphemeralService
    public func makeEphemeralServiceWithListeningTask(_ debugName: String, assumeActivatedIn: (EphemeralService.Receiver) -> Task<EphemeralService.ListeningToken, Never>) -> EphemeralServiceWithListeningTask
}

// ===========================================================================================
// MARK: - XPCSystem: DistributedActorSystem
// ===========================================================================================

/// [SYM] There are **eight** `protocol witness for Distributed.DistributedActorSystem.…
///       in conformance XPCDistributed.XPCSystem : Distributed.DistributedActorSystem` symbols:
///       `assignID`, `actorReady`, `resignID`, `resolve`, `makeInvocationEncoder`, `remoteCall`,
///       `remoteCallVoid`, and **`invokeHandlerOnReturn`**. The wire-format spec says "all seven
///       requirements"; `invokeHandlerOnReturn` is the eighth and it is implemented too.
///
/// [SYM] Associated types, from the `associated type witness table accessor …` symbols:
///       `ActorID = XPCSystem.ActorID`               (witnesses `: Swift.Hashable`)
///       `InvocationEncoder = XPCSystem.InvocationEncoder`
///       `InvocationDecoder = XPCSystem.InvocationDecoder`   (not EncodedInvocationDecoder)
///       `ResultHandler = XPCSystem.ResultHandler`
///       `SerializationRequirement = any Decodable & Encodable`   [WITNESS] read, not inferred.
///           A previous revision marked this [INFER] on the stated basis that "there is no witness
///           symbol for a `SerializationRequirement` associated type because it is a same-type
///           witness." There is one: `DistributedActorSystem`'s protocol descriptor has
///           `NumRequirements=17`, `req[8]` is an `AssociatedTypeAccess` requirement for
///           `SerializationRequirement`, and XPCSystem's witness-table slot for it holds the
///           mangled name `Se_SEp` = `any Decodable & Encodable`. `METHOD.md` already records
///           that mangling, so this was answerable with a documented tool. Spelled `Codable`
///           below only because that is the Swift spelling of the same constraint -- note every
///           *method* mangling in this file spells it as the two separate requirements.
///
/// Note the asymmetry, which is Apple's and is read verbatim off the manglings: `resolve` and
/// `remoteCall` use **typed throws**, `remoteCallVoid` uses plain `throws`.
extension XPCSystem: DistributedActorSystem {

    public typealias ActorID = XPCSystem.ActorID
    public typealias InvocationEncoder = XPCSystem.InvocationEncoder
    public typealias InvocationDecoder = XPCSystem.InvocationDecoder
    public typealias ResultHandler = XPCSystem.ResultHandler
    public typealias SerializationRequirement = Codable

    /// [SYM][DISA] `0x2ad51e17c`, 144 bytes.
    /// [DISA] The type argument is never touched. Body: load `self.id` from `+0x20`, mint the
    ///       instance id with an inlined **`ID64()`** -- same `swift_once` token `0x2d70d7a90`
    ///       and same `static ID64.(default)` counter at `0x2d70d7450` that `XPCSystem.init` uses
    ///       for `self.id` -- then `stp id, n, [x8]` and `strb wzr, [x8, #0x40]`, enum tag 0,
    ///       `.local`. So it is literally
    ///       `ActorID(rawActorID: .local(.init(actorSystemID: self.id, instanceID: ID64())))`,
    ///       and `actorSystemID` and `instanceID` are drawn from **one** process-global counter --
    ///       an `actorSystemID` can therefore never equal an `instanceID` in the same process.
    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
        where Act: DistributedActor, Act.ID == ActorID

    /// [SYM][DISA] `0x2ad51e20c`, 188 bytes.
    /// [DISA] `dispatch thunk of Swift.Identifiable.id.getter`, then `brk #1` (a bare trap, no
    ///       message) if the id is `.remote`; then `os_unfair_lock_lock` on `actorTable`, the
    ///       `withLock` closure `closure #1 (sending inout [RawActorID.Local : WeakActorRef])`,
    ///       `os_unfair_lock_unlock`. Stores `WeakActorRef(actor)` -- weakly.
    public func actorReady<Act>(_ actor: Act)
        where Act: DistributedActor, Act.ID == ActorID

    /// [SYM][DISA] `0x2ad51e4a8`, 124 bytes.
    /// [DISA] `brk #1` on `.remote`; otherwise lock, specialised
    ///       `Dictionary.subscript.setter` with nil, unlock.
    public func resignID(_ id: ActorID)

    /// [SYM][DISA] `0x2ad51e064`, 280 bytes. Typed throws.
    /// [DISA] `ldrb w8, [x0, #0x40]; cmp w8, #1; b.ne` -- tag test:
    ///        - `.local`  -> the `private resolve(id:as:)` above;
    ///        - `.remote` and `remote.session.actorSystem === self` -> **return nil** (Swift's
    ///          instruction to synthesise a proxy);
    ///        - `.remote` otherwise -> throw `SetupError` with the 49-byte literal at
    ///          `0x2ad526850`, `"Remote actor does not belong to the actor system."`
    ///       The `===` test is `RawActorID.Remote.belongsTo(actorSystem:)` inlined. [SPEC]
    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws(SetupError) -> Act?
        where Act: DistributedActor, Act.ID == ActorID

    /// [SYM][SPEC] `0x2ad51e524`, 40 bytes, no calls: zero an 88-byte struct and plant the
    ///       empty-array singleton twice.
    public func makeInvocationEncoder() -> InvocationEncoder

    /// [SYM] `0x2ad51e9d8`. Typed throws.
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws(RemoteInvocationCancellationError) -> Res
        where Act: DistributedActor, Err: Error, Res: Decodable, Res: Encodable, Act.ID == ActorID

    /// [SYM] `0x2ad51ec44`. Plain `throws` in the mangling, unlike `remoteCall`.
    /// [SPEC] Binds the result type to `Ack`.
    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
        where Act: DistributedActor, Err: Error, Act.ID == ActorID

    /// [SYM] `XPCSystem.invokeHandlerOnReturn(handler: XPCSystem.ResultHandler,
    ///       resultBuffer: Swift.UnsafeRawPointer, metatype: Any.Type) async throws -> ()`.
    /// This is the eighth `DistributedActorSystem` witness — and "eighth" is now a real
    /// exhaustiveness result rather than a symbol count: `DistributedActorSystem`'s protocol
    /// descriptor has `NumRequirements=17`, of which exactly **8** are method requirements, none
    /// defaulted, and XPCSystem's witness table fills all 17 slots.
    ///
    /// Body resolved — by the Invocation agent, not here; see
    /// `reconstruction/Invocation.swift`. `0x2ad51eef0` loads the protocol descriptors for
    /// `Decodable` and `Encodable` and calls `dynamic_cast_existential_2_unconditional`
    /// (`0x2ad51fd70`, two `swift_conformsToProtocol2` then `brk #1`) with **no branch testing the
    /// result**, so a non-`Codable` return type **traps the callee here**. The continuation then
    /// does `resultBuffer.load(as: A.self)` and calls `ResultHandler` vtable slot `0x80`.
    public func invokeHandlerOnReturn(
        handler: ResultHandler,
        resultBuffer: UnsafeRawPointer,
        metatype: Any.Type
    ) async throws

    /// [SYM] `XPCSystem.(remoteCall)<Act, Res>(actor:target:invocation:result:)` (`0x2ad51e54c`,
    ///       544 bytes) -- **private**, the funnel both public entry points tail into.
    /// [DISA] Reads `actor.id`, calls
    ///       `(extension in XPCDistributed) DistributedActor.session.getter` (`0x2ad4f8b34`),
    ///       and if that is nil throws
    ///       `RemoteInvocationCancellationError(reason: .executionFailed, message: "Remote call on a local actor.")`
    ///       -- resolved at `0x2ad51e730`: `mov w9, #2; strb w9, [x20]` is `Reason` tag 2, and the
    ///       count word `0x1d` (29) with the pointer to `0x2ad526890` is the 29-byte literal
    ///       `"Remote call on a local actor."`. Otherwise it dispatches
    ///       `OutboundSessionProtocol.sendInvocation`.
    private func remoteCall<Act, Res>(
        actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        result: Res.Type
    ) async throws(RemoteInvocationCancellationError) -> Res
        where Act: DistributedActor, Res: Decodable, Res: Encodable, Act.ID == ActorID
}

/// [SYM] `protocol witness for XPCDistributed.Internal.Identifiable.id.getter : A.ID in
///       conformance XPCDistributed.XPCSystem : XPCDistributed.Internal.Identifiable`, plus
///       `associated type witness table accessor for Internal.Identifiable.ID : Swift.Hashable`.
///       The witness is the stored `id`, so `ID == ID64`.
extension XPCSystem: Internal.Identifiable {
    public typealias ID = ID64
}

/// [SYM] `(extension in XPCDistributed):Distributed.DistributedActor< where A.ID ==
///       XPCDistributed.XPCSystem.ActorID>.session.getter :
///       XPCDistributed.XPCSystem.OutboundSessionProtocol?` (`0x2ad4f8b34`), with a matching
///       `property descriptor`. [SPEC] requires tag 1 and returns the `Remote`'s session; nil for
///       a local id. Included here because it is how `remoteCall` finds its session.
extension DistributedActor where ID == XPCSystem.ActorID {
    internal var session: (any XPCSystem.OutboundSessionProtocol)? { get }
}

// ===========================================================================================
// MARK: - Identity
// ===========================================================================================

extension XPCSystem {

    /// [FIELD] one stored property, `rawActorID: XPCDistributed.XPCSystem.RawActorID`, `flags = 0x0`
    ///       so `let`.
    /// [SYM] Conformance descriptors: `Hashable`, `Equatable`, `CustomDebugStringConvertible`,
    ///       `Decodable`, `Encodable`. No `CodingKeys` in the field descriptors, so no keyed
    ///       container is possible.
    /// [VWT] `value witness table for XPCSystem.ActorID` (`0x2d9b84dc8`): size 65, stride 72,
    ///       extraInhabitants 254 -- i.e. 0x41 bytes of payload+tag, which is exactly the
    ///       `RawActorID` layout below, wrapped with no overhead.
    public struct ActorID: Hashable, CustomDebugStringConvertible, Codable {

        public let rawActorID: RawActorID

        /// [SYM] `ActorID.init(rawActorID: RawActorID)` (`0x2ad4f7620`).
        public init(rawActorID: RawActorID)

        /// [SPEC] `0x2ad4f6c34`. **Traps** on a `.remote` id with
        ///        `"Cannot send remote actor proxies over an session."` (Apple's typo,
        ///        `ActorID.swift:111`); otherwise reads `encoder.userInfo`, dispatches
        ///        `InboundSessionProtocol.handleActorShared(_:)` to mint a `SharedActorKey`, and
        ///        writes that key into a `singleValueContainer()`.
        public func encode(to encoder: Encoder) throws

        /// [SPEC] `0x2ad4f702c`. Reads `decoder.userInfo`, decodes a `SharedActorKey` from a
        ///        `singleValueContainer()`, and returns `.remote(session, key)` **unconditionally**.
        ///        No table is consulted.
        public init(from decoder: Decoder) throws

        /// [SYM][DISA] `ActorID.debugDescription.getter` (`0x2ad4f745c`) is 4 bytes: an
        ///       unconditional `b` to `RawActorID.debugDescription.getter` (`0x2ad4f7460`).
        public var debugDescription: String { get }

        public func hash(into hasher: inout Hasher)
        public var hashValue: Int { get }
        public static func == (lhs: ActorID, rhs: ActorID) -> Bool
    }

    /// [FIELD] Two payload cases, and the field-descriptor order **is** the tag order:
    ///       `local(XPCSystem.RawActorID.Local)` then `remote(XPCSystem.RawActorID.Remote)` --
    ///       both payload types read out of the records' mangled names.
    /// [SPEC] Tag assignment independently resolved from two disassembly sites: `local` is 0,
    ///       `remote` is 1. The two readings agree.
    /// [SYM] Conformances: `Hashable`, `Equatable`, `CustomDebugStringConvertible`.
    ///       **Not `Codable`** -- there is no `Encodable`/`Decodable` conformance descriptor for
    ///       `RawActorID`, only for the `ActorID` wrapper. So `RawActorID` never crosses a coder
    ///       directly.
    /// [VWT] `0x2d9b84e48`: size 65, stride 72, extraInhabitants 254. Payload region 0x40 bytes
    ///       (`Remote` is the larger payload) with the tag in a separate byte at `+0x40`, which is
    ///       why every tag test in the image is `ldrb w8, [id, #0x40]`.
    public enum RawActorID: Hashable, CustomDebugStringConvertible {

        case local(Local)
        case remote(Remote)

        /// [FIELD] `let actorSystemID: XPCDistributed.ID64`, `let instanceID: XPCDistributed.ID64`.
        /// [SYM] `Local.init(actorSystemID: ID64, instanceID: ID64)` (`0x2ad4f7748`).
        /// [SYM] Conformances: `Hashable`, `Equatable`, `CustomDebugStringConvertible`.
        /// [VWT] `0x2d9b84ed8`: size 16, stride 16, extraInhabitants 0 -- two bare `UInt64`s, no
        ///       spare bits, which is what makes it the whole 16-byte key of `actorTable`.
        public struct Local: Hashable, CustomDebugStringConvertible {
            public let actorSystemID: ID64
            public let instanceID: ID64
            public init(actorSystemID: ID64, instanceID: ID64)
            public var debugDescription: String { get }
        }

        /// [FIELD] `let session: XPCDistributed.XPCSystem.OutboundSessionProtocol` (the mangled
        ///       name ends `_p`, so the **existential**) and `let key: XPCSystem.SharedActorKey`.
        /// [SYM] `Remote.init(session: XPCSystem.OutboundSessionProtocol, key: SharedActorKey)`
        ///       (`0x2ad4f78f8`).
        /// [VWT] `0x2d9b84f58`: size 64, stride 64. That splits as `session` `0x00..0x28` (a
        ///       5-word opaque existential, consistent with `OutboundSessionProtocol` being a
        ///       plain `protocol`, not a `class-protocol`, in the field descriptors) and `key`
        ///       `0x28..0x40`.
        /// [DISA] Corroborated by `SharedActorKey.init(from: Remote)` (`0x2ad4f7fe4`), which reads
        ///       exactly three words at `Remote+0x28`, `+0x30`, `+0x38`.
        /// [SYM] Conformances: `Hashable`, `Equatable`, `CustomDebugStringConvertible`. That an
        ///       existential-holding struct is `Hashable` means the conformance is hand-written;
        ///       `Remote.hash(into:)` (`0x2ad4f7940`) and `== ` (`0x2ad4f793c`) exist as real
        ///       functions. What they hash was not resolved.
        public struct Remote: Hashable, CustomDebugStringConvertible {
            public let session: any XPCSystem.OutboundSessionProtocol
            public let key: SharedActorKey
            public init(session: any XPCSystem.OutboundSessionProtocol, key: SharedActorKey)

            /// [SPEC] `0x2ad4f7a9c`. Projects the `OutboundSessionProtocol` existential, calls the
            ///        `actorSystem` getter witness (requirement index 3, slot `+0x18`), releases,
            ///        and compares the pointer against `actorSystem`.
            public func belongsTo(actorSystem: XPCSystem) -> Bool

            public var debugDescription: String { get }
        }

        public var debugDescription: String { get }
    }
}

/// [FIELD] `XPCDistributed.WeakActorRef` -- **top-level**, a `struct`, one field.
///       The record is decisive on all three questions at once: the resolved type is
///       `Swift.Optional<Distributed.DistributedActor>`, `flags = 0x2` sets **`IsVar`**, and the
///       mangled name is `\x029r\x87*_pSgXw` -- it ends **`Xw`**, which is `weak`. So the
///       declaration is exactly `weak var ref: (any DistributedActor)?`, read off metadata
///       rather than deduced from the runtime calls.
/// [SYM] Corroborated by `property descriptor for …WeakActorRef.ref`, `ref.getter`, `ref.setter`
///       and `ref.modify` -- the non-trivial accessor set a `weak` binding produces.
/// [DISA] And a third time: `WeakActorRef.init<A>(_:)` (`0x2ad4f6b14`, 84 bytes) calls
///       `swift_unknownObjectWeakInit` then `swift_unknownObjectWeakAssign`; reading it back
///       (in `XPCSystem.resolve(id: RawActorID.Local)`) goes through
///       `swift_unknownObjectWeakLoadStrong`.
/// [VWT] `0x2d9b84d48`: size 16, stride 16 -- a `WeakReference` word plus the existential's
///       witness-table word, which is what `weak` on a class-constrained existential costs.
/// [SYM] The symbol map contains no `protocol conformance descriptor for
///       XPCDistributed.WeakActorRef : …` of any kind, so `WeakActorRef` conforms to nothing.
///       Scope of that absence: conformance descriptors are one-per-conformance and each gets its
///       own symbol, so this is a sound absence -- unlike an argument from a missing *witness
///       table accessor*, which can be folded under another type's name. `Sendable` would be
///       invisible either way.
/// [SYM] Not private: no `anonymous descriptor`, and `ref` has a property descriptor. It is part
///       of Apple's surface even though nothing but `actorTable` uses it.
public struct WeakActorRef {

    public weak var ref: (any DistributedActor)?

    /// [SYM] `WeakActorRef.init<A where A: Distributed.DistributedActor,
    ///        A.ID == XPCDistributed.XPCSystem.ActorID>(A)` -- note the constraint is on `ID`,
    ///       not on `ActorSystem`.
    public init<Act>(_ actor: Act) where Act: DistributedActor, Act.ID == XPCSystem.ActorID
}

// ===========================================================================================
// MARK: - ActorReference -- resolved: it is the @Resolvable *stub* reference
// ===========================================================================================

extension XPCSystem {

    /// **What `ActorReference` is for, resolved.** It is the user-facing, `Codable`,
    /// transferable reference you put in a distributed func's signature, and its generic
    /// parameter is constrained to a **`_DistributedActorStub`** -- i.e. the `$Foo` type that
    /// Swift's `@Resolvable` macro generates for a distributed protocol. It is not the actor
    /// table, and it stores no key.
    ///
    /// [DESC] Generic signature read out of the nominal type descriptor
    ///        (`0x2ad526f04`): `NumParams=1  NumRequirements=2  NumKeyArguments=2`
    ///          req[0] Protocol  `x : <protocol descriptor at libswiftDistributed>`
    ///                 -> `dladdr` resolves that descriptor to
    ///                    `protocol descriptor for Distributed._DistributedActorStub`
    ///          req[1] SameType  `x.ActorSystem == <context>`
    ///                 -> `dladdr` resolves that context to
    ///                    `nominal type descriptor for XPCDistributed.XPCSystem`
    ///        This is worth stressing: the demangled *symbols* alone cannot tell you this. A
    ///        method of a generic type mangles only the requirements introduced at its own level,
    ///        so `ActorReference.resolve() -> A` and `init(_:as:)` both print with no constraint
    ///        on the class's own parameter. Reading `_DistributedActorStub` off the descriptor is
    ///        what pinned it, and it explains an otherwise puzzling instruction sequence -- see
    ///        `init(from:)` below.
    ///
    /// [FIELD] Two stored properties, both `flags = 0x0` (`let`) and neither carrying an `Xw`:
    ///        `id: XPCDistributed.XPCSystem.ActorID` and
    ///        `actor: Distributed.DistributedActor` (mangled `\x02\xe9t\x87*_p`, the `_p` making
    ///        it the existential). So the reference it holds is **strong** -- the contrast with
    ///        `WeakActorRef` is deliberate on Apple's part and visible in the metadata.
    /// [SYM]  Conformances: `Decodable`, `Encodable` (both unconditional -- the descriptors are
    ///        `ActorReference<A> : Swift.Decodable/Encodable`).
    /// [DESC] Field offsets (static globals): `id` at 0x10, `actor` at 0x58; instance size 0x68.
    ///        Generic arguments live in the metadata at `+0x50` (the stub type) and `+0x58` (its
    ///        `_DistributedActorStub` witness table); `class metadata base offset` is 0x50.
    /// [INFER] **not `final`**: both initialisers have `method descriptor` symbols and there is a
    ///        `method lookup function for XPCSystem.ActorReference`, i.e. they occupy vtable
    ///        slots. `init(from:)` being a vtable entry is what a `required init(from:)` on a
    ///        non-final `Decodable` class looks like.
    /// [SCAN] `init(_:as:)` (`0x2ad4ec02c`) and `resolve()` (`0x2ad4ec38c`) have **zero** direct
    ///        `BL`/`B` call sites in the image; `encode(to:)` and `__allocating_init(from:)` have
    ///        exactly one each, namely their own `Codable` protocol witnesses.
    ///        **That is weaker than "unused" and must not be written up as more.** A
    ///        direct-branch scan is blind to `blraa`, and both of these are vtable members with
    ///        `method descriptor` symbols, so class dispatch would not appear. The claim the scan
    ///        actually supports is: no *statically bound* call to either exists inside
    ///        `XPCDistributed`. Combined with the fact that the type's public generic parameter is
    ///        a client-supplied `@Resolvable` stub, the reading is that it is client-facing API --
    ///        but the strong form ("the session never consults it") is inherited from [SPEC], not
    ///        established here. Closing it properly needs a scan that resolves `blraa` through the
    ///        vtable, which was not run.
    /// [SYM] Not private: no `anonymous descriptor`; `id` and `actor` both have property
    ///        descriptors.
    /// A `Sendable` constraint on `Stub` would be invisible to every probe used here.
    public class ActorReference<Stub>: Codable
        where Stub: _DistributedActorStub, Stub.ActorSystem == XPCSystem {

        /// [FIELD][SYM] `id.getter : XPCSystem.ActorID` (`0x2ad4ebf10`), property descriptor, no
        ///              setter.
        public let id: ActorID

        /// [FIELD][SYM] `actor.getter : Distributed.DistributedActor` (`0x2ad4ebf70`) -- the
        ///              existential `any DistributedActor`, two words at `+0x58`. A *strong*
        ///              reference (contrast `WeakActorRef`).
        public let actor: any DistributedActor

        /// [SYM][DISA] `0x2ad4ec02c`, 120 bytes.
        /// [DISA] Reads `actor.id` through `dispatch thunk of Swift.Identifiable.id.getter`,
        ///        stores it into `self.id`, and stores `(actor, its DistributedActor witness
        ///        table)` into `self.actor`. It performs **no** check and mints **no**
        ///        `SharedActorKey` -- sharing happens later, inside `ActorID.encode(to:)`.
        ///        The `as:` argument is a phantom: only its type matters.
        public init<Act>(_ actor: Act, as stubType: Stub.Type)
            where Act: DistributedActor, Act.ActorSystem == XPCSystem

        /// [SYM][DISA] `0x2ad4ec0a4`, **32 bytes**: `add x20, x20, #0x10` then a direct
        ///        `bl XPCSystem.ActorID.encode(to:)` on `self.id`. It opens no container of its
        ///        own. **On the wire an `ActorReference` is exactly its `ActorID`**, which
        ///        [SPEC] is a bare `SharedActorKey` in a single-value container -- so an
        ///        `ActorReference<$Foo>` argument is indistinguishable on the wire from a bare
        ///        `SharedActorKey`. Nothing records the stub type.
        public func encode(to encoder: Encoder) throws

        /// [SYM][DISA] `0x2ad4ec118`, 628 bytes. `required`.
        /// [DISA] In order: `ActorID.init(from: decoder)` straight on the incoming decoder (no
        ///        container), store into `self.id`; read `decoder.userInfo`, look up
        ///        `Distributed.CodingUserInfoKey.actorSystemKey`, and `swift_dynamicCast` the
        ///        value to `XPCSystem` with flags 7 -- **unconditional**, so a missing or
        ///        wrong-typed actor system traps; then
        ///        `static Distributed.DistributedActor.resolve(id:using:)` with the stub type
        ///        (metadata `+0x50`) and the *base* `DistributedActor` witness table read out of
        ///        the stub witness table at `+0x58` slot 1 -- which is exactly the shape the
        ///        `_DistributedActorStub` requirement predicts; finally store the resolved
        ///        instance and that base witness table into `self.actor`.
        ///        Note it uses only `actorSystemKey`, **not**
        ///        `"com.apple.xpc.distributed/Session"`.
        public required init(from decoder: Decoder) throws

        /// [SYM][DISA] `0x2ad4ec38c`, 120 bytes: `swift_unknownObjectRetain` on `actor`, then
        ///        `swift_dynamicCast` to the generic parameter with flags 7 -- an unconditional
        ///        `as!`, so it traps on a mismatch. Non-throwing, non-optional.
        public func resolve() -> Stub

        deinit
    }
}

// ===========================================================================================
// MARK: - SharedActorKey
// ===========================================================================================

extension XPCSystem {

    /// [FIELD] Three payload cases, in tag order, **with their payload types read straight out of
    ///         the records' mangled names** -- an independent confirmation of what the wire-format
    ///         spec resolved by disassembling `encode(to:)`:
    ///           `exported(XPCDistributed.SwiftType)`
    ///           `exportedRawValue(Swift.String)`   (mangled `SS`)
    ///           `dynamic(XPCDistributed.ID64)`
    ///         Exactly one nested type, `WireCode`. **No `CodingKeys` of any kind** in this build.
    /// [SPEC]  `encode(to:)` (`0x2ad4f8458`) opens an `unkeyedContainer()` and every branch does
    ///         two encodes: `[ <WireCode : UInt8>, <payload> ]`.
    /// [SYM]   Conformances: `Hashable`, `Equatable`, `CustomDebugStringConvertible`,
    ///         `Decodable`, `Encodable`.
    /// [VWT]   `0x2d9b84fd8`: size 24, stride 24, extraInhabitants 125. Payload region 3 words
    ///         (0x18) with **no separate tag byte** -- the tag lives in spare bits.
    /// [DISA]  Which spare bits: `debugDescription` (`0x2ad4f89f0`) extracts the tag with
    ///         `lsr x8, x2, #0x3e`, i.e. the top two bits of the third word, which for the
    ///         `exported` case is `SwiftType.type`'s `Any.Type` pointer.
    /// [DISA]  `debugDescription` independently corroborates both the case order and the payload
    ///         types, from a different function than `encode(to:)`: tag 0 appends the 7-byte
    ///         inline string `"preset_"` and then `_print_unlocked` of the payload; tag 1 appends
    ///         the 14-byte inline string `"preset_forKey_"` and then `String.append` of the
    ///         payload *directly* (only a `String` payload permits that); tag 2 appends
    ///         `"dynamic_"` and then `String(describing:)` of the payload. `exported` = 0,
    ///         `exportedRawValue` = 1, `dynamic` = 2.
    public enum SharedActorKey: Hashable, CustomDebugStringConvertible, Codable {

        case exported(SwiftType)
        case exportedRawValue(String)
        case dynamic(ID64)

        /// [FIELD] cases `exported`, `exportedRawValue`, `dynamic` in that order, all three with a
        ///         **null type reference** (empty mangled name) -- payload-free; no `CodingKeys`.
        ///         Note the contrast with the enclosing `SharedActorKey`, whose three same-named
        ///         cases *do* carry type references. That contrast, in one metadata section, is
        ///         what makes `WireCode` unmistakably the discriminator and not a copy of the key.
        /// [VWT]   `0x2d9b85068`: size 1, stride 1, extraInhabitants 253 -- consistent with three
        ///         payload-free cases (but see the [VWT] caveat in the header: the count alone
        ///         would not prove it).
        /// [SPEC]  `RawRepresentable` over `UInt8`; raw values are the defaults 0, 1, 2 in
        ///         declaration order, and it reaches the wire as a bare integer via
        ///         `RawRepresentable`'s conditional `Codable`.
        /// [SYM]   Conformance descriptors: `RawRepresentable`, `Equatable`, `Hashable`,
        ///         `Decodable`, `Encodable` -- and *no* `WireCode.encode(to:)` function symbol,
        ///         which is what a `RawRepresentable`-derived conformance looks like.
        /// [SYM]   Not private: no `anonymous descriptor` (contrast `ResultHandler.(Mode)` and
        ///         `InvocationDecoder.(Mode)`, which have one).
        public enum WireCode: UInt8, Hashable, Codable {
            case exported
            case exportedRawValue
            case dynamic
        }

        /// [SYM][DISA] `SharedActorKey.init(from: RawActorID.Remote)` (`0x2ad4f7fe4`, 80 bytes).
        ///        Reads the three payload words at `Remote+0x28`, retains, destroys the `Remote`,
        ///        and returns them: it is `remote.key`, nothing more. Not the `Decodable` init.
        /// [SCAN] Zero direct call sites. **Do not read that as "unused"** -- it is an 80-byte
        ///        struct initialiser in a single-module binary and would be inlined at any call
        ///        site. `TestHook.sharedActorKey(for: RawActorID.Remote)` [SYM] is the visible
        ///        wrapper around the same operation.
        public init(from remote: RawActorID.Remote)

        /// [SPEC] `0x2ad4f8458` / mirror. Unkeyed pair.
        public func encode(to encoder: Encoder) throws
        public init(from decoder: Decoder) throws

        public var debugDescription: String { get }
    }
}

// ===========================================================================================
// MARK: - RestrictedAccessDistributedActor
// ===========================================================================================

extension XPCSystem {

    /// [FIELD] Listed as a **`class-protocol`**, i.e. `AnyObject`-constrained (which
    ///         `DistributedActor` already implies).
    /// [DESC]  Protocol descriptor `0x2ad527dd8`: `NumRequirementsInSignature = 2`,
    ///         `NumRequirements = 2`.
    ///           signature req[0] Protocol  `Self : <descriptor>` ->
    ///                     `protocol descriptor for Distributed.DistributedActor`
    ///           signature req[1] SameType  `Self.ActorSystem == <context>` ->
    ///                     `nominal type descriptor for XPCDistributed.XPCSystem`
    ///           requirement[0] flags 0x0        -> the base conformance to `DistributedActor`
    ///                          (`base conformance descriptor for …: Distributed.DistributedActor`,
    ///                           `0x2ad527e08` = requirementsBase + 8)
    ///           requirement[1] flags 0x2a940013 -> kind 3 (Getter) | 0x10 (IsInstance)
    ///                          (`method descriptor for …peerRequirement.getter`, `0x2ad527e10`)
    ///         So the protocol has **exactly one** member requirement, a get-only instance
    ///         property, and its `where` clause pins the actor system.
    /// [SYM]  The requirement's type is `XPC.XPCPeerRequirement` -- **non-optional**, unlike
    ///        `XPCSystem.peerRequirement` which is `XPCPeerRequirement?`.
    /// [SPEC] The inbound path applies it per actor: `handleReceivedRequest`'s `closure #2` does
    ///        `swift_conformsToProtocol2` against this protocol's descriptor (`0x2ad527dd8`), and
    ///        if the resolved actor conforms it reads `Session.RemoteInterface.auditToken` and
    ///        calls `audit_token_t.satisfies(requirement:)`. Failure string, from `__cstring`:
    ///        `"Failed actor's peer requirement check"` (distinct from XPCSystem's own
    ///        `"Peer failed XPCSystem's entitlement check"` /
    ///        `"(Internal) failed XPCSystem's peer requirement check"`).
    /// [SCAN] The `dispatch thunk of …peerRequirement.getter` (`0x2ad520144`) has **zero** direct
    ///        call sites, which is consistent with [SPEC]: the inbound path loads the witness out
    ///        of the table returned by `swift_conformsToProtocol2` and calls it indirectly, so it
    ///        never goes through the thunk.
    /// Written as a nested protocol because that is what the binary says: the mangled name is
    /// `$s14XPCDistributed9XPCSystemC32RestrictedAccessDistributedActorP`, i.e. nested inside the
    /// *class* `XPCSystem`. `InboundSessionProtocol`, `OutboundSessionProtocol`,
    /// `ConnectableService` and `ServiceRegistry.Key` are nested the same way, so this is a
    /// consistent choice of Apple's and not a mangling artefact. It may not compile on a
    /// toolchain that still rejects nested protocols; the transcription is deliberate.
    public protocol RestrictedAccessDistributedActor: DistributedActor
        where ActorSystem == XPCSystem {
        var peerRequirement: XPCPeerRequirement { get }
    }
}

// ===========================================================================================
// MARK: - Errors
// ===========================================================================================

extension XPCSystem {

    /// [FIELD] one stored property, `message: Swift.String` (mangled `SS`), `flags = 0x0` so `let`.
    /// [VWT] `0x2d9b85550`: size 16, stride 16, extraInhabitants `0x7fffffff`, and the
    ///       incomplete-placeholder flag `0x00400000` is **clear** so the layout is real. The
    ///       extra-inhabitant count being *exactly* `String`'s confirms the struct is one bare
    ///       `String` with nothing wrapped around it -- contrast
    ///       `RemoteInvocationCancellationError` at `0x7ffffffe`, one fewer, which is what the
    ///       `String?` costs.
    /// [SYM]  Conformance descriptors: `Swift.Error`, `Distributed.DistributedActorSystemError`,
    ///        `Foundation.LocalizedError`, `Swift.CustomDebugStringConvertible`.
    ///        (Not `CustomStringConvertible` -- that is the *other* error type.)
    /// [DISA] `init(_:)` (`0x2ad4fefd0`) is 8 bytes: `stp x0, x1, [x8]; ret`.
    ///        `message.getter` (`0x2ad4ff2a0`) returns the stored string.
    ///        `debugDescription.getter` (`0x2ad4ff2d0`) builds
    ///        `"SetupError{\"" + message + "\"}"` -- the 12-byte inline small string
    ///        `SetupError{"` from `movz/movk` at `+0x34`/`+0x44`, and the 2-byte `"}` at `+0x64`.
    ///        `errorDescription.getter` (`0x2ad4ff354`) returns `message`.
    ///        The other three `LocalizedError` witnesses (`failureReason`, `helpAnchor`,
    ///        `recoverySuggestion`) exist only as protocol witnesses, i.e. defaulted.
    /// This is the error every `throws(SetupError)` in the framework throws; observed message
    /// strings include `"Remote actor does not belong to the actor system."` and
    /// `"Could not resolve actor ID <id> as <Type>"`.
    public struct SetupError: Error, DistributedActorSystemError, LocalizedError,
                              CustomDebugStringConvertible {
        public let message: String
        public init(_ message: String)
        public var debugDescription: String { get }
        public var errorDescription: String? { get }
    }

    /// [FIELD] two stored properties, both `let`:
    ///         `_reason: XPCDistributed.XPCSystem.RemoteInvocationCancellationError.Reason` and
    ///         `_message: Swift.Optional<Swift.String>` (mangled `SSSg`). Read off the field
    ///         records, so the `String?` is not a deduction from the factories' `stp xzr, xzr`.
    /// [VWT]  `0x2d9b85440`: size 24, stride 24, extraInhabitants `0x7ffffffe`, placeholder flag
    ///         clear. That is one tag byte padded to 8 plus a 16-byte `String?`, matching the
    ///         instruction-level layout below; and the count being one *below* `String`'s
    ///         `0x7fffffff` is the independent tell that the stored string is optional.
    /// [SYM]  `_reason` and `_message` have **no** property descriptors, while `reason`,
    ///        `message`, `description` and `errorDescription` do -- so the two underscored fields
    ///        are the private storage and the four unadorned names are the public computed
    ///        surface.
    /// [SYM]  Conformance descriptors: `Swift.Error`, `Distributed.DistributedActorSystemError`,
    ///        `Foundation.LocalizedError`, `Swift.CustomStringConvertible`.
    /// [DISA] Layout, from `init(reason:message:)` (`0x2ad4ff188`, 16 bytes:
    ///        `ldrb w9,[x0]; strb w9,[x8]; stp x1,x2,[x8,#8]; ret`): `_reason` is one byte at
    ///        `+0x00`, `_message: String?` is 16 bytes at `+0x08` with nil == (0, 0).
    public struct RemoteInvocationCancellationError: Error, DistributedActorSystemError,
                                                    LocalizedError, CustomStringConvertible {

        /// [FIELD] four cases, and **each field record's type reference is null** (empty mangled
        ///        name), which is the direct evidence that all four are payload-free -- the string
        ///        really does live in `_message`, not in the cases. Field-descriptor order is tag
        ///        order, so this alone also gives the numbering.
        /// [VWT]  `0x2d9b854c0`: size 1, stride 1, extraInhabitants 252. Consistent with four
        ///        payload-free cases, but *only* consistent: `256 - caseCount` is also what a
        ///        multi-payload enum with a spare tag byte reports (`Packet.(Header)` is the
        ///        counterexample). The size of 1 plus the null type references are what settle it.
        /// [DISA] And a third source agrees: the four static factories write the tag literally --
        ///        `strb wzr` = 0, `mov w9,#1` = 1, `#2`, `#3` -- in exactly this order.
        /// [SYM]  Conformance descriptors: `Equatable`, `Hashable`. No `anonymous descriptor`, so
        ///        `Reason` is not private.
        public enum Reason: Hashable {
            case underlyingSessionCancelled   // tag 0
            case callingTaskCancelled         // tag 1
            case executionFailed              // tag 2
            case resultPropagationFailed      // tag 3
        }

        private let _reason: Reason
        private let _message: String?

        /// [SYM][DISA] `0x2ad4ff188`.
        public init(reason: Reason, message: String?)

        /// [SYM][DISA] The four static factories, each a 16-20 byte store of a tag plus the
        ///        string. Note that **`callingTaskCancelled` takes no argument** and writes
        ///        `stp xzr, xzr` -- a nil `_message`; the other three take an unlabelled `String`.
        public static func underlyingSessionCancelled(_ message: String) -> Self  // 0x2ad4ff198
        public static func callingTaskCancelled() -> Self                          // 0x2ad4ff1a8
        public static func executionFailed(_ message: String) -> Self              // 0x2ad4ff1b8
        public static func resultPropagationFailed(_ message: String) -> Self      // 0x2ad4ff1cc

        /// [SYM][DISA] `reason.getter` `0x2ad4ff060` -- returns `_reason`.
        public var reason: Reason { get }

        /// [SYM][DISA] `message.getter` `0x2ad4ff06c`, 284 bytes. It is
        ///        `defaultText(_reason) + ". " + (_message ?? "")`:
        ///        a `csel` chain on the reason byte picks one of four (count, pointer) pairs, the
        ///        text is appended, then the 2-byte inline small string `". "`
        ///        (`mov w0,#0x202e`, count 0xE2), then `_message` if non-nil.
        ///
        ///        The four default texts, read out of the image at the selected pointers with the
        ///        selected lengths:
        ///          `.underlyingSessionCancelled` (32) `"Underlying session was cancelled"`
        ///          `.callingTaskCancelled`       (57) `"The task calling the distributed invocation was cancelled"`
        ///          `.executionFailed`            (43) `"The distributed invocation was not executed"`
        ///          `.resultPropagationFailed`    (79) `"Failed to obtain the result of the distributed invocation after it was executed"`
        ///
        ///        The wire-format spec listed only the first two; the third and fourth were sitting
        ///        in `__cstring` unattributed. Note that `.executionFailed`'s default text says the
        ///        invocation was *not* executed -- that is Apple's pairing, not a transcription slip.
        public var message: String { get }

        /// [SYM][DISA] `description.getter` `0x2ad4ff1e0` and `errorDescription.getter`
        ///        `0x2ad4ff21c` both call `message.getter` and return it.
        public var description: String { get }
        public var errorDescription: String? { get }
    }
}

// ===========================================================================================
// MARK: - Referenced but owned by other subsystems
// ===========================================================================================
//
// Declared elsewhere in this reconstruction pass; named here only so the signatures above read:
//
//   XPCDistributed.ID64, ID64.Generator, XPCDistributed.SwiftType, XPCDistributed.Ack
//   XPCDistributed.Environment            (`Environment.preserveSelfIPC`, XPCSYSTEM_PRESERVE_SELFIPC)
//   XPCDistributed.Internal.Identifiable
//   XPCDistributed.TestHook               -- Support agent. Members touching identity, for
//                                            cross-reference only, all [SYM]:
//        static func isLocal(_: XPCSystem.ActorID) -> Bool                       // 0x2ad4f8ba0
//        static func mapToLocalActorID(_: XPCSystem.ActorID,
//                                      session: XPCSystem.Session) -> XPCSystem.ActorID?  // 0x2ad50b6a0
//        static func sharedActorKey(for: XPCSystem.RawActorID.Remote) -> XPCSystem.SharedActorKey  // 0x2ad4f8bb0
//        static func unassignedLocalID(in: XPCSystem) -> XPCSystem.ActorID        // 0x2ad51fce0
//   XPCSystem.Session, .LocalInterface, .RemoteInterface, .InboundSessionProtocol,
//     .OutboundSessionProtocol, .Transport, .Service, .EphemeralService, .InProcessService,
//     .ConnectableService, .ServiceRegistry, .InvocationEncoder, .InvocationDecoder,
//     .ResultHandler, .EncodedResultHandler
//
// Two findings for OTHER subsystems that fell out of the field-record reader while it was pointed
// at this one. Passed along, not reconstructed here -- but both are things the wire-format spec
// records as open or unstated, so they should be routed rather than lost:
//
//   * **`Session.Kind`'s case-to-payload assignment is now resolved.** The spec lists this under
//     what it "left unresolved, listed so it is not mistaken for settled", saying the two payload
//     types are facts but "the case-to-payload assignment was not read out of `Kind`'s field
//     descriptor payload records." It is readable there, and it is the obvious reading after all:
//         [FIELD]  xpc(XPCDistributed.XPCSystem.Transport)
//                  local(XPCDistributed.XPCSystem.Session.LocalSessionState)
//     in that field-record order, which for an enum is tag order.
//
//   * **`Transport.inboundSession` is `weak`.** [FIELD] its mangled name is
//     `\x02_\xffe,_pSgXw` -- `flags = 0x2` (var) and the `Xw` suffix -- so the declaration is
//     `weak var inboundSession: (any XPCSystem.InboundSessionProtocol)?`. That is the second weak
//     edge in the framework after `WeakActorRef.ref`, and it is what stops `Transport` and
//     `Session` from retaining each other.
//
// ===========================================================================================
// MARK: - UNRESOLVED
// ===========================================================================================
//
// UNRESOLVED: which source file `ActorReference` and `WeakActorRef` are declared in, and hence
//   whether they are one file's plumbing or independent API. The file-discriminator test only
//   works on `private` declarations and neither type is private, so it cannot answer this. Next
//   step: the framework's file list is known from assertion strings, and neither type appears in
//   any of them; a per-file grouping for non-private declarations would have to come from
//   something else -- address locality is suggestive (`ActorReference`'s members sit at
//   `0x2ad4ebf10..0x2ad4ec4cc`, `WeakActorRef`'s at `0x2ad4f69c4..0x2ad4f6b60`, i.e. **not**
//   adjacent) but locality is not proof.
//
// UNRESOLVED: `public` versus `internal`, everywhere. What *is* resolved is that none of these
//   types is `private` or `fileprivate` (no `anonymous descriptor`, no parenthesised name), and
//   that every stored property named here has a `property descriptor`, which is emitted for
//   public/resilient properties -- so the surface is at least library-visible. Distinguishing
//   `public` from `@usableFromInline internal` is not possible from a stripped private framework
//   with no `.swiftinterface`. Everything above is spelled `public` on that basis; treat the
//   keyword as "not private", not as a resolved access level.
//
// UNRESOLVED: whether `XPCSystem` is `Sendable`. `Sendable` is a marker protocol and emits no
//   conformance descriptor, so the symbol table cannot answer it. It must be, for
//   `DistributedActorSystem`, whose `Sendable` refinement would be checked at compile time --
//   but that is a deduction from the protocol, not a reading of the image. Next step: none
//   available from this binary; take it from `DistributedActorSystem`'s own declaration.
//
// UNRESOLVED: whether `XPCSystem` and `XPCSystem.ActorReference` are `final`. Both have vtables
//   (method descriptors + a method lookup function) covering only their initialisers, which is
//   what a non-final class produces, and that is the reading given above -- but a `@objc`-free
//   `final` class emitting init descriptors cannot be ruled out from symbols alone. Next step:
//   parse the class descriptors' `ExtraClassFlags` / `NumImmediateMembers` and compare against a
//   locally compiled `final` and non-final control pair.
//
// UNRESOLVED: whether anything inside `XPCDistributed` reaches `ActorReference` or
//   `RestrictedAccessDistributedActor.peerRequirement` by *indirect* dispatch. The callers-of scan
//   run here decodes only direct `BL`/`B`, so it is blind to `blraa` -- vtable dispatch for the
//   class, witness dispatch for the protocol. Its "zero call sites" results are therefore
//   evidence of no static binding and nothing more. Next step: extend the scan to resolve `blraa`
//   through the vtable and through witness tables, with a known-answer control whose indirect
//   call count is independently known.
//
// UNRESOLVED: what `RawActorID.Remote.hash(into:)` (`0x2ad4f7940`) and
//   `Remote.== ` (`0x2ad4f793c`) actually compare. `Remote` holds an `any OutboundSessionProtocol`
//   existential, which is not `Hashable`, so the conformance is hand-written; the obvious reading
//   is "hash the session's `Internal.Identifiable.id` and the key", and that is exactly the kind
//   of guess this pass exists to avoid. Next step: disassemble both (216 and 168 bytes) and look
//   for the `Identifiable.id.getter` witness dispatch. Not peer-observable either way.
//
// UNRESOLVED: the exact text `RawActorID.debugDescription` /
//   `Local.debugDescription` / `Remote.debugDescription` produce. All three are
//   `_print_unlocked`-based interpolations; the literals were not decoded because they are inline
//   small strings inside `csel` chains. Purely diagnostic, not peer-observable. Next step: full
//   `dump-function.py` listings of `0x2ad4f7460`, `0x2ad4f86f8`, `0x2ad4f879c`.
//
// UNRESOLVED: why `XPCSystem.remoteCallVoid` is spelled with plain `throws` while `remoteCall`,
//   `resolve`, and the private `(remoteCall)` all use typed throws. The manglings are
//   unambiguous, so this is a question about Apple's source, not about the reading.
