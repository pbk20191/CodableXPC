# gRPC over XPC — design

> **PARTIALLY SUPERSEDED (2026-08-27):** the wire format, backpressure and
> lifecycle sections (§4–§8, deviations D1–D6) are superseded by the normative wire
> specification embedded in `docs/superpowers/plans/2026-08-27-grpc-xpc-http2-transport.md`
> (binary HTTP/2 frames over XPC). §1–§3 (goals, GRPCCore contract, packaging) still apply.

**Status:** design, awaiting review. **Branch:** `feature/grpc-over-xpc`.
**Date:** 2026-08-19.

## 1. Goal and non-goals

Implement grpc-swift v2's transport abstraction over Apple's `XPCSession` /
`XPCListener` overlay, so that a standard grpc-swift service (protoc-generated,
protobuf messages, all four call types) runs with its RPC bytes carried by XPC
instead of HTTP/2 over TCP.

We implement the two transport protocols and nothing above them:

- `GRPCCore.ClientTransport` → `XPCClientTransport`
- `GRPCCore.ServerTransport` → `XPCServerTransport`

**Non-goals.** No code generation (standard `protoc` + the grpc-swift plugin is
used unchanged). No HTTP/2, no NIO. No protobuf handling in the transport — the
transport frames opaque `[UInt8]` payloads; (de)serialization stays in the
generated stubs. No change to the existing dependency-free targets.

**Scope of first milestone.** A complete client+server transport pair that
inherently supports all four call types (unary, client-streaming,
server-streaming, bidirectional), verified end-to-end in-process. Lightweight
backpressure is in scope from the start (section 6); precise per-stream flow
control is deferred (section 6, deviation D3).

## 2. Background: the grpc-swift v2 transport contract (verified against tag 2.4.1)

Verified from `github.com/grpc/grpc-swift-2` at tag `2.4.1`. The transport moves
**typed RPC parts**, not HTTP/2 frames — the same abstraction the in-process
transport uses with no sockets.

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
  func config(forMethod: MethodDescriptor) -> MethodConfig?
}

public protocol ServerTransport<Bytes>: Sendable {
  associatedtype Bytes: GRPCContiguousBytes & Sendable
  typealias Inbound  = RPCAsyncSequence<RPCRequestPart<Bytes>, any Error>
  typealias Outbound = RPCWriter<RPCResponsePart<Bytes>>.Closable
  @available(gRPCSwift 2.3, *) func configure(context: GRPCServerContext)   // default impl exists
  func listen(streamHandler: @escaping @Sendable
    (RPCStream<Inbound, Outbound>, ServerContext) async -> Void) async throws
  func beginGracefulShutdown()
}
```

The parts carried on each stream:

```swift
public enum RPCRequestPart<Bytes: GRPCContiguousBytes>  { case metadata(Metadata); case message(Bytes) }
public enum RPCResponsePart<Bytes: GRPCContiguousBytes> { case metadata(Metadata); case message(Bytes)
                                                          case status(Status, Metadata) }   // exactly one, terminal
```

Supporting shapes we serialize onto the wire:

- `MethodDescriptor.fullyQualifiedMethod: String` (`"pkg.Service/Method"`).
- `Metadata`: ordered `(key: String, value: .string(String) | .binary([UInt8]))`, multi-value per key.
- `Status`: `code: Int` (0–16) + `message: String`; trailers are the `Metadata` in `.status`.
- `Bytes = [UInt8]` (`[UInt8]` already conforms to `GRPCContiguousBytes`).
- `ServerContext.transportSpecific: (any TransportSpecific)?` — our hook to attach the XPC peer's audit token / `PeerAttestation`.

**Reference implementation.** `Sources/GRPCInProcessTransport/` pairs two
`GRPCAsyncThrowingStream`s cross-wired (client-out → server-in,
server-out → client-in). Our transport replaces those two in-memory streams with
XPC message pipes on each side; the cross-wiring is identical.

**Hard parts over a message substrate (from the verified contract):**
1. Backpressure — `RPCWriter.write(_:) async throws` must suspend until accepted; no window API (section 6).
2. `connect()` lifecycle — blocks for the connection's life; `withStream` waits for connectivity (section 5).
3. Graceful shutdown — GOAWAY-like: drain in-flight, refuse new (section 5).
4. Per-stream ordering + exactly-one-terminal-`.status` over unordered messages (section 7).
5. Deadlines (`CallOptions.timeout`) and cancellation (`ServerContext.cancellation`) (section 5).
6. `retryThrottle`/`config(forMethod:)` may return `nil` initially. Message-size limits and compression are optional; XPC already frames messages, so no length-delimiting is needed.

## 3. Packaging and availability

- New SwiftPM dependency, **isolated to one new target**: `.package(url:
  "https://github.com/grpc/grpc-swift-2.git", from: "2.4.1")`, product `GRPCCore`.
- New product + target **`GRPCXPCTransport`**, dependencies: `GRPCCore` + `CodableXPC`
  (xpc↔Codable and zero-copy `Data`/`xpc_data`). It does **not** depend on
  `XPCActors` (macOS 26, distributed-actor specific).
- Test target `GRPCXPCTransportTests` also depends on `GRPCInProcessTransport`
  (reference) and the generated echo stubs.
- Availability floor: **macOS 15 / iOS 18 / watchOS 11 / tvOS 18 / visionOS 2**
  (grpc-swift v2's `@available(gRPCSwift 2.0, *)`). XPCSession is 14+; grpc is the
  binding floor. The `GRPCXPCTransport` target adopts the Swift 6 language mode
  (grpc-swift is v6-only), consistent with the XPCActors precedent.
- Existing targets are untouched and stay dependency-free.

## 4. Architecture

```
 generated stubs (protoc)                        generated service (protoc)
        │  GRPCClient                                    │  GRPCServer
        ▼                                                ▼
 XPCClientTransport ── XPCConnection ──[ XPCSession ]── XPCConnection ── XPCServerTransport
        (ClientTransport)   │  stream mux                 │  stream mux   (ServerTransport)
                            └── per-stream part channels ─┘
```

- **`XPCConnection`** — wraps one `XPCSession`. Owns the stream-multiplexing table
  `[StreamID: StreamChannel]`, the inbound demux (routes each inbound `XPCFrame` to
  its stream), the outbound send path, and the connection lifecycle
  (unconnected → connected → draining → closed). Shared by both sides; the only
  asymmetry is who allocates `StreamID`s (client) and who accepts new streams
  (server). It adopts `ActorBackedByDispatchSerialQueue` (section 6) so its
  isolation *is* the XPCSession target queue.
- **`XPCClientTransport: ClientTransport`** — `connect()` activates the session and
  blocks until shutdown; `withStream` allocates a `StreamID`, sends an `openStream`
  frame, builds an `RPCStream` whose `Outbound` writes push request-part frames and
  whose `Inbound` is an `RPCAsyncSequence` fed by the demux.
- **`XPCServerTransport: ServerTransport`** — `listen` starts an `XPCListener`; each
  accepted session becomes an `XPCConnection`; an inbound `openStream` frame creates
  a server-side `RPCStream` and yields `(stream, ServerContext)` to the
  `streamHandler`.
- **`XPCFrame`** — the on-the-wire unit (section 5), encoded to an xpc dictionary.
- **`StreamChannel`** — per-stream state: the inbound `AsyncThrowingStream`
  continuation the demux writes into, the outbound credit state (section 6), the
  half-close/terminal flags, and the ordering guard (section 7).

Each unit has one purpose and a narrow interface: `XPCFrame` is pure
(de)serialization; `StreamChannel` holds one stream's state; `XPCConnection` owns
mux + lifecycle; the two transports are thin adapters from GRPCCore's protocols to
`XPCConnection`.

## 5. Wire protocol over XPCSession

One `XPCSession` = one connection, carrying many concurrent RPCs multiplexed by a
client-allocated monotonic `StreamID` (`UInt64`) — the same correlation pattern as
the reconstructed actor transport's `headerID`. Every packet is one `XPCSession`
message; a message is one `XPCFrame`:

| kind | fields |
|------|--------|
| `openStream` | `streamID`, `fullyQualifiedMethod: String`, `deadline?` |
| `metadata`   | `streamID`, `Metadata` |
| `message`    | `streamID`, `seq: UInt64`, bytes → **`xpc_data` (zero-copy via CodableXPC)** |
| `halfClose`  | `streamID` — the sender has finished its half (`RPCWriter.finish()`) |
| `status`     | `streamID`, `code: Int`, `message: String`, trailers `Metadata` — server terminal |
| `cancel`     | `streamID`, reason — either side aborts a stream |
| `credit`     | `streamID`, `n: UInt32` — explicit flow-control credit; **fallback path only** (section 6 uses reply-as-credit; this frame is used iff `handoffReply` cannot carry credit, risk 11) |
| `goAway`     | connection draining (graceful shutdown) |

Encoding: `XPCFrame` maps to an xpc dictionary; only `message` bytes ride as
`xpc_data`, everything else is small scalar/array fields. `Metadata` serializes as
a list of `(key, tag, bytes)` triples where `tag` distinguishes `.string`/`.binary`.

Sends are one-way `XPCSession.send(message:)`; the XPC **reply channel is reserved
for flow-control credit only** (section 6), not for RPC correlation — correlation
lives in `streamID`, so either side may originate a stream (bidi symmetry).

## 6. Backpressure (lightweight, XPC-native)

`RPCWriter.write(_:) async throws` must suspend until the peer accepts the element.
We realize this with **reply-as-credit**, deferred by `handoffReply`:

- **Verified hook.** `XPCReceivedMessage.handoffReply(to queue: DispatchQueue, _
  produceReply: @escaping () -> (any Encodable)?)` (macOS 14+) defers producing a
  message's reply onto a queue we own. The reply is the flow-control credit.
- **Write side.** `outbound.write(part)` serializes the part, sends it as an
  XPC message-expecting-reply, and **awaits the reply**. `write` returns when the
  credit reply arrives — this is precisely the "suspend until accepted" contract.
- **Read side.** On receiving a `message` frame we call `handoffReply(to:
  streamQueue)`; the credit reply is produced **when the stream's consumer has room**
  (i.e. when the `RPCAsyncSequence` reader pulls the next element). A slow reader
  therefore withholds credit and the writer's `write` stays suspended.
- **Executor unification.** `XPCConnection` (and each `StreamChannel`) adopts
  `ActorBackedByDispatchSerialQueue` (the protocol added on `master`), so its actor
  isolation *is* the XPCSession target queue. The `streamQueue` handed to
  `handoffReply` is that same serial executor — one queue serializes delivery,
  actor state, and credit production.
- **Coarse valve.** `dispatch_suspend`/`resume` on that queue is an optional
  connection-level override (pause all delivery under memory pressure). The primary,
  precise mechanism is per-consumer credit above; suspend/resume is a blunt backstop.

**Correctness constraints (load-bearing, enforced in code and tests):**

- **C1 — suspend/resume balance.** Over-`resume` traps (`EXC_BAD_INSTRUCTION`). A
  guarded state machine (an explicit `enum running/suspended` under a lock, never a
  raw counter) gates every suspend/resume; the coarse valve is off by default.
- **C2 — never suspend a queue from within itself.** Code isolated to the executor
  must not suspend that executor and expect to resume it; resume is always driven
  from outside the suspended queue. `ActorBackedByDispatchSerialQueue` makes this
  mistake easy, so the valve controller lives off-actor.
- **C3 — granularity is connection-near, not per-stream.** XPC flow control is a
  function of outstanding replies on the connection; withholding one stream's credits
  reduces the shared window, so streams are not fully independent (deviation D3).
  Acceptable for v1; true per-stream windows are a follow-up.
- **C4 — bidi symmetry.** Both directions originate messages-with-reply, the opposite
  of the actor reconstruction's one-way choice. `XPCSession.send(_:replyHandler:)`
  works in both directions; an in-process test pins that credit flows service→client
  as well as client→service.

## 7. Ordering and the exactly-one-status invariant

The response stream must deliver at most one leading `.metadata`, then zero+
`.message`, then exactly one terminal `.status` — over XPC messages that are not
guaranteed mutually ordered. Guards:

- A per-stream `seq: UInt64` on `message` frames; `StreamChannel` delivers in `seq`
  order (a small reorder buffer; in practice one serial session queue preserves
  order, and the seq is the assertion that it did).
- `StreamChannel` is a state machine: `open → (metadata?) → messages → terminal`.
  A `status` frame closes the inbound stream exactly once; a second terminal, or a
  `message` after terminal, is a protocol violation that fails the stream with
  `RPCError(.internalError)` rather than being delivered.
- `halfClose` finishes one direction without terminating the RPC; `status` is the
  only full terminator (server→client). `cancel` aborts both directions.

## 8. Lifecycle

- **connect()** activates the `XPCSession` and blocks until `beginGracefulShutdown`
  (a `CheckedContinuation` released by shutdown), matching the in-process client.
  `withStream` awaits the `connected` state before allocating a `StreamID`.
- **listen()** starts the `XPCListener`, accepts sessions, and per accepted session
  runs the demux loop; each `openStream` yields to the `streamHandler`. Returns when
  shutdown drains.
- **beginGracefulShutdown()** sends `goAway`, refuses new `openStream`s, lets
  in-flight streams finish, then tears the session(s) down.
- **cancellation / deadlines.** `CallOptions.timeout` starts a per-stream timer that
  sends `cancel` and fails both halves; `ServerContext.cancellation` is wired to an
  inbound `cancel` frame. XPC session death (peer crash) fails every stream on the
  connection with `RPCError(.unavailable)` — reusing the reconstruction's death-channel
  pattern.

## 9. Testing

- A sample `echo.proto` with one method of each call type (unary,
  clientStreaming, serverStreaming, bidiStreaming); `protoc` + the grpc-swift plugin
  generate the stubs, which are **checked in** (codegen is not part of this package's
  build).
- Integration tests run **both transports in one process**: `XPCServerTransport` on
  an anonymous `XPCListener`, its `XPCEndpoint` handed to an `XPCClientTransport`
  (the in-process 2-session pattern from `RealXPCEndToEndTests`). Each of the four
  methods is exercised for a full round-trip, including trailing metadata and a
  non-`ok` status path.
- Backpressure tests: a deliberately slow reader must suspend the writer's `write`
  (assert bounded in-flight), and a cancel/deadline must unblock both sides.
- Unit tests for `XPCFrame` round-tripping every kind, and for the `StreamChannel`
  ordering state machine (reject a post-terminal message, reject a double status).

## 10. Deliberate deviations

- **D1 — reply channel used for credit.** The actor reconstruction avoids the XPC
  reply channel entirely (one-way sends) so a listener can originate calls. This
  transport *uses* the reply channel, but only as the flow-control credit signal;
  RPC correlation still lives in `streamID`, so bidi origination is preserved (C4).
- **D2 — no retries/hedging in v1.** `retryThrottle` returns `nil` and
  `config(forMethod:)` returns `nil`; retry/hedge policy is a follow-up.
- **D3 — connection-near flow control.** Per section 6/C3, not independent per-stream
  windows in v1.
- **D4 — REVERSED 2026-08-19 (user decision): message payloads use gRPC's standard framing.**
  This section originally argued that because XPC already frames messages, the gRPC
  Length-Prefixed-Message envelope was redundant and could be dropped. That is true for
  *correctness* but costs interoperability: the payload bytes then differ from what every other
  gRPC implementation carries, so proxying to or from a real gRPC endpoint would require
  re-framing, and `maxRequest/ResponseMessageBytes` and compression become inexpressible.
  A `message` frame's payload is therefore the standard
  `Compressed-Flag (1 byte) | Message-Length (4 bytes, big-endian) | Message`,
  making it byte-identical to gRPC over HTTP/2. Compression stays unimplemented in v1 (the flag
  is written as 0 and a non-zero flag is rejected), and message-size enforcement stays deferred —
  but the *shape* is now standard rather than bespoke.
- **D6 — the envelope mirrors HTTP/2's semantics, not its bytes (added 2026-08-19, user decision).**
  Sections 5 and 6 originally left the envelope as a Swift `Codable` enum, which encodes to the
  compiler's synthesized shape (`{"message": {"_0": 3, …}}`) — a Swift artifact rather than a
  protocol. Since gRPC's only standard framing *is* HTTP/2, the envelope now carries HTTP/2's own
  vocabulary natively in the xpc dictionary: RFC 9113 §6 frame type codes (DATA `0x0`, HEADERS
  `0x1`, RST_STREAM `0x3`, GOAWAY `0x7`, WINDOW_UPDATE `0x8`), the END_STREAM flag `0x1` (so
  half-close and a terminal status are *flags*, as in HTTP/2, not frame kinds of their own), gRPC's
  request pseudo-headers (`:path`, `content-type: application/grpc`, `grpc-timeout`) and its trailer
  names (`grpc-status`, `grpc-message`). What is deliberately not adopted: HTTP/2's binary frame
  header and HPACK. Those exist to multiplex and compress over a byte stream; XPC already frames and
  types messages, so binary framing would mean tunnelling HTTP/2 through XPC and discarding the
  typed dictionary and its zero-copy `xpc_data` for no interoperability gain on a local link.
  Remaining honest divergences: stream ids are `UInt64` (HTTP/2 uses 31 bits); the `seq` field is
  ours, because HTTP/2 infers message order from stream ordering that a message bus does not
  guarantee; and RST_STREAM carries a human-readable reason rather than a 32-bit error code.
  **The internal representation is unchanged** — `XPCFrame` and `StreamChannel`'s grammar, `seq`
  accounting and terminal rules stay exactly as reviewed; only the encode/decode boundary moved.
- **D5 — metadata and status use gRPC's vocabulary, carried natively.** Metadata keys are
  normalized to lowercase ASCII and the `-bin` suffix is the binary discriminator, exactly as
  gRPC defines — replacing this design's earlier private numeric tag. Status carries the standard
  integer code (0–16) with a plain UTF-8 message. What is deliberately *not* copied is HTTP/2's
  text-transport armour: binary values are not base64-encoded and status messages are not
  percent-encoded, because an XPC dictionary carries raw bytes and Unicode strings natively.
  Those encodings exist to squeeze binary through a text header block; reproducing them here
  would cost size and CPU while making the payload less faithful, not more.

## 11. Risks

- The `handoffReply` exact closure/return shape is read from the SDK ABI dump
  (`() -> (any Encodable)?`); confirm against a live compile before relying on the
  return-value-as-reply semantics. If `handoffReply` does not return the reply the
  way the dump implies, fall back to an explicit `credit` frame (already in the wire
  table, section 5) instead of reply-as-credit — the design degrades cleanly.
- Backpressure fidelity (C3) and graceful-shutdown drain ordering are the two areas
  most likely to need iteration after the first working round-trip.
- grpc-swift 2.x may add transport requirements in a minor release (e.g. `configure`
  arrived in 2.3 with a default); pin `from: "2.4.1"` and re-check on bumps.

## 12. Milestones (for the implementation plan)

1. Target + dependency wiring; empty `XPCClientTransport`/`XPCServerTransport`
   conforming and compiling; `XPCFrame` + round-trip unit tests.
2. `XPCConnection` mux + demux + lifecycle; unary round-trip in-process (no
   backpressure yet — unbounded credit).
3. All four call types over the mux; ordering state machine (section 7).
4. Backpressure (section 6) with C1–C4 and the slow-reader test.
5. Cancellation, deadlines, graceful shutdown; peer-death failure path.
