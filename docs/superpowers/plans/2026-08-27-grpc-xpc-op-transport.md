# gRPC over XPC — op-based transport with pluggable seams

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended)
> or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. Written for a model with ZERO
> prior context: everything needed is in this file plus the referenced sources.

**Goal:** A gRPC transport whose design centre is gRPC's own **stream-op model**, carried over XPC,
with two explicit seams — the substrate (`MessagePipe`) and the wire encoding (`WireCodec`) — so a
different substrate or encoding could be added later without touching the core.

**Supersedes** `docs/superpowers/plans/2026-08-27-grpc-xpc-http2-transport.md` from its Task 4
onward. That plan's Tasks 1–3 are already implemented, reviewed and **kept** (see “Existing work”).

**Tech Stack:** grpc-swift-2 `2.4.2`, product **`GRPCCore` only** — `grpc-swift-nio-transport` and
NIO in any form are **forbidden by the project owner**. Apple XPC Swift overlay, `XPCDispatchDataBridge`,
Swift 6 language mode.

---

## Why this shape (read before writing code)

gRPC core defines a transport not as HTTP/2 but as a set of **stream operations** on a stream:
`send/recv_initial_metadata`, `send/recv_message` (zero or more), `send/recv_trailing_metadata`
(client-side = half-close; server-side = final status), and `cancel_stream`. gRPC's own in-process
transport is a complete, legitimate transport with no HTTP/2 anywhere. HTTP/2 is one *encoding* of
those ops, not the definition of a transport.

grpc-swift v2's abstraction maps onto that model exactly, which is why the op model is the natural
design centre here:

| gRPC core op | grpc-swift v2 |
|---|---|
| send/recv_initial_metadata | `RPCRequestPart.metadata` / `RPCResponsePart.metadata` |
| send/recv_message | `.message(Bytes)` |
| client send_trailing_metadata (half-close) | `RPCWriter.finish()` on the request stream |
| server send_trailing_metadata (final status) | `RPCResponsePart.status(Status, Metadata)` |
| cancel_stream | `RPCError(code: .cancelled)` / `RPCCancellationHandle` |

**Be honest about what this is.** This design is close to the project's *first* build, which also
carried parts over XPC. Three specific defects are what that build died of, and each is fixed here
by construction — if a task ever reintroduces one, it is a defect, not a preference:

1. **The encoding was an accident.** `XPCFrame` was a Swift `Codable` enum, so the wire was the
   compiler's synthesized shape (`{"message": {"_0": 3, …}}`) — unreadable to anything else, and
   unspecified. Here the encoding is an explicit, documented byte layout behind a `WireCodec` seam.
2. **The op vocabulary was invented.** Frame kinds were named ad hoc. Here they are named after,
   and justified against, gRPC's own op list; anything not in that list needs an argument.
3. **Flow control was improvised.** Reply-as-credit grew a permit-loss race and a peer-controlled
   DoS. Here it is a designed credit policy in the core (byte windows, the same shape HTTP/2 uses
   because that shape is well-tested), substrate-agnostic so it survives a future pipe swap.

## Architecture (single target, seams by protocol + file)

```
      GRPCCore.ClientTransport / ServerTransport      (grpc-swift's contract)
                          ▲
                 RPCTransportCore                      ← knows nothing about XPC or bytes
                   · stream table, id allocation
                   · op sequencing + per-stream state machines
                   · lifecycle: cancel, deadlines, drain, peer death
                   · credit-based flow control policy
                          ▲                    ▲
                 MessagePipe (substrate)   WireCodec (encoding)
                   send / onReceive          encode(op) / decode(blob)
                   onPeerDeath / cancel
                          ▲                    ▲
                     XPCPipe               CompactCodec
                  (the only conformer)   (the only conformer)
```

**Single SwiftPM target** (`GRPCXPCTransport`); the seams are protocols and file boundaries, not
modules — the project owner chose this over splitting a core module out.

**The core must not import `XPC`.** That is the only thing keeping the seam honest without a
separate module: if a task needs an XPC type inside `RPCTransportCore`, the abstraction is wrong and
the task must report it rather than importing.

**No socket pipe is built.** The seam exists so one *could* be; building it is out of scope.

## Existing work: what stays

| File | Status |
|---|---|
| `Sources/GRPCXPCTransport/GRPCDispatchData.swift` (`GRPCSwiftData`) | **Keep, central.** The byte type everywhere. Zero-copy `init(from: xpc_object_t)` and `createXPCRepresentation()` are the ONLY two crossings to libxpc. Its `Codable`/`XPCNativeObject` extension is deleted at the swap. |
| `Sources/GRPCXPCTransport/GRPCWireHeaders.swift` (Task 3) | **Keep, reused.** Metadata ↔ name/value fields, `grpc-timeout`, `grpc-status`/`grpc-message`, `-bin` base64, reserved-name stripping. Encoding-agnostic. **Correction to the superseded plan: `grpc-timeout` rounds UP, never truncates** — truncating tells the server a shorter deadline than the caller asked for, so it can abandon a call the client would still have accepted; grpc-swift's own `Timeout.swift` rounds up for the same reason. |
| `HTTP2Frame.swift`, `HPACKLiteralCodec.swift` (+ their 37 tests) | **DELETE (revised 2026-08-27).** HTTP/2 is not coming, so these are unreachable code — and the module-level `StreamID` they sit beside is what blocked Task 1. The `WireCodec` seam preserves the option; the code stays recoverable from git (dd647c1, 205316c, dbe3edf). `HTTPField` moves to `RPCOp.swift`, since `GRPCWireHeaders` needs it. |
| `XPCFrame.swift`, `StreamChannel.swift`, `XPCOutboundWriter.swift`, `XPCConnection.swift`, `Backpressure.swift`, `GRPCMessageFraming.swift` + their tests | **Legacy.** Stay compiling until the swap task deletes them. |

## Normative op + wire specification

### O1. Ops

```
RPCStreamID = UInt32, client-allocated, odd, monotonically increasing.

Op:
  openStream(streamID, method: String, timeout: Duration?)   // client: initial metadata + path
  metadata(streamID, fields: [HTTPField])                    // leading metadata (either direction)
  message(streamID, payload: GRPCSwiftData)                  // one whole message, already delimited by the op
  halfClose(streamID)                                        // client: no more messages
  status(streamID, code: Int, message: String, trailers: [HTTPField])  // server: final status; terminal
  cancel(streamID, reason: String)                           // either side aborts one stream
  credit(streamID, bytes: UInt32)                            // flow-control replenishment (streamID 0 = connection)
  goAway(lastStreamID: UInt32)                               // drain: no new streams above this id
```

Justification against gRPC's op list — every op maps, and nothing else exists:
`openStream`+`metadata` = send_initial_metadata; `message` = send_message; `halfClose` = client
send_trailing_metadata; `status` = server send_trailing_metadata; `cancel` = cancel_stream;
`credit` and `goAway` are transport-level control, the equivalent of what HTTP/2 spends
WINDOW_UPDATE and GOAWAY on and what gRPC core's docs call "operations like pings and statistics
that shape transport-level characteristics like flow control".

**A `message` op carries one whole message.** Unlike HTTP/2, where DATA frames are arbitrary byte
ranges and gRPC must add its Length-Prefixed-Message envelope to find message boundaries, an op
substrate already delimits. So **the compact codec carries raw message bytes with no LPM prefix**;
LPM belongs to a byte-stream encoding and would be added by a future `HTTP2Codec`. This is the
seam earning its keep — do not add LPM to the compact codec "for standardness".

### O2. Grammar (per stream, enforced by the core's state machine)

- Request direction: `openStream` → `metadata`? → `message`* → `halfClose`. A second `openStream`,
  `metadata` after the first `message`, or anything after `halfClose` is a protocol violation.
- Response direction: `metadata`? → `message`* → `status`. `status` is the single terminator; a
  second terminal, or a `message` after it, is a violation.
- A violation fails **that stream** with `RPCError(code: .internalError, …)` and sends `cancel`;
  it never tears down the connection.
- `cancel` from either side terminates the stream in both directions.
- Ordering: the substrate delivers messages in order, and the core processes them serially per
  connection. There is no sequence number — XPC guarantees ordering, and the Task “XPCPipe”
  pins that with a 10 000-message stress test. If that test ever fails, STOP and report; do not
  silently add sequence numbers.

### O3. Compact wire encoding (the only `WireCodec` conformer)

One XPC message carries **one blob**; a blob carries **one or more encoded ops**, concatenated.
Every op:

```
+--------+--------+--------------------+---------------------+
| kind   | flags  | streamID (4 BE)    | body length (4 BE)  |  10-byte header
+--------+--------+--------------------+---------------------+
| body …                                                     |
+------------------------------------------------------------+
```

`kind`: `openStream=1, metadata=2, message=3, halfClose=4, status=5, cancel=6, credit=7, goAway=8`.
`flags`: reserved, MUST be 0 on send, ignored on receive. Unknown `kind` values are **skipped**
(body length lets a reader advance past an op it does not understand) — this is what lets the
encoding grow without breaking older peers.

Bodies:
- `openStream`: field list (below) containing `:path` and, if set, `grpc-timeout` — built by
  `GRPCWireHeaders.request(...)`.
- `metadata` / `status`: a field list. For `status`, the list includes `grpc-status` and, when
  non-empty, `grpc-message`, per `GRPCWireHeaders.trailers(...)`.
- `message`: the raw message bytes.
- `halfClose` / `goAway`: empty, except `goAway` carries a 4-byte last-stream-id.
- `cancel`: UTF-8 reason.
- `credit`: 4-byte byte-count.

**Field list** (used by `openStream`, `metadata`, `status`): a 2-byte BE count, then per field a
2-byte BE name length, name UTF-8, 4-byte BE value length, value UTF-8. Names are already lowercased
and reserved-name-filtered by `GRPCWireHeaders`; `-bin` values are already base64 there, so the
codec never interprets a value.

Max blob size is not fixed; a single op body above **16 MiB** is rejected as a protocol error
(a bound on peer-controlled allocation, not a protocol feature).

### O4. Flow control

Byte-based credit, initial window **65 535** per stream and per connection, exactly HTTP/2's
defaults — not because we are HTTP/2 but because those numbers and that shape are well-tested.

- Only `message` bodies consume window (both the stream's and the connection's). Control ops —
  `metadata`, `halfClose`, `status`, `cancel`, `credit`, `goAway` — are never flow-controlled, so a
  terminal op can never be starved by a stalled window.
- Sender: reserve from the stream window then the connection window (always that order, so two
  streams cannot deadlock each other); suspend when either is exhausted.
- Receiver: replenish **on consumption** — when a message is delivered to the application's async
  iterator, credit its charge on both the stream and the connection. Credits are **batched**: the
  receiver accumulates and emits a `credit` op only once the accumulation reaches half the initial
  window, so a stream of small messages does not produce one control op each.
- **A message's charge is `min(payload.count, 65_535)`, not its length.** Both sides compute it
  from the payload length, which both sides know, so it needs no negotiation and no protocol
  change. Without this clamp an oversize message deadlocks: `message` op bodies are atomic (O2 has
  no chunking), so a sender reserving partially would take the whole window, block, and wait on a
  receiver that cannot credit a message it has not finished receiving and therefore cannot deliver.
  With it, no message can charge more than the window it must fit in, and an oversize message
  serializes the **connection**, not merely its own stream: 65 535 is the whole connection window
  too, so every other stream's `message` waits behind it until the receiving application consumes.
  That is head-of-line blocking, not deadlock — the stream-then-connection order above makes two
  concurrent oversize senders queue on the connection window's FIFO rather than hold-and-wait — and
  it is exactly as much backpressure as chunking with consumption-credit could give. Size retries
  and timeouts against the connection, not the stream.
- The clamp has **one definition**, `FlowControl.charge(for:window:)`. Send side and receive side
  both call it. Two hand-inlined `min`s that must agree forever is the shape of bug the charge rule
  was introduced to prevent.
- A credit that would take a window above 2³¹−1 is a protocol error. Applying credit is **O(1)
  arithmetic** — never a loop over a peer-supplied count (see lesson L2).
- A reservation is **spent, not lent**. A sender that reserves and then does not send must hand the
  bytes back with `release(_:)`, which is not `grant`: those bytes were already inside the window,
  so they cannot breach the ceiling and must not be validated against the peer's contract. `fail`
  is for a window that is actually dead — never for a stranded reservation, since failing the
  *connection* window because one stream's send failed would kill every other stream on it.

### O5. Deviations, complete list

1. No connection handshake: XPC session establishment is it. Windows are fixed at the defaults and
   never negotiated.
2. No message-level standard framing (no LPM) in the compact codec — see O1's rationale.
3. `cancel` carries a human-readable reason rather than a numeric code; the core maps it to
   `RPCError(code: .cancelled)`.
4. No compression, no message-size limits in v1.
5. Credit is batched at half the initial window rather than emitted per message, and an oversize
   message is charged the window rather than its length — both in O4, both consequences of O2's
   atomic `message` bodies.

---

## Verified API facts (pinned — do not re-derive, do not guess)

### grpc-swift-2 2.4.2 (`GRPCCore`)

```swift
public protocol ClientTransport<Bytes>: Sendable {
  associatedtype Bytes: GRPCContiguousBytes & Sendable
  typealias Inbound  = RPCAsyncSequence<RPCResponsePart<Bytes>, any Error>
  typealias Outbound = RPCWriter<RPCRequestPart<Bytes>>.Closable
  var retryThrottle: RetryThrottle? { get }
  func connect() async throws                 // runs for the transport's lifetime
  func beginGracefulShutdown()
  func withStream<T: Sendable>(descriptor: MethodDescriptor, options: CallOptions,
    _ closure: (RPCStream<Inbound, Outbound>, ClientContext) async throws -> T) async throws -> T
  func config(forMethod: MethodDescriptor) -> MethodConfig?     // nil is fine
}
public protocol ServerTransport<Bytes>: Sendable {
  associatedtype Bytes: GRPCContiguousBytes & Sendable
  typealias Inbound  = RPCAsyncSequence<RPCRequestPart<Bytes>, any Error>
  typealias Outbound = RPCWriter<RPCResponsePart<Bytes>>.Closable
  func listen(streamHandler: @escaping @Sendable
    (RPCStream<Inbound, Outbound>, ServerContext) async -> Void) async throws
  func beginGracefulShutdown()
  // configure(context:) exists (2.3+) with a default no-op impl — not required.
}
public enum RPCRequestPart<Bytes>  { case metadata(Metadata); case message(Bytes) }
public enum RPCResponsePart<Bytes> { case metadata(Metadata); case message(Bytes)
                                     case status(Status, Metadata) }   // exactly one, terminal
```

- `RPCStream { descriptor; inbound; outbound }`; `RPCAsyncSequence(wrapping:)`;
  `RPCWriter.Closable(wrapping: some ClosableRPCWriterProtocol<Element>)`;
  `ClosableRPCWriterProtocol` = `write(_:)`, `write(contentsOf:)`, `finish()`, `finish(throwing:)`,
  all `async`.
- `Metadata`: ordered multi-map; `addString(_:forKey:)`, `addBinary(_:forKey:)` — **`addBinary`
  asserts the key ends `-bin`** (it traps, it does not throw); element `(key: String, value: Value)`
  with `Value = .string(String) | .binary([UInt8])`; `[stringValues:]` / `[binaryValues:]`;
  case-insensitive lookup.
- `Status(code:message:)`; `Status.Code(rawValue: Int)` failable; `.ok`, `.cancelled`,
  `.deadlineExceeded`, `.unavailable`, `.internalError`, `.unimplemented`, …
  `RPCError(code:message:metadata:cause:)`.
- `MethodDescriptor` has **no** `init(fullyQualifiedMethod:)` — only
  `init(fullyQualifiedService:method:)` / `init(service:method:)`; read `fullyQualifiedMethod`
  ("pkg.Service/Method", no leading slash).
- `ClientContext(descriptor:remotePeer:localPeer:)`.
  `ServerContext(descriptor:remotePeer:localPeer:cancellation:)`; `RPCCancellationHandle` has no
  public init — obtain it via `withServerContextRPCCancellationHandle { handle in … }` and keep it
  registered so drain/cancel/peer-death can `cancel()` it. Reference shape:
  `GRPCInProcessTransport/InProcessTransport+Server.swift` in the resolved checkout.
- `CallOptions.defaults`, `CallOptions.timeout: Duration?`.
- **Cancellation contracts (verified in source):** `GRPCClient.runConnections()` and
  `GRPCServer.serve()` both document “cancel the task” as the sanctioned abrupt stop and wrap any
  thrown error as a transport failure ⇒ `connect()` and `listen()` must return **normally** (not
  throw) when their own task is cancelled.

### XPC overlay + platform

- Read `Sources/XPCActors/XPCRawTransport.swift` — the repo's reviewed reference for anonymous
  `XPCListener` accept, `XPCSession(endpoint:)` dialing with `options: .inactive`, target queues,
  and cancellation handlers.
- **Lifecycle traps (measured):** cancelling a never-activated `XPCSession` traps in libxpc, and so
  does releasing an activated-but-uncancelled one. Track activation: accepted (server) sessions are
  already live and must NOT be re-activated; client sessions are created inactive and activated
  exactly once by a factory that constructs-and-activates; `deinit` cancels only when activated.
- **Zero-copy facts (measured, already implemented and pinned in `GRPCDispatchData.swift` +
  `GRPCSwiftDataTests.swift` — keep them):** `GRPCSwiftData.init(from: xpc_object_t)` wraps the
  buffer via `DispatchData(bytesNoCopy:)` with a deallocator holding the xpc object alive; `Data`
  keeps values **≤ 14 bytes inline** (copies) and only references the buffer at **≥ 15 bytes**;
  `xpc_data_get_bytes_ptr` can return NULL (non-contiguous) → copy fallback.
- **`GRPCSwiftData` indices do NOT rebase to zero.** A sliced value starts at its parent's offset;
  every offset must derive from `startIndex`, never a literal `0`. Both existing codecs have
  regression tests pinning this — write your decoders the same way.

## Lessons from the previous builds (each cost a reproduced bug — treat as MUSTs)

- **L1 — wakeup race:** when a suspended writer wakes, check **granted BEFORE cancelled**. The old
  credit window checked cancelled first; a grant racing a cancellation leaked the permit
  permanently (measured 1–14 lost per 3 000 races → window reached zero → stream stalled forever).
- **L2 — peer-controlled arithmetic is O(1) or it is a DoS.** The old code looped `0..<n` on a
  peer-supplied count: one `release(UInt32.max)` measured **450 s inside a mutex**, blocking the
  whole connection. Clamp and add.
- **L3 — handler completion tears the stream down.** When a server's `streamHandler` returns,
  remove the stream and release its windows (sending `cancel` if it did not terminate cleanly). The
  old build left state behind and an early-returning handler stranded the peer's writer forever
  (measured: 33 of 200 sent, then permanent hang).
- **L4 — serial routing.** All inbound decoding and routing for a connection runs on the pipe's
  serial queue; per-stream state machines assume it. Document the precondition where it is relied on.
- **L5 — one-phase accept.** The server's accepted-stream sequence yields a **fully built** stream.
  The old two-phase register-later design produced, in sequence: dropped frames, a table leak, then
  silent data loss. Never reintroduce a pending table.
- **L6 — ownership.** Outbound writers hold the connection **weakly** (a strong reference through
  the accepted-streams buffer made the connection immortal and leaked the XPC session). Whoever
  creates streams keeps the connection alive; a write after the connection is gone throws
  `RPCError(.unavailable)`; connection `deinit` fails all streams, or a stream outliving its
  connection hangs forever on inbound. Prove `deinit` reachability with a weak-reference test.
- **L7 — transport lifecycle machines.** `connect()`/`listen()` need explicit
  idle → running → shutDown states under one lock: a second concurrent call is refused
  deterministically (the old single-continuation slot leaked one — the runtime printed SWIFT TASK
  CONTINUATION MISUSE); a call after shutdown returns immediately; double shutdown resumes at most
  once; task cancellation unblocks and returns normally. Take-and-transition atomically under the
  lock; resume continuations OUTSIDE it.
- **L8 — bounded tests, always** (for the later test task): run the call on its own `Task`,
  accumulate in a task-local `var`, write once into a `Mutex<T?>`, fulfil an `XCTestExpectation`,
  and `await fulfillment(of:, timeout: 5)` before reading. An unbounded streaming test hangs the
  suite with no diagnosis — it happened twice.
- **L9 — tests must discriminate.** Mutate the behaviour and confirm the test fails before trusting
  it. "No copy" is proven by comparing base addresses (minding the 14-byte inline threshold);
  "suspends" by asserting the exact in-flight bound; "ok status" by sending a non-ok one.
- **L10 — repo hygiene.** Unrelated user WIP lives in the tree (`Sources/XPCActors/Packet.swift`,
  `Sources/XPCCompat/Conformances.swift`, `Sources/XPCDispatchDataBridge/DispatchDataBridge.swift`,
  `.swiftpm/**/*.xcscheme`). **Never `git add -A` / `git add .`.**
- **L11 — build discipline.** Build/test only with an explicit `--scratch-path`, never the default
  build dir. Every task ends with `swift build` and `swift build --build-tests` green.
- **L12 — deadline timers must not leak:** one per deadline-bearing RPC, cancelled on completion.

## Test policy (project owner directive)

**Tasks implement production code only.** Test files and TDD steps are deferred to the final test
task. A task is done when it compiles clean and satisfies its contract by inspection.

- `swift build` and `swift build --build-tests` stay green at every commit; the existing suites
  (Task 1's 17 HTTP2Frame tests, Task 2's 20 HPACK tests, `GRPCSwiftDataTests`, and the legacy
  suite until the swap) must keep passing.
- **Every task report ends with a “Deferred tests” section** listing the cases that task would have
  written, plus any case discovered while implementing. That list is the backlog the test task
  consumes; an unwritten case is a lost case.

## File map

**Create:** `RPCOp.swift` (op model + `WireCodec`/`MessagePipe` protocol seams),
`CompactWireCodec.swift`, `FlowControl.swift`, `StreamStateMachines.swift`,
`XPCPipe.swift`, `RPCTransportCore.swift`.
**Rewrite at the swap:** `XPCClientTransport.swift`, `XPCServerTransport.swift`.
**Delete at the swap:** `XPCFrame.swift`, `StreamChannel.swift`, `XPCOutboundWriter.swift`,
`XPCConnection.swift`, `Backpressure.swift`, `GRPCMessageFraming.swift` and their tests; the
`Codable`/`XPCNativeObject` extension in `GRPCDispatchData.swift`; the `CodableXPC` dependency of
the target in `Package.swift` (add `XPCDispatchDataBridge` as a direct dependency).

## Global Constraints

- `@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)` on every public type.
- Swift 6 language mode, strict-concurrency clean, **zero warnings**.
- `Bytes = GRPCSwiftData` throughout; **never `Codable`**, never `CodableXPC`. `GRPCSwiftData`
  crosses to libxpc through exactly `init(from:)` and `createXPCRepresentation()`.
- Dependencies of the target: `GRPCCore` + `XPCDispatchDataBridge`. **NIO is forbidden.**
- `RPCTransportCore` and the codec **must not import `XPC`**. If a task needs to, report it.
- Build/test only with `--scratch-path <scratch>/build`.
- Lessons L1–L12 bind every task.

---

### Task 1: Op model and the two seams

**Files:** create `Sources/GRPCXPCTransport/RPCOp.swift`.

Define, per §O1: `HTTPField`, `RPCStreamID` (`UInt32` — **not** `StreamID`, which the legacy stack still owns until the swap), `RPCOp` (an enum of the eight ops — this one *is* a sum type, because an op stream
genuinely is a tagged union and the alternative is a struct with seven optional fields), `StreamID`,
and the two protocols:

```swift
protocol WireCodec: Sendable {
    func encode(_ ops: [RPCOp]) throws -> GRPCSwiftData
    func decode(_ blob: GRPCSwiftData) throws -> [RPCOp]
}
protocol MessagePipe: Sendable {
    var queue: DispatchSerialQueue { get }              // all delivery is serial on this
    func send(_ blob: GRPCSwiftData) throws
    func onReceive(_ handler: @escaping @Sendable (GRPCSwiftData) -> Void)   // set once, pre-activation
    func onPeerDeath(_ handler: @escaping @Sendable () -> Void)
    func cancel()
}
```

Document on `MessagePipe` that a conformer MUST deliver blobs in send order and MUST call handlers
on `queue`; the core's correctness rests on it (L4), and a substrate that cannot promise ordering
needs a sequencing adapter, not a weakened core.

- [ ] Write the file; `swift build` + `--build-tests` green; commit
  `feat(GRPCXPCTransport): gRPC stream-op model and the substrate/encoding seams`.
- [ ] Report the exact declarations (later tasks are written against them) + Deferred tests.

### Task 2: `CompactWireCodec`

**Files:** create `Sources/GRPCXPCTransport/CompactWireCodec.swift`.

Implement §O3 exactly: the 10-byte op header, the field-list format, the per-kind bodies, unknown-
kind skipping via the body length, and the 16 MiB body cap. Reuse `GRPCWireHeaders` for building and
parsing field lists (it already handles `-bin`, `grpc-timeout`, `grpc-status`/`grpc-message`,
reserved names) and `HTTPField` from `RPCOp.swift` as the field type.

Do **not** add LPM framing (§O1). Decode must never trust a length: every length is checked against
the remaining buffer before slicing, and every offset derives from `startIndex` (indices do not
rebase). Throw `RPCError(code: .internalError, …)` naming the offending value.

- [ ] Implement; build green; commit `feat(GRPCXPCTransport): compact op wire codec`.
- [ ] Report the byte layout you implemented, hand-walked for one op of each kind + Deferred tests.

### Task 3: Flow control

**Files:** create `Sources/GRPCXPCTransport/FlowControl.swift`.

```swift
final class FlowControlWindow: Sendable {          // sender side; one per stream + one per connection
    init(initial: Int)                              // 65_535
    func reserve(upTo requested: Int) async throws -> Int   // ≥1, suspends while empty
    func grant(_ bytes: UInt32) throws              // O(1); throws if total > 2^31-1
    func fail(_ error: any Error)                   // wakes all waiters
    var available: Int { get }
}
struct WindowAccountant {                           // receiver side
    init(initial: Int)
    mutating func consumed(_ bytes: Int) -> UInt32? // credit to send now
}
```

**L1 is the whole point of this file:** a waiter woken by `grant` must consume its reservation even
if its task was cancelled in the same instant — check granted **before** cancelled, never drop a
grant. **L2:** `grant` is arithmetic, never a loop. Resume continuations outside the lock (L7).

- [ ] Implement; build green; commit `feat(GRPCXPCTransport): credit-based flow-control windows`.
- [ ] Report the state machine and how L1/L2 are structurally prevented + Deferred tests.

### Task 4: Per-stream state machines

**Files:** create `Sources/GRPCXPCTransport/StreamStateMachines.swift`.

Four explicit types (no generic factories — a previous build's generic spelling fought type
inference): `RequestOpDecoder` (ops → `RPCRequestPart`, plus a `remoteEnded` signal on `halfClose`),
`ResponseOpDecoder` (ops → `RPCResponsePart`; the `.status` part is itself the terminal signal, so
no extra flag), `RequestOpEncoder` (parts → ops, emitting `openStream` first and `halfClose` on
finish), `ResponseOpEncoder` (parts → ops, synthesising empty initial metadata if a message is
written before any metadata).

Enforce §O2's grammar; a violation throws `RPCError(code: .internalError, …)`. Document that
`accept` is serial-per-stream (L4).

- [ ] Implement; build green; commit `feat(GRPCXPCTransport): per-stream op state machines`.
- [ ] Report the four types' exact signatures + the grammar table + Deferred tests.

### Task 5: `XPCPipe`

**Files:** create `Sources/GRPCXPCTransport/XPCPipe.swift`.

The only `MessagePipe` conformer. One `XPCSession`; blobs ride as a dictionary `{"b": xpc_data}`;
outbound uses `blob.createXPCRepresentation()` and inbound wraps with `GRPCSwiftData(from:)` — the
only two libxpc crossings. Port the accept/dial recipes and the activation-tracking rules from
`Sources/XPCActors/XPCRawTransport.swift` and the legacy `XPCConnection.swift` (both reviewed):
anonymous `XPCListener`, publish-before-return at accept time, `deinit` cancels only if activated.

- [ ] Implement; build green; commit `feat(GRPCXPCTransport): XPCPipe substrate`.
- [ ] Report the working accept/dial recipe (later tasks and the test task depend on it) + Deferred
  tests, which MUST include the 10 000-blob ordering stress test that licenses having no sequence
  numbers (§O2).

### Task 6: `RPCTransportCore`

**Files:** create `Sources/GRPCXPCTransport/RPCTransportCore.swift`.

The mux. Holds a `MessagePipe` and a `WireCodec` and **must not import `XPC`**.

Contract (each line is a later test):
1. Inbound blobs decode on the pipe's queue; ops route by stream id to the per-stream machines; a
   machine's throw fails that stream and sends `cancel` — never `try?`-swallowed, never a
   connection teardown.
2. `openStream` for an unknown odd id (server role) builds decoder + writer + `RPCStream` and yields
   a **fully built** `AcceptedStream { id, descriptor, timeout, stream }` in the same routing turn (L5).
3. `credit` routes to the matching window (stream, or connection for id 0); an overflowing credit is
   a protocol error that fails the connection.
4. Outbound `message`: reserve stream window then connection window, then encode and send. Control
   ops bypass flow control entirely.
5. Inbound `message` delivery: on consumption, `WindowAccountant` emits `credit` for stream and
   connection.
6. `cancel` inbound fails that stream with `RPCError(.cancelled)` and removes it.
7. A stream leaves the table when both directions are done, or on cancel — no entry outlives its
   stream (the old build leaked one per RPC).
8. `goAway` inbound marks draining; opening a new stream then throws `RPCError(.unavailable)`.
9. Peer death fails all streams with `RPCError(.unavailable)`, waking every parked window waiter.
10. Writers hold the core weakly; a write after it is gone throws `.unavailable`; `deinit` fails all
    streams and finishes the accepted-stream sequence (L6).

- [ ] Implement; build green; commit `feat(GRPCXPCTransport): op-based transport core`.
- [ ] Report the public surface for the transports + Deferred tests covering all ten lines.

### Task 7: Transports + swap out the legacy stack

**Files:** rewrite `XPCClientTransport.swift`, `XPCServerTransport.swift`; modify `Package.swift`
and `GRPCDispatchData.swift`; delete the legacy files and tests listed in the File map.

- Lifecycle machines per L7 (port the shapes from the current, reviewed transports).
- Client `withStream`: allocate the stream, start a deadline timer when `CallOptions.timeout` is set
  (timer → `cancel` op + local `.deadlineExceeded`; cancel the timer on completion — L12); on
  closure exit send `cancel` if the stream did not terminate cleanly.
- Server `listen`: drain accepted streams; build `ServerContext` via
  `withServerContextRPCCancellationHandle`, register the handle so drain/cancel/peer-death can fire
  it; run handler-completion cleanup when the handler returns (L3).
- `beginGracefulShutdown`: send `goAway`, refuse new streams, let in-flight finish, release
  `connect()`/`listen()`.
- Port the legacy call-type and lifecycle tests to the new seam **or**, if the test policy still
  defers them, move their intent into the Deferred-tests backlog and delete the files with the
  legacy stack — say which you did and why.

- [ ] Implement; `swift build`, `--build-tests`, and `swift test` green (the surviving suites must
  pass); commit `feat(GRPCXPCTransport)!: op-based transports; delete the custom-protocol stack`.

### Task 8: The deferred test suite

**Files:** create the test files the earlier tasks deferred.

Consume every "Deferred tests" section from Tasks 1–7's reports (in
`.superpowers/sdd/2026-08-27-grpc-xpc-op-transport/`), plus the four call types end to end over two
real XPC sessions, backpressure (a gated reader bounds the writer's in-flight bytes), cancellation,
deadlines, graceful shutdown and peer death. Every test bounded (L8) and discriminating (L9).

- [ ] Implement; full suite green; commit `test(GRPCXPCTransport): the deferred suite`.
