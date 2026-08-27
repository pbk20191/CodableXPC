# gRPC over XPC — HTTP/2-native transport (full redesign) Implementation Plan

> **SUPERSEDED from Task 4 onward (2026-08-27).** The project owner observed that gRPC core
> defines a transport by its stream-op batch semantics, not by HTTP/2 — gRPC's own in-process
> transport carries no HTTP/2 at all — so byte-level HTTP/2 framing is only required for wire
> interop with foreign peers, which an XPC endpoint does not have. The replacement is
> `docs/superpowers/plans/2026-08-27-grpc-xpc-op-transport.md`. **Tasks 1–3 of this plan are
> implemented, reviewed and kept**: the frame codec and HPACK codec stand unused as the basis of
> a future optional HTTP/2 `WireCodec`, and the gRPC header vocabulary is reused directly.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking. This plan is written to be executed by a model with
> ZERO prior context: everything you need is in this file plus the referenced source files.

**Goal:** Rebuild `GRPCXPCTransport` so that its wire format is genuine, byte-level HTTP/2 —
every mechanism the previous build invented (custom frame enum, seq numbers, reply-as-credit
flow control, custom cancel/goAway frames) is replaced by its RFC 9113 / gRPC-over-HTTP/2
counterpart. One XPC message carries one or more complete binary HTTP/2 frames.

**Architecture:** Layered, bottom-up: binary HTTP/2 frame codec → HPACK (literal-only subset)
→ gRPC header vocabulary → Length-Prefixed-Message stream codec → flow-control windows →
per-stream gRPC state machines → HTTP/2 connection (mux) over an `XPCPipe` → thin
`GRPCCore.ClientTransport` / `ServerTransport` conformances. The old custom-protocol stack is
built alongside and swapped out at the end, so every commit stays green.

**Tech Stack:** grpc-swift-2 `2.4.2` (**product `GRPCCore` ONLY — `grpc-swift-nio-transport`
and any NIO dependency are FORBIDDEN by the project owner**), Apple XPC Swift overlay
(`XPCSession`/`XPCListener`), `XPCDispatchDataBridge` (zero-copy `Data`↔`xpc_data`),
Swift 6 language mode.

**Spec:** This document is self-contained and normative for the wire format (section “Wire
format specification” below). It supersedes the transport/backpressure/wire sections (§4–§8,
D1–D6) of `docs/superpowers/specs/2026-08-19-grpc-over-xpc-design.md`; that document’s §1–§3
(goals, GRPCCore contract, packaging) still apply except where amended here.

---

## Why the redesign (context you must internalize before writing code)

The previous build (still on this branch, commits `2f6732c..7f15717`) works — all four gRPC
call types pass end-to-end over real XPC sessions with backpressure, cancellation, deadlines
and graceful shutdown, 460+ tests green. It was stopped by the project owner for three
reasons, all real:

1. **The wire was not standard.** The envelope was a Swift `Codable` enum’s synthesized shape
   (`{"message": {"_0": 3, "seq": 7, …}}`) — a compiler artifact no other implementation could
   ever parse. Only the payload framing (gRPC Length-Prefixed-Message) and metadata vocabulary
   were standard.
2. **Too many invented types.** An 8-case frame sum-enum, namespace enums, custom credit
   types, a custom seq mechanism — all consequences of inventing a protocol.
3. **Quality risk concentrated in invented mechanisms.** Review rounds found (and fixed) a
   permit-loss race, a peer-controlled DoS, and a data-loss window — all in code that exists
   only because the protocol was bespoke.

**The redesign thesis: stop inventing. Every bespoke mechanism has an RFC counterpart:**

| Previous invention | Standard replacement |
|---|---|
| `XPCFrame` 8-case sum enum | `HTTP2Frame` struct `{kind, flags, streamID, payload}` — HTTP/2’s own frame model (RFC 9113 §4.1) |
| `StreamID: UInt64` + custom `seq` | 31-bit stream IDs, client-initiated odd (§5.1.1); ordering from the transport (XPC delivers in order — pinned by a stress test) |
| reply-as-credit backpressure (`handoffReply`, HeldReply, CreditWindow) | **WINDOW_UPDATE** frames + byte-based windows, initial 65 535 (§5.2, §6.9) |
| `halfClose` frame | **END_STREAM flag** (§6.1) |
| `status` frame | trailing **HEADERS + END_STREAM** carrying `grpc-status`/`grpc-message` |
| `cancel(reason: String)` | **RST_STREAM** with standard error codes (§6.4; CANCEL = 0x8) |
| `deadlineNanos` field | **`grpc-timeout`** request header (gRPC spec) |
| `goAway` marker | **GOAWAY** with last-stream-id (§6.8) — this IS the drain semantic |
| invented part-grammar state machine | RFC 9113 **§5.1 stream states** + the gRPC HTTP/2 mapping |

The standard also already encodes the bugs the old build hit: windows cap at 2³¹−1 with
FLOW_CONTROL_ERROR on overflow (the DoS), only DATA is flow-controlled so terminal frames can
never be credit-starved (the termination deadlock), and END_STREAM-as-flag removes the
“halfClose on the wrong direction” violation class entirely.

---

## Wire format specification (normative)

### W1. Carriage

- One `XPCSession` per connection. Every XPC message is a dictionary with a single key
  `"f"` whose value is an `xpc_data` containing **one or more complete HTTP/2 frames,
  concatenated**. A frame is never split across XPC messages.
- Consequence (and the point): the concatenation of all `"f"` blobs in order is a valid
  HTTP/2 frame stream (minus connection preface — see W6). Any HTTP/2 debugging tool can
  parse a captured session.
- XPC connections deliver messages in order; the receiver processes each blob’s frames in
  order on the session’s serial target queue. (Ordering is pinned by a 10 000-frame stress
  test in Task 7; the old build’s seq-gap guard never fired across 460+ tests, which is the
  empirical basis.)

### W2. Frames (RFC 9113 §4.1)

9-byte header, network byte order:

```
+-----------------------------------------------+
|                 Length (24)                   |   payload length, excl. this header
+---------------+---------------+---------------+
|   Type (8)    |   Flags (8)   |
+-+-------------+---------------+---------------+
|R|                 Stream Identifier (31)      |   R bit always 0 on send, ignored on receive
+=+=============================================+
|                Frame Payload …                |
```

Supported types and their payloads:

| Type | Code | Payload | Flags used |
|---|---|---|---|
| DATA | 0x0 | raw bytes (a slice of the stream’s LPM byte stream). No padding ever. | END_STREAM (0x1) |
| HEADERS | 0x1 | one complete HPACK block (see W3). No padding, no PRIORITY. | END_HEADERS (0x4, **always set**), END_STREAM (0x1) |
| RST_STREAM | 0x3 | 4-byte error code | — |
| GOAWAY | 0x7 | 4-byte R+last-stream-id, 4-byte error code, optional UTF-8 debug data. Stream 0 only. | — |
| WINDOW_UPDATE | 0x8 | 4-byte R+window-increment (1 … 2³¹−1). Stream 0 = connection window. | — |

Rules:
- Max frame payload = **16 384** bytes (the RFC default; we never negotiate larger). DATA
  larger than that is split; an HPACK block larger than that is a v1 limitation error
  (“metadata exceeds 16KB”) — CONTINUATION is not implemented.
- Unknown frame **types** are ignored and discarded (RFC 9113 §4.1 MUST). Unknown **flags**
  are ignored (masked). Do not error on either — that is what the standard says.
- Malformed known frames (wrong payload size for RST/WINDOW_UPDATE, stream 0 where a stream
  is required, stream ≠ 0 for GOAWAY, WINDOW_UPDATE increment 0) → connection error:
  send GOAWAY(PROTOCOL_ERROR or FLOW_CONTROL_ERROR) and fail all streams.
- Error codes are a `RawRepresentable UInt32` **struct with static constants**, not an enum —
  RFC 9113 §7 requires treating unknown codes as INTERNAL_ERROR, which a struct models
  naturally. Constants needed: `noError=0x0, protocolError=0x1, internalError=0x2,
  flowControlError=0x3, cancel=0x8, compressionError=0x9`.

### W3. HEADERS payloads — HPACK, literal-only subset (RFC 7541)

- **Emit:** every field as *Literal Header Field without Indexing — New Name* (§6.2.2):
  first byte `0x00`, then name as a string literal, then value as a string literal.
  String literal = H-bit 0 (never Huffman) + length as a 7-bit-prefix integer (§5.1) + raw
  octets. Names are lowercase ASCII. Pseudo-headers (`:` prefixed) come first (RFC 9113 §8.3).
  This emits 100 % valid HPACK that ANY conformant decoder accepts, with zero dynamic state.
- **Accept:** literal without indexing (`0000` prefix) and literal never-indexed (`0001`
  prefix), raw (non-Huffman) strings. Reject with COMPRESSION_ERROR: indexed fields (`1…`),
  literal-with-incremental-indexing (`01…`), dynamic-table-size updates (`001…`), and
  Huffman-coded strings (H bit set). Both peers are this transport in v1; full HPACK decode is
  a future interop step and the error message must say so.
- 7-bit-prefix integer: value < 127 → one byte; else `0x7F` then LEB128 of (value − 127).

### W4. gRPC mapping (gRPC-over-HTTP/2 spec)

- **Request** (client → server, opening HEADERS, no END_STREAM unless the call sends no
  messages — do not use that shortcut in v1):
  `:method: POST`, `:scheme: http`, `:path: /{fullyQualifiedService}/{method}`,
  `te: trailers`, `content-type: application/grpc`, then `grpc-timeout` if a deadline is set,
  then user metadata. User metadata: keys lowercased; keys ending `-bin` → value =
  **unpadded base64** of the binary (accept padded and unpadded on parse); reserved names
  (pseudo-headers, `grpc-*`, `te`, `content-type`) are stripped from user metadata on emit.
- **grpc-timeout format:** 1–8 ASCII digits + one unit char of `n u m S M H`
  (nanos/micros/millis/seconds/minutes/hours). Emit the **finest unit that fits in 8 digits**
  (truncating — never lengthen a deadline): nanos if ≤ 99 999 999, else micros, else millis,
  else seconds, else minutes, else hours.
- **Response:** initial HEADERS = `:status: 200`, `content-type: application/grpc`, + user
  metadata. Messages as DATA. **Trailers** = HEADERS + END_STREAM with `grpc-status`
  (decimal integer 0–16) and, when non-empty, `grpc-message` (**percent-encoded**: bytes in
  0x20…0x7E except `%` pass through; everything else emits `%XX` uppercase hex of the UTF-8
  bytes; decode leniently — invalid sequences pass through untouched, per spec).
- **Trailers-Only:** a response whose FIRST HEADERS carries END_STREAM and `grpc-status` —
  a complete RPC with no messages. The decoder must recognize it.
- **Messages:** gRPC Length-Prefixed-Message (1-byte compressed flag, always 0 — flag 1 is
  rejected `unimplemented`; 4-byte big-endian length; payload) forming a byte stream carried
  in DATA frames. **Message boundaries are independent of frame boundaries** — a message may
  span DATA frames and a DATA frame may carry several messages. The receiver reassembles.
- **Half-close (client done sending):** END_STREAM on the final DATA frame, or an empty DATA
  frame with END_STREAM if nothing is pending.
- **Cancellation:** RST_STREAM(CANCEL) from either side. Client deadline expiry: local timer →
  RST_STREAM(CANCEL) + fail the local call `RPCError(code: .deadlineExceeded)`. Timers MUST be
  cancelled when the call completes (a leaked timer per RPC is a defect).
- **Graceful shutdown:** GOAWAY(last-stream-id, NO_ERROR). Receiver opens no new streams;
  in-flight streams complete; then teardown. Peer death (XPC session cancellation) fails every
  stream `RPCError(code: .unavailable)`.

### W5. Flow control (RFC 9113 §5.2, §6.9)

- Byte-based. Two windows per direction: the connection window (stream 0) and one per stream.
  Initial size **65 535** for both (no SETTINGS exchange → RFC defaults apply).
- Only DATA payload bytes consume window (both the stream’s and the connection’s). HEADERS,
  RST_STREAM, GOAWAY, WINDOW_UPDATE are never flow-controlled — so terminal frames can never
  be starved (this was a hand-built lesson in the old code; here it is free).
- Sender: to send N payload bytes on stream S, atomically consume from S’s window and the
  connection window; if either is exhausted, send what fits (chunked ≤ 16 384) and suspend the
  writer until WINDOW_UPDATE arrives. See lesson L1 for the mandatory wakeup-race rule.
- Receiver: replenish on **consumption**, not on arrival — when a reassembled message is
  delivered to the application’s async iterator, emit WINDOW_UPDATE for the consumed byte
  count on both the stream and the connection. (Demand-driven, same principle as the old
  reply-as-credit, now in standard clothes.)
- A window must never exceed 2³¹−1: a WINDOW_UPDATE that would overflow is a
  FLOW_CONTROL_ERROR (stream error for a stream window; connection error for the connection
  window). Handling an increment is **O(1) arithmetic** — never loop proportional to a
  peer-supplied number (lesson L2: the old code had a measured 450-second stall from
  `release(UInt32.max)`).

### W6. Documented deviations (the complete list — keep it complete)

1. **No connection preface, no SETTINGS, no PING.** XPC session establishment replaces the
   preface/SETTINGS handshake; XPC session cancellation replaces PING liveness. RFC defaults
   (65 535 windows, 16 384 max frame) are fixed, never negotiated.
2. **The carriage is an XPC dictionary `{"f": xpc_data}`** rather than a TCP byte stream, and
   frames never split across messages.
3. `:scheme` is `http` nominally; there is no TLS/ALPN (the trust boundary is the XPC peer
   attestation, handled at the pipe layer).
4. HPACK acceptance is the literal-only subset (W3) in v1.
5. HPACK blocks > 16 384 bytes are unsupported in v1 (no CONTINUATION).

---

## Verified API facts (pinned against real sources — do NOT re-derive, do NOT guess)

### grpc-swift-2, resolved 2.4.2 (read the checkout under `.build`/scratch `checkouts/grpc-swift-2/Sources/GRPCCore/` if in doubt)

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
  // configure(context:) exists (2.3+) but has a default no-op impl — not required.
}
public enum RPCRequestPart<Bytes>  { case metadata(Metadata); case message(Bytes) }
public enum RPCResponsePart<Bytes> { case metadata(Metadata); case message(Bytes)
                                     case status(Status, Metadata) }   // exactly one, terminal
```

- `RPCStream { descriptor; inbound; outbound }`; `RPCAsyncSequence(wrapping:)`;
  `RPCWriter.Closable(wrapping: some ClosableRPCWriterProtocol<Element>)`;
  `ClosableRPCWriterProtocol` = `write(_:)`, `write(contentsOf:)`, `finish()`,
  `finish(throwing:)` — all `async`.
- `Metadata`: ordered multi-map; `addString(_:forKey:)`, `addBinary(_:forKey:)` (**asserts the
  key ends `-bin`**), iteration element `(key: String, value: Value)` with
  `Value = .string(String) | .binary([UInt8])`; subscripts `[stringValues:]`,
  `[binaryValues:]`. Key lookup is case-insensitive.
- `Status(code:message:)`; `Status.Code(rawValue: Int)` failable; all 17 static codes exist
  (`.ok`, `.cancelled`, `.deadlineExceeded`, `.unavailable`, `.internalError`,
  `.unimplemented`, …). `RPCError(code:message:metadata:cause:)`; `RPCError.Code` mirrors
  `Status.Code` minus `.ok`.
- `MethodDescriptor`: **NO** `init(fullyQualifiedMethod:)` — only
  `init(fullyQualifiedService:method:)` and `init(service:method:)`. Read
  `fullyQualifiedMethod` (“pkg.Service/Method”, no leading slash — the `:path` adds it).
- `ClientContext(descriptor:remotePeer:localPeer:)` — peer strings like `"xpc:<something>"`.
- `ServerContext(descriptor:remotePeer:localPeer:cancellation:)`; `RPCCancellationHandle` has
  no public init — obtain via `withServerContextRPCCancellationHandle { handle in … }` and
  keep the handle registered so shutdown/RST can `cancel()` it. The reference shape is
  `GRPCInProcessTransport/InProcessTransport+Server.swift` in the checkout.
- `CallOptions.defaults`; `CallOptions.timeout: Duration?`.
- Cancellation contracts verified against source: `GRPCClient.runConnections()` and
  `GRPCServer.serve()` both document “cancel the task” as the sanctioned abrupt stop and wrap
  any thrown error as a transport failure ⇒ `connect()`/`listen()` must return **normally**
  (not throw) when their task is cancelled.

### XPC overlay + platform facts

- `XPCSession.send(message: XPCDictionary)` one-way send; incoming raw handler via the
  accept/init variants used in `Sources/XPCActors/XPCRawTransport.swift` (READ that file —
  it is the reviewed reference for anonymous `XPCListener` accept, `XPCSession(endpoint:)`
  dialing with `options: .inactive`, target queues, and cancellation handlers).
- **Lifecycle traps (measured):** cancelling a never-activated `XPCSession` traps in libxpc;
  releasing an activated-but-uncancelled one traps too. Therefore: track activation
  (server/accepted sessions are already live and must NOT be re-activated; client sessions are
  created inactive and activated exactly once via a factory that constructs-and-activates),
  and `deinit` cancels only when activated.
- `XPCDictionary(_ xpc_object_t)` wraps+retains; `withUnsafeUnderlyingDictionary { raw in … }`
  exposes the raw object; build a message dict with `xpc_dictionary_create` +
  `xpc_dictionary_set_value(dict, "f", dataObj)`.
- **Zero-copy facts (measured this week, keep the tests that pin them):**
  `GRPCSwiftData.init(from: xpc_object_t)` wraps an `xpc_data`’s buffer via
  `DispatchData(bytesNoCopy:)` with a deallocator holding the xpc object alive — but `Data`
  keeps values **≤ 14 bytes in inline storage** (copies them) and only references the buffer
  at **≥ 15 bytes**; and `xpc_data_get_bytes_ptr` can return NULL (non-contiguous) → copy
  fallback via `xpc_data_get_bytes`. Both behaviors already implemented and pinned in
  `Sources/GRPCXPCTransport/GRPCDispatchData.swift` + `Tests/.../GRPCSwiftDataTests.swift` —
  **keep them** (delete only the `Codable`/`XPCNativeObject` extension, which the new wire
  does not use).
- Outbound `Data` → `xpc_data` goes through `XPCDispatchDataBridge.DispatchDataBridge.xpcData(for:)`
  (takes the cheaper of two copies; none when dispatch-backed).

---

## Hard-won lessons from the previous build (each cost a real, reproduced bug — treat as MUSTs)

- **L1 — wakeup race:** when a suspended writer is woken, check **granted BEFORE cancelled**.
  The old `CreditWindow` checked cancelled first; a grant racing a cancellation leaked the
  permit permanently (measured 1–14 lost permits per 3 000 races → window shrank to zero →
  stream stalled forever). The same applies to window-wakeups here: a waiter that was granted
  window and then cancelled must either consume the grant or return it — never drop it.
- **L2 — peer-controlled arithmetic:** handling WINDOW_UPDATE must be O(1). The old code
  looped `0..<n` on a peer-supplied `n`: `release(UInt32.max)` measured **450 s inside a
  Mutex**, blocking the whole connection. Clamp and add — never iterate.
- **L3 — handler-completion cleanup:** when the server’s `streamHandler` returns, tear the
  stream down (send RST_STREAM(CANCEL) if not cleanly terminated, remove state, release
  windows). The old build left state behind; an early-returning handler stranded the peer’s
  writer forever (measured: 33 of 200 sent, then permanent hang).
- **L4 — serial routing:** all inbound frame processing for a connection runs on the XPC
  session’s serial target queue. Per-stream decoders assume serial delivery — document the
  precondition on the decoder’s `accept`-equivalent, and never call it off that queue.
- **L5 — one-phase accept:** the server’s accepted-streams sequence yields a **fully built**
  stream (id + descriptor + RPCStream). The old two-phase register-later design caused, in
  sequence: silently dropped frames, a table leak, then silent data loss. Do not reintroduce
  a pending table.
- **L6 — ownership:** outbound writers hold the connection **weakly** (a strong ref through
  the accepted-streams buffer made the connection immortal and leaked the native XPC session).
  Whoever creates streams keeps the connection alive; a write after the connection is gone
  throws `RPCError(.unavailable)` deterministically; connection `deinit` fails all streams
  (otherwise a stream outliving its connection hangs forever on inbound). Document this
  contract on the connection type AND prove `deinit` reachability with a weak-ref test.
- **L7 — transport lifecycle state machines:** `connect()`/`listen()` need explicit
  idle → running → shutDown states under one lock: a second concurrent call is refused
  deterministically (the old single-optional-continuation slot leaked a continuation —
  runtime printed SWIFT TASK CONTINUATION MISUSE); a call after shutdown returns immediately;
  double `beginGracefulShutdown()` resumes at most once; task cancellation unblocks and
  returns normally (`withTaskCancellationHandler`); take-and-transition happens atomically
  under the lock and the continuation is resumed OUTSIDE the lock.
- **L8 — bounded tests, always:** every async test uses the pattern: run the client call on
  its own `Task`; accumulate into a `var` local to that task’s closure; write the finished
  value into a `Mutex<T?>` exactly once; fulfil an `XCTestExpectation`; the test body
  `await fulfillment(of:[…], timeout: 5)` then reads the Mutex. An unbounded streaming test
  hangs the whole suite with no diagnosis (happened twice).
- **L9 — tests must discriminate:** a test that passes when the behavior is broken is a
  defect. Where the property is “no copy”, compare base addresses (and mind the 14-byte
  inline threshold); where it is “suspends”, assert the exact in-flight bound from both sides
  (`>= window` and `<= window + slack`); where it is “ok status”, mutate to a non-ok status
  and confirm the test fails before trusting it.
- **L10 — repo hygiene:** the repo has the user’s unrelated uncommitted WIP
  (`Sources/XPCActors/Packet.swift`, `Sources/XPCCompat/Conformances.swift`,
  `Sources/XPCDispatchDataBridge/DispatchDataBridge.swift`, `.swiftpm/**/*.xcscheme`).
  **Never `git add -A` / `git add .`** — stage only files this plan creates or modifies.
- **L11 — build discipline:** build/test ONLY with an explicit scratch path
  (`--scratch-path <scratch>/build`, executor picks a stable dir under its session scratchpad),
  never the default build dir. Every task ends with `swift build` green and its tests passing.
- **L12 — deadline timers must not leak:** one timer per deadline-bearing RPC, cancelled on
  completion. Assert no timer survives a completed call.

---

## File map

**Create (new stack):**

| File | Contents |
|---|---|
| `Sources/GRPCXPCTransport/HTTP2Frame.swift` | `HTTP2Frame` struct, `Kind`, `Flags` OptionSet, `HTTP2ErrorCode` struct, binary codec |
| `Sources/GRPCXPCTransport/HPACKLiteralCodec.swift` | literal-only HPACK encode/decode + 7-bit-prefix integers |
| `Sources/GRPCXPCTransport/GRPCWireHeaders.swift` | gRPC header vocabulary: request/response/trailers build+parse, timeout format, `-bin` base64, percent-encoding |
| `Sources/GRPCXPCTransport/LPMCodec.swift` | `LPMEncoder` (message → framed bytes) + stateful `LPMDecoder` (byte chunks → messages, spanning frames) |
| `Sources/GRPCXPCTransport/FlowControl.swift` | sender `FlowControlWindow` (suspending, race-safe) + receiver `WindowAccountant` |
| `Sources/GRPCXPCTransport/StreamCodecs.swift` | `ResponseStreamDecoder`/`RequestStreamDecoder` (frames→parts) + `RequestStreamEncoder`/`ResponseStreamEncoder` (parts→frames) |
| `Sources/GRPCXPCTransport/XPCPipe.swift` | XPCSession wrap: ordered blob delivery, activation tracking, cancellation handler, attestation hook |
| `Sources/GRPCXPCTransport/HTTP2Connection.swift` | the mux: stream table, id allocation, frame routing, flow control, GOAWAY/RST, accepted-streams |
| (rewrite) `XPCClientTransport.swift`, `XPCServerTransport.swift` | thin conformances + lifecycle machines + deadlines |

**Keep:** `GRPCDispatchData.swift` (`GRPCSwiftData`; delete only its `Codable` extension),
`Tests/.../GRPCSwiftDataTests.swift`, `Tests/.../XPCPairHarness.swift` (adapt),
the bounded-test pattern.

**Delete at the swap (Task 9):** `XPCFrame.swift`, `StreamChannel.swift`,
`XPCOutboundWriter.swift`, `XPCConnection.swift`, `Backpressure.swift`,
`GRPCMessageFraming.swift` (subsumed by `LPMCodec`), and their tests
(`XPCFrameTests`, `StreamChannelTests`, `XPCConnectionTests`, `BackpressureTests`,
`GRPCMessageFramingTests`); port `CallTypeTests`/`LifecycleTests`/transport tests to the new
seam. Also remove the `CodableXPC` dependency from the `GRPCXPCTransport` target in
`Package.swift` (the new wire never Codable-encodes) and add `XPCDispatchDataBridge` as a
direct dependency (it was transitive).

**Read first (reviewed reference code):** `Sources/XPCActors/XPCRawTransport.swift` (overlay
usage), `Sources/GRPCXPCTransport/XPCConnection.swift` + `XPCClientTransport.swift` (the
lifecycle machines and mux shapes worth porting), `Tests/GRPCXPCTransportTests/XPCServerTransportTests.swift`
(the bounded-test worked example).

## AMENDMENT (2026-08-27, project owner): test implementation is deferred

Tasks 2 onward implement **production code only**. Every task's test file and its TDD steps are
deferred to a dedicated test task run later; a task is "done" when it compiles clean and satisfies
its interface and spec contract by inspection, not when tests pass.

What this changes, stated plainly so nobody mistakes the state of the work:
- `swift build` (and `swift build --build-tests`, since the legacy suite still exists) must stay
  green at every commit. Behaviour is otherwise **unverified** until the test task runs.
- Reviews still gate each task, but their evidence is code read against the RFC and the brief —
  reviewers independently derive byte layouts rather than trusting a green suite (this is how
  Task 1's vectors were confirmed, and it caught nothing false).
- Each task's report MUST end with a **"Deferred tests"** section: the concrete cases its brief
  specified, plus any case the implementer found while writing the code and would have pinned.
  Those lists are the backlog the test task consumes; a case that is not written down is lost.
- Task 1 already shipped with 17 passing tests. They stay and must keep passing.

## Global Constraints

- Availability annotation on every public type:
  `@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)`.
- `GRPCXPCTransport` and its test target stay in the **Swift 6 language mode**
  (`swiftSettings: [.swiftLanguageMode(.v6)]`) — strict-concurrency clean, zero warnings.
  The package default stays `.v5`; other targets untouched.
- `Bytes = GRPCSwiftData` throughout (it conforms to `GRPCContiguousBytes`).
- Dependencies of the `GRPCXPCTransport` target: `GRPCCore` (grpc-swift-2) +
  `XPCDispatchDataBridge`. **Nothing else. NIO in any form is forbidden.**
- Frame constants: max frame payload 16 384; initial windows 65 535; stream IDs odd,
  client-allocated, 31-bit.
- **The new wire never uses `Codable`.** `GRPCSwiftData` crosses to and from libxpc through
  exactly two internal members — `init(from: xpc_object_t)` (zero-copy wrap on receive) and
  `createXPCRepresentation() -> xpc_object_t` (send) — and every byte buffer in the stack is a
  `GRPCSwiftData`, not a `Data`. `GRPCSwiftData`'s `Codable`/`XPCNativeObject` extension exists
  only to keep the legacy stack compiling and is deleted in Task 9; no new code may reference it,
  and the `CodableXPC` dependency leaves the target in Task 9.
- All lessons L1–L12 above bind every task.
- Keep every commit green: build the new stack alongside the old; the old stack is deleted
  only in Task 9’s swap commit.

---

### Task 1: `HTTP2Frame` — the binary frame codec

**Files:**
- Create: `Sources/GRPCXPCTransport/HTTP2Frame.swift`
- Test: `Tests/GRPCXPCTransportTests/HTTP2FrameTests.swift`

**Interfaces (later tasks code against these exact names):**

```swift
struct HTTP2Frame: Equatable, Sendable {
    struct Flags: OptionSet, Equatable, Sendable {
        let rawValue: UInt8
        static let endStream  = Flags(rawValue: 0x1)
        static let endHeaders = Flags(rawValue: 0x4)
    }
    enum Kind: UInt8, Sendable { case data = 0x0, headers = 0x1, rstStream = 0x3,
                                 goAway = 0x7, windowUpdate = 0x8 }
    var kind: Kind
    var flags: Flags
    var streamID: UInt32          // 31-bit; encode masks the top bit to 0
    var payload: GRPCSwiftData
}

struct HTTP2ErrorCode: RawRepresentable, Equatable, Sendable {
    let rawValue: UInt32
    static let noError          = HTTP2ErrorCode(rawValue: 0x0)
    static let protocolError    = HTTP2ErrorCode(rawValue: 0x1)
    static let internalError    = HTTP2ErrorCode(rawValue: 0x2)
    static let flowControlError = HTTP2ErrorCode(rawValue: 0x3)
    static let cancel           = HTTP2ErrorCode(rawValue: 0x8)
    static let compressionError = HTTP2ErrorCode(rawValue: 0x9)
}

enum HTTP2FrameCodec {
    static let maxFramePayload = 16_384
    static func encode(_ frames: [HTTP2Frame]) -> GRPCSwiftData   // concatenated wire bytes
    /// Parses a blob of ≥0 COMPLETE frames. Unknown frame types are skipped (RFC §4.1 MUST);
    /// a truncated trailing frame, a known-type frame with an invalid payload size, or a
    /// length > maxFramePayload throws.
    static func decodeAll(_ blob: GRPCSwiftData) throws -> [HTTP2Frame]
}
```

- [ ] **Step 1: failing tests.** Byte-exact vectors, hand-computed from RFC 9113 — include at
  minimum:

```swift
// DATA, stream 1, END_STREAM, payload 00 00 00 00 00 (an empty LPM message):
// header = 00 00 05 | 00 | 01 | 00 00 00 01
func testDATAFrameIsByteExact() { … XCTAssertEqual([UInt8](encoded),
    [0x00,0x00,0x05, 0x00, 0x01, 0x00,0x00,0x00,0x01, 0x00,0x00,0x00,0x00,0x00]) … }
// WINDOW_UPDATE, stream 0, increment 65535: 00 00 04 | 08 | 00 | 00 00 00 00 | 00 00 ff ff
// RST_STREAM, stream 3, CANCEL: 00 00 04 | 03 | 00 | 00 00 00 03 | 00 00 00 08
```

  plus: round-trip of every kind; multiple concatenated frames decode in order; unknown type
  (e.g. 0x6 PING) between two known frames is skipped and both known frames survive; unknown
  flag bits are preserved-but-maskable; truncated tail throws; RST/WINDOW_UPDATE with wrong
  payload length throws; length > 16 384 throws; stream id top bit is masked on decode.
- [ ] **Step 2:** run — expect FAIL (types undefined).
- [ ] **Step 3:** implement. Encoding writes big-endian manually into `Data`; decoding slices
  (`GRPCSwiftData` views — remember indices do NOT rebase to zero; always offset from
  `startIndex`).
- [ ] **Step 4:** run to green.
- [ ] **Step 5:** commit — `feat(GRPCXPCTransport): binary HTTP/2 frame codec (RFC 9113 §4)`.

---

### Task 2: HPACK literal-only codec

**Files:** Create `Sources/GRPCXPCTransport/HPACKLiteralCodec.swift`,
test `Tests/GRPCXPCTransportTests/HPACKLiteralCodecTests.swift`.

**Interfaces:**
```swift
enum HPACKLiteralCodec {
    static func encode(_ fields: [(name: String, value: String)]) -> GRPCSwiftData
    static func decode(_ block: GRPCSwiftData) throws -> [(name: String, value: String)]
    // integer helpers, internal but tested directly:
    static func writeInt(_ value: Int, prefixBits: Int, firstByteBits: UInt8, into: inout Data)
    /// Reads a prefix-integer starting at `offset` within `block`; advances `offset`.
    static func readInt(prefixBits: Int, block: GRPCSwiftData, offset: inout Int) throws -> Int
}
```

- [ ] **Step 1: failing tests.** Byte-exact vectors:
  `(":method","POST")` → `00 07 3a 6d 65 74 68 6f 64 04 50 4f 53 54`;
  `("grpc-status","0")` → `00 0b 67 72 70 63 2d 73 74 61 74 75 73 01 30`;
  a 300-byte value’s length encodes as `7F AD 01` (127 + LEB128(173)); multi-field ordering
  preserved; decode of never-indexed prefix `0x10` accepted; decode REJECTS: indexed field
  `0x82`, incremental-indexing `0x40`, table-size update `0x20`, Huffman string (H bit set);
  round-trip of a realistic gRPC request header list.
- [ ] **Steps 2–4:** RED → implement → GREEN. Encoder lowercases names and asserts
  pseudo-headers precede regular fields (precondition).
- [ ] **Step 5:** commit — `feat(GRPCXPCTransport): literal-only HPACK codec (RFC 7541 §6.2)`.

---

### Task 3: gRPC wire-header vocabulary

**Files:** Create `Sources/GRPCXPCTransport/GRPCWireHeaders.swift`,
test `Tests/GRPCXPCTransportTests/GRPCWireHeadersTests.swift`.

**Interfaces:**
```swift
enum GRPCWireHeaders {
    static func request(path: String, timeout: Duration?, metadata: Metadata) -> [(String, String)]
    static func initialResponse(metadata: Metadata) -> [(String, String)]
    static func trailers(status: Status, metadata: Metadata) -> [(String, String)]

    struct ParsedRequest { var path: String; var timeout: Duration?; var metadata: Metadata }
    static func parseRequest(_ fields: [(String, String)]) throws -> ParsedRequest
    enum ParsedResponse { case initial(Metadata); case trailers(Status, Metadata) }
    /// END_STREAM on the frame decides trailers-vs-initial at the caller; this validates
    /// grpc-status presence for trailers and its absence for initial metadata.
    static func parseResponse(_ fields: [(String, String)], endStream: Bool) throws -> ParsedResponse

    static func encodeTimeout(_ d: Duration) -> String       // finest unit fitting 8 digits
    static func parseTimeout(_ s: String) throws -> Duration
    static func percentEncode(_ s: String) -> String
    static func percentDecode(_ s: String) -> String          // lenient
    static func base64Unpadded(_ bytes: [UInt8]) -> String
    static func parseBase64(_ s: String) throws -> [UInt8]    // accepts padded + unpadded
}
```

Rules to implement exactly (from W4): request field order `:method,:scheme,:path,te,
content-type[,grpc-timeout],user-metadata…`; user metadata keys lowercased; `-bin` values
base64; reserved names (`:` prefix, `grpc-` prefix, `te`, `content-type`) stripped from user
metadata on emit and excluded from user metadata on parse; `grpc-message` percent-encoding;
path built as `"/" + descriptor.fullyQualifiedMethod`; parse splits on the LAST `/`
(`MethodDescriptor(fullyQualifiedService:method:)` — there is no fullyQualifiedMethod init).

- [ ] **Step 1: failing tests** — timeout table: `1s → "1000000u"` (1s in nanos is 10 digits,
  too many, so the finest fitting unit is micros), `100ms → "100000u"`, `27h → "97200000m"`,
  plus a parse test for every unit char; percent-encode round trips incl. Korean text and `%` itself;
  base64 padded/unpadded acceptance; trailers-only vs initial disambiguation; reserved-key
  stripping; `-bin` round trip through `Metadata`.
- [ ] **Steps 2–4:** RED → implement → GREEN.
- [ ] **Step 5:** commit — `feat(GRPCXPCTransport): gRPC HTTP/2 header vocabulary`.

---

### Task 4: LPM stream codec (messages spanning frames)

**Files:** Create `Sources/GRPCXPCTransport/LPMCodec.swift`,
test `Tests/GRPCXPCTransportTests/LPMCodecTests.swift`.

**Interfaces:**
```swift
enum LPMEncoder {
    /// 1-byte compressed flag (always 0) + 4-byte BE length + payload.
    static func encode(_ message: GRPCSwiftData) -> GRPCSwiftData
}
/// Stateful reassembler: DATA payload chunks in, complete messages out. NOT thread-safe;
/// owned by a single stream's decoder and driven on the connection's serial queue (L4).
struct LPMDecoder {
    mutating func append(_ chunk: GRPCSwiftData)
    /// nil = need more bytes. Throws on compressed flag ≠ 0 (`unimplemented`) or a declared
    /// length that exceeds a sanity bound. When a message lies entirely within one appended
    /// chunk, the returned value is a zero-copy slice of it.
    mutating func next() throws -> GRPCSwiftData?
    var bytesBuffered: Int { get }
}
```

- [ ] **Step 1: failing tests** — single message in one chunk (assert zero-copy via base
  address, payload ≥ 15 bytes per the inline-storage fact); message split across 3 chunks at
  awkward boundaries (inside the 5-byte prefix, inside the body); several messages in one
  chunk; empty message; compressed flag rejected; declared-length overflow rejected;
  incremental `next()` returns nil until complete.
- [ ] **Steps 2–4:** RED → implement → GREEN.
- [ ] **Step 5:** commit — `feat(GRPCXPCTransport): LPM stream codec`.

---

### Task 5: Flow control

**Files:** Create `Sources/GRPCXPCTransport/FlowControl.swift`,
test `Tests/GRPCXPCTransportTests/FlowControlTests.swift`.

**Interfaces:**
```swift
/// Sender-side window (one per stream + one per connection). Byte-based, initial 65_535.
final class FlowControlWindow: Sendable {
    init(initial: Int)
    /// Reserve up to `requested` bytes; returns the number actually reserved (≥1) —
    /// suspending while the window is empty. Throws CancellationError on task cancellation
    /// and the window's failure error after fail(_:).
    /// L1 RULE: a waiter woken by grant() must consume its reservation even if its task was
    /// cancelled in the same instant — check granted BEFORE cancelled; never drop a grant.
    func reserve(upTo requested: Int) async throws -> Int
    /// WINDOW_UPDATE arrival. O(1). Throws on total > 2^31-1 (flow-control error) — L2.
    func grant(_ increment: UInt32) throws
    func fail(_ error: any Error)     // wakes all waiters with the error
    var available: Int { get }
}
/// Receiver-side accounting: consumed bytes → WINDOW_UPDATE increments to emit.
struct WindowAccountant {
    init(initial: Int)
    /// Record that `bytes` of DATA payload were delivered to the consumer; returns an
    /// increment to send now (v1: echo the consumed bytes immediately; coalescing is a
    /// documented future optimization).
    mutating func consumed(_ bytes: Int) -> UInt32?
}
```

- [ ] **Step 1: failing tests** —
  (a) exact bound: window 10, writer wants 25 → reserves 10, suspends; grant(7) → 7; grant(8)
  → 8; total 25.
  (b) **the L1 race, reproduced**: 3 000 iterations of concurrent grant-vs-cancel on a parked
  `reserve`; after each iteration assert the window’s total accounting is intact (no permit
  lost — the old bug lost 1–14 per 3 000).
  (c) **the L2 guard**: `grant(UInt32.max)` completes in O(1) (assert < 50 ms) and throws
  flow-control error when the total would exceed 2³¹−1.
  (d) fail() wakes all waiters with the error; reserve() after fail throws immediately.
  (e) task cancellation unblocks a parked reserve with CancellationError (when no grant raced).
  All bounded per L8.
- [ ] **Steps 2–4:** RED → implement → GREEN. Implementation: `Mutex`-guarded state +
  `CheckedContinuation` FIFO; resume outside the lock; take-and-transition atomic (L7’s lock
  discipline applies).
- [ ] **Step 5:** commit — `feat(GRPCXPCTransport): byte-based HTTP/2 flow-control windows`.

---

### Task 6: Per-stream gRPC codecs (frames ↔ RPC parts)

**Files:** Create `Sources/GRPCXPCTransport/StreamCodecs.swift`,
test `Tests/GRPCXPCTransportTests/StreamCodecsTests.swift`.

**Interfaces (explicit types, no generic factories — the old generic spelling fought
inference):**
```swift
/// Client side: response frames in → RPCResponsePart out. Serial use only (L4).
struct ResponseStreamDecoder {
    /// Feed one frame belonging to this stream. Returns 0+ parts to deliver.
    /// Grammar: HEADERS(no ES) once as leading metadata → DATA* (LPM reassembly) →
    /// HEADERS(ES) as trailers → done. FIRST HEADERS with ES = Trailers-Only.
    /// DATA before HEADERS, anything after trailers, HEADERS twice without ES,
    /// or a malformed HPACK/LPM payload → throws (stream error).
    mutating func accept(_ frame: HTTP2Frame) throws -> [RPCResponsePart<GRPCSwiftData>]
    var consumedDataBytes: Int { get }   // for WindowAccountant
}
/// Server side: request frames in → RPCRequestPart out; END_STREAM ends the sequence.
struct RequestStreamDecoder {
    mutating func accept(_ frame: HTTP2Frame) throws
        -> (parts: [RPCRequestPart<GRPCSwiftData>], remoteEnded: Bool)
    var consumedDataBytes: Int { get }
}
/// Client side: RPCRequestPart in → frames out (window-agnostic; the connection applies
/// flow control and 16 384-byte chunking to the DATA bytes).
struct RequestStreamEncoder {
    init(descriptor: MethodDescriptor, timeout: Duration?)
    mutating func encodeMetadata(_ m: Metadata) -> HTTP2Frame        // opening HEADERS
    mutating func encodeMessage(_ b: GRPCSwiftData) -> GRPCSwiftData  // LPM bytes for DATA
    mutating func endStream() -> HTTP2Frame?                          // empty DATA+ES if needed
}
struct ResponseStreamEncoder {
    mutating func encodeMetadata(_ m: Metadata) -> HTTP2Frame         // :status 200 …
    mutating func encodeMessage(_ b: GRPCSwiftData) -> GRPCSwiftData
    mutating func encodeStatus(_ s: Status, _ trailers: Metadata) -> HTTP2Frame // HEADERS+ES
}
```

- [ ] **Step 1: failing tests** — all four call-type shapes exercised at frame level (no XPC):
  unary (metadata → 1 msg → ES; response metadata → 1 msg → trailers); server/client
  streaming; bidi interleaved; Trailers-Only; a message spanning two DATA frames; two
  messages in one DATA frame; violations each throw (DATA-before-HEADERS, frames after
  trailers, second non-ES HEADERS, client receiving HEADERS-trailers from a client encoder is
  N/A — but server receiving trailers HEADERS from a client throws); implicit initial
  metadata: server encoder inserts `.metadata` part exactly once even if the handler writes a
  message first (gRPC requires :status HEADERS before DATA — if `encodeMessage` is called
  before `encodeMetadata`, synthesize empty initial metadata; test it).
- [ ] **Steps 2–4:** RED → implement → GREEN.
- [ ] **Step 5:** commit — `feat(GRPCXPCTransport): per-stream gRPC codecs over HTTP/2 frames`.

---

### Task 7: `XPCPipe`

**Files:** Create `Sources/GRPCXPCTransport/XPCPipe.swift`; adapt
`Tests/GRPCXPCTransportTests/XPCPairHarness.swift`; test `Tests/GRPCXPCTransportTests/XPCPipeTests.swift`.

**Interfaces:**
```swift
/// Thin, frame-agnostic byte pipe over one XPCSession. Owns the serial queue.
final class XPCPipe: Sendable {
    enum Role: Sendable { case client, server }
    let queue: DispatchSerialQueue
    /// Wire: dictionary {"f": xpc_data}. Blob = ≥1 complete frames (the pipe doesn't parse).
    /// MUST build the xpc_data via `blob.createXPCRepresentation()` — never via Codable and never
    /// by re-wrapping through `Data`. That method and `GRPCSwiftData(from:)` are the ONLY two
    /// crossings between this module and libxpc.
    func send(_ blob: GRPCSwiftData) throws   // one-way; throws .unavailable after teardown
    /// Set exactly once before activation: called on `queue`, in order, per received blob.
    func onReceive(_ handler: @escaping @Sendable (GRPCSwiftData) -> Void)
    func onPeerDeath(_ handler: @escaping @Sendable () -> Void)
    var peerAttestation: (any PeerAttestation)? { get }   // optional; nil in v1 is acceptable
    static func connecting(to endpoint: XPCEndpoint) throws -> XPCPipe   // creates + ACTIVATES
    static func accepting(_ request: XPCListener.IncomingSessionRequest) -> (Decision, XPCPipe)
    func cancel()                              // idempotent
    // deinit: cancels ONLY if activated (trap facts) — port the activation tracking from the
    // old XPCConnection verbatim.
}
```
Port the accept/dial recipes from `Sources/XPCActors/XPCRawTransport.swift` and the old
`XPCConnection.swift`/`XPCPairHarness.swift` (both reviewed): anonymous `XPCListener`, live
accepted sessions (never re-activate), the Box-publication pattern at accept time, incoming
raw dictionaries via `withUnsafeUnderlyingDictionary`, extracting `"f"` with
`xpc_dictionary_get_value`, wrapping via `GRPCSwiftData(from:)` (zero-copy ≥ 15 B).

- [ ] **Step 1: failing tests** — pair harness connects; a blob round-trips byte-identical;
  **ordering stress: 10 000 blobs each carrying its index arrive in exact order** (this test
  is what licenses dropping the old `seq` mechanism — if it ever fails, the redesign
  assumption is wrong and you must STOP and report rather than re-adding seq silently);
  peer death fires `onPeerDeath` on the survivor; `send` after cancel throws; deinit
  reachability with a weak ref (L6); double-cancel safe.
- [ ] **Steps 2–4:** RED → implement → GREEN (bounded tests, L8).
- [ ] **Step 5:** commit — `feat(GRPCXPCTransport): XPCPipe ordered byte carriage`.

---

### Task 8: `HTTP2Connection` — the mux

**Files:** Create `Sources/GRPCXPCTransport/HTTP2Connection.swift`,
test `Tests/GRPCXPCTransportTests/HTTP2ConnectionTests.swift`.

**Interfaces:**
```swift
struct AcceptedStream: Sendable {
    let id: UInt32
    let descriptor: MethodDescriptor
    let timeout: Duration?
    let stream: RPCStream<RPCAsyncSequence<RPCRequestPart<GRPCSwiftData>, any Error>,
                          RPCWriter<RPCResponsePart<GRPCSwiftData>>.Closable>
}
final class HTTP2Connection: Sendable {
    init(pipe: XPCPipe, role: XPCPipe.Role)
    /// Client: allocate an odd stream id, build the client RPCStream. The connection must be
    /// kept alive by the caller while streams are in use (L6 — document on the type, on this
    /// method, and on acceptedStreams).
    func openClientStream(descriptor: MethodDescriptor, timeout: Duration?)
        -> (UInt32, RPCStream<RPCAsyncSequence<RPCResponsePart<GRPCSwiftData>, any Error>,
                              RPCWriter<RPCRequestPart<GRPCSwiftData>>.Closable>)
    /// Server: yields FULLY BUILT streams (L5 — one phase, no register-later).
    var acceptedStreams: AsyncStream<AcceptedStream> { get }
    func sendGoAway(lastStreamID: UInt32, code: HTTP2ErrorCode)
    func failAll(_ error: any Error)
    // deinit: failAll(.unavailable) + finish acceptedStreams (L6).
}
```

Behavior contract (each line is a test):
1. Inbound blobs are parsed with `HTTP2FrameCodec.decodeAll` on the pipe’s queue; frames route
   by stream id to the per-stream decoders; a decoder throw → RST_STREAM(streamError code) out
   + fail that stream locally with the thrown `RPCError` (never `try?`-swallowed).
2. New inbound HEADERS on an unknown odd id (server role) → parse request headers, build
   `RequestStreamDecoder` + outbound writer + `RPCStream`, register in the table, yield on
   `acceptedStreams` — all within the same serial routing turn (L5).
3. WINDOW_UPDATE routes to the matching `FlowControlWindow` (stream or connection);
   grant-overflow → GOAWAY(FLOW_CONTROL_ERROR) + failAll (L2).
4. Outbound message path (both roles): LPM-encode → loop: `reserve(upTo:)` on the stream
   window then the connection window (consistent order, release-on-error) → emit DATA frames
   ≤ 16 384 → pipe.send (batching frames of one write into one blob is allowed and preferred).
   HEADERS/RST/GOAWAY bypass flow control entirely.
5. Inbound DATA delivery: when a decoder yields message parts to the stream’s
   `AsyncThrowingStream`, account consumed bytes via `WindowAccountant` and send
   WINDOW_UPDATE (stream + connection) — replenish-on-consumption.
6. RST_STREAM inbound → fail that stream with the mapped `RPCError` (`cancel` → `.cancelled`,
   else `.unavailable`/`.internalError` mapping documented inline); remove from table.
7. Terminal cleanup: a stream leaves the table when both sides have ended (trailers sent +
   remote ended, or RST either way). No entry may outlive its stream (the old build leaked
   one per RPC until reviewed).
8. GOAWAY inbound: mark draining — `openClientStream` after GOAWAY throws
   `RPCError(.unavailable, "connection is shutting down")`; streams ≤ last-stream-id continue.
9. Peer death (pipe.onPeerDeath) → failAll(.unavailable); all parked window-waiters wake with
   the error (L1’s fail path).
10. Writers hold the connection weakly; write-after-gone throws `.unavailable` (L6);
    connection deinit reachable with accepted-but-undrained streams buffered (weak-ref test).

- [ ] **Step 1: failing tests** — one test per contract line above, built on `XPCPairHarness`
  (two real pipes) where interaction is needed and on direct frame injection where not; all
  bounded (L8); include the slow-reader backpressure test at this seam: server writes 200
  messages of 1 000 bytes to a gated client reader → in-flight bytes bounded by
  65 535 + one frame of slack; opening the gate drains all 200 (this is the discriminating
  “write genuinely suspends” test, L9).
- [ ] **Steps 2–4:** RED → implement → GREEN.
- [ ] **Step 5:** commit — `feat(GRPCXPCTransport): HTTP/2 connection mux over XPCPipe`.

---

### Task 9: Transports + the swap

**Files:**
- Rewrite: `Sources/GRPCXPCTransport/XPCClientTransport.swift`, `XPCServerTransport.swift`
- Modify: `Package.swift` (drop `CodableXPC` dep from the target; add `XPCDispatchDataBridge`)
- Modify: `Sources/GRPCXPCTransport/GRPCDispatchData.swift` (delete the `Codable`/
  `XPCNativeObject` extension only)
- Delete: `XPCFrame.swift`, `StreamChannel.swift`, `XPCOutboundWriter.swift`,
  `XPCConnection.swift`, `Backpressure.swift`, `GRPCMessageFraming.swift`, and tests
  `XPCFrameTests/StreamChannelTests/XPCConnectionTests/BackpressureTests/GRPCMessageFramingTests`
- Port: `CallTypeTests.swift`, `LifecycleTests.swift`, `XPCClientTransportTests.swift`,
  `XPCServerTransportTests.swift` to the new seam (preserve every test’s INTENT; adapt
  construction only; carry the status-assertion + timeout hygiene they already have).

**Contracts:**
- Lifecycle machines per L7, ported from the old (reviewed) transports: explicit states,
  refuse double connect/listen, post-shutdown immediate return, cancellation-returns-normally.
- Client `withStream`: allocate stream (+ timeout from `CallOptions.timeout`), start the
  deadline timer if set (timer → RST_STREAM(CANCEL) + local `.deadlineExceeded`; cancel timer
  on completion — L12), run the closure, on closure exit send RST(CANCEL) if the stream is not
  terminally closed (L3’s client-side mirror).
- Server `listen`: drain `acceptedStreams`; per stream build `ServerContext` via
  `withServerContextRPCCancellationHandle`, register the handle so GOAWAY-drain/RST/peer-death
  can `cancel()` it; after `streamHandler` returns run handler-completion cleanup (L3).
- `beginGracefulShutdown` (both): send GOAWAY(NO_ERROR), stop opening/accepting, let in-flight
  finish, release `connect()`/`listen()`.
- [ ] **Step 1:** port the tests first (they are the spec of behavior), watch the missing
  pieces fail. **Step 2:** implement. **Step 3:** delete the legacy files + tests, fix the
  build. **Step 4:** full suite green (`swift build`, `swift build --build-tests`,
  `swift test`). **Step 5:** commit —
  `feat(GRPCXPCTransport)!: swap to the HTTP/2-native stack, delete the custom protocol`.

---

### Task 10: End-to-end + byte-standard verification

**Files:** Create `Tests/GRPCXPCTransportTests/EndToEndTests.swift`,
`Tests/GRPCXPCTransportTests/WireStandardnessTests.swift`.

- [ ] **Step 1: service-level e2e without protoc** — register a handler through
  `GRPCCore.GRPCServer(transport:services:)`-level APIs or, simpler and sufficient, drive
  `withStream`/`listen` directly for all four call types over two real XPC sessions (port of
  the old CallTypeTests already does this in Task 9 — here add one test that goes through
  `GRPCClient`/`GRPCServer` with a minimal hand-registered service if the RPCRouter API allows
  registration without codegen; if it does not without protobuf, document that and keep the
  transport-level matrix as the e2e).
- [ ] **Step 2: wire-standardness proof** — capture every blob a client session sends during a
  unary call (test hook on `XPCPipe`), concatenate, and parse with an INDEPENDENT minimal
  reader written in the test (its own 9-byte-header walker — not `HTTP2FrameCodec`); assert
  the exact sequence: HEADERS(EH) → DATA* → DATA(ES) and, server side,
  HEADERS(EH) → DATA* → HEADERS(EH|ES); assert the first HEADERS block’s first bytes are
  `0x00 0x07 :method …` (literal-only HPACK) and that the DATA payload starts with
  `0x00` + 4-byte BE length (LPM). This is the test that makes “byte-level standard” a pinned
  property instead of a claim.
- [ ] **Step 3:** full-suite verification: `swift test` green across the package
  (XPCActors 342 + CodableXPC 25 + this target), per-target language modes unchanged
  (`GRPCXPCTransport`+tests = 6, others = 5), zero warnings in the target.
- [ ] **Step 4:** commit — `test(GRPCXPCTransport): end-to-end + byte-level standardness pins`.

---

## Self-review checklist for the executing model (run before calling any task done)

1. Does the diff invent a mechanism that W1–W6 already standardize? Revert to the standard.
2. Is any test unbounded (L8) or non-discriminating (L9)? Fix before commit.
3. Did you touch the user’s WIP files or `git add -A`? (L10 — never.)
4. Do inter-task names match this plan’s Interfaces blocks exactly? Later tasks were written
   against them.
