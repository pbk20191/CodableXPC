// XPCDistributed — interface reconstruction: the Transport subsystem
// ==================================================================
//
// Covers, all under `XPCDistributed.XPCSystem`:
//
//   Transport                                  (class, 8 stored properties)
//   Transport.RawTransportProtocol             (protocol, 4 requirements)
//   Transport.EscalationHandledBy              (enum)
//   Transport.Packet / .Payload / .Header      (Header is private)
//   Transport.RawTransportError                (enum, Error)
//   Transport.TransportError                   (enum, Error)
//   Transport.XPCRawTransport                  (class) + .PeerGate + .PeerGate.State (private) + .Role
//   Transport.InProcessRawTransport            (class) + .Locked
//   TransportReceiver                          (class) + .PeerTaskTable (private) + .Slot
//
// These are Apple's declarations, transcribed, not adapted. Nothing here is renamed
// or corrected. Bodies are omitted; behaviour that a signature does not carry is in
// the doc comments, each of which says how it was established.
//
// Source file names, from `__cstring`:
//   .../XPCDistributed/Transport/Transport.swift
//   .../XPCDistributed/Transport/XPC/Service+XPC.swift
//   .../XPCDistributed/Transport/TransportReceiver.swift
//
// HOW THINGS WERE ESTABLISHED — the four probes used, so a claim's tag is meaningful:
//
//   [sym]      read off a demangled symbol in `symbols-demangled.txt`. Swift symbols
//              carry full signatures, so parameter labels, `throws(E)`, `async` and
//              return types are read, not inferred.
//   [fieldmd]  read from a `__swift5_fieldmd` field descriptor at the address named by
//              its `reflection metadata field descriptor …` symbol, including each
//              record's *mangled type name* (record `+4`) and its flags (bit `0x2` =
//              IsVar). This is what gives stored-property and enum-case-payload TYPES,
//              which `field-descriptors.txt` throws away.
//   [measured] read out of the live image at run time: field-offset globals, and value
//              witness table size (+0x40), stride (+0x48), flags (+0x50) and
//              extraInhabitantCount (+0x54). Every size quoted below was read from a
//              real `value witness table for X` symbol; none fell back to
//              `full type metadata for X`, which points at the VWT *pointer* and yields
//              nonsense if the two are conflated. The only two types here whose VWT
//              reports `Incomplete` with size 0 are `Packet` and `Packet.Payload`
//              (lazily instantiated metadata), and no size is claimed for either.
//   [disasm]   resolved by disassembling the function named, with call targets annotated
//              through `__auth_stubs` → `__auth_got` → `dladdr`.
//
// ORDER OF ENUM CASES BELOW IS TAG ORDER, NOT DECLARATION ORDER. A reflection field
// descriptor lists an enum's payload cases first and its payload-free cases after, so
// the listing order is the tag numbering and says nothing about the order Apple wrote
// them in. Every enum here is listed in descriptor order and no declaration order is
// claimed. Where a tag *value* is asserted (`Header`, `PeerGate.State`) it is
// independently confirmed from disassembled comparisons, not taken from the listing.
//
// Access level is read from three signals that agree, not guessed: a parenthesised name
// component (`Transport.(requestManager)`) or a file-private discriminator
// (`(configureAndActivateSession in _6E80E26E63AF20C261D5E7DB1C74DCD5)`); local symbol
// binding (`t`/`s` in nm output) rather than exported (`T`/`S`); and, for types, an
// `anonymous descriptor` symbol instead of an exported `nominal type descriptor`.
// A `private` type is invisible in `field-descriptors.txt`, which prints it under its
// bare name, so the symbol table is the only check. Across this whole subsystem exactly
// three types have an `anonymous descriptor`, and they are exactly the three marked
// `private` below: `Packet.(Header)` (`0x2ad526df8`),
// `XPCRawTransport.PeerGate.(State)` (`0x2ad526cbc`) and
// `TransportReceiver.(PeerTaskTable)` (`0x2ad526e58`). `PeerGate`, `Locked`, `Role`,
// `EscalationHandledBy` and `Slot` were each checked and have none — so, despite being
// plausible candidates, they are not private. Non-private declarations are left bare
// rather than guessed between `internal` and `public`.
//
// The ENVELOPE — `Packet`'s three xpc keys, the `headerCategory` renumbering, and
// `Payload`'s `"payload"` key and overlay byte-stream body — is already fully resolved
// and written up in `docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md`,
// section "Envelope". It is NOT restated here; see the references in `Packet` below.

import Dispatch
import Synchronization
import XPC
import os

extension XPCSystem {

    // ==========================================================================
    // MARK: - Transport
    // ==========================================================================

    /// [sym] `class metadata base offset for XPCDistributed.XPCSystem.Transport`,
    /// `method lookup function for …Transport` — a resilient class. Its designated
    /// init is the only member with a `method descriptor` + `dispatch thunk`
    /// (`0x2ad526d14` / `0x2ad4e7840`), so it is vtable-dispatched and the class is
    /// not `final`; no other member is overridable. No superclass: the field
    /// descriptor's superclass reference is 0. [fieldmd]
    ///
    /// [measured] Instance size 0x80. Field offsets read live out of the
    /// `direct field offset for …` globals: 0x10, 0x20, 0x28, 0x38, 0x40, 0x68,
    /// 0x70, 0x78 in the declaration order below.
    class Transport {

        /// [fieldmd] mangled type `{InboundSessionProtocol}_pSgXw` — the trailing `Xw`
        /// is weak storage; flags bit 0x2 (IsVar) is set. Offset 0x10 [measured],
        /// 16 bytes: 8 for the weak reference plus 8 for the witness table, because
        /// `InboundSessionProtocol` is class-constrained (`class-protocol` in
        /// `__swift5_fieldmd`).
        ///
        /// [disasm] `Transport.init` at `0x2ad4e6054` stores 0 into `self+0x18`
        /// (the witness table) and calls `swift_unknownObjectWeakInit(self+0x10, nil)`;
        /// `deinit` (`0x2ad4e12a4`) calls
        /// `outlined destroy of weak XPCDistributed.XPCSystem.InboundSessionProtocol?`.
        private weak var inboundSession: (any InboundSessionProtocol)?

        /// [fieldmd] `{XPCDistributed.Fuse}`. [measured] `Fuse` is 1 byte, stride 1,
        /// and its value witness flags carry `NonCopyable` — so `struct Fuse: ~Copyable`
        /// wrapping `Synchronization.Atomic<Bool>` ([sym] `Fuse.value.read : Atomic<Bool>`).
        /// Offset 0x20 [measured]; `init` zeroes it with `strb wzr, [self, #0x20]` [disasm].
        private let isCancelledFuse: Fuse

        /// [fieldmd] `SS`, flags 0x0 (not IsVar). Offset 0x28 [measured].
        let debugName: String

        /// [fieldmd] `So24OS_dispatch_queue_serialC`. Offset 0x38 [measured].
        ///
        /// [disasm] `Transport.init` (`0x2ad4e5edc`) creates it as
        /// `DispatchQueue(label: "XPCTransport-" + debugName, qos: .unspecified,
        /// attributes: <empty>, autoreleaseFrequency: …, target: nil)`. The label prefix
        /// is a Swift small string built from `movz`/`movk` immediates at `+0x1ac`
        /// (`"XPCTransport-"`, 13 bytes, count byte 0xED) and so appears in no string table.
        let queue: DispatchQueue     // __C.OS_dispatch_queue_serial

        /// [fieldmd] `{RawTransportProtocol}_p` — a plain (not class-constrained)
        /// existential, so 40 bytes: 3 inline buffer words + metadata + one witness
        /// table. Occupies 0x40..0x68 [measured], which the 0x68 offset of the next
        /// field confirms, and which `__swift_project_boxed_opaque_existential_1` /
        /// `__swift_destroy_boxed_opaque_existential_1` at every use site corroborates
        /// [disasm].
        let rawTransport: any RawTransportProtocol

        /// [fieldmd] `{RequestManager}y{ID64}{Result}y{Packet.Payload}{TransportError}GG`.
        /// Offset 0x68 [measured].
        ///
        /// [disasm] `init` allocates it inline (`swift_allocObject` size 0x20, storing
        /// `queue` at +0x10 and an empty `[ID64: Request]` at +0x18) rather than calling
        /// a `RequestManager.init` symbol.
        private let requestManager: RequestManager<ID64, Result<Packet.Payload, TransportError>>

        /// [fieldmd] `{ID64.Generator}`. Offset 0x70 [measured]. 8 bytes, `~Copyable`
        /// [measured: value witness flags carry NonCopyable].
        ///
        /// DEAD IN THIS BUILD — on **one** discriminating probe plus a positive control, not on
        /// the four signals an earlier revision listed. Two of those four were checked against
        /// controls and fail: "no accessor symbol exists" distinguishes *access level*, not
        /// liveness (all four of `Transport`'s private fields lack accessors and three are
        /// demonstrably live, while `Session.idGenerator` has a `read` only because it is not
        /// `private`); and "`deinit` skips `+0x70`" also skips `+0x20`, which is
        /// `isCancelledFuse` and unquestionably live — deinit skipping a field means it is
        /// trivially destroyed, nothing more. The probe that does discriminate is the atomic
        /// scan, and its positive control is the same scan over `Session`, which *does* find the
        /// inlined generator (`cas` at `shareActor+0x24` and `handleActorShared+0x24` against
        /// `Session+0x20`). Widened to the whole image: 2239 functions, 21 atomic sites, none in
        /// `Transport`. Also checked rather
        /// than taken from the wire-format spec:
        ///   1. no accessor symbol of any kind exists for it, in contrast with
        ///      `XPCDistributed.XPCSystem.Session.idGenerator.read : ID64.Generator`
        ///      which does exist [sym];
        ///   2. `init` writes zero into it and never reads it — the same instruction
        ///      that stores `requestManager` does it:
        ///      `stp x21, xzr, [x19, #0x68]` at `0x2ad4e6224` [disasm];
        ///   3. `deinit` touches 0x10, 0x30, 0x38, 0x40, 0x68 and 0x78 and skips
        ///      0x70 [disasm] (consistent with a trivial `Atomic<UInt64>`);
        ///   4. an instruction scan over every `XPCSystem.Transport*` function range
        ///      finds compare-and-swap instructions at exactly two sites,
        ///      `Transport.cancel()+0x20` and `Transport.handleCancellation()+0xa8`,
        ///      both against the fuse at +0x20, and none against +0x70 [measured].
        /// A fifth signal is weaker than it looks and is recorded as such: a direct
        /// `BL`/`B` scan of `__text` finds no callers of `ID64.Generator.next()`
        /// (`0x2ad4ef334`) at all — but a direct-branch scan cannot see `blraa`, so on
        /// its own that proves only that `next()` is always inlined, not that it is
        /// unused. Signals 1–4 are what carry the claim.
        private let idGenerator: ID64.Generator

        /// [fieldmd] `{BackpressureManager}y{ID64}GSg`, flags 0x2 (IsVar).
        /// Offset 0x78 [measured]. `init` sets it to nil and then calls
        /// `setBackpressurePolicy(.default)` — the tail of `init` is a `swift_once` on
        /// `static BackpressurePolicy.default` (`0x2d70d8060`) followed by
        /// `bl 0x2ad4dc974` [disasm].
        private var backpressureManager: BackpressureManager<ID64>?

        /// [sym] `0x2ad4dc86c`; the real body is the outlined specialization at
        /// `0x2ad4e5edc` (`Arg[1] = Existential To Protocol Constrained Generic`).
        init(debugName: String, rawTransport: any RawTransportProtocol)

        // ---- accessors ----------------------------------------------------------

        /// [sym] `0x2ad4df368`. [disasm] 4 instructions: `ldaprb` of the fuse byte at
        /// `self+0x20`, i.e. `isCancelledFuse.isTripped` — an acquire-ordered atomic load.
        var isCancelled: Bool { get }

        /// [sym] `0x2ad4e122c`. [disasm] forwards to `rawTransport.auditToken`
        /// (witness table slot +0x20). Returns 33 bytes: the 32-byte token plus the
        /// Optional tag byte.
        var auditToken: audit_token_t? { get }

        // ---- setup --------------------------------------------------------------

        /// [sym] `0x2ad4dcbf8`, `throws(SetupError)`.
        /// [disasm] the whole body is `try rawTransport.activate(linking: self)` —
        /// project the existential, call witness slot +0x8. Nothing else. In particular
        /// there is NO handshake here; see the wire-format spec, "There is no version
        /// field and no handshake."
        func activate() throws(SetupError)

        /// [sym] `0x2ad4df378`; the body is the specialization at `0x2ad4e5ec8`.
        /// [disasm] five instructions: store the witness table into `self+0x18`, then
        /// `swift_unknownObjectWeakAssign(self+0x10, session)`. So the transport does
        /// NOT retain its inbound session. (The Session agent independently found
        /// `Session.init(actorSystem:transport:options:)` performing the same
        /// weak assignment; same effect either way.)
        func setInboundSession(_ session: any InboundSessionProtocol)

        /// [sym] `0x2ad4dc974`.
        /// [disasm] if a `backpressureManager` already exists it is drained on
        /// `queue.sync { … }` first; then, if `policy.enabled` (byte 0 of the policy),
        /// a fresh `BackpressureManager<ID64>` is built with
        /// `policy.maxConcurrentRequests` (byte 1) and installed, otherwise
        /// `backpressureManager` is set to nil. Toggling while requests are inflight is
        /// an API violation and traps with
        /// `"API violation: Trying to toggle backpressure policy while there are still
        /// inflight requests. Use .disabled to force-drain pending requests."`
        /// (`Transport.swift:201`).
        func setBackpressurePolicy(_ policy: BackpressurePolicy)

        // ---- send path ----------------------------------------------------------

        /// [sym] `0x2ad4df504`, `async`, plus six suspend/await resume partial functions.
        /// Returns nil when the request manager produced no reply.
        ///
        /// [disasm] the shape, from the resume functions in order:
        ///   1. `let token = await backpressureManager?.acquireSlot(for: id)`
        ///      ([sym] `generic specialization <ID64> of
        ///      BackpressureManager.acquireSlot(for:) async -> SendToken?`, reached
        ///      through the async function pointer at `0x2ad520ec8`); the `nil`
        ///      `backpressureManager` path stores tag 6 into the token slot and skips it;
        ///   2. `swift_task_addPriorityEscalationHandler` with the
        ///      `@Sendable (TaskPriority, TaskPriority) -> ()` closure at `0x2ad4e0e24`
        ///      and a `Mutex<EscalationHandledBy>` as its context (see
        ///      `EscalationHandledBy` below);
        ///   3. `await requestManager.withRequest(id:perform:)` with the `perform`
        ///      closure at `0x2ad4e0140`, which builds the `.request(id:)` packet and
        ///      calls `sendPacketWithProperQoS`;
        ///   4. `swift_task_removePriorityEscalationHandler(record)`;
        ///   5. `if let token { await backpressureManager.releaseSlot(token: token) }`;
        ///   6. destroy the `EscalationHandledBy` and return.
        ///
        /// [disasm] the `perform` closure (`0x2ad4e0140`), under the escalation mutex:
        /// builds `Packet(header: .request(id: id), payload: payload)` — `str x19, [buf]`
        /// then `strb wzr, [buf, #8]`, i.e. `ID64` at offset 0 and enum tag 0 at offset 8
        /// — and calls `sendPacketWithProperQoS`. On success it reads the task-local
        /// `XPCSystem.currentSession` ([sym] `static XPCSystem.$currentSession :
        /// TaskLocal<Session?>`, `0x2d70d8090`), traps if it is nil, and stores
        /// `.escalationHandler(using: session)` into the mutex. On failure it boxes the
        /// `RawTransportError` with `swift_allocError`, releases the lock, and — if the
        /// current QoS does not match the task's — hands the failure reply to
        /// `queue.async(group: nil, qos:, flags: .enforceQoS)`; that block
        /// (`0x2ad4e0658`) builds a message string and calls
        /// `RequestManager.Request.reply(with: .failure(TransportError…))`.
        func sendRequest(id: ID64, payload: Packet.Payload) async
            -> Result<Packet.Payload, TransportError>?

        /// [sym] `0x2ad4e1000`, `throws(TransportError)`.
        /// [disasm] builds `Packet(header: .notification, payload: payload)` — a zero
        /// word at offset 0 and enum tag 2 at offset 8 — calls
        /// `sendPacketWithProperQoS`, and on a thrown `RawTransportError` rethrows
        /// `TransportError.transportCancelled(message: "Failed to send notification with
        /// error \(error)")`. The literal is `__cstring` `"Failed to send notification
        /// with error "` (38 bytes, appended by `_StringGuts.grow(0x29)` +
        /// `String.append`), and the type of the thrown value is pinned by
        /// `swift_willThrowTypedImpl` being handed
        /// `type metadata for …Transport.TransportError` (`0x2d9b83bc0`) [sym].
        func sendNotification(withPayload payload: Packet.Payload) throws(TransportError)

        /// [sym] `0x2ad4dd5f0`, 3444 bytes, `throws(RawTransportError)`.
        ///
        /// [disasm] It touches no dictionary and no wire key — it only chooses where the
        /// send runs. In full:
        ///
        ///   let threadQoS = DispatchQoS(qos_class: qos_class_self())
        ///   let taskQoS   = DispatchQoS(qos_class: <from Task.currentPriority.rawValue>)
        ///   if threadQoS == taskQoS { try rawTransport.send(packet: packet); return }
        ///   logger.debug("\(debugName)/\(packet.header): Sending @\(…)/\(…)")
        ///   var result: Result<Void, RawTransportError>? = nil
        ///   let item = DispatchWorkItem(qos: taskQoS, flags: .enforceQoS) {
        ///       result = Result { try rawTransport.send(packet: packet) }
        ///   }
        ///   item.perform()          // synchronous, on the caller's thread
        ///   switch result { case nil: fatalError; case .failure(let e): throw e; … }
        ///
        /// Details, each resolved rather than inferred:
        ///  * the two QoS values come from `qos_class_self()` and from
        ///    `(extension in XPCDistributed) DispatchQoS.init(qos_class:)` applied to
        ///    `Task.currentPriority.rawValue`, and are compared through
        ///    `DispatchQoS : Equatable` [disasm, `+0xa8`..`+0x1cc`];
        ///  * the equal case calls witness slot +0x10 (`send(packet:)`) directly;
        ///  * the work item's `qos:` argument is the TASK QoS — traced from
        ///    `stp x19, x22, [x29, #-0xb0]` (x22 being the buffer
        ///    `DispatchQoS.init(qos_class:)` wrote the task value into) to the
        ///    `ldur x1, [x29, #-0xa8]` that feeds `DispatchWorkItem.init(qos:flags:block:)`
        ///    [disasm];
        ///  * `flags` is `DispatchWorkItemFlags.enforceQoS` [sym, the getter is called
        ///    directly];
        ///  * the block (`0x2ad4df414`) writes a `Result<(), RawTransportError>?` into a
        ///    box the outer frame allocated with the Optional tag byte pre-set to 0xFF;
        ///    after `perform()` the outer function reads that byte: 0xFF is `brk #1`
        ///    (the block did not run — unreachable), 1 is `throw`, 0 is success [disasm].
        ///  * log format string `"%s/%s: Sending @%s/%s"` at `0x2ad52c320`, read out of
        ///    `__TEXT,__oslogstring`; arguments 1 and 2 are `debugName` and
        ///    `String(describing: packet.header)` (`_print_unlocked` with
        ///    `type metadata for Packet.(Header)`). Which of arguments 3 and 4 is the
        ///    thread QoS is only *inferred*: argument 4 was traced to the task QoS,
        ///    argument 3 by elimination.
        func sendPacketWithProperQoS(_ packet: Packet) throws(RawTransportError)

        // ---- receive path -------------------------------------------------------

        /// [sym] `0x2ad4db994`, 1468 bytes. Called by both raw transports.
        ///
        /// [disasm] in order:
        ///   1. `swift_unknownObjectWeakLoadStrong(&inboundSession)`; if nil, log
        ///      `"Inbound session is nil when a packet is received on %s"`
        ///      (`0x2ad52c2b0`, `%s` = `debugName`) and return — the packet is dropped;
        ///   2. `dispatchPrecondition(condition: .onQueue(queue))`
        ///      ([sym] `Dispatch._dispatchPreconditionTest(DispatchPredicate)`; a false
        ///      result falls into `brk #1`);
        ///   3. switch on the header's enum tag byte at packet offset 8:
        ///      tag 0 -> `inboundSession.handleReceivedRequest(packet.payload,
        ///               replyUsing: { [id, self] payload in … })`
        ///               (witness slot +0x10; the reply closure is `0x2ad4dd1fc`, whose
        ///               captures are exactly the header's `ID64` and `self`),
        ///      tag 1 -> `requestManager.assumeIsolated { … }` on the request manager's
        ///               queue, completing the pending request for that `ID64`
        ///               (closure `0x2ad4de364`),
        ///      tag 2 -> `inboundSession.handleReceivedNotification(packet.payload)`
        ///               (witness slot +0x18).
        /// Witness slot offsets match the `method descriptor` offsets from
        /// `protocol requirements base descriptor for …InboundSessionProtocol`
        /// (`0x2ad527ccc`) exactly: +0x10, +0x18, +0x28 [sym].
        func handleReceivedPacket(_ packet: Packet)

        /// [sym] `0x2ad4dbf50`, 1028 bytes.
        /// [disasm] in order:
        ///   1. trip the fuse (`caslb 0 -> 1` on `self+0x20`); on the first trip only,
        ///      log `"%s is cancelled because remote end is gone."` (`0x2ad52c2f0`);
        ///   2. assert the request manager's executor
        ///      (`swift_task_isCurrentExecutor(requestManager.queue…)`; the failure path
        ///      builds `"Incorrect actor executor assumption; Expected same executor as
        ///      …"` and calls `_assertionFailure`), then
        ///      `requestManager.assumeIsolated { … }` (closure `0x2ad4defa8`) to fail
        ///      every pending request;
        ///   3. weak-load `inboundSession`; if present, clear it (weak-assign nil and
        ///      zero the witness table slot) and call
        ///      `inboundSession.handleTransportCancellation()` (witness slot +0x28).
        /// Note step 3's order: the reference is cleared BEFORE the callback runs.
        func handleCancellation()

        /// [sym] `0x2ad4e11b8`. Returns whether this call was the one that cancelled.
        /// [disasm] `caslb 0 -> 1` on the fuse at `self+0x20`; the return value is
        /// `previous == 0`, and `rawTransport.cancel()` (witness slot +0x18) is called
        /// only on that first transition.
        func cancel() -> Bool

        deinit
    }
}

// ==========================================================================
// MARK: - RawTransportProtocol
// ==========================================================================

extension XPCSystem.Transport {

    /// [sym] `protocol descriptor` `0x2ad526da4`,
    /// `protocol requirements base descriptor` `0x2ad526db4`.
    /// [fieldmd] listed as `protocol`, NOT `class-protocol` — it is not class
    /// constrained, which is why `Transport.rawTransport` is a 40-byte boxed
    /// existential rather than two words.
    ///
    /// Exactly four requirements, and their order is read from the four
    /// `method descriptor` addresses relative to the base descriptor
    /// (+0x8, +0x10, +0x18, +0x20) [sym]; the same offsets are the witness table slots
    /// actually called from `Transport.activate/sendPacketWithProperQoS/cancel/auditToken`
    /// [disasm]. There is no fifth slot and no inherited-protocol witness slot.
    ///
    /// Both conformances have static (non-lazy) witness tables [sym]:
    /// `protocol witness table for InProcessRawTransport : RawTransportProtocol`
    /// (`0x2d9b831c8`) and `… XPCRawTransport …` (`0x2d9b837d8`).
    ///
    /// UNRESOLVED: whether the protocol inherits `Sendable`. A marker protocol adds no
    /// witness table slot, so its absence from the witness table proves nothing; nor do
    /// nominal/protocol descriptors, which omit marker protocols from the requirement
    /// signature entirely. And the declared type of `Transport.rawTransport` mangles as a
    /// single-protocol existential (`…_p`, not a composition), which rules out
    /// `any RawTransportProtocol & Sendable` at the use site but not
    /// `protocol RawTransportProtocol: Sendable`. Next step: `outlined …` symbols tend to
    /// print fuller signatures than a type's own symbols do, so grep those, and read the
    /// protocol descriptor's requirement-signature records at `0x2ad526da4`.
    protocol RawTransportProtocol {

        /// [sym] `throws(SetupError)`. Called by `Transport.activate()`.
        func activate(linking transport: XPCSystem.Transport) throws(XPCSystem.SetupError)

        /// [sym] `throws(RawTransportError)`. The only place a packet leaves the process.
        func send(packet: Packet) throws(RawTransportError)

        func cancel()

        var auditToken: audit_token_t? { get }
    }
}

// ==========================================================================
// MARK: - Escalation
// ==========================================================================

extension XPCSystem.Transport {

    /// [fieldmd] `0x2ad52a274`: two cases, `escalationHandler` with mangled payload
    /// `{XPCSystem.Session}5using_t` (a single labelled element, label `using`) and
    /// `senderTask` with no payload record.
    /// [measured] size 8, stride 8, `NonPOD`, extra inhabitants 2147483646 — i.e. one
    /// class-reference payload case plus one empty case encoded as the null pointer.
    ///
    /// [measured] Not `private`: no symbol spells it with a discriminator or parentheses.
    /// It has no methods, no accessors and no initialiser symbols at all — only metadata,
    /// value witnesses and one `outlined destroy` (`0x2ad4e76f8`).
    ///
    /// [measured] A `BL`/`ADRP+ADD` cross-reference scan of `__text` against its type
    /// metadata (`0x2d9b83b30`), its metadata accessor (`0x2ad4e7854`) and its outlined
    /// destroy finds exactly two call sites, both inside
    /// `Transport.sendRequest(id:payload:)` — the `(4) await resume` and
    /// `(6) suspend resume` partial functions. So this enum exists only as
    /// `sendRequest`'s local escalation state.
    ///
    /// [disasm] It lives inside a `Mutex` captured by the priority-escalation handler:
    /// the handler closure (`0x2ad4e0e24`) does `os_unfair_lock_lock(ctx)`, reads
    /// `ctx+8`, and if that is non-null builds `Session.RemoteNotification` case 1 with
    /// the request `ID64` and a `TaskPriority` and calls
    /// `Session.sendNotification(_:)`; if it is null it does nothing.
    /// The `perform` closure (`0x2ad4e0140`) is what moves the state from null to a
    /// `Session` after the packet has gone out. So `.senderTask` means "the sending task
    /// is still on the hook for the escalation" and `.escalationHandler(using:)` means
    /// "notify the peer over this session".
    enum EscalationHandledBy {
        case escalationHandler(using: XPCSystem.Session)
        case senderTask
    }
}

// ==========================================================================
// MARK: - Errors
// ==========================================================================

extension XPCSystem.Transport {

    /// [fieldmd] `0x2ad52a318`: one case, payload `SS7message_t` — a single `String`
    /// labelled `message`. [measured] size 16, stride 16, extra inhabitants
    /// 0x7fffffff, i.e. exactly `String`'s: one payload case and no empty case.
    /// [sym] conformance descriptor `0x2ad520f70`, `: Swift.Error`.
    ///
    /// [disasm] Thrown by `XPCRawTransport.send(packet:)` and
    /// `InProcessRawTransport.send(packet:)`; the in-process one uses the `__cstring`
    /// literal `"InProcessRawTransport is cancelled"`.
    enum RawTransportError: Error {
        case rawTransportCancelled(message: String)
    }

    /// [fieldmd] `0x2ad52a29c`: `transportCancelled` with payload `SS7message_t`,
    /// `taskCancelled` with no payload record. [measured] size 16, stride 16, extra
    /// inhabitants 0x7ffffffe — `String`'s count minus one, which is one payload case
    /// plus one empty case. This is how the payload was pinned to
    /// `transportCancelled` rather than to `taskCancelled`: the value that
    /// `sendNotification` hands to `swift_willThrowTypedImpl` under
    /// `type metadata for TransportError` is a bare 16-byte `String` in registers
    /// (x0/x1) with no tag fixup [disasm].
    /// [sym] conformance descriptor `0x2ad520ed0`, `: Swift.Error`.
    enum TransportError: Error {
        case transportCancelled(message: String)
        case taskCancelled
    }
}

// ==========================================================================
// MARK: - Packet
// ==========================================================================

extension XPCSystem.Transport {

    /// [fieldmd] `0x2ad52a2c4`: `header: {Packet.(Header)}`, `payload: {Packet.Payload}`,
    /// both with flags 0x0 (`let`).
    /// [sym] conforms to `Swift.RawRepresentable` (conformance descriptor `0x2ad520f10`)
    /// with `RawValue == XPC.XPCDictionary`, and to `Swift.CustomStringConvertible`
    /// (`0x2ad520f48`).
    ///
    /// THE WIRE FORMAT OF THIS TYPE IS ALREADY RESOLVED. `rawValue`,
    /// `init(rawValue:)`, the three xpc keys (`"headerCategory"`, `"headerID"`,
    /// `"payload"`), the enum-tag-to-`headerCategory` renumbering, the strictness of the
    /// decoder, and the fact that all three packet kinds go out through the one-way
    /// `XPCSession.send(message:)` are written up in
    /// `docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md`,
    /// section "Envelope". Do not re-derive them from here.
    struct Packet: RawRepresentable, CustomStringConvertible {

        let header: Header
        let payload: Payload

        /// [sym] `0x2ad4dc354`. Returns nil on any rejection. See the wire-format spec.
        init?(rawValue: XPCDictionary)

        /// [sym] `0x2ad4dc7a4`. Encodes: copies `payload.dictionary` and tail-calls
        /// `Header.write(to:)` on the copy. See the wire-format spec.
        var rawValue: XPCDictionary { get }

        /// [sym] `0x2ad4df3c8`, 76 bytes. [disasm] the entire body is
        /// `_print_unlocked(self, &out)` with `x2 = type metadata for Packet.(Header)`
        /// (`0x2d9b83ce0`) and `x0 = self` — and `header` is field 0 at offset 0, so
        /// this is `String(describing: header)`. No literal text is added.
        var description: String { get }
    }
}

extension XPCSystem.Transport.Packet {

    /// PRIVATE. [sym] every symbol spells it `Packet.(Header)`, and
    /// `Packet.(Header in _FAA01C12A2380E0897C7DDEFF26409A2).write(to:)` carries a
    /// file-private discriminator; the `write(to:)` symbol has local binding (`t`).
    ///
    /// [fieldmd] `0x2ad52a334`, kind `mp-enum`: `request` payload `{ID64}2id_t`
    /// (labelled `id`), `response` payload `{ID64}2to_t` (labelled `to`),
    /// `notification` with no payload record.
    /// [measured] size 9, stride 16, align 8, extra inhabitants 253 — the `ID64` at
    /// offset 0 and the tag byte at offset 8, which every construction site writes
    /// literally (`str <id>, [buf]` then `strb <tag>, [buf, #8]`) [disasm].
    /// Do NOT read that 253 as `256 − caseCount` proving payload-freeness: the two
    /// numbers collide here (this enum has three cases *and* a spare tag byte), and the
    /// payloads are what the field descriptor and the disassembly both show.
    /// Tag values: `request` = 0, `response` = 1, `notification` = 2 — see the
    /// wire-format spec for the four independent sites that pin this and for the
    /// separate `headerCategory` numbering, which is different.
    private enum Header {
        case request(id: ID64)
        case response(to: ID64)
        case notification

        /// [sym] `0x2ad4e134c`, 220 bytes, local binding. The hand-written writer.
        /// Resolved in full in the wire-format spec.
        func write(to dictionary: inout XPCDictionary)

        /// [sym] `0x2ad4e71c0`. The exact inverse. Resolved in the wire-format spec.
        init?(from dictionary: XPCDictionary)
    }

    /// [fieldmd] `0x2ad52a2ec`: one stored property `dictionary` of type
    /// `XPC.XPCDictionary`, with flags bit 0x2 set, i.e. declared `var`.
    /// [sym] only a getter exists (`0x2ad4e1428`), no setter and no `modify` — so it is
    /// most likely `private(set) var` or a `var` mutated only inline. Recorded as `var`
    /// because that is what the field record says; the setter's absence is noted rather
    /// than resolved.
    ///
    /// The `"payload"` key and the overlay byte-stream body this type carries are
    /// resolved in the wire-format spec — see "What actually carries an XPCDistributed
    /// body".
    struct Payload {

        var dictionary: XPCDictionary

        /// [sym] `0x2ad4e1668`.
        init?(from dictionary: XPCDictionary)

        /// [sym] `0x2ad4e1488`, `throws` (untyped).
        init<T: Encodable>(encoding value: T, userInfo: [CodingUserInfoKey: Any]) throws

        /// [sym] `0x2ad4e1630`, `throws` (untyped). `userInfo` has a default argument
        /// ([sym] `default argument 0 of …Payload.decode(as:userInfo:)`, `0x2ad4bd8f4`).
        func decode<T: Decodable>(as type: T.Type,
                                  userInfo: [CodingUserInfoKey: Any] = …) throws -> T
    }
}

// ==========================================================================
// MARK: - XPCRawTransport
// ==========================================================================

extension XPCSystem.Transport {

    /// [sym] resilient class; only `__allocating_init` has a method descriptor
    /// (`0x2ad526c5c`) and dispatch thunk, so it is not `final`.
    /// [measured] field offsets 0x10, 0x18, 0x20; instance size 0x28.
    class XPCRawTransport: RawTransportProtocol {

        /// [fieldmd] `{XPCSystem.Transport}Sg`, flags 0x2 (`var`). NOT weak and NOT
        /// unowned — a plain strong `Optional`. Offset 0x10 [measured].
        ///
        /// That does create a reference cycle `Transport -> rawTransport ->
        /// parentTransport`, and it is broken explicitly rather than by ownership:
        /// see `InProcessRawTransport.handleReceivedCancellation()`, which sets
        /// `parentTransport = nil` after delivering the cancellation [disasm].
        /// UNRESOLVED for `XPCRawTransport` specifically: I did not find the site that
        /// clears this field. Next step: disassemble the XPC session's cancellation
        /// handler installed by `configureAndActivateSession(queue:)` (the
        /// `@Sendable (XPCRichError) -> ()` closure at `0x2ad4daf9c`).
        private var parentTransport: XPCSystem.Transport?

        /// [fieldmd] `XPC.XPCSession`, flags 0x0. Offset 0x18 [measured].
        private let session: XPCSession

        /// [fieldmd] `{XPCRawTransport.Role}`, flags 0x0. Offset 0x20 [measured].
        private let role: Role

        /// [sym] `0x2ad4da9b0`. `role` has a default argument
        /// ([sym] `default argument 1 of …XPCRawTransport.init(session:role:)`,
        /// `0x2ad4bd8e4`); which value it defaults to is UNRESOLVED — next step is to
        /// disassemble `0x2ad4bd8e4`, which is 16 bytes.
        init(session: XPCSession, role: Role = …)

        /// [sym] `0x2ad4da9e4`, 628 bytes, `throws(SetupError)`.
        /// [disasm]:
        ///   self.parentTransport = transport      // release old, retain new
        ///   if case .peer(let gate) = role {
        ///       // under gate's os_unfair_lock, at gate+0x10:
        ///       guard gate.state == .initial else { return }   // state byte at gate+0x14
        ///       try configureAndActivateSession(queue: transport.queue)
        ///   } else {
        ///       try configureAndActivateSession(queue: transport.queue)
        ///   }
        /// A thrown error becomes `SetupError` carrying
        /// `"Failed to activate XPCSession (error: " + String(describing: error) + …"`
        /// (`__cstring`, 38 bytes, then `_print_unlocked`, then
        /// `swift_willThrowTypedImpl` with the `SetupError : Error` witness) [disasm].
        /// So an already-activated or already-cancelled peer gate silently suppresses
        /// activation.
        func activate(linking transport: XPCSystem.Transport) throws(SetupError)

        /// [sym] `0x2ad4dac58`, local binding, file-private discriminator
        /// `_6E80E26E63AF20C261D5E7DB1C74DCD5`; `throws` (untyped).
        /// [disasm] installs the session's incoming-message handler
        /// (`@Sendable (XPCDictionary) -> XPCDictionary?`, closure `0x2ad4dad4c`) and its
        /// error handler (`@Sendable (XPCRichError) -> ()`, closure `0x2ad4daf9c`), then
        /// activates the session on `queue`.
        private func configureAndActivateSession(queue: DispatchQueue) throws

        /// [sym] `0x2ad4db0c0`, 504 bytes, `throws(RawTransportError)`.
        /// [disasm] copies `packet.payload.dictionary`, calls `Header.write(to:&dict)`
        /// inline, then `session.send(message: dict)`; a thrown XPC error is rethrown as
        /// `RawTransportError.rawTransportCancelled(message:)` built from a literal plus
        /// the error's description. Note the message is sent one-way — there is no
        /// reply-expecting variant. (See the wire-format spec, "Correlation lives in the
        /// envelope".)
        func send(packet: Packet) throws(RawTransportError)

        /// [sym] `0x2ad4db014`, 172 bytes.
        /// [disasm]:
        ///   if case .peer(let gate) = role {
        ///       // under gate's lock:
        ///       guard gate.state < .canceled else { return }   // unsigned compare vs 2
        ///       gate.state = .canceled
        ///       session.rejectPeer(reason: "(transport cancelled by client)")
        ///   } else {
        ///       session.cancel(reason: "(transport cancelled by client)")
        ///   }
        /// Both branches use the same 31-byte `__cstring` literal. The peer branch calls
        /// `rejectPeer(reason:)` even when the gate was already `.activated`, not only
        /// when it was `.initial`.
        func cancel()

        /// [sym] `0x2ad4db2b8`.
        /// [disasm] `session.auditToken`, then
        /// `(extension in XPC) audit_token_t.isValid`; returns nil when invalid.
        var auditToken: audit_token_t? { get }

        deinit
    }
}

extension XPCSystem.Transport.XPCRawTransport {

    /// [sym] a class; `PeerGate.__allocating_init()` has a method descriptor
    /// (`0x2ad526cb4`) and a dispatch thunk, so it is not `final`.
    /// The ONLY members with symbols are `init()`, `deinit` and the field offset — the
    /// gate has no methods of its own. Its state is manipulated inline by
    /// `XPCRawTransport.activate(linking:)` and `.cancel()`, which take
    /// `os_unfair_lock` at `gate+0x10` and read/write the state byte at `gate+0x14`
    /// [disasm]. That is the `Mutex<State>` below: on Darwin `Synchronization.Mutex`
    /// is an `os_unfair_lock` followed by the value.
    class PeerGate {

        /// [fieldmd] `{Synchronization.Mutex}y{PeerGate.(State)}G`. Offset 0x10
        /// [measured].
        private let state: Mutex<State>

        init()

        /// PRIVATE. [sym] every symbol spells it `PeerGate.(State)`.
        /// [fieldmd] `0x2ad52a1d0`: three cases, none with a payload.
        /// [measured] size 1, stride 1. Raw tag values, from the comparisons in
        /// `activate` (`cbz` against 0) and `cancel` (unsigned `>= 2`) [disasm]:
        /// `initial` = 0, `activated` = 1, `canceled` = 2.
        /// [sym] conforms to `Swift.Hashable` (`0x2ad520df8`) and `Swift.Equatable`
        /// (`0x2ad520e38`) — synthesized witnesses, all four present.
        private enum State: Hashable {
            case initial
            case activated
            case canceled
        }
    }

    /// [fieldmd] `0x2ad52a18c`: `peer` with payload `{PeerGate}4gate_t` (labelled
    /// `gate`), `client` with no payload record.
    /// [measured] size 8, stride 8, `NonPOD`, extra inhabitants 2147483646 — one
    /// class-reference payload case plus one empty case as the null pointer. Every
    /// `role` test in the class is therefore a null check on one word [disasm].
    enum Role {
        case peer(gate: PeerGate)
        case client

        /// [sym] `static …Role.peer.getter` (`0x2ad4da930`) plus
        /// `property descriptor for static …Role.peer` (`0x2ad520d60`).
        /// [disasm] 44 bytes: fetch `PeerGate` metadata, `swift_allocObject`, return.
        /// So this is a static computed property that mints a FRESH gate on every
        /// access — it shadows the `case peer(gate:)` for callers who do not have one.
        static var peer: Role { get }
    }
}

// ==========================================================================
// MARK: - InProcessRawTransport
// ==========================================================================

extension XPCSystem.Transport {

    /// [sym] resilient class, `method lookup function` at `0x2ad4c707c`. Used by
    /// `XPCSystem.InProcessService.connect(using:)`, which returns a `Transport`
    /// built over one of these [sym].
    /// [measured] field offsets 0x10, 0x18, 0x20.
    class InProcessRawTransport: RawTransportProtocol {

        /// [fieldmd] `{XPCSystem.Transport}Sg`, flags 0x2 — strong `var`, not weak.
        /// Offset 0x10 [measured]. Cleared in `handleReceivedCancellation()` [disasm],
        /// which is what breaks the cycle with the owning `Transport`.
        private var parentTransport: XPCSystem.Transport?

        /// [fieldmd] `Sb`, flags 0x2. Offset 0x18 [measured]. A one-shot guard against
        /// delivering cancellation twice; see `handleReceivedCancellation()`.
        private var cancellationCompleted: Bool

        /// [fieldmd] `{Synchronization.Mutex}y{Locked}G`, flags 0x0. Offset 0x20
        /// [measured]: `os_unfair_lock` at 0x20, `remoteEnd` at 0x28 [disasm].
        private let locked: Mutex<Locked>

        /// [fieldmd] `0x2ad52a014`, one field.
        struct Locked {
            /// [fieldmd] `{InProcessRawTransport}Sg`, flags 0x2.
            var remoteEnd: InProcessRawTransport?

            /// [sym] `0x2ad4c6310` (8 bytes: `mov x0, #0; ret`) and
            /// `0x2ad4c636c` (memberwise).
            init()
            init(remoteEnd: InProcessRawTransport?)
        }

        /// [sym] `0x2ad4c630c`, `static`. The real body is
        /// `function signature specialization <Arg[0] = Dead, Arg[1] = Dead>`
        /// (`0x2ad4c6d0c`) — the compiler proved the `String` argument DEAD, i.e. the
        /// debug name it takes is unused in this build [sym].
        /// Returns the two ends already pointed at each other; the tuple labels
        /// `outbound` / `inbound` are from the symbol.
        static func makePair(_ debugName: String)
            -> (outbound: InProcessRawTransport, inbound: InProcessRawTransport)

        /// [sym] `0x2ad4c6370`, 60 bytes, `throws(SetupError)`.
        /// [disasm] the entire body is `self.parentTransport = transport` (release old,
        /// retain new). It never throws in practice and does no handshake.
        func activate(linking transport: XPCSystem.Transport) throws(SetupError)

        /// [sym] `0x2ad4c69b0`, 436 bytes, `throws(RawTransportError)`.
        /// [disasm] takes `locked.remoteEnd` under the lock; if nil, throws
        /// `.rawTransportCancelled(message: "InProcessRawTransport is cancelled")`
        /// (the `__cstring` literal); otherwise boxes a copy of the packet and calls
        /// `remoteEnd.receive { $0.handleReceivedPacket(packet) }`.
        func send(packet: Packet) throws(RawTransportError)

        /// [sym] `0x2ad4c664c`, 136 bytes.
        /// [disasm] takes `remoteEnd` out of the mutex and nils it, then delivers a
        /// cancellation to BOTH ends — `self.receive { $0.handleReceivedCancellation() }`
        /// and `remote.receive { $0.handleReceivedCancellation() }`, two calls with the
        /// same closure (`0x2ad4c7300`, which the symbol table names as both
        /// `closure #2` and `closure #3` of this function — a merged pair).
        func cancel()

        /// [sym] `0x2ad4c6b64`, 20 bytes. [disasm] returns nil unconditionally — there
        /// is no audit token for an in-process pair.
        var auditToken: audit_token_t? { get }

        /// [sym] `0x2ad4c63ac`, 672 bytes, local binding, file-private discriminator
        /// `_2E4FF6C38697ACBDC759839CD8B3F868`.
        /// [disasm] `guard let t = self.parentTransport else { return }`, then
        /// `t.queue.async(group: nil, qos: .unspecified, flags: [], execute: { body(self) })`
        /// — so it hops onto ITS OWN transport's queue and hands `self` to the closure.
        /// That is why `cancel()` calls it on both ends: each end wakes up on its own
        /// queue.
        private func receive(_ body: @escaping (InProcessRawTransport) -> ())

        /// [sym] `0x2ad4c6848`, 360 bytes, local binding.
        /// [disasm] `dispatchPrecondition(condition: .onQueue(…))`; reads `remoteEnd`
        /// under the lock and returns if it is nil (i.e. after cancellation); otherwise
        /// `parentTransport?.handleReceivedPacket(packet)`.
        private func handleReceivedPacket(_ packet: Packet)

        /// [sym] `0x2ad4c66d4`, 372 bytes, local binding.
        /// [disasm] `dispatchPrecondition(condition: .onQueue(…))`;
        /// `locked.withLock { $0.remoteEnd = nil }`;
        /// `guard !cancellationCompleted else { return }`;
        /// `cancellationCompleted = true`;
        /// `parentTransport!.handleCancellation()` (nil traps, `brk #1`);
        /// `parentTransport = nil`.
        private func handleReceivedCancellation()

        deinit
    }
}

// ==========================================================================
// MARK: - TransportReceiver
// ==========================================================================

extension XPCSystem {

    /// [sym] resilient class, `method lookup function` `0x2ad4eb5d8`; only
    /// `__allocating_init` has a method descriptor (`0x2ad526e50`).
    /// Declared in `.../XPCDistributed/Transport/TransportReceiver.swift`.
    /// [measured] field offsets 0x10, 0x18, 0x20, 0x30, 0x40; instance size 0x48.
    ///
    /// Used by `ServiceRegistry.register(service:receiver:actorSystem:targetQueue:)`
    /// and by `InProcessService`, which holds an
    /// `UnownedAwaitableEvent<TransportReceiver>` [sym].
    class TransportReceiver {

        /// [fieldmd] `{XPCDistributed.Fuse}`. Offset 0x10 [measured].
        private let isCancelledFuse: Fuse

        /// [fieldmd] `{XPCDistributed.XPCSystem}`. Offset 0x18 [measured].
        private let actorSystem: XPCSystem

        /// [fieldmd] mangled `yt6result_{Session.LocalInterface.ActivationToken}5tokent`
        /// `{Session.LocalInterface}nYaYbc`: `n` = consuming/`__owned`, `Ya` = `async`,
        /// `Yb` = `@Sendable`, and the return is the labelled tuple
        /// `(result: (), token: ActivationToken)`. Offset 0x20, 16 bytes [measured].
        /// The same type appears verbatim in the `init` symbol [sym].
        private let peerHandler: @Sendable (__owned Session.LocalInterface) async
            -> (result: (), token: Session.LocalInterface.ActivationToken)

        /// [fieldmd] `yyYbcSg`, flags 0x2. Offset 0x30, 16 bytes [measured].
        private var cancellationHandler: (@Sendable () -> ())?

        /// [fieldmd] `{TransportReceiver.(PeerTaskTable)}`. Offset 0x40 [measured].
        private let peerHandlingTasks: PeerTaskTable

        /// [sym] `0x2ad4e99f0`.
        init(actorSystem: XPCSystem,
             peerHandler: @Sendable (__owned Session.LocalInterface) async
                 -> (result: (), token: Session.LocalInterface.ActivationToken))

        /// [sym] `0x2ad4e94d8`. [disasm] `peerHandlingTasks.liveCount`, i.e. the
        /// mutex-guarded count of `.live` slots.
        var peerTaskCount: Int { get }

        /// [sym] `0x2ad4e8e40`, 604 bytes, `throws(SetupError)`.
        /// [disasm] builds `Session(actorSystem:transport:options:)`, takes
        /// `session.debugDescription` as a task name, starts the peer handler with
        /// `Task.immediate(name:priority:executorPreference:operation:)` producing a
        /// `Task<Session.LocalInterface.ActivationToken, Never>`, records it in
        /// `peerHandlingTasks` under the session's `ID64`, and calls
        /// `session.readyToReceive(task)` [all four calls resolved by symbol].
        ///
        /// **[corrected — see `Slot`]** What the table records is the running task's
        /// `UnsafeCurrentTask`, not the `Task` value, and the slot passes `initial →
        /// task(_)`. `Task.immediate` runs the handler synchronously up to its first
        /// suspension, which is what lets its exports land before this returns and is the
        /// natural place for the running task to record its own current-task handle.
        func attachTransport(_ transport: Transport) throws(SetupError)

        /// [sym] `0x2ad4e91dc`, 764 bytes. Returns the newly created peer-side session.
        /// [disasm] same shape as `attachTransport`, but it builds a
        /// `Session.LocalSessionState` (with a weak back-reference, `swift_weakInit` /
        /// `swift_weakAssign`) and a second `Session` via
        /// `Session.init(actorSystem:local:options:)`, naming it
        /// `"\(session.debugDescription)/localPeer"` — `"/localPeer"` is a Swift small
        /// string decoded from `movz`/`movk` immediates at `+0x98`/`+0xa8` and so
        /// appears in no string table.
        func attachLocalSession(_ session: Session) -> Session

        /// [sym] `0x2ad4e90f4`. [disasm] stores the closure into `self+0x30`/`+0x38`,
        /// releasing whatever was there. The parameter is not optional.
        func setCancellationHandler(_ handler: @Sendable @escaping () -> ())

        /// [sym] `0x2ad4e9138`, 164 bytes.
        /// [disasm] `caslb 0 -> 1` on the fuse at `self+0x10`; returns immediately if it
        /// was already tripped. Then it TRAPS (`brk #1`) if `cancellationHandler` is nil,
        /// calls it, and clears it. So `setCancellationHandler` must have been called
        /// before `cancel()`.
        func cancel()

        /// [sym] `0x2ad4e952c`, `async`, with three resume partial functions.
        /// [disasm] under the mutex it walks `peerHandlingTasks` and cancels each running
        /// slot (`UnsafeCurrentTask.cancel()`), then awaits — so it cancels every peer and
        /// then waits for them.
        ///
        /// **[UNRESOLVED — what it awaits]** The first read said it collected
        /// `[Task<ActivationToken, Never>]` and awaited each `.result`. That cannot be
        /// right given the corrected `Slot`: the slot holds an `UnsafeCurrentTask`, which
        /// has no `.result`/`.value` to await. So the await is on *something else* — a
        /// per-session completion event, a keeper task, or a live-count reaching zero. This
        /// is the deciding question (see `Slot`): it is what tells us whether the shutdown
        /// join is hand-rolled or structured. Also UNRESOLVED: whether the log line
        /// `"%s handler did not wait for cancellation."` (`0x2ad52c360`) is emitted here or
        /// from `Session`.
        func unwindPeers() async

        deinit
    }
}

extension XPCSystem.TransportReceiver {

    /// PRIVATE. [sym] every symbol spells it `TransportReceiver.(PeerTaskTable)`, and
    /// its members carry the file-private discriminator
    /// `_8B81741E63C7FBE05247CDB0318EE90A`; all its symbols have local binding.
    /// A class, with an `anonymous descriptor` (`0x2ad526e58`) rather than a public
    /// nominal one.
    private class PeerTaskTable {

        /// [fieldmd] `{Synchronization.Mutex}ySD y{ID64}{Slot}GG` — a
        /// `Mutex<[ID64: Slot]>`. Offset 0x10 [measured]; `os_unfair_lock` at 0x10 and
        /// the dictionary at 0x18 [disasm].
        let storage: Mutex<[ID64: Slot]>

        /// [sym] `0x2ad4ea1d4`, 284 bytes.
        /// [disasm] under the lock: `__RawDictionaryStorage.find(id)`; a found terminal
        /// slot (`.doneOrCancelled`) is removed and the registration proceeds; a found
        /// running slot (`.task`) hits `_assertionFailure` with
        /// `"Bug in XPCDistributed: duplicate sessionID in PeerTaskTable"`; otherwise the
        /// slot advances into the running state.
        ///
        /// **[corrected — see `Slot`]** An earlier reading had this as `storage[id] =
        /// .live(task)` with a `Task` payload. The slot actually holds an
        /// `UnsafeCurrentTask` and moves `initial → task(_) → doneOrCancelled`, so this
        /// records the running task's *current-task* handle, which implies the running
        /// task registers itself (the handle only exists inside `withUnsafeCurrentTask`),
        /// not that a `Task` value is handed in from the spawner. The exact parameter type
        /// is therefore **[UNRESOLVED]** pending a re-read of the operands; what is firm is
        /// the slot's payload type and its three states.
        func register(for id: ID64)

        /// [sym] the method itself has no symbol — it is inlined into its callers — but
        /// its closure does:
        /// `closure #1 (sending inout [ID64: Slot]) -> sending () in
        ///  …(PeerTaskTable).markCompleted(ID64) -> ()` at `0x2ad4ea974`, which is where
        /// the signature below comes from. The `__cstring`
        /// `"Bug in XPCDistributed: double completion in PeerTaskTable"` is the guard it
        /// enforces.
        func markCompleted(_ id: ID64)

        /// [sym] likewise inlined; its closure
        /// `closure #1 (sending inout [ID64: Slot]) -> sending Int in
        ///  …(PeerTaskTable).liveCount.getter : Int` is at `0x2ad4eaa64`.
        var liveCount: Int { get }

        deinit

        /// **[CORRECTED]** This was first read as a two-case `live(Task<…>)/tombstone`.
        /// The slot is a **three-state machine over an `UnsafeCurrentTask`**:
        ///
        /// ```
        /// enum Slot { case initial; case task(UnsafeCurrentTask); case doneOrCancelled }
        /// ```
        ///
        /// [measured] size 8, stride 8, `NonPOD`, extra inhabitants 2147483646 — one
        /// pointer-width payload with **two** payload-less cases. `UnsafeCurrentTask` wraps
        /// a single `Builtin.NativeObject`, so `task(_)` is that pointer and `initial` /
        /// `doneOrCancelled` occupy two extra inhabitants. That EI count, `2^31 − 2`, is
        /// *more* consistent with two spare-inhabitant cases than with the single one a
        /// `live/tombstone` pair would consume — the measurement corroborates the
        /// correction rather than merely permitting it.
        ///
        /// **Why `UnsafeCurrentTask`, not `Task`.** An `UnsafeCurrentTask` offers `cancel()`,
        /// `escalatePriority(to:)` (26+), `isCancelled`, `priority` — control only. It does
        /// **not** retain, and it has no `.value`/`.result`: the handler's result cannot be
        /// awaited through it. So the table holds a *control* handle and the result
        /// (`ActivationToken`) is discarded — a genuinely discarding model, which is why the
        /// result type never leaves the peer handler.
        ///
        /// **Why three states.** An `UnsafeCurrentTask` must not be used after its task
        /// ends, and it is obtained only inside `withUnsafeCurrentTask`. The states bracket
        /// its validity: `initial` is the reserved-but-not-yet-recorded window (id reserved
        /// before the running task records its own handle); `task(_)` is the only state in
        /// which cancel/escalate is sound; `doneOrCancelled` invalidates the handle before
        /// the task deallocates. That bracket is the whole reason a bare `Task` handle was
        /// *not* used — a `Task` would retain and be awaitable but heavier; Apple took the
        /// lighter handle and paid for it with this state machine.
        ///
        /// **[UNRESOLVED, and it is the one that matters]** `unwindPeers` (0x2ad4e952c) is
        /// `async` and was read as awaiting each task's `.result` — but an
        /// `UnsafeCurrentTask` cannot be awaited. So either that read is wrong, or the wait
        /// is on a separate completion signal (a per-session event, a keeper, a counter).
        /// Resolving *what `unwindPeers` awaits after cancel* is the deciding evidence for
        /// whether Apple's shutdown is a hand-rolled join or a structured one.
        ///
        /// Not itself spelled with a discriminator, so it is `internal` to a `private`
        /// enclosing type.
        enum Slot {
            case initial
            case task(UnsafeCurrentTask)
            case doneOrCancelled
        }
    }
}

// ==========================================================================
// MARK: - Types referenced from other subsystems (not reconstructed here)
// ==========================================================================
//
//   XPCSystem.SetupError, XPCSystem.Session and its LocalInterface /
//   LocalSessionState / RemoteNotification / ActivationToken,
//   XPCSystem.InboundSessionProtocol, XPCSystem.BackpressurePolicy,
//   XPCDistributed.Fuse, XPCDistributed.ID64 and ID64.Generator,
//   XPCDistributed.RequestManager, XPCDistributed.BackpressureManager,
//   XPC.XPCDictionary, XPC.XPCSession.
//
// How a `Session` reaches its `Transport`, and how the cycle is broken (from the Session
// agent, corroborated here): `Session.Kind.xpc` carries a `Transport` as its enum
// payload, so the reference is through `Kind`, not through a stored property; and the
// reverse edge, `Transport.(inboundSession)`, is assigned weakly — by
// `Session.init(actorSystem:transport:options:)` on the Session agent's reading and by
// `Transport.setInboundSession(_:)` on mine — but those are two different functions, and
// `setInboundSession` has **zero callers in this image** (it has no method descriptor and is not
// a protocol requirement, so a direct scan is exhaustive for it). In this build the wiring
// happens only inside `Session.init`, which contains an inlined copy. The instructions are the
// same either
// way. So the `Session <-> Transport` cycle is broken on the transport's side.
//
// Two more facts about neighbours that this subsystem's disassembly pins, recorded here
// because they belong to someone else's file:
//
//   * `InboundSessionProtocol` has six named requirements; their witness table slot
//     offsets, relative to `protocol requirements base descriptor` `0x2ad527ccc`, are
//     +0x10 `handleReceivedRequest(_:replyUsing:)`, +0x18
//     `handleReceivedNotification(_:)`, +0x20 `handleActorShared(_:)`, +0x28
//     `handleTransportCancellation()`, +0x30 `actorSystem`, +0x38 `isBidirectional`
//     [sym], and `Transport` calls the first, second and fourth at exactly those
//     offsets [disasm]. The slot before +0x10 is the base conformance --
//     `base conformance descriptor for XPCSystem.InboundSessionProtocol:
//     XPCDistributed.Internal.Identifiable` at 0x2ad527cd4 = base+0x08, and 0x2ad527d60 for the
//     outbound one; null in the live table until instantiation. RESOLVED. The old note said no
//     `method descriptor` symbol; what it is is UNRESOLVED.
//   * `Session.RemoteNotification` case index 1 is the escalation notification: the
//     escalation handler stores tag 1 with `swift_storeEnumTagMultiPayload` and a
//     payload of (the request `ID64`, a `TaskPriority` at payload offset 0x30) before
//     calling `Session.sendNotification(_:)` [disasm].
//
// ==========================================================================
// MARK: - LEFT UNRESOLVED
// ==========================================================================
//
//  1. Whether `RawTransportProtocol` inherits `Sendable` (or any marker protocol).
//     Witness tables cannot show it and the existential mangling does not settle it.
//     Next: parse the requirement-signature records of the protocol descriptor at
//     `0x2ad526da4`.
//  2. The default value of `XPCRawTransport.init(session:role:)`'s `role:` parameter.
//     Next: disassemble `default argument 1 of …init(session:role:)` at `0x2ad4bd8e4`
//     (16 bytes).
//  3. Where `XPCRawTransport.parentTransport` is cleared. The in-process transport
//     clears its own in `handleReceivedCancellation()`; the XPC one has no equivalent
//     site that I found, so the `Transport <-> XPCRawTransport` cycle may be broken
//     elsewhere or not at all. Next: disassemble the session error handler closure at
//     `0x2ad4daf9c`.
//  4. Argument order of the `"%s/%s: Sending @%s/%s"` debug log in
//     `sendPacketWithProperQoS`. Argument 4 is resolved to the task QoS; argument 3 is
//     assigned to the thread QoS by elimination, not traced. The two stack slots the
//     log reads are written through the `sub xN, x29, #imm; stur …, [xN, #-0x100]`
//     idiom, which my reading of the listing did not follow to completion.
//  5. `Packet.Payload.dictionary` is declared `var` [fieldmd flags], but no setter or
//     `modify` accessor is emitted. Whether the source says `private(set) var` is not
//     established.
//  6. Whether `unwindPeers()` is the emitter of
//     `"%s handler did not wait for cancellation."` (`0x2ad52c360`).
//  7. Whether the `EscalationHandledBy` mutex is a `Synchronization.Mutex` or a
//     hand-rolled `os_unfair_lock` wrapper. The layout is right for `Mutex`
//     (lock word, value at +8) and the calls are direct `os_unfair_lock_lock` /
//     `_unlock`, which is what a specialized `Mutex.withLock` inlines to — but that
//     is consistent with both, and no metadata for the mutex type appears at the site.
