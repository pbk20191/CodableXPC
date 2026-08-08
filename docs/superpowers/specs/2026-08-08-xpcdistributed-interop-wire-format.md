# XPCDistributed interop — the real wire format

**Supersedes the wire sections of** `2026-08-06-xpc-distributed-actor-system-design.md`. That
document's section "Non-goal: Apple wire compatibility" is now inverted: the goal is that a real
`XPCDistributed` peer cannot tell us apart. Its architecture, layering, and testing strategy still
stand. Everything it says about field names, discriminators, and envelope shape does not.

**Goal:** interoperate with Apple's shipping `XPCDistributed`. Every byte a peer observes is
binding. Our type names, file layout, and tests are free.

## Provenance

Read from `/System/Library/PrivateFrameworks/XPCDistributed.framework`, macOS 27.0 build
26A5388g, on the development machine. The framework is shared-cache-only — no on-disk Mach-O —
but it `dlopen`s, so its Swift reflection metadata was read from memory: 106 field descriptors
from `__TEXT,__swift5_fieldmd`, with type names resolved through their context descriptors, plus
`__swift5_reflstr` (196 strings) and `__TEXT,__cstring` (119 strings).

Extraction script and output: `xpcdump/macos27-XPCDistributed/`.

The framework was subsequently also extracted from the shared cache (`dyld_shared_cache_arm64e.67`,
image header at file offset `0x50bb000`) with `/usr/lib/dsc_extractor.bundle`, giving a real Mach-O
with a full 5705-entry symbol table — including the private discriminator types the `.mm` dump omits
entirely. The demangled symbol map is checked in as `symbols-demangled.txt`; the binary itself is
deliberately not committed. Addresses quoted below are unslid addresses from that map, which
`verify-containers.py` re-slides against the live image.

This supersedes `xpcDistributed/*.mm`, a decompilation which preserved symbol names but not
string literals — it contains 40 quoted literals in 729 KB and not one coding key. Every claim
below is from the shipping binary. Where something could not be read, it says so.

Apple's own module is `XPCDistributed`; the Xcode project was `XPC_DistributedActors`. Their file
layout, recovered from assertion strings:

```
XPCDistributed/{XPCSystem,ActorID,Transport,TransportReceiver,Backpressure}.swift
XPCDistributed/{InvocationCoder,InvocationResultHandler}.swift
XPCDistributed/Session{,+Inbound,+Outbound,+Transport,+CommunicationProtocol}.swift
XPCDistributed/Transport/XPC/Service+XPC.swift
XPCDistributed/Utilities/{RequestManager,Precondition}.swift
```

## The `.mm` dump is a DIFFERENT, OLDER BUILD

Discovered late, and it invalidates anything derived from `xpcDistributed/*.mm` alone.

The `.mm` decompilation shows `SharedActorKey.ExportedCodingKeys`, `DynamicCodingKeys`, and
`ExportedRawValueCodingKeys` — synthesized per-case enum coding. **The macOS 27 binary contains
none of them.** Its `SharedActorKey` has exactly one nested type, `WireCode`, and no `CodingKeys`
at all. Two independent checks agree: the extracted binary's 5705-entry symbol table has no
symbol matching those names, and the reflection field descriptors list only `WireCode`.

So the two sources are different builds, and the original design document was right about this:
"Apple's dump build uses Swift's synthesized enum coding here; its shipping build moved to a
`UInt8` discriminator." macOS 27 is the shipping build.

**Rule for the rest of this document: where the two disagree, the extracted macOS 27 binary
wins.** The `.mm` remains useful for functions the binary's symbols alone do not explain, but
never for format.

## The coding convention

Enums that *are* coded with Swift's synthesis use the shape

```
{ "<caseName>": { "<label or _0>": <payload> } }
```

with exactly one key at the top level, which the binary enforces —
`Session+CommunicationProtocol.swift` carries `"Invalid number of keys found, expected one."`
`RemoteInvocationFailure` and `RemoteNotification` are coded this way. `SharedActorKey` is not;
see below.

Every `CodingKeys` raw value is its case name. No explicit raw values were found: the three key
names longer than Swift's 15-byte small-string limit — `genericSubsitutions`,
`remoteCallIdentifier`, `targetedSharedActor` — appear verbatim in `__cstring`, and the shorter
ones are inline small strings, which is precisely what synthesized `stringValue` produces.

## Envelope

`Transport.Packet` is `{ header, payload }`, and **both halves are native entries of one xpc
dictionary** — the message handed to `XPCSession.send(message:)`. The header is not `Codable`,
does not go through the overlay byte stream, and is not nested under anything. The whole wire
message is:

```
xpc dictionary
  "headerCategory" : xpc_uint64    0 = notification, 1 = request, 2 = response
  "headerID"       : xpc_uint64    the ID64 -- present for request and response, ABSENT for notification
  "payload"        : the overlay-encoded body   (see "What actually carries an XPCDistributed body")
```

Every claim in that table is resolved from
`Packet.(Header).write(to: inout XPC.XPCDictionary)` (`0x2ad4e134c`, 220 bytes) and its exact
mirror `Packet.(Header).init(from: XPC.XPCDictionary)` (`0x2ad4e71c0`). `write(to:)` is a
hand-written writer, not a `Codable` conformance: it makes two calls to
`XPC.XPCDictionary.subscript.setter<A: UnsignedInteger>(String)`, one with the `UInt8` witness
table and one with the `UInt64` witness table, and nothing else. Both key names are Swift small
strings built from `movz`/`movk` immediates — which is why neither appears in any string table —
and decoded from the immediates at their two call sites they are `"headerCategory"` (14 bytes,
count byte `0xEE`) and `"headerID"` (8 bytes, count byte `0xE8`).

`Packet.Header` is a multi-payload enum. Its cases, and the associated value of each, are read
from the reflection field descriptor (`0x2ad52a334`), resolving each case's symbolic type
reference through its indirect slot:

```
request(ID64) | response(ID64) | notification
```

`notification` has no payload record at all; both of the others point at
`nominal type descriptor for XPCDistributed.ID64`. The enum tag is *not* the wire value —
`write(to:)` renumbers:

| case | enum tag | `headerCategory` | `headerID` |
|---|---|---|---|
| `request(ID64)`  | 0 | **1** | the id |
| `response(ID64)` | 1 | **2** | the id |
| `notification`   | 2 | **0** | not written |

The tag-to-case assignment is resolved from four independent sites, not inferred from
declaration order: `sendNotification(withPayload:)` (`0x2ad4e1000`) writes tag 2 with a zero
payload word; the reply closure inside `handleReceivedPacket` (`0x2ad4dd1fc`) writes tag 1 with
the captured id; the `perform` closure inside `sendRequest(id:payload:)` (`0x2ad4e0140`) writes
tag 0 with the `id` argument; and on receive, `handleReceivedPacket` (`0x2ad4db994`) branches
`tag == 0 -> inboundSession.handleReceivedRequest(_:replyUsing:)`,
`tag == 1 -> requestManager`, `tag == 2 -> inboundSession.handleReceivedNotification(_:)`.

**`Packet.rawValue.getter` does encode.** An earlier reading of it as "returns a stored
dictionary" was wrong. It copies `payload.dictionary` into the return slot and then *tail-calls*
`Header.write(to:)` on that copy (`0x2ad4dc824: b 0x2ad4e134c`). `XPCRawTransport.send(packet:)`
(`0x2ad4db0c0`) does the same thing inline before calling `XPCSession.send(message:)`.
`Packet.init(rawValue:)` is the inverse: `Header.init(from:)`, then
`XPCDictionary.contains(key: "payload")`, and it returns nil if either fails.

**The decoder is strict, and every rule is a rejection, not a default.** From
`Header.init(from:)` and `Packet.init(rawValue:)`, in order: a missing `headerCategory` rejects
the packet; `headerCategory == 0` yields `notification` and `headerID` is never even read;
`headerCategory` of 1 or 2 requires `headerID`, and a missing one rejects the packet; any
`headerCategory >= 3` rejects the packet; and all three kinds require `payload` to be present.
Rejection means `Packet.init(rawValue:)` returns nil and the message is dropped.

Three facts about the xpc encoding were **measured** rather than read, by compiling against the
`XPC` overlay on this machine (the same `XPCDictionary` API the binary calls):

- an `UnsignedInteger` written through that subscript becomes `xpc_uint64`, for `UInt8` as well
  as for `UInt64` — so `headerCategory` is an `xpc_uint64` holding 0, 1, or 2, not a byte;
- assigning `nil` leaves the key **absent**; it does not write a null. A notification therefore
  has two top-level entries, a request or response three;
- both getters the decoder uses accept `xpc_int64` as well as `xpc_uint64`, and return nil on
  an out-of-range value. A peer would tolerate `xpc_int64` here, but we emit `xpc_uint64`.

**Correlation lives in the envelope, not in XPC's message semantics.** The candidate reading that
a request is an XPC message sent with a reply expectation and a response is that reply is
**false**: `XPCRawTransport.send(packet:)` sends all three kinds through the one-way
`XPCSession.send(message:) throws -> ()`, and `sendPacketWithProperQoS` (`0x2ad4dd5f0`) touches
no dictionary and no key at all — it only picks a QoS and forwards. What matches a response to
its request is `headerID`: the response branch of `handleReceivedPacket` hands the header's
`ID64` to `Transport.requestManager` (a `RequestManager<ID64, Result<Packet.Payload,
TransportError>>`, field offset `0x68`), which does a
`__RawDictionaryStorage.find<ID64>` and completes that pending request with `.success(payload)`;
an unmatched id is silently dropped. A reply re-uses the id it received: the reply closure
stores the captured request id into the header it builds.

So there are **two** id-like values in flight, and this document's *Request* section describes
the other one. `RemoteInvocationRequest.id` is generated by `Session.idGenerator` — an inlined
`ID64.Generator.next()`, a `cas` loop on `Session+0x20` that traps on overflow, so ids are
monotonic from 1 — and that same value is what `RemoteNotification.invocationCancelled(id:)`
later refers to. Whether the envelope's `headerID` carries that *same* number is **inference,
not resolved**: `Transport.sendRequest(id:)` takes its id from the caller, and I did not follow
the closure capture chain from `Session.sendInvocation` to the call. The inference rests on an
exhaustive `cas`-instruction scan of `__text`, which finds exactly one `ID64.Generator.next()`
inlining on the send path (the one above) and none against `Transport.(idGenerator)`
(field offset `0x70`). If only one id is ever minted per outgoing call, envelope and body must
carry it twice.

An earlier revision added "`ID64.Generator.next()` also has no `BL` callers anywhere" as support.
That sentence reads stronger than it is: a direct `BL`/`B` scan cannot see `blraa`, so zero direct
callers establishes only that `next()` is always inlined — which is true and unsurprising, and
says nothing about whether any particular field is used. Removed rather than softened. The
`Transport.(idGenerator)` field being dead is separately well-supported: it has no accessor symbol
where `Session.idGenerator.read` does exist, `Transport.init` zeroes `+0x70` in the same `stp`
that stores `requestManager`, `deinit` skips it, and a `cas` scan over every
`XPCSystem.Transport*` range finds compare-and-swap at exactly two sites, both the fuse at
`+0x20`. **For interop it does not matter**: a peer matches on `headerID` alone, so the two
merely have to be internally consistent on our side.

Nothing here is `Codable`, so `verify-containers.py` cannot speak to it. What resolved it was
disassembling the two `Header` methods and decoding their `movz`/`movk` key literals; a probe
that does that — dump a function live, annotate `BL` targets through `__auth_stubs`, and decode
small strings per call site — would be worth keeping next to `verify-containers.py`, and is the
tool to reach for the next time a key is suspected to be inline rather than in `__cstring`.

**There is no version field and no handshake.** `hello` and `helloAck` do not exist in
`XPCDistributed`. Our Phase A `ProtocolVersion`, `HelloBody`, `HelloAckBody`, and the negotiation
in `Transport.activate()` are not interoperable and must not be sent — a real peer receiving them
would fail to decode a packet kind it has no case for.

This is a genuine loss and it should be recorded as one: the version field existed specifically
to catch the silent format drift that this whole exercise is a reconstruction of. Interop costs
us that detector.

## Invocation coding

`XPCSystem.InvocationCodingKeys` — the wire keys, in declaration order:

```
protocolStub          : SwiftType?
genericSubsitutions   : [SwiftType]        <-- misspelled, one 's' after "sub"
arguments             : [ ... ]            positional
errorType             : SwiftType?
returnType            : SwiftType?
```

**The misspelling is required.** It is not a transcription error in this document and not a guess.
The proof is internal to the binary: `InvocationCodingKeys` — which is what serializes — spells it
`genericSubsitutions`, while `DirectInvocationDecoder` — the in-process path that never touches
the wire — spells it `genericSubstitutions`. Apple fixed the typo only where it was free to.

`InvocationEncoder`'s stored properties match the wire keys exactly:
`protocolStub, genericSubsitutions, arguments, errorType, returnType`.

`InvocationDecoder` is `{ mode }` where `Mode` is `encoded | direct`. `DirectInvocationDecoder`
adds `currentArgumentIndex`. We implement `encoded` only; `direct` never serializes, so omitting
it is invisible to a peer.

### SwiftType

`SwiftType` is `{ mangledTypeName, type }` in memory — `type` is the resolved `Any.Type`, cached —
but **on the wire it is a bare String**. `SwiftType.encode(to:)` (`0x2ad4f5940`) opens a
`singleValueContainer()` and calls the `SingleValueEncodingContainer.encode(Swift.String)`
thunk; `init(from:)` (`0x2ad4f59dc`) is its mirror. There is no `SwiftType.CodingKeys` in this
build, so a keyed container is impossible. Verified mechanically — see *Verifying a container
choice* below.

`SwiftTypeCache` holds `State { nameToType, typeToName }` — the same bidirectional cache our
Task 1 built, which stands unchanged except that it must now be wrapped by `SwiftType` at every
wire boundary.

Failure string: `"Unable to resolve type: "`, and `"Failed to record generic substitution of type "`.

**A non-nil mangled name is not a usable one.** `_mangledTypeName` succeeds for types whose names
no peer can resolve, and for one category it succeeds with a name that is outright *wrong*:

- **`private` and `fileprivate` types, and function-local types**, mangle with a
  `$<process address>yXZ` discriminator. `_typeByName` returns nil for them, in this process and
  any other. Measured: 26 ordinary constructions — structs, classes, enums, actors, generic
  instantiations, nested types, stdlib and Foundation types, collections, optionals,
  existentials — all round-trip; every `private`/`fileprivate`/local one fails.
- **An ObjC class created at runtime over a Swift superclass** mangles to the *superclass's*
  name — non-nil, resolvable, and a different type. `objc_allocateClassPair` copies the
  superclass's metadata prefix, nominal type descriptor included.

So the check that matters is `_typeByName(_mangledTypeName(t)) == t`, not a nil test. The
practical consequence for callers: **a distributed func's signature may not use a `fileprivate`
type**. That fails loudly at record time rather than as an unresolvable type in the peer's
process.

This also means a name→type cache must not be populated from the mangling direction. Doing so
asserts an inverse that was never checked, and it makes any test of "does this name resolve"
answer from the cache's own guess.

### protocolStub

`protocolStub` carries the stub type used when a call goes through a **distributed protocol**
rather than a concrete actor type — Swift's `_DistributedActorStub`. The previous design omitted
it as "purpose could not be determined"; `InvocationCoder.swift` settles it with
`"Encoding second _DistributedActorStub "`, an error raised when a second stub is recorded,
which means the field holds at most one.

**Absent when nil, not null** — resolved. `InvocationEncoder.encode(to:)` (`0x2ad4ffb38`) opens a
keyed container against `InvocationCodingKeys` and branches on the optional before encoding
(`cbnz x8`, a value test — distinct from the `cbnz x21` error-register tests that follow every
throwing call). The whole binary contains zero occurrences of `encodeIfPresent` as a symbol, so
this is either an explicit `if let` or an inlined `encodeIfPresent`; both omit the key.

The same holds for the other optionals — `errorType`, `returnType`, `basePriority`. A nil
optional means **the key is not written**, never a null value.

### How protocolStub is recorded, and why genericSubsitutions is always empty

`DistributedTargetInvocationEncoder` has no `recordProtocolStub`, and Apple did not add one —
`InvocationEncoder`'s only protocol witnesses are the four `record*` methods plus
`doneRecording`. The stub is captured inside **`recordGenericSubstitution`**. Both of its error
strings resolve to that one function (`0x2ad4ff6e4`, 340 bytes):

```
0x2ad4ff750   "Encoding second _DistributedActorStub "
0x2ad4ff788   "Failed to record generic substitution of type "
```

It branches early on the recorded type, calls `SwiftType.init<A>(A.Type)`, and reaches for
`Distributed.DistributedActorCodingError`'s witness table — so both failures are thrown, not
trapped. A type conforming to `_DistributedActorStub` goes to `protocolStub`, a second one is an
error, and a type with no mangled name is an error.

**`genericSubsitutions` is always empty on the wire.** `InvocationEncoder.encode(to:)`
(`0x2ad4ffb38`) ends with

```
+0x308   "Bug in XPCDistributed: Found generic substitutions during encoding."
+0x34c   BL   <fatal-error reporter>
+0x354   BRK        <-- trap, not a throw
```

Apple's own encoder *crashes* rather than serialise a non-empty `genericSubsitutions`. Two
readings are possible — the array is drained into `protocolStub` and the check is defensive, or
generic distributed declarations are simply unsupported — and they give the **same wire
outcome**, which is what makes the conclusion safe: the key is present and its value is `[]`.

**What actually triggers it is wider than "a generic distributed func."** Observed by driving a
real `DistributedActorSystem` with a logging encoder: a `distributed actor Foo<T>` records its
own generic arguments on **every** call, including calls to entirely non-generic distributed
funcs. So declaring the actor generic is by itself enough to make every remote call on it
unrepresentable on this wire. A call through an `@Resolvable` protocol stub, by contrast, records
exactly one substitution — the fully applied `$Greeter<System>` — and that one is the stub.

Also observed from the same probe, and worth having written down because no fixture would
otherwise pin it: for a plain `throws` distributed func the runtime records the **existential**,
`any Error` (`s5Error_p`), not a concrete error type. A concrete one appears only under typed
throws. And `recordErrorType` is not called at all for a non-throwing target, which is what makes
the key's presence the signal.

Note the strength of each claim here. The two string attributions and the `BRK` are resolved from
the binary. "Therefore the array is always `[]`" is an inference *from* them — a robust one,
because both available readings agree, but an inference. It has not been observed on a wire.

### basePriority is derived, not passed — now resolved

`RemoteInvocationRequest`'s real initializer is

```
init(id: ID64, targetedSharedActor: SharedActorKey,
     remoteCallTarget: Distributed.RemoteCallTarget, invocation: InvocationEncoder)
```

— note that `invocation` is the **encoder itself** — which has an `encode(to:)` method but does
**not** conform to `Encodable`; see the correction below — and that there is no
`basePriority` parameter. `basePriority` has a getter and no setter, so the init computes it.

The name and type match Swift's `Task.basePriority: TaskPriority?` exactly, which was confirmed
to exist and to be optional by compiling against it. That is the obvious source, and it fits the
protocol's shape: the receiver executes at the caller's priority, and `invocationEscalated` /
`responseEscalated` exist to raise it afterwards.

> This was **marked as inference** and is now **resolved**. `RemoteInvocationRequest.init` is
> inlined into `Session.sendInvocation`, and the inlined body is visible there: the `cas` that
> mints the request id, `outlined copy of SharedActorKey`, `outlined init with copy of
> InvocationEncoder`, `RemoteCallTarget.identifier.getter`, `swift_storeEnumTagMultiPayload` for
> the `InvocationContents` tag, and then a direct call to
> `static Swift.Task<Never, Never>.basePriority.getter : TaskPriority?`. The init reads
> `Task.basePriority`. See *The session layer* for how that region was read.

### basePriority and priority

`TaskPriority`, and it reaches the wire as a **bare `UInt8`** — not `{"rawValue": n}`. The
conformance is `Swift.TaskPriority : Codable` *in the standard library*, not an extension in
XPCDistributed, and it comes from `RawRepresentable`'s conditional conformance, which codes the
raw value in a single-value container.

Checked directly rather than reasoned about, since it is stdlib behavior we can just run:

```
TaskPriority.high        -> 25
TaskPriority.medium      -> 21
TaskPriority.low         -> 17
TaskPriority.background  ->  9
```

A nil `basePriority` omits the key entirely, consistent with the optional rule above.

## Request

`Session.RemoteInvocationRequest`, a struct with keys in this order:

```
id                   : ID64          the correlation id -- NOT a bare integer
basePriority         : ...           TaskPriority
targetedSharedActor  : SharedActorKey
remoteCallIdentifier : ...           the RemoteCallTarget identifier
contents             : InvocationContents
```

`encode(to:)` opens one keyed container against `CodingKeys` — confirmed with
`verify-containers.py`, and consistent with `RemoteInvocationRequest` having a `CodingKeys` in
the field descriptors. It encodes `id` through **`ID64`'s own conformance**: the generic
`encode<A>(_:forKey:)` overload with the `ID64` witness table. `targetedSharedActor` and
`contents` likewise go through their own conformances; one non-generic `encode(_:forKey:)` call
handles a builtin-typed key.

Going through `ID64`'s conformance is **not** the same as writing a nested dictionary. `ID64` is
single-value (see *Identity*), so `id` lands as a plain integer under the `id` key — the witness
table is about which `encode` runs, not about adding a level of nesting. An earlier revision of
this section concluded "so the correlation id is `{ "value": <UInt64> }`, not a bare integer,"
and generalised it to "anywhere our design writes a bare `uint64`, Apple writes a one-field
dictionary." Both were wrong, for the reason recorded under *Identity*.

`ID64` is still the wire representation of every identifier in this protocol — the request id
here, and the `dynamic` shared-actor key. It just isn't a dictionary.

### InvocationContents is not a wire discriminator — resolved

`InvocationContents` is an enum `send | recv`, and the obvious reading — that the wire carries a
`send`/`recv` tag — is **wrong**. Disassembling `InvocationContents.init(from:)` settles it: the
function never opens a keyed container and never looks for a case name. It calls
`EncodedInvocationDecoder.init(from:)` directly on the incoming decoder, then injects an enum tag
(0 or 1) into the local value.

So `send` versus `recv` is an **in-memory** distinction — which direction this process holds the
invocation in, an encoder it is about to send versus a decoder it just received — not something a
peer observes. On the wire, `contents` is simply the encoded invocation: the
`InvocationCodingKeys` dictionary described above.

This matters for our implementation in the good direction: `contents` needs no wrapper enum, just
the invocation dictionary. It is also a warning about reading field lists alone — the name
`InvocationContents` with two cases looks exactly like a wire tag, and is not one.

Apple's decoder type here is `EncodedInvocationDecoder`, distinct from `InvocationDecoder`; it
carries the `DistributedTargetInvocationDecoder` conformance
(`decodeGenericSubstitutions`, `decodeNextArgument`, `decodeErrorType`, `decodeReturnType`).

**The apparent conditional was a decompiler artifact** — resolved. Disassembling the real
`encode(to:)` (`0x2ad50dd3c`) shows the guards are `cbnz x21, 0x2ad50dfb0`: the Swift error
register tested after each throwing encode, all branching to one shared cleanup path. There is no
conditional group. All five keys are always encoded, subject only to the optional rule above.

Failure strings: `"Failed to encode invocation request (error: "`,
`"Request contents are corrupted."`, `"Received invocation contents cannot be encoded."`

## Response

`Session.RemoteInvocationResponse` has one stored field, `_value` — but **`_value` is not a wire
key.** The struct has no `CodingKeys`, and `encode(to:)` (`0x2ad50f8e0`) / `init(from:)`
(`0x2ad50fa28`) both open a `singleValueContainer()`. So the response *is* its payload,
unwrapped; there is no envelope around it. Resolved with `verify-containers.py`, which carries
this method for exactly this reason — the field name reads like a key and is not one.

`_value` is not the payload directly either. It is **`Either<A, RemoteInvocationFailure>`**, a
generic enum of Apple's own (`XPCDistributed.Either`, cases `a | b`), and `Either` carries the
success-versus-failure discriminator. Its coding is the same shape as `SharedActorKey`'s — an
unkeyed pair whose first element is a `UInt8` tag:

```
[ <Either.Case : UInt8>, <payload> ]

0  ->  the success result   (A)
1  ->  a RemoteInvocationFailure
```

`Either.encode(to:)` (`0x2ad4ed7c4`) opens an `unkeyedContainer()`; `init(from:)` (`0x2ad4ed9e4`)
mirrors it. `Either.Case` is `RawRepresentable` over `UInt8`
(`Either.(Case).init(rawValue: Swift.UInt8)`), with no `CodingKeys`, so the tag is a bare
integer. As with `WireCode`, the raw values are the defaults in declaration order — `a` is 0,
`b` is 1 — and `Either<A, RemoteInvocationFailure>` puts the result in `a`.

So a full response is `[0, <result>]` or `[1, {"executionFailed": {"_0": "..."}}]`. There is no
`_value` key and no response-level dictionary anywhere in that.

### What fills `A` for a void return — `Ack`

`Void` is not `Codable`, so a void-returning target still has to bind the response's generic
parameter to something. Apple binds it to **`XPCDistributed.Ack`**, a field-less struct with
synthesized `Codable`. Its encoded form is an empty keyed container, so a void success on the
wire is

```
[0, {}]
```

— and the `{}` is `Ack`'s empty dictionary, not a sentinel anyone chose to mean "returned
nothing".

The chain, every link an annotated direct call or reflection metadata:
`EncodedResultHandler.onReturnVoid()` (`0x2ad5036f4`) tail-calls `onReturn<A>` with `x1` set to
the type metadata for `Ack` and both witness tables, and no value register because `Ack` is
zero-sized; `onReturn` (`0x2ad503404`) stores `Result` case 0 and calls the sole `ReplyHandler`
requirement; `encodeReply`'s success arm calls `encodeReturn` directly; `encodeReturn`
(`0x2ad512298`) calls `RemoteInvocationResponse<A>.init(result:)`. `Ack.encode(to:)` opens a
keyed container and encodes nothing, and the field descriptors show no fields and no
`CodingKeys` cases. Corroborated independently by the in-process path:
`ResultHandler.onReturnVoid()` stores `.success(Ack())` — precisely, `0x2ad5051b4` is only the
async prologue; the wrapper dispatches on `mode`, and it is the **`.direct` arm**
(`0x2ad5052f0`, `DirectResultHandler.onReturnVoid` inlined) that stores it, while the `.encoded`
arm dispatches to `EncodedResultHandler`.

Not proven: nobody has driven a real peer to return `Void`. The reachable half is covered —
Apple's decoder reads a `[0, {}]` we wrote, as an `Ack`.

`RemoteInvocationResponse<Never>` is the **failure-only** instantiation. Its `Encodable` witness
accessor (`0x2ad516ad8`) is reached from **eight** sites, every one of them a failure path:
`encodeReturn`'s catch path, `encodeReply`'s failure arm, three in
`Session.handleReceivedRequest`, and three more in its closures. Each of the six in
`handleReceivedRequest` is an inlined `Payload(encoding: RemoteInvocationResponse<Never>(...))` —
a `userInfo` dictionary literal, `XPCDictionary.init()`, the `<Never>` witness, then
`XPCDictionary.encode(_:forKey: "payload", withUserInfo:)`. A `.result` is uninhabited in this
instantiation, which is the point.

> An earlier revision of this paragraph said the accessor is reached "only from `encodeReply`'s
> failure arm and `encodeReturn`'s catch path." That was two of eight. The conclusion was
> unaffected — every site is a failure path, so `<Never>` is *more* clearly failure-only than
> claimed — but the exhaustiveness was asserted without the scan that would establish it, and it
> reached this document rather than staying in a session note. Recorded because an unearned
> "only" is the same defect this document keeps catching elsewhere.
>
> The revision after that said **seven**, "two more in its closures." It is **three** in the
> closures, so eight in total: `closure #2`, `closure #3`, and the `(3) suspend resume partial
> function for closure #4`, all nested in `closure #2 () async -> ()`. Corrected from an
> exhaustive direct-branch scan of `__text` for the accessor's address, listed site by site.
> Same conclusion for the third time; third wrong count. The count only ever mattered as a
> demonstration that the scan was run, which is exactly why getting it wrong matters.

The last link is tighter than a call chain: `RemoteInvocationResponse.init(result:)`
(`0x2ad50f7c4`) has **exactly one caller in the whole image**, `encodeReturn+0x234`, found by
scanning every branch in `__text`. So "tag 0 on the wire comes from `encodeReturn`" is not an
inference from the path taken; there is no other path.

> This document had the answer and did not notice. `Ack` appears twice above as a *methodological
> control* — the field-less struct that proves the field-descriptor extraction captures even a
> trivial `CodingKeys`, and the keyed control in `verify-containers.py`. Meanwhile this section
> carried an invented justification for `[0, {}]` ("so 'returned nothing' stays distinguishable
> from 'carried no result'") through four rounds. The bytes were right and the reason was ours.
> Worth remembering that a fact can be present in the toolkit and absent from the conclusions.

Corroborating the direction, `RemoteInvocationResponse` has exactly three initializers:
`init(result: A)`, `init(executionFailure: Swift.String)`, `init(resultPropagationFailure:
Swift.String)`. Both failure payloads are **`String`** — which is the same fact as "Apple does
not propagate concrete errors", below, arrived at from the type signatures.

`RemoteInvocationFailure` itself is keyed (it does have `CodingKeys`), a multi-payload enum coded
in the synthesized shape:

```
{ "executionFailed":         { "_0": <String> } }
{ "resultPropagationFailed": { "_0": <String> } }
```

Both per-case key sets contain exactly `_0`, confirming a single unlabelled associated value each.

**Apple does not propagate concrete errors.** The binary contains
`", but XPCSystem does not support propagating errors."` — the previous design's three-tier error
propagation was the main practical benefit of owning the format, and interop forfeits it. A peer
expects a description string, not a typed payload.

Failure strings: `"Failed to decode invocation response (error: "`,
`"Failed to encode result of invocation (error: "`,
`"Failed to obtain the result of the distributed invocation after it was executed"`,
`"The distributed invocation was not executed"`.

## Notification

`Session.RemoteNotification`, synthesized enum coding — one top-level key naming the case:

```
{ "invocationCancelled":  { "id": <UInt64> } }
{ "invocationEscalated":  { "id": <UInt64>, "priority": <...> } }
{ "responseEscalated":    { "id": <UInt64>, "priority": <...> } }
```

The field is **`id`**, not `requestSeq`. The previous design renamed it deliberately to keep the
envelope's sequence distinguishable from the request being referred to; that rename is not
interoperable. Apple does have an envelope-level id — `headerID`, see *Envelope* — but a
notification packet carries none, so there is nothing here for this `id` to collide with: it
always names the earlier request being referred to.

## SharedActorKey — an unkeyed pair, not synthesized coding

```
exported | exportedRawValue | dynamic
```

`SharedActorKey.encode(to:)` was disassembled from the **macOS 27 binary** (`0x2ad4f8458`). Each
of the three branches performs exactly two encodes: a `WireCode`, then the payload.

```
[ <WireCode : UInt8>, <payload> ]
```

| `WireCode` | payload |
|---|---|
| `exported` | a **`SwiftType`** — which is itself a bare String |
| `exportedRawValue` | a **String** (no witness-table call; the builtin overload) |
| `dynamic` | an **`ID64`** — which is itself a bare `UInt64` |

The two exported cases are therefore structurally identical on the wire (array of two, second
element a string). That is not a problem — it is why the `WireCode` discriminator has to exist.

The container is **unkeyed**. That is not an inference from the instruction sequence alone: the
type has no `CodingKeys` of any kind in this build, so a keyed container is impossible, and each
case emits two sequential encodes into the same container.

`WireCode` is `RawRepresentable` with `UInt8` — confirmed by
`WireCode.rawValue.getter : Swift.UInt8` and `WireCode.init(rawValue: Swift.UInt8)`. Raw values
are the default `0, 1, 2` in declaration order.

This partly vindicates our Task 2, which chose an explicit discriminator. What it got wrong is
the case names, the payload types (all three were strings), and the container — Task 2 wrote a
keyed dictionary, Apple writes a two-element array.

## Identity — unchanged, and already correct

`RawActorID` is `local | remote`, with `Local { actorSystemID, instanceID }` and
`Remote { session, key }`. Our Task 3 implementation matches this exactly, including the field
names. The `ActorID` wrapper is `{ rawActorID }`.

The session-in-userInfo mechanism is also Apple's: `"Bug in XPCDistributed: Session required in
user info dictionary"`. Our `SessionCoding` seam is compatible with it.

**`ID64` is on the wire** — resolved. `SharedActorKey.encode(to:)` encodes an `ID64` as the
`dynamic` case's payload, through ID64's own `Codable` conformance. That conformance is
hand-written and **single-value**: `ID64.encode(to:)` (`0x2ad4ef3ac`) opens a
`singleValueContainer()` and calls the `encode(Swift.UInt64)` thunk; `init(from:)`
(`0x2ad4ef440`) opens a `singleValueContainer()` and calls `decode(UInt64.self)`. So an `ID64`
is a **bare `UInt64`** on the wire, not `{ "value": … }`.

> An earlier revision of this document claimed `{ "value": <UInt64> }`, reasoning that a
> single-field struct codes as a keyed container. That was an inference from the field list, not
> disassembly, and it was wrong — it contradicted this document's own rule two sections up
> (no `CodingKeys` ⇒ no keyed container). The `{ value: }` shape belongs to the older `.mm` dump
> build (`xpcDistributed/XPCDistributed_01.mm:8141`), which does have an `ID64.CodingKeys`;
> macOS 27 does not.

That is narrower than it first looks, and it does **not** overturn the previous design's rule.
What crosses is the *dynamic sharing counter*, which is exactly the `SharedActorKey` payload — not
`RawActorID.Local`'s `actorSystemID` / `instanceID`. Those two remain process-local, so
`ActorID.encode` as built in Task 3 stands. And because `ID64` is a bare `UInt64`, our
`.dynamic(UInt64)` payload is already wire-correct as written — it just has to go through
`ID64`'s conformance for the types to line up.

## The session layer

Everything in this section was read from the shipping macOS 27 image by disassembling named
functions and by two scans over `__text`. The tooling is the `dump-function.py` probe plus two new
ones described under *Two more probes worth keeping*. Where a claim rests on a scan, the scan is
named; where it rests on a name or a field list, it says so and is marked as inference.

Field offsets quoted for `Session` are the live values of its `direct field offset` variables,
read out of the loaded image rather than guessed from declaration order:

```
+0x10  actorSystem                            +0x58  unownedLocalInterfaceActivationEvent
+0x18  id                                     +0x70  isBidirectional
+0x20  idGenerator                            +0x78  ownedLocalInterfaceActivationEvent
+0x28  kind                                   +0x99  activationFuse
+0x30  sharedActors                           +0xa0  pendingInvocationExecutionTasks
+0x40  cancellationEvent
```

That table is what lets the byte tests in the disassembly be read at all. Two of them matter a
lot below: `ldrb w8, [session, #0x70]` is `isBidirectional`, and `add x0, session, #0x30` takes
the `sharedActors` lock.

### The storage, and one thing the field lists got wrong

```
XPCSystem.(actorTable)  : Synchronization.Mutex<[RawActorID.Local : WeakActorRef]>
Session.(sharedActors)  : Synchronization.Mutex<[SharedActorKey  : any DistributedActor]>
WeakActorRef            : { ref : (any DistributedActor)? }      -- a weak box
```

`sharedActors` is **one direction only: key → actor**. There is no actor→key map, and no
`ActorID` is stored beside the instance. The mutex's lock word is at `Session+0x30` and the
dictionary at `Session+0x38`.

**`ActorReference` is not the actor table.** The field list `ActorReference { id, actor }` reads
exactly like "the `ActorID` stored beside the instance", and it is not that. It is
`ActorReference<A>` — where **`A` is a `Distributed._DistributedActorStub` with
`A.ActorSystem == XPCSystem`**, not an actor. That constraint is invisible in every symbol,
because a method of a generic type mangles only the requirements introduced at its own level, so
`resolve() -> A` prints unconstrained; it lives in the nominal type descriptor
(`0x2ad526f04`, `NumRequirements=2`). So this is a reference to an `@Resolvable` *protocol stub*,
and `resolve()` hands back the stub-typed proxy. On the wire it is nothing special:
`ActorReference.encode(to:)` is 36 bytes and `bl`s `ActorID.encode(to:)` on `self.id` — an earlier
revision said 32 bytes and "tail-calls", both wrong, though the semantics it drew from them hold —
so an
`ActorReference` **is a bare `SharedActorKey`** with nothing recording the stub type. A `Codable`
class with `init<A1>(_: A1, as: A.Type)` and
`resolve() -> A` — the user-facing transferable actor reference, a thing you put in a distributed
func's signature. **No statically bound call to `ActorReference.init(_:as:)` or `resolve()` exists
inside `XPCDistributed`** — which is what the scan behind this actually supports, and not the same
as "the session never consults it": both are vtable members with method descriptors, so a
direct-branch scan is blind to exactly the dispatch they would use. An earlier revision said "it
is not consulted by the session at all," and the reconstruction pass declined to inherit that
strong form rather than repeat it. Left as the weaker claim until someone scans `blraa` too.

One more field list that looked like
an answer.

### Where a SharedActorKey is minted, and by which generator

Four functions mint keys, covering the three `WireCode` cases, and all four funnel into one
private writer:

| function | key produced |
|---|---|
| `Session.shareActor(RawActorID.Local)` (`0x2ad508e04`) | `.dynamic(ID64)` |
| `Session.handleActorShared(RawActorID.Local)` (`0x2ad5167dc`) | `.dynamic(ID64)` |
| `LocalInterface.export(_:asDefaultActorFor: B.Type) where B: _DistributedActorStub` (`0x2ad509790`) | `.exported(SwiftType)` |
| `LocalInterface.export(_:asServerActorFor: String)` (`0x2ad509878`) | `.exportedRawValue(String)` |

`shareActor` and `handleActorShared` are byte-identical clones, 96 bytes each: load
`Session+0x20`, `adds #1`, `b.hs` to a `brk` on overflow, `cas` loop, then build the key. So the
`dynamic` counter is **`Session.idGenerator`** — a per-session `ID64.Generator`, ids monotonic
from 1, an overflow traps. This is the same inlining shape the *Envelope* section describes for
the request id, on a different field.

The two `export` overloads each read `actor.id` through `Identifiable.id.getter`, trap if it is
`.remote`, and then build their key — `SwiftType.init(B.Type)` for the stub type, or the caller's
string. That settles which `WireCode` each case comes from, which the *SharedActorKey* section
above could only guess at from the payload types.

`Session.(addSharedActor)(_: RawActorID.Local, at: SharedActorKey)` (`0x2ad508d08`) is the only
writer:

1. asserts `isBidirectional` — `"API violation: Session must be bidirectional to share actor
   references"`, `Session.swift:263`;
2. locks `sharedActors`;
3. calls `XPCSystem.resolve(id: RawActorID.Local) -> (any DistributedActor)?` on
   `session.actorSystem` — an `actorTable` lookup;
4. `sharedActors[key] = thatOptional`.

Step 4 is a `Dictionary.subscript.setter` taking an **optional**, so a local id that is not in
`actorTable` does not store a placeholder — it *removes* the key. And note what is absent: no
lookup before minting. **Sharing the same actor twice mints two different keys**, both mapping to
the same instance. There is no reverse map with which to dedupe.

`Session.resolveSharedActor(at: SharedActorKey) -> (any DistributedActor)?` (`0x2ad507dc8`) is the
only reader. An exhaustive direct-branch scan of `__text` finds exactly **two** callers, both on
the inbound execution path: `handleReceivedRequest`'s `closure #2`, and `executeDirectInvocation`.
It is not called from any decode path.

### An incoming SharedActorKey becomes an ActorID — and Apple does not recognise its own keys

This is the defect an earlier review of our own design found and carried forward as a note. Apple
has it too. Resolved, not inferred, and worth stating in full because the conclusion is a decision
rather than a bug report.

**`ActorID` on the wire is a bare `SharedActorKey`.** Both halves open a single-value container.

`ActorID.encode(to:)` (`0x2ad4f6c34`):

- `ldrb w8, [id, #0x40]; cmp w8, #1; b.eq` → **trap** if the id is `.remote`, with
  `"Cannot send remote actor proxies over an session."` (`ActorID.swift:111` — Apple's typo, not
  this document's);
- otherwise read `encoder.userInfo`, `swift_dynamicCast` the value to an existential, and call the
  witness at witness-table slot `+0x20` with the `Local`, taking back a `SharedActorKey`.

  That slot is **`InboundSessionProtocol.handleActorShared(_:)`**, resolved from the method
  descriptors rather than guessed from the signature. Requirement indices are
  `(descriptor - requirementsBase) / 8`, and for `InboundSessionProtocol` (base `0x2ad527ccc`)
  they run: 1 base conformance to `Internal.Identifiable`, 2 `handleReceivedRequest`,
  3 `handleReceivedNotification`, **4 `handleActorShared`**, 5 `handleTransportCancellation`,
  6 `actorSystem`, 7 `isBidirectional`. Slot `+0x20` is index 4. The same arithmetic checks out
  independently on `OutboundSessionProtocol` (base `0x2ad527d58`: 1 base conformance,
  2 `sendInvocation`, 3 `actorSystem`), where slot `+0x18` is index 3 — which is the slot
  `belongsTo` and `resolve` call below;
- `singleValueContainer()`, then `SingleValueEncodingContainer.encode<A>` with the
  `SharedActorKey : Encodable` witness table.

`ActorID.init(from:)` (`0x2ad4f702c`) is the mirror, and the important thing about it is what it
does *not* do:

- read `decoder.userInfo`, `swift_dynamicCast` to an existential;
- `singleValueContainer().decode(SharedActorKey.self)`;
- `mov w8, #1; sturb w8, …; strb w8, [out, #0x40]` — store enum tag **1** and return
  `.remote(session, key)`. Unconditionally.

**No table is consulted.** That is an absence claim, so here is the scan that earns it: the
function's complete annotated call list — every `BL`/`B` target in all 1060 bytes, not a truncated
view — is 20 distinct targets, and the only `__RawDictionaryStorage.find` among them is
specialised over `Swift.CodingUserInfoKey`. There is no `os_unfair_lock_lock`, no
`find<SharedActorKey>`, and no call to `resolveSharedActor`. All four indirect `blraa` in the
function are `CodingUserInfoKey` value-witness and metadata calls (allocate / init-with-copy /
destroy / size), not dispatch to anything that could reach `sharedActors`.

**The recognition is not deferred to `resolve` either.** `XPCSystem.resolve(id:as:)`
(`0x2ad51e064`, 280 bytes) branches on the same tag byte:

| id | what `resolve` does |
|---|---|
| `.local` (tag 0) | private `resolve(id: RawActorID.Local, as:)` — `actorTable` lookup, `swift_unknownObjectWeakLoadStrong`, conditional `swift_dynamicCast` to `A`, else throw `SetupError` |
| `.remote` (tag 1), session's actor system **is** self | **return nil** — which is Swift's instruction to synthesise a remote proxy |
| `.remote` (tag 1), session's actor system is **not** self | throw `SetupError("Remote actor does not belong to the actor system.")` |

The middle test is `RawActorID.Remote.belongsTo(actorSystem:)` (`0x2ad4f7a9c`) inlined: project
the `OutboundSessionProtocol` existential from `Remote+0x00`, call witness-table slot `+0x18`
(the `actorSystem` getter), `swift_release`, compare against the `XPCSystem`. The two functions'
instruction sequences are identical, which is how the inlining was identified rather than
assumed.

So a key we minted, sent, and got back becomes a **proxy**, and `returned.id == local.id` is
false. Apple's answer to "does it recognise a key it minted itself" is no.

The tag-to-case assignment that all of the above rests on is resolved from two independent sites,
not from declaration order: `assignID` writes tag **0** immediately after storing a
`Local(actorSystemID:instanceID:)`, and `TestHook.mapToLocalActorID` traps on tag `!= 1` with the
message `"Local actor ID passed to a function that expects a remote actor ID"`. `local` is 0,
`remote` is 1.

### Apple wrote the fix and shipped it as a test hook

`TestHook.mapToLocalActorID(_: ActorID, session: Session) -> ActorID?` (`0x2ad50b6a0`, 460 bytes)
is precisely the operation our review said belongs in `Session`:

1. precondition the id is `.remote` (else the assertion above, `Session.swift:667`);
2. return nil unless `session.isBidirectional`;
3. lock `sharedActors`, `find<SharedActorKey>`, retain the found actor, unlock;
4. **get that actor's id through the existential**: `swift_getObjectType`, then
   `swift_getAssociatedTypeWitness` for `ID` and `swift_getAssociatedConformanceWitness`, then the
   `Swift.Identifiable.id.getter` dispatch thunk, then `swift_dynamicCast` to
   `XPCSystem.ActorID` (flags 6/7 — conditional).

An exhaustive direct-branch scan of `__text` finds **zero** call sites. It is a `static` func on
a non-generic type, so there is no indirect path it could be reached by. Apple built the mapping,
exposed it to its own tests, and does not use it in the protocol.

Step 4 answers the blocker in our own note directly. Our note said the fix "needs the `ActorID`
stored beside the instance, since `.id` is not reachable through `any DistributedActor`." **It is
reachable** — dynamically, through the associated-type and associated-conformance witnesses, which
is what Apple does. No extra storage is required, and Apple keeps none.

### What that means for us

**Correction — Apple does not have this defect, and the framing above is wrong.** Two paragraphs
up, this document records that `ActorID.encode(to:)` **traps** on a `.remote` id
(`"Cannot send remote actor proxies over an session."`). So under Apple's protocol a peer
*cannot* send our key back to us: every `SharedActorKey` reaching `ActorID.init(from:)` was minted
by the sender, and returning `.remote(session, key)` unconditionally is **correct by
construction**, not an oversight. `TestHook.mapToLocalActorID` having zero callers is consistent
with that — it is unnecessary, not forgotten.

The defect is **ours alone**, and we create it: our `ActorID.encode` echoes `remote.key` where
Apple traps. That divergence is what makes the reflect-back case reachable at all. It also lets a
proxy obtained through session S1 be encoded into session S2, sending S1's key into S2's
namespace, which is the same root cause.

And the obvious repair — consult our own table in `remoteID(for:)` — is **worse than the disease**.
`dynamic` keys come from a *per-session* generator that both sides zero at init, so both ends mint
`.dynamic(1)` first and the two key spaces are numerically identical with nothing on the wire to
tell them apart. Consulting our table first therefore resolves *the peer's* actor as our own the
moment both sides share an actor — silently, and under peer control, since the peer chooses the
bytes. The invariant that keeps this sound is the one stated below: **a key is only ever
interpreted in the map of the side that minted it.** The fix belongs on the encode side, matching
Apple, and then that invariant holds by construction.

**None of this is peer-observable**, which is what made the wrong repair look free. A
`SharedActorKey` on the wire is the same bytes whichever way we resolve it locally — but "costs no
compatibility" is not "is correct", and consulting the local table is incorrect for the reason
above.

**The decision, corrected.** We match Apple on the encode side: **refuse to encode a `.remote`
`ActorID`**. Ours throws where Apple traps — a peer sending us an unencodable value should get a
decodable error, not a crash in whichever process happened to hold the proxy — but the rule is the
same, and it is the rule that makes `remoteID(for:)`'s unconditional `.remote` correct.

The cost is real and is Apple's too: **a proxy cannot be passed on.** An actor reference obtained
from a peer cannot be handed back to that peer, nor forwarded to a third. If we ever want that, it
is a *new feature* with a *new prerequisite* — the two `dynamic` key spaces must first be made
attributable, by seeding each session's generator randomly or partitioning it by role — and not a
defect repair. `TestHook.mapToLocalActorID` is the shape to copy only in that world.

> **Correction: `InvocationEncoder` does not conform to `Encodable`.** It has an `encode(to:)`
> method, and `InvocationContents`'s `Encodable` witness reaches it by direct call, but the
> conformance does not exist. Established by walking `__TEXT,__swift5_proto` — 192 records, one
> per conformance — rather than by a missing symbol name, so it is immune to the merged-accessor
> problem: `InvocationEncoder` has exactly **one** record (`DistributedTargetInvocationEncoder`),
> against positive controls of `Ack` 2, `SwiftType` 5, `SharedActorKey` 5. The same holds for
> `InvocationDecoder`/`EncodedInvocationDecoder`: `init(from:)` is a plain initializer, not a
> `Decodable` witness. **The wire outcome is unaffected** — the bytes are produced either way —
> but the interface claim was wrong, and a section walk is now the settled way to ask whether a
> conformance exists. See `xpcdump/macos27-XPCDistributed/METHOD.md`.

**Eight** requirements are implemented on `XPCSystem` itself, not on `Session`. An earlier
revision said seven and missed `invokeHandlerOnReturn(handler:resultBuffer:metatype:)`, which is
the runtime's path for handing a returned value back through a `ResultHandler`. It casts the
runtime's `metatype` to `(any Decodable & Encodable).Type` **unconditionally**
(`dynamic_cast_existential_2_unconditional`, two `swift_conformsToProtocol2` then `brk #1`), so a
non-`Codable` return type traps the *callee*.

- **`assignID<A>(A.Type) -> ActorID`** (`0x2ad51e17c`) ignores its type argument entirely. It
  builds `Local(actorSystemID: self.id, instanceID: n)` and writes tag 0. `n` comes from a
  `cas` loop on a **process-global** `ID64.Generator` behind a `swift_once` — not from any
  per-`XPCSystem` field. So `instanceID` is unique per process, and `actorSystemID` is what
  distinguishes two `XPCSystem`s in one process.
- **`actorReady<A>(A)`** (`0x2ad51e20c`) reads `actor.id` through `Identifiable.id.getter`, traps
  if `.remote`, locks `actorTable`, and stores `WeakActorRef(actor)` — **weakly**, so the table
  never keeps an actor alive.
- **`resignID(ActorID)`** (`0x2ad51e4a8`) traps on `.remote` (a bare `brk`, no message) and does
  `actorTable[local] = nil`.
- **`resolve(id:as:)`** — the table above.
- **`makeInvocationEncoder()`** (`0x2ad51e524`) is 40 bytes with no calls: zero an 88-byte struct
  and plant the empty-array singleton at `+0x18` and `+0x20`. That is an independent
  corroboration of the encoder's stored properties and their order —
  `protocolStub: SwiftType?` (3 words), `genericSubsitutions: [SwiftType]`, `arguments`,
  `errorType: SwiftType?`, `returnType: SwiftType?` = `0x58` exactly. It also confirms
  `SwiftType` is two words of `String` plus one `Any.Type`, as the *SwiftType* section says.
- **`remoteCall` / `remoteCallVoid`** (`0x2ad51e9d8`, `0x2ad51ec44`) both funnel into a private
  `(remoteCall)<A, B>(actor:target:invocation:result:)` (`0x2ad51e54c`), which reads `actor.id`,
  calls `(extension in XPCDistributed) DistributedActor.session.getter`
  (`0x2ad4f8b34` — requires tag 1, returns the `Remote`'s session, nil for a local id), throws
  `RemoteInvocationCancellationError` if that is nil, and otherwise dispatches
  `OutboundSessionProtocol.sendInvocation`. The two `swift_conformsToProtocol` calls in the public
  `remoteCall` are the serialization-requirement checks the compiler emits for the witness.

  **`remoteCallVoid` binds the result type to `Ack`.** Both `Ack : Decodable` and `Ack : Encodable`
  witness-table accessors are called at the tail call into the private `remoteCall`. That is a
  second, caller-side source for the `[0, {}]` finding under *What fills `A` for a void return*,
  which until now rested only on the reply-handler chain.

The two session protocols, read from their method descriptors:

```
InboundSessionProtocol  : Internal.Identifiable
    actorSystem, isBidirectional, handleActorShared, handleReceivedRequest,
    handleReceivedNotification, handleTransportCancellation
OutboundSessionProtocol : Internal.Identifiable
    actorSystem, sendInvocation
```

### The inbound path

**The userInfo dictionary, resolved exactly.** `handleReceivedRequest` builds a two-entry
dictionary literal:

```
[ CodingUserInfoKey("com.apple.xpc.distributed/Session") : session,
  Distributed.CodingUserInfoKey.actorSystemKey            : session.actorSystem ]
```

The first key is a lazily-initialised global (`swift_once` at `0x2ad50b2fc`) built by
`CodingUserInfoKey.init(rawValue:)` from the 33-byte string at `0x2ad526030`, read out of the
image: `"com.apple.xpc.distributed/Session"`. The second is the *standard* Swift key from
`libswiftDistributed`. The values were read from the `Any` existential boxes the literal is built
into: `session` at `Session` itself, and `session.actorSystem` loaded from `Session+0x10` with
`type metadata accessor for XPCSystem` as its metadata. `Session.sendInvocation` builds the same
dictionary on the way out.

This closes the *Identity* section's "session-in-userInfo mechanism is also Apple's" from a
failure string into a concrete contract. Both `ActorID.encode(to:)` and `ActorID.init(from:)`
look up the first key and `swift_dynamicCast` the value; the mangled cast targets both end in
`_p`, so both cast to a **protocol existential**, and the two are different protocols. Which
protocol each one names is *inferred*, from the field type and the failure strings, not read out
of the descriptors: encode needs `handleActorShared`, so `any InboundSessionProtocol`; decode
stores into `Remote.session : OutboundSessionProtocol`, so `any OutboundSessionProtocol`. Both
sites carry the same two messages, `"Bug in XPCDistributed: Session required in user info
dictionary"` for a missing key and `"Bug in XPCDistributed: Session conforms to inbound session"`
for a failed cast.

**`Session.handleReceivedRequest(_:replyUsing:)`** (`0x2ad512a04`) is 7060 bytes of synchronous
prologue. In order: build the userInfo; `XPCDictionary.decode(as: RemoteInvocationRequest.self,
forKey: "payload", withUserInfo:)`; `Session.remoteSatisfiesActorSystemRequirement()`;
`Session.cancel(because:)` on one failure arm; `RemoteCallTarget.init(_:)` from
`remoteCallIdentifier`; a priority clamp against `Task.currentPriority` and
`TaskPriority.userInitiated` via `Comparable.<`; then
`Task.immediate(name:priority:executorPreference:operation:)` to spawn the execution task, and
`Session.addPendingInvocationExecutionTask(_:withID:)` to register it.

**The success path** is `closure #2 () async -> ()` (`0x2ad514598`):

1. `os_transaction_create` with a name built from the target;
2. `withUnsafeCurrentTask { … }`, which stashes the task for later escalation;
3. **`Session.waitForLocalInterfaceActivation()`** — inbound execution blocks until the session's
   local interface has been activated. This is where the `ActivationToken` machinery touches the
   request path;
4. `Task.isCancelled`;
5. `Session.resolveSharedActor(at: key)` — the target actor;
6. `swift_conformsToProtocol2` against the protocol descriptor at `0x2ad527dd8`, which is
   `XPCSystem.RestrictedAccessDistributedActor : DistributedActor` with one requirement,
   `peerRequirement.getter : XPCPeerRequirement`. If the resolved actor conforms, the path reads
   `Session.RemoteInterface.auditToken` and calls
   `audit_token_t.satisfies(requirement:)` — **a per-actor peer entitlement check**, separate
   from `XPCSystem.peerRequirement`;
7. `swift_getEnumCaseMultiPayload` on the `InvocationContents`;
8. `DistributedActorSystem.executeDistributedTarget(on:target:invocationDecoder:handler:)`;
9. reply through `Session.replyToPendingInvocation(withID:replyBlock:)`.

**`EncodedInvocationDecoder`'s role** is to be the `invocationDecoder` of step 8.
`XPCSystem.InvocationDecoder` is `{ mode: encoded | direct }` and is the conformance's
`InvocationDecoder`, so what `executeDistributedTarget` receives is
`InvocationDecoder(mode: .encoded(EncodedInvocationDecoder))`, built by
`InvocationContents.init(from:)` as the *Request* section describes.
`EncodedInvocationDecoder` carries the four `DistributedTargetInvocationDecoder` witnesses, and
its private helper is spelled
`static EncodedInvocationDecoder.(_decodeErrorType)(from: KeyedDecodingContainer<InvocationCodingKeys>)`
— which independently confirms that the decoder reads the `InvocationCodingKeys` container
directly, with the misspelling and all.

**`pendingInvocationExecutionTasks` is `[ID64 : Task<(), Never>]`, keyed by the request body's
`id`** — the same `ID64` that `RemoteNotification.invocationCancelled(id:)` names, not the
envelope's `headerID`. The five accessors are named in the symbol table and leave nothing to
infer:

```
addPendingInvocationExecutionTask(_: Task<(), Never>, withID: ID64)
escalatePendingInvocationExecution(withID: ID64, to: TaskPriority)
cancelPendingInvocationExecutionTask(withID: ID64)
cancelAllPendingInvocationExecutionTasks()
replyToPendingInvocation(withID: ID64, replyBlock: () -> ()) async
```

**How `invocationCancelled` reaches it.** `Session.handleReceivedNotification(_:)`
(`0x2ad516268`) decodes a `RemoteNotification` from `"payload"`, calls
`swift_getEnumCaseMultiPayload`, and dispatches on the tag:

| tag | case | handler |
|---|---|---|
| 0 | `invocationCancelled` | `cancelPendingInvocationExecutionTask(withID:)` |
| 1 | `invocationEscalated` | `escalatePendingInvocationExecution(withID:to:)` |
| 2 | `responseEscalated` | `Session.verifyEscalatedInvocationResponse(withID:to:)` |

That also confirms the case order the *Notification* section lists, from the branch targets
rather than from declaration order.

### Kind, LocalInterface, and ActivationToken

Less was resolved here, and the parts that were not are marked.

`Session.Kind` is a multi-payload enum with cases `xpc` and `local`. `Session` has exactly two
initialisers —

```
init(actorSystem: XPCSystem, transport: Transport,           options: InitializationOptions) throws(SetupError)
init(actorSystem: XPCSystem, local:     LocalSessionState,   options: InitializationOptions)
```

— so `xpc` carrying the `Transport` and `local` carrying the
`LocalSessionState { label, peerSession, cancellationFuse }` is the obvious reading. **Marked as
inference**: the two initialisers and the two payload types are facts; the case-to-payload
assignment was not read out of `Kind`'s field descriptor payload records.

`InitializationOptions` is `{ rawValue }`, an OptionSet with exactly two members —
`bidirectional` = **2** and `inactive` = **4**, bit 0 unused. Two independent reads each: the
static storage at `0x2ad523140`/`0x2ad523148`, and the getters, which are literally
`mov w0,#2; ret` and `mov w0,#4; ret`. Independently re-verified during the reconstruction
review. And `isBidirectional` is set from it — both initializers end
`ubfx w8, wOptions, #1, #1; strb w8, [self, #0x70]` — and is a stored `let`, so those two
initializers are the whole story.

`isBidirectional` is a plain stored `Bool` at `Session+0x70`, also an `InboundSessionProtocol`
requirement. It gates the entire shared-actor mechanism: `addSharedActor` asserts it, and
`TestHook.mapToLocalActorID` returns nil without it. **Where it is set was not resolved** — the
obvious candidate is `InitializationOptions`, which is exactly the kind of guess this document
does not make.

**`ActivationToken` does not cross the wire.** It has `CodingKeys { id }` and a real `Codable`
conformance, and the conformance is never used to build a packet. The scan that establishes this
is the one that enumerates *every* way a Swift value becomes a packet body: for each direct
`BL`/`B` in `__text`, resolve the target through `__auth_stubs` → `__auth_got` → `dladdr` and keep
the ones landing on `XPC.XPCDictionary.encode(_:forKey:withUserInfo:)` — the single libswiftXPC
call that `Packet.Payload.init(encoding:userInfo:)` is built from. There are **eleven**, and every
one is accounted for:

| sites | function | body |
|---|---|---|
| 1 | `Payload.init<A>(encoding:userInfo:)` | the generic helper itself |
| 1 | `RemoteInvocationReplyEncoder.encodeReturn<A>(value:)` | `RemoteInvocationResponse<A>` |
| 1 | `RemoteInvocationReplyEncoder.encodeReply<A,B>(with:)` | `RemoteInvocationResponse<A>` |
| 6 | `Session.handleReceivedRequest` and its closures | `RemoteInvocationResponse<Never>` |
| 1 | `Session.sendNotification(_:)` | `RemoteNotification` |
| 1 | `Session.sendInvocation` | `RemoteInvocationRequest` |

So there are three body types and no fourth, `ActivationToken` is not among them, and the
*Envelope* section's three packet kinds are complete on the producing side as well as the
consuming side.

What `ActivationToken` actually is, on the evidence of its uses: an in-process handoff receipt.
`TransportReceiver.(peerHandler)` is
`@Sendable (LocalInterface) async -> (result: (), token: ActivationToken)`;
`Session.(ownedLocalInterfaceActivationEvent)` is `OwnedAwaitableEvent<ActivationToken>?`; and
`EphemeralService.Receiver.listen(forPeersSatisfying:executingForEachPeer:)` takes the same
closure type. The token is what a peer-handling closure returns to prove it ran, and
`waitForLocalInterfaceActivation` (step 3 of the inbound path) is what waits on it. Whether some
*other* framework encodes an `ActivationToken` is not a question this image can answer, so
**the purpose of its `Codable` conformance is unresolved.** It is not part of this protocol.

### Merged witness-table accessors do not name their type

A new rule for the *Verifying a container choice* discipline, earned during this round.

Symbols of the form `merged lazy protocol witness table accessor for type X and conformance
X : P` name **one** of several types whose accessor bodies were folded together. These accessors
are parameterised helpers: the caller loads the cache variable, the instantiation function, and
the **conformance descriptor** into `x0`/`x1`/`x2` and then branches to the shared body. The type
therefore lives in the caller's constants, not in the callee's symbol name.

This cost a wrong attribution mid-investigation. The payload encode in `Session.sendInvocation` is
preceded by a call annotated `merged lazy protocol witness table accessor … RemoteNotification :
Encodable`, which reads as though the outbound request path encodes a notification. The
conformance descriptor it is handed is `0x2ad523900`, and that address is
`protocol conformance descriptor for Session.RemoteInvocationRequest : Swift.Encodable`. Resolve
the descriptor, not the symbol.

The corollary is the sharper half: **the absence of a named witness-table accessor proves
nothing**, because the accessor may exist under another type's name. An earlier draft of this
section concluded "`ActivationToken` is never encoded" from exactly that non-evidence. The claim
survived only because it was re-established by the eleven-site payload scan above, which reasons
about call sites rather than about symbol names.

### Two more probes worth keeping

Neither needs an extracted binary; both read the live image, like `verify-containers.py`.

- **A callers-of scan over `__text`.** Given a target, walk every 4-byte word in the range
  spanned by the `T`/`t` symbols, decode `BL`/`B`, and report the enclosing symbol of each site.
  Three claims in this section are absence or exhaustiveness claims and none of them could have
  been made without it: zero callers of `TestHook.mapToLocalActorID`, exactly two of
  `resolveSharedActor`, eight of the `<Never>` accessor. A variant that resolves each target
  through `__auth_stubs` → `__auth_got` → `dladdr` and groups by demangled name is what produced
  the eleven-site payload table, and is the general form — it answers "who calls this" for
  cross-image targets too, where a raw address comparison cannot, because the slide differs per
  process.
- **A live reader for `direct field offset` variables.** Four instruction-level readings in this
  section turn on knowing that `+0x70` is `isBidirectional` and `+0x30` is `sharedActors`. The
  offsets are not declaration order — `activationFuse` sits at `+0x99`, unaligned, between two
  8-aligned fields — so they cannot be derived from the field descriptor list.

They live in this round's scratch directory and are **not** committed. If they are worth keeping
they belong next to `dump-function.py` in `xpcdump/macos27-XPCDistributed/`, with known-answer
controls in the style `verify-containers.py` uses — for the callers-of scan, a target whose call
count is independently known.

## Verifying a container choice

Three claims in this document turn on *which* container a hand-written `Codable` conformance
opens. That is checkable mechanically, and single-sourced inference has already been wrong once
here, so the rule is: **do not infer a container from a field list — resolve the call.**

Two checks, cheapest first.

1. **Reflection metadata.** Swift's synthesized `Codable` always emits a `CodingKeys` enum, and
   `field-descriptors.txt` captures them (all 13 in this build, including one on the field-less
   `struct Ack`). A type with no `CodingKeys` there has a hand-written conformance and *cannot*
   be using a keyed container. `ID64`, `SwiftType`, `XPCSystem.ActorID`, `SharedActorKey`, and
   `SharedActorKey.WireCode` all lack one.
2. **Resolve the branch.** `dlopen` the framework, take `_dyld_get_image_vmaddr_slide`, decode
   the `BL`s in the function body at its address from `symbols-demangled.txt`, follow each into
   `__auth_stubs` (`adrp`/`add`/`ldr x16`), read the `__auth_got` slot, mask off the PAC bits,
   and compare against `dlsym` of the `…Tj` dispatch-thunk manglings. Get those manglings by
   `nm -u` on a two-line Swift file that calls `singleValueContainer()` / `unkeyedContainer()`
   — do not hand-mangle them, the names are easy to get subtly wrong.

`xpcdump/macos27-XPCDistributed/verify-containers.py` does step 2 and prints the resolved thunk
for every call in the coding methods. It needs no extracted Mach-O — it reads the live image.
`SharedActorKey` (unkeyed) and `Ack` (keyed) are in its output as labelled controls, so a
misread shows up as the controls coming out wrong rather than as a silently plausible answer.

## Other surface worth reproducing

- `RemoteInvocationCancellationError { _reason, _message }` with
  `Reason { underlyingSessionCancelled, callingTaskCancelled, executionFailed, resultPropagationFailed }`.
  Message strings recovered: `"Underlying session was cancelled"`,
  `"The task calling the distributed invocation was cancelled"`.
- `EncodedResultHandler { reply, replyHandler, canThrow }`; `ResultHandler { mode }` with
  `Mode { encoded, direct }`. `canThrow` is a stored property, as our design derived it. The
  non-throwing trap is Apple's too: `" in a distributed func that doesn't throw."`
- `BackpressurePolicy { enabled, maxConcurrentRequests }` with priority buckets
  `UI, IN, DEF, UT, BG`, `BUCKET_COUNT`, `fromBucket`, and outcomes
  `admitted | stale | enqueuedAsPending` — matching the previous design's Phase C almost exactly.
- `Transport.TransportError { transportCancelled, taskCancelled }` and
  `RawTransportError { rawTransportCancelled }` — our Phase A already matches these names.
- `Service { isMach, name }`, `EphemeralService { debugName, endpoint }`, service prefixes
  `com.apple.XPCDistributed.Service.` and `com.apple.XPCDistributed.EphemeralService.`.
  `com.apple.xpc.distributed/Session` was listed here as a "session label". **It is not a label
  — it is a `CodingUserInfoKey` raw value**, and it is load-bearing; see *The session layer*.
- `XPCSYSTEM_PRESERVE_SELFIPC`, an environment variable gating `preserveSelfIPC`.
- `ServiceRegistry` and `InProcessRawTransport` both exist in Apple's build. The previous design
  omitted `ServiceRegistry` as unnecessary; that remains our choice, since a registry is not
  peer-observable.

## What this costs the existing implementation

| Task | Status |
|---|---|
| 1 — TypeName cache | **Keep.** Matches `SwiftTypeCache.State`. Needs a `SwiftType` wrapper added at the wire boundary. |
| 2 — SharedActorKey | **Rewrite.** Explicit discriminator was right; case names, payload types, and container (unkeyed pair, not a keyed dict) all wrong. |
| 3 — ActorID | **Keep.** Field names already match. `ID64` needs a hand-written single-value `Codable` conformance so it lands on the wire as a bare `UInt64`; the synthesized one emits `{"rawValue": …}`. |
| 4 — ActorRegistry | **Keep.** Not peer-observable. |
| 5 — invocation bodies | **Rewrite.** Wrong keys, wrong envelope, wrong error model. |
| 6 — InvocationEncoder | **Rewrite.** Must produce `protocolStub`/`genericSubsitutions`/`arguments`/`errorType`/`returnType`. |
| Phase A handshake | **Delete from the interop path.** `ProtocolVersion`, `HelloBody`, `HelloAckBody`, and negotiation are not interoperable. |
| `Session.remoteID(for:)` | **Fix, and diverge on purpose.** Consult the locally shared table first, in the shape of `TestHook.mapToLocalActorID`. Apple returns a proxy here; the divergence is not peer-observable. See *The session layer*. |
| the `ActorID` beside each shared instance | **Not needed.** Read `.id` off `any DistributedActor` through the associated-type/conformance witnesses, as Apple's own test hook does. |

## Status

All three remaining unknowns are resolved, from the extracted macOS 27 binary:
`SharedActorKey`'s container and payloads, `protocolStub`'s absent-vs-null, and the request
encoder's apparent conditional. The packet header, which this document previously did not
account for at all, is resolved too — see *Envelope*.

One thing is now marked unresolved, and it is deliberately not peer-observable: whether the
envelope's `headerID` and the request body's `id` are the same number. See *Envelope* for what
the inference rests on and why interop does not turn on it. The inference is now a little
narrower: a callers-of scan over `__text` finds that `Transport.sendRequest(id:payload:)` has
**exactly one** call site in the whole image, `closure #1` in `Session.sendInvocation` — so there
is only one place an outgoing `headerID` can come from, and only one `cas` on that path mints an
id. Following the closure's capture chain to the store would close it; that was not done.

`Session` and the `DistributedActorSystem` conformance are covered by *The session layer*. Three items that round left unresolved were closed by the reconstruction pass and are recorded
above: `Session.Kind`'s case-to-payload assignment (`.xpc(Transport)` / `.local(LocalSessionState)`,
8 bytes with the tag in pointer bit 63 — read independently by two agents with two implementations
of the field-record reader, then cross-checked against both store sites), the members of
`InitializationOptions`, and where `isBidirectional` is written.

Still unresolved, listed so it is not mistaken for settled: which protocol existential each of
`ActorID`'s two coding methods casts the userInfo value to (inferred from the field type and the
failure strings, not read from the descriptors); and the purpose of `ActivationToken`'s `Codable`
conformance, which is not exercised by any packet path in this image.

The goal is **our own protocol matched to Apple's format**, not live interop with Apple's
services — so the entitlement wall (`"Peer failed XPCSystem's entitlement check"`, enforced by
`findmydevice-user-agent`, `searchpartyd`, `transparencyd`) does not apply, and byte fidelity is
a matter of discipline rather than of a peer accepting us.

That has one honest consequence. **Nothing here has been validated against a running Apple peer,
and under this goal nothing ever will be.** Every claim is read from reflection metadata,
disassembly, and string tables. The strongest available check is internal consistency, which is
why the `.mm`-versus-binary disagreement above matters so much: it is the one case where two
sources could be compared, and they disagreed. Treat single-sourced claims accordingly.

### What actually carries an XPCDistributed body — resolved, and it changes the plan

Both items previously open here are closed, and closing them turned up something larger.

**`Packet.Payload` is `{ "payload": <body> }`.** `Payload.init<A>(encoding:userInfo:)`
(`0x2ad4e1488`) creates an empty `XPCDictionary` and calls
`XPCDictionary.encode(value, forKey:, withUserInfo:)`. The key is a Swift small string built
from immediates rather than a `__cstring`, which is why it does not appear in the string tables;
decoded from the `movz`/`movk` pair it is **`"payload"`**. `Payload.init(from: XPC.XPCDictionary)`
(`0x2ad4e1668`) reads the same key. So there is no conflict between an array-shaped response and
a dictionary-shaped payload: the payload is a dictionary with one entry, and the entry is the
body, whatever shape it has.

**But the body is not a native xpc structure at all.**
`XPCDictionary.encode(_:forKey:withUserInfo:)` in `libswiftXPC` calls
`XPCReceivedMessage.encodeMessage(_:userInfo:)` and stores its result under the key. That is the
XPC overlay's Codable coder, and its output is an **envelope whose `_CodableBody` is one
`xpc_data` byte stream** — not a dictionary of named xpc entries. Measured, not inferred: an
overlay-encoded message's body is `XPC_TYPE_DATA` and none of the value's fields appear as xpc
entries (`AppleDecoderIntegerToleranceTests`).

So an XPCDistributed request on the wire is:

```
Packet.Payload  ->  { "payload": { "_CodableBody": <byte stream>, "_CodableCoderVersion": 1, ... } }
```

and every key name in this document — `genericSubsitutions`, `targetedSharedActor`, the
`WireCode` discriminator, `_0` — lives *inside that stream*, encoded by the overlay's own
tagging, not as xpc dictionary keys.

**What this does and does not invalidate.** Everything this document establishes about the
*Codable* level stands unchanged: the types, the `CodingKeys` and their exact spellings, which
containers each conformance opens, which optionals are omitted, the unkeyed pairs and their tag
values. Those are properties of the `Encodable` conformances and are independent of which
`Encoder` runs. What changes is which encoder must run at the transport boundary: **the overlay
coder (`XPCOverlayCoder`, the iOS 26 generation), not a native-xpc `Encoder`.** Fixtures pinned
through a native-xpc encoder pin the shape correctly and are not the wire.

The repo's overlay coder is already interop-capable in the direction that matters: a message it
encodes decodes in Apple's own coder in-process, verified by `AppleCoderBridge`.

**The signedness question was the wrong question.** Whether a small `UInt8` becomes `xpc_int64`
or `xpc_uint64` cannot arise, because no field of the body becomes an xpc integer. Signedness is
the byte stream's business, and `XPCOverlayCoder`'s generation table documents it there.

That warning has already been earned once. The `ID64` and `SwiftType` container claims were
originally written as inferences from a field list, and both were wrong — they had silently
reproduced the older `.mm` build's shape. `verify-containers.py` now resolves them; anything else
in this document that turns on a container choice should be resolved the same way before an
implementer builds against it.
