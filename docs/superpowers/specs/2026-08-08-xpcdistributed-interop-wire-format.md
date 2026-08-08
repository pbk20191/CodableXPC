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

`Transport.Packet` is `{ header, payload }`; `Packet.Payload` wraps a single field, `dictionary`.

`Packet.Header` is a multi-payload enum:

```
request | response | notification
```

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

Type names are not bare strings. `SwiftType` is `{ mangledTypeName, type }` — only
`mangledTypeName` is encoded; `type` is the resolved `Any.Type`, cached.

`SwiftTypeCache` holds `State { nameToType, typeToName }` — the same bidirectional cache our
Task 1 built, which stands unchanged except that it must now be wrapped by `SwiftType` at every
wire boundary.

Failure string: `"Unable to resolve type: "`, and `"Failed to record generic substitution of type "`.

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

## Request

`Session.RemoteInvocationRequest`, a struct with keys in this order:

```
id                   : ID64          the correlation id -- NOT a bare integer
basePriority         : ...           TaskPriority
targetedSharedActor  : SharedActorKey
remoteCallIdentifier : ...           the RemoteCallTarget identifier
contents             : InvocationContents
```

`encode(to:)` was read from the decompilation. It opens one keyed container against `CodingKeys`
and encodes `id` through **`ID64`'s own conformance** — the generic `encode<A>(_:forKey:)`
overload with the `ID64` witness table. So the correlation id is `{ "value": <UInt64> }`, not a
bare integer. `targetedSharedActor` and `contents` likewise go through their own conformances;
one non-generic `encode(_:forKey:)` call handles a builtin-typed key.

That makes **`ID64` the wire representation of every identifier in this protocol** — the request
id here, and the `dynamic` shared-actor key. Anywhere our design writes a bare `uint64`, Apple
writes a one-field dictionary.

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

`Session.RemoteInvocationResponse` is `{ _value }`. The `_value` is a success payload or a
`RemoteInvocationFailure`, a multi-payload enum coded in the synthesized shape:

```
{ "executionFailed":         { "_0": <payload> } }
{ "resultPropagationFailed": { "_0": <payload> } }
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
interoperable. Apple has no envelope `seq` to collide with, because correlation lives in the
request body's `id`.

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
| `exported` | a **`SwiftType`** — so `{ mangledTypeName: … }` |
| `exportedRawValue` | a **String** (no witness-table call; the builtin overload) |
| `dynamic` | an **`ID64`** — so `{ value: <UInt64> }` |

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
`dynamic` case's payload, through ID64's own `Codable` conformance. `ID64` is `{ value }`, a
single field, so it codes as a keyed container `{ "value": <UInt64> }` rather than a bare integer.

That is narrower than it first looks, and it does **not** overturn the previous design's rule.
What crosses is the *dynamic sharing counter*, which is exactly the `SharedActorKey` payload — not
`RawActorID.Local`'s `actorSystemID` / `instanceID`. Those two remain process-local, so
`ActorID.encode` as built in Task 3 stands. What changes is only that our `.dynamic(UInt64)` must
encode as an `ID64` struct, not a bare `uint64`.

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
| 3 — ActorID | **Keep**, pending the `ID64`-on-the-wire question. Field names already match. |
| 4 — ActorRegistry | **Keep.** Not peer-observable. |
| 5 — invocation bodies | **Rewrite.** Wrong keys, wrong envelope, wrong error model. |
| 6 — InvocationEncoder | **Rewrite.** Must produce `protocolStub`/`genericSubsitutions`/`arguments`/`errorType`/`returnType`. |
| Phase A handshake | **Delete from the interop path.** `ProtocolVersion`, `HelloBody`, `HelloAckBody`, and negotiation are not interoperable. |

## Status

All three remaining unknowns are resolved, from the extracted macOS 27 binary:
`SharedActorKey`'s container and payloads, `protocolStub`'s absent-vs-null, and the request
encoder's apparent conditional. Nothing in this document is now marked unverified.

The goal is **our own protocol matched to Apple's format**, not live interop with Apple's
services — so the entitlement wall (`"Peer failed XPCSystem's entitlement check"`, enforced by
`findmydevice-user-agent`, `searchpartyd`, `transparencyd`) does not apply, and byte fidelity is
a matter of discipline rather than of a peer accepting us.

That has one honest consequence. **Nothing here has been validated against a running Apple peer,
and under this goal nothing ever will be.** Every claim is read from reflection metadata,
disassembly, and string tables. The strongest available check is internal consistency, which is
why the `.mm`-versus-binary disagreement above matters so much: it is the one case where two
sources could be compared, and they disagreed. Treat single-sourced claims accordingly.

## What this costs the existing implementation
| Task | Status |
|---|---|
| 1 — TypeName cache | **Keep.** Matches `SwiftTypeCache.State`. Needs a `SwiftType` wrapper added at the wire boundary. |
| 2 — SharedActorKey | **Rewrite.** Explicit discriminator was right; case names, payload types, and container (unkeyed pair, not a keyed dict) all wrong. |
| 3 — ActorID | **Keep**, pending the `ID64`-on-the-wire question. Field names already match. |
| 4 — ActorRegistry | **Keep.** Not peer-observable. |
| 5 — invocation bodies | **Rewrite.** Wrong keys, wrong envelope, wrong error model. |
| 6 — InvocationEncoder | **Rewrite.** Must produce `protocolStub`/`genericSubsitutions`/`arguments`/`errorType`/`returnType`. |
| Phase A handshake | **Delete from the interop path.** `ProtocolVersion`, `HelloBody`, `HelloAckBody`, and negotiation are not interoperable. |

## Before any of this can claim byte fidelity

Three of the original unknowns are resolved: the key's coding shape and the `ID64` question from
`SharedActorKey.encode(to:)`, and `InvocationContents` from its `init(from:)`. Three remain.

The framework has since been extracted from the shared cache
(`dyld_shared_cache_arm64e.67`, image header at file offset `0x50bb000`) with
`/usr/lib/dsc_extractor.bundle`, so the remaining work is ordinary disassembly against a real
Mach-O with a full 5705-entry symbol table — including the private discriminator types the
`.mm` dump omits entirely. The demangled symbol map is checked in as
`xpcdump/macos27-XPCDistributed/symbols-demangled.txt`; the binary itself is deliberately not
committed.

1. The nested payload key name for `SharedActorKey`'s three cases — `_0` is likely but
   unevidenced (see above). Disassemble the `stringValue` getter of
   `SharedActorKey.ExportedCodingKeys`.
2. `protocolStub` — written as absent, or as null, for a concrete-actor call? Start at
   `XPCSystem.InvocationEncoder.encode`.
3. The conditional in `RemoteInvocationRequest.encode(to:)` (see Request, above).

Until these are resolved an implementation can match Apple's *key names* but cannot be claimed to
interoperate.

And even then, the honest test is a real one: stand up a peer against Apple's own
`XPCDistributed` and exchange an invocation. Nothing short of that verifies this document —
everything here is read from metadata and decompiled code, which shows what the binary *contains*,
not what two processes actually accept from each other. The previous design's tier-3 technique
(an anonymous listener dialled from the same process) does not help, because both ends would be
ours; this needs Apple's code on one side.
