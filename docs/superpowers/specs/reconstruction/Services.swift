// Reconstruction of Apple's `XPCDistributed` interface — services and discovery.
//
// Covers, all nested in `XPCDistributed.XPCSystem`:
//
//   Service
//   ServiceRegistry, ServiceRegistry.RegisteredService, ServiceRegistry.Key
//   ConnectableService                         (protocol; not in the assigned list, but
//                                               both Service and EphemeralService conform
//                                               and it is what `connect(from:with:)` is a
//                                               requirement of, so it is written here)
//   EphemeralService, .CodingKeys, .ListeningToken, .ListeningToken.CodingKeys, .Receiver
//   EphemeralServiceWithListeningTask
//   InProcessService
//
// plus the `XPCSystem` entry points whose first parameter is one of those service types
// (`listen(on:…)`, `_listen(on:as:…)`, `makeEphemeralService…`, and the
// `make/withRemoteInterface` / `make/withBidirectionalInterface` families), because those
// are the discovery surface and are not meaningful apart from it.
//
// `Session`, `Session.LocalInterface`, `Session.RemoteInterface`,
// `Session.ServiceConnectArguments`, `Session.InitializationOptions`, `Session.Kind`,
// `Session.LocalSessionState`, `Transport`, `Transport.XPCRawTransport`,
// `Transport.InProcessRawTransport`, `TransportReceiver`, `SetupError`, `ID64`,
// `UnownedAwaitableEvent` are OTHER agents' types and are referenced, not reconstructed.
//
// ── Evidence tags ─────────────────────────────────────────────────────────────────────
//   [sym]   read off a demangled symbol's own signature in symbols-demangled.txt
//   [refl]  read out of the field record for a named type — the MANGLED TYPE NAME at +4
//           and the flags at +0, not just the name at +8 that field-descriptors.txt shows.
//           This is the declared type and the let/var of a stored property, straight from
//           reflection metadata, independent of any getter existing to disassemble.
//           Descriptor addresses come from the `reflection metadata field descriptor …`
//           symbols and every symbolic reference is resolved by looking its target address
//           up in the dynamic symbol table, so no section is scanned and no
//           parent-descriptor chain is walked. See the method note at the end.
//   [oslog] the `os_log` format string a function passes to `_os_log_impl` in x3, from
//           __TEXT,__oslogstring — a section separate from __cstring and absent from
//           cstrings.txt. Apple describing its own behaviour.
//   [vwt]   value-witness table read out of the loaded image: size +0x40, stride +0x48,
//           flags +0x50, extraInhabitantCount +0x54. Used ONLY for struct size/stride;
//           see the method note for why the enum shortcut is unsound.
//   [dis]   resolved by disassembling the function (dump-function.py + capstone)
//   [vc]    verify-containers.py, run with its METHODS list extended
//   [scan]  caller scan over __text 0x2ad4b0000–0x2ad520400. SEE THE CAVEAT BELOW.
//   [inf]   inferred — the basis is stated inline
//
// ── What the caller scan does and does not see ────────────────────────────────────────
// [scan] decodes only DIRECT `b`/`bl` branch immediates. It is blind to `blraa`/`braa`
// (vtable dispatch, protocol-witness dispatch, closure and async-function-pointer calls).
// So "[scan] found no caller" is evidence of absence ONLY for a function that cannot be
// reached indirectly — i.e. one with no method descriptor, no dispatch thunk, and no
// witness-table slot. Where that condition holds it is stated explicitly below. It never
// holds for a protocol witness, which is by construction always called through a witness
// table; a scan result about a witness's callers is worthless and is not used as evidence
// anywhere in this file.
//
// ── On access levels ──────────────────────────────────────────────────────────────────
// Linkage does not give access level here: `XPCDistributed.ID64` and `XPCDistributed.Fuse`
// are plainly internal utility types, yet every member of each is an external (`T`)
// symbol. Nor does field-descriptors.txt, which prints a private type under its bare name.
// What DOES resolve `private`/`fileprivate`:
//   * a TYPE that is private has an `anonymous descriptor` symbol and spells itself
//     parenthesised, e.g. `ServiceRegistry.(RegisteredService)`;
//   * a MEMBER that is private demangles with a private discriminator, e.g.
//     `Service.(makeXPCSession in _E24F9F3C47E8475B1F8536DBBA84FFC2)`.
// [sym] Enumerating every `anonymous descriptor` in the module: of the types in this
// subsystem, exactly three are private — `ServiceRegistry.RegisteredService`,
// `EphemeralService.CodingKeys`, and `EphemeralService.ListeningToken.CodingKeys`.
// `Service`, `EphemeralService`, `EphemeralService.ListeningToken`,
// `EphemeralService.Receiver`, `EphemeralServiceWithListeningTask`, `InProcessService`
// and `ServiceRegistry` all have unparenthesised `S` nominal type descriptors and no
// anonymous descriptor, so none of them is private. Nothing below claims a
// `public`/`internal` distinction, which remains unresolvable.
//
// Unslid addresses are from xpcdump/macos27-XPCDistributed/symbols-demangled.txt.

import Dispatch
import XPC

extension XPCDistributed.XPCSystem {

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: - ServiceRegistry.Key
    // ─────────────────────────────────────────────────────────────────────────────────

    /// The key half of in-process service discovery: anything that can name a service
    /// slot in `ServiceRegistry.services`.
    ///
    /// [sym] `protocol descriptor for …ServiceRegistry.Key` @ 0x2ad526a40.
    /// [sym] The one and only requirement: `method descriptor for
    ///       …ServiceRegistry.Key.debugName.getter : Swift.String` @ 0x2ad526a6c
    ///       (with its `dispatch thunk of` @ 0x2ad4c5ed4).
    /// [sym] `base conformance descriptor for …ServiceRegistry.Key: Swift.Hashable`
    ///       @ 0x2ad526a64 — hence the `: Hashable` refinement. This module emits a base
    ///       conformance descriptor for every protocol refinement it declares (five exist,
    ///       e.g. `InboundSessionProtocol: Internal.Identifiable`), so `Hashable` is the
    ///       only non-marker refinement. A marker protocol such as `Sendable` would leave
    ///       no symbol either way.
    /// Nested inside `ServiceRegistry` per the mangling
    /// `$s14XPCDistributed9XPCSystemC15ServiceRegistryC3KeyP`.
    protocol /* XPCSystem.ServiceRegistry. */ Key: Hashable {
        var debugName: String { get }
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: - ConnectableService
    // ─────────────────────────────────────────────────────────────────────────────────

    /// A service a client can open a `Session` to.
    ///
    /// [sym] `protocol descriptor for …ConnectableService` @ 0x2ad526bc0; one method
    ///       descriptor @ 0x2ad526bd8 giving the full signature below.
    /// [sym] No `base conformance descriptor for …ConnectableService: …` exists, so it
    ///       refines no non-marker protocol. Notably it does NOT refine
    ///       `ServiceRegistry.Key` — `Service` and `EphemeralService` each conform to the
    ///       two protocols separately, with two conformance descriptors apiece.
    /// [sym] Exactly two conformers ship in the framework: `Service` (witness table
    ///       @ 0x2d9b83368) and `EphemeralService` (@ 0x2d9b83378). `InProcessService` does
    ///       not conform — see its note.
    protocol /* XPCSystem. */ ConnectableService {
        func connect(
            from actorSystem: XPCDistributed.XPCSystem,
            with arguments: XPCDistributed.XPCSystem.Session.ServiceConnectArguments
        ) async throws(XPCDistributed.XPCSystem.SetupError) -> XPCDistributed.XPCSystem.Session
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: - Service
    // ─────────────────────────────────────────────────────────────────────────────────

    /// A launchd-registered service, addressed by name. Not `Codable`.
    ///
    /// [refl] Field records, in order:
    ///        `isMach` flags=0x00 type `Sb`  → `let isMach: Swift.Bool`
    ///        `name`   flags=0x00 type `SS`  → `let name: Swift.String`
    ///        Neither has the IsVar bit (0x2), so both are `let`.
    /// [vwt]  size 24, stride 24 — consistent with `Bool` at offset 0 and `String`
    ///        (16 bytes) at offset 8.
    /// [dis]  Offsets confirmed independently: `machService(_:)` @ 0x2ad4c8eb8 writes `1`
    ///        to byte [0] and the string to [8]; `xpcService(_:)` @ 0x2ad4c8ecc writes `0`.
    /// [sym]  Conforms to `Hashable`/`Equatable` (0x2ad520780 / 0x2ad5207c0),
    ///        `ConnectableService`, `ServiceRegistry.Key`. There is no
    ///        `Encodable`/`Decodable` conformance descriptor for `Service` anywhere in the
    ///        symbol table: it is not `Codable`.
    struct /* XPCSystem. */ Service: Hashable, XPCDistributed.XPCSystem.ConnectableService,
                                     XPCDistributed.XPCSystem.ServiceRegistry.Key {

        /// [refl] type and `let`-ness resolved.
        /// [inf] `private` is inferred, not resolved: unlike `name`, `isMach` has neither a
        ///       getter symbol nor a property descriptor, and both static factories store
        ///       the byte inline instead of calling an initializer [dis] — there is no
        ///       `Service.init` symbol of any kind, which is what an inlined private
        ///       memberwise init looks like. Reflection metadata carries no access level.
        private let isMach: Bool

        /// [refl] `SS`. [sym] getter @ 0x2ad4c8e88, property descriptor @ 0x2ad5209c0.
        /// No setter or `modify` symbol exists.
        let name: String

        /// [sym] `static Service.machService(Swift.String) -> Service` @ 0x2ad4c8eb8.
        /// [dis] Sets `isMach = true`, `name = <argument>`. No argument label in the
        ///       mangling, so it is `_`.
        static func machService(_ name: String) -> XPCDistributed.XPCSystem.Service

        /// [sym] `static Service.xpcService(Swift.String) -> Service` @ 0x2ad4c8ecc.
        /// [dis] Sets `isMach = false`.
        static func xpcService(_ name: String) -> XPCDistributed.XPCSystem.Service

        /// [sym] `Service.debugName.getter : Swift.String` @ 0x2ad4c92e4 (property
        ///       descriptor @ 0x2ad5209c4). A second, separate body @ 0x2ad4c9368 is the
        ///       `ServiceRegistry.Key.debugName` witness.
        /// [dis] Both build `(isMach ? "mach:" : "xpc:") + name`. The prefixes are Swift
        ///       small strings assembled from `movz`/`movk` immediates —
        ///       0x616d/0x6863/0x3a with discriminator 0xE5 = "mach:" (5 bytes), and
        ///       0x7078/0x3a63 with 0xE4 = "xpc:" (4 bytes). Neither literal appears in
        ///       any string table.
        var debugName: String { get }

        /// [sym] `Service.(makeXPCSession)(peerRequirement: XPC.XPCPeerRequirement?) ->
        ///       XPC.XPCSession` @ 0x2ad4c8edc — private discriminator, so `private`.
        /// [dis] Branches on `isMach`: `XPCSession(machService: name, targetQueue: nil,
        ///       options: .inactive, cancellationHandler: nil)` when true, else
        ///       `XPCSession(xpcService: name, …)`; then, when `peerRequirement != nil`,
        ///       `session.setPeerRequirement(_:)`. The session is created `.inactive`.
        private func makeXPCSession(peerRequirement: XPC.XPCPeerRequirement?) -> XPC.XPCSession

        /// [sym] `Service.connect(from:with:) async throws(SetupError) -> Session`
        ///       @ 0x2ad4d7020; `ConnectableService` witness @ 0x2ad4d7980.
        /// [dis] Body, fully resolved (see "Registration, discovery and connection" below):
        ///       reads `actorSystem.preserveSelfIPC`; when TRUE it goes straight to the XPC
        ///       path; when FALSE it first `await`s
        ///       `ServiceRegistry.shared.lookUpAndConnect(to:from:options:)` and returns
        ///       that `Session` if non-nil. The XPC path is
        ///       `makeXPCSession(peerRequirement:)` → `Transport.XPCRawTransport` →
        ///       `Transport(debugName:rawTransport:)` →
        ///       `Session(actorSystem:transport:options:)`.
        /// [oslog] Apple names both branches from this function:
        ///       'Using same-process optimization for service %s' (0x2ad52c1a0) and
        ///       'preserveSelfIPC set, forcing XPC for service %s' (0x2ad52c1d0). These
        ///       independently confirm the branch direction traced in the disassembly.
        func connect(
            from actorSystem: XPCDistributed.XPCSystem,
            with arguments: XPCDistributed.XPCSystem.Session.ServiceConnectArguments
        ) async throws(XPCDistributed.XPCSystem.SetupError) -> XPCDistributed.XPCSystem.Session

        // [sym] Synthesized Hashable: `hash(into:)` @ 0x2ad4c90ec, `== infix` @ 0x2ad4c90a4,
        // `hashValue.getter` @ 0x2ad4c9130. [dis] `hash(into:)` combines the `Bool` then
        // the `String`; `==` compares both.
        func hash(into hasher: inout Hasher)
        static func == (lhs: XPCDistributed.XPCSystem.Service,
                        rhs: XPCDistributed.XPCSystem.Service) -> Bool
        var hashValue: Int { get }
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: - EphemeralService
    // ─────────────────────────────────────────────────────────────────────────────────

    /// An anonymous service identified by a live `XPCEndpoint` rather than by a name in
    /// launchd. The one service type in the framework that is `Codable`.
    ///
    /// [refl] Field records, in order, both `let` (no IsVar bit):
    ///        `debugName` `SS`               → `Swift.String`
    ///        `endpoint`  `{XPC.XPCEndpoint}` — an indirect (kind 0x02) symbolic reference
    ///        whose target resolves through the dynamic symbol table to
    ///        `$s3XPC11XPCEndpointVMn` in libswiftXPC.dylib, i.e. the nominal type
    ///        descriptor for the STRUCT `XPC.XPCEndpoint`. Independently corroborated by
    ///        [sym] `EphemeralService.init(debugName: Swift.String,
    ///        endpoint: XPC.XPCEndpoint)` @ 0x2ad4d57e8.
    /// [vwt]  `value witness table for …EphemeralService` reports size 0 / stride 0 /
    ///        flags 0x00400000. That is the incomplete-metadata placeholder, not a real
    ///        layout: `EphemeralService` embeds the resilient `XPC.XPCEndpoint`, so its
    ///        metadata is instantiated at runtime (it has a `type metadata singleton
    ///        initialization cache` @ 0x2d70d7758 and a `type metadata completion function`
    ///        @ 0x2ad4d9890). Do not read a size out of it — this is the trap where a VWT
    ///        symbol exists but carries nothing.
    /// [sym]  Conformances, each with its own descriptor: `Hashable` (0x2ad52090c),
    ///        `Equatable` (0x2ad52094c), `Encodable` (0x2ad5208e4), `Decodable`
    ///        (0x2ad5208bc), `ConnectableService` (0x2ad5209a8), `ServiceRegistry.Key`
    ///        (0x2ad520974).
    struct /* XPCSystem. */ EphemeralService: Hashable, Codable,
                                              XPCDistributed.XPCSystem.ConnectableService,
                                              XPCDistributed.XPCSystem.ServiceRegistry.Key {

        /// [refl] `SS`, `let`. [sym] getter @ 0x2ad4d5740, property descriptor @ 0x2ad5209d0.
        /// [dis] The `ServiceRegistry.Key.debugName` witness @ 0x2ad4d6ff0 is a bare load
        ///       of field 0 — the stored property satisfies the requirement directly,
        ///       unlike `Service`, which computes it.
        let debugName: String

        /// [refl] `let`. [sym] getter @ 0x2ad4da8cc, property descriptor @ 0x2ad5209d4.
        let endpoint: XPC.XPCEndpoint

        /// [sym] `EphemeralService.xpcEndpoint.getter : XPC.XPCEndpoint` @ 0x2ad4d5770,
        ///       property descriptor @ 0x2ad5209c4. Not a stored property — it is absent
        ///       from the field records [refl], which list only `debugName` and `endpoint`.
        /// [dis] `endpoint.getter` @ 0x2ad4da8cc is a one-instruction `b` to
        ///       `xpcEndpoint.getter` @ 0x2ad4d5770, which is itself a `b` to the single
        ///       folded body @ 0x2ad4d5774 (`merged …EphemeralService.endpoint.getter`).
        ///       So the two getters return the same stored field.
        /// UNRESOLVED: why a second spelling exists. No protocol in this module requires
        /// `xpcEndpoint`. NEXT STEP: check whether libswiftXPC declares an
        /// `xpcEndpoint`-bearing protocol whose conformance record lives in that image
        /// rather than this one — a scan of this image's conformance section cannot see it.
        var xpcEndpoint: XPC.XPCEndpoint { get }

        /// [sym] `EphemeralService.init(debugName:endpoint:)` @ 0x2ad4d57e8. Whether this
        ///       is the implicit memberwise init or an explicit one is not resolvable.
        init(debugName: String, endpoint: XPC.XPCEndpoint)

        /// [sym] `EphemeralService.makeXPCSession(peerRequirement: XPC.XPCPeerRequirement?)
        ///       -> XPC.XPCSession` @ 0x2ad4d5864. NOT parenthesised — so, unlike
        ///       `Service.makeXPCSession`, this one is not `private`.
        /// [dis] `XPCSession(endpoint: endpoint, targetQueue: nil, options: .inactive,
        ///       cancellationHandler: nil)`, then `setPeerRequirement(_:)` when non-nil.
        ///       Ends in `Swift._assertionFailure`. [inf] the message is cstrings.txt's
        ///       "Bug in XPCDistributed: Creation of inactive XPCSession not expected to
        ///       throw" — that is the only assertion string of that shape and this is an
        ///       inactive-session creation site, but the string reference was not resolved.
        func makeXPCSession(peerRequirement: XPC.XPCPeerRequirement?) -> XPC.XPCSession

        /// [sym] `EphemeralService.connect(from:with:) async throws(SetupError) -> Session`
        ///       @ 0x2ad4d7a2c; `ConnectableService` witness @ 0x2ad4d8434.
        /// [dis] Same shape as `Service.connect`: continuation 1 loads the same
        ///       `preserveSelfIPC` field-offset global 0x2d70d80c8, and continuation 2 calls
        ///       `generic specialization <EphemeralService> of
        ///       ServiceRegistry.lookUpAndConnect`, falling through to the endpoint-based
        ///       XPC path.
        /// [oslog] The two branches are named by Apple, in this very function:
        ///       'Using same-process optimization for ephemeral service %s' (0x2ad52c200)
        ///       and 'preserveSelfIPC set, forcing XPC for ephemeral service %s'
        ///       (0x2ad52c240), both passed in x3 to `_os_log_impl` from
        ///       `EphemeralService.connect` continuation 1. That upgrades what was an
        ///       inference from `Service.connect`'s shape into a resolved fact about THIS
        ///       function, and it names the semantics: the registry hit is a "same-process
        ///       optimization", and `preserveSelfIPC` "forces XPC".
        func connect(
            from actorSystem: XPCDistributed.XPCSystem,
            with arguments: XPCDistributed.XPCSystem.Session.ServiceConnectArguments
        ) async throws(XPCDistributed.XPCSystem.SetupError) -> XPCDistributed.XPCSystem.Session

        // [sym] Synthesized Hashable: `hash(into:)` @ 0x2ad4d5ebc, `== infix` @ 0x2ad4d5a60,
        // `hashValue.getter` @ 0x2ad4d5f4c. [dis] BOTH fields participate: `hash(into:)`
        // calls `String.hash(into:)` then dispatches `Hashable.hash(into:)` for
        // `XPCEndpoint`; `==` calls `_stringCompareWithSmolCheck` then
        // `static XPC.XPCEndpoint.== infix`. So endpoint identity is part of the registry key.
        func hash(into hasher: inout Hasher)
        static func == (lhs: XPCDistributed.XPCSystem.EphemeralService,
                        rhs: XPCDistributed.XPCSystem.EphemeralService) -> Bool
        var hashValue: Int { get }

        // [sym] `encode(to:)` @ 0x2ad4d5d04, `init(from:)` @ 0x2ad4d5ff8, with the
        // Encodable/Decodable witnesses @ 0x2ad4d630c / 0x2ad4d62f4.
        func encode(to encoder: any Encoder) throws
        init(from decoder: any Decoder) throws

        /// Compiler-synthesized coding keys.
        ///
        /// [sym] `anonymous descriptor …EphemeralService.(CodingKeys)` @ 0x2ad526be0 and a
        ///       lowercase nominal type descriptor @ 0x2ad526be8 — a private TYPE. The live
        ///       demangler spells it
        ///       `EphemeralService.(CodingKeys in _E24F9F3C47E8475B1F8536DBBA84FFC2)`; the
        ///       same file discriminator appears on
        ///       `Service.(makeXPCSession in _E24F9F3C47E8475B1F8536DBBA84FFC2)`, so both
        ///       live in one source file — `…/Transport/XPC/Service+XPC.swift`, named in
        ///       cstrings.txt.
        /// [refl] Two case records, `debugName` then `endpoint`, and NEITHER carries a type
        ///       reference at +4 — so both are payload-free, and the enum has exactly these
        ///       two cases. Reflection lists every case of an enum, payload cases first then
        ///       empty ones, in tag order; with no payload cases at all, these are tags 0
        ///       and 1. (This is the sound test. The tempting shortcut —
        ///       `extraInhabitantCount == 256 − caseCount` — is NOT sufficient; the VWT here
        ///       does report size 1 / 254, but see the method note for the counterexample
        ///       that makes that reasoning inadmissible.)
        /// [sym] Conforms to `CodingKey`, `Hashable`, `Equatable`,
        ///       `CustomStringConvertible`, `CustomDebugStringConvertible` — exactly the set
        ///       the compiler synthesizes for a `String`-raw-valued `CodingKeys`.
        /// [dis] The `CodingKey.stringValue` witness @ 0x2ad4d5b68 is a `csel` between two
        ///       small strings: 0x6564/0x7562/0x4e67/0x6d61 + 0x65 with discriminator 0xE9
        ///       = "debugName" (9 bytes), selected when the tag is NOT 1; and
        ///       0x6e65/0x7064/0x696f/0x746e with 0xE8 = "endpoint" (8 bytes), selected when
        ///       the tag IS 1. That agrees with the reflection tag order. Neither literal
        ///       is in any string table. The raw values are the property names verbatim —
        ///       no renaming, no abbreviation.
        private enum CodingKeys: String, CodingKey {
            case debugName   // tag 0, "debugName"
            case endpoint    // tag 1, "endpoint"
        }

        // ── What EphemeralService puts on the wire ──────────────────────────────────
        //
        // [vc] `encode(to:)` @ 0x2ad4d5d04 → `Encoder.container(keyedBy:)` at +0x0e0;
        //      `init(from:)` @ 0x2ad4d5ff8 → `Decoder.container(keyedBy:)` at +0x1ac. Run
        //      with the script's own controls agreeing with their labels (`SharedActorKey`
        //      unkeyed, `Ack` keyed), so the resolution is trustworthy. KEYED, two keys.
        // [dis] Inside `encode(to:)`: `KeyedEncodingContainer.encode(_: String, forKey:)`
        //      at +0x0fc for `debugName`, then
        //      `KeyedEncodingContainer.encode<A: Encodable>(_:forKey:)` at +0x178 for
        //      `endpoint`, with the witness table fetched from `lazy protocol witness table
        //      cache variable for type XPC.XPCEndpoint and conformance
        //      XPC.XPCEndpoint : Swift.Encodable in XPC` (cache var @ 0x2d58d44a8).
        //      dump-function.py annotates that accessor with a `merged …` name belonging to
        //      an unrelated Dispatch type — exactly the folded-symbol trap the brief warns
        //      about; the cache-variable address, computed from the adrp/add pair, is what
        //      identifies it.
        //      So an encoded `EphemeralService` is a two-key dictionary:
        //          "debugName" -> string
        //          "endpoint"  -> whatever XPC.XPCEndpoint's own Codable emits
        //      and it is therefore only codable by an XPC-aware coder, because XPCEndpoint
        //      has to round-trip an `xpc_endpoint_t`.
        //
        // It is NOT a fourth top-level payload kind. The load-bearing evidence:
        //   * [sym] The symbol table contains no `lazy protocol witness table
        //     accessor`/`cache variable` for `EphemeralService : Encodable` or
        //     `: Decodable`, though it contains them for `EphemeralService`'s `Hashable`
        //     and `Equatable` conformances (0x2d70d76f8, 0x2d70d76f0) and for
        //     `XPC.XPCEndpoint : Encodable`/`Decodable` (0x2d58d44a8, 0x2d58d44b8). No
        //     `protocol witness table for …EphemeralService : Swift.Encodable` symbol
        //     exists either: every Codable conformance in this module is instantiated at
        //     runtime through its conformance descriptor. To use such a conformance
        //     generically, Swift code in this module must first obtain the witness table,
        //     and that emits the lazy accessor. Nothing here does. So no code in
        //     XPCDistributed encodes or decodes an `EphemeralService`.
        //   * This is NOT supported by the caller scan: `encode(to:)`/`init(from:)` are
        //     reached through witness tables, i.e. indirectly, so a direct-branch scan
        //     could not see such a call even if one existed. Stated because the scan result
        //     is easy to misread as confirmation; it is not.
        //   * The earlier finding that all eleven `XPCDictionary.encode` sites in __text are
        //     request, response, or notification is likewise a direct-branch result and
        //     shares that blindness.
        //   Taken together: an `EphemeralService` never becomes a packet by itself. It
        //   reaches a peer as a value INSIDE an invocation — an element of
        //   `InvocationEncoder.arguments`, which lands in a `RemoteInvocationRequest`'s
        //   `contents` (or symmetrically in a response). "Pass the EphemeralService as a
        //   distributed-method argument" is how a process hands a peer a private
        //   back-channel; there is no separate service-advertisement packet.

        // ─────────────────────────────────────────────────────────────────────────────
        // MARK: EphemeralService.ListeningToken
        // ─────────────────────────────────────────────────────────────────────────────

        /// Proof, handed back by `Receiver.listen`, that a particular `Receiver` is the one
        /// that was activated. Its only established job is that identity check.
        ///
        /// [refl] One field record: `id`, `let`, type `{XPCDistributed.ID64}` (symbolic
        ///        reference resolving to `$s14XPCDistributed4ID64VMn`).
        /// [vwt]  size 8, stride 8 — one pointer-sized field and nothing else, so the field
        ///        list is complete. Struct size/stride is the part of the VWT that is sound.
        /// [sym]  Conformances: `Hashable` (0x2ad520854), `Equatable` (0x2ad520894),
        ///        `Encodable` (0x2ad52082c), `Decodable` (0x2ad520804).
        ///        Nominal type descriptor is `S` and unparenthesised: not private.
        struct ListeningToken: Hashable, Codable {

            /// [refl] `let`. [sym] getter @ 0x2ad4d4a20, property descriptor @ 0x2ad5209c8.
            let id: XPCDistributed.ID64

            /// [sym] `ListeningToken.init(id:)` @ 0x2ad4d4a28.
            init(id: XPCDistributed.ID64)

            // [sym] `== infix` @ 0x2ad4d4a30, `hash(into:)` @ 0x2ad4d4d2c,
            // `hashValue.getter` @ 0x2ad4d4d58, `encode(to:)` @ 0x2ad4d4bec,
            // `init(from:)` @ 0x2ad4d4da0.
            static func == (lhs: ListeningToken, rhs: ListeningToken) -> Bool
            func hash(into hasher: inout Hasher)
            var hashValue: Int { get }
            func encode(to encoder: any Encoder) throws
            init(from decoder: any Decoder) throws

            /// [sym] `anonymous descriptor …ListeningToken.(CodingKeys)` @ 0x2ad526c04 —
            ///       a private TYPE.
            /// [refl] One case record, `id`, with NO type reference at +4 — payload-free,
            ///       and the only case. (The VWT reports size 0 / stride 1, consistent with
            ///       a single payload-free case, but the field record is the actual evidence;
            ///       see the method note on why enum VWT arithmetic is not admissible.)
            /// [sym] Conforms to `CodingKey`, `Hashable`, `Equatable`,
            ///       `CustomStringConvertible`, `CustomDebugStringConvertible` — the
            ///       synthesized set again.
            /// [dis] Its `CodingKey.stringValue` witness is at 0x2ad4d4ad0:
            ///       `mov w0, #0x6469; mov x1, #0xE200000000000000; ret` = "id". That same
            ///       address is ALSO the symbol for the corresponding witness of
            ///       `Session.RemoteNotification.(InvocationCancelledCodingKeys)` — the two
            ///       bodies were folded because both return "id". Per the brief's warning,
            ///       a folded symbol names only one of the types it serves; the shared body
            ///       is nonetheless what both conformances use.
            private enum CodingKeys: String, CodingKey {
                case id    // "id"
            }

            // [vc] `encode(to:)` → `Encoder.container(keyedBy:)` at +0x0dc;
            //      `init(from:)` → `Decoder.container(keyedBy:)` at +0x0e4. KEYED, one key
            //      "id", whose value is an `ID64` — and `ID64` is single-value/`UInt64`
            //      [vc, pre-existing rows]. So `{"id": <uint64>}`.
            // [sym] Like `EphemeralService`, there is no lazy witness-table accessor for
            //      `ListeningToken : Encodable` or `: Decodable`, so nothing in the
            //      framework uses those conformances generically.
            //      UNRESOLVED: why `ListeningToken` is `Codable` at all. Its one established
            //      in-module use [dis, 0x2ad4d6f30] is a local integer comparison of `id`
            //      against `Receiver.id`, which needs no coding. NEXT STEP: look for a
            //      shipping client of XPCDistributed that stores or forwards a
            //      `ListeningToken`; this image cannot answer it.
        }

        // ─────────────────────────────────────────────────────────────────────────────
        // MARK: EphemeralService.Receiver
        // ─────────────────────────────────────────────────────────────────────────────

        /// The listening side of an ephemeral service: owns the `XPCListener` whose
        /// endpoint the `EphemeralService` value carries.
        ///
        /// [refl] Field records, in order, all `let`, every type resolved through the
        ///        symbol table:
        ///        `id`          `{XPCDistributed.ID64}`                → `$s14XPCDistributed4ID64VMn`
        ///        `service`     `{…EphemeralService}`                  → `…9XPCSystemC16EphemeralServiceVMn`
        ///        `actorSystem` `{XPCDistributed.XPCSystem}`           → `…9XPCSystemCMn` (a class)
        ///        `listener`    `{XPC.XPCListener}`                    → `$s3XPC11XPCListenerCMn`
        ///                      in libswiftXPC.dylib — a CLASS, per the `C` in the mangling.
        /// [sym]  No `$defaultActor` field and no `Swift.Actor` conformance: a plain class,
        ///        not an actor. No conformance descriptor of any kind names `Receiver`.
        ///        Nominal type descriptor is `S` and unparenthesised, with no anonymous
        ///        descriptor: NOT private.
        /// [sym]  `__allocating_init(service:actorSystem:listener:)` has a `method
        ///        descriptor` @ 0x2ad526b90 and a `dispatch thunk` @ 0x2ad4d9a38, so the
        ///        init is in the class's vtable — the class is not `final`. (Because of
        ///        that vtable slot, a caller scan cannot establish anything about who
        ///        constructs a `Receiver`; no such claim is made.)
        class Receiver {

            /// [refl] `let id: XPCDistributed.ID64`.
            /// [dis] `init` @ 0x2ad4d5240 does NOT take `id`: it draws one from a
            ///       module-level `ID64.Generator` (a `swift_once`-initialised global at
            ///       0x2d70d7450, token at 0x2d70d7a90, incremented with an atomic CAS loop)
            ///       and stores it at object offset 0x10.
            let id: XPCDistributed.ID64

            let service: XPCDistributed.XPCSystem.EphemeralService
            let actorSystem: XPCDistributed.XPCSystem
            let listener: XPC.XPCListener

            /// [sym] `Receiver.init(service:actorSystem:listener:)` @ 0x2ad4d5240
            /// (allocating entry @ 0x2ad4d5158).
            init(service: XPCDistributed.XPCSystem.EphemeralService,
                 actorSystem: XPCDistributed.XPCSystem,
                 listener: XPC.XPCListener)

            /// [sym] Signature verbatim from the symbol @ 0x2ad4d5308. `async` but NOT
            ///       `throws`.
            /// [dis] Tail-calls, through the async function pointer at 0x2ad520740,
            ///       `generic specialization <EphemeralService> of XPCSystem._listen(
            ///       on: listener, as: service, forPeersSatisfying:, executingForEachPeer:)`
            ///       — so an ephemeral service goes into the same `ServiceRegistry` as a
            ///       named one, keyed by the `EphemeralService` value itself.
            ///       (The tail call is indirect; the target was identified by resolving the
            ///       async-function-pointer address 0x2ad520740 in the symbol table, not by
            ///       a branch-immediate scan.)
            /// [dis] On error it traps rather than propagating: continuation 4 @ 0x2ad4d5530
            ///       builds "Bug in XPCDistributed: " + "Listening on EphemeralService
            ///       threw " and calls `Swift._assertionFailure`. That is why the signature
            ///       can be non-throwing.
            func listen(
                forPeersSatisfying peerRequirement: XPC.XPCPeerRequirement?,
                executingForEachPeer body: @Sendable (
                    __owned XPCDistributed.XPCSystem.Session.LocalInterface
                ) async -> (result: Void,
                            token: XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken)
            ) async -> XPCDistributed.XPCSystem.EphemeralService.ListeningToken

            deinit
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: - EphemeralServiceWithListeningTask
    // ─────────────────────────────────────────────────────────────────────────────────

    /// An `EphemeralService` bundled with the task listening on it, so the caller can keep
    /// the listener alive (or await it).
    ///
    /// [refl] Field records, both `let`:
    ///        `service`       `{…EphemeralService}`
    ///        `listeningTask` `ScTy{…EphemeralService.ListeningToken}{Swift.Never}G`
    ///                        — `ScT` is `Swift.Task` and BOTH generic arguments are embedded
    ///                        symbolic references, resolved individually through the symbol
    ///                        table. So the type is read whole from reflection metadata, not
    ///                        borrowed from the getter's signature.
    /// [vwt]  size 0 / stride 0 / flags 0x00400000 — the incomplete placeholder again
    ///        (it embeds an `EphemeralService`, whose layout is resilient). Not a layout.
    /// [sym]  Getters @ 0x2ad4d6cc0 / 0x2ad4d6ccc; memberwise init @ 0x2ad4d6d04.
    ///        No conformance descriptor names this type: it conforms to nothing.
    ///        Not private.
    struct /* XPCSystem. */ EphemeralServiceWithListeningTask {
        let service: XPCDistributed.XPCSystem.EphemeralService
        let listeningTask: Task<XPCDistributed.XPCSystem.EphemeralService.ListeningToken, Never>

        init(service: XPCDistributed.XPCSystem.EphemeralService,
             listeningTask: Task<XPCDistributed.XPCSystem.EphemeralService.ListeningToken, Never>)
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: - InProcessService
    // ─────────────────────────────────────────────────────────────────────────────────

    /// A service that exists only inside one process: no launchd name, no endpoint, and —
    /// unlike `Service` and `EphemeralService` — no `ServiceRegistry` entry. The rendezvous
    /// is a single awaitable event instead.
    ///
    /// [refl] Field records, in order, both flags=0x00 (`let`):
    ///        `debugName`             `SS`
    ///        `receiverAttachedEvent` `{XPCDistributed.UnownedAwaitableEvent}y{…TransportReceiver}G`
    ///                                → `UnownedAwaitableEvent<TransportReceiver>`
    /// [sym]  Both fields are also printed parenthesised in their field-offset symbols
    ///        (`InProcessService.(debugName)` @ 0x2ad5203c8,
    ///        `InProcessService.(receiverAttachedEvent)` @ 0x2ad5203d0), so both members are
    ///        `private`; neither has a getter or a property descriptor, consistent with
    ///        that. The TYPE itself is not private — its nominal type descriptor
    ///        @ 0x2ad5269c8 is `S` and unparenthesised, and there is no anonymous
    ///        descriptor for it.
    /// [sym]  `__allocating_init(Swift.String)` has a method descriptor @ 0x2ad5269fc and a
    ///        dispatch thunk @ 0x2ad4c0570 — in the vtable, so not `final`.
    /// [sym]  No conformance descriptor names `InProcessService`. It conforms to NEITHER
    ///        `ConnectableService` NOR `ServiceRegistry.Key`, which is why its connect entry
    ///        point is a distinct private method with a different signature (returning a
    ///        `Transport`, not a `Session`) and why every `XPCSystem` entry point that
    ///        accepts it is a separate concrete overload rather than the generic
    ///        `<A: ConnectableService>` one.
    class /* XPCSystem. */ InProcessService {

        private let debugName: String
        private let receiverAttachedEvent:
            XPCDistributed.UnownedAwaitableEvent<XPCDistributed.XPCSystem.TransportReceiver>

        /// [sym] `InProcessService.init(Swift.String)` @ 0x2ad4be240 — no argument label,
        ///       so `_`. [inf] the parameter is the `debugName`: it is the only `String`
        ///       stored field [refl] and `connect(using:)` derives its transport labels
        ///       from it [dis].
        /// [dis] The init builds the `UnownedAwaitableEvent` via
        ///       `Combine.Future.init(((Result<A, B>) -> ()) -> ())`, confirming that
        ///       `UnownedAwaitableEvent` is Future/promise-backed.
        init(_ debugName: String)

        /// [sym] `InProcessService.(connect)(using: XPCDistributed.XPCSystem) async
        ///       throws(SetupError) -> Transport` @ 0x2ad4bda64 — private discriminator,
        ///       so `private`. Returns a `Transport`, not a `Session`, which is why it
        ///       cannot be the `ConnectableService` witness.
        /// [dis] Body: (1) `Transport.InProcessRawTransport.makePair(_: String)` →
        ///       `(outbound:, inbound:)`, with labels built from `debugName` plus small
        ///       strings, one of which decodes to "/inbound-"; (2) wrap each raw transport
        ///       in `Transport(debugName:rawTransport:)`; (3) `await` the
        ///       `receiverAttachedEvent` (a `Combine.Future.value` get) for a
        ///       `TransportReceiver`; (4) build `Session(actorSystem:transport:options:)`
        ///       for the receiver's end, start the peer task with
        ///       `Task.immediate(name:priority:executorPreference:operation:)` returning a
        ///       `Session.LocalInterface.ActivationToken`, register it in
        ///       `TransportReceiver.(PeerTaskTable).register(_:for:)`, and call
        ///       `Session.readyToReceive(_:)`; (5) return the caller's (outbound)
        ///       `Transport`. The body also contains `Swift._print_unlocked` calls — plain
        ///       `print`s, not `os_log`.
        /// [oslog] Corroborating that: attributing all 24 __oslogstring format strings to
        ///       the functions that pass them to `_os_log_impl` yields none in any
        ///       `InProcessService` function. The in-process path is instrumented with
        ///       `print`, the registry path with `os_log`. So the log-string evidence that
        ///       resolved the `Service`/`EphemeralService` branches has no counterpart here,
        ///       and the in-process behaviour rests on disassembly alone.
        private func connect(
            using actorSystem: XPCDistributed.XPCSystem
        ) async throws(XPCDistributed.XPCSystem.SetupError) -> XPCDistributed.XPCSystem.Transport

        deinit
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: - ServiceRegistry
    // ─────────────────────────────────────────────────────────────────────────────────

    /// The process-wide table of services this process is listening on. Its whole purpose
    /// is to let a client in the *same* process reach a listener without going through XPC:
    /// `Service.connect` and `EphemeralService.connect` consult it first.
    ///
    /// [refl] Field records: `$defaultActor` flags=0x06 type `BD`, and `services`
    ///        flags=0x02 type
    ///        `SDy{Swift.AnyHashable}{…ServiceRegistry.(RegisteredService)}G` — both
    ///        generic arguments are embedded symbolic references resolved through the
    ///        symbol table, so the KEY TYPE `Swift.AnyHashable` comes out of reflection
    ///        metadata directly. The generic `Key` is erased at the registry boundary.
    ///        `$defaultActor` plus [sym] `protocol conformance descriptor for
    ///        …ServiceRegistry : Swift.Actor` @ 0x2ad520440 make it an `actor`.
    ///        Flags 0x02 on `services` is the IsVar bit, so it is a `var`; 0x06 on
    ///        `$defaultActor` is IsVar plus the artificial bit the compiler sets on it.
    /// [sym]  Corroborated by `direct field offset for …ServiceRegistry.(services) :
    ///        [Swift.AnyHashable : …ServiceRegistry.(RegisteredService)]` @ 0x2ad520470,
    ///        parenthesised (a private member) and carrying the same dictionary type.
    /// [dis]  `unownedExecutor.getter` @ 0x2ad4c2010 is `mov x0, x20; mov x1, #0; ret` —
    ///        the default actor executor, no custom executor. The one-time initializer for
    ///        `shared` @ 0x2ad4c080c calls `swift_allocObject` then
    ///        `swift_defaultActor_initialize`, confirming the same.
    actor /* XPCSystem. */ ServiceRegistry {

        private var services: [AnyHashable: RegisteredService]

        /// [sym] `static ServiceRegistry.shared` @ 0x2d70d80d8, getter @ 0x2ad4c08a4,
        ///       `unsafeMutableAddressor` @ 0x2ad4c0854, `one-time initialization function
        ///       for shared` @ 0x2ad4c080c, token @ 0x2d70d7340.
        /// [dis] The initializer allocates a `ServiceRegistry` directly; there is no
        ///       `ServiceRegistry.init` symbol at all, so the implicit `init()` was inlined.
        static let shared: XPCDistributed.XPCSystem.ServiceRegistry

        /// [sym] Full signature from the symbol @ 0x2ad4c0900. Not `async`: an
        ///       actor-isolated synchronous method — callers `swift_task_switch` onto the
        ///       actor and then call it directly [dis].
        /// [oslog] 'Registered service %s in process-wide registry' (0x2ad52c100), passed
        ///       from this function and both its specialisations — Apple's own name for what
        ///       the registry is. `unregister` logs 'Unregistered service %s from registry'
        ///       (0x2ad52c130).
        /// [scan] Every caller of the generic body and of both specialisations
        ///       (`<Service>` @ 0x2ad4c7304, `<EphemeralService>` @ 0x2ad4c7684) is inside
        ///       `XPCSystem._listen(on:as:…)`. That exhaustiveness claim is admissible here
        ///       because [sym] none of `ServiceRegistry`'s four methods has a method
        ///       descriptor, a dispatch thunk, or a witness-table slot — the only
        ///       `ServiceRegistry`-related method descriptor in the module is
        ///       `ServiceRegistry.Key.debugName.getter` — so they cannot be reached by
        ///       vtable or witness dispatch. It remains possible in principle to reach one
        ///       through a captured function pointer, which the scan would miss.
        func register<Key: XPCDistributed.XPCSystem.ServiceRegistry.Key>(
            service: Key,
            receiver: XPCDistributed.XPCSystem.TransportReceiver,
            actorSystem: XPCDistributed.XPCSystem,
            targetQueue: __C.OS_dispatch_queue_serial
        )

        /// [sym] @ 0x2ad4c1204. [scan] Only called from `XPCSystem._listen`'s unwind path;
        ///       same admissibility argument as `register`.
        func unregister<Key: XPCDistributed.XPCSystem.ServiceRegistry.Key>(service: Key)

        /// The in-process short-circuit. [sym] Full signature @ 0x2ad4c15a0; returns
        /// `Session?` and is NOT `async`.
        /// [dis][oslog] Body, with the two `os_log` strings pinning the order. Box the key
        ///       with `Swift._convertToAnyHashable`; look it up in `services`; on a miss
        ///       return `nil`. On a hit:
        ///         1. `Session.LocalSessionState.clientSession(to: service)` then
        ///            `Session(actorSystem:local:options:)` — the CLIENT end. Logged at
        ///            +0x2d8 with 'Created local client session %s' (0x2ad52c180).
        ///         2. `DispatchQueue.asyncAndWait { … }` on the registered `targetQueue`.
        ///            That closure (`closure #1 () -> Session`) begins with
        ///            `swift_unownedRetainStrong` — the `unowned` `receiver` being safely
        ///            promoted to strong — and then builds a SECOND `LocalSessionState` and
        ///            `Session`, which it returns. So the SERVER end is constructed on the
        ///            listener's own queue, not on the registry actor.
        ///         3. Back on the actor, logged at +0x494 with
        ///            'Created local server session %s' (0x2ad52c160).
        ///         4. `swift_weakAssign` into `LocalSessionState.peerSession`, so that
        ///            direction of the pairing is weak.
        ///       Two sessions are created here, not one. This is the only construction site
        ///       of a `LocalSessionState` reached from this subsystem, and
        ///       `Session.Kind.local` is the case carrying a `LocalSessionState`, so this is
        ///       where a `.local` session comes from.
        /// [dis] `Session.LocalSessionState.clientSession(to:)` @ 0x2ad4bd608 labels the
        ///       session `"[local]" + key.debugName`; the prefix is a small string from
        ///       0x6c5b/0x636f/0x6c61/0x5d with discriminator 0xE7 (7 bytes).
        /// [scan] Callers: `Service.connect(from:with:)` and
        ///       `EphemeralService.connect(from:with:)`, and no others; same admissibility
        ///       argument as `register`.
        func lookUpAndConnect<Key: XPCDistributed.XPCSystem.ServiceRegistry.Key>(
            to service: Key,
            from actorSystem: XPCDistributed.XPCSystem,
            options: XPCDistributed.XPCSystem.Session.InitializationOptions
        ) -> XPCDistributed.XPCSystem.Session?

        /// [sym] @ 0x2ad4c1ec8. [scan] Only caller:
        ///       `static XPCDistributed.TestHook.peerTaskCount(for: Service) async -> Int?`
        ///       @ 0x2ad4f6884. Test-only surface.
        func peerTaskCount<Key: XPCDistributed.XPCSystem.ServiceRegistry.Key>(for service: Key) -> Int?

        /// One entry of `services`.
        ///
        /// [sym] `anonymous descriptor …ServiceRegistry.(RegisteredService)` @ 0x2ad526a74
        ///       plus a lowercase nominal type descriptor @ 0x2ad526a7c: a private TYPE.
        /// [refl] Field records, in order — and this is where reflection metadata replaced
        ///       what was going to be a name-based guess:
        ///         `receiver`    flags=0x02  `{…TransportReceiver}Xo`
        ///         `actorSystem` flags=0x00  `{XPCDistributed.XPCSystem}`
        ///         `targetQueue` flags=0x00  `So24OS_dispatch_queue_serialC`
        ///       The `Xo` suffix on `receiver`'s mangled type is UNOWNED (a weak field
        ///       would end in `Xw`), and its IsVar bit is set, so it is `unowned var`.
        ///       The other two are `let`. `targetQueue` is the imported ObjC class
        ///       `DispatchSerialQueue` -- whose mangled name **is** `So24OS_dispatch_queue_serialC`; an earlier revision claimed these were different types and they are not (measured with `_mangledTypeName(DispatchSerialQueue.self)`) — the
        ///       same spelling `register(…targetQueue:)` uses [sym].
        /// [dis] Ownership independently confirmed: `outlined copy of RegisteredService?`
        ///       @ 0x2ad4c626c calls, in field order, `swift_unownedRetain`,
        ///       `swift_retain`, `objc_retain`; `outlined consume` @ 0x2ad4c62b8 mirrors it
        ///       with `swift_unownedRelease`, `swift_release`, `objc_release`. Safe unowned,
        ///       not `unowned(unsafe)` — that would retain nothing at all.
        /// [vwt] size 24, stride 24: exactly three pointer-sized fields, so the field list
        ///       is complete.
        /// The load-bearing fact: the registry does not keep a listener alive.
        private struct RegisteredService {
            unowned var receiver: XPCDistributed.XPCSystem.TransportReceiver
            let actorSystem: XPCDistributed.XPCSystem
            let targetQueue: __C.OS_dispatch_queue_serial
        }

        deinit
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────
// MARK: - The XPCSystem entry points that name a service
// ─────────────────────────────────────────────────────────────────────────────────────
//
// All signatures below are [sym] — read verbatim off the demangled symbol, including
// `__owned`, `@Sendable`, `@isolated(any)`, the tuple return labels `(result:token:)`, and
// the typed `throws(SetupError)`. Only the notes are inference or disassembly.
//
// Two things worth noticing in the shapes:
//   * `Service`-taking overloads take a NON-optional `XPC.XPCPeerRequirement` and come with
//     a separate no-requirement overload; the `EphemeralService` and generic
//     `ConnectableService` overloads take `XPC.XPCPeerRequirement?`. There are no
//     `default argument N of` symbols for any of these, so they are genuinely distinct
//     overloads, not one function with a defaulted parameter.
//   * `InProcessService` overloads take no peer requirement at all (nothing to attest to
//     in-process), and `listen(on: InProcessService, …)` is the only one of the four
//     `listen` entry points declared with UNTYPED `throws` rather than
//     `throws(SetupError)`.

extension XPCDistributed.XPCSystem {

    // ── Listening ──────────────────────────────────────────────────────────────────

    /// The implementation all named/ephemeral listening funnels into.
    /// [dis] Body order: build `TransportReceiver(actorSystem:peerHandler:)`;
    ///   `listener.setIncomingSessionHandler(_:)`; `listener.setPeerRequirement(_:)` when the
    ///   requirement is non-nil; `listener.activate()`; register; suspend; on unwind
    ///   `await receiver.unwindPeers()` then `await ServiceRegistry.shared.unregister(service:)`.
    /// [dis] Registration is GATED ON `preserveSelfIPC`, and the branch is now resolved.
    ///   In the `<Service>` specialisation's continuation 1, at +0x2dc, the field-offset
    ///   global 0x2d70d80c8 is loaded and the flag byte read, then:
    ///       +0x2f0  tbz w8, #0, 0x2ad4cba0c    ; flag FALSE -> registry path
    ///   The fall-through (flag TRUE) goes straight to
    ///   `swift_task_addCancellationHandler` and suspends — it never registers. The taken
    ///   edge at 0x2ad4cba0c touches the `shared` one-time token (0x2d70d7340), loads
    ///   `static ServiceRegistry.shared` (0x2d70d80d8), reads `XPC.XPCListener.targetQueue`,
    ///   and hops onto the actor to reach the `register` call in continuation 2.
    ///   Two consequences: (a) `preserveSelfIPC` suppresses BOTH halves of the
    ///   same-process optimization — nothing registers and nothing looks up, so every
    ///   connection goes through real XPC, which is exactly what the env var promises;
    ///   (b) the `targetQueue` a `RegisteredService` stores is the listener's own
    ///   `targetQueue`, which is what makes `lookUpAndConnect`'s `asyncAndWait` land on the
    ///   listener's queue.
    /// [sym] @ 0x2ad4cd254, with specialisations for `Service` (0x2ad4cb508) and
    ///   `EphemeralService` (0x2ad4cc378) — the only two `ServiceRegistry.Key` types.
    /// The leading underscore is Apple's.
    func _listen<Key: XPCDistributed.XPCSystem.ServiceRegistry.Key>(
        on listener: XPC.XPCListener,
        as service: Key,
        forPeersSatisfying peerRequirement: XPC.XPCPeerRequirement?,
        executingForEachPeer body: @Sendable (
            __owned XPCDistributed.XPCSystem.Session.LocalInterface
        ) async -> (result: Void,
                    token: XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken)
    ) async throws(XPCDistributed.XPCSystem.SetupError)

    /// [sym] @ 0x2ad4cfc28.
    /// [dis] Creates a serial `DispatchQueue` whose label is a 33-byte literal
    ///   ("com.apple.XPCDistributed.Service.", `w0 = 0x21`, in __TEXT near 0x2ad524c60)
    ///   plus the service name, then
    ///   `XPCListener(service:targetQueue:options:incomingSessionHandler:)` with
    ///   `.inactive`, then hands off to `_listen`.
    /// [dis] NOTE: only `XPCListener.init(service:…)` appears — the listen path does NOT
    ///   branch on `Service.isMach`, unlike `Service.makeXPCSession`, which does. Checked
    ///   across every continuation of all three `listen(on: Service, …)` overloads; each
    ///   overload builds its own listener rather than forwarding to a sibling.
    func listen(
        on service: XPCDistributed.XPCSystem.Service,
        forPeersSatisfying peerRequirement: XPC.XPCPeerRequirement?,
        executingForEachPeer body: @Sendable (
            __owned XPCDistributed.XPCSystem.Session.LocalInterface
        ) async -> (result: Void,
                    token: XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken)
    ) async throws(XPCDistributed.XPCSystem.SetupError)

    /// [sym] @ 0x2ad4d33e0. Same shape, non-optional requirement, different second label.
    func listen(
        on service: XPCDistributed.XPCSystem.Service,
        forPeersSatisfying peerRequirement: XPC.XPCPeerRequirement,
        andExecuteForEachPeer body: @Sendable (
            __owned XPCDistributed.XPCSystem.Session.LocalInterface
        ) async -> (result: Void,
                    token: XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken)
    ) async throws(XPCDistributed.XPCSystem.SetupError)

    /// [sym] @ 0x2ad4d0324.
    func listen(
        on service: XPCDistributed.XPCSystem.Service,
        executingForEachPeer body: @Sendable (
            __owned XPCDistributed.XPCSystem.Session.LocalInterface
        ) async -> (result: Void,
                    token: XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken)
    ) async throws(XPCDistributed.XPCSystem.SetupError)

    /// [sym] @ 0x2ad4beef8. UNTYPED `throws` — the odd one out.
    /// [dis] Builds `TransportReceiver(actorSystem:peerHandler:)`, posts it into the
    ///   service's private `receiverAttachedEvent` (an indirect `blraa` through the promise
    ///   closure stored in the event, i.e. `UnownedAwaitableEvent.post(value:)` inlined),
    ///   installs a `swift_task_addCancellationHandler`, then suspends on a
    ///   `CheckedContinuation` until cancelled.
    /// [scan] It never touches `ServiceRegistry`: every `register`/`unregister` call site in
    ///   __text is inside `_listen`, and none is on this path. Admissible for the reason
    ///   given on `ServiceRegistry.register`.
    func listen(
        on service: XPCDistributed.XPCSystem.InProcessService,
        executingForEachPeer body: @Sendable (
            __owned XPCDistributed.XPCSystem.Session.LocalInterface
        ) async -> (result: Void,
                    token: XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken)
    ) async throws

    // ── Creating an ephemeral service ──────────────────────────────────────────────

    /// [sym] @ 0x2ad4d6650.
    /// [dis] Body: build a serial queue labelled with a 42-byte literal
    ///   ("com.apple.XPCDistributed.EphemeralService.", `x9 = 0x2a`, at 0x2ad524c60) plus
    ///   the name argument; `XPCListener(targetQueue:options: .inactive,
    ///   incomingSessionHandler:)` — the ANONYMOUS-listener initializer, no service name;
    ///   read `listener.endpoint`; build `EphemeralService(debugName:endpoint:)`; build
    ///   `EphemeralService.Receiver(service:actorSystem:listener:)`; call
    ///   `assumeActivatedIn` with that receiver to obtain the `Task`; `swift_task_create` a
    ///   detached `closure #2 () async -> ()` that `await`s `listeningTask.value` and, if
    ///   `token.id != receiver.id` (receiver `id` at object offset 0x10), calls
    ///   `Swift._assertionFailure` with "API violation: Returned token is not for the
    ///   EphemeralService.Receiver passed in." — string at 0x2ad524cb0; the referencing
    ///   function was found by scanning __text for adrp/add pairs producing that address,
    ///   which is how the assertion was tied to this function rather than guessed.
    ///   That check is the entire established purpose of `ListeningToken`.
    func makeEphemeralServiceWithListeningTask(
        _ debugName: String,
        assumeActivatedIn body: (XPCDistributed.XPCSystem.EphemeralService.Receiver)
            -> Task<XPCDistributed.XPCSystem.EphemeralService.ListeningToken, Never>
    ) -> XPCDistributed.XPCSystem.EphemeralServiceWithListeningTask

    /// [sym] @ 0x2ad4d6580. [dis] Calls the above and returns only its `.service`,
    ///   dropping the task.
    func makeEphemeralService(
        _ debugName: String,
        assumeActivatedIn body: (XPCDistributed.XPCSystem.EphemeralService.Receiver)
            -> Task<XPCDistributed.XPCSystem.EphemeralService.ListeningToken, Never>
    ) -> XPCDistributed.XPCSystem.EphemeralService

    // ── Connecting: makeRemoteInterface ────────────────────────────────────────────
    // [sym] Five overloads. The generic one is the shared shape; the concrete ones exist
    // separately, each with its own symbol and its own body.

    func makeRemoteInterface<S: XPCDistributed.XPCSystem.ConnectableService>(
        to service: S,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement?
    ) async throws(XPCDistributed.XPCSystem.SetupError)
        -> XPCDistributed.XPCSystem.Session.RemoteInterface                     // 0x2ad4cb0f4

    func makeRemoteInterface(
        to service: XPCDistributed.XPCSystem.Service,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement
    ) async throws(XPCDistributed.XPCSystem.SetupError)
        -> XPCDistributed.XPCSystem.Session.RemoteInterface                     // 0x2ad4d25b8

    func makeRemoteInterface(
        to service: XPCDistributed.XPCSystem.Service
    ) async throws(XPCDistributed.XPCSystem.SetupError)
        -> XPCDistributed.XPCSystem.Session.RemoteInterface                     // 0x2ad4cac68

    func makeRemoteInterface(
        to service: XPCDistributed.XPCSystem.EphemeralService,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement?
    ) async throws(XPCDistributed.XPCSystem.SetupError)
        -> XPCDistributed.XPCSystem.Session.RemoteInterface                     // 0x2ad4d3fe0

    /// [dis] `await service.connect(using: self)` for a `Transport`, then
    /// `Session(actorSystem:transport:options:)`.
    func makeRemoteInterface(
        to service: XPCDistributed.XPCSystem.InProcessService
    ) async throws(XPCDistributed.XPCSystem.SetupError)
        -> XPCDistributed.XPCSystem.Session.RemoteInterface                     // 0x2ad4bec3c

    // ── Connecting: withRemoteInterface ───────────────────────────────────────────
    // Two families: a `Result`-returning one (`B: Error`, typed-throwing body) and a
    // non-throwing one. Note `@isolated(any)` on the generic and ephemeral variants and its
    // absence on the `Service`/`InProcessService` variants — that asymmetry is in the
    // manglings, not an editing slip.

    func withRemoteInterface<A: Sendable, B: Error, S: XPCDistributed.XPCSystem.ConnectableService>(
        to service: S,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement?,
        perform body: @isolated(any) (XPCDistributed.XPCSystem.Session.RemoteInterface) async throws(B) -> A
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> Result<A, B>          // 0x2ad4ca640

    func withRemoteInterface<A: Sendable, S: XPCDistributed.XPCSystem.ConnectableService>(
        to service: S,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement?,
        perform body: @isolated(any) (XPCDistributed.XPCSystem.Session.RemoteInterface) async -> A
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> A                     // 0x2ad4c99a8

    func withRemoteInterface<A: Sendable, B: Error>(
        to service: XPCDistributed.XPCSystem.Service,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement,
        perform body: (XPCDistributed.XPCSystem.Session.RemoteInterface) async throws(B) -> A
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> Result<A, B>          // 0x2ad4d2180

    func withRemoteInterface<A: Sendable>(
        to service: XPCDistributed.XPCSystem.Service,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement,
        perform body: (XPCDistributed.XPCSystem.Session.RemoteInterface) async -> A
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> A                     // 0x2ad4d1d60

    func withRemoteInterface<A: Sendable, B: Error>(
        to service: XPCDistributed.XPCSystem.Service,
        perform body: (XPCDistributed.XPCSystem.Session.RemoteInterface) async throws(B) -> A
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> Result<A, B>          // 0x2ad4c9fc4

    func withRemoteInterface<A: Sendable>(
        to service: XPCDistributed.XPCSystem.Service,
        perform body: (XPCDistributed.XPCSystem.Session.RemoteInterface) async -> A
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> A                     // 0x2ad4c93ec

    func withRemoteInterface<A: Sendable, B: Error>(
        to service: XPCDistributed.XPCSystem.EphemeralService,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement?,
        perform body: @isolated(any) (XPCDistributed.XPCSystem.Session.RemoteInterface) async throws(B) -> A
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> Result<A, B>          // 0x2ad4d3d8c

    func withRemoteInterface<A: Sendable>(
        to service: XPCDistributed.XPCSystem.EphemeralService,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement?,
        perform body: @isolated(any) (XPCDistributed.XPCSystem.Session.RemoteInterface) async -> A
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> A                     // 0x2ad4d3b70

    func withRemoteInterface<A: Sendable, B: Error>(
        to service: XPCDistributed.XPCSystem.InProcessService,
        perform body: (XPCDistributed.XPCSystem.Session.RemoteInterface) async throws(B) -> A
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> Result<A, B>          // 0x2ad4be818

    func withRemoteInterface<A: Sendable>(
        to service: XPCDistributed.XPCSystem.InProcessService,
        perform body: (XPCDistributed.XPCSystem.Session.RemoteInterface) async -> A
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> A                     // 0x2ad4be3fc

    // ── Connecting bidirectionally: makeBidirectionalInterface ────────────────────

    func makeBidirectionalInterface<S: XPCDistributed.XPCSystem.ConnectableService>(
        to service: S,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement?,
        assumeLocalInterfaceActivatedIn body:
            (XPCDistributed.XPCSystem.Session.LocalInterface.UncheckedHandoff)
            -> Task<XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken, Never>
    ) async throws(XPCDistributed.XPCSystem.SetupError)
        -> XPCDistributed.XPCSystem.Session.RemoteInterface                     // 0x2ad4d189c

    func makeBidirectionalInterface(
        to service: XPCDistributed.XPCSystem.Service,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement,
        assumeLocalInterfaceActivatedIn body:
            (XPCDistributed.XPCSystem.Session.LocalInterface.UncheckedHandoff)
            -> Task<XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken, Never>
    ) async throws(XPCDistributed.XPCSystem.SetupError)
        -> XPCDistributed.XPCSystem.Session.RemoteInterface                     // 0x2ad4d2e2c

    func makeBidirectionalInterface(
        to service: XPCDistributed.XPCSystem.Service,
        assumeLocalInterfaceActivatedIn body:
            (XPCDistributed.XPCSystem.Session.LocalInterface.UncheckedHandoff)
            -> Task<XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken, Never>
    ) async throws(XPCDistributed.XPCSystem.SetupError)
        -> XPCDistributed.XPCSystem.Session.RemoteInterface                     // 0x2ad4d1338

    func makeBidirectionalInterface(
        to service: XPCDistributed.XPCSystem.EphemeralService,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement?,
        assumeLocalInterfaceActivatedIn body:
            (XPCDistributed.XPCSystem.Session.LocalInterface.UncheckedHandoff)
            -> Task<XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken, Never>
    ) async throws(XPCDistributed.XPCSystem.SetupError)
        -> XPCDistributed.XPCSystem.Session.RemoteInterface                     // 0x2ad4d45d0

    func makeBidirectionalInterface(
        to service: XPCDistributed.XPCSystem.InProcessService,
        assumeLocalInterfaceActivatedIn body:
            (XPCDistributed.XPCSystem.Session.LocalInterface.UncheckedHandoff)
            -> Task<XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken, Never>
    ) async throws(XPCDistributed.XPCSystem.SetupError)
        -> XPCDistributed.XPCSystem.Session.RemoteInterface                     // 0x2ad4bfea4

    // ── Connecting bidirectionally: withBidirectionalInterface ────────────────────

    func withBidirectionalInterface<A: Sendable, S: XPCDistributed.XPCSystem.ConnectableService>(
        to service: S,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement?,
        perform body: @isolated(any) (__owned XPCDistributed.XPCSystem.Session.LocalInterface)
            async -> (result: A,
                      token: XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken)
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> A                     // 0x2ad4d0ec8

    func withBidirectionalInterface<A: Sendable>(
        to service: XPCDistributed.XPCSystem.Service,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement,
        perform body: (__owned XPCDistributed.XPCSystem.Session.LocalInterface)
            async -> (result: A,
                      token: XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken)
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> A                     // 0x2ad4d2a94

    func withBidirectionalInterface<A: Sendable>(
        to service: XPCDistributed.XPCSystem.Service,
        perform body: (__owned XPCDistributed.XPCSystem.Session.LocalInterface)
            async -> (result: A,
                      token: XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken)
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> A                     // 0x2ad4d0a6c

    func withBidirectionalInterface<A: Sendable>(
        to service: XPCDistributed.XPCSystem.EphemeralService,
        assumingPeerSatisfies peerRequirement: XPC.XPCPeerRequirement?,
        perform body: (__owned XPCDistributed.XPCSystem.Session.LocalInterface)
            async -> (result: A,
                      token: XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken)
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> A                     // 0x2ad4d4378

    func withBidirectionalInterface<A: Sendable>(
        to service: XPCDistributed.XPCSystem.InProcessService,
        perform body: (__owned XPCDistributed.XPCSystem.Session.LocalInterface)
            async -> (result: A,
                      token: XPCDistributed.XPCSystem.Session.LocalInterface.ActivationToken)
    ) async throws(XPCDistributed.XPCSystem.SetupError) -> A                     // 0x2ad4bf84c
}

// ─────────────────────────────────────────────────────────────────────────────────────
// MARK: - Registration, discovery and connection, in one place
// ─────────────────────────────────────────────────────────────────────────────────────
//
// Two mechanisms, not one, and they do not share a table.
//
// (1) Named and ephemeral services — `ServiceRegistry`.
//     REGISTER: only `_listen(on:as:forPeersSatisfying:executingForEachPeer:)` registers
//       [scan, admissible because ServiceRegistry's methods have no vtable or witness
//       slots], and only when `preserveSelfIPC` is false [dis]. It puts a
//       `RegisteredService` {unowned var receiver, let actorSystem, let targetQueue —
//       the queue being the listener's own `XPCListener.targetQueue`} into
//       `ServiceRegistry.shared.services[AnyHashable(service)]`, and removes it on unwind
//       after `TransportReceiver.unwindPeers()`. `Service` reaches `_listen` through the
//       three `listen(on: Service, …)` overloads; `EphemeralService` reaches it through
//       `EphemeralService.Receiver.listen(forPeersSatisfying:executingForEachPeer:)`.
//     FIND + CONNECT: `ConnectableService.connect(from:with:)`. RESOLVED [dis] for
//       `Service.connect`, continuation 1 @ 0x2ad4d7100:
//         +0x05c  adrp/add 0x2d70d80c8      ; the XPCSystem.preserveSelfIPC field offset
//         +0x068  ldrb  w9, [x19, x9]      ; load the flag off the actor system
//         +0x06c  cmp   w9, #1
//         +0x070  b.ne  0x2ad4d7304        ; flag FALSE -> registry path
//       The fall-through (flag TRUE) logs and then `b 0x2ad4d74c0`, which is the
//       `makeXPCSession` / `XPCRawTransport` / `Session(actorSystem:transport:options:)`
//       block — no registry lookup at all. The `b.ne` side logs and reaches
//       0x2ad4d761c, which touches the `shared` one-time token at 0x2d70d7340 and then
//       `swift_task_switch`es into continuation 2, whose only call is
//       `lookUpAndConnect`. So `preserveSelfIPC == true` FORCES real XPC even to
//       yourself, exactly as the `XPCSYSTEM_PRESERVE_SELFIPC` env var name implies.
//       [oslog] Apple's own words for the two edges, emitted from this function:
//       'Using same-process optimization for service %s' and
//       'preserveSelfIPC set, forcing XPC for service %s'.
//       `EphemeralService.connect` has the SAME two edges — resolved, not inferred: it
//       carries its own pair of format strings, 'Using same-process optimization for
//       ephemeral service %s' and 'preserveSelfIPC set, forcing XPC for ephemeral
//       service %s', both passed from its continuation 1 [oslog].
//     Registry hit  -> TWO sessions: the client end via
//       `Session.LocalSessionState.clientSession(to:)` + `Session(actorSystem:local:options:)`
//       on the registry actor, and the server end built inside the `asyncAndWait` closure
//       on the listener's `targetQueue` [dis][oslog: 'Created local client session %s'
//       then 'Created local server session %s']. Both are `Session.Kind.local`, the case
//       that carries a `LocalSessionState`. Label `"[local]" + debugName`.
//     Registry miss -> `makeXPCSession` -> `Transport.XPCRawTransport` -> `Transport` ->
//       `Session(actorSystem:transport:options:)` -> `Session.Kind.xpc`.
//     The registry key is the service VALUE, and `EphemeralService`'s `Hashable` covers
//       both `debugName` and `endpoint` [dis], so two ephemeral services with the same
//       debug name but different endpoints are distinct entries.
//
// (2) `InProcessService` — no registry at all.
//     REGISTER/FIND: `listen(on: InProcessService, executingForEachPeer:)` posts a
//       `TransportReceiver` into the service object's own private
//       `UnownedAwaitableEvent<TransportReceiver>`; `InProcessService.connect(using:)`
//       awaits that same event. Discovery is by holding the `InProcessService` object, not
//       by looking anything up. `Transport.InProcessRawTransport.makePair(_:)` supplies
//       both ends of the transport.
//     `InProcessService` conforms to neither `ConnectableService` nor
//       `ServiceRegistry.Key`, which is why it has its own overload of every entry point.
//     RESOLVED, with the other agent's `Session.Kind` result: `.xpc` carries a `Transport`
//       and `.local` carries a `Session.LocalSessionState`. `InProcessService.connect`
//       yields a `Transport` and every session on that path is built with
//       `Session(actorSystem:transport:options:)`, never with the `local:` initializer, and
//       no `LocalSessionState` is constructed anywhere on it [dis]. So an
//       `InProcessService` session is `Session.Kind.xpc` running over an
//       `InProcessRawTransport` — the kind tracks which `Session` initializer ran, not
//       whether the bytes left the process. `.local` belongs exclusively to the
//       `ServiceRegistry` short-circuit. The two in-process mechanisms are therefore
//       genuinely different: one skips the transport entirely, the other keeps a full
//       transport and only skips XPC.

// ─────────────────────────────────────────────────────────────────────────────────────
// MARK: - Method note for the other agents
// ─────────────────────────────────────────────────────────────────────────────────────
//
// FIELD RECORDS ARE THE BEST TOOL FOR THIS SUBSYSTEM, and the symbol-table way of reading
// them is strictly better than walking descriptors. Every field type and every
// `let`-vs-`var` in this file came out of a field record's +0 flags and +4 mangled type
// name — not out of a getter. That matters most for `ServiceRegistry.RegisteredService`,
// which has no getters at all: without it, its three field types would have been a name
// match against `register(…)`'s parameter labels, exactly the inference this pass exists to
// prevent. It also CORRECTED a disassembly-based reading — `receiver` is `unowned var`, not
// the `unowned let` that the retain/release pattern alone suggested — and it gave
// `Service.isMach` a resolved type where only a visibility inference had been possible.
//
// The two refinements that made it work, both worth reusing verbatim:
//   * Do not scan `__swift5_fieldmd`. Take descriptor addresses from the
//     `reflection metadata field descriptor …` symbols, and resolve every symbolic
//     reference by `dladdr`-ing the TARGET ADDRESS and demangling the symbol you get back.
//     No parent-descriptor chain is walked, no unmapped page is touched, and the SIGBUS
//     problem disappears rather than being guarded against. It also crosses image
//     boundaries for free: `{XPC.XPCEndpoint}` and `{XPC.XPCListener}` came back as
//     `$s3XPC11XPCEndpointVMn` / `$s3XPC11XPCListenerCMn` in libswiftXPC, which a
//     descriptor walk could not read at all — and the `V`/`C` in those manglings even
//     settles struct-vs-class.
//   * Resolve symbolic references EMBEDDED IN a composite mangling, not just whole-string
//     ones. `Swift.Task<ListeningToken, Never>` and
//     `[Swift.AnyHashable : RegisteredService]` are each a mangling with two embedded
//     references; handling only the whole-string case leaves both unreadable.
//
// ENUM CASES: the sound test is whether a case's field record has a type reference at +4.
// It does not for any case of either `CodingKeys` here, which is what establishes them as
// payload-free — and the same reader shows `Transport.TransportError.transportCancelled`
// as `SS7message_t` and `Packet.Header.request` as `{ID64}2id_t`, i.e. it does distinguish
// payloads, which is the control that makes the negative result meaningful. Do NOT use
// `extraInhabitantCount == 256 − caseCount`: the Transport agent's `Packet.Header` reports
// 253 with three cases and is a two-payload enum, so the identity is necessary but not
// sufficient. `EphemeralService.CodingKeys` happens to satisfy it honestly (size 1, 254,
// two payload-free cases) — which is precisely why the coincidence is dangerous.
//
// VALUE-WITNESS TABLES: sound for struct size/stride, and decisive twice here —
// `RegisteredService` size 24 proved its three-field layout complete, `ListeningToken`
// size 8 proved its single field. But `EphemeralService` and
// `EphemeralServiceWithListeningTask` both HAVE a `value witness table for X` symbol and
// both report size 0 / stride 0 / flags 0x00400000: the incomplete-metadata placeholder for
// a type whose layout is resilient (both embed a resilient XPC type). A distinct trap from
// "only `full type metadata for X` exists" — here the symbol is present and the numbers are
// simply not a layout.
//
// __TEXT,__oslogstring WAS THE OTHER BIG WIN, and for this subsystem it did what no
// signature could. Extracting all 24 format strings and attributing each to the function
// that passes it in x3 to `_os_log_impl` turned two branch traces into Apple's own prose:
// 'preserveSelfIPC set, forcing XPC for service %s' versus 'Using same-process optimization
// for service %s'. That confirmed the `Service.connect` branch direction independently, and
// it UPGRADED `EphemeralService.connect` from "inferred to have the same shape" to resolved,
// because it carries its own matching pair. It also caught something the disassembly had
// glossed: `lookUpAndConnect` logs BOTH 'Created local client session %s' and 'Created
// local server session %s', so it creates two sessions, not one. Worth noting for others:
// absence is informative too — no oslog string is attributed to any `InProcessService`
// function, which corroborates that that path is instrumented with `print`
// (`_print_unlocked`) instead.

// ─────────────────────────────────────────────────────────────────────────────────────
// MARK: - Left unresolved
// ─────────────────────────────────────────────────────────────────────────────────────
//
// Shorter than it was: the field-record reader and __oslogstring closed four of the items
// that stood in the first pass (all field types including the cross-image ones,
// `Service.isMach`'s type, `EphemeralService.connect`'s branch direction, and `_listen`'s
// `preserveSelfIPC` gate). What remains:
//
//  1. `public` vs `internal`, everywhere. `private` IS resolved (anonymous descriptors for
//     types, private discriminators for members) — only three types in this subsystem are
//     private: `RegisteredService` and the two `CodingKeys`. The public/internal split is
//     not recoverable from this binary; linkage does not encode it, as `ID64` shows.
//  2. `Service.isMach`'s VISIBILITY. Its type (`Bool`) and `let`-ness are resolved [refl];
//     the `private` is inferred from the absence of the getter and property descriptor that
//     `name` has.
//  3. Why `EphemeralService.xpcEndpoint` exists alongside `endpoint`. Both getters fold to
//     one body returning the stored field; no protocol here requires the second spelling.
//  4. Why `ListeningToken` is `Codable`. Nothing in the framework codes it, and there is no
//     lazy witness-table accessor for either conformance. Only a client could answer it.
//  5. Whether `ServiceRegistry.Key` and `ConnectableService` also require `Sendable`.
//     Marker protocols leave no witness tables, so the symbol table cannot say.
//  6. Whether `EphemeralService.Receiver` and `InProcessService` are `open` or merely
//     non-final. Both have their init in the vtable (method descriptor + dispatch thunk),
//     which establishes non-final but not the access level.
//  7. `XPCSystem.listen(on: InProcessService, …)` being declared with untyped `throws`
//     while every sibling uses `throws(SetupError)`: read off the mangling and reproduced
//     faithfully, but the reason is not established. It may be an oversight in Apple's
//     source; do not silently "fix" it in our reimplementation without deciding to.
//  8. Whether `EphemeralService.init(debugName:endpoint:)` and
//     `EphemeralServiceWithListeningTask.init(service:listeningTask:)` are implicit
//     memberwise inits or explicitly written ones. The symbols are identical either way.
//  9. The exact `Session.Kind` stored by `Session(actorSystem:local:options:)` versus
//     `Session(actorSystem:transport:options:)`. This file's conclusions — registry hits
//     are `.local`, `InProcessService` sessions are `.xpc` over an `InProcessRawTransport`
//     — follow from which initializer each path calls plus the Session agent's finding that
//     `.local` carries a `LocalSessionState` and `.xpc` a `Transport`. The initializers
//     themselves are that agent's to disassemble.
