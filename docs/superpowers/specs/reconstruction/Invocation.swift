// Invocation.swift — reconstruction of Apple's `XPCDistributed` invocation-coding and
// result-handling surface, as declaration syntax.
//
// Covers, all nested in `XPCDistributed.XPCSystem`:
//
//   InvocationCodingKeys        (private, mangled discriminator)
//   InvocationEncoder           + DistributedTargetInvocationEncoder conformance
//   InvocationDecoder           + .Mode (private) + DistributedTargetInvocationDecoder conformance
//   EncodedInvocationDecoder    + DistributedTargetInvocationDecoder conformance
//   DirectInvocationDecoder     + DistributedTargetInvocationDecoder conformance
//   ResultHandler               + .Mode (private) + DistributedTargetInvocationResultHandler
//   EncodedResultHandler        + nested `ReplyHandler` protocol + the same conformance
//   DirectResultHandler         + the same conformance
//
// Source files (from the assertion-string file paths): `XPCDistributed/InvocationCoder.swift`
// and `XPCDistributed/InvocationResultHandler.swift`.
//
// Bodies are omitted. Every declaration carries how it was established. Addresses are unslid,
// from `xpcdump/macos27-XPCDistributed/symbols-demangled.txt`; disassembly is from
// `dump-function.py` against the live shared-cache image (macOS 27.0, arm64e).
//
// Three evidence sources beyond the symbol table and disassembly are used below, all read out
// of the loaded image:
//
//   (a) **Field records with their declared types.** A reflection field record is 12 bytes —
//       `flags` at +0, a relative pointer to the *mangled type name* at +4, the field name at
//       +8. `extract.py` (and therefore `field-descriptors.txt`) only ever read +8, which is
//       why the types are missing there. Following +4 and resolving the embedded symbolic
//       references gives the declared type of every stored property and every enum case
//       payload directly. Flag bit `0x2` is `IsVar`, which is where the `let`/`var` below comes
//       from. Two things this needs that a naive walk gets wrong: `ContextDescriptor.Parent` is
//       a `RelativeIndirectablePointer` (low bit set = the relative target is a pointer slot,
//       not the descriptor — adding the raw value lands on an odd address in another
//       shared-cache region and SIGBUSes), and indirect symbolic-reference slots hold signed
//       pointers whose PAC must be stripped.
//   (b) **Value witness tables.** `value witness table for X` → size at +0x40, stride at +0x48,
//       flags at +0x50, `extraInhabitantCount` at +0x54. Used here only for sizes and as
//       corroboration.
//       *Caveat, and it matters for the two `Mode` enums below:* the identity
//       `extraInhabitantCount == 256 - caseCount` is **necessary but not sufficient** for
//       payload-freeness. `Transport.Packet.(Header)` reports 253 with three cases and is a
//       two-payload enum — its extra inhabitants come from a spare tag byte and the numbers
//       coincide. Payloads are therefore settled from (a) below, never from this count.
//       Also note that a type whose metadata is completed at runtime has a *pre-completion*
//       VWT under this symbol, reporting size 0 — true here of `InvocationDecoder`,
//       `InvocationDecoder.Mode` and `EncodedInvocationDecoder`.
//   (c) **The privacy test is the symbol table, not the field descriptors.** The field-descriptor
//       extractor resolves context descriptors without their discriminators, so a `private` type
//       appears under its bare name and reads as internal. The real markers are a `LL` private
//       discriminator in the mangled symbol (the live demangler prints it as
//       `Foo.(Bar in _<hash>)`; `symbols-demangled.txt` strips the hash) and, for a
//       file-scope-private *type*, an `MXX` anonymous descriptor. Applied here by running the
//       live demangler over `dladdr`-recovered raw symbols:
//         private:      `XPCSystem.(InvocationCodingKeys in _D025C974E591FC5F9CCF5C171ECD5CA5)`,
//                       `InvocationDecoder.(Mode in _D025C974E591FC5F9CCF5C171ECD5CA5)`,
//                       `ResultHandler.(Mode in _AF3EABBF82306E763A49A69563B36D8F)`,
//                       `ResultHandler.(mode in _AF3EABBF82306E763A49A69563B36D8F)`.
//         not private:  `DirectInvocationDecoder` (`…VMn`), `DirectResultHandler` (`…CMn`),
//                       `EncodedResultHandler.ReplyHandler` (`…Mp`), and likewise
//                       `InvocationEncoder`, `InvocationDecoder`, `EncodedInvocationDecoder`,
//                       `EncodedResultHandler`, `ResultHandler` — all bare, no discriminator,
//                       no anonymous descriptor.
//       The discriminators also partition the subsystem by source file, which no other evidence
//       does: `_D025C974E591FC5F9CCF5C171ECD5CA5` covers `InvocationCodingKeys`,
//       `InvocationDecoder.Mode` and `EncodedInvocationDecoder._decodeErrorType` — so the keys,
//       the encoder and both decoders are one file, `InvocationCoder.swift`. A different hash,
//       `_AF3EABBF82306E763A49A69563B36D8F`, covers `ResultHandler.Mode`/`mode`, i.e.
//       `InvocationResultHandler.swift`. `Session.(RemoteInvocationReplyEncoder)` is a third,
//       `_F34001C6A313144E9D6E4C7E2E6275E3`.
//
//   (d) **Conformances are enumerated from `__TEXT,__swift5_proto`, not from symbol names.**
//       This matters because a `merged lazy protocol witness table accessor` prints only one of
//       the folded types' names, so the absence of a *named* accessor for a conformance proves
//       nothing. Conformance descriptors do not have that problem: they are one record per
//       declared conformance in a section, and the section is walkable. 192 records in this
//       module. Positive controls that Codable conformances do show up there: `Ack` 2 records,
//       `SwiftType` 5, `SharedActorKey` 5. Against those controls, each of
//       `InvocationEncoder`, `InvocationDecoder`, `EncodedInvocationDecoder`,
//       `DirectInvocationDecoder`, `ResultHandler`, `EncodedResultHandler` and
//       `DirectResultHandler` has **exactly one** record — the `Distributed` conformance named
//       in the symbol table and nothing else.
//
// Access levels: a declaration is written `public` when the symbol table exports it (`T`/`S`)
// and `internal` when it does not (`t`/`s`, or no symbol at all). That distinction is real but
// it does not separate `public` from `package` — see UNRESOLVED at the bottom.
//
// **All ten types here are non-generic**, checked by reading the `IsGeneric` bit (0x80 of the
// low flags byte) out of each nominal type descriptor: `InvocationEncoder` 0x00100051,
// `InvocationDecoder` 0x00110051, `InvocationDecoder.Mode` 0x00110052,
// `EncodedInvocationDecoder` 0x00110051, `DirectInvocationDecoder` 0x00100051, `ResultHandler`
// 0x80000050, `ResultHandler.Mode` 0x00100052, `EncodedResultHandler` 0x80010050,
// `DirectResultHandler` 0x80000050, `InvocationCodingKeys` 0x00000052 — bit 7 clear in every
// one. (The 0x80000000 on the classes is a class-specific flag field, not `IsGeneric`.) That
// check matters: a method of a generic type mangles only the requirements introduced at its own
// level, so a constraint on the enclosing type is invisible in the method's symbol. Because
// none of these types is generic, the generic signatures written below — which are read off the
// method manglings — are complete.
//
// Two label traps, both hit while writing this file:
//   - The `enum` vs `mp-enum` label in the field-descriptor dump is **not** evidence about
//     payloads. `InvocationDecoder.Mode` is labelled plain `enum` and both of its cases carry
//     payloads (resolved below).
//   - Field-descriptor order for an enum is **payload cases first, then payload-free cases**,
//     and multi-payload tag numbering follows that order — so it is tag order, not necessarily
//     declaration order. For both `Mode`s here every case has a payload, so the two coincide,
//     and the tags were independently read from the tag stores anyway.

import Distributed

extension XPCSystem {

    // MARK: - InvocationCodingKeys

    /// The wire keys of an encoded invocation.
    ///
    /// **Private**, three independent ways. The demangled symbols spell it
    /// `XPCDistributed.XPCSystem.(InvocationCodingKeys in _D025C974E591FC5F9CCF5C171ECD5CA5)`;
    /// there is an `anonymous descriptor XPCDistributed.XPCSystem.(InvocationCodingKeys)` at
    /// `0x2ad5276c0`; and `EncodedInvocationDecoder.container`'s mangled type name embeds a
    /// direct symbolic reference to this type's nominal descriptor, whose own symbol is
    /// `$s14XPCDistributed9XPCSystemC20InvocationCodingKeys33_D025C974E591FC5F9CCF5C171ECD5CA5LLOMn`
    /// — the `LL` is Swift's private-discriminator marker and the `O` is `enum`.
    /// `EncodedInvocationDecoder.(_decodeErrorType)` carries the same file discriminator, so
    /// both live in `InvocationCoder.swift`.
    ///
    /// **Payload-free**, resolved from the field records: all five case records carry a null
    /// relative pointer at +4, i.e. no payload type reference. (The value witness table
    /// `0x2d9b856f0` — size 1, stride 1, `extraInhabitantCount` 251 = 256 − 5 — agrees, but
    /// that arithmetic on its own would not have been proof; see the caveat in the header.)
    ///
    /// Note it is nested directly in `XPCSystem`, **not** in `InvocationEncoder`.
    ///
    /// It is declared `: CodingKey` and **not** `: String, CodingKey`. Resolved from the
    /// conformance list: the type has conformance descriptors for `CodingKey`, `Hashable`,
    /// `Equatable`, `CustomStringConvertible` and `CustomDebugStringConvertible`, and there is
    /// **no** `RawRepresentable` conformance anywhere for it. A `String`-raw-valued enum would
    /// have one, and its `CodingKey` witnesses would be forwarded through `rawValue`; here
    /// `CodingKey.stringValue.getter` (`0x2ad5009a0`) and
    /// `CodingKey.init(stringValue:)` (`0x2ad500a58`) are synthesized directly over the cases.
    ///
    /// Case tag values are 0…4 in declaration order, resolved from the single byte written into
    /// the key slot immediately before each `contains`/`decode` call:
    /// `0` protocolStub and `1` genericSubsitutions in
    /// `EncodedInvocationDecoder.decodeGenericSubstitutions` (`0x2ad500220 +0x034`, `+0x0fc`),
    /// `2` arguments in `EncodedInvocationDecoder.init(from:)` (`0x2ad4fffa8 +0x184`),
    /// `4` returnType in `EncodedInvocationDecoder.decodeReturnType` (`0x2ad500884 +0x01c`).
    /// `3` errorType is the only remaining value and is used by `_decodeErrorType`.
    ///
    /// The misspelling `genericSubsitutions` is Apple's and is load-bearing on the wire; it is
    /// already established in the wire-format spec and is not re-derived here.
    private enum InvocationCodingKeys: CodingKey {
        case protocolStub           // 0
        case genericSubsitutions    // 1  <-- Apple's misspelling, required
        case arguments              // 2
        case errorType              // 3
        case returnType             // 4
    }

    // MARK: - InvocationEncoder

    /// The outbound half. One of these is created per remote call by
    /// `XPCSystem.makeInvocationEncoder()`, filled by the four `record*` witnesses, and then
    /// either serialised (`encode(to:)`, reached from `InvocationContents`'s `Encodable`
    /// witness) or converted in-process (`makeDirectInvocationDecoder`).
    ///
    /// Field names, order, **declared types** and `let`/`var` all come straight out of the
    /// reflection field records (technique (a) above). Verbatim:
    ///
    ///     struct XPCDistributed.XPCSystem.InvocationEncoder        (recsize=12, n=5)
    ///         [0x02 var] protocolStub:        XPCDistributed.SwiftType?
    ///         [0x02 var] genericSubsitutions: [XPCDistributed.SwiftType]
    ///         [0x02 var] arguments:           [Swift.Decodable & Swift.Encodable]
    ///         [0x02 var] errorType:           XPCDistributed.SwiftType?
    ///         [0x02 var] returnType:          XPCDistributed.SwiftType?
    ///
    /// The struct descriptor at `0x2ad527608` gives `NumFields = 5` and
    /// `FieldOffsetVectorOffset = 2`, and the value witness table (`0x2d9b855d0`) gives
    /// size = stride = **88**, which is the same 88 that `makeInvocationEncoder()`
    /// (`0x2ad51e524`) zeroes. So the field list, the field types and the three-word `SwiftType`
    /// layout all agree.
    ///
    /// Field *offsets* were resolved separately, from disassembly, and are recorded because the
    /// argument-transform loop and the `SwiftType?` optional tests below are only legible with
    /// them:
    ///   - `errorType` at +0x28 (String at +0x28…+0x38, `type` at +0x38) — the two stores at the
    ///     end of `recordErrorType` (`0x2ad4ffa6c +0x030`, `+0x034`), which write the three-word
    ///     result of `SwiftType.init<A>(A.Type)`.
    ///   - `returnType` at +0x40 — the same pattern in `recordReturnType`
    ///     (`0x2ad4ffabc +0x060`, `+0x064`).
    ///   - `protocolStub` at +0x00, `genericSubsitutions` at +0x18, `arguments` at +0x20 — the
    ///     load pattern at the head of `makeDirectInvocationDecoder`
    ///     (`0x2ad501c68 +0x030…+0x044`), where +0x08/+0x10 are read as the second half of
    ///     `protocolStub`'s `String` and its `type`, +0x18 is walked as a 24-byte-stride array,
    ///     and +0x20 is walked as a 48-byte-stride array.
    ///
    /// Total 0x58 = 88 bytes, matching the VWT size above.
    ///
    /// `SwiftType.type` is **non-optional** `Any.Type`: `SwiftType.type.getter` (`0x2ad4f57ec`,
    /// 8 bytes) is a plain load and its demangled return type is `Any.Type`. The
    /// optional-ness tested at every use site above is `SwiftType?`'s, carried in the spare
    /// inhabitants of the `mangledTypeName` `String`'s object word.
    public struct InvocationEncoder {

        /// Resolved: `makeDirectInvocationDecoder` reads +0x08/+0x10 and passes
        /// `protocolStub?.type` on. Populated by `recordGenericSubstitution`, per the
        /// wire-format spec.
        internal var protocolStub: SwiftType?

        /// Resolved: 24-byte-stride array walked in `makeDirectInvocationDecoder`
        /// (`+0x070…+0x07c`), each element's +0x10 (`.type`) collected into `[Any.Type]`.
        internal var genericSubsitutions: [SwiftType]

        /// Resolved: `recordArgument` appends into a 48-byte-stride array via
        /// `generic specialization <Swift.Decodable & Swift.Encodable> of
        /// Swift.Array._appendElementAssumeUniqueAndCapacity` (`0x2ad4ff890 +0x150`).
        /// 48 bytes = 3-word inline buffer + metadata + two witness tables, i.e. an existential
        /// with exactly two conformances. Positional: no label or name is recorded.
        internal var arguments: [any Decodable & Encodable]

        /// Resolved: `recordErrorType` (`0x2ad4ffa6c`).
        internal var errorType: SwiftType?

        /// Resolved: `recordReturnType` (`0x2ad4ffabc`).
        internal var returnType: SwiftType?

        /// Resolved: `InvocationEncoder.init()` (`0x2ad4ff6bc`, 40 bytes, no calls) zeroes the
        /// 88-byte struct. Present as an exported symbol, so it is not the synthesized
        /// memberwise init.
        public init()

        // --- DistributedTargetInvocationEncoder conformance -------------------------------
        //
        // Conformance descriptor `0x2ad522af8`. Five witnesses and no more:
        //   recordGenericSubstitution 0x2ad4ffe90, recordArgument 0x2ad4ffea8,
        //   recordErrorType           0x2ad4fff08, recordReturnType 0x2ad4fff20,
        //   doneRecording             0x2ad4c6368.
        // There is no `recordProtocolStub` requirement and Apple did not add one; the stub is
        // captured inside `recordGenericSubstitution` (already in the wire-format spec).

        /// Resolved: `0x2ad4ff6e4` (340 bytes). Throws
        /// `Distributed.DistributedActorCodingError`; its two message literals
        /// (`"Encoding second _DistributedActorStub "`,
        /// `"Failed to record generic substitution of type "`) both resolve here. Already in
        /// the wire-format spec.
        public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws

        /// Resolved: `0x2ad4ff890`. Calls `RemoteCallArgument.value.getter` and appends the
        /// value into `arguments`; the `RemoteCallArgument` label/name are dropped.
        public mutating func recordArgument<Value: Decodable & Encodable>(
            _ argument: RemoteCallArgument<Value>
        ) throws

        /// Resolved: `0x2ad4ffa6c` (76 bytes). Body is `errorType = SwiftType(type)` — one call
        /// to `SwiftType.init<A>(A.Type)`, one release of the old String, two stores. **There is
        /// no throw path in the body**; `throws` comes from the protocol requirement.
        public mutating func recordErrorType<E: Error>(_ type: E.Type) throws

        /// Resolved: `0x2ad4ffabc` (124 bytes). Same shape as `recordErrorType` plus the two
        /// `swift_conformsToProtocol` calls that materialise `R`'s Decodable/Encodable witness
        /// tables. No throw path in the body.
        public mutating func recordReturnType<R: Decodable & Encodable>(_ type: R.Type) throws

        /// Resolved: `0x2ad4ffab8`, 4 bytes — a bare `ret`. A no-op. (Its protocol witness at
        /// `0x2ad4c6368` is a folded `ret` shared with several value witnesses; the folding is
        /// why that address appears under other names too.)
        public mutating func doneRecording() throws

        // --- serialisation ---------------------------------------------------------------

        /// Resolved: `0x2ad4ffb38`. Opens a keyed container over `InvocationCodingKeys`, writes
        /// the five keys (optionals omitted when nil), and traps rather than serialise a
        /// non-empty `genericSubsitutions`. Already in the wire-format spec.
        ///
        /// **`InvocationEncoder` does not conform to `Encodable`.** Resolved by walking
        /// `__TEXT,__swift5_proto` (technique (d)): the type has exactly one conformance record,
        /// and the symbol table names that one `DistributedTargetInvocationEncoder`. `Ack` (2
        /// records), `SwiftType` (5) and `SharedActorKey` (5) are the positive controls proving
        /// `Encodable`/`Decodable` conformances do appear in that section. This is a bare
        /// method, reached by a **direct** call from
        /// `RemoteInvocationRequest.(InvocationContents)`'s `Encodable` witness
        /// (`0x2ad50db44`), not through a witness table. See the contradiction note at the
        /// bottom of this file.
        public func encode(to encoder: any Encoder) throws

        // --- the in-process shortcut -----------------------------------------------------

        /// Converts a filled encoder into a `DirectInvocationDecoder` without going near the
        /// wire. Resolved from disassembly of `0x2ad501c68` (788 bytes), end to end:
        ///
        ///   protocolStub         = self.protocolStub?.type          (+0x048 csel on the
        ///                                                            String object word)
        ///   genericSubstitutions = self.genericSubsitutions.map(\.type)
        ///                                                          (+0x064…+0x0ac loop)
        ///   arguments            = try self.arguments.map {
        ///                              try InvocationEncoder.transformValueForDirectInvocation(
        ///                                  $0, senderSession: senderSession,
        ///                                  receiverSession: receiverSession) }
        ///                                                          (+0x110…+0x288 loop)
        ///   currentArgumentIndex = 0                               (+0x2cc `stp x20, xzr`)
        ///   errorType            = self.errorType?.type
        ///   returnType           = self.returnType?.type            (+0x2ac…+0x2d0, both
        ///                                                            computed in one NEON
        ///                                                            zip1/zip2/cmeq/bic
        ///                                                            sequence)
        ///
        /// The `throws` is entirely `transformValueForDirectInvocation`'s: the only error edge
        /// in the function is the `cbnz x21` after that call (+0x198). The generic-substitution
        /// loop performs **no** nil check and **no** `_DistributedActorStub` check — unlike the
        /// encoded path, see `EncodedInvocationDecoder.decodeGenericSubstitutions`.
        ///
        /// One direct call site was found by a b/bl scan of `__text`
        /// (0x2ad4bc620…0x2ad5202c0): `Session.(executeDirectInvocation)`'s
        /// `(2) suspend resume partial function` at `0x2ad519eb4`. A scan of that kind cannot
        /// see `blraa` indirect dispatch, so this is "one direct call site", not "the only
        /// caller" — and a zero result from such a scan means "always inlined or
        /// vtable/witness-dispatched", never "unused".
        ///
        /// **Sequencing**, from `__TEXT,__oslogstring` (a section separate from `__cstring` and
        /// absent from our dump; `_os_log_impl` takes the format string in `x3`, so the
        /// references were found by scanning for adrp/add pairs):
        ///   - `"Direct invocation to %s for %s"` (`0x2ad52c520`) is logged in
        ///     **`Session.sendInvocation`** at +0x3c8 — so the same-process fork is decided in
        ///     `sendInvocation`, *before* `executeDirectInvocation` is entered, and it is tested
        ///     ahead of the encoded arm, whose
        ///     `"Created request %llu targeting %s for invocation %s"` (`0x2ad52c4e0`) is logged
        ///     in the same function at +0x850.
        ///   - `"Direct invocation completed for %s"` (`0x2ad52c540`) is logged in
        ///     `executeDirectInvocation`'s `(3) await resume partial function` at +0x3f8, which
        ///     is the same partial function that calls
        ///     `transformValueForDirectInvocation` at +0x750. The log precedes the call, so the
        ///     **return value is transformed after the invocation is considered complete** —
        ///     i.e. the return-value transform is not inside the timed/logged region.
        ///   - The inbound encoded counterpart,
        ///     `"Received request %llu targeting %s for invocation %s"` (`0x2ad52c450`), is in
        ///     `Session.handleReceivedRequest+0xf10`.
        public func makeDirectInvocationDecoder(
            senderSession: Session,
            receiverSession: Session
        ) throws -> DirectInvocationDecoder

        /// Re-homes one value from the sender's session to the receiver's. Resolved from
        /// disassembly of `0x2ad501868` (1024 bytes):
        ///
        ///   if String(reflecting: type(of: value as Any)).contains("ActorReference<") {
        ///       let node = try XPC.encodeToEncodingContainer(
        ///           value,
        ///           userInfo: [.sessionKey: senderSession,
        ///                      .actorSystemKey: senderSession.actorSystem])
        ///       return try XPC.decodeFromEncodingContainer(
        ///           A.self, from: node,
        ///           userInfo: [.sessionKey: receiverSession,
        ///                      .actorSystemKey: receiverSession.actorSystem])
        ///   } else {
        ///       return value   // value-witness initializeWithCopy, +0x390
        ///   }
        ///
        /// Every link resolved: `swift_getDynamicType` (+0x04c),
        /// `swift_getMetatypeMetadata` (+0x058), `String.init(reflecting:)` (+0x064),
        /// Foundation's `StringProtocol.contains` (+0x0b4), the branch
        /// `tbz w20, #0, 0x2ad501bf8` (+0x0c4) that takes the copy path when the match fails,
        /// two `[CodingUserInfoKey: Any]` dictionary literals of exactly two entries each
        /// (`swift_arrayDestroy` count 2, +0x260/+0x348) whose keys are
        /// `(extension in XPCDistributed):CodingUserInfoKey.sessionKey` (the lazily-initialised
        /// global at `0x2d70d8078`, reached through `__swift_project_value_buffer` at +0x1b4)
        /// and `Distributed`'s `CodingUserInfoKey.actorSystemKey` (+0x21c/+0x310), whose values
        /// are the session and `session.actorSystem` (`Session`+0x10, its first stored field),
        /// then `XPC.encodeToEncodingContainer` (+0x288) and
        /// `XPC.decodeFromEncodingContainer` (+0x374) from libswiftXPC.
        ///
        /// The two dictionary literals match
        /// `(extension in XPCDistributed):Dictionary<CodingUserInfoKey, Any>.init(session:xpcSystem:)`
        /// (`0x2ad50b4cc`), inlined.
        ///
        /// `"ActorReference<"` is 15 bytes, i.e. a Swift small string: it is built from
        /// `movz`/`movk` immediates at +0x06c/+0x080 and appears in no string table.
        ///
        /// The `throws` is the two `XPC.*` calls'. Two direct call sites found in the same scan:
        /// `makeDirectInvocationDecoder+0x190` (the argument loop) and
        /// `Session.(executeDirectInvocation)`'s `(3) await resume partial function`
        /// at `0x2ad51aaa8` — the latter is the return-value transform, matching the string
        /// `"Failed to transform return value: "`.
        public static func transformValueForDirectInvocation<Value: Decodable & Encodable>(
            _ value: Value,
            senderSession: Session,
            receiverSession: Session
        ) throws -> Value
    }

    // MARK: - InvocationDecoder

    /// The type that carries the `DistributedActorSystem.InvocationDecoder` associated type
    /// (associated-type witness accessor `0x2ad51fe44`). A one-field wrapper that forwards
    /// every requirement to whichever concrete decoder it holds.
    ///
    /// `struct`, one stored field `mode`: reflection metadata. `mode` is at offset 0x00 —
    /// `errorType.getter` (`0x2ad501700`) uses `x20` (self) directly as the enum's address.
    public struct InvocationDecoder {

        /// **Private** — the demangled symbols spell it
        /// `InvocationDecoder.(Mode in _D025C974E591FC5F9CCF5C171ECD5CA5)`, the same
        /// `InvocationCoder.swift` file discriminator as `InvocationCodingKeys`.
        ///
        /// **Both cases carry payloads, and these are their types** — resolved from the field
        /// records, which is the only sound way to answer this. Verbatim:
        ///
        ///     enum XPCDistributed.XPCSystem.InvocationDecoder.(Mode)     (recsize=12, n=2)
        ///         encoded: XPCDistributed.XPCSystem.EncodedInvocationDecoder
        ///         direct:  XPCDistributed.XPCSystem.DirectInvocationDecoder
        ///
        /// Note the dump labels this one a plain `enum`, not `mp-enum`, which is why the label
        /// must not be used as evidence about payloads. `swift_storeEnumTagMultiPayload` /
        /// `swift_getEnumCaseMultiPayload` are used on it throughout, which agrees.
        ///
        /// Tag values resolved:
        ///   - tag 0 = `.encoded` — `init(from:)` (`0x2ad500ea0 +0x0ac`) stores tag `#0`
        ///     immediately after `EncodedInvocationDecoder.init(from:)` returns.
        ///   - tag 1 = `.direct` — `init(direct:)` (`0x2ad500f8c +0x034`) stores tag `#1`.
        ///     That init also copies 0x30 = 48 bytes, which is `DirectInvocationDecoder`'s size.
        ///   - `errorType.getter` reads the payload at self+0x20 when the case is 1, which is
        ///     `DirectInvocationDecoder.errorType`'s offset — corroborating case 1 = `.direct`.
        ///
        /// Case order in the field records is `encoded`, `direct`; for an enum that order is
        /// payload-cases-first and matches multi-payload tag numbering, so it independently
        /// implies `encoded` = 0 and `direct` = 1 — which is what the tag stores say.
        private enum Mode {
            case encoded(EncodedInvocationDecoder)
            case direct(DirectInvocationDecoder)
        }

        /// `var`: field-record flags `0x02`. (Contrast `ResultHandler.mode`, which is `let`.)
        private var mode: Mode

        /// Resolved: `0x2ad500ea0` (236 bytes). Calls `EncodedInvocationDecoder.init(from:)`
        /// on the incoming decoder and injects tag 0.
        ///
        /// **Not a `Decodable` witness.** There is no
        /// `protocol conformance descriptor for InvocationDecoder : Swift.Decodable` in the
        /// image; this is a plain initializer that happens to take a `Decoder`.
        public init(from decoder: any Decoder) throws

        /// Resolved: `0x2ad500f8c` (84 bytes) — copy 48 bytes, inject tag 1.
        public init(direct: DirectInvocationDecoder)

        /// Resolved: `0x2ad501700` (76 bytes). `switch mode` on the multi-payload tag; case 1
        /// (`.direct`) loads payload+0x20, otherwise loads `EncodedInvocationDecoder.errorType`
        /// through the resilient field-offset vector. Computed, no backing field.
        ///
        /// Exists in addition to `decodeErrorType()` because callers need the error type
        /// *before* invoking the target (it is what tells the result handler whether the target
        /// can throw). Where exactly it is read is not established here — see UNRESOLVED.
        public var errorType: Any.Type? { get }

        // --- DistributedTargetInvocationDecoder conformance -------------------------------
        //
        // Conformance descriptor `0x2ad522bd8`; witnesses at 0x2ad50174c, 0x2ad501764,
        // 0x2ad5017f4, 0x2ad501850. All four bodies switch on `mode`, mutate the payload in
        // place, and re-store the enum tag; resolved from the call annotations of
        // 0x2ad500fe0 / 0x2ad50121c / 0x2ad501500 / 0x2ad50155c, each of which contains a
        // `swift_getEnumCaseMultiPayload` … `swift_storeEnumTagMultiPayload` pair around a call
        // into the `EncodedInvocationDecoder` method of the same name.

        public mutating func decodeGenericSubstitutions() throws -> [Any.Type]
        public mutating func decodeNextArgument<Argument: Decodable & Encodable>() throws -> Argument
        public mutating func decodeErrorType() throws -> Any.Type?
        public mutating func decodeReturnType() throws -> Any.Type?
    }

    // MARK: - EncodedInvocationDecoder

    /// The wire-side decoder — what an inbound `RemoteInvocationRequest` produces, and the
    /// thing `InvocationDecoder.Mode.encoded` wraps.
    ///
    /// Three stored fields, in this order (reflection metadata). Order corroborated by
    /// `decodeErrorType()` (`0x2ad50084c`), which reads field-offset-vector slot 2
    /// (metadata+0x18) for `errorType`, and `decodeNextArgument` (`0x2ad500714 +0x054`), which
    /// reads slot 1 (metadata+0x14) for `argumentDecoder`. Field offsets are resilient — the
    /// type has a metadata completion function and a singleton init cache.
    public struct EncodedInvocationDecoder {

        /// Resolved from the field record. Its mangled type name is
        /// `\x02<indirect ref> y \x01<direct ref> G` — a generic nominal type applied to one
        /// argument, where the direct reference resolves to
        /// `$s14XPCDistributed9XPCSystemC20InvocationCodingKeys33_D025…LLOMn`, i.e.
        /// `InvocationCodingKeys`'s nominal descriptor. The generic type itself is behind the
        /// indirect reference (a cross-image GOT slot that `dladdr` will not attribute) and is
        /// pinned by two other things: `init(from:)` (`0x2ad4fffa8 +0x144`) calls
        /// `Decoder.container(keyedBy:)`, whose return type it is, and
        /// `_decodeErrorType`'s own symbol spells the parameter
        /// `Swift.KeyedDecodingContainer<XPCDistributed.XPCSystem.(InvocationCodingKeys)>`.
        ///
        /// `let`: field-record flags `0x00`. The container is held for the lifetime of the
        /// decoder; `decodeGenericSubstitutions`, `decodeReturnType` and `_decodeErrorType` all
        /// read from it later, and none of them writes it back.
        internal let container: KeyedDecodingContainer<InvocationCodingKeys>

        /// **This is the retained-unconsumed arguments container.**
        ///
        /// Type resolved from the field record: the mangled name is `\x02<indirect ref>_pSg`,
        /// which is `Optional<any P>` for **exactly one** protocol `P` — the single `_p` rules
        /// out a composition. `P` is `UnkeyedDecodingContainer`: that is the return type of
        /// `nestedUnkeyedContainer(forKey:)`, which is what fills the field. `var`:
        /// field-record flags `0x02`.
        ///
        /// Resolved: `init(from:)`
        /// does `container.contains(.arguments)` (+0x198, key byte 2) and, if present,
        /// `container.nestedUnkeyedContainer(forKey: .arguments)` (+0x1bc), then
        /// `outlined assign with take of Swift.UnkeyedDecodingContainer?` (+0x1d0). Absent key
        /// leaves it `nil`.
        ///
        /// It is a `var` because `decodeNextArgument` mutates it: `0x2ad500714` copies the
        /// existential out (+0x06c), `__swift_mutable_project_boxed_opaque_existential_1Tm`
        /// (+0x07c), dispatches `UnkeyedDecodingContainer.decode<T>(_:)` (+0x0a0), then destroys
        /// the stored optional (+0x0ac) and writes the advanced container back (+0x0b8). The
        /// arguments are consumed positionally, in call order, one per `decodeNextArgument`.
        ///
        /// (The outlined helpers around this are named
        /// `outlined init with copy of Swift.Decoder` / `outlined destroy of
        /// Swift.UnkeyedDecodingContainer?` — same-shape 5-word boxed existentials get folded
        /// together, so the name in the symbol is only one of the folded types. Do not read the
        /// name as the type.)
        internal var argumentDecoder: (any UnkeyedDecodingContainer)?

        /// Type resolved from the field record with no symbolic references at all: the mangled
        /// name is the literal `ypXpSg` = `Optional<Any.Type>` (`yp` Any, `Xp` existential
        /// metatype, `Sg` Optional). `let`: flags `0x00`.
        ///
        /// Resolved: `init(from:)` (+0x1dc) calls `_decodeErrorType(from: container)` and
        /// stores the result; `decodeErrorType()` (`0x2ad50084c`, 56 bytes) is nothing but a
        /// load of this field. Decoded eagerly at init time, unlike `returnType`.
        public let errorType: Any.Type?

        /// Resolved: `0x2ad4fffa8` (632 bytes). Opens the keyed container, optionally builds
        /// `argumentDecoder`, and decodes `errorType`.
        ///
        /// **Not a `Decodable` witness** — no
        /// `EncodedInvocationDecoder : Swift.Decodable` conformance descriptor exists. It is
        /// called directly by `RemoteInvocationRequest.(InvocationContents).init(from:)`.
        public init(from decoder: any Decoder) throws

        /// Private helper. Full symbol:
        /// `static XPCDistributed.XPCSystem.EncodedInvocationDecoder.(_decodeErrorType in
        /// _D025C974E591FC5F9CCF5C171ECD5CA5)(from: Swift.KeyedDecodingContainer<...>)
        /// throws -> Any.Type?`. Only a
        /// `function signature specialization <Arg[1] = Dead>` of it survives, at `0x2ad502400`
        /// (180 bytes): `container.contains(.errorType)`, then
        /// `container.decode(SwiftType.self, forKey: .errorType).type`, else nil.
        ///
        /// Its signature independently confirms that this decoder reads a keyed
        /// `InvocationCodingKeys` container.
        private static func _decodeErrorType(
            from container: KeyedDecodingContainer<InvocationCodingKeys>
        ) throws -> Any.Type?

        // --- DistributedTargetInvocationDecoder conformance -------------------------------
        // Conformance descriptor `0x2ad522b48`; witnesses 0x2ad500934, 0x2ad50094c
        // (+ a merged variant at 0x2ad501790), 0x2ad500978, 0x2ad500988.

        /// Resolved: `0x2ad500220` (768 bytes), read instruction by instruction.
        ///
        ///   var subs: [SwiftType] = []
        ///   if container.contains(.protocolStub) {                       // key 0, +0x034
        ///       subs.append(try container.decode(SwiftType.self, forKey: .protocolStub))
        ///   }
        ///   if container.contains(.genericSubsitutions) {                // key 1, +0x0fc
        ///       subs.append(contentsOf:
        ///           try container.decode([SwiftType].self, forKey: .genericSubsitutions))
        ///   }
        ///   var out: [Any.Type] = []
        ///   for s in subs {                                              // stride 0x18, +0x10
        ///       guard <s.type conforms to Distributed._DistributedActorStub> else {
        ///           throw DistributedActorCodingError(
        ///               message: "Failed to decode generic substitution.")   // len 0x26 = 38
        ///       }
        ///       out.append(s.type)
        ///   }
        ///   return out
        ///
        /// Two facts worth carrying forward. First, **`protocolStub` is returned to the Swift
        /// runtime as a generic substitution** — the two wire keys are merged into the one
        /// `[Any.Type]` the requirement returns, stub first. Second, the guard at +0x1d4 is
        /// `swift_conformsToProtocol2(type, <protocol descriptor for
        /// Distributed._DistributedActorStub>)`; the descriptor was resolved by reading the
        /// authenticated GOT slot at `0x2d01029f0` in the live image. So Apple's decoder
        /// **rejects any substitution that is not an actor stub**, which is the receive-side
        /// counterpart of the encoder trapping on a non-empty `genericSubsitutions`.
        public mutating func decodeGenericSubstitutions() throws -> [Any.Type]

        /// Resolved: `0x2ad500714` (312 bytes).
        ///
        ///   guard argumentDecoder != nil else {                          // +0x060 cbz on the
        ///       throw DistributedActorCodingError(                       //   existential's
        ///           message: "Found no arguments from decoder.")         //   metadata word
        ///   }
        ///   return try argumentDecoder!.decode(Argument.self)            // + write-back
        public mutating func decodeNextArgument<Argument: Decodable & Encodable>() throws -> Argument

        /// Resolved: `0x2ad50084c` (56 bytes) — returns the stored `errorType`. Cannot throw in
        /// practice; the key was already read in `init(from:)`.
        public mutating func decodeErrorType() throws -> Any.Type?

        /// Resolved: `0x2ad500884` (176 bytes). `container.contains(.returnType)` (key byte 4),
        /// then `container.decode(SwiftType.self, forKey: .returnType).type`, else nil. Decoded
        /// lazily, on each call — the asymmetry with `errorType` is real.
        public mutating func decodeReturnType() throws -> Any.Type?
    }

    // MARK: - DirectInvocationDecoder

    /// The in-process decoder. Never serialises; produced only by
    /// `InvocationEncoder.makeDirectInvocationDecoder`.
    ///
    /// Six stored fields, with names, declared types and `let`/`var` all read from the field
    /// records. Verbatim:
    ///
    ///     struct XPCDistributed.XPCSystem.DirectInvocationDecoder    (recsize=12, n=6)
    ///         [0x00 let] protocolStub:         Any.Type?
    ///         [0x00 let] genericSubstitutions: [Any.Type]
    ///         [0x00 let] arguments:            [Swift.Decodable & Swift.Encodable]
    ///         [0x02 var] currentArgumentIndex: Swift.Int
    ///         [0x00 let] errorType:            Any.Type?
    ///         [0x00 let] returnType:           Any.Type?
    ///
    /// `currentArgumentIndex` is the only `var` — which is the cleanest single statement of what
    /// it participates in. Value witness table (`0x2d9b85660`): size = stride = **48**,
    /// confirming six single-word fields and no padding.
    ///
    /// Offsets resolved from the
    /// 16-byte `init` at `0x2ad500b0c`, from `errorType.getter`/`decodeErrorType`
    /// (`ldr x0, [x20, #0x20]`), `decodeReturnType` (`ldr x0, [x20, #0x28]`), and from
    /// `decodeNextArgument`'s `ldp x8, x26, [x20, #0x10]`:
    ///
    ///   +0x00 protocolStub   +0x08 genericSubstitutions   +0x10 arguments
    ///   +0x18 currentArgumentIndex   +0x20 errorType   +0x28 returnType     (48 bytes total)
    ///
    /// Note it spells the field `genericSubstitutions` **correctly** — the misspelling only
    /// exists where it reaches the wire.
    public struct DirectInvocationDecoder {

        internal let protocolStub: Any.Type?
        internal let genericSubstitutions: [Any.Type]

        /// Resolved: `decodeNextArgument` indexes this with stride 48
        /// (`add x9, x26, x26, lsl #1` then `lsl #4`), which is a two-conformance existential.
        internal let arguments: [any Decodable & Encodable]

        /// **What it participates in:** it is the read cursor of `arguments`, and nothing else.
        /// Resolved from `decodeNextArgument` (`0x2ad500bd0`): it is compared against
        /// `arguments.count` (+0x0b8), used as the element index (+0x0c4…+0x0d0), and
        /// incremented *only after the dynamic cast to `Argument` succeeds*
        /// (+0x128 `add x8, x26, #1`; +0x12c `str x8, [x20, #0x18]`). No other function in the
        /// image references it — it has no getter symbol, no property descriptor, and is not
        /// an `init` parameter. It is the direct-path analogue of `EncodedInvocationDecoder`'s
        /// mutated `argumentDecoder`.
        internal var currentArgumentIndex: Int = 0

        internal let errorType: Any.Type?
        internal let returnType: Any.Type?

        /// Resolved: `0x2ad500b0c`, 16 bytes:
        ///   stp x0, x1, [x8]        // protocolStub, genericSubstitutions
        ///   stp x2, xzr, [x8,#0x10] // arguments, currentArgumentIndex = 0
        ///   stp x3, x4, [x8,#0x20]  // errorType, returnType
        ///
        /// Hand-written, not the synthesized memberwise init: it is an exported (`T`) symbol,
        /// memberwise inits are internal, and `currentArgumentIndex` — a `var` — is absent from
        /// the parameter list, which a memberwise init would include as a defaulted parameter.
        public init(
            protocolStub: Any.Type?,
            genericSubstitutions: [Any.Type],
            arguments: [any Decodable & Encodable],
            errorType: Any.Type?,
            returnType: Any.Type?
        )

        /// Resolved: `0x2ad500b04`, 8 bytes — `ldr x0, [x20, #0x20]; ret`.
        public var errorType: Any.Type? { get }

        // --- DistributedTargetInvocationDecoder conformance -------------------------------
        // Conformance descriptor `0x2ad522b90`; witnesses 0x2ad500e1c, 0x2ad500e34,
        // 0x2ad500e90, 0x2ad500e98.

        /// Resolved: `0x2ad500b1c` (180 bytes). Same merge as the encoded path —
        /// `(protocolStub.map { [$0] } ?? []) + genericSubstitutions` — but with **no**
        /// `_DistributedActorStub` check.
        public mutating func decodeGenericSubstitutions() throws -> [Any.Type]

        /// Resolved: `0x2ad500bd0` (572 bytes).
        ///
        ///   guard currentArgumentIndex < arguments.count else {
        ///       throw DistributedActorCodingError(
        ///           message: "No more arguments to decode.")             // len 0x1c = 28
        ///   }
        ///   guard let v = arguments[currentArgumentIndex] as? Argument else {   // +0x104
        ///       throw DistributedActorCodingError(                        //   swift_dynamicCast
        ///           message: "Failed to cast argument to expected type "  // len 0x29 = 41
        ///                    + _typeName(Argument.self, qualified: false))
        ///   }
        ///   currentArgumentIndex += 1
        ///   return v
        ///
        /// **This cast throws rather than traps, and that was checked rather than assumed.**
        /// `swift_dynamicCast`'s behaviour turns on its flag argument, so the flag register was
        /// read: `mov w4, #6` at +0x100, and the code then tests the returned `Bool`
        /// (`tbz w0, #0, 0x2ad500d4c` at +0x108) and branches to the throw. The unconditional
        /// form would neither return a testable `Bool` nor need that branch. A b/bl scan for
        /// `swift_dynamicCast` finds exactly two call sites in the image: this one and one in
        /// `Session.(executeDirectInvocation)`'s `(3) await resume partial function` at
        /// `0x2ad51aa24`. So within this subsystem there is exactly one argument cast, and it is
        /// the throwing kind — in contrast to the result-metatype cast in
        /// `invokeHandlerOnReturn`, which traps (see the cross-references below).
        public mutating func decodeNextArgument<Argument: Decodable & Encodable>() throws -> Argument

        /// Resolved: `0x2ad500e0c`, 8 bytes — `ldr x0, [x20, #0x20]; ret`.
        public mutating func decodeErrorType() throws -> Any.Type?

        /// Resolved: `0x2ad500e14`, 8 bytes — `ldr x0, [x20, #0x28]; ret`.
        public mutating func decodeReturnType() throws -> Any.Type?
    }

    // MARK: - ResultHandler

    /// The type that carries the `DistributedActorSystem.ResultHandler` associated type
    /// (associated-type witness accessor `0x2ad51fee4`). Same wrapper shape as
    /// `InvocationDecoder`, but a **class**.
    ///
    /// `class`: it has a metaclass (`0x2d70d7d28`), a class metadata base offset
    /// (`0x2ad5230a8`), a method lookup function (`0x2ad5064f0`), `deinit` / `__deallocating_deinit`
    /// and `__allocating_init`s. Its metadata is statically emitted (no singleton init cache),
    /// so `mode` sits at the fixed offset 0x10, immediately after the 16-byte object header —
    /// resolved from `init(direct:)`'s `str x8, [x20, #0x10]`.
    ///
    /// It is **not** a superclass of `EncodedResultHandler` or `DirectResultHandler`, and they
    /// are not subclasses of it: it stores them in an enum. Two independent reasons.
    /// (1) `ResultHandler.reply` is computed (property descriptor, no field offset) while
    ///     `EncodedResultHandler.reply` is stored (direct field offset `0x2d70d8110`), and Swift
    ///     does not allow a stored property to override anything.
    /// (2) `ResultHandler.init(direct: DirectResultHandler)` exists, and the payload it stores
    ///     is a `DirectResultHandler` reference with a tag bit set.
    ///
    /// Why a class at all: the receive path writes `reply`/`capturedResult` from inside
    /// `executeDistributedTarget` and reads it back afterwards, which needs reference identity.
    public class ResultHandler {

        /// **Private**, in `InvocationResultHandler.swift`: the live demangler prints
        /// `ResultHandler.(Mode in _AF3EABBF82306E763A49A69563B36D8F)`, and the stored property
        /// shares the hash — `ResultHandler.(mode in _AF3EABBF82306E763A49A69563B36D8F)`. That
        /// hash differs from `InvocationDecoder.Mode`'s, i.e. the two `Mode`s are declared in
        /// different files.
        ///
        /// **Both cases carry payloads, and these are their types** — from the field records:
        ///
        ///     mp-enum XPCDistributed.XPCSystem.ResultHandler.(Mode)      (recsize=12, n=2)
        ///         encoded: XPCDistributed.XPCSystem.EncodedResultHandler
        ///         direct:  XPCDistributed.XPCSystem.DirectResultHandler
        ///
        /// Corroborated (not established) by the value witness table `0x2d9b85780`: size =
        /// stride = 8 with `extraInhabitantCount` 126. An 8-byte two-case enum is only possible
        /// if both cases are pointer payloads sharing a spare-bit tag; a payload-free two-case
        /// enum would be 1 byte with 254 extra inhabitants.
        ///
        /// The tag is a **spare bit, bit 63**, not a separate byte:
        ///   - `.encoded` = bit 63 clear. Resolved from
        ///     `ResultHandler.init(_:canThrow:)`'s specialization (`0x2ad505d20 +0x0d8`):
        ///     `str x21, [x19, #0x10]` where `x21` is a freshly allocated
        ///     `EncodedResultHandler`, stored unmodified.
        ///   - `.direct` = bit 63 set. Resolved from `init(direct:)` (`0x2ad504e84`, 16 bytes):
        ///     `orr x8, x0, #0x8000000000000000; str x8, [x20, #0x10]`.
        ///   Every consumer tests it with `tbnz x20, #0x3f` and masks with
        ///   `and x20, x20, #0x7fffffffffffffff` (e.g. `0x2ad5052f0 +0x000`).
        ///
        /// Case order in the field records is `encoded`, `direct`, matching the tag order.
        private enum Mode {
            case encoded(EncodedResultHandler)
            case direct(DirectResultHandler)
        }

        /// **`let`, not `var`** — field-record flags `0x00`. Corrected: an earlier draft of this
        /// file wrote `var` by analogy with `InvocationDecoder.mode` (which really is `0x02`).
        /// `let` works here because `ResultHandler` is a class and both payloads are themselves
        /// mutable class references, so the wrapper never has to reassign the enum. Its
        /// field-offset symbol also spells the type:
        /// `direct field offset for ResultHandler.(mode in _AF3E…) : ResultHandler.(Mode in _AF3E…)`.
        private let mode: Mode

        /// Resolved: `0x2ad504d58` (244 bytes) plus its
        /// `<Arg[0] = Existential To Protocol Constrained Generic>` specialization at
        /// `0x2ad505d20`, which allocates an `EncodedResultHandler`, initialises
        /// `reply = nil` / `replyHandler` / `canThrow`, and stores `.encoded(that)`.
        /// `__allocating_init` at `0x2ad504cf4`.
        public init(_ replyHandler: any EncodedResultHandler.ReplyHandler, canThrow: Bool)

        /// Resolved: `0x2ad504e84` (16 bytes). `__allocating_init` at `0x2ad504e4c`.
        public init(direct: DirectResultHandler)

        /// Resolved: getter `0x2ad504a78`, setter `0x2ad504abc`, `_modify` `0x2ad504b9c`.
        /// All three switch on `mode`:
        ///   - `.encoded` → class-dispatch to `EncodedResultHandler.reply`
        ///     (vtable slot 0x68 = getter, 0x70 = setter).
        ///   - `.direct` → **`brk #1`**, a bare trap with no message. Resolved from
        ///     `tbnz x20, #0x3f, 0x2ad504ab8` in the getter and the identical branch in the
        ///     setter. What source construct emits that bare trap is not established.
        ///
        /// So `reply` is meaningful only on the encoded path; the direct path's result comes
        /// out of `DirectResultHandler.capturedResult` instead.
        public var reply: Transport.Packet.Payload? { get set }

        // --- DistributedTargetInvocationResultHandler conformance -------------------------
        // Conformance descriptor `0x2ad522f70`; witnesses 0x2ad50587c (onReturn),
        // 0x2ad5059dc (onReturnVoid), 0x2ad505be4 (onThrow).
        // All three are `async throws` and all three dispatch on `mode`'s bit 63.

        /// Resolved: prologue `0x2ad504e94`, body `0x2ad504f28` (408 bytes).
        /// `tbnz x20, #0x3f` at +0x030: `.direct` tail-calls
        /// `DirectResultHandler.onReturn` (`0x2ad5044b8`+, a `b` at +0x194); `.encoded` goes
        /// through the class vtable.
        public func onReturn<Success: Decodable & Encodable>(value: Success) async throws

        /// Resolved: prologue `0x2ad5051b4`, body `0x2ad5051d4` (428 bytes).
        /// `.encoded` (+0x030) dispatches `EncodedResultHandler.onReturnVoid` via vtable slot
        /// 0x90. `.direct` (`0x2ad5052f0`) has `DirectResultHandler.onReturnVoid` **inlined**:
        /// it masks off the tag bit, materialises `Ack`'s metadata (`0x2d9b84470`) and its
        /// Decodable/Encodable witness tables, writes result tag byte 0, and assigns
        /// `.success(Ack())` into `directHandler.capturedResult` under
        /// `swift_beginAccess`/`swift_endAccess`.
        public func onReturnVoid() async throws

        /// Resolved: prologue `0x2ad505474`, body `0x2ad505498` (412 bytes). Same
        /// bit-63 dispatch.
        public func onThrow<Err: Error>(error: Err) async throws
    }

    // MARK: - EncodedResultHandler

    /// The wire-side result handler: turns the target's return value or error into a reply
    /// `Payload`.
    ///
    /// `class` (metaclass `0x70d7b90`, method lookup `0x2ad506008`, `deinit` `0x2ad503de8`).
    /// Its metadata has a completion function (`0x2ad505f64`) and a singleton init cache, so
    /// field offsets are resilient and are read from the globals
    /// `0x2d70d8110` (reply), `0x2d70d8118` (replyHandler), `0x2d70d8120` (canThrow) —
    /// which is also how the field order was corroborated against reflection metadata.
    public class EncodedResultHandler {

        /// A protocol **nested inside a class** — legal since SE-0404 (protocols in
        /// non-generic contexts). Protocol descriptor `0x2ad52775c`, requirements base
        /// descriptor `0x2ad52776c`, declared as `protocol` and not `class-protocol` in the
        /// reflection dump, so it carries no `AnyObject` constraint.
        ///
        /// Read out of the protocol descriptor itself (`0x2ad52775c`):
        /// `NumRequirementsInSignature = 0`, `NumRequirements = 1`,
        /// `AssociatedTypeNames = <null>`. So: **one requirement, no associated types, and no
        /// inherited protocol** — with the caveat that a marker protocol such as `Sendable`
        /// would not appear in a runtime requirement signature, so `: Sendable` cannot be ruled
        /// out this way. The parent chain of the descriptor resolves to
        /// `[XPCDistributed (module), XPCSystem (class), EncodedResultHandler (class)]`, which is
        /// the nesting, from metadata.
        ///
        /// Exactly one method descriptor exists for it (`0x2ad527774`), agreeing with
        /// `NumRequirements = 1`. Exactly one conformance exists in the image:
        /// `Session.(RemoteInvocationReplyEncoder)` (descriptor `0x2ad5245f0`, witness table
        /// `0x2d9b86170`, witness `0x2ad5129e8`), a private struct with one field, `userInfo`.
        public protocol ReplyHandler {

            /// Not `async`, not `throws`, not `mutating` — the demangled method descriptor
            /// carries no `async`/`throws`, and both call sites reach it through
            /// `__swift_project_boxed_opaque_existential_1Tm` (the non-mutable projection).
            ///
            /// The method descriptor's raw symbol spells the whole thing, generic signature
            /// included:
            /// `…20EncodedResultHandlerC05ReplyE0P06encodeF04withAC9TransportC6PacketV7PayloadV`
            /// `s0D0Oyqd__qd_0_G_tSeRd__SERd__s5ErrorRd_0_r0_lFTq`
            /// — `s0D0Oyqd__qd_0_G` is `Swift.Result<τ_1_0, τ_1_1>`, the requirements are
            /// `Se` (Decodable) and `SE` (Encodable) on the first and `s5Error` on the second,
            /// the return is `Transport.Packet.Payload`, and `Tq` marks it a method descriptor.
            /// No `Sendable` appears, but marker protocols are omitted from runtime generic
            /// signatures, so that is not evidence either way.
            ///
            /// `Failure` is bound to `Never` on the success path and to the thrown error's
            /// concrete type on the failure path; see `onReturn`/`onThrow` below.
            func encodeReply<Success: Decodable & Encodable, Failure: Error>(
                with result: Result<Success, Failure>
            ) -> Transport.Packet.Payload
        }

        /// Field records for this class, verbatim — types and `let`/`var` both:
        ///
        ///     class XPCDistributed.XPCSystem.EncodedResultHandler       (recsize=12, n=3)
        ///         [0x02 var] reply:        XPCDistributed.XPCSystem.Transport.Packet.Payload?
        ///         [0x00 let] replyHandler: any <ReplyHandler>          (`\x01<ref>_p`)
        ///         [0x00 let] canThrow:     Swift.Bool
        ///
        /// `replyHandler`'s mangled name is one symbolic reference followed by `_p` — a
        /// single-protocol existential, no composition — and the reference resolves through the
        /// parent chain to a protocol nested in `EncodedResultHandler`, which is `ReplyHandler`.
        ///
        /// Stored. Written by `onReturn`/`onReturnVoid`/`onThrow`, read by the session.
        /// Initialised to `nil` in `init` (`0x2ad505d20 +0x0b4`, `storeEnumTagSinglePayload`
        /// with `1, 1` on `Payload`).
        /// Accessors: getter `0x2ad503160`, setter `0x2ad5031cc`, `_modify` `0x2ad503240`.
        public var reply: Transport.Packet.Payload?

        /// Stored, a boxed existential with one conformance (5 words; every use goes through
        /// `__swift_project_boxed_opaque_existential_1Tm` and reads the metadata at +0x18 and
        /// one witness table at +0x20 — e.g. `onThrow` body `0x2ad503b18 +0x070`).
        /// Getter `0x2ad5032a4`.
        public let replyHandler: any ReplyHandler

        /// Stored, one byte. Getter `0x2ad5032b8`. **Only consumer resolved: `onThrow`.**
        public let canThrow: Bool

        /// Resolved: `0x2ad503370` (148 bytes); `__allocating_init` `0x2ad5032c8`.
        public init(_ replyHandler: any ReplyHandler, canThrow: Bool)

        // --- DistributedTargetInvocationResultHandler conformance -------------------------
        // Conformance descriptor `0x2ad522ec0`; witnesses 0x2ad503eb4 (onReturn),
        // 0x2ad504014 (onReturnVoid), 0x2ad504128 (onThrow).

        /// Resolved: prologue `0x2ad503404`, body `0x2ad503540` (436 bytes).
        ///
        ///   reply = replyHandler.encodeReply(with: Result<Success, Never>.success(value))
        ///
        /// `Failure == Never` is resolved, not inferred: the `Swift.Result` metadata accessor
        /// is called at +0x054 with `x1 = Success`, `x2 = <type metadata for Swift.Never>` and
        /// `x3 = <protocol witness table for Swift.Never : Swift.Error>`, both read out of the
        /// authenticated GOT slots `0x2d0101dc0` and `0x2d0101de8` in the live image. The
        /// success tag is stored by `swift_storeEnumTagMultiPayload` at +0x0a8.
        ///
        /// This is what makes `RemoteInvocationResponse<Never>` the failure-only
        /// instantiation — the success arm instantiates over the *target's* return type.
        public func onReturn<Success: Decodable & Encodable>(value: Success) async throws

        /// Resolved: prologue `0x2ad5036f4`, body `0x2ad503714` (280 bytes). Materialises
        /// `Ack`'s metadata and its two witness tables and dispatches its own `onReturn`
        /// through vtable slot 0x88 — i.e. `onReturnVoid()` is `try await onReturn(value: Ack())`
        /// with dynamic dispatch, not a direct call. Already recorded in the wire-format spec;
        /// noted here for the vtable detail.
        public func onReturnVoid() async throws

        /// Resolved: prologue `0x2ad503a0c`, body `0x2ad503b18` (720 bytes).
        ///
        ///   guard canThrow else {                                   // +0x040 cmp w8,#1 / b.ne
        ///       fatalError("API violation: Swift threw \(error) "
        ///                  + "in a distributed func that doesn't throw.")
        ///   }
        ///   reply = replyHandler.encodeReply(with: Result<Never, Err>.failure(error))
        ///
        /// `Success == Never` resolved the same way as above: the `Result` accessor at +0x024
        /// gets `x1 = Swift.Never`'s metadata (GOT `0x2d0101dc0`) and `x2 = Err`.
        ///
        /// The message is assembled from three pieces, all resolved:
        /// the 15-byte small string `"API violation: "` (movz/movk at +0x1d0…+0x1ec — it is in
        /// no string table), the 12-byte small string `"Swift threw "` (+0x210…+0x228),
        /// `DefaultStringInterpolation.appendInterpolation(error)` (+0x240), and the 42-byte
        /// literal `" in a distributed func that doesn't throw."` at `0x2ad525c60` (+0x244).
        /// The trap itself is `Swift._assertionFailure("Fatal error", message,
        /// file: <.../InvocationResultHandler.swift>, line: 26, flags: 0)` (+0x2ac).
        ///
        /// So `canThrow` is an API-violation assertion, not a fallback: throwing out of a
        /// non-throwing distributed func crashes the *callee*.
        public func onThrow<Err: Error>(error: Err) async throws
    }

    // MARK: - DirectResultHandler

    /// The in-process result handler: captures the result in memory instead of encoding it.
    ///
    /// `class` (metaclass `0x2d70d7c88`, method lookup `0x2ad5064a0`, `deinit` `0x2ad5046e8`).
    /// Statically emitted metadata, so `capturedResult` is at the fixed offset 0x10 — resolved
    /// from `init()` (`0x2ad504408`) and from every accessor's `x20 + 0x10`.
    public class DirectResultHandler {

        /// **The type is read straight off the accessor symbols**, which are demangled with it:
        /// `DirectResultHandler.capturedResult.getter :
        ///  Swift.Result<Swift.Decodable & Swift.Encodable, Swift.Error>?`
        /// (getter `0x2ad504264`, setter `0x2ad5042bc`, `_modify` `0x2ad50437c`, property
        /// descriptor `0x2ad522fb0`, direct field offset `0x2ad523040`).
        ///
        /// Independently confirmed by the field record, which is `var` (flags `0x02`) and whose
        /// mangled type name is
        /// `\x02<ref A> y Se _ SE p \x02<ref B> _p G Sg`
        /// = `Optional<A<any Decodable & Encodable, any B>>`, with `Se`/`SE` the standard
        /// substitutions for `Decodable`/`Encodable`. `A` and `B` sit behind indirect symbolic
        /// references into cross-image GOT slots that `dladdr` will not attribute; the accessor
        /// symbols name them `Swift.Result` and `Swift.Error`.
        ///
        /// Layout resolved from `init()` (`0x2ad504408`, 28 bytes): the 48-byte
        /// `any Decodable & Encodable` payload occupies +0x10…+0x40 and the enum tag byte sits
        /// at +0x40, which `init()` sets to `0xff` — the `nil` tag. The writers use tag `0` for
        /// `.success` (`0x2ad5044b8 +0x070`) and tag `1` for `.failure` (`0x2ad5045e0 +0x094`).
        ///
        /// Every write goes through `swift_beginAccess`/`swift_endAccess` (exclusivity
        /// enforcement on a class stored property), which is visible in all three writers.
        public var capturedResult: Result<any Decodable & Encodable, any Error>?

        /// Resolved: `0x2ad504408` (28 bytes) — zeroes the payload and writes the nil tag.
        /// `__allocating_init` `0x2ad5043d0`.
        public init()

        // --- DistributedTargetInvocationResultHandler conformance -------------------------
        // Conformance descriptor `0x2ad522f18`; witnesses 0x2ad504760 (onReturn),
        // 0x2ad504828 (onReturnVoid), 0x2ad504904 (onThrow).

        /// Resolved: prologue `0x2ad504424`, body `0x2ad5044b8` (228 bytes).
        /// `capturedResult = .success(value)` — boxes `value` into
        /// `any Decodable & Encodable` (`__swift_allocate_boxed_opaque_existential_2` +0x044),
        /// writes tag 0, assigns under `beginAccess`.
        public func onReturn<Success: Decodable & Encodable>(value: Success) async throws

        /// Resolved: prologue `0x2ad50459c`; its body is folded onto the protocol witness's
        /// resume function at `0x2ad50484c` (200 bytes). `capturedResult = .success(Ack())` —
        /// `Ack`'s Decodable and Encodable witness accessors, then the same tag-0 assign.
        public func onReturnVoid() async throws

        /// Resolved: prologue `0x2ad5045bc`, body `0x2ad5045e0` (264 bytes).
        /// `capturedResult = .failure(error)` — boxes `Err` into `any Error`
        /// (`_getErrorEmbeddedNSError` then `swift_allocError`), writes tag 1, assigns.
        public func onThrow<Err: Error>(error: Err) async throws
    }
}

// =====================================================================================
// Cross-references established while reconstructing this subsystem, recorded because they
// belong to other agents' types but were resolved here.
// =====================================================================================
//
// - `RemoteInvocationRequest.(InvocationContents)`'s `Encodable` witness (`0x2ad50db44`,
//   192 bytes) is the *only* `encode(to:)` that type has — there is no separate
//   `InvocationContents.encode(to:)` symbol. It does `swift_getEnumCaseMultiPayload`, then for
//   `.send` a **direct call** to `InvocationEncoder.encode(to:)` (`0x2ad4ffb38`), and for
//   `.recv` `Swift._assertionFailure` (the string
//   `"Received invocation contents cannot be encoded."`) followed by `brk #1`.
//
// - `Session.RemoteInvocationRequest.invocation.getter` is demangled
//   `: XPCSystem.InvocationDecoder?` (`0x2ad50d838`, property descriptor `0x2ad5239dc`) — an
//   *optional* computed decoder, presumably nil in the `.send` direction.
//
// - **`invokeHandlerOnReturn` is an eighth `DistributedActorSystem` requirement**, and it is a
//   result-handler one, so it belongs here even though the conformance is another agent's. The
//   wire-format spec's "all seven requirements" undercounts.
//   `XPCSystem.invokeHandlerOnReturn(handler: ResultHandler, resultBuffer: UnsafeRawPointer,
//   metatype: Any.Type) async throws` (`0x2ad51eecc`, witness `0x2ad51f818`) is the missing link
//   between `executeDistributedTarget` and `ResultHandler.onReturn<A>`. Resolved end to end:
//
//       func invokeHandlerOnReturn(handler: ResultHandler,
//                                  resultBuffer: UnsafeRawPointer,
//                                  metatype: Any.Type) async throws {
//           func doInvokeOnReturn<A: Decodable & Encodable>(returnType: A.Type) async throws {
//               try await handler.onReturn(value: resultBuffer.load(as: A.self))
//           }
//           // metatype cast to (any Decodable & Encodable).Type -- UNCONDITIONAL
//           <open the existential metatype>; doInvokeOnReturn(returnType: $0)
//       }
//
//   Bodies: `0x2ad51eef0` (208 bytes) does the metatype cast at +0x044 and tail-branches into
//   `doInvokeOnReturn` (`0x2ad51efc0`, 188 bytes), whose continuation `0x2ad51f07c` (308 bytes)
//   calls `Swift.UnsafeRawPointer.load<A>(fromByteOffset: Swift.Int, as: A.Type)` at +0x038 with
//   offset 0, then dispatches `ResultHandler` vtable slot **0x80** — `onReturn<A>(value:)` — at
//   +0x04c.
//
//   **The metatype cast traps; it does not throw.** The cast goes through the outlined helper
//   `dynamic_cast_existential_2_unconditional` (`0x2ad51fd70`, 124 bytes), which does two
//   `swift_conformsToProtocol2` calls (Decodable, then Encodable) and, if either returns null,
//   falls through to `brk #1` at +0x078. So a distributed func whose return type is not
//   `Codable` crashes the callee at this point. That helper has two direct callers in the whole
//   b/bl scan, both this function and its protocol witness, so the trap is specific to the
//   result-metatype cast.
//
// - `(extension in XPCDistributed):CodingUserInfoKey.sessionKey` (`0x2d70d8078`, getter
//   `0x2ad50b42c`) and
//   `(extension in XPCDistributed):Dictionary<CodingUserInfoKey, Any>.init(session:xpcSystem:)`
//   (`0x2ad50b4cc`) are the userInfo plumbing that `transformValueForDirectInvocation` inlines.
//
// - `XPCSystem.ActorReference<A>` is generic (`__allocating_init(from:)` demangles as
//   `-> ActorReference<A>`), which is why the `"ActorReference<"` substring test works.
//
// =====================================================================================
// UNRESOLVED
// =====================================================================================
//
// 1. `public` vs `package` vs `@_spi` on every member above. The symbol table's `T`/`t`
//    distinction separates ABI-visible from module-internal, not `public` from `package`.
//    Everything written `public` here is ABI-visible; everything written `internal` has no
//    exported symbol and no property descriptor. Next step: none available from this image —
//    it would need a `.swiftinterface` or a `.private.swiftinterface`, and this framework
//    ships neither.
//
// 2. `Sendable` / actor-isolation annotations on all of these — including whether
//    `EncodedResultHandler.ReplyHandler` is declared `: Sendable`. `Sendable` is a marker
//    protocol: it gets no conformance descriptor and is omitted from runtime generic
//    signatures, so `ReplyHandler`'s `NumRequirementsInSignature = 0` and the absence of
//    `Sendable` from the `encodeReply` method descriptor's requirement list are both consistent
//    with it being there. The three result handlers are classes mutated from `async` contexts
//    with `swift_beginAccess` exclusivity checks and no locks, which is consistent with
//    `@unchecked Sendable` or with isolation the type does not declare — but that is a guess
//    and is left as one.
//    Next step: check whether `XPCSystem.executeDistributedTarget`'s call site passes the
//    handler across an isolation boundary.
//
// 3. What source construct produces the bare `brk #1` in `ResultHandler.reply`'s accessors on
//    the `.direct` path. There is no call to any error reporter before it, so it is a
//    `Builtin.unreachable`, not a `fatalError`. `XPCDistributed.Internal` (a case-less enum in
//    the reflection dump) and `XPCDistributed/Utilities/Precondition.swift` are candidates for
//    an always-inlined helper. Next step: look for other bare `brk #1` sites in the image and
//    see whether they share a shape.
//
// 4. Where `EncodedResultHandler.canThrow` is computed, and by whom. A b/bl scan of the whole
//    `__text` range (0x2ad4bc620…0x2ad5202c0) finds **no** direct call to
//    `ResultHandler.__allocating_init(_:canThrow:)` (`0x2ad504cf4`),
//    `ResultHandler.__allocating_init(direct:)` (`0x2ad504e4c`),
//    `DirectResultHandler.__allocating_init()` (`0x2ad5043d0`), or to any of their dispatch
//    thunks — so the handlers are constructed either inline or through `blraa`, neither of
//    which that scan sees. `InvocationDecoder.errorType` (`0x2ad501700`) likewise has no
//    direct caller. The obvious reading is `canThrow = (invocation.errorType != nil)` inside
//    `Session.handleReceivedRequest`, matching `recordErrorType` not being called at all for a
//    non-throwing target — but that is an inference and it is *not* resolved here.
//    Next step: the Session-subsystem agent should look for the inlined
//    `swift_allocObject(<EncodedResultHandler metadata>)` sequence in
//    `Session.handleReceivedRequest` and read what feeds the `canThrow` byte.
//
// 5. Whether `SwiftType.type` can be nil in practice. It is declared non-optional
//    (`SwiftType.type.getter : Any.Type`), yet `EncodedInvocationDecoder.
//    decodeGenericSubstitutions` emits a null test on it at +0x1dc alongside the
//    `_DistributedActorStub` conformance test. Most likely the optional there is the result of
//    `as? any _DistributedActorStub.Type` rather than of `.type`; not settled.
//    Next step: disassemble `SwiftType.init(from:)` (`0x2ad4f59dc`) and see whether it throws
//    `"Unable to resolve type: "` on a failed `_typeByName`, which would make a post-decode
//    nil impossible. That belongs to the SwiftType/identity subsystem.
