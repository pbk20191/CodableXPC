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

## The coding convention, and why it matters

Apple's bodies use **Swift's synthesized `Codable` for enums**, not a hand-written discriminator.
That shape is:

```
{ "<caseName>": { "<label or _0>": <payload> } }
```

exactly one key at the top level. The binary enforces it — `Session+CommunicationProtocol.swift`
carries the string `"Invalid number of keys found, expected one."`

This is the single most important correction to the previous design, which wrote one flat
dictionary with an explicit `kind` integer. Every enum on the wire below follows the synthesized
shape unless stated otherwise.

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

⚠️ **Unverified:** whether `protocolStub` is written as absent or as null when a call targets a
concrete actor. Determine before claiming byte fidelity.

## Request

`Session.RemoteInvocationRequest`, a struct with keys in this order:

```
id                   : UInt64        the correlation id
basePriority         : ...           TaskPriority
targetedSharedActor  : SharedActorKey
remoteCallIdentifier : ...           the RemoteCallTarget identifier
contents             : InvocationContents
```

`InvocationContents` is an enum: `send | recv`. This is the `contents` nesting the previous design
flattened away, and it is load-bearing.

⚠️ **Unverified:** what distinguishes `send` from `recv`, and the payload of each. Both names
appear in `__swift5_reflstr` adjacent to the request's keys. Determine before implementing.

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

## SharedActorKey

```
exported | exportedRawValue | dynamic
```

with a companion `WireCode` enum carrying the same three cases — so Apple's shipping build does
use an explicit wire discriminator, as the previous design suspected. What that design got wrong
are the case names: it used `type` / `name` / `dynamic`.

⚠️ **Unverified:** `WireCode`'s raw values and whether the key is coded as the synthesized enum
shape or as a `WireCode` + payload pair. Determine before implementing.

Apple **refuses to forward a remote proxy**: `"API violation: Remote proxy cannot be shared!"` and
`"Cannot send remote actor proxies over an session."` (their typo). The previous design allowed a
proxy to cross the wire to a third party. Match Apple: refuse.

## Identity — unchanged, and already correct

`RawActorID` is `local | remote`, with `Local { actorSystemID, instanceID }` and
`Remote { session, key }`. Our Task 3 implementation matches this exactly, including the field
names. The `ActorID` wrapper is `{ rawActorID }`.

The session-in-userInfo mechanism is also Apple's: `"Bug in XPCDistributed: Session required in
user info dictionary"`. Our `SessionCoding` seam is compatible with it.

⚠️ **Unverified:** whether `Local`'s two halves ever reach the wire. `ID64` has its own
`CodingKeys`, which suggests it is encodable somewhere; the previous design asserted the halves
are never transmitted. Determine — it changes whether `ActorID.encode` may stay as built.

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
| 2 — SharedActorKey | **Rewrite.** Wrong case names, wrong coding shape. |
| 3 — ActorID | **Keep**, pending the `ID64`-on-the-wire question. Field names already match. |
| 4 — ActorRegistry | **Keep.** Not peer-observable. |
| 5 — invocation bodies | **Rewrite.** Wrong keys, wrong envelope, wrong error model. |
| 6 — InvocationEncoder | **Rewrite.** Must produce `protocolStub`/`genericSubsitutions`/`arguments`/`errorType`/`returnType`. |
| Phase A handshake | **Delete from the interop path.** `ProtocolVersion`, `HelloBody`, `HelloAckBody`, and negotiation are not interoperable. |

## Before any of this can claim byte fidelity

Four things are named but not valued. Each needs to be read out of the decompiled encode/decode
functions in `xpcDistributed/*.mm`, or observed empirically:

1. `protocolStub` — absent or null for a concrete-actor call?
2. `InvocationContents.send` vs `.recv` — what distinguishes them, and each payload.
3. `SharedActorKey.WireCode` — raw values, and the coding shape.
4. `ID64` — does either half of a `Local` id ever reach the wire?

Until these are resolved, an implementation can match Apple's *key names* but cannot be claimed
to interoperate. The honest test is a real one: stand up a peer against Apple's own
`XPCDistributed` and exchange an invocation. Nothing short of that verifies this document.
