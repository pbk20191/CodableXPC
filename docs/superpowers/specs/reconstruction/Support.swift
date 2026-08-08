// XPCDistributed — interface reconstruction: the top-level support types.
//
// Covers, in this order:
//
//   Ack (+ CodingKeys)                       Either (+ private Case)
//   ID64, ID64.Generator                     SwiftType, SwiftTypeCache (+ State)
//   RequestManager (+ Request, Request.State)
//   BackpressureManager (+ Decision, PendingRequest, PriorityBucket, SendToken)
//   XPCSystem.BackpressurePolicy             Fuse
//   Environment                              OwnedAwaitableEvent / UnownedAwaitableEvent
//   TestHook                                 Internal
//   ActorBackedByDispatchSerialQueue          (top-level, unassigned, load-bearing here)
//
// These are Apple's declarations, not ours. Spellings — including `N`, `UI`/`IN`/`DEF`/`UT`/`BG`,
// `BUCKET_COUNT`, and the leading underscores on `_setReplyHandler`/`_cancel` — are kept verbatim.
//
// HOW EVIDENCE IS CITED
//   [sym]        read out of `symbols-demangled.txt`; a demangled Swift symbol carries its
//                full signature, so parameter labels/types/`throws`/`async` come from there.
//   [fieldmd]    `field-descriptors.txt` (stored-property / enum-case *names* and nesting only).
//   [fieldrec]   the **declared type** of a stored property, and the **payload type** of an enum
//                case, read out of the same reflection records that `field-descriptors.txt` is
//                built from. `extract.py` only ever read `FieldRecord+8` (the name); the record is
//                `uint32 Flags; RelPtr MangledTypeName (+4); RelPtr FieldName (+8)`, so the type
//                is at `+4`. Flag bit `0x2` is `IsVar`, which distinguishes `let` from `var`.
//                Reader: `support-fieldtypes.py` in this round's scratch directory. Thanks to the
//                Session agent for the record layout — it converted eight of the inferences in an
//                earlier draft of this file into resolved facts, and it independently reproduced
//                the `Request.State` payloads I had derived from disassembly.
//   [dis @addr]  disassembled from the live shared-cache image with `dump-function.py`;
//                addresses are unslid.
//   [vwt]        value-witness-table size/stride/flags read out of the loaded image
//                (this is where `size`, `~Copyable`, and "N cases, no payload" come from).
//   [gsig]       generic requirements read out of the nominal type descriptor's generic
//                context in the loaded image. Control: BackpressureManager came out
//                `A: Hashable`, matching the `where A: Swift.Hashable` printed in its
//                `enum case for …PriorityBucket.*` symbols. NOTE: `Sendable` is a marker
//                protocol and is NOT present in that list, so its absence proves nothing.
//   [cstr]       `cstrings.txt`, attributed to a function by disassembling the site and
//                matching the `String` length register against the literal's length.
//   [inference]  said so, and from what.
//
// A private declaration is written `private`. Two independent tells: the demangler prints a
// private name in parentheses (`BackpressureManager.(Decision)`, `XPCDistributed.(SwiftTypeCache)`),
// and `field-descriptors.txt` shows a mangled discriminator in the dotted name.
//
// Apple's files for this subsystem, from assertion strings [cstr]:
//   XPCDistributed/Backpressure.swift
//   XPCDistributed/Utilities/RequestManager.swift
//   XPCDistributed/Utilities/Precondition.swift
// `Ack`, `Either`, `ID64`, `SwiftType`, `Fuse`, `Environment`, the awaitable events, `TestHook`
// and `Internal` have no file named in any assertion string reachable from them, so their file
// placement is unresolved.

// ============================================================================================
// MARK: - Ack
// ============================================================================================

/// Already resolved in `2026-08-08-xpcdistributed-interop-wire-format.md`: field-less, with a
/// synthesized `Codable` whose encode side opens an empty keyed container and whose decode side
/// opens no container at all. Not re-derived; cross-checked only.
///
/// [vwt] size 0. [sym] the three methods below and both conformance descriptors.
/// [dis 0x2ad4ebcdc] `init(from:)` is 40 bytes: it destroys the boxed `Decoder` existential and
/// returns. No `container(keyedBy:)`, no `singleValueContainer()`, no call of any kind besides
/// `__swift_destroy_boxed_opaque_existential_1Tm`. That is the whole function.
struct Ack: Codable {
    init()
    init(from decoder: any Decoder) throws
    func encode(to encoder: any Encoder) throws

    /// PRIVATE, and it has **zero cases** — which is exactly what Swift synthesizes for a
    /// field-less struct, and what makes `Ack` encode as `{}`.
    ///
    /// [fieldmd] listed as `enum XPCDistributed.Ack..CodingKeys` with no case records. The
    /// doubled dot is an empty private-discriminator string, not a transcription slip.
    /// [sym] `anonymous descriptor XPCDistributed.Ack.(CodingKeys)` plus conformance descriptors
    /// for `CodingKey`, `CustomStringConvertible`, `CustomDebugStringConvertible` — the last two
    /// are inherited by `CodingKey`, not extra.
    private enum CodingKeys: CodingKey {}
}

// ============================================================================================
// MARK: - Either
// ============================================================================================

/// [fieldmd] `enum XPCDistributed.Either { a, b }`. [gsig] two generic parameters, **zero**
/// generic requirements on the type itself — every constraint lives on an extension.
/// [fieldrec] the two case payloads are `x` and `q_` — the first and second generic parameters,
/// bare. So `a(A)` / `b(B)` with unlabelled single payloads, resolved rather than assumed from the
/// name.
///
/// Wire shape already resolved in the wire-format spec (`[<Case: UInt8>, payload]`, `a` = 0,
/// `b` = 1, unkeyed container, `encode(to:)` at 0x2ad4ed7c4 / `init(from:)` at 0x2ad4ed9e4).
/// Not re-derived.
enum Either<A, B> {
    case a(A)
    case b(B)

    /// [sym] all four, with these exact generic shapes. `mapA`/`mapB` are unconstrained;
    /// the `flatMap*` pair returns an Optional, i.e. it is Optional-flattening, not error-mapping.
    func mapA<T>(_ transform: (A) -> T) -> Either<T, B>
    func mapB<T>(_ transform: (B) -> T) -> Either<A, T>
    func flatMapA<T>(_ transform: (A) -> T?) -> Either<T, B>?
    func flatMapB<T>(_ transform: (B) -> T?) -> Either<A, T>?
}

/// [sym] `protocol conformance descriptor for < where A: Equatable, B: Equatable> Either<A, B> :
/// Equatable`, and likewise `Hashable`. Both are conditional.
extension Either: Equatable where A: Equatable, B: Equatable {
    static func == (lhs: Either<A, B>, rhs: Either<A, B>) -> Bool
}
extension Either: Hashable where A: Hashable, B: Hashable {
    func hash(into hasher: inout Hasher)
    var hashValue: Int { get }
}

/// [sym] `(extension in XPCDistributed):Either< where B: Swift.Error>.…` — a distinct extension
/// whose only constraint is `B: Error`. This is the `Result` bridge, and it is what makes
/// `Either<Success, RemoteInvocationFailure>` the response type it is.
///
/// Note `getA()` is `throws(B)` — typed throws — and that this overload of `flatMapA` takes a
/// `throws(B)` transform but is **not itself** declared `throws` in the demangled signature, so
/// it must turn a thrown `B` into `.b`. That last step is [inference] from the signature; the
/// body was not disassembled.
extension Either where B: Error {
    init(_ result: Result<A, B>)
    func getA() throws(B) -> A
    func flatMapA<T>(_ transform: (A) throws(B) -> T) -> Either<T, B>
}

/// [sym] `protocol conformance descriptor for < where A: Decodable, A: Encodable, B: Decodable,
/// B: Encodable> Either<A, B> : Encodable` / `: Decodable`. The conformance is written on an
/// extension constrained to `A: Codable, B: Codable`, and `Case` is declared **inside that
/// extension** — its symbol is
/// `(extension in XPCDistributed):XPCDistributed.Either< where A: Decodable, … >.(Case)`.
extension Either: Codable where A: Codable, B: Codable {
    func encode(to encoder: any Encoder) throws
    init(from decoder: any Decoder) throws

    /// PRIVATE. `a` = 0, `b` = 1 (declaration order, no explicit raw values found).
    ///
    /// [sym] `(Case).init(rawValue: Swift.UInt8)` and `(Case).rawValue.getter : Swift.UInt8` fix
    /// the raw type; `anonymous descriptor …(Case)` fixes `private`. It additionally conforms to
    /// `Encodable`/`Decodable` (via `RawRepresentable`'s conditional conformance, which is
    /// single-value) and to `Hashable`/`Equatable`.
    ///
    /// CORRECTION to the brief's framing: the garbage in the `field-descriptors.txt` parent name
    /// (`enum XPCDistributed.<mangled>yxq_G.Case`) is the *extension* context descriptor being
    /// walked as if it were a nominal one — `yxq_G` is the mangling of `Either<A, B>` — it is not
    /// a private discriminator. `Case` is private, but that is established by the symbol form,
    /// not by that string.
    private enum Case: UInt8, Codable, Hashable {
        case a
        case b
    }
}

// ============================================================================================
// MARK: - ID64
// ============================================================================================

/// [fieldmd] one stored field, `value`. [sym] `ID64.value.getter : Swift.UInt64`, and there is no
/// `value.setter` symbol anywhere in the image.
///
/// [fieldrec] `value` is `Swift.UInt64` with `IsVar` clear — a `let`, resolved, not read off the
/// getter's return type.
///
/// Single-value `Codable` (bare `UInt64` on the wire) is already resolved in the wire-format spec
/// — `encode(to:)` at 0x2ad4ef3ac, `init(from:)` at 0x2ad4ef440. Not re-derived.
struct ID64: Hashable, Codable, CustomDebugStringConvertible {
    let value: UInt64

    /// **`ID64()` mints a fresh process-global id.** It is not a zero-value initializer.
    ///
    /// [dis 0x2ad4ef1e0] 116 bytes, and the whole body is: `swift_once`-guard the private static
    /// `default` generator, then an inlined `Generator.next()` — `ldr x9, [global]`,
    /// `adds x0, x9, #1`, `b.hs` to a `brk` on unsigned overflow, `cas` retry loop on the same
    /// global word. The global is at 0x2d70d7450 and the once-token at 0x2d70d7a90.
    ///
    /// This is the generator the wire-format spec attributes to `XPCSystem.assignID` ("a `cas`
    /// loop on a process-global `ID64.Generator` behind a `swift_once`"). It now has a name.
    init()

    init(from decoder: any Decoder) throws
    func encode(to encoder: any Encoder) throws
    var debugDescription: String { get }
    func hash(into hasher: inout Hasher)
    static func == (lhs: ID64, rhs: ID64) -> Bool

    /// PRIVATE. [sym] `static XPCDistributed.ID64.(default) : XPCDistributed.ID64.Generator`.
    private static let `default`: ID64.Generator

    /// `~Copyable`, because it stores a `Synchronization.Atomic`.
    ///
    /// [fieldrec] **`atomic` is `Synchronization.Atomic<UInt64>`, resolved** — the mangled record
    /// is `{Synchronization.Atomic}y{Swift.UInt64}G` — and `IsVar` is clear, so it is a `let`
    /// (which is correct for `Atomic`: you declare `let` and mutate through a borrow). An earlier
    /// draft had both the type and the `var` as inferences.
    ///
    /// [dis 0x2ad4ef254] `Generator.init()` is two instructions: `str xzr, [x8]; ret` — one
    /// 8-byte word, zeroed. [dis 0x2ad4ef334] `next()` is 40 bytes: load, `adds #1`, `b.hs` →
    /// `brk`, `cas` retry. Starts at 0 and returns the *incremented* value, so **ids are monotonic
    /// from 1** and overflow traps rather than wrapping.
    ///
    /// `~Copyable` is [inference] from `Atomic` being non-copyable, corroborated by
    /// `Session.idGenerator` being exposed as a `read` *coroutine* accessor
    /// (`Session.idGenerator.read : ID64.Generator` [sym]) rather than a `getter` — which is what
    /// Swift emits for a property that must be borrowed in place.
    ///
    /// **There is more than one instantiation, and they are reached by inlining, not by call.**
    ///  - a process-global one behind a `swift_once`: token at 0x2d70d7a90, counter word at
    ///    0x2d70d7450. That is `ID64.(default)` above, reached by `ID64.init()`
    ///    [dis 0x2ad4ef1e0], and — per the Session agent — it is also what mints `Session.id` and
    ///    what the wire-format spec sees behind `XPCSystem.assignID`'s `instanceID`.
    ///  - a per-object one: `Session.idGenerator` at `Session+0x20`, the `dynamic`
    ///    `SharedActorKey` counter [sym, field offset symbol; wire-format spec, *SharedActorKey*].
    ///  - `Transport.(idGenerator)` at `Transport+0x70` exists as a field [sym] but the
    ///    wire-format spec now argues it is **dead in this build**, on evidence I did not gather
    ///    and am not restating.
    ///
    /// Every use is the same 5-instruction `cas` sequence, inlined.
    ///
    /// CAUTION, and this corrects an earlier draft of this file: I supported that with "[sym]
    /// `Generator.next()` has no `BL` callers anywhere in the image," citing the wire-format spec.
    /// **The spec has since retracted that sentence** as an unearned strengthening, and it is
    /// right to: a direct `BL`/`B` scan cannot see `blraa`, so zero direct callers establishes only
    /// that `next()` is always inlined — which is the same `blraa`-blindness that note above
    /// records for callers-of scans generally. Kept here as the claim it can actually carry.
    ///
    /// The practical consequence for a reimplementation is unchanged: the symbol table will not
    /// tell you where ids come from. The field offsets and the `swift_once` token do.
    struct Generator: ~Copyable {
        let atomic: Synchronization.Atomic<UInt64>
        init()
        func next() -> ID64
    }
}

/// [sym] `(extension in XPCDistributed):XPC.XPCDictionary.subscript(Swift.String) -> ID64?` with
/// getter, setter and `modify`. This is the accessor `Packet.Header` uses for `"headerID"`; it is
/// XPCDistributed's own extension on the overlay type, not part of `libswiftXPC`.
extension XPC.XPCDictionary {
    subscript(key: String) -> ID64? { get set }
}

// ============================================================================================
// MARK: - SwiftType / SwiftTypeCache
// ============================================================================================

/// [fieldmd] `{ mangledTypeName, type }`. [vwt] size 24 = `String` (16) + `Any.Type` (8).
/// Single-value `Codable` (bare `String`) is already resolved in the wire-format spec
/// (`encode(to:)` 0x2ad4f5940, `init(from:)` 0x2ad4f59dc, `verify-containers.py`). Not re-derived.
///
/// `mangledTypeName` has **no** accessor symbol and no property descriptor anywhere in the image,
/// while `type` has both (`SwiftType.type.getter : Any.Type`) — so absence of an accessor says
/// nothing about a field's existence or type.
///
/// [fieldrec] both fields resolved: `mangledTypeName` is `SS` = `Swift.String`, `type` is `ypXp` =
/// `Any.Type` (an existential metatype), and **both have `IsVar` clear, so both are `let`**. Note
/// `type` is a *stored* `let`, not a computed property — an earlier draft of this file wrote it as
/// `var type: Any.Type { get }`, which was wrong in both respects; the `type.getter` symbol is
/// just the accessor Swift emits for a stored property.
struct SwiftType: Hashable, Codable, CustomDebugStringConvertible {
    let mangledTypeName: String
    let type: Any.Type

    /// [sym] `SwiftType.init<A>(A.Type) -> SwiftType` — generic over the type, not over a name.
    /// This is what `recordGenericSubstitution` and `LocalInterface.export(_:asDefaultActorFor:)`
    /// call.
    init<T>(_ type: T.Type)

    init(from decoder: any Decoder) throws
    func encode(to encoder: any Encoder) throws
    var debugDescription: String { get }
    func hash(into hasher: inout Hasher)
    static func == (lhs: SwiftType, rhs: SwiftType) -> Bool

    /// PRIVATE static, and the cache type is itself private.
    /// [sym] `static XPCDistributed.SwiftType.(cache) : XPCDistributed.(SwiftTypeCache)`.
    private static let cache: SwiftTypeCache
}

/// **`SwiftTypeCache` is `private` at file scope** — the wire-format spec calls it
/// `SwiftTypeCache` without qualification, which is right about the name and silent about this.
/// [sym] every symbol spells it `XPCDistributed.(SwiftTypeCache)`; there is an
/// `anonymous descriptor` for it. `field-descriptors.txt` shows the bare name only because the
/// extractor resolves context descriptors without discriminators.
private final class SwiftTypeCache {
    /// [sym] `direct field offset for XPCDistributed.(SwiftTypeCache).cache :
    /// Synchronization.Mutex<XPCDistributed.(SwiftTypeCache).State>` — the field's full type,
    /// read straight off the offset symbol. Same `Mutex` pattern as `XPCSystem.actorTable`
    /// and `Session.sharedActors`.
    let cache: Synchronization.Mutex<State>

    /// [dis 0x2ad4f5684] `type(for:)` takes `os_unfair_lock_lock` (the `Mutex`), then
    /// `__RawDictionaryStorage.find<Swift.String>`, then unlocks. So `nameToType` is keyed by
    /// `String`.
    func type(for name: String) -> Any.Type?

    /// [dis 0x2ad4f56f4] `mangledName(for:)` takes the lock and does
    /// `__RawDictionaryStorage.find<Swift.ObjectIdentifier>`. So `typeToName` is keyed by
    /// `ObjectIdentifier`, not by a string and not by `Any.Type` (which is not `Hashable`).
    func mangledName<T>(for type: T.Type) -> String?

    /// Already resolved in the wire-format spec as `{ nameToType, typeToName }`.
    /// [vwt] size 16 = two `Dictionary`s, one word each.
    /// [fieldrec] **both types resolved**, and they agree with the two `find<…>` specialisations
    /// above: `nameToType` is `SDySSypXpG` = `[String : Any.Type]`, `typeToName` is `SDySOSSG` =
    /// `[ObjectIdentifier : String]` (`SO` is `Swift.ObjectIdentifier`). Both carry `IsVar`.
    /// Worth stating plainly because `Any.Type` is not `Hashable`, so the reverse map *had* to be
    /// keyed by something else, and `ObjectIdentifier` is the answer rather than a mangled name.
    struct State {
        var nameToType: [String: Any.Type]
        var typeToName: [ObjectIdentifier: String]
    }

    // UNRESOLVED: no `SwiftTypeCache.init` symbol exists. Either the implicit `init()` was
    // inlined into the initializer of `SwiftType.(cache)` and stripped, or there is an explicit
    // one that was. Next step: dump the `one-time initialization function for cache` next to
    // `static SwiftType.(cache)` and read what it allocates.
    //
    // UNRESOLVED: whether either accessor *writes* the other direction's map. The wire-format
    // spec warns that a name->type cache must not be populated from the mangling direction; I
    // dumped both accessors for their `find<…>` witness only and did not enumerate their stores.
    // Next step: dump both at full length and look for `Dictionary.subscript.setter`.
}

// ============================================================================================
// MARK: - RequestManager
// ============================================================================================

/// An **actor** with a `DispatchSerialQueue` executor. `field-descriptors.txt` says `class`
/// because reflection has no separate kind for actors.
///
/// [sym] `protocol conformance descriptor for RequestManager<A, B> : Swift.Actor` and
/// `: XPCDistributed.ActorBackedByDispatchSerialQueue`; `protocol witness for
/// Swift.Actor.unownedExecutor.getter` exists for it.
///
/// [gsig] the descriptor lists exactly one runtime requirement, `A: Hashable`.
/// The `Sendable` halves are readable elsewhere: [sym] `outlined consume of
/// [A : RequestManager<A, B>.Request].Iterator._Variant<A, B where A: Swift.Hashable,
/// A: Swift.Sendable, B: Swift.Sendable>` prints the full signature. So the constraint set is
/// `<A: Hashable & Sendable, B: Sendable>` — resolved, from two sources.
///
/// `Transport.(requestManager)` is `RequestManager<ID64, Result<Packet.Payload, TransportError>>`
/// [sym, field offset symbol], which is the instantiation everything below was disassembled in.
actor RequestManager<A: Hashable & Sendable, B: Sendable>: ActorBackedByDispatchSerialQueue {
    /// [sym] `direct field offset for RequestManager.queue : __C.OS_dispatch_queue_serial`, plus
    /// a `property descriptor` and a `queue.getter`. `__C.OS_dispatch_queue_serial` is
    /// `DispatchSerialQueue`.
    /// [fieldrec] `So24OS_dispatch_queue_serialC`, `IsVar` clear -> `let`.
    let queue: DispatchSerialQueue

    /// PRIVATE. [sym] `direct field offset for RequestManager.(activeRequests) :
    /// [A : RequestManager<A, B>.Request]` — the dictionary's full type, off the offset symbol.
    /// [fieldrec] `SDyx{RequestManager.Request}yxq__GG` = `[A : Request<A, B>]`, and **`IsVar` is
    /// set** — the one mutable field on the manager. One direction only: id -> request.
    private var activeRequests: [A: Request]

    /// [sym] `RequestManager.init(queue: __C.OS_dispatch_queue_serial)`, with an
    /// `__allocating_init`, a method descriptor and a dispatch thunk (so it is not `final` in the
    /// vtable sense — see the note at the end of this file about `final`).
    init(queue: DispatchSerialQueue)

    /// [dis 0x2ad4f10b0] `activeRequests[id]` (`Dictionary.subscript.getter`), then
    /// `Actor.assumeIsolated { $0.reply(with: …) }` on the found `Request`. There is one
    /// `_assertionFailure` path with a `DefaultStringInterpolation` in it.
    /// UNRESOLVED: what that assertion says. Its literal was not matched to a `__cstring` entry.
    func reply(to id: A, with value: B)

    /// [dis 0x2ad4f13b4] iterates `activeRequests`, replies to each through `assumeIsolated`,
    /// then `Dictionary.removeAll(keepingCapacity:)`. So `replyAll` drains the table.
    func replyAll(with value: B)

    /// [dis 0x2ad4f3ebc] `activeRequests[id]`, then
    /// `ActorBackedByDispatchSerialQueue.asyncToActor { $0._cancel(with: value) }` — note this
    /// one hops asynchronously to the request's actor rather than asserting isolation, which is
    /// the difference from `reply(to:with:)`.
    func cancel(to id: A, with value: B)

    /// [sym] both overloads, with these exact labels. The `perform` closure is how the caller
    /// gets the `Request` handed to it while still isolated — `Transport.sendRequest(id:payload:)`
    /// uses it to send the packet after the request is registered ([sym] `closure #1
    /// (RequestManager<ID64, Result<…>>.Request) -> () in closure #1 () async -> … in
    /// Transport.sendRequest(id:payload:)`).
    ///
    /// [dis 0x2ad4e0960, the `<ID64, Result<…>>` specialisation of the first overload] uses
    /// `swift_task_addCancellationHandler` / `removeCancellationHandler` — i.e. a
    /// `withTaskCancellationHandler`, which is how `TransportError.taskCancelled` gets delivered
    /// to a waiter.
    ///
    /// [sym] both overloads suspend on `CheckedContinuation<Result<A1, B1>, Never>`
    /// (`closure #1 (Swift.CheckedContinuation<Swift.Result<A1, B1>, Swift.Never>) -> ()`), and
    /// [cstr] the literal `"withRequest(id:replyHandler:perform:)"` — 37 bytes, and
    /// [dis 0x2ad4f27b8+0x73c] loads exactly `0x25` = 37 as a string length — is the
    /// `function: String = #function` default argument of `withCheckedContinuation`.
    func withRequest(id: A, perform: (Request) -> ()) async -> B?
    func withRequest<T, E: Error>(
        id: A,
        replyHandler: @Sendable (B?) throws(E) -> T,
        perform: (Request) -> ()
    ) async throws(E) -> T

    /// Also an actor, also on the manager's queue — `init` takes the same queue.
    /// [sym] `: Swift.Actor` and `: ActorBackedByDispatchSerialQueue` conformance descriptors,
    /// and `merged protocol witness for Swift.Actor.unownedExecutor.getter … Request : Actor`.
    actor Request: ActorBackedByDispatchSerialQueue {
        /// [fieldmd] order is `id, state, queue`. [sym] `property descriptor for
        /// RequestManager.Request.id : A` and `… .queue : __C.OS_dispatch_queue_serial`.
        /// `state` has no accessor and no property descriptor.
        /// [fieldrec] all three resolved: `id` is `x` (the first generic parameter, `let`),
        /// `state` is `{RequestManager.Request.State}yxq___G` = `State<A, B>` with **`IsVar` set**,
        /// `queue` is `So24OS_dispatch_queue_serialC` (`let`). So `state` is the only mutable
        /// field, which is what makes the whole type a one-slot state machine.
        let id: A
        private var state: State
        let queue: DispatchSerialQueue

        init(id: A, queue: DispatchSerialQueue)

        /// **This is the state machine, and it is resolved, not guessed.**
        ///
        /// [dis 0x2ad4e07d4] `reply(with:)` in the `<ID64, Result<…>>` specialisation:
        /// read `state`, `swift_getEnumCaseMultiPayload`; if the tag is **1**, load a
        /// `(fn, ctx)` pair straight out of the payload and *call it* with the incoming `B?`,
        /// release the context, then `swift_storeEnumTagMultiPayload(…, 3)` and store back.
        /// Returns `tag == 1`. So tag 1 carries the reply handler and tag 3 is the terminal
        /// "already replied" case.
        ///
        /// [dis 0x2ad4f2394] `_cancel(with:)` branches on the same tag:
        ///   tag 0 -> destroy the temporary and return (already cancelled, no-op)
        ///   tag 1 -> call the stored handler with the value, release it, store tag 3
        ///   tag 2 -> `initializeWithCopy` the `B?` into a fresh payload and store tag **0**
        ///   tag 3 -> return (no-op)
        ///
        /// [dis 0x2ad4f1fa8] `_setReplyHandler(to:)`:
        ///   tag 0 -> call the handler immediately with the stored value, store tag 3,
        ///            return **false**
        ///   tag 2 -> store the handler as tag **1**, return **true**
        ///   tag 1 or 3 -> `_assertionFailure` [cstr]
        ///            `"setting reply handler for request in state "` interpolated with the
        ///            state (`DefaultStringInterpolation.appendInterpolation`), from
        ///            `XPCDistributed/Utilities/RequestManager.swift`.
        ///
        /// Mapping tags to the names in [fieldmd] uses one general rule, not declaration order:
        /// Swift's reflection field descriptor emits an enum's **payload cases first, then its
        /// empty cases**, and the multi-payload tag numbering does the same, so the
        /// field-descriptor order *is* the tag order. `Packet.Header` is the control — reflection
        /// lists `request, response, notification` and the wire-format spec resolved those tags
        /// as 0, 1, 2 from four independent branch sites. Here reflection lists
        /// `cancelled, active, initial, completed`, which therefore reads:
        ///   0 cancelled(payload)   1 active(payload)   2 initial   3 completed
        /// and that is exactly the behaviour above.
        ///
        /// **Payload types resolved twice, independently.** From disassembly: tag 1's payload is
        /// loaded as a `(fn, ctx)` pair and called with a `B?`, and tag 0's is built from
        /// `_cancel`'s `B?` argument through the `B?` value witness. And [fieldrec], straight off
        /// the case records:
        ///     cancelled : `q_Sg`    = `Optional<B>`
        ///     active    : `yq_Sgc`  = `(Optional<B>) -> ()`
        ///     initial   : no payload record
        ///     completed : no payload record
        /// The two agree exactly, including which two cases are the payload-carrying ones — which
        /// is also the independent check on the "reflection lists payload cases first" rule the
        /// tag mapping rests on.
        ///
        /// The **source** declaration order is almost certainly `initial, active, completed,
        /// cancelled` or similar; reflection order is not declaration order and I am not
        /// claiming one.
        private enum State {
            case cancelled(B?)
            case active((B?) -> ())
            case initial
            case completed
        }

        /// [sym] exactly these three, with the leading underscores and the `__owned`.
        /// `__owned` on the handler is Apple's — the setter consumes the closure.
        func reply(with value: B?) -> Bool
        func _setReplyHandler(to handler: __owned (B?) -> ()) -> Bool
        func _cancel(with value: B?)
    }
}

// [cstr] `XPCDistributed/Utilities/RequestManager.swift` also carries
// `"Bug in XPCDistributed: Unexpected suspension/corruption when evaluating fresh request"`.
// I did not pin which function raises it. Attribution to one of the two `withRequest` overloads
// is [inference] from `__cstring` adjacency only — the string sits between
// `.../Utilities/RequestManager.swift` and `withRequest(id:replyHandler:perform:)`. Next step:
// match its length (85 bytes) against a `String` length immediate in
// `RequestManager.withRequest<…>` (0x2ad4f27b8, 5892 bytes), the way the Backpressure twin below
// was pinned.

// ============================================================================================
// MARK: - BackpressureManager
// ============================================================================================

/// An **actor** on a `DispatchSerialQueue`, file `XPCDistributed/Backpressure.swift`.
/// [sym] `: Swift.Actor` and `: ActorBackedByDispatchSerialQueue` conformance descriptors.
/// [gsig] one requirement, `A: Hashable`; [sym] the `enum case for …PriorityBucket.*` symbols
/// print the full signature `<A where A: Swift.Hashable, A: Swift.Sendable>`.
///
/// `Transport.(backpressureManager)` is `BackpressureManager<ID64>?` [sym, field offset symbol] —
/// **optional**, so a transport may have none. All disassembly below is the `<ID64>`
/// specialisation; field offsets quoted are that instantiation's.
actor BackpressureManager<A: Hashable & Sendable>: ActorBackedByDispatchSerialQueue {
    // Field layout, [fieldmd] for names and order, and [dis] for the offsets, each one read off
    // an instruction rather than derived from declaration order:
    //   +0x10 queue                  (16-byte object header, no default-actor storage: it has a
    //                                 custom executor)
    //   +0x18 N                      `ldrb w8, [x20, #0x18]` in `admissible(to:)`
    //   +0x20 inflightCountByPrio    `add x0, x20, #0x20` (beginAccess) in `admissible(to:)`
    //   +0x28 pendingRequestsByPrio  `add x0, x19, #0x28` in `evaluateIncomingRequest`
    //   +0x30 activeRequests         `add x0, x20, #0x30` in `reply(to:with:)`
    //   +0x38 isEnabled              `ldrb w8, [x20, #0x38]; cmp #1` in `releaseSlot(token:)`

    // [fieldrec] confirms every type below and, usefully, splits them: `queue` and `N` have
    // `IsVar` clear (`let`); `inflightCountByPrio`, `pendingRequestsByPrio`, `activeRequests` and
    // `isEnabled` all have `IsVar` set (`var`). So the concurrency limit is immutable after
    // construction and `setBackpressurePolicy` cannot be changing it in place — it must be
    // replacing the manager or going through `disable()`, which is consistent with
    // `Transport.(backpressureManager)` being an Optional.

    /// [sym] offset symbol + property descriptor + getter. [fieldrec] `let`.
    let queue: DispatchSerialQueue

    /// The concurrency limit. [sym] `direct field offset for BackpressureManager.N : Swift.UInt8`,
    /// `N.getter : Swift.UInt8`, and a property descriptor. [fieldrec] `{Swift.UInt8}`, `let`.
    /// Apple's spelling is the single capital `N`; keep it.
    let N: UInt8

    /// PRIVATE. [sym] `direct field offset for BackpressureManager.(inflightCountByPrio) :
    /// [Swift.UInt8]` — a flat array of per-bucket in-flight counts, one `UInt8` each, indexed by
    /// `PriorityBucket.rawValue`. [fieldrec] `Say{Swift.UInt8}G` = `[UInt8]`, `var`.
    /// [dis] every access is `ldrb`/`strb` into the array buffer at `+0x20` from the element base.
    private var inflightCountByPrio: [UInt8]

    /// PRIVATE. [sym] `direct field offset for BackpressureManager.(pendingRequestsByPrio) :
    /// [CollectionsInternal.Deque<BackpressureManager<A>.PendingRequest>]` — an array of deques,
    /// again indexed by bucket. `CollectionsInternal` is the vendored swift-collections copy.
    /// [fieldrec] agrees on the structure — `Say<container>y{…PendingRequest}yx_GGG`, i.e. an
    /// `Array` of a one-parameter container of `PendingRequest<A>`, `var` — but my symbolic-ref
    /// resolver named the container badly (it printed a `CollectionsInternal._Hash` fragment).
    /// The field-offset symbol is the one that names `Deque`, and it is unambiguous, so that is
    /// what is written here.
    private var pendingRequestsByPrio: [CollectionsInternal.Deque<PendingRequest>]

    /// PRIVATE. [sym] `direct field offset for BackpressureManager.(activeRequests) :
    /// [A : RequestManager<A, BackpressureManager<A>.SendToken>.Request]`, and [fieldrec]
    /// `SDyx{RequestManager.Request}yx{…SendToken}yx_G_GG` — the same thing, twice.
    /// **The backpressure manager reuses `RequestManager.Request` as its own waiter primitive**,
    /// instantiated with `B == SendToken`: a caller waiting for admission is a pending request
    /// whose eventual "reply" is the token. `var`.
    private var activeRequests: [A: RequestManager<A, SendToken>.Request]

    /// PRIVATE. [fieldrec] `Sb` = `Bool`, `var`. [dis 0x2ad4e0f50] `releaseSlot` is a no-op unless
    /// this is 1.
    private var isEnabled: Bool

    /// [sym] `init(queue: __C.OS_dispatch_queue_serial, N: Swift.UInt8)`, and
    /// [dis 0x2ad4bd8f8] `default argument 1` is two instructions, `mov w0, #3; ret` — so the
    /// default limit is **3**, matching `BackpressurePolicy.default` below.
    init(queue: DispatchSerialQueue, N: UInt8 = 3)

    /// [sym] `acquireSlot(for: A) async -> SendToken?`.
    /// [dis 0x2ad4dfc10] uses `swift_task_addPriorityEscalationHandler` /
    /// `removePriorityEscalationHandler`, i.e. a `withTaskPriorityEscalationHandler`, and
    /// [sym] its nested closures are
    ///   `closure #1 () async -> SendToken?`
    ///     -> `closure #1 @Sendable (RequestManager<A, SendToken>.Request) -> ()`
    ///        -> `closure #1 (isolated BackpressureManager<A>) -> Decision`
    ///   `closure #2 @Sendable (TaskPriority, TaskPriority) -> ()`  (the escalation handler)
    /// so admission goes: enter `withRequest`, and inside the isolated `perform` closure call
    /// `evaluateIncomingRequest`.
    /// UNRESOLVED: what makes the result `nil` (cancellation vs. disabled vs. drain). Not
    /// disassembled past the call graph.
    func acquireSlot(for id: A) async -> SendToken?

    /// [dis 0x2ad4e0f50] 176 bytes, and the whole body is: return immediately unless
    /// `isEnabled`; `inflightCountByPrio[token.fromBucket.rawValue] -= 1` (with a `brk` on
    /// underflow); then call `evaluatePendingRequests()`. **This is what the token is for** — it
    /// names the bucket whose counter has to be given back.
    func releaseSlot(token: SendToken)

    /// [dis 0x2ad4faaa8] 136 bytes: `Task.currentPriority` ->
    /// `PriorityBucket(taskPriority:)` -> `admissible(to:)`. A convenience for "would a request
    /// at *my* priority be admitted right now".
    func admissible() -> Bool

    /// [dis 0x2ad4f9968] reads `pendingRequestsByPrio` through `Sequence.contains(where:)` and
    /// `activeRequests` through `Dictionary.isEmpty`, and has two `_assertionFailure` sites.
    /// [cstr] both are pinned by matching the `String` length immediate at the site against the
    /// literal's length: `0x4B` = 75 = `"Bug in XPCDistributed: No inflight requests, but pending
    /// queue is not empty"` (at 0x2ad4f9b4c), and `0x47` = 71 = `"Bug in XPCDistributed: No
    /// inflight requests, but find suspended task(s)"` (at 0x2ad4f9b90), file
    /// `XPCDistributed/Backpressure.swift`. So `isIdle()` is also the consistency check: no
    /// in-flight slots must imply an empty pending queue and an empty waiter table.
    ///
    /// [cstr] `Transport.setBackpressurePolicy` is the caller that matters — `Transport.swift`
    /// carries `"API violation: Trying to toggle backpressure policy while there are still
    /// inflight requests. Use .disabled to force-drain pending requests."`, and [sym]
    /// `Transport.setBackpressurePolicy` has a `closure #1 (isolated BackpressureManager<ID64>)
    /// -> Bool` and a `closure #2 (isolated BackpressureManager<ID64>) -> ()`. Attributing the
    /// `Bool` closure to `isIdle()` is [inference] from that pairing; I did not disassemble
    /// `setBackpressurePolicy`.
    func isIdle() -> Bool

    /// [dis 0x2ad4f9bdc] walks `pendingRequestsByPrio`, calls the private `reply(to:with:)` for
    /// each queued `PendingRequest`, and clears. This is the force-drain the API-violation string
    /// above points `.disabled` at.
    /// UNRESOLVED: I did not confirm the `isEnabled = false` store; the 792-byte body was read
    /// for its call annotations only.
    func disable()

    /// PRIVATE. **The admission rule, fully resolved.** [dis 0x2ad4e3a00] 160 bytes:
    /// sum `inflightCountByPrio[0 ... bucket.rawValue]` into a `UInt8` (`brk` on overflow), then
    /// `ldrb w8, [self, #0x18]` (`N`), `cmp w8, sum`, `cset w0, hi` — i.e.
    ///
    ///     N > inflightCountByPrio[0...bucket.rawValue].reduce(0, +)
    ///
    /// Because bucket 0 is the *highest* priority, the sum is "slots currently held at this
    /// priority or better". A low-priority request is therefore squeezed out by high-priority
    /// traffic while a high-priority one only counts its own peers.
    private func admissible(to bucket: PriorityBucket) -> Bool

    /// PRIVATE. **Resolved in full.** [dis 0x2ad4e4034] 428 bytes:
    ///
    ///     if admissible(to: bucket) {
    ///         if reply(to: id, with: SendToken(fromBucket: bucket)) {
    ///             inflightCountByPrio[bucket.rawValue] += 1   // brk on overflow
    ///             return .admitted                            // returns 0 in w0
    ///         }
    ///         return .stale                                   // returns 1 in w0
    ///     }
    ///     pendingRequestsByPrio[bucket.rawValue].append(PendingRequest(id: id))
    ///     return .enqueuedAsPending                           // returns 2 in w0
    ///
    /// The `Deque.append` is visible as
    /// `generic specialization <BackpressureManager<ID64>.PendingRequest> of closure #1
    /// (Deque<A>._UnsafeHandle) -> () in Deque.append(A)`.
    ///
    /// `.stale` is therefore "the waiter is gone" — `reply` returning false means the id was no
    /// longer in `activeRequests`, so no slot is consumed.
    private func evaluateIncomingRequest(id: A, to bucket: PriorityBucket) -> Decision

    /// PRIVATE. [dis 0x2ad4e3aa0] 1220 bytes; pops from `pendingRequestsByPrio`
    /// (`Deque._Storage._makeUniqueCopy`), looks up `activeRequests`
    /// (`__RawDictionaryStorage.find<ID64>`), and replies through
    /// `assumeIsolated` on the `Request`. Has an `_assertionFailure` path.
    /// UNRESOLVED: the assertion's text, and the exact promotion order across buckets.
    private func evaluatePendingRequests()

    /// PRIVATE. [dis 0x2ad4e3f64] 208 bytes: `find<A>` in `activeRequests`; if absent return
    /// false; else `Actor.assumeIsolated { $0.reply(with: token) }` at
    /// `Backpressure.swift:284` (the line immediate `0x11C` = 284 is in the call). Returns the
    /// `Request.reply(with:)` result.
    private func reply(to id: A, with token: SendToken) -> Bool

    /// PRIVATE, both overloads. [sym] exact signatures; note the label is `performIsolated`
    /// here, against `perform` on `RequestManager`.
    /// [cstr] `"withRequest(id:replyHandler:performIsolated:)"` (45 bytes) appears as a `#function`
    /// default argument — [dis 0x2ad4fca08] loads `0x2d` = 45 — and
    /// `"Bug in XPCDistributed: Unexpected suspension when registering request for backpressure"`
    /// (86 bytes) is pinned to this function by [dis 0x2ad4fccb4] loading `0x56` = 86 four
    /// instructions before its `_assertionFailure`.
    private func withRequest(
        id: A,
        performIsolated: (RequestManager<A, SendToken>.Request) -> ()
    ) async -> SendToken?
    private func withRequest<T, E: Error>(
        id: A,
        replyHandler: @Sendable (SendToken?) throws(E) -> T,
        performIsolated: (RequestManager<A, SendToken>.Request) -> ()
    ) async throws(E) -> T

    /// PRIVATE. **Payload-free, three cases, tags 0/1/2 in this order.**
    ///
    /// [fieldrec] **all three case records carry no payload pointer at all** — the direct
    /// statement, which the two size arguments below were standing in for.
    /// [vwt] size 1, stride 1, `HasEnumWitnesses`, extraInhabitants 253 = 256 − 3: three cases,
    /// no payload. It also has no `type metadata completion function` symbol, so its layout does
    /// not depend on `A` despite being nested in a generic actor.
    /// [fieldmd] the name comes through as `BackpressureManager..Decision` — the doubled dot is an
    /// empty private-discriminator string, the same tell as `Ack..CodingKeys`.
    /// [dis 0x2ad4e4034] the three `mov w0, #0` / `#1` / `#2` returns line up with the three
    /// branches quoted under `evaluateIncomingRequest`, which is what fixes the tag values.
    /// [sym] `anonymous descriptor …(Decision)` -> private; conformance descriptors for
    /// `Equatable` and `Hashable`, plus `(Decision).hash(into:)` (40 bytes) and `hashValue`.
    private enum Decision: Hashable {
        case admitted
        case stale
        case enqueuedAsPending
    }

    /// [fieldmd] one field, `id`. [sym] `PendingRequest.id.getter : A` and
    /// `PendingRequest.init(id: A)`. [fieldrec] the record is `x`, the first generic parameter,
    /// `IsVar` clear. That is the whole type — one immutable key. **The priority is not stored**,
    /// because the deque it sits in *is* the priority; that is now an absence read off a
    /// one-record field descriptor rather than an argument from the field list.
    struct PendingRequest {
        let id: A
        init(id: A)
    }

    /// `TaskPriority` -> bucket, **fully resolved**, and it is a threshold ladder, not a table.
    ///
    /// [dis 0x2ad4fa6b8] `init(taskPriority:)`, 456 bytes, four `TaskPriority.>=` comparisons
    /// against, in order: `TaskPriority(rawValue: 0x21)` = 33, `TaskPriority.userInitiated`
    /// (25), `TaskPriority(rawValue: 0x15)` = 21, and `TaskPriority.low` (17). The result byte
    /// stored at the end is 0/1/2/3/4 respectively (the last via `mov w8, #3; cinc w8, w8, eq`):
    ///
    ///     >= 33  -> UI      (33 is .userInteractive, which is not public API — hence the literal)
    ///     >= 25  -> IN      (.userInitiated / .high)
    ///     >= 21  -> DEF     (.medium)
    ///     >= 17  -> UT      (.low / .utility)
    ///     else   -> BG      (.background is 9)
    ///
    /// [fieldrec] all six case records carry no payload. [vwt] size 1, extraInhabitants
    /// 250 = 256 − 6, no metadata completion function. [sym] `PriorityBucket.init(rawValue:
    /// Swift.UInt8)` and `rawValue.getter : Swift.UInt8` fix `RawRepresentable`/`UInt8`; the
    /// `enum case for …PriorityBucket.<name>` symbols confirm all six names.
    ///
    /// `BUCKET_COUNT` is the sixth case and its raw value is 5 — the count of the real buckets.
    /// Apple uses it as the array length for `inflightCountByPrio` / `pendingRequestsByPrio`.
    /// That last sentence is [inference] from `admissible(to:)`'s loop bound and the two arrays'
    /// element types; I did not disassemble the initializer that sizes them.
    enum PriorityBucket: UInt8, Hashable {
        case UI
        case IN
        case DEF
        case UT
        case BG
        case BUCKET_COUNT
    }

    /// **What a `SendToken` is for: it is the receipt naming the counter to decrement.**
    ///
    /// [fieldmd] one field, `fromBucket`. [sym] `SendToken.init(fromBucket: PriorityBucket)` and
    /// `SendToken.fromBucket.getter : PriorityBucket`. [fieldrec]
    /// `{…BackpressureManager.PriorityBucket}yx_G` = `PriorityBucket<A>`, `IsVar` clear -> `let`.
    /// [vwt] size 1, no enum witnesses — a one-byte struct wrapping the bucket, and it inherits
    /// the bucket's 250 spare bits.
    /// [dis 0x2ad4e0f50] `releaseSlot(token:)` uses it for exactly one thing:
    /// `inflightCountByPrio[token.fromBucket.rawValue] -= 1`. Because admission is decided at the
    /// caller's *current* priority, the token has to remember which bucket paid, so that a
    /// caller whose priority was escalated mid-flight still returns the slot it took.
    struct SendToken {
        let fromBucket: PriorityBucket
        init(fromBucket: PriorityBucket)
    }
}

// ============================================================================================
// MARK: - XPCSystem.BackpressurePolicy   (nested, but it belongs with the manager)
// ============================================================================================

extension XPCSystem {
    /// [fieldmd] `{ enabled, maxConcurrentRequests }`, in that order.
    /// [dis 0x2ad51faf4] `custom(maxConcurrentRequests:)` is four instructions —
    /// `mov w9, #1; strb w9, [x8]; strb w0, [x8, #1]; ret` — which pins the layout to two bytes,
    /// `enabled` at +0 and `maxConcurrentRequests` at +1, and shows `custom` always sets
    /// `enabled = true`.
    ///
    /// **The two named policies are resolved to their bytes**:
    ///   [dis 0x2ad51fa18] `one-time initialization function for disabled` stores a zero
    ///       halfword -> `(enabled: false, maxConcurrentRequests: 0)`
    ///   [dis 0x2ad51fa50] `one-time initialization function for default` stores `0x0301`
    ///       little-endian -> `(enabled: true, maxConcurrentRequests: 3)`
    /// which agrees independently with `BackpressureManager.init`'s `N` default of 3.
    ///
    /// [fieldrec] `enabled` is `Sb` = `Bool` and `maxConcurrentRequests` is `{Swift.UInt8}`, both
    /// with `IsVar` clear, so both are `let` — which no longer rests on "there is a getter and no
    /// setter". There is still no `init` symbol: the memberwise initializer is either private or
    /// was inlined away, and the three statics are the whole construction surface.
    struct BackpressurePolicy: Hashable {
        let enabled: Bool
        let maxConcurrentRequests: UInt8

        static var disabled: BackpressurePolicy { get }   // (false, 0)
        static var `default`: BackpressurePolicy { get }  // (true, 3)
        static func custom(maxConcurrentRequests: UInt8) -> BackpressurePolicy

        static func == (lhs: BackpressurePolicy, rhs: BackpressurePolicy) -> Bool
        func hash(into hasher: inout Hasher)
        var hashValue: Int { get }
    }
}

/// [sym] the two setters that consume a policy. `RemoteInterface`'s is the public door;
/// `Transport`'s is where the API-violation check lives ([cstr], `Transport.swift`).
extension XPCSystem.Session.RemoteInterface {
    func setBackpressurePolicy(_ policy: XPCSystem.BackpressurePolicy)
}
extension XPCSystem.Transport {
    func setBackpressurePolicy(_ policy: XPCSystem.BackpressurePolicy)
}

// ============================================================================================
// MARK: - Fuse
// ============================================================================================

/// A one-shot latch. **`~Copyable`, one byte, and `trip()` tells you whether *you* tripped it.**
///
/// [fieldmd] one field, `value`. [sym] `Fuse.value.read : Synchronization.Atomic<Swift.Bool>` —
/// a `read` *coroutine* accessor, which is what Swift emits for a borrowed non-copyable
/// property, and which also gives the field's exact type.
/// [fieldrec] independently: `{Synchronization.Atomic}ySbG` = `Atomic<Bool>`, `IsVar` clear, so
/// `let` (an earlier draft wrote `var`).
/// [vwt] size 1, stride 1, flags `0x03810000` = NonPOD + **NonCopyable** + NonBitwiseBorrowable.
/// So `struct Fuse: ~Copyable` is resolved, not assumed.
///
/// [dis 0x2ad4f605c] `init()` is `strb wzr, [x8]; ret`.
/// [dis 0x2ad4f6064] `trip()` is six instructions: `caslb` 0 -> 1 on the byte, then
/// `cmp w8, #0; cset w0, eq` — a compare-and-swap returning **true only for the caller that
/// won**. Idempotent for everyone else.
/// [dis 0x2ad4f607c] `isTripped` is `ldaprb` (acquiring load) + `and #1`.
///
/// Users, all four read off `direct field offset` symbols [sym]:
///   `Session.(activationFuse)`, `Session.LocalSessionState.(cancellationFuse)`,
///   `Transport.(isCancelledFuse)`, `TransportReceiver.(isCancelledFuse)`.
/// The one-byte size is what lets `Session.activationFuse` sit at the unaligned `+0x99` that the
/// wire-format spec's field-offset table records.
struct Fuse: ~Copyable {
    let value: Synchronization.Atomic<Bool>
    init()
    var isTripped: Bool { get }
    func trip() -> Bool
}

// ============================================================================================
// MARK: - Environment
// ============================================================================================

/// **A field-less namespace struct for reading process environment variables.** It is not a
/// value anybody constructs; it exists to hang `static` accessors off.
///
/// [fieldmd] listed with no fields. [sym] its entire member surface is
/// `static Environment.preserveSelfIPC.getter : Swift.Bool` (plus a property descriptor for it)
/// and the implicit `Environment.init()`. [dis 0x2ad4feea8] the getter is a two-instruction
/// tail-call into a `function signature specialization <Arg[0] = Dead>` of itself — the "dead"
/// argument being the discarded `self` metatype, which is what a namespace type's static
/// accessor looks like.
///
/// [cstr] `XPCSYSTEM_PRESERVE_SELFIPC` is the variable, and `XPCSystem` has a
/// `preserveSelfIPC` stored property [fieldmd] that this feeds. So `Environment` is the seam
/// between `getenv` and `XPCSystem.preserveSelfIPC`.
///
/// Note the asymmetry with `Internal` below: Apple used a `struct` here (so it is inhabited and
/// has an `init()`) and an `enum` there. Recorded because it is the kind of detail a
/// reimplementation would silently normalise.
struct Environment {
    init()
    static var preserveSelfIPC: Bool { get }
    // UNRESOLVED: whether this is the only environment variable read. The getter body was not
    // followed into the specialisation, so a second `static` on this type that got inlined
    // everywhere would not appear. Next step: dump 0x2ad4feeb0.
}

// ============================================================================================
// MARK: - UnownedAwaitableEvent / OwnedAwaitableEvent
// ============================================================================================

/// **A one-shot async event built on `Combine.Future`.** This is the third leg of the session
/// lifecycle alongside `Fuse`.
///
/// [fieldmd] `{ future, promise }`. [vwt] size 24, stride 24, align 8, NonPOD, **copyable** —
/// three words.
///
/// [fieldrec] **both field types resolved**, and both are `let` (`IsVar` clear):
///   `future`  : `{Combine.Future}yx{Swift.Never}G`   = `Combine.Future<Value, Never>`
///   `promise` : `y{Swift.Result}yx{Swift.Never}Gc`   = `(Result<Value, Never>) -> ()`
/// 1 word for the class reference + 2 for the closure = the 3 words `[vwt]` measures.
/// Corroborated by [sym]: the only `Combine` types the whole image mentions are
/// `Combine.Future<(), Swift.Never>` and `Combine.Future<TransportReceiver, Swift.Never>`, which
/// are exactly the two instantiations that appear in field-offset symbols.
///
/// Whether Apple *spells* the second one `Future<Value, Never>.Promise` or writes the function
/// type out cannot be recovered: a typealias mangles as its underlying type. Written as the
/// typealias below because that is what `Future`'s own initializer takes.
///
/// [dis 0x2ad4ec7d4] `init()` allocates a box, calls
/// `Combine.Future.__allocating_init(((Result<A, B>) -> ()) -> ())`, and takes a
/// `swift_beginAccess` — i.e. the standard `Future { promise in … }` trick that captures the
/// promise out of the closure and stores it. [sym] the closure is
/// `closure #1 ((Swift.Result<A, Swift.Never>) -> ()) -> () in UnownedAwaitableEvent.init()`.
/// [dis 0x2ad4ec734] `wait()` calls
/// `(extension in Combine):Combine.Future< where B == Swift.Never>.value.getter` — so waiting is
/// `await future.value`.
/// [dis 0x2ad4ec600] `post(value:)` builds a `Result` (`type metadata accessor for Swift.Result`)
/// and calls the stored promise.
///
/// Users [sym, field offset symbols]: `Session.(cancellationEvent) : UnownedAwaitableEvent<()>`,
/// `Session.(unownedLocalInterfaceActivationEvent) : UnownedAwaitableEvent<()>`,
/// `InProcessService.(receiverAttachedEvent) : UnownedAwaitableEvent<TransportReceiver>`.
struct UnownedAwaitableEvent<Value> {
    let future: Combine.Future<Value, Never>
    let promise: Combine.Future<Value, Never>.Promise   // (Result<Value, Never>) -> ()

    init()
    func post(value: Value)
    func wait() async -> Value
}

/// [sym] `(extension in XPCDistributed):UnownedAwaitableEvent<A where A == ()>.post() -> ()` —
/// a same-type-constrained extension, so the `Void` case gets an argument-less `post()`.
/// [dis 0x2ad4ec9b8] 56 bytes: zero a byte on the stack (that is `Result<(), Never>.success(())`,
/// which `[vwt]`-wise is one tag byte) and call the promise.
extension UnownedAwaitableEvent where Value == () {
    func post()
}

/// **`~Copyable`, and its layout is measured, not inferred.**
///
/// [fieldmd] `{ unownedAwaitableEvent, owningTask, posted }`, in that order.
/// [vwt] size **33**, stride 40, align 8, flags `0x03830007` = NonPOD + NonInline +
/// **NonCopyable** + NonBitwiseBorrowable. 33 = 24 + 8 + 1, and
/// [dis 0x2ad4ed050] `post()` confirms each piece independently:
///   `ldp x8, x20, [self, #8]`  -> the promise's (fn, ctx) at +0x08/+0x10, so the embedded
///                                 `UnownedAwaitableEvent<()>` occupies +0x00…+0x17
///   `add x9, self, #0x20; caslb 0 -> 1, [x9]`  -> a one-byte latch at +0x20
/// leaving `owningTask` as the single word at +0x18.
///
/// [fieldrec] **all three field types resolved**, and all three are `let` (`IsVar` clear):
///   `unownedAwaitableEvent` : `{XPCDistributed.UnownedAwaitableEvent}yytG`
///                             = `UnownedAwaitableEvent<()>`   (`yt` is the empty tuple)
///   `owningTask`            : `ScTyx{Swift.Never}G` = `Task<Success, Never>`
///   `posted`                : `{XPCDistributed.Fuse}` — **it really is `Fuse`.**
/// [sym] `init(wrapping: UnownedAwaitableEvent<()>, ownedBy: Swift.Task<A, Swift.Never>)`
/// independently gives the first two. `Task<Success, Never>` is why the type is generic even
/// though `wait()` returns `()`: the parameter is the owning task's `Success`, not the event's
/// value.
///
/// `posted: Fuse` was marked [inference] in an earlier draft of this file — the reasoning was that
/// `post()` ends with the exact `caslb` 0 -> 1 of `Fuse.trip()` (0x2ad4f6064) with its result
/// discarded, and [dis 0x2ad4eca00] `wait()` opens with the exact `ldaprb` + `tbz` of
/// `Fuse.isTripped` (0x2ad4f607c) at `self+0x20`, but a bare `Atomic<Bool>` would compile
/// identically so the *name* could not be proven from instructions. The field record proves it.
/// Recorded as a worked example of the difference between "the behaviour is resolved" and "the
/// declaration is resolved": the inference was right, and it was still only an inference.
///
/// [dis 0x2ad4eca00] `wait()` is: fast-path on `posted`; otherwise install a
/// `closure #2 @Sendable (TaskPriority, TaskPriority) -> ()` escalation handler and await
/// `closure #1 () async -> ()`. So it is a `withTaskPriorityEscalationHandler` around the
/// underlying wait, which is how a waiter's escalation reaches `owningTask`.
/// UNRESOLVED: exactly what `closure #1` awaits (the embedded event, `owningTask.value`, or
/// both) and therefore what `owningTask` is *for*. Next step: dump
/// `closure #1 () async -> () in OwnedAwaitableEvent.wait()`.
///
/// User [sym, field offset symbol]:
/// `Session.(ownedLocalInterfaceActivationEvent) : OwnedAwaitableEvent<Session.LocalInterface.ActivationToken>?`
/// — and the wire-format spec's reading of `ActivationToken` as "the receipt a peer-handling
/// closure returns to prove it ran" fits: the *owning task* is the peer handler, the event's
/// value is `()`, and the generic parameter is the token the task produces.
struct OwnedAwaitableEvent<Success>: ~Copyable {
    let unownedAwaitableEvent: UnownedAwaitableEvent<()>
    let owningTask: Task<Success, Never>
    let posted: Fuse

    init(wrapping: UnownedAwaitableEvent<()>, ownedBy: Task<Success, Never>)
    func post()
    func wait() async
}

// ============================================================================================
// MARK: - TestHook
// ============================================================================================

/// A field-less namespace struct of `static` test entry points. [fieldmd] no fields;
/// [vwt] size 0, stride 1.
///
/// [sym] the complete member list is these five statics plus the implicit `init()`. The
/// wire-format spec names only `mapToLocalActorID`; the other four are new here.
struct TestHook {
    init()

    /// Already covered by the wire-format spec (0x2ad50b6a0, 460 bytes, zero call sites). Not
    /// re-derived here, and I did not re-run the scan.
    ///
    /// The "zero callers" claim is sound in this one case for a reason worth writing down, because
    /// the same scan is unsound elsewhere: **a direct-branch scan of `__text` sees `BL`/`B` and is
    /// blind to `blraa`**, i.e. to vtable and witness-table dispatch. The Session agent's run of it
    /// reproduced both known-answer controls and then reported zero callers of
    /// `Session.__allocating_init`, which is vtable dispatch, not deadness. `mapToLocalActorID` is
    /// a `static` method on a non-generic, non-class type, so it has no vtable slot and no
    /// protocol witness — a direct-call scan is exhaustive for it. Do not carry the result over to
    /// anything with a method descriptor.
    ///
    /// I make **no** call-site claim about the other four statics below; I did not scan for them.
    static func mapToLocalActorID(_ id: XPCSystem.ActorID, session: XPCSystem.Session) -> XPCSystem.ActorID?

    /// [sym] signature only. Presumably `id.rawActorID` tag == 0, the same byte test
    /// `ActorID.encode(to:)` and `resolve(id:as:)` use — but that is [inference] from the name
    /// and the tag assignment the wire-format spec resolved, not disassembled here.
    static func isLocal(_ id: XPCSystem.ActorID) -> Bool

    /// [sym] signature only. Note the argument is `RawActorID.Remote`, whose fields are
    /// `{ session, key }` [fieldmd] — so this is very likely just the `key` projection, exposed
    /// so a test can see the key inside a remote id. UNRESOLVED (not disassembled).
    static func sharedActorKey(for remote: XPCSystem.RawActorID.Remote) -> XPCSystem.SharedActorKey

    /// [sym] signature only. UNRESOLVED. Name suggests it mints a `Local` id without registering
    /// it in `actorTable`, i.e. the negative case for `resolve(id:as:)`.
    static func unassignedLocalID(in system: XPCSystem) -> XPCSystem.ActorID

    /// [sym] `async -> Swift.Int?`, with an async function pointer. Reads
    /// `TransportReceiver.(PeerTaskTable).liveCount` for the receiver registered under a
    /// `Service` — [inference] from the name plus [sym]
    /// `closure #1 (sending inout [ID64 : PeerTaskTable.Slot]) -> sending Swift.Int in
    /// PeerTaskTable.liveCount.getter`. Not disassembled.
    static func peerTaskCount(for service: XPCSystem.Service) async -> Int?
}

// ============================================================================================
// MARK: - Internal
// ============================================================================================

/// **A caseless namespace enum whose only content is a nested protocol.** [fieldmd] lists
/// `enum XPCDistributed.Internal` with no cases, and there is no `Internal.init` symbol
/// (consistent with `enum`, and the reason it differs from `Environment`/`TestHook`, which are
/// field-less *structs* with implicit `init()`s).
///
/// Nesting a protocol inside a type is legal as of Swift 6 (SE-0404), which is what lets this
/// shape exist at all.
enum Internal {
    /// **`ID` is constrained to `Hashable`** — resolved, not guessed.
    ///
    /// [sym] `associated conformance descriptor for
    /// XPCDistributed.Internal.Identifiable.XPCDistributed.Internal.Identifiable.ID:
    /// Swift.Hashable`, plus `associated type descriptor for …Identifiable.ID` and
    /// `associated type witness table accessor for …ID : Swift.Hashable` in both conformances.
    ///
    /// [sym] `method descriptor for Internal.Identifiable.id.getter : A.ID` is the *only*
    /// requirement, and it has a dispatch thunk.
    ///
    /// Conformers, both with real witness tables [sym]: `XPCSystem` and `XPCSystem.Session` —
    /// whose `id` is `ID64` [sym, `XPCSystem.id.getter : ID64`, `Session.id.getter : ID64`].
    /// `ID64` is `Hashable`, which closes the loop.
    ///
    /// Why it exists rather than using `Swift.Identifiable`: this one carries no
    /// `Swift.Identifiable` inheritance and no `Sendable`/`AnyObject` bound, and it is
    /// deliberately *internal* — `Session` also has to satisfy `Swift.Identifiable` in places
    /// (`Identifiable.id.getter` is what `actorReady`/`export` dispatch through, per the
    /// wire-format spec), so shadowing the name inside a namespace keeps the two apart. That
    /// motive is [inference]; the declaration and its one requirement are resolved.
    ///
    /// [sym] both session protocols inherit it:
    /// `base conformance descriptor for XPCSystem.InboundSessionProtocol:
    /// XPCDistributed.Internal.Identifiable` and the same for `OutboundSessionProtocol` — which
    /// is the "1 base conformance" slot the wire-format spec counts when it derives requirement
    /// indices for those two protocols.
    protocol Identifiable {
        associatedtype ID: Hashable
        var id: ID { get }
    }
}

// ============================================================================================
// MARK: - ActorBackedByDispatchSerialQueue
// ============================================================================================

/// NOT IN MY ASSIGNMENT, but it is a top-level support protocol, it is not nested under
/// `XPCSystem`, and both `RequestManager` and `BackpressureManager` are meaningless without it.
/// Included so it does not fall between subsystems.
///
/// [fieldmd] `class-protocol $s14XPCDistributed32ActorBackedByDispatchSerialQueueP` — the
/// `class-protocol` kind means it is class-constrained, and the `unownedExecutor` extension below
/// means the constraint is `Actor`.
///
/// [sym] one requirement, `method descriptor for
/// ActorBackedByDispatchSerialQueue.queue.getter : __C.OS_dispatch_queue_serial`, with a dispatch
/// thunk. Plus an extension carrying three members: a defaulted `unownedExecutor` (with its own
/// `property descriptor`, so it is the witness every conformer uses — there are `protocol witness
/// for Swift.Actor.unownedExecutor.getter` symbols for `RequestManager`, `RequestManager.Request`
/// and `BackpressureManager`), and two isolation helpers.
///
/// [dis 0x2ad4e3aa0, inside `evaluatePendingRequests`]
/// `(extension in Dispatch):__C.OS_dispatch_queue_serial_executor.asUnownedSerialExecutor()` is
/// called — so `unownedExecutor` is `queue.asUnownedSerialExecutor()`, resolved.
///
/// `syncToActor` / `asyncToActor` are the `file`/`line`-carrying wrappers everything in this
/// subsystem hops through; `syncToActor` is built on `Swift.Actor.assumeIsolated`
/// ([sym] `generic specialization <BackpressureManager<ID64>, ()> of closure #1 () throws -> A1
/// in …syncToActor`), which is where the [cstr] string
/// `"Incorrect actor executor assumption; Expected same executor as "` comes from.
protocol ActorBackedByDispatchSerialQueue: Actor {
    var queue: DispatchSerialQueue { get }
}

extension ActorBackedByDispatchSerialQueue {
    var unownedExecutor: UnownedSerialExecutor { get }
    func syncToActor<T: Sendable>(
        _ body: (isolated Self) throws -> T,
        file: StaticString,
        line: UInt
    ) throws -> T
    func asyncToActor(
        _ body: (isolated Self) -> (),
        file: StaticString,
        line: UInt
    )
}

// ============================================================================================
// MARK: - What is left unresolved
// ============================================================================================
//
// NOTE: eight items that were in this list before the field-record reader existed are now
// resolved, and are marked [fieldrec] at their declarations: every stored-property type on
// `Fuse`, `ID64`, `ID64.Generator`, `SwiftType`, `SwiftTypeCache.State`, `BackpressurePolicy`,
// both awaitable events (including `posted: Fuse`, which was the weakest inference in the file),
// plus `let`-vs-`var` throughout and the payload types of `Either`'s and `Request.State`'s cases.
//
// Interface-level:
//
//  1. `SwiftTypeCache.init` — no symbol. Next: dump the one-time initialization function behind
//     `static SwiftType.(cache)`.
//  2. Whether `SwiftTypeCache`'s two accessors write the opposite map (the wire-format spec's
//     "do not populate name->type from the mangling direction" warning turns on this). I read
//     both bodies for their `find<…>` witness only. Note both `State` fields are `var`
//     [fieldrec], so *something* writes both; that is not the same as knowing which accessor.
//  3. `BackpressurePolicy`'s memberwise `init` — no symbol; access level unknown.
//  4. `ID64`'s value-taking initializer — no symbol of any kind. `Generator.next()` and
//     `init(from:)` both have to build an `ID64` from a `UInt64`, so one exists; it is either
//     private or trivially inlined everywhere. I did not distinguish.
//  5. `Environment` may have members beyond `preserveSelfIPC` that were inlined away.
//  6. `TestHook.isLocal`, `.sharedActorKey(for:)`, `.unassignedLocalID(in:)`,
//     `.peerTaskCount(for:)` — signatures resolved, bodies not read, and no call-site claim.
//  7. Whether Apple *spells* `promise` as `Future<Value, Never>.Promise` or writes the function
//     type out. A typealias mangles as its underlying type, so [fieldrec] cannot distinguish
//     them; the type itself is resolved either way.
//  8. `pendingRequestsByPrio`'s element container is named `Deque` by the field-offset symbol;
//     my symbolic-reference resolver mis-named it, so the two sources agree on structure but only
//     one names the type. Next step: fix the resolver's handling of symbolic-reference kinds
//     other than 0x01/0x02 (`{type_layout_string …}` in the output is my bug, not Apple's).
//
// Behaviour-level, and these matter for the session work:
//
//  8. `BackpressureManager.acquireSlot(for:)` — what makes it return `nil`. The call graph is
//     resolved, the failure arms are not.
//  9. `BackpressureManager.evaluatePendingRequests()` — the cross-bucket promotion order, and
//     the text of its assertion.
// 10. `BackpressureManager.disable()` — I confirmed it drains the pending deques through
//     `reply(to:with:)` but not the `isEnabled = false` store.
// 11. `OwnedAwaitableEvent.wait()`'s `closure #1 () async -> ()`, and hence what `owningTask` is
//     awaited for. This is the one gap that directly touches
//     `Session.waitForLocalInterfaceActivation`.
// 12. `RequestManager.reply(to:with:)`'s assertion text, and whether `withRequest` removes the
//     request from `activeRequests` on completion (only `replyAll`'s `removeAll` was seen).
// 13. `"Bug in XPCDistributed: Unexpected suspension/corruption when evaluating fresh request"`
//     is attributed to a `RequestManager` function by `__cstring` adjacency alone. Its
//     Backpressure twin was pinned properly by length-matching; this one was not.
//
// Methodological notes for the other agents:
//
//  * **The field records carry the types, and `extract.py` throws them away.** Credit to the
//    Session agent for the layout; this is the single highest-yield probe in the round for a
//    subsystem like mine. `FieldRecord` is `uint32 Flags; RelPtr MangledTypeName (+4);
//    RelPtr FieldName (+8)`, 12 bytes; `field-descriptors.txt` is `+8` only. Flag bit `0x2` is
//    `IsVar`, `0x1` is `IsIndirectCase`, `0x4` is `IsArtificial`. Enum case payloads live in the
//    same records, so "does this case have a payload, and of what type" is a direct read — which
//    is how `Decision` and `PriorityBucket` were shown payload-free without any disassembly, and
//    how `Request.State`'s `cancelled(B?)` / `active((B?) -> ())` were confirmed against the
//    reading I had taken from three functions' `swift_getEnumCaseMultiPayload` branches.
//    Generic-parameter references show up as `x` (first), `q_` (second), `q0_`… rather than as
//    concrete types, so a generic type's records are still readable — you just get
//    `[A : Request<A, B>]` instead of a concrete instantiation.
//    Reader: `support-fieldtypes.py` (prefixed per the shared-scratchpad rule).
//
//  * **Guarding those reads: three probes were wrong before one worked.** This is worth the space
//    because a wrong guard here does not produce a wrong answer, it produces *no* answer and no
//    traceback (exit 139/138, nothing flushed), which reads exactly like "the type has no fields".
//      - `dladdr() != 0` — too strict. It returns 0 for the shared cache's coalesced
//        `__AUTH_CONST` GOT slots that indirect symbolic references point at, even though those
//        addresses read fine. Every cross-module field type came out `{unmapped-indirect}`, i.e.
//        `Fuse.value` looked unresolvable when it was one dereference away.
//      - `LC_SEGMENT_64` vmaddr ranges — also too strict, same cause. Those slots are outside
//        *every* segment of the image that uses them: XPCDistributed's own `__AUTH_CONST` is
//        `0x2f42e7050..0x2f42ec618`, and the slot holding `Swift.UInt64`'s descriptor pointer is
//        at `0x2f2503b38`.
//      - `write(/dev/null, addr, 1) == 1` — **wrong and actively dangerous.** macOS does not
//        validate the buffer for `/dev/null`; it returns 1 for address `0x1`. Believing it made
//        the guard accept everything and produced the SIGBUS it existed to prevent.
//      - `mincore(page, PAGE, &vec)` then `vec & 0x1` (`MINCORE_INCORE`) — works. Real mapped
//        pages come back `0x03`, unmapped ones `0x80`. A genuinely paged-out mapping would
//        false-negative, which fails safely (reports unresolved instead of crashing).
//    Also: a mangled name can *embed* symbolic references whose 4-byte payload contains NUL, so
//    `strlen` is the wrong way to measure one. Skip 5 bytes per control byte in `0x01..0x17`.
//
//  * A **direct-branch callers-of scan is blind to `blraa`** — vtable and witness-table dispatch.
//    "0 callers" is not "unused" for anything with a method descriptor. The one zero-caller result
//    this project relies on, `TestHook.mapToLocalActorID`, is sound because the target is a
//    `static` method on a non-generic non-class type, which has no vtable slot and no witness —
//    say which kind of dispatch you scanned whenever you report a count.
//
//  * `[vwt]` — reading a type's value-witness table out of the loaded image answers what neither
//    the symbols nor the field records do: exact `size`/`stride`, which is the only way to get a
//    field's *offset* in a struct (structs get no `direct field offset` symbols), and the
//    `NonCopyable` flag, which turned "`Fuse` is probably `~Copyable`" into a fact. It pairs well
//    with `[fieldrec]`: the records give you the field types and order, the VWT gives you the
//    size, and together they pinned `OwnedAwaitableEvent`'s layout to the byte (24 + 8 + 1 = 33).
//    `extraInhabitantCount` is a useful cross-check on enums — for a payload-free one it is
//    `256 - caseCount`, matching `Decision` (253) and `PriorityBucket` (250). The symbol is
//    `value witness table for X`;
//    layout is 8 witnesses, then `size` at +0x40, `stride` +0x48, `flags` +0x50 (`NonCopyable` is
//    `0x00800000`), `extraInhabitantCount` +0x54. Beware: for some types only
//    `full type metadata for X` exists, which points at the VWT *pointer*, not the VWT — mixing
//    the two up produces plausible-looking garbage (I printed `size=11941515652` for `ID64`
//    before noticing).
//
//  * `[gsig]` — generic requirements are readable out of the nominal type descriptor's generic
//    context, and that is the only place `RequestManager`'s `A: Hashable` is stated outright.
//    **`Sendable` is a marker protocol and is absent from that list**, so it is a non-evidence
//    trap in exactly the way `merged lazy protocol witness table accessor` is: I nearly wrote
//    `RequestManager<A: Hashable, B>` on the strength of the descriptor alone. The `Sendable`
//    halves came from an unrelated `outlined consume of [A : Request].Iterator._Variant<A, B
//    where A: Hashable, A: Sendable, B: Sendable>` symbol, which prints the whole signature.
//    General rule: an *outlined* or *enum case for* symbol often carries a generic signature
//    that the type's own symbols do not.
//
//  * Reflection field-descriptor order for an enum is **payload cases first, then empty cases**,
//    and the multi-payload tag numbering is the same, so the two agree — that is what let
//    `Request.State`'s four names be assigned to the four tags observed in `reply`, `_cancel` and
//    `_setReplyHandler`. It is *not* declaration order. **And the rule is now checkable rather
//    than trusted**: the field records say which cases carry payloads, so you can confirm the
//    payload-first split directly instead of assuming it — for `Request.State`, `cancelled` and
//    `active` have payload pointers and `initial`/`completed` do not, exactly as the ordering rule
//    requires. Do that check before relying on the ordering. Relatedly, the `enum` vs `mp-enum` kind
//    in `field-descriptors.txt` is **inconclusive for a generic enum**: Swift only emits
//    `MultiPayloadEnum` when the payload size does not have to live in metadata, so
//    `Request.State` is labelled `enum` despite having two payload cases. I nearly read that
//    label as "single payload".
//
//  * Pinning an assertion string to a function without a full disassembly: Swift passes a
//    literal `String` as (count|flags, object). The count register holds the byte length, so
//    grepping the function for `mov x3, #<len>` and comparing against `len(candidate_string)`
//    identifies which literal is which. That is how `isIdle()`'s two messages (75 and 71) and
//    Backpressure's `withRequest` message (86) were attributed, and it also incidentally reveals
//    `#function` default arguments (`withRequest(id:replyHandler:perform:)` = 37 = `0x25`), which
//    is how "this function uses `withCheckedContinuation`" got established.
//
//  * `capstone` is not installed system-wide and macOS pip refuses to add it (PEP 668). A
//    throwaway venv in the scratch directory works and makes `dump-function.py`'s instruction
//    listing available, which was necessary here — the branch targets alone would not have given
//    the enum tag values.
//
//  * Probe files in this round's shared scratch directory are prefixed `support-` so six agents do
//    not overwrite each other's. Mine: `support-fieldtypes.py` (the field-record reader above).
//    Two earlier one-shots were written before that rule reached me and are *not* prefixed —
//    `genreq.py` (the `[gsig]` reader) and `vwt.py` (the `[vwt]` reader). If either is worth
//    keeping it should move next to `dump-function.py` and `verify-containers.py` under a proper
//    name, with the known-answer controls those two use: `BackpressureManager` for `genreq`
//    (independently known to be `A: Hashable` from its `enum case for` symbols), and `Ack`
//    (size 0) plus `SwiftType` (size 24) for `vwt`. `support-fieldtypes.py` has a control too:
//    every `IsVar` bit lands where a reader would predict — the eight mutable fields across
//    `RequestManager`, `BackpressureManager` and `SwiftTypeCache.State` are marked and nothing
//    else is — which is what makes the `let`/`var` reading trustworthy rather than a bit I decided
//    the meaning of.
