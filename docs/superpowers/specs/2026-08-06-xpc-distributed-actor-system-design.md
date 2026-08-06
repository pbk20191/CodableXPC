# XPCActors — an XPC-backed `DistributedActorSystem`

Design spec, 2026-08-06.

## Summary

`XPCActors` is a new target in the `CodableXPC` package providing `XPCActorSystem`, a
production-quality `DistributedActorSystem` that carries `distributed func` calls over XPC.

Its architecture is reverse-engineered from Apple's private `XPCDistributed.framework`
(`XPCSystem`). Its wire format is **not** Apple's — see "Non-goal: Apple wire compatibility"
for why that was rejected on evidence.

## Provenance and confidence

Everything structural in this document was read from one of three sources, in descending order
of confidence:

1. **The `.tbd` export table** of `XPCDistributed.framework` (1,257 symbols). Demangled Swift
   signatures. Highest confidence: these are the real declared types.
2. **Reflection metadata of the shipping binary** — `__swift5_types` field descriptors and
   `__TEXT,__cstring` / `__swift5_reflstr`, read by `dlopen`ing the framework. Gives real field
   names, enum case names, and string literals.
3. **Hex-Rays pseudocode** of an iOS 26 dump (`xpcDistributed/*.mm`, ~25k lines). Gives function
   bodies and control flow, but is a *different, older build* than (1) and (2).

Claims that rest only on (3) are marked. Where (2) and (3) disagree, (2) wins and the
disagreement is recorded.

**This method has been wrong before in this project.** Earlier work on `XPCCompat` produced two
conclusions from static reading that measurement later overturned: the shape of Apple's Codable
envelope, and the ownership conventions of `XPCSession.init(fromConnection:)`. Nothing in this
spec is validated against a live Apple peer, and by design nothing needs to be — see the next
section.

## Non-goal: Apple wire compatibility

The original intent was to be wire-compatible with Apple's `XPCSystem`. That was abandoned after
two findings.

**The format is not stable.** The iOS 26 dump and the macOS 27 shipping binary already disagree:

| | iOS 26 dump | macOS 27 shipping |
|---|---|---|
| `SharedActorKey` coding | synthesized enum (`{"exported":{"_0":…}}`) | `WireCode: UInt8` discriminator |
| `InvocationCodingKeys` | 4 cases | 5 (`protocolStub` prepended) |
| `RemoteInvocationRequest` | 4 fields | 5 (`basePriority` added) |
| `ResultHandler` | one type | `Direct` / `Encoded` split |

There is no single "Apple wire format" to target. Apple ships no version field and no handshake,
which is precisely how these two builds came to diverge silently.

**Compatibility would buy nothing.** `XPCDistributed` has no `.swiftmodule` or `.swiftinterface`
anywhere on the filesystem, so no third party can import it; its only consumers are Apple daemons
(`appleaccountd`, `searchpartyd`, `transparencyd`, `findmydevice-user-agent`). Those daemons
re-evaluate `remoteSatisfiesActorSystemRequirement()` on every inbound request and gate individual
actors behind `RestrictedAccessDistributedActor`. An unentitled peer is rejected regardless of
whether its bytes are correct.

So: **we adopt Apple's architecture and reject its wire format.** We define our own, versioned and
negotiated, and we own both ends.

## Deployment and packaging

`XPCActors` is a separate target and product, following the precedent already set by
`CodableXPCSystem` in this package.

`import Distributed` places an `LC_LOAD_DYLIB` on `/usr/lib/swift/libswiftDistributed.dylib`.
That dylib is resolved from the dyld shared cache with install-name `/usr/lib/swift/...`; it first
shipped in macOS 13 and is in no Swift back-deployment set. This is the same trap that
`import System` set for `CodableXPC`, and it has the same fix: keep it in a target that a
back-deploying consumer simply does not link.

- Package-wide `platforms:` stays at macOS 10.13 / Mac Catalyst 13.1. It is package-wide in
  SwiftPM and cannot be set per target.
- Most declarations in `XPCActors` carry `@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)`.
  macOS 14 is the floor because `XPCSession` / `XPCListener` are macOS 14, which is above
  `Distributed`'s macOS 13.
- **Endpoints are narrower, and this is not a blanket floor.** Measured against the shipping
  overlay's `.swiftinterface` during Phase A: `XPCEndpoint`, `XPCSession.init(endpoint:…)`, and
  `XPCListener.endpoint` are all `@available(macOS 15.0, macCatalyst 18.0, *)` and explicitly
  `unavailable` on iOS, tvOS, and watchOS. Anything endpoint-based is therefore macOS 15 /
  Mac Catalyst 18 and cannot exist on iOS at all. Two consequences:
  - Phase A's `XPCRawTransport.connecting(to:)` and its real-XPC test carry the narrower
    annotation; the rest of the type stays at macOS 14.
  - **Phase C's `EphemeralService` is macOS 15 / Mac Catalyst 18 only.** It is built entirely on
    an anonymous listener plus its endpoint, so there is no iOS implementation to write. The
    plan for Phase C must scope it accordingly rather than assuming the macOS 14 floor.
- Dependencies: `CodableXPC` only, plus Apple's `XPC` overlay via `import XPC`.
  **Not** `XPCCompat` — above macOS 14 the real overlay exists, and `XPCCompat.XPCDictionary`
  would collide with `XPC.XPCDictionary`.
- Requires a Swift 6.0+ compiler for typed throws. Verified: typed throws and
  `_mangledTypeName` / `_typeByName` all compile and run under `-swift-version 5`, so the
  package's tools-version stays at 5.7.

`CodableXPC` already provides `XPCEncoder` and `XPCDecoder` with `userInfo` support on both
sides. That is the whole coding foundation this design needs; no work is required in `XPCCompat`.

### Two libxpc rules that trap rather than throw

Both were established empirically in Phase A, by removing a guard and reading the resulting
crash, because neither is expressed in the overlay's types or documentation. Later phases must
respect them:

- A session obtained from `IncomingSessionRequest.accept` is **already live**. Calling
  `activate()` on it is not a catchable error — libxpc traps and the process dies. `XPCRawTransport`
  carries an `isAlreadyActive` flag for exactly this, and it is load-bearing, not defensive.
- An `XPCListener` created with `options: .none` is likewise already active, so a following
  explicit `activate()` traps. Create listeners with `.inactive` when you intend to activate them
  yourself.

## Architecture

Four layers, mirroring Apple's, with the seams in the same places.

```
XPCActorSystem       DistributedActorSystem conformance; local actor registry
  └ Session          per-peer state; shared actors; in-flight invocations
      └ Transport    Packet framing; request correlation; backpressure
          └ RawTransportProtocol   send(Packet) throws(RawTransportError)
             ├ XPCRawTransport         XPCSession / XPCListener
             └ InProcessRawTransport   loopback
```

The protocol is named `RawTransportProtocol`, not `RawTransport`, mirroring Apple's own
`XPCSystem.Transport.RawTransportProtocol` in the framework dump this design came from.

The `RawTransportProtocol` seam is the load-bearing design decision. It makes every layer above it
testable with no XPC, no second process, and no installed service, and it leaves room for an
`xpc_connection_t`-backed transport later (which would lower the floor to macOS 13) without
touching anything above.

Below `Session`, nothing imports `Distributed`. `Transport` and `Packet` are a pure messaging
layer and are tested as one.

### Files

```
Sources/XPCActors/
  XPCActorSystem.swift        DistributedActorSystem conformance; remoteCall / assignID / resolve
  ActorRegistry.swift         weak local actor table
  ActorID.swift               ActorID / RawActorID / ID64
  SharedActorKey.swift        key type and its wire coding
  TypeName.swift              mangled type name <-> Any.Type, with cache
  Session.swift               session state machine
  SessionInterfaces.swift     LocalInterface / RemoteInterface / ActivationToken
  SessionOptions.swift
  ProtocolVersion.swift       version type and negotiation
  Packet.swift                envelope: PacketHeader / PacketKind / Packet
  Payload.swift               Packet.Payload -- XPCEncoder/XPCDecoder bridge
  HandshakeBodies.swift       HelloBody / HelloAckBody
  Transport.swift             correlation, negotiation, in-flight tables
  RequestTable.swift          seq -> continuation
  RawTransport.swift          the RawTransportProtocol seam
  XPCRawTransport.swift       XPCSession / XPCListener binding
  InProcessRawTransport.swift
  Service.swift               Service / EphemeralService
  InvocationEncoder.swift
  InvocationDecoder.swift
  ResultHandler.swift
  Backpressure.swift
  Errors.swift
```

## Wire format

Normative. Version 1.

### Transport is one-way

Every packet is sent one-way with `XPCSession.send(message:)`. The XPC reply channel is never
used: the incoming-message handler always returns `nil`. Replies are ordinary inbound packets
matched against a local correlation table by `seq`.

This is Apple's design and it is correct. XPC's reply channel binds a response to the requester,
which would make it impossible for a listener-side peer to originate a call. One-way plus
correlation gives full duplex, and unifies replies, notifications, and mid-flight cancellation
into a single mechanism.

### Envelope

`Packet` is a validating view over an `XPCDictionary`; `init?(rawValue:)` returns `nil` for any
dictionary that does not satisfy the table below, and such packets are dropped.

| key | XPC type | presence | meaning |
|---|---|---|---|
| `version` | uint64 | always | protocol version (see below) |
| `kind` | uint64 | always | `0` request, `1` reply, `2` notification, `3` hello, `4` helloAck |
| `seq` | uint64 | `kind ∈ {0,1}` | correlation id; absent otherwise |
| `body` | dictionary | always | payload, encoded by `XPCEncoder` |

`seq` values come from a per-transport monotonic atomic counter. They are unique within a
transport, not globally.

On `hello` and `helloAck` (`kind ∈ {3,4}`) the `version` field is **0**, meaning "not yet
negotiated". Version 0 is reserved for exactly this and is never a valid negotiated version. On
every other packet `version` carries the negotiated value, and a receiver that sees a mismatch
cancels the session rather than attempting to interpret the body.

All integers on the wire are XPC `uint64` values regardless of the width of the Swift type they
carry, because that is the only unsigned primitive `xpc_dictionary` offers. Narrower types such as
`TaskPriority`'s `UInt8` raw value are range-checked on decode.

### Version negotiation

The dialing side sends `hello` before anything else and awaits `helloAck`. No invocation may be
sent or served until negotiation completes. `makeRemoteInterface(to:)` is already `async throws`,
so this adds no API surface.

```
hello    body: { min: uint64, max: uint64 }
helloAck body: { version: uint64 }
```

The receiver picks the highest version in the intersection, or rejects. Cost is one round trip
per session, incurred on first use.

**Rejection is a `helloAck` whose *body* `version` is `0`, sent immediately before the responder
cancels.** Version 0 in the body is reserved for exactly this and is never a version a responder
can choose. This is distinct from the *envelope* `version: 0` that every `hello` and `helloAck`
carries, which only means "not yet negotiated" — the two zeros sit at different levels and mean
different things.

The rejection is sent rather than merely cancelling because this protocol has no timeout: a
responder that dies silently leaves the initiator's `activate()` suspended forever, since an
absent reply is indistinguishable from a slow one.

### Request body

```
actor      : SharedActorKey    (see below)
target     : string            mangled RemoteCallTarget identifier
generics   : [string]          mangled type names
args       : [ ... ]           positional; no per-argument type tag
errorType  : string?           mangled type name
returnType : string?           mangled type name
basePriority : uint64?         TaskPriority raw value
```

Argument labels are discarded. The receiver's `executeDistributedTarget` knows each parameter's
label and type statically from the callee signature and calls `decodeNextArgument<A>()` in order,
so per-argument type information on the wire is pure overhead.

Apple wraps every type name as `{"mangledTypeName": "…"}` and nests the invocation under a
`contents` key. Both are flattened here.

Apple's key for generic substitutions is misspelled — `genericSubsitutions`, one `s` after `sub`.
Since this is our format, it is spelled `generics`.

### Reply body

Exactly one of `ok` or `err` is present; a body with neither or both fails decoding.

```
ok  : <encoded return value>          -- an empty dictionary for Void
err : { kind: uint64, type: string?, value: <encoded>?, text: string }
```

`err.kind`:

| value | meaning |
|---|---|
| 0 | target threw |
| 1 | encoding the result failed |
| 2 | no actor for the given key |
| 3 | peer requirement not satisfied |
| 4 | session is not accepting inbound invocations |
| 5 | request could not be decoded |

### Notification body

Notifications are one-way and carry no envelope `seq`; the request they refer to is named in the
body. The body field is deliberately **not** called `seq`, so that "the envelope's `seq`" and "the
request a notification refers to" are never confused in code or in logs.

```
kind       : uint64    0 invocationCancelled, 1 invocationEscalated, 2 responseEscalated
requestSeq : uint64    the request being referred to
priority   : uint64?   TaskPriority raw value; present for kinds 1 and 2
```

### SharedActorKey

An actor reference on the wire is exactly one `SharedActorKey` and nothing else.

| `kind` | payload key | meaning |
|---|---|---|
| 0 | `type` : string (mangled) | the default actor for a type |
| 1 | `name` : string | an actor exported under a name |
| 2 | `id` : uint64 | an actor shared dynamically during a call |

Apple's dump build uses Swift's synthesized enum coding here; its shipping build moved to a
`UInt8` discriminator. We use an explicit discriminator from the start.

## Identity

```swift
struct ActorID: Codable, Hashable { let raw: RawActorID }

enum RawActorID: Hashable {
    case local(Local)     // Local  { systemID: ID64, instanceID: ID64 }
    case remote(Remote)   // Remote { session: Session, key: SharedActorKey }
}
```

`ID64` wraps a `UInt64` drawn from a process-global monotonic atomic counter. It is neither
random nor pid-derived, and it never needs to be unique across processes, because:

**Neither half of a `RawActorID` is transmitted.** `ActorID.encode(to:)` reads the session out of
`encoder.userInfo`, shares the actor into that session, and writes the resulting `SharedActorKey`
into a single-value container. `init(from:)` mirrors it, reconstructing the session from the
decoding context. `systemID` and `instanceID` never leave the process.

Encoding an `ActorID` without a session in `userInfo` is a programmer error and traps.

### Two tables

| table | owner | key | strength |
|---|---|---|---|
| `actorRegistry` | `XPCActorSystem` | `RawActorID.Local` | **weak** |
| `sharedActors` | `Session` | `SharedActorKey` | **strong** |

The system registry is populated by `actorReady` and cleared by `resignID`. It holds weak
references so it never extends an actor's lifetime, and it is keyed by local IDs only — a remote
ID is never looked up, it is resolved into a proxy.

The session table faces the wire and holds strong references: a peer holding a key must not find
the actor gone.

### Sharing an actor

```swift
localInterface.export(actor, asDefaultActorFor: Greeter.self)  // -> .type(mangled)
localInterface.export(actor, asServerActorFor: "primary")      // -> .name("primary")
// passing an actor as an argument or return value -> .dynamic(counter)
```

The first two are pre-agreed coordinates: a remote peer can `import` them into a proxy with no
round trip. The third happens automatically when an actor crosses the wire as a value.

## Session lifecycle

`LocalInterface` and `RemoteInterface` are thin wrappers over the same `Session`, distinguished by
direction. `LocalInterface` exports; `RemoteInterface` imports and calls.

`ActivationToken` closes a race by construction. The listener side creates the session with its
transport inactive, runs the user's per-peer handler, and only opens for inbound traffic once the
handler returns a token:

```swift
try await system.listen(on: .machService("com.example.svc")) { local in
    let token = local.export(MyActor(actorSystem: system), asDefaultActorFor: Greeter.self)
    return ((), token)
}
```

It is structurally impossible for a request to arrive before exports are registered and fail with
"no such actor".

```swift
struct SessionOptions: OptionSet {
    static let receiving  = SessionOptions(rawValue: 1 << 0)  // accept inbound invocations
    static let deferStart = SessionOptions(rawValue: 1 << 1)  // do not auto-activate the transport
}
```

Apple's equivalent has three bits but only ever uses two combinations (`0` for client-only and
`2|4` for bidirectional); the unused bit is dropped.

### Cancellation and timeouts

Cancellation is a notification packet, not a flag, so it can interrupt an in-flight request. When
the calling `Task` is cancelled the caller sends `invocationCancelled(seq)` and the receiver
cancels the corresponding execution `Task`.

**There is no timeout, by decision.** `Task` cancellation is already the correct Swift idiom, and
a caller wrapping a call in a timeout gets cancellation propagated to the peer for free. A
library-level timeout would create a second, competing cancellation path. Apple also has none.

**Having no timeout makes a death channel mandatory.** `RawTransportProtocol.setCancellationHandler`
reports a pipe that died for a reason that did not originate on this side — the peer crashed,
exited, or cancelled. Without it, a request whose peer is gone is indistinguishable from one whose
peer is merely slow, and there is nothing behind it to break the wait. `Transport` installs a
handler that resumes any outstanding `helloWaiter` with a failure and calls
`RequestTable.failAll(with: .transportCancelled)`. It shares a one-shot `cancelled` flag with
`Transport.cancel`, so a local cancel and a remote death cannot both run teardown.

## Invocation coding

```swift
struct InvocationEncoder: DistributedTargetInvocationEncoder {
    typealias SerializationRequirement = Codable
    var generics: [String]
    var arguments: [any Codable]
    var errorType: String?
    var returnType: String?
}
```

Type identity uses the stdlib's `_mangledTypeName(_:)` and `_typeByName(_:)`. Both are wrapped in
a bidirectional cache (`[String: Any.Type]` and `[ObjectIdentifier: String]`) because `_typeByName`
performs a runtime lookup on every call; Apple added the same cache (`SwiftTypeCache`) between the
two builds we can observe.

`InvocationDecoder` consumes arguments positionally from a single `UnkeyedDecodingContainer`; the
container's own cursor is the state, so no index is tracked.

### Error propagation

Apple flattens every thrown error to `"Remote threw \(error), but XPCSystem does not support
propagating errors."` regardless of whether it is `Codable`. Recovering the concrete error is the
main practical benefit of owning the format, so it is in scope, with three tiers:

1. Typed throws where the error type is `Codable` — Swift passes the error type statically to
   `remoteCall(…throwing:…)`, so it round-trips with no registry.
2. Untyped throws where the concrete type was registered via `system.registerError(MyError.self)`
   — round-trips using `err.type` and `err.value`.
3. Otherwise — `err.text` carries the interpolated description, matching Apple.

Tier 3 always applies as a fallback, so an unregistered error is never a failure.

### Non-throwing violation traps

`canThrow` is not on the wire. It is derived on the receiver from whether `errorType` was present
in the request. When a non-throwing target throws and `canThrow` is false, the receiver **traps**,
matching Apple.

This is a deliberate choice to surface contract violations immediately, and it carries a known
risk documented under Security below.

## Backpressure

Backpressure is entirely local, sender-side admission control. It has no wire representation; the
only peer-observable parts of the priority system are `basePriority` in the request body and the
two escalation notifications.

```swift
struct BackpressurePolicy: Hashable {
    var enabled: Bool
    var maxConcurrentRequests: UInt8
    static let disabled = BackpressurePolicy(enabled: false, maxConcurrentRequests: 0)
}
```

`BackpressureManager` keeps a per-`TaskPriority` bucket with an in-flight count and a pending
deque, and classifies each request as `admitted`, `enqueuedAsPending`, or `stale`. When a
higher-priority caller ends up waiting on an already-sent request, an escalation notification asks
the peer to reschedule it.

Because it is local, `BackpressureManager` is a self-contained component tested with no transport
at all.

## Errors

```swift
struct SetupError: Error              // typed throws on connect/activate paths
enum TransportError                   // transportCancelled(String) / taskCancelled  -- local
enum RawTransportError                // rawTransportCancelled(String)               -- local
struct RemoteCallError: Error         // a failure reported by the peer
```

Transport errors never cross the wire; a remote failure always arrives as an `err` reply body.
`RemoteCallError` is where tier-3 error propagation lands — when the concrete type was recovered,
the original error is rethrown instead.

## Security

**Peer requirements are enforced at two levels**, as in Apple's design: once per session, and
optionally per actor. The session-level check is re-evaluated on every inbound request rather than
cached, because a peer's code-signing state is not immutable for the life of a connection.

**Known risk — remotely triggerable trap.** Because `canThrow` is derived from the request's
`errorType` field, a peer that omits `errorType` while invoking a throwing target can crash the
receiving process when that target throws. The receiver cannot close this hole on its own: there
is no way to ask the runtime whether a `RemoteCallTarget` throws without executing it.

The mitigation is peer requirements. A service that accepts only requirement-satisfying peers is
not exposed to this. A service that accepts arbitrary peers is, and the documentation must say so
plainly. This trade was chosen deliberately over replying with an error, to keep contract
violations loud.

## Testing

The `RawTransport` seam removes the usual need for a second process and an installed service.

**Tier 1 — codec golden fixtures.** Pin the encoded form of the envelope and every body type.
A format change breaks these tests, forcing a deliberate decision about whether to bump `version`.
The absence of exactly this test is how Apple's two builds diverged silently.

**Tier 2 — full stack over `InProcessRawTransport`.** `InProcessRawTransport.makePair()` links two
transports and real `distributed actor`s are called across them. This covers cancellation,
backpressure, bidirectional calls, and actor references passed as values. The payload is genuinely
encoded on this path (only header framing is skipped), so serialization bugs are caught here.

**Tier 3 — real XPC in one process.** Stand up an anonymous `XPCListener` and dial its
`XPCEndpoint` from the same process. This exercises `XPCRawTransport` and version negotiation over
real XPC with no installed service. The technique is already proven in this repository's
`Tools/WireProbe`.

**Tier 4 — what cannot be covered.** Peer requirement checks need distinct code signatures and
cannot be genuinely verified in CI. The requirement evaluator is injectable so the wiring is
tested, and the documentation states that real signature enforcement is unverified. No test will
pretend otherwise.

**Known untested after Phase A: the XPC death channel actually firing.** `RawTransportProtocol`
gained `setCancellationHandler` so that a peer which crashes or exits resolves the caller's
outstanding requests — without it, a dead peer is indistinguishable from a slow one and the
caller waits forever, because this protocol has no timeout. `XPCRawTransport` wires it to the
overlay's `cancellationHandler`, and that wiring is type-checked against the real signature, but
only the in-process equivalent is exercised by a test. Killing a peer deterministically needs a
second process, and a flaky tier-3 test is worse than an absent one. Revisit in Phase C, when
`EphemeralService` provides a real child process to kill.

## Deliberate omissions

**The `Direct` invocation path.** Apple's shipping build added `DirectInvocationDecoder` and
`DirectResultHandler` to skip serialization entirely when both peers are in one process. Our
`InProcessRawTransport` already gives us the testability benefit while still encoding payloads, so
`Direct` is purely a performance optimization. It is omitted until there is a workload to measure,
and the layering means adding it later touches nothing above `Session`.

**`ServiceRegistry` and `InProcessService`.** Apple's process-wide service registry lets in-process
peers find each other by name. Not needed for the target use cases; `InProcessRawTransport.makePair()`
covers the testing need.

**`protocolStub`.** Present in the shipping build's `InvocationCodingKeys`, absent from the dump.
Its purpose could not be determined from either source, so it is not reproduced.

## Implementation phases

Three phases, each independently verifiable. Each gets its own implementation plan.

**Phase A — codec and transport.** `Packet`, `Payload`, envelope coding, `RawTransport`,
`InProcessRawTransport`, `XPCRawTransport`, correlation, version negotiation, transport errors.
Imports nothing from `Distributed`. Done when tier-1 golden fixtures and a tier-3 real-XPC
round trip both pass.

**Phase B — session, identity, invocation.** `Session`, `LocalInterface` / `RemoteInterface`,
`ActivationToken`, `ActorID` / `SharedActorKey`, the registries, `InvocationEncoder` /
`InvocationDecoder`, `ResultHandler`, error propagation, cancellation. Done when tier-2 tests call
a real `distributed actor` end to end.

**Phase C — services and backpressure.** `Service`, `EphemeralService`, peer requirement
enforcement, `BackpressureManager`, priority escalation.

Phase A is a verified foundation on its own, which is why it comes first: when Phase B fails, the
failure is unambiguously in Phase B.

## Open questions

- The raw string values of Apple's two `CodingUserInfoKey`s could not be recovered from either
  source. Irrelevant to this design, which defines its own, but recorded because it was searched
  for.
- Whether `XPCDictionary`'s unsigned subscript setter calls `xpc_uint64_create` was inferred, not
  observed. It affects only how we choose to write our own envelope integers, which is settled by
  our golden fixtures regardless.
