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
(field offset `0x70`, apparently dead in this build); `ID64.Generator.next()` also has no `BL`
callers anywhere. If only one id is ever minted per outgoing call, envelope and body must carry
it twice. **For interop it does not matter**: a peer matches on `headerID` alone, so the two
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

### basePriority is derived, not passed

`RemoteInvocationRequest`'s real initializer is

```
init(id: ID64, targetedSharedActor: SharedActorKey,
     remoteCallTarget: Distributed.RemoteCallTarget, invocation: InvocationEncoder)
```

— note that `invocation` is the **encoder itself**, which is `Encodable`, and that there is no
`basePriority` parameter. `basePriority` has a getter and no setter, so the init computes it.

The name and type match Swift's `Task.basePriority: TaskPriority?` exactly, which was confirmed
to exist and to be optional by compiling against it. That is the obvious source, and it fits the
protocol's shape: the receiver executes at the caller's priority, and `invocationEscalated` /
`responseEscalated` exist to raise it afterwards. **Marked as inference** — the getter-only
property and the name match are facts; that the init reads `Task.basePriority` is not resolved.

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
`ResultHandler.onReturnVoid()` (`0x2ad5051b4`) stores `.success(Ack())`.

Not proven: nobody has driven a real peer to return `Void`. The reachable half is covered —
Apple's decoder reads a `[0, {}]` we wrote, as an `Ack`.

`RemoteInvocationResponse<Never>` is the **failure-only** instantiation. Its `Encodable` witness
accessor (`0x2ad516ad8`) is reached from **seven** sites, every one of them a failure path:
`encodeReturn`'s catch path, `encodeReply`'s failure arm, three in
`Session.handleReceivedRequest`, and two more in its closures. Each of the five in
`handleReceivedRequest` is an inlined `Payload(encoding: RemoteInvocationResponse<Never>(...))` —
a `userInfo` dictionary literal, `XPCDictionary.init()`, the `<Never>` witness, then
`XPCDictionary.encode(_:forKey: "payload", withUserInfo:)`. A `.result` is uninhabited in this
instantiation, which is the point.

> An earlier revision of this paragraph said the accessor is reached "only from `encodeReply`'s
> failure arm and `encodeReturn`'s catch path." That was two of seven. The conclusion was
> unaffected — every site is a failure path, so `<Never>` is *more* clearly failure-only than
> claimed — but the exhaustiveness was asserted without the scan that would establish it, and it
> reached this document rather than staying in a session note. Recorded because an unearned
> "only" is the same defect this document keeps catching elsewhere.

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
  `com.apple.XPCDistributed.Service.` and `com.apple.XPCDistributed.EphemeralService.`,
  session label `com.apple.xpc.distributed/Session`.
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

## Status

All three remaining unknowns are resolved, from the extracted macOS 27 binary:
`SharedActorKey`'s container and payloads, `protocolStub`'s absent-vs-null, and the request
encoder's apparent conditional. The packet header, which this document previously did not
account for at all, is resolved too — see *Envelope*.

One thing is now marked unresolved, and it is deliberately not peer-observable: whether the
envelope's `headerID` and the request body's `id` are the same number. See *Envelope* for what
the inference rests on and why interop does not turn on it.

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
