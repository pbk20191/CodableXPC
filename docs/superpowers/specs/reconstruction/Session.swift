// ===========================================================================================
// Reconstruction of Apple's `XPCDistributed` interface — the Session subsystem.
//
// Covers, all nested in `XPCDistributed.XPCSystem`:
//
//   Session                                  (class, 11 stored properties, all members)
//   Session.InitializationOptions            (OptionSet)
//   Session.Kind                             (multi-payload enum: xpc, local)
//   Session.LocalInterface
//   Session.LocalInterface.ActivationToken   (+ its private CodingKeys)
//   Session.LocalInterface.UncheckedHandoff  (+ its private Box)
//   Session.LocalSessionState                (class)
//   Session.RemoteInterface
//   Session.ServiceConnectArguments
//   Session.RemoteInvocationReplyEncoder     (private)
//   InboundSessionProtocol / OutboundSessionProtocol  (+ witness slot offsets)
//
// NOT covered here (other agents / already written up):
//   Session.RemoteInvocationRequest, .RemoteInvocationResponse, .RemoteNotification and their
//   coding — see docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md.
//   Session.handleReceivedRequest's inbound pipeline and Session.sendInvocation's outbound
//   pipeline bodies — same document. Only their signatures appear below.
//
// Every declaration carries how it was established. Vocabulary used in the annotations:
//
//   [symbol]      read out of `symbols-demangled.txt`; a demangled Swift symbol carries its
//                 own full signature, so this is a direct read, not an inference.
//   [fieldmd]     read out of the live image's `__TEXT,__swift5_fieldmd` field descriptor,
//                 INCLUDING the field's resolved type reference. `field-descriptors.txt` has
//                 only the names; the types below were resolved this round with a new
//                 `fieldtypes.py` probe that follows each record's type-reference relative
//                 pointer and resolves symbolic references (kind 0x01 direct / 0x02 indirect)
//                 through their context descriptors — and, for cross-image targets, through
//                 `dladdr`. That probe is what closed `Session.Kind`'s payloads and
//                 `RemoteInvocationReplyEncoder.userInfo`.
//   [offset]      read out of a live `direct field offset` variable.
//   [disasm @A]   resolved by disassembling the function at unslid address A.
//   [descriptor]  computed from protocol/method descriptor addresses.
//   [inference]   NOT resolved — says what it rests on.
//
// A `(name)` in parentheses in a demangled symbol means the declaration is `private`; those
// are written `private` below and called out.
//
// Unslid addresses are from the extracted macOS 27.0 (26A5388g) Mach-O, the same base the
// interop document uses. Live reads were done against the dlopen'd shared-cache image.
// ===========================================================================================

extension XPCSystem {

    // =======================================================================================
    // MARK: - The two session protocols
    // =======================================================================================
    //
    // Both requirement lists are read from the protocols' *method descriptor* symbols, in
    // descriptor order, and each requirement's witness-table slot offset is
    //
    //     slot = 8 * (methodDescriptorAddress - protocolRequirementsBaseDescriptorAddress) / 8
    //
    // i.e. slot = descriptorAddress - base. Slot 0 of a witness table is the conformance
    // descriptor, so the first requirement lands at +0x08.
    //
    // InboundSessionProtocol   requirements base 0x2ad527ccc   descriptor 0x2ad527c98
    //   +0x08  0x2ad527cd4  base conformance: Internal.Identifiable
    //   +0x10  0x2ad527cdc  handleReceivedRequest(_:replyUsing:)
    //   +0x18  0x2ad527ce4  handleReceivedNotification(_:)
    //   +0x20  0x2ad527cec  handleActorShared(_:)              <-- the slot ActorID.encode calls
    //   +0x28  0x2ad527cf4  handleTransportCancellation()
    //   +0x30  0x2ad527cfc  actorSystem.getter
    //   +0x38  0x2ad527d04  isBidirectional.getter
    //
    // OutboundSessionProtocol  requirements base 0x2ad527d58   descriptor 0x2ad527d30
    //   +0x08  0x2ad527d60  base conformance: Internal.Identifiable
    //   +0x10  0x2ad527d68  sendInvocation(to:target:invocation:)
    //   +0x18  0x2ad527d70  actorSystem.getter                 <-- the slot belongsTo/resolve call
    //
    // This *confirms* the interop document's two claims about slots (+0x20 inbound
    // handleActorShared, +0x18 outbound actorSystem) from the descriptor addresses directly.
    // [descriptor]

    /// `InboundSessionProtocol` is a **class-bound** protocol: its field descriptor's kind is
    /// `class-protocol` (5), not `protocol` (4). [fieldmd]
    /// Refines `XPCDistributed.Internal.Identifiable`, which is
    /// `{ associatedtype ID: Hashable; var id: ID { get } }` — read from its own descriptors
    /// (requirements base 0x2ad527168; +0x08 associated conformance `ID: Hashable`,
    /// +0x10 associated type `ID`, +0x18 `id.getter`). [descriptor]
    protocol InboundSessionProtocol: AnyObject, Internal.Identifiable {

        /// Dispatch thunk 0x2ad517090. [symbol]
        func handleReceivedRequest(
            _ payload: Transport.Packet.Payload,
            replyUsing: (Transport.Packet.Payload) -> ()
        )

        /// Dispatch thunk 0x2ad5170a4. [symbol]
        func handleReceivedNotification(_ payload: Transport.Packet.Payload)

        /// Dispatch thunk 0x2ad5170b8. [symbol]
        func handleActorShared(_ id: RawActorID.Local) -> SharedActorKey

        /// Dispatch thunk 0x2ad5170cc. [symbol]
        func handleTransportCancellation()

        /// Dispatch thunk 0x2ad5170e0. [symbol]
        var actorSystem: XPCSystem { get }

        /// Dispatch thunk 0x2ad5170f4. [symbol]
        var isBidirectional: Bool { get }
    }

    /// A plain (non-class-bound) protocol: field descriptor kind is `protocol` (4). [fieldmd]
    protocol OutboundSessionProtocol: Internal.Identifiable {

        /// Dispatch thunk 0x2ad51b6d8; async function pointer 0x2ad524688. Note the typed
        /// throws and the `inout` encoder. [symbol]
        func sendInvocation<Res: Codable>(
            to id: ActorID,
            target: Distributed.RemoteCallTarget,
            invocation: inout InvocationEncoder
        ) async throws(RemoteInvocationCancellationError) -> Res

        /// Dispatch thunk 0x2ad51b83c. [symbol]
        var actorSystem: XPCSystem { get }
    }

    // =======================================================================================
    // MARK: - Session
    // =======================================================================================

    /// Apple's file layout puts this across
    /// `Session.swift`, `Session+Inbound.swift`, `Session+Outbound.swift`,
    /// `Session+Transport.swift`, `Session+CommunicationProtocol.swift`. [cstrings]
    ///
    /// Conformances, each from its own `protocol conformance descriptor` symbol: [symbol]
    ///   `Hashable` (and `Equatable`), `CustomDebugStringConvertible`,
    ///   `Internal.Identifiable` (with `ID == ID64`), `InboundSessionProtocol`,
    ///   `OutboundSessionProtocol`.
    ///
    /// `Sendable` is **not** determinable from this binary: it is a marker protocol and emits
    /// no witness table, and the image contains zero `Sendable` conformance descriptors of any
    /// kind. Given the class holds a `Mutex` and is handed across tasks it is almost certainly
    /// `Sendable` or `@unchecked Sendable`, but that is not written down here as a fact.
    ///
    /// Only the two initialisers have `method descriptor` / `dispatch thunk` symbols; no other
    /// member does, so no other member is vtable-dispatched. Whether the class is spelled
    /// `final` was not resolved. [symbol]
    class Session {

        // -----------------------------------------------------------------------------------
        // Stored properties. All eleven, in declaration order, with their resolved types.
        //
        // Types come from two independent sources that agree: the `direct field offset`
        // symbols (which are demangled *with* the field's type) and the field descriptor's
        // own type references. `let`/`var` comes from the field record flag bit 0x2 (IsVar).
        // [offset] + [fieldmd]
        //
        // Live offsets (read from the `direct field offset` variables 0x2ad523558..0x2ad5235a8):
        //   +0x10 actorSystem   +0x18 id      +0x20 idGenerator  +0x28 kind
        //   +0x30 sharedActors  +0x40 cancellationEvent
        //   +0x58 unownedLocalInterfaceActivationEvent
        //   +0x70 isBidirectional
        //   +0x78 ownedLocalInterfaceActivationEvent
        //   +0x99 activationFuse
        //   +0xa0 pendingInvocationExecutionTasks
        // -----------------------------------------------------------------------------------

        let actorSystem: XPCSystem                                          // +0x10

        /// Minted in both initialisers from a **process-global** `ID64.Generator` behind a
        /// `swift_once` (guard at 0x2d70d7a90, counter at 0x2d70d7450) — an inlined `cas`
        /// loop with `adds #1` / `b.hs` to a `brk` on overflow. Same global generator that
        /// `XPCSystem.assignID` uses for `instanceID`. Not per-`XPCSystem`.
        /// [disasm @0x2ad5075b0 +0x88..0xb4, @0x2ad50c09c +0x7c..0xa8]
        let id: ID64                                                        // +0x18

        /// Zeroed by both initialisers (`str xzr, [self, #0x20]`), so its first `next()`
        /// yields 1. This is the generator the `SharedActorKey.dynamic` counter comes from.
        /// Exposed only through a `read` accessor (0x2ad5071e8) because `ID64.Generator`
        /// wraps an `Atomic`. [disasm @0x2ad5075b0 +0x25c] [symbol]
        let idGenerator: ID64.Generator                                     // +0x20

        let kind: Kind                                                      // +0x28

        /// One direction only: key -> actor. No reverse map. `_p` in the field descriptor's
        /// type reference confirms the value is a protocol existential.
        /// The mutex's lock word is at +0x30 and the dictionary at +0x38 — both initialisers
        /// write `stur wzr, [self,#0x30]` then the empty dictionary at +0x38.
        /// [offset] [fieldmd] [disasm @0x2ad5075b0 +0x78]
        private let sharedActors: Mutex<[SharedActorKey: any DistributedActor]>   // +0x30

        /// `UnownedAwaitableEvent` is `{ future: Combine.Future<(), Never>, promise }` and is
        /// 0x18 bytes: both initialisers build it with `Combine.Future.init(_:)` and then
        /// `stp` + `str` three words at +0x40/+0x48/+0x50.
        /// [offset] [fieldmd] [disasm @0x2ad5075b0 +0xc0..0x168]
        private let cancellationEvent: UnownedAwaitableEvent<()>            // +0x40

        /// Second `UnownedAwaitableEvent<()>`, built identically at +0x58/+0x60/+0x68.
        /// [offset] [fieldmd] [disasm @0x2ad5075b0 +0x170..0x200]
        private let unownedLocalInterfaceActivationEvent: UnownedAwaitableEvent<()>  // +0x58

        /// **This is a `let`, and this is where it is set** — the interop document's open
        /// question "where `isBidirectional` is written" is closed here, and the answer is
        /// `InitializationOptions`, exactly the candidate that document refused to guess.
        ///
        /// Both initialisers end with the same two instructions:
        ///
        ///     ubfx w8, wOptions, #1, #1     // extract bit 1 of the options raw value
        ///     strb w8, [self, #0x70]        // isBidirectional
        ///
        /// and bit 1 is `InitializationOptions.bidirectional` (raw value 2, below). There is
        /// no setter symbol and the field record flag has bit 0x2 clear, so it is immutable
        /// after init.
        /// [fieldmd] [disasm @0x2ad5075b0 +0x24c..0x254, @0x2ad50c09c +0x238..0x23c]
        let isBidirectional: Bool                                           // +0x70

        /// Set to `nil` by both initialisers. Populated by `readyToReceive(_:)`, which stores
        /// the passed `Task` as the event's owning task. Occupies +0x78..+0x99 (0x21 bytes:
        /// `future`, `promise` (2 words), `owningTask`, `posted: Bool`), which is why
        /// `activationFuse` sits at the unaligned +0x99.
        /// [offset] [fieldmd] [disasm @0x2ad5075b0 +0x204..0x248, @0x2ad506ff8]
        private var ownedLocalInterfaceActivationEvent: OwnedAwaitableEvent<LocalInterface.ActivationToken>?   // +0x78

        /// `Fuse` is `{ value: Bool }`. Flipped 0 -> 1 with a `caslb` in `activateTransport()`,
        /// in `readyToReceive(_:)`, and in the `.inactive`-guarded activation inlined into
        /// `init(actorSystem:transport:options:)` — a one-shot "already activated" latch.
        /// [offset] [fieldmd] [disasm @0x2ad507964 +0x28, @0x2ad5075b0 +0x2c8]
        private let activationFuse: Fuse                                    // +0x99

        /// Keyed by the **request body's** `ID64`, not the envelope's `headerID`. Note it is a
        /// bare `var` dictionary with no lock: `addPendingInvocationExecutionTask` opens with
        /// `Dispatch._dispatchPreconditionTest(_:)` before mutating, so the invariant that
        /// protects it is "called on the transport's serial queue", not a mutex.
        /// [offset] [fieldmd] [disasm @0x2ad507e88]
        private var pendingInvocationExecutionTasks: [ID64: Task<(), Never>]   // +0xa0

        // -----------------------------------------------------------------------------------
        // Initialisers. These are the only two members with `method descriptor` and
        // `dispatch thunk` symbols, i.e. the only vtable entries. [symbol]
        //
        // The `= []` default on `options` is resolved, not assumed: `default argument 2 of ...`
        // is `mov x0, #0; ret` for both (0x2ad4bd900 and 0x2ad4bd908). [disasm]
        // -----------------------------------------------------------------------------------

        /// Stores `.xpc(transport)` into `kind`; installs itself as the transport's
        /// `inboundSession` **weakly** (`transport+0x18 = <Session : InboundSessionProtocol>`
        /// witness table, then `swift_unknownObjectWeakAssign` into `transport+0x10`); and,
        /// **unless `options.contains(.inactive)`** (`tbnz wOptions, #2`), flips
        /// `activationFuse` and activates the raw transport inline — the body of
        /// `activateTransport()`, which is why this initialiser is the throwing one.
        /// [symbol] [disasm @0x2ad5075b0]
        init(
            actorSystem: XPCSystem,
            transport: Transport,
            options: InitializationOptions = []
        ) throws(SetupError)

        /// Stores `.local(local)` into `kind`. Does **not** test `.inactive` and never
        /// activates a transport, which is why it does not throw.
        /// The real body is the function-signature specialization at 0x2ad50c09c; the symbol
        /// at 0x2ad507a10 is a 72-byte forwarding shim.
        /// [symbol] [disasm @0x2ad507a10, @0x2ad50c09c]
        init(
            actorSystem: XPCSystem,
            local: LocalSessionState,
            options: InitializationOptions = []
        )

        /// Calls `cancel(because:)`. The string is almost certainly
        /// `"[Internal] auto-close after last release of session"` (`Session.swift`, cstrings),
        /// but the literal was not decoded at this call site — [inference], from the string
        /// table plus the observed call.
        /// [symbol] [disasm @0x2ad50723c]
        deinit

        // -----------------------------------------------------------------------------------
        // Computed properties — every one of these branches on `kind`'s tag bit.
        // -----------------------------------------------------------------------------------

        /// `ldr x0, [self,#0x28]; tbnz x0, #63 -> brk #1`.
        /// **Traps for a `.local` session.** Non-optional on purpose.
        /// [symbol] [disasm @0x2ad507a58]
        var transport: Transport { get }

        /// `LocalInterface(session: self)` — a one-word struct, so this is just a retain.
        /// Two accessor symbols exist, `local.getter` (0x2ad506fc4) and `local.read`
        /// (0x2ad507a78, a yield-once coroutine); which one the source declares is not
        /// resolved. [symbol] [disasm @0x2ad506fc4]
        var local: LocalInterface { get }

        /// `RemoteInterface(session: self)`. The getter at 0x2ad50d5d0 is 4 bytes and folds
        /// straight into `RemoteInterface.session.getter` at 0x2ad50d5d4. [symbol]
        var remote: RemoteInterface { get }

        /// Reads the *cancellation fuse of whichever kind* with an atomic acquire load:
        ///
        ///     x10 = kind & 0x7fffffffffffffff      // strip the tag bit
        ///     off = (kind is .xpc) ? 0x20 : 0x28   // csel
        ///     ldaprb w8, [x10 + off]
        ///
        /// Both offsets are live reads of `direct field offset` variables, not guesses:
        /// `Transport.(isCancelledFuse)` (0x2ad520fd8) holds 0x20 and
        /// `LocalSessionState.(cancellationFuse)` (0x2ad520328) holds 0x28.
        /// [symbol] [disasm @0x2ad506fd0] [offset]
        var isCancelled: Bool { get }

        /// `lsr x0, kind, #63` — literally "the kind is `.local`". So `optimizeSelfIPC` is
        /// not a stored flag or an option; it is a synonym for an in-process session.
        /// [symbol] [disasm @0x2ad5093a4]
        var optimizeSelfIPC: Bool { get }

        /// Tail-calls `RemoteInterface.auditToken.getter`.
        /// [symbol] [disasm @0x2ad5093b0]
        var remoteAuditToken: audit_token_t? { get }

        /// Branches on `kind` (`tbnz x8, #63`), appends two strings, prints through
        /// `_print_unlocked`. The exact format was not decoded.
        /// [symbol] [disasm @0x2ad506a08]
        var debugDescription: String { get }

        /// `ldrb w0, [self, #0x70]`. [symbol] [disasm @0x2ad507234]
        var isBidirectional: Bool { get }

        /// `Internal.Identifiable` witness (0x2ad50b108) is this getter.
        /// So `Session.ID == ID64`. [symbol]
        var id: ID64 { get }

        var kind: Kind { get }          // 0x2ad507208 — retains the payload, returns the tagged word
        var actorSystem: XPCSystem { get }   // 0x2ad5071d8

        // -----------------------------------------------------------------------------------
        // Lifecycle / transport
        // -----------------------------------------------------------------------------------

        /// Flips `activationFuse` with a `caslb`, traps (`brk #1`) if `kind` is `.local`
        /// (`tbnz x20, #63`), then projects the transport's `rawTransport` existential and
        /// calls a `RawTransportProtocol` witness through it.
        /// Inlined into `init(actorSystem:transport:options:)` and into `readyToReceive(_:)`.
        /// [symbol] [disasm @0x2ad507964]
        func activateTransport() throws(SetupError)

        /// Opens by testing `isBidirectional` (`ldrb w8, [self,#0x70]`) and reaching for
        /// `Swift._assertionFailure` — the message is
        /// `"Bug in XPCDistributed: Session must be bidirectional to enable receiving invocation"`
        /// (`Session.swift`). Then installs `ownedLocalInterfaceActivationEvent` with the
        /// passed task as its owner (clearing `posted` at +0x98), flips `activationFuse`, and
        /// activates the transport.
        /// The message attribution is [inference] from the string table; the `isBidirectional`
        /// test and the assertion call are [disasm @0x2ad506ff8].
        func readyToReceive(_ task: Task<LocalInterface.ActivationToken, Never>) throws(SetupError)

        /// Logs through `os.Logger`, flips two `caslb` latches, branches on `kind`, and for a
        /// `.local` session `swift_weakLoadStrong`s the peer session out of `LocalSessionState`
        /// to propagate the cancellation. [symbol] [disasm @0x2ad506a98]
        func cancel(because reason: String)

        /// `os_unfair_lock_lock` / `unlock` around a drain, plus two byte stores.
        /// Called by `handleTransportCancellation()`. Which lock is taken was not resolved.
        /// [symbol] [disasm @0x2ad508e64]
        func cancellationCompleted()

        /// 40 bytes: `cancelAllPendingInvocationExecutionTasks()` then
        /// `cancellationCompleted()`. `InboundSessionProtocol` witness at 0x2ad5168cc.
        /// [symbol] [disasm @0x2ad51683c]
        func handleTransportCancellation()

        /// `tbz x8, #63 -> brk #1`, i.e. **traps unless `kind` is `.local`**; then
        /// `swift_beginAccess`, `swift_weakLoadStrong` on `LocalSessionState.peerSession`, and
        /// `cbnz x0 -> brk #1` — it traps if a peer session is *already* set — before
        /// `swift_weakAssign`. So this is a one-shot weak back-pointer install.
        /// [symbol] [disasm @0x2ad506e84]
        func updatePeerSession(_ peer: Session)

        /// Both are `swift_task_switch` prologues onto the awaited event.
        /// Async function pointers at 0x2ad5231a0 and 0x2ad523168. [symbol]
        func waitForCancellation() async
        func waitForLocalInterfaceActivation() async

        /// Instantiates `XPC.XPCPeerRequirement` metadata and checks the peer against it —
        /// the actor-system-wide entitlement gate, distinct from the per-actor
        /// `RestrictedAccessDistributedActor.peerRequirement` check on the inbound path.
        /// Failure strings live in `Session+Outbound.swift`:
        /// `"(Internal) Remote peer does not satisfy actor system's peer requirement"`,
        /// `"(failed XPCSystem's peer requirement check)"`.
        /// String attribution is [inference]; the signature and the metadata call are
        /// [symbol] [disasm @0x2ad508ed8].
        func remoteSatisfiesActorSystemRequirement() -> Bool

        // -----------------------------------------------------------------------------------
        // Shared actors. Bodies already written up in the interop document; signatures only.
        // -----------------------------------------------------------------------------------

        /// [symbol] 0x2ad508e04 — mints `.dynamic(ID64)` from `idGenerator`.
        func shareActor(_ id: RawActorID.Local) -> SharedActorKey

        /// [symbol] 0x2ad5167dc — byte-identical clone of `shareActor`.
        /// `InboundSessionProtocol` witness at 0x2ad51686c. This is the slot `+0x20` that
        /// `ActorID.encode(to:)` calls through.
        func handleActorShared(_ id: RawActorID.Local) -> SharedActorKey

        /// `private`. The only writer of `sharedActors`. Asserts `isBidirectional`
        /// (`"API violation: Session must be bidirectional to share actor references"`,
        /// `Session.swift:263`). [symbol] 0x2ad508d08
        private func addSharedActor(_ id: RawActorID.Local, at key: SharedActorKey)

        /// The only reader of `sharedActors`. An exhaustive direct-branch scan of `__text`
        /// (re-run this round with the known-answer controls the interop document names)
        /// finds exactly two call sites: `handleReceivedRequest`'s `closure #2`
        /// (0x2ad514978) and `executeDirectInvocation` (0x2ad519e8c). [symbol] 0x2ad507dc8
        func resolveSharedActor(at key: SharedActorKey) -> (any DistributedActor)?

        // -----------------------------------------------------------------------------------
        // Pending invocation execution tasks. All five [symbol].
        // -----------------------------------------------------------------------------------

        func addPendingInvocationExecutionTask(_ task: Task<(), Never>, withID id: ID64)   // 0x2ad507e88
        func escalatePendingInvocationExecution(withID id: ID64, to priority: TaskPriority) // 0x2ad508008
        func verifyEscalatedInvocationResponse(withID id: ID64, to priority: TaskPriority)  // 0x2ad508284
        func cancelPendingInvocationExecutionTask(withID id: ID64)                          // 0x2ad50896c
        func cancelAllPendingInvocationExecutionTasks()                                     // 0x2ad508ae8
        func replyToPendingInvocation(withID id: ID64, replyBlock: () -> ()) async          // 0x2ad508620

        // -----------------------------------------------------------------------------------
        // The communication protocol. Bodies are in the interop document.
        // -----------------------------------------------------------------------------------

        /// `InboundSessionProtocol` witness at 0x2ad516864. [symbol] 0x2ad512a04
        func handleReceivedRequest(
            _ payload: Transport.Packet.Payload,
            replyUsing reply: (Transport.Packet.Payload) -> ()
        )

        /// `InboundSessionProtocol` witness at 0x2ad516868. [symbol] 0x2ad516268
        func handleReceivedNotification(_ payload: Transport.Packet.Payload)

        /// [symbol] 0x2ad5173ec
        func sendNotification(_ notification: RemoteNotification)

        /// `OutboundSessionProtocol` witness at 0x2ad51b1d8. [symbol] 0x2ad517b00
        func sendInvocation<Res: Codable>(
            to id: ActorID,
            target: Distributed.RemoteCallTarget,
            invocation: inout InvocationEncoder
        ) async throws(RemoteInvocationCancellationError) -> Res

        /// `private`. Note this is an **instance** method that takes a *second* session in
        /// `on:` — the demangled symbol carries no `static`. Reading `on:` as the peer session
        /// of a `.local` pair (cf. `LocalSessionState.peerSession`, `optimizeSelfIPC`) is
        /// [inference]; the signature itself is [symbol] 0x2ad519c04.
        /// One of the two callers of `resolveSharedActor`.
        /// Failure strings (`Session+Outbound.swift`): `"Direct invocation threw error: "`,
        /// `"Local session was cancelled before executing direct invocation."`,
        /// `"Local peer session no longer available"`.
        private func executeDirectInvocation<Res: Codable>(
            on peer: Session,
            targetKey: SharedActorKey,
            target: Distributed.RemoteCallTarget,
            invocation: inout InvocationEncoder
        ) async throws(RemoteInvocationCancellationError) -> Res

        // -----------------------------------------------------------------------------------
        // Hashable / Equatable. [symbol]
        // -----------------------------------------------------------------------------------
        func hash(into hasher: inout Hasher)                        // 0x2ad50b118
        var hashValue: Int { get }                                  // 0x2ad50b158
        static func == (lhs: Session, rhs: Session) -> Bool         // 0x2ad50b144


        // ===================================================================================
        // MARK: Session.InitializationOptions
        // ===================================================================================

        /// **The members are now resolved.** The interop document records
        /// "`InitializationOptions` is `{ rawValue }`, an OptionSet. Its members were not
        /// resolved." There are exactly two, and their raw values are 2 and 4.
        ///
        /// Conformances, each from its own conformance descriptor: `OptionSet`, `SetAlgebra`,
        /// `RawRepresentable`, `ExpressibleByArrayLiteral`, `Equatable` — all the default
        /// `OptionSet` witnesses are present, so this is a plain `struct: OptionSet`. [symbol]
        ///
        /// `rawValue` is `UInt64`, from `rawValue.getter : Swift.UInt64` and
        /// `init(rawValue: Swift.UInt64)`. [symbol]
        ///
        /// **Bit 0 (raw value 1) is unaccounted for.** That is not a gap in the search: any
        /// `static let` or `static var` member — including a `private` one, which would carry
        /// a discriminator — emits an addressor or getter symbol, and the symbol table
        /// contains exactly two (`bidirectional` at 0x2ad506fac / 0x2ad507340,
        /// `inactive` at 0x2ad506fb8 / 0x2ad507348) plus `rawValue` and `init(rawValue:)`.
        /// So in *this build* there is no member at bit 0. Whether Apple's source skips it or
        /// once had a member there is not answerable from this image.
        struct InitializationOptions: OptionSet {

            let rawValue: UInt64                                        // [fieldmd] [symbol]

            /// **Raw value 2** (bit 1). Two independent reads agree: the static's storage at
            /// 0x2ad523140 holds `0x2`, and its getter is `mov w0, #2; ret`.
            /// This bit is what both initialisers `ubfx` into `isBidirectional`.
            /// [disasm @0x2ad507340] + live read of 0x2ad523140
            static let bidirectional: InitializationOptions             // = InitializationOptions(rawValue: 2)

            /// **Raw value 4** (bit 2). Storage at 0x2ad523148 holds `0x4`; getter is
            /// `mov w0, #4; ret`. `init(actorSystem:transport:options:)` tests it with
            /// `tbnz wOptions, #2` and, when set, *skips* flipping `activationFuse` and
            /// activating the transport — so `.inactive` means "construct but do not
            /// activate". [disasm @0x2ad507348, @0x2ad5075b0 +0x2b8] + live read of 0x2ad523148
            static let inactive: InitializationOptions                  // = InitializationOptions(rawValue: 4)
        }


        // ===================================================================================
        // MARK: Session.Kind
        // ===================================================================================

        /// **The case-to-payload assignment is now resolved.** The interop document marked it
        /// as inference ("the two initialisers and the two payload types are facts; the
        /// case-to-payload assignment was not read out of `Kind`'s field descriptor payload
        /// records"). It has now been read out of exactly those records, and the inference was
        /// right.
        ///
        /// `Kind`'s field descriptor (0x2ad52abf0, kind `mp-enum`, 2 records) carries a
        /// **direct** symbolic type reference (control byte 0x01) per case:
        ///   record 0 `xpc`   -> relative offset -5531  -> 0x2ad526ce0
        ///                       = `nominal type descriptor for XPCSystem.Transport`
        ///   record 1 `local` -> -> 0x2ad52698c
        ///                       = `nominal type descriptor for Session.LocalSessionState`
        /// [fieldmd]
        ///
        /// Corroborated independently at the two store sites, which also give the physical
        /// representation: `Kind` is 8 bytes and the tag lives in the pointer's **high bit**.
        ///   `.xpc`   : `stur x1, [self+0x28]`                          — plain pointer
        ///   `.local` : `orr x8, x1, #0x8000000000000000; stur x8, ...` — pointer | bit 63
        /// [disasm @0x2ad5075b0 +0x54, @0x2ad50c09c +0x44]
        ///
        /// Every `Kind` consumer in `Session` is a `tbnz/tbz #63` or an `lsr #63` on that
        /// word — `transport`, `local`, `isCancelled`, `optimizeSelfIPC`, `updatePeerSession`,
        /// `activateTransport`, `RemoteInterface.auditToken`,
        /// `RemoteInterface.setBackpressurePolicy`, `debugDescription`.
        ///
        /// Field-descriptor record order is `xpc` then `local`, so as declared `xpc` is case 0.
        enum Kind {
            case xpc(Transport)
            case local(LocalSessionState)
        }


        // ===================================================================================
        // MARK: Session.LocalSessionState
        // ===================================================================================

        /// A **class** (field descriptor kind 1; `__allocating_init` and
        /// `__deallocating_deinit` symbols exist). The `.local` payload of `Kind`.
        /// [fieldmd] [symbol]
        /// Live field offsets, read from the `direct field offset` variables at
        /// 0x2ad520318 / 0x2ad520320 / 0x2ad520328: `label` +0x10, `peerSession` +0x20,
        /// `cancellationFuse` +0x28. [offset]
        class LocalSessionState {

            let label: String                                       // +0x10 [offset] [fieldmd]

            /// `var`, and **weak**: the field record's flags have bit 0x2 (IsVar) set and its
            /// mangled type reference ends `SgXw` — `Optional<Session>` *weak*. The accessors
            /// corroborate: `updatePeerSession` and `LocalSessionState.cancel(because:)` reach
            /// it through `swift_weakLoadStrong` / `swift_weakAssign`, and
            /// `clientSession(to:)` builds it with `swift_weakInit`.
            /// [fieldmd] [offset] [disasm @0x2ad506e84, @0x2ad4bd784, @0x2ad4bd608]
            weak var peerSession: Session?                           // +0x20

            /// `private` — the demangled field offset symbol is
            /// `LocalSessionState.(cancellationFuse)`. One-shot: `cancel(because:)` flips it
            /// with a `caslb` and returns whether it won. Read by `Session.isCancelled` at
            /// +0x28. [offset] [fieldmd] [disasm @0x2ad4bd784 +0x28]
            private let cancellationFuse: Fuse                       // +0x28

            /// [symbol] 0x2ad4bd590 / allocating 0x2ad4bd504
            init(label: String, peerSession: Session?)

            /// Builds the label by appending the key's debug name to the Swift small string
            /// literal `"[local]"` (decoded from the `movz`/`movk` immediates at +0x40/+0x50 —
            /// it is 7 bytes, so it appears in no string table), then constructs a
            /// `LocalSessionState` with `swift_weakInit`.
            /// [symbol] [disasm @0x2ad4bd608]
            static func clientSession<K: ServiceRegistry.Key>(to key: K) -> Self

            /// The 8-byte symbol at 0x2ad4bd6d4 forwards to
            /// `function signature specialization <Arg[1] = Dead>` at 0x2ad4bd910 — the
            /// session argument is dead in the specialization, i.e. only its identity/label is
            /// used. [symbol] [disasm @0x2ad4bd6d4]
            static func serverSession(for session: Session) -> Self

            /// `task_info` on the current task. [symbol] [disasm @0x2ad4bd6d8]
            static func currentProcessAuditToken() -> audit_token_t?

            /// `caslb` on `cancellationFuse`, then `swift_weakLoadStrong` on `peerSession` and,
            /// if it is still alive, `Session.cancel(because:)` on it with an appended reason.
            /// Returns whether this call was the one that flipped the fuse.
            /// [symbol] [disasm @0x2ad4bd784]
            func cancel(because reason: String) -> Bool

            /// [symbol] 0x2ad4bd86c
            var isCancelled: Bool { get }
        }


        // ===================================================================================
        // MARK: Session.LocalInterface
        // ===================================================================================

        /// A one-field struct over the session — the "server side" handle you export actors on.
        /// [fieldmd] [symbol]
        struct LocalInterface {

            let session: Session                                    // [fieldmd]

            /// `__shared` in the demangled symbol, i.e. `borrowing`. [symbol] 0x2ad507a70
            init(session: borrowing Session)

            /// Both `export` overloads read `actor.id` through `Identifiable.id.getter`, trap
            /// if it is `.remote` (`"API violation: Remote proxy cannot be shared!"`,
            /// `Session.swift`), then mint a key and funnel into `addSharedActor`.
            /// [symbol] 0x2ad509790 — mints `.exported(SwiftType(B.self))`
            func export<A: DistributedActor, B: Distributed._DistributedActorStub>(
                _ actor: A, asDefaultActorFor stub: B.Type
            ) where A.ActorSystem == XPCSystem, B.ActorSystem == XPCSystem

            /// [symbol] 0x2ad509878 — mints `.exportedRawValue(name)`
            func export<A: DistributedActor>(
                _ actor: A, asServerActorFor name: String
            ) where A.ActorSystem == XPCSystem

            /// The three `activateThen*` entry points all return the `ActivationToken` beside
            /// their result, as a labelled tuple `(result:token:)`. That tuple shape is what
            /// `TransportReceiver.(peerHandler)` and
            /// `EphemeralService.Receiver.listen(forPeersSatisfying:executingForEachPeer:)`
            /// are typed against. [symbol]
            func activateThenWaitForCancellation() async -> (result: (), token: ActivationToken)   // 0x2ad509e54

            func activateThenWithRemoteInterface<A: Sendable>(                                     // 0x2ad50a1f4
                perform: (RemoteInterface) async -> A
            ) async -> (result: A, token: ActivationToken)

            /// Note the *typed* throws on the closure and the `Result` in the return — the
            /// error is captured, not rethrown. [symbol] 0x2ad50a884
            func activateThenWithRemoteInterface<A: Sendable, E: Error>(
                perform: (RemoteInterface) async throws(E) -> A
            ) async -> (result: Result<A, E>, token: ActivationToken)

            /// Appends the reason, calls `Session.cancel(because:)`, and still hands back a
            /// token — the receipt a peer-handling closure must return.
            /// [symbol] [disasm @0x2ad50af24]
            func cancelWithoutActivating(because reason: String) -> (result: (), token: ActivationToken)


            // -------------------------------------------------------------------------------
            // MARK: LocalInterface.ActivationToken
            // -------------------------------------------------------------------------------

            /// Conformances from their own descriptors: `Hashable` (+`Equatable`),
            /// `Encodable`, `Decodable`. [symbol]
            ///
            /// The interop document's finding stands: **`ActivationToken` does not cross the
            /// wire**, and the purpose of its `Codable` conformance is unresolved. Nothing
            /// below changes that; it is repeated here only so the declaration is not read as
            /// a wire type.
            ///
            /// The coding *is* keyed — that is now a direct read rather than a deduction from
            /// "it has CodingKeys": the image carries
            /// `mangled name ref for type metadata for Swift.KeyedEncodingContainer<ActivationToken.(CodingKeys)>`
            /// at 0x2ad5231a8 and the matching `KeyedDecodingContainer` at 0x2ad5231b0. [symbol]
            struct ActivationToken: Hashable, Codable {

                let id: ID64                                        // [fieldmd]

                /// `private` — the field descriptor spells the enclosing type
                /// `ActivationToken.<discriminator>.CodingKeys`, and a discriminator on a
                /// nested type means `private`. One case, `id`. [fieldmd]
                private enum CodingKeys: String, CodingKey {
                    case id
                }

                init(id: ID64)                                      // [symbol] 0x2ad509948
                init(from decoder: any Decoder) throws              // [symbol] 0x2ad509b90
                func encode(to encoder: any Encoder) throws         // [symbol] 0x2ad5099dc
                func hash(into hasher: inout Hasher)                // [symbol] 0x2ad509b1c
                var hashValue: Int { get }                          // [symbol] 0x2ad509b48
                static func == (lhs: ActivationToken, rhs: ActivationToken) -> Bool  // 0x2ad509950
            }


            // -------------------------------------------------------------------------------
            // MARK: LocalInterface.UncheckedHandoff
            // -------------------------------------------------------------------------------

            /// A one-shot, once-only transfer of a `Session` into a `LocalInterface`, used to
            /// hand a not-yet-`Sendable`-checked local interface across an isolation boundary.
            /// `XPCSystem.makeBidirectionalInterface(to:assumeLocalInterfaceActivatedIn:)`
            /// takes `(UncheckedHandoff) -> Task<ActivationToken, Never>`. [symbol]
            struct UncheckedHandoff {

                /// The box is `private`; `box` itself is not.
                /// [fieldmd] (type reference resolves to the `(Box)` nominal descriptor at
                /// 0x2ad527970)
                let box: Box

                /// `private` — demangled as `UncheckedHandoff.(Box)`. A class, with one
                /// stored property. [fieldmd] [offset]
                private class Box {
                    /// `Mutex<Session?>` from the `direct field offset` symbol at 0x2ad523738
                    /// and from the field descriptor's own type reference. [offset] [fieldmd]
                    let mutex: Mutex<Session?>
                }

                /// Allocates the `Box` and seats the session in its mutex.
                /// [symbol] [disasm @0x2ad50b024]
                init(_ session: Session)

                /// Locks the box (`os_unfair_lock_lock`), takes the session out, and on `nil`
                /// reaches `Swift._assertionFailure` — the message is
                /// `"API violation: Unchecked handoff can only be completed once."`
                /// (`Session.swift`). Returns `LocalInterface(session:)`.
                /// The lock/take/assert structure is [disasm @0x2ad50b068]; the message
                /// attribution is [inference] from the string table.
                func complete() -> LocalInterface
            }
        }


        // ===================================================================================
        // MARK: Session.RemoteInterface
        // ===================================================================================

        /// A one-field struct over the session — the "client side" handle you import actors
        /// from. It is also what `XPCSystem.currentRemoteInvocationOrigin()` (0x2ad5168f4)
        /// returns. [fieldmd] [symbol]
        struct RemoteInterface {

            let session: Session                                    // [fieldmd]

            init(session: Session)                                  // [symbol] 0x2ad507a68

            /// Branches on `kind` (`tbnz x21, #63`): for `.xpc` it projects the transport's
            /// `rawTransport` existential and asks it (`RawTransportProtocol.auditToken`);
            /// for `.local` it calls `task_info` for the current process's token. Optional
            /// because either can fail. Failure string, `Session.swift`:
            /// `"Bug in XPCDistributed: Expected valid audit token if the transport returns one"`.
            /// [symbol] [disasm @0x2ad5093fc]; string attribution [inference]
            var auditToken: audit_token_t? { get }

            /// `nil` when `auditToken` is nil, otherwise
            /// `XPC.audit_token_t.satisfies(requirement:)`. The double optionality is the
            /// point: "unknown" is distinct from "no". [symbol] [disasm @0x2ad50b298]
            func satisfies(requirement: XPC.XPCPeerRequirement) -> Bool?

            /// `tbnz kind, #63` -> for a `.local` session this is a **no-op**; for `.xpc` it
            /// forwards to `Transport.setBackpressurePolicy`. Backpressure is a transport
            /// concern and an in-process session has none.
            /// [symbol] [disasm @0x2ad509524]
            func setBackpressurePolicy(_ policy: BackpressurePolicy)

            /// Both `import` overloads build a `SharedActorKey`, wrap it in
            /// `RawActorID.Remote(session: <self.session as any OutboundSessionProtocol>, key:)`,
            /// and hand the resulting `ActorID` to
            /// `Distributed.DistributedActor.resolve(id:using:)`.
            ///
            /// Caution, and it is the trap the interop document names: both call sites are
            /// preceded by a call annotated `merged lazy protocol witness table accessor for
            /// type Session and conformance Session : InboundSessionProtocol`. That name is not
            /// evidence — merged accessors name only one of the folded types and the real
            /// conformance is in the caller's constants. Since `Remote.session` is typed
            /// `OutboundSessionProtocol`, the conformance actually loaded must be the outbound
            /// one; the conformance descriptor operand was **not** resolved, so read this as
            /// [inference] from the field type.
            /// [symbol] 0x2ad50957c — key is `.exported(SwiftType(A.self))`
            func `import`<A: Distributed._DistributedActorStub>(defaultActorFor stub: A.Type) -> A
                where A.ActorSystem == XPCSystem

            /// [symbol] 0x2ad509684 — key is `.exportedRawValue(name)`
            func `import`<A: DistributedActor>(clientActorFor name: String) -> A
                where A.ActorSystem == XPCSystem
        }


        // ===================================================================================
        // MARK: Session.ServiceConnectArguments
        // ===================================================================================

        /// The argument bundle of `XPCSystem.ConnectableService.connect(from:with:)`
        /// (dispatch thunk present; `Service` and `EphemeralService` both implement it,
        /// `async throws(SetupError) -> Session`). Two stored properties, both `let`.
        /// [fieldmd] [symbol]
        struct ServiceConnectArguments {

            /// `default argument 1 of ...init(peerRequirement:options:)` at 0x2ad4bd8ec is
            /// `mov x0, #0; ret` — so the default is `nil`. [disasm]
            let peerRequirement: XPC.XPCPeerRequirement?

            /// No `default argument 2` symbol exists for this initialiser, so `options` has
            /// **no** default here — unlike `Session.init`, where it defaults to `[]`.
            /// [symbol] (absence of the symbol)
            let options: InitializationOptions

            init(peerRequirement: XPC.XPCPeerRequirement? = nil,
                 options: InitializationOptions)                    // [symbol] 0x2ad506f6c
        }


        // ===================================================================================
        // MARK: Session.RemoteInvocationReplyEncoder
        // ===================================================================================

        /// `private` — the demangled symbols spell it `Session.(RemoteInvocationReplyEncoder)`.
        /// A struct with one stored property. It carries the sole requirement of
        /// `XPCSystem.EncodedResultHandler.ReplyHandler` (protocol requirements base
        /// 0x2ad52776c, one method descriptor at 0x2ad527774 -> slot +0x08); the conformance
        /// descriptor is at 0x2ad5245f0 and the witness at 0x2ad5129e8. [symbol] [fieldmd]
        ///
        /// `EncodedResultHandler` stores one of these as `replyHandler`, existentially:
        /// `direct field offset for EncodedResultHandler.replyHandler :
        ///  EncodedResultHandler.ReplyHandler`. [symbol]
        private struct RemoteInvocationReplyEncoder: EncodedResultHandler.ReplyHandler {

            /// **Resolved this round.** The field descriptor's type reference for `userInfo`
            /// is the mangled blob `SD y <symbolic 0x02> yp G`, i.e.
            /// `Swift.Dictionary<X, Any>`; dereferencing the indirect symbolic slot gives a
            /// pointer into `libswiftCore.dylib` whose `dladdr` name is
            /// `$ss17CodingUserInfoKeyVMn` — the nominal type descriptor for
            /// `Swift.CodingUserInfoKey`. So `X == CodingUserInfoKey`.
            /// [fieldmd] (blob at unslid 0x2ad5293d6; slot at 0x2d7d9eee8)
            ///
            /// This is the same two-entry `userInfo` dictionary
            /// `Session.handleReceivedRequest` builds — the
            /// `CodingUserInfoKey("com.apple.xpc.distributed/Session")` and
            /// `Distributed.CodingUserInfoKey.actorSystemKey` pair — carried forward so the
            /// reply can be encoded with the same session in scope. That identification is
            /// [inference], from the type and from `encodeReturn` passing it to
            /// `XPCDictionary.encode(_:forKey:withUserInfo:)`.
            let userInfo: [CodingUserInfoKey: Any]

            /// The `ReplyHandler` witness. Success arm calls `encodeReturn(value:)`; failure
            /// arm builds a `RemoteInvocationResponse<Never>`. Body partly mapped in the
            /// interop document's *Response* section. [symbol] 0x2ad512738
            func encodeReply<A: Codable, B: Error>(with result: Result<A, B>) -> Transport.Packet.Payload

            /// Not a protocol requirement — a private helper, and the **only** caller of
            /// `RemoteInvocationResponse.init(result:)` in the whole image. Body partly mapped
            /// in the interop document. [symbol] 0x2ad512298
            func encodeReturn<A: Codable>(value: A) -> Transport.Packet.Payload
        }
    }
}


// ===========================================================================================
// Neighbouring declarations this subsystem's signatures reference. Listed for the reader's
// benefit only — they belong to other agents' subsystems and are reproduced verbatim from
// their symbols, not reconstructed.  [symbol]
// ===========================================================================================
//
//   XPCDistributed.Fuse                       { value }
//   XPCDistributed.UnownedAwaitableEvent<A>   { future, promise }         — 3 words
//   XPCDistributed.OwnedAwaitableEvent<A>     { unownedAwaitableEvent, owningTask, posted }
//   XPCDistributed.ID64                       { value }, ID64.Generator { atomic }
//   XPCDistributed.Internal.Identifiable      { associatedtype ID: Hashable; var id: ID { get } }
//
//   direct field offset for Transport.(inboundSession) : InboundSessionProtocol?
//       — private, and assigned **weakly** by Session.init(actorSystem:transport:options:)
//         (`swift_unknownObjectWeakAssign` into transport+0x10, witness table at +0x18).
//
//   direct field offset for TransportReceiver.(peerHandler) :
//       @Sendable (__owned Session.LocalInterface) async -> (result: (), token: Session.LocalInterface.ActivationToken)
//
//   static XPCSystem.currentSession : Session?            (a Swift.TaskLocal<Session?>)
//   static XPCSystem.currentRemoteInvocationOrigin() -> Session.RemoteInterface?   0x2ad5168f4
//   (extension in XPCDistributed) Swift.CodingUserInfoKey.sessionKey : CodingUserInfoKey
//       — the "com.apple.xpc.distributed/Session" key, as an extension member
//   ServiceRegistry.lookUpAndConnect<K: ServiceRegistry.Key>(to:from:options: Session.InitializationOptions) -> Session?
//   XPCSystem.{Service,EphemeralService}.connect(from:with: Session.ServiceConnectArguments)
//       async throws(SetupError) -> Session
//   XPCSystem.makeBidirectionalInterface(to: InProcessService,
//       assumeLocalInterfaceActivatedIn: (Session.LocalInterface.UncheckedHandoff) -> Task<...ActivationToken, Never>)
//       async throws(SetupError) -> Session.RemoteInterface
//   XPCSystem.{makeRemoteInterface,withRemoteInterface,withBidirectionalInterface}(...)
//   (extension in XPCDistributed) Distributed.DistributedActor.session : OutboundSessionProtocol?


// ===========================================================================================
// LEFT UNRESOLVED
// ===========================================================================================
//
// 1. `InitializationOptions` bit 0 (raw value 1). Both existing members are at bits 1 and 2.
//    The symbol-table argument above establishes that no *member* occupies bit 0 in this
//    build; it does not explain why. Next step, if it ever matters: scan every call site that
//    constructs a `Session` or a `ServiceConnectArguments` for the immediate loaded into the
//    options register and see whether any odd value is ever passed. My callers-of scan found
//    **zero** direct callers of either `__allocating_init` and zero of either dispatch thunk,
//    so the constructions are all vtable-indirect (`blraa`) or inlined — a direct-branch scan
//    cannot answer it and a register-tracking pass over the `blraa` sites would be needed.
//
// 2. Which lock `Session.cancellationCompleted()` (0x2ad508e64) takes, and what it drains.
//    It calls `os_unfair_lock_lock`/`unlock` and `swift_bridgeObjectRelease`. The only
//    `os_unfair_lock` in `Session` is `sharedActors`' Mutex word at +0x30, which does not
//    obviously belong here. Next step: read the base register of the `os_unfair_lock_lock`
//    argument against the field-offset table.
//
// 3. Whether `Session.local` is declared as a getter or with `_read`. Both a `local.getter`
//    (0x2ad506fc4) and a `local.read` coroutine (0x2ad507a78) exist; which the source spells
//    is not recoverable from that alone.
//
// 4. `Session`'s `final`-ness and its `Sendable` conformance. `Sendable` is a marker protocol
//    and emits no descriptor anywhere in this image, so no symbol can answer it. `final`
//    likewise: only the two initialisers have method descriptors, which shows nothing else is
//    overridable but does not settle the keyword.
//
// 5. Access levels above `private`. `T` vs `t` linkage separates "exported" from "internal",
//    and a parenthesised name marks `private`, but `public` / `package` / `internal` /
//    `@usableFromInline` cannot be distinguished. Nothing above claims one.
//
// 6. `Session.debugDescription`'s format string, and the exact literals passed to
//    `cancel(because:)` from `deinit`, to `_assertionFailure` from `readyToReceive(_:)`, and
//    to `_assertionFailure` from `UncheckedHandoff.complete()`. In each case the matching
//    string exists in `__cstring` and the attribution is marked `[inference]` above; decoding
//    the actual `adrp`/`add` operand at each site would close them.
//
// 7. `executeDirectInvocation`'s `on:` parameter semantics (peer session vs. self). Signature
//    resolved; the reading is inference.
//
// 8. Which protocol existential `RemoteInterface.import` loads its witness table for. See the
//    note on the merged-accessor trap at that declaration — the conformance descriptor operand
//    was not resolved. This is the same open question the interop document already records for
//    `ActorID`'s two coding methods.
//
// ===========================================================================================
// NOTHING HERE CONTRADICTS
// docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md.
// Three of the things it lists as open are now closed, and in each case its stated inference
// turned out to be correct: `Session.Kind`'s case-to-payload assignment, the members of
// `InitializationOptions`, and where `isBidirectional` is written. One thing it lists as a
// fact — that `isBidirectional` is a "plain stored `Bool`" — is refined rather than corrected:
// it is a stored `let`, immutable after init.
// ===========================================================================================
