# gRPC over XPC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry a standard grpc-swift v2 service over Apple's `XPCSession`/`XPCListener` by implementing `GRPCCore.ClientTransport` and `ServerTransport`.

**Architecture:** One `XPCSession` per connection multiplexes many RPCs by a client-allocated `StreamID`; each RPC's typed parts (`metadata`/`message`/`status`) are framed as `XPCFrame`s and sent as XPC messages. Backpressure is reply-as-credit via `XPCReceivedMessage.handoffReply(to:)`, with the connection's Dispatch serial queue adopted as its `SerialExecutor`. HTTP/2 is not involved.

**Tech Stack:** grpc-swift-2 `2.4.1` (`GRPCCore`), Apple `XPC` Swift overlay (`XPCSession`/`XPCListener`), `CodableXPC` (Codable↔`xpc_object_t`, zero-copy `Data`→`xpc_data`), Swift 6 language mode, `Synchronization`.

**Spec:** `docs/superpowers/specs/2026-08-19-grpc-over-xpc-design.md`

## Global Constraints

- Availability floor: `@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)` on every public type (grpc-swift v2's floor). Apply it uniformly.
- New dependency `.package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.1")`, product `GRPCCore`, is used **only** by the new `GRPCXPCTransport` target (+ `GRPCInProcessTransport` in the test target). Existing targets stay dependency-free.
- New target `GRPCXPCTransport` adopts the Swift 6 language mode (`swiftSettings: [.swiftLanguageMode(.v6)]`), like `XPCActors`. The package default stays `.v5`.
- `Bytes = [UInt8]` throughout (it conforms to `GRPCContiguousBytes`).
- Build/test only with an explicit scratch path, never the default build dir:
  `--scratch-path <scratch>/build` (executor picks a stable dir under the session scratchpad).
- Every task ends green: `swift build` and the task's tests pass. Do not proceed past a red task.
- `StreamID` is `UInt64`, monotonic, allocated by the client side only.
- Verbatim gRPC signatures in this plan were verified against grpc-swift-2 tag `2.4.1`. Task 1 re-confirms them against the resolved module; if a signature differs, fix the conformance and note it — the wire model and backpressure design do not change.

---

### Task 1: Package wiring + compiling empty conformances

**Files:**
- Modify: `Package.swift` (add dependency, product, target, test target)
- Create: `Sources/GRPCXPCTransport/XPCClientTransport.swift`
- Create: `Sources/GRPCXPCTransport/XPCServerTransport.swift`
- Create: `Tests/GRPCXPCTransportTests/SmokeTests.swift`

**Interfaces:**
- Consumes: `GRPCCore.ClientTransport`, `GRPCCore.ServerTransport`.
- Produces: `public struct XPCClientTransport: ClientTransport` and `public final class XPCServerTransport: ServerTransport`, both with `typealias Bytes = [UInt8]`. Exact requirement set is pinned here by making the module compile.

- [ ] **Step 1: Add the dependency, product, and targets to `Package.swift`**

In `dependencies:` add:
```swift
.package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.1"),
```
In `products:` add:
```swift
.library(name: "GRPCXPCTransport", targets: ["GRPCXPCTransport"]),
```
In `targets:` add:
```swift
.target(
    name: "GRPCXPCTransport",
    dependencies: [
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        "CodableXPC",
    ],
    swiftSettings: [.swiftLanguageMode(.v6)]
),
.testTarget(
    name: "GRPCXPCTransportTests",
    dependencies: [
        "GRPCXPCTransport",
        .product(name: "GRPCInProcessTransport", package: "grpc-swift-2"),
    ],
    swiftSettings: [.swiftLanguageMode(.v6)]
),
```

- [ ] **Step 2: Write minimal conforming stubs that trap**

`Sources/GRPCXPCTransport/XPCClientTransport.swift`:
```swift
import GRPCCore

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct XPCClientTransport: ClientTransport {
    public typealias Bytes = [UInt8]

    public var retryThrottle: RetryThrottle? { nil }

    public func connect() async throws { fatalError("unimplemented") }
    public func beginGracefulShutdown() { fatalError("unimplemented") }

    public func withStream<T: Sendable>(
        descriptor: MethodDescriptor,
        options: CallOptions,
        _ closure: (RPCStream<Inbound, Outbound>, ClientContext) async throws -> T
    ) async throws -> T { fatalError("unimplemented") }

    public func config(forMethod descriptor: MethodDescriptor) -> MethodConfig? { nil }
}
```
`Sources/GRPCXPCTransport/XPCServerTransport.swift`:
```swift
import GRPCCore

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class XPCServerTransport: ServerTransport {
    public typealias Bytes = [UInt8]

    public func listen(
        streamHandler: @escaping @Sendable (RPCStream<Inbound, Outbound>, ServerContext) async -> Void
    ) async throws { fatalError("unimplemented") }

    public func beginGracefulShutdown() { fatalError("unimplemented") }
}
```

- [ ] **Step 3: Build to pin the real protocol requirement set**

Run: `swift build --target GRPCXPCTransport --scratch-path <scratch>/build`
Expected: PASS. If the compiler reports a missing requirement (e.g. `configure(context:)` from 2.3+, or a different `withStream`/`listen` signature), add/fix it to match the resolved `GRPCCore`, then rebuild. Record any signature that differed from this plan in a comment at the top of each file.

- [ ] **Step 4: Write a smoke test that the types exist**

`Tests/GRPCXPCTransportTests/SmokeTests.swift`:
```swift
import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class SmokeTests: XCTestCase {
    func testTypesConform() {
        // Compile-time: the conformances exist with Bytes == [UInt8].
        func requireClient<T: ClientTransport>(_ t: T.Type) where T.Bytes == [UInt8] {}
        func requireServer<T: ServerTransport>(_ t: T.Type) where T.Bytes == [UInt8] {}
        requireClient(XPCClientTransport.self)
        requireServer(XPCServerTransport.self)
    }
}
```

- [ ] **Step 5: Run tests and confirm green**

Run: `swift test --scratch-path <scratch>/build 2>&1 | grep -E "GRPCXPCTransportTests|Executed"`
Expected: builds and `testTypesConform` passes.

- [ ] **Step 6: Commit**
```bash
git add Package.swift Package.resolved Sources/GRPCXPCTransport Tests/GRPCXPCTransportTests
git commit -m "feat(GRPCXPCTransport): scaffold target + grpc-swift-2 dependency"
```

---

### Task 2: `XPCFrame` — the wire unit

**Files:**
- Create: `Sources/GRPCXPCTransport/XPCFrame.swift`
- Test: `Tests/GRPCXPCTransportTests/XPCFrameTests.swift`

**Interfaces:**
- Consumes: `GRPCCore.Metadata`, `Metadata.Value`, `GRPCCore.Status`.
- Produces:
  - `typealias StreamID = UInt64`
  - `enum XPCFrame: Codable, Sendable` with cases `openStream(StreamID, method: String, deadlineNanos: Int64?)`, `metadata(StreamID, WireMetadata)`, `message(StreamID, seq: UInt64, bytes: Data)`, `halfClose(StreamID)`, `status(StreamID, code: Int, message: String, trailers: WireMetadata)`, `cancel(StreamID, reason: String)`, `credit(StreamID, n: UInt32)`, `goAway`.
  - `struct WireMetadata: Codable, Sendable` with `init(_ metadata: Metadata)` and `func asMetadata() -> Metadata`.
  - `func encodeToXPC() throws -> xpc_object_t` and `static func decode(from: xpc_object_t) throws -> XPCFrame` (via `CodableXPC.XPCEncoder`/`XPCDecoder`).

- [ ] **Step 1: Write the failing test for `WireMetadata` round-trip**

`Tests/GRPCXPCTransportTests/XPCFrameTests.swift`:
```swift
import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class XPCFrameTests: XCTestCase {
    func testWireMetadataRoundTripsStringAndBinary() {
        var md = Metadata()
        md.addString("v1", forKey: "k1")
        md.addString("v2", forKey: "k1")            // multi-value
        md.addBinary([0xDE, 0xAD], forKey: "k2-bin")
        let restored = WireMetadata(md).asMetadata()
        XCTAssertEqual(Array(restored[stringValues: "k1"]), ["v1", "v2"])
        XCTAssertEqual(Array(restored[binaryValues: "k2-bin"]).first, [0xDE, 0xAD])
    }
}
```
Note: confirm the exact `Metadata` mutation API (`addString(_:forKey:)`, `addBinary(_:forKey:)`, subscripts `[stringValues:]`/`[binaryValues:]`) against the resolved module in Task 1; adjust names if they differ.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter XPCFrameTests/testWireMetadataRoundTripsStringAndBinary --scratch-path <scratch>/build`
Expected: FAIL (`WireMetadata` not defined).

- [ ] **Step 3: Implement `StreamID`, `WireMetadata`, `XPCFrame`**

`Sources/GRPCXPCTransport/XPCFrame.swift`:
```swift
import Foundation
import GRPCCore
import CodableXPC
import XPC

public typealias StreamID = UInt64

/// A `GRPCCore.Metadata` in a Codable shape. Each entry is a key plus a tagged value:
/// tag 0 = UTF-8 string, tag 1 = raw binary (the gRPC `-bin` convention).
struct WireMetadata: Codable, Sendable {
    struct Entry: Codable, Sendable { var key: String; var tag: UInt8; var bytes: Data }
    var entries: [Entry]

    init(_ metadata: Metadata) {
        entries = metadata.map { element in
            switch element.value {
            case .string(let s): Entry(key: element.key, tag: 0, bytes: Data(s.utf8))
            case .binary(let b): Entry(key: element.key, tag: 1, bytes: Data(b))
            }
        }
    }

    func asMetadata() -> Metadata {
        var md = Metadata()
        for e in entries {
            if e.tag == 0 { md.addString(String(decoding: e.bytes, as: UTF8.self), forKey: e.key) }
            else { md.addBinary([UInt8](e.bytes), forKey: e.key) }
        }
        return md
    }
}

/// One packet on the wire. Exactly one of these per `XPCSession` message.
enum XPCFrame: Codable, Sendable {
    case openStream(StreamID, method: String, deadlineNanos: Int64?)
    case metadata(StreamID, WireMetadata)
    case message(StreamID, seq: UInt64, bytes: Data)
    case halfClose(StreamID)
    case status(StreamID, code: Int, message: String, trailers: WireMetadata)
    case cancel(StreamID, reason: String)
    case credit(StreamID, n: UInt32)
    case goAway
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter XPCFrameTests/testWireMetadataRoundTripsStringAndBinary --scratch-path <scratch>/build`
Expected: PASS.

- [ ] **Step 5: Write the failing test for xpc round-trip of every frame kind**

Append to `XPCFrameTests.swift`:
```swift
@available(macOS 15.0, *)
extension XPCFrameTests {
    func testEveryFrameKindRoundTripsThroughXPC() throws {
        var md = Metadata(); md.addString("x", forKey: "k")
        let frames: [XPCFrame] = [
            .openStream(1, method: "pkg.S/M", deadlineNanos: 1_000),
            .metadata(2, WireMetadata(md)),
            .message(3, seq: 7, bytes: Data([1, 2, 3])),
            .halfClose(4),
            .status(5, code: 0, message: "ok", trailers: WireMetadata(md)),
            .cancel(6, reason: "test"),
            .credit(7, n: 4),
            .goAway,
        ]
        for f in frames {
            let obj = try f.encodeToXPC()
            let back = try XPCFrame.decode(from: obj)
            XCTAssertEqual(f, back)   // XPCFrame: Equatable — add the conformance
        }
    }
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `swift test --filter XPCFrameTests/testEveryFrameKindRoundTripsThroughXPC --scratch-path <scratch>/build`
Expected: FAIL (`encodeToXPC`/`decode` not defined; `Equatable` missing).

- [ ] **Step 7: Add `Equatable` and the xpc bridge**

Add `Equatable` to `WireMetadata`, `WireMetadata.Entry`, and `XPCFrame`. Append to `XPCFrame.swift`:
```swift
extension WireMetadata.Entry: Equatable {}
extension WireMetadata: Equatable {}
extension XPCFrame: Equatable {}

extension XPCFrame {
    /// Encode via CodableXPC. `Data` fields map to `xpc_data` (zero-copy for the message payload,
    /// per CodableXPC's ZeroCopyData path).
    func encodeToXPC() throws -> xpc_object_t {
        try XPCEncoder().encode(self)
    }
    static func decode(from object: xpc_object_t) throws -> XPCFrame {
        try XPCDecoder().decode(XPCFrame.self, from: object)
    }
}
```
Note: confirm `XPCEncoder().encode(_:) -> xpc_object_t` and `XPCDecoder().decode(_:from:)` signatures against `CodableXPC` in this step; adjust if the entry points differ.

- [ ] **Step 8: Run tests to verify pass**

Run: `swift test --filter XPCFrameTests --scratch-path <scratch>/build`
Expected: both tests PASS.

- [ ] **Step 9: Commit**
```bash
git add Sources/GRPCXPCTransport/XPCFrame.swift Tests/GRPCXPCTransportTests/XPCFrameTests.swift
git commit -m "feat(GRPCXPCTransport): XPCFrame wire unit + xpc round-trip"
```

---

### Task 3: `StreamChannel` — per-stream ordering state machine

**Files:**
- Create: `Sources/GRPCXPCTransport/StreamChannel.swift`
- Test: `Tests/GRPCXPCTransportTests/StreamChannelTests.swift`

**Interfaces:**
- Consumes: `XPCFrame`, `GRPCCore.RPCError`.
- Produces: `final class StreamChannel<Part: Sendable>` where the inbound side is fed frames and yields `Part`s in order.
  - `init(streamID: StreamID, makePart: @escaping (InboundEvent) -> Part?, finish: ...)` — but concretely, two typed factories are exposed:
    - `static func clientInbound(streamID:) -> (StreamChannel, RPCAsyncSequence<RPCResponsePart<[UInt8]>, any Error>)`
    - `static func serverInbound(streamID:) -> (StreamChannel, RPCAsyncSequence<RPCRequestPart<[UInt8]>, any Error>)`
  - `func accept(_ frame: XPCFrame) throws` — routes a frame into the inbound stream, enforcing order (`metadata* → message* → terminal`), rejecting a post-terminal message or a second `status` with `RPCError(code: .internalError)`.
  - `func failInbound(_ error: any Error)` — used on cancel / peer death.

- [ ] **Step 1: Write the failing test — in-order delivery + reject double terminal (server inbound)**

`Tests/GRPCXPCTransportTests/StreamChannelTests.swift`:
```swift
import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class StreamChannelTests: XCTestCase {
    func testServerInboundDeliversMetadataThenMessagesInOrder() async throws {
        let (channel, inbound) = StreamChannel.serverInbound(streamID: 1)
        try channel.accept(.metadata(1, WireMetadata(Metadata())))
        try channel.accept(.message(1, seq: 0, bytes: Data([10])))
        try channel.accept(.message(1, seq: 1, bytes: Data([11])))
        try channel.accept(.halfClose(1))            // finishes the request stream

        var kinds: [String] = []
        for try await part in inbound {
            switch part {
            case .metadata: kinds.append("md")
            case .message(let b): kinds.append("msg(\(b.first ?? 0))")
            }
        }
        XCTAssertEqual(kinds, ["md", "msg(10)", "msg(11)"])
    }

    func testARequestStreamHasNoStatusTerminator() async throws {
        // Requests terminate with halfClose, not status; a status on a request stream is a violation.
        let (channel, _) = StreamChannel.serverInbound(streamID: 2)
        XCTAssertThrowsError(try channel.accept(.status(2, code: 0, message: "", trailers: WireMetadata(Metadata()))))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter StreamChannelTests --scratch-path <scratch>/build`
Expected: FAIL (`StreamChannel` not defined).

- [ ] **Step 3: Implement `StreamChannel` with an `AsyncThrowingStream`-backed inbound and a state machine**

`Sources/GRPCXPCTransport/StreamChannel.swift`:
```swift
import Foundation
import GRPCCore
import Synchronization

/// One RPC's inbound side. Frames arrive (possibly interleaved with other streams' frames at the
/// connection); this delivers this stream's parts in order and enforces the gRPC part grammar.
final class StreamChannel<Part: Sendable>: Sendable {
    private enum Phase: Sendable { case leading, messages, terminated }
    private struct State: Sendable { var phase: Phase = .leading; var nextSeq: UInt64 = 0 }

    let streamID: StreamID
    private let state = Mutex(State())
    private let continuation: AsyncThrowingStream<Part, any Error>.Continuation
    private let toPart: @Sendable (Inbound) -> Part
    private let isServer: Bool

    enum Inbound { case metadata(Metadata); case message([UInt8]); case status(Status, Metadata) }

    private init(streamID: StreamID, isServer: Bool,
                 continuation: AsyncThrowingStream<Part, any Error>.Continuation,
                 toPart: @escaping @Sendable (Inbound) -> Part) {
        self.streamID = streamID; self.isServer = isServer
        self.continuation = continuation; self.toPart = toPart
    }

    static func serverInbound(streamID: StreamID)
    -> (StreamChannel<RPCRequestPart<[UInt8]>>, RPCAsyncSequence<RPCRequestPart<[UInt8]>, any Error>) {
        let (stream, cont) = AsyncThrowingStream.makeStream(of: RPCRequestPart<[UInt8]>.self)
        let ch = StreamChannel<RPCRequestPart<[UInt8]>>(streamID: streamID, isServer: true, continuation: cont) { ev in
            switch ev {
            case .metadata(let m): .metadata(m)
            case .message(let b): .message(b)
            case .status: fatalError("requests carry no status")
            }
        }
        return (ch, RPCAsyncSequence(wrapping: stream))
    }

    static func clientInbound(streamID: StreamID)
    -> (StreamChannel<RPCResponsePart<[UInt8]>>, RPCAsyncSequence<RPCResponsePart<[UInt8]>, any Error>) {
        let (stream, cont) = AsyncThrowingStream.makeStream(of: RPCResponsePart<[UInt8]>.self)
        let ch = StreamChannel<RPCResponsePart<[UInt8]>>(streamID: streamID, isServer: false, continuation: cont) { ev in
            switch ev {
            case .metadata(let m): .metadata(m)
            case .message(let b): .message(b)
            case .status(let s, let t): .status(s, t)
            }
        }
        return (ch, RPCAsyncSequence(wrapping: stream))
    }

    func accept(_ frame: XPCFrame) throws {
        switch frame {
        case .metadata(_, let wm):
            try state.withLock { st in
                guard st.phase == .leading || st.phase == .messages else { throw violation() }
            }
            continuation.yield(toPart(.metadata(wm.asMetadata())))
        case .message(_, let seq, let bytes):
            try state.withLock { st in
                guard st.phase != .terminated else { throw violation() }
                guard seq == st.nextSeq else { throw violation() }
                st.nextSeq += 1; st.phase = .messages
            }
            continuation.yield(toPart(.message([UInt8](bytes))))
        case .halfClose:
            // Ends the *request* direction. For a client inbound (responses), halfClose is not used;
            // for a server inbound (requests), it finishes the sequence without a status.
            if isServer { continuation.finish() }
        case .status(_, let code, let message, let trailers):
            guard !isServer else { throw violation() }   // requests have no status
            try state.withLock { st in
                guard st.phase != .terminated else { throw violation() }
                st.phase = .terminated
            }
            let status = Status(code: Status.Code(rawValue: code) ?? .unknown, message: message)
            continuation.yield(toPart(.status(status, trailers.asMetadata())))
            continuation.finish()
        default:
            break   // openStream/cancel/credit/goAway are handled by the connection, not the channel
        }
    }

    func failInbound(_ error: any Error) {
        state.withLock { $0.phase = .terminated }
        continuation.finish(throwing: error)
    }

    private func violation() -> any Error {
        RPCError(code: .internalError, message: "stream \(streamID): out-of-order or post-terminal frame")
    }
}
```
Note: confirm `RPCAsyncSequence(wrapping:)`, `Status.Code(rawValue:)`, and `Status.Code.unknown` against the resolved module; adjust if needed.

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter StreamChannelTests --scratch-path <scratch>/build`
Expected: both tests PASS.

- [ ] **Step 5: Add the post-terminal-message rejection test (client inbound)**

Append:
```swift
@available(macOS 15.0, *)
extension StreamChannelTests {
    func testClientInboundRejectsMessageAfterStatus() throws {
        let (channel, _) = StreamChannel.clientInbound(streamID: 3)
        try channel.accept(.message(3, seq: 0, bytes: Data([1])))
        try channel.accept(.status(3, code: 0, message: "ok", trailers: WireMetadata(Metadata())))
        XCTAssertThrowsError(try channel.accept(.message(3, seq: 1, bytes: Data([2]))))
    }
    func testClientInboundRejectsOutOfOrderSeq() throws {
        let (channel, _) = StreamChannel.clientInbound(streamID: 4)
        XCTAssertThrowsError(try channel.accept(.message(4, seq: 5, bytes: Data([1]))))
    }
}
```

- [ ] **Step 6: Run and confirm pass**

Run: `swift test --filter StreamChannelTests --scratch-path <scratch>/build`
Expected: all four PASS.

- [ ] **Step 7: Commit**
```bash
git add Sources/GRPCXPCTransport/StreamChannel.swift Tests/GRPCXPCTransportTests/StreamChannelTests.swift
git commit -m "feat(GRPCXPCTransport): per-stream inbound ordering state machine"
```

---

### Task 4: `XPCConnection` — session wrap, mux, demux, lifecycle (unbounded credit)

**Files:**
- Create: `Sources/GRPCXPCTransport/XPCConnection.swift`
- Test: `Tests/GRPCXPCTransportTests/XPCConnectionTests.swift`

**Interfaces:**
- Consumes: `XPCFrame`, `StreamChannel`, Apple `XPCSession`.
- Produces:
  - `final class XPCConnection: Sendable` adopting `ActorBackedByDispatchSerialQueue` semantics via an internal serial `DispatchQueue` set as the `XPCSession` target queue.
  - `init(session: XPCSession, role: Role)` where `Role = .client | .server`.
  - `func send(_ frame: XPCFrame) throws` — serialize + `session.send(message:)` (one-way; credit path added in Task 9).
  - `func openClientStream(descriptor:) -> (StreamID, RPCStream<clientInbound, clientOutbound>)` — allocates a `StreamID`, registers a `StreamChannel`, returns a full client `RPCStream`.
  - `var acceptedStreams: AsyncStream<(StreamID, MethodDescriptor)>` — server side; the demux yields each inbound `openStream`.
  - `func registerServerStream(_ id: StreamID, descriptor: MethodDescriptor) -> RPCStream<serverInbound, serverOutbound>` — server builds its side after accept.
  - `func failAll(_ error: any Error)` — on peer death / shutdown.

- [ ] **Step 1: Write the failing test — two in-process connections exchange a frame**

`Tests/GRPCXPCTransportTests/XPCConnectionTests.swift`:
```swift
import XCTest
import GRPCCore
import XPC
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class XPCConnectionTests: XCTestCase {
    func testAClientOpenStreamAppearsOnTheServersAcceptedStreams() async throws {
        // Anonymous listener + a client session dialing its endpoint, both in this process.
        let harness = try XPCPairHarness()           // defined in Step 3 (test helper)
        let (clientConn, serverConn) = try await harness.connectPair()

        let (sid, _) = clientConn.openClientStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "pkg.S", method: "M"))
        try clientConn.send(.openStream(sid, method: "pkg.S/M", deadlineNanos: nil))

        var it = serverConn.acceptedStreams.makeAsyncIterator()
        let accepted = await it.next()
        XCTAssertEqual(accepted?.0, sid)
        XCTAssertEqual(accepted?.1.fullyQualifiedMethod, "pkg.S/M")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter XPCConnectionTests --scratch-path <scratch>/build`
Expected: FAIL (`XPCConnection`, `XPCPairHarness` not defined).

- [ ] **Step 3: Implement `XPCConnection` and the test harness**

`Sources/GRPCXPCTransport/XPCConnection.swift`:
```swift
import Foundation
import GRPCCore
import Synchronization
import XPC
import CodableXPC

final class XPCConnection: Sendable {
    enum Role: Sendable { case client, server }

    let role: Role
    private let session: XPCSession
    let queue: DispatchSerialQueue
    private let nextStreamID = Atomic<UInt64>(1)

    private struct Registry: Sendable {
        var clientChannels: [StreamID: StreamChannel<RPCResponsePart<[UInt8]>>] = [:]
        var serverChannels: [StreamID: StreamChannel<RPCRequestPart<[UInt8]>>] = [:]
    }
    private let registry = Mutex(Registry())

    private let acceptedContinuation: AsyncStream<(StreamID, MethodDescriptor)>.Continuation
    let acceptedStreams: AsyncStream<(StreamID, MethodDescriptor)>

    init(session: XPCSession, role: Role, queue: DispatchSerialQueue) {
        self.session = session; self.role = role; self.queue = queue
        (acceptedStreams, acceptedContinuation) = AsyncStream.makeStream()
        session.setIncomingMessageHandler { [weak self] (message: XPCDictionary) -> XPCDictionary? in
            self?.handleInbound(message); return nil
        }
        session.setTargetQueue(queue)
    }

    func send(_ frame: XPCFrame) throws {
        try session.send(message: XPCDictionary(frame.encodeToXPC()))
    }

    private func handleInbound(_ message: XPCDictionary) {
        guard let frame = try? message.withUnsafeUnderlyingDictionary({ try XPCFrame.decode(from: $0) })
        else { return }
        route(frame)
    }

    private func route(_ frame: XPCFrame) {
        switch frame {
        case .openStream(let id, let method, _):
            let descriptor = MethodDescriptor(fullyQualifiedMethod: method)
            acceptedContinuation.yield((id, descriptor))
        case .cancel(let id, let reason):
            failStream(id, RPCError(code: .cancelled, message: reason))
        case .goAway:
            break   // Task 10
        case .credit:
            break   // Task 9
        default:
            let id = frame.streamID
            registry.withLock { reg in
                if let c = reg.clientChannels[id] { try? c.accept(frame) }
                else if let s = reg.serverChannels[id] { try? s.accept(frame) }
            }
        }
    }

    func openClientStream(descriptor: MethodDescriptor)
    -> (StreamID, RPCStream<RPCAsyncSequence<RPCResponsePart<[UInt8]>, any Error>,
                            RPCWriter<RPCRequestPart<[UInt8]>>.Closable>) {
        let id = nextStreamID.wrappingAdd(1, ordering: .relaxed).oldValue
        let (channel, inbound) = StreamChannel.clientInbound(streamID: id)
        registry.withLock { $0.clientChannels[id] = channel }
        let outbound = RPCWriter.Closable(wrapping: XPCOutboundWriter<RPCRequestPart<[UInt8]>>(
            streamID: id, connection: self))
        return (id, RPCStream(descriptor: descriptor, inbound: inbound, outbound: outbound))
    }

    func registerServerStream(_ id: StreamID, descriptor: MethodDescriptor)
    -> RPCStream<RPCAsyncSequence<RPCRequestPart<[UInt8]>, any Error>,
                 RPCWriter<RPCResponsePart<[UInt8]>>.Closable> {
        let (channel, inbound) = StreamChannel.serverInbound(streamID: id)
        registry.withLock { $0.serverChannels[id] = channel }
        let outbound = RPCWriter.Closable(wrapping: XPCOutboundWriter<RPCResponsePart<[UInt8]>>(
            streamID: id, connection: self))
        return RPCStream(descriptor: descriptor, inbound: inbound, outbound: outbound)
    }

    private func failStream(_ id: StreamID, _ error: any Error) {
        registry.withLock { reg in
            reg.clientChannels[id]?.failInbound(error); reg.clientChannels[id] = nil
            reg.serverChannels[id]?.failInbound(error); reg.serverChannels[id] = nil
        }
    }

    func failAll(_ error: any Error) {
        registry.withLock { reg in
            reg.clientChannels.values.forEach { $0.failInbound(error) }
            reg.serverChannels.values.forEach { $0.failInbound(error) }
            reg = Registry()
        }
        acceptedContinuation.finish()
    }
}

extension XPCFrame {
    var streamID: StreamID {
        switch self {
        case .openStream(let id, _, _), .metadata(let id, _), .message(let id, _, _),
             .halfClose(let id), .status(let id, _, _, _), .cancel(let id, _), .credit(let id, _):
            return id
        case .goAway: return 0
        }
    }
}
```
Add the outbound writer `Sources/GRPCXPCTransport/XPCOutboundWriter.swift`:
```swift
import GRPCCore

/// Bridges a gRPC outbound `RPCWriter` to `XPCConnection.send`. In this task `write` does not yet
/// suspend for credit (unbounded); Task 9 adds reply-as-credit.
struct XPCOutboundWriter<Part: Sendable>: ClosableRPCWriterProtocol {
    typealias Element = Part
    let streamID: StreamID
    let connection: XPCConnection
    private let seq = Atomic<UInt64>(0)   // per-writer message sequence

    func write(_ element: Part) async throws {
        try connection.send(Self.frame(for: element, streamID: streamID,
                                       seq: seq.wrappingAdd(1, ordering: .relaxed).oldValue))
    }
    func write(contentsOf elements: some Sequence<Part>) async throws {
        for e in elements { try await write(e) }
    }
    func finish() async {
        try? connection.send(.halfClose(streamID))
    }
    func finish(throwing error: any Error) async {
        try? connection.send(.cancel(streamID, reason: "\(error)"))
    }

    private static func frame(for element: Part, streamID: StreamID, seq: UInt64) -> XPCFrame {
        switch element {
        case let req as RPCRequestPart<[UInt8]>:
            switch req {
            case .metadata(let m): return .metadata(streamID, WireMetadata(m))
            case .message(let b): return .message(streamID, seq: seq, bytes: Data(b))
            }
        case let resp as RPCResponsePart<[UInt8]>:
            switch resp {
            case .metadata(let m): return .metadata(streamID, WireMetadata(m))
            case .message(let b): return .message(streamID, seq: seq, bytes: Data(b))
            case .status(let s, let t):
                return .status(streamID, code: s.code.rawValue, message: s.message, trailers: WireMetadata(t))
            }
        default:
            fatalError("unsupported part type")
        }
    }
}
```
Add the test harness `Tests/GRPCXPCTransportTests/XPCPairHarness.swift`:
```swift
import XPC
import Dispatch
@testable import GRPCXPCTransport

/// Spins up an anonymous XPCListener and dials it in-process, returning a connected
/// (client, server) XPCConnection pair. Modeled on XPCActors' RealXPCEndToEnd pattern.
@available(macOS 15.0, *)
struct XPCPairHarness {
    func connectPair() async throws -> (XPCConnection, XPCConnection) {
        // Confirm the exact XPCListener anonymous-endpoint + XPCSession(endpoint:) API against
        // the overlay while implementing; this is the one place that needs live XPC.
        fatalError("implement using XPCListener anonymous endpoint + XPCSession(endpoint:)")
    }
}
```
Note: the harness body is the single spot that must be filled against the live `XPCListener`/`XPCSession` API (anonymous endpoint, accept, dial). Confirm `XPCListener` init, `IncomingSessionRequest.accept`, `XPCEndpoint`, and `XPCSession(endpoint:targetQueue:options:)` while implementing — the reconstructed `XPCActors/XPCRawTransport.swift` `accepting`/`connecting(to:)` factories are a working reference.

- [ ] **Step 4: Implement the harness against live XPC, run the test**

Fill `XPCPairHarness.connectPair()` using `XPCListener` (anonymous), capture its `XPCEndpoint`, dial with `XPCSession(endpoint:)`, wrap both ends in `XPCConnection` with fresh `DispatchSerialQueue`s. Run:
`swift test --filter XPCConnectionTests --scratch-path <scratch>/build`
Expected: PASS (server sees the client's openStream).

- [ ] **Step 5: Commit**
```bash
git add Sources/GRPCXPCTransport/XPCConnection.swift Sources/GRPCXPCTransport/XPCOutboundWriter.swift Tests/GRPCXPCTransportTests/XPCConnectionTests.swift Tests/GRPCXPCTransportTests/XPCPairHarness.swift
git commit -m "feat(GRPCXPCTransport): XPCConnection mux/demux over XPCSession"
```

---

### Task 5: `XPCClientTransport` — connect + withStream

**Files:**
- Modify: `Sources/GRPCXPCTransport/XPCClientTransport.swift`
- Test: `Tests/GRPCXPCTransportTests/XPCClientTransportTests.swift`

**Interfaces:**
- Consumes: `XPCConnection.openClientStream`.
- Produces: a working `XPCClientTransport` whose `connect()` activates the session and blocks until shutdown, and whose `withStream` sends `openStream` then runs the closure with the client `RPCStream` + a `ClientContext`.

- [ ] **Step 1: Write the failing test — withStream sends openStream and yields a usable stream**
```swift
import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class XPCClientTransportTests: XCTestCase {
    func testWithStreamOpensAndWritesARequestMessage() async throws {
        let harness = try XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let client = XPCClientTransport(connection: clientConn)

        async let serverSaw: [UInt8]? = {
            var it = serverConn.acceptedStreams.makeAsyncIterator()
            guard let (sid, d) = await it.next() else { return nil }
            let s = serverConn.registerServerStream(sid, descriptor: d)
            for try await part in s.inbound { if case .message(let b) = part { return b } }
            return nil
        }()

        try await client.withStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "pkg.S", method: "M"),
            options: .defaults
        ) { stream, _ in
            try await stream.outbound.write(.message([42]))
            await stream.outbound.finish()
        }
        let bytes = try await serverSaw
        XCTAssertEqual(bytes, [42])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter XPCClientTransportTests --scratch-path <scratch>/build`
Expected: FAIL (`XPCClientTransport(connection:)` not defined).

- [ ] **Step 3: Implement `XPCClientTransport`**

Replace the stub body:
```swift
import GRPCCore
import Synchronization

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct XPCClientTransport: ClientTransport {
    public typealias Bytes = [UInt8]
    private let connection: XPCConnection
    private let shutdown = Mutex<CheckedContinuation<Void, Never>?>(nil)

    init(connection: XPCConnection) { self.connection = connection }

    public var retryThrottle: RetryThrottle? { nil }

    public func connect() async throws {
        await withCheckedContinuation { c in shutdown.withLock { $0 = c } }
    }
    public func beginGracefulShutdown() {
        shutdown.withLock { $0?.resume(); $0 = nil }
    }

    public func withStream<T: Sendable>(
        descriptor: MethodDescriptor,
        options: CallOptions,
        _ closure: (RPCStream<Inbound, Outbound>, ClientContext) async throws -> T
    ) async throws -> T {
        let (sid, stream) = connection.openClientStream(descriptor: descriptor)
        try connection.send(.openStream(sid, method: descriptor.fullyQualifiedMethod, deadlineNanos: nil))
        let context = ClientContext(descriptor: descriptor, remotePeer: "xpc:peer", localPeer: "xpc:self")
        return try await closure(stream, context)
    }

    public func config(forMethod descriptor: MethodDescriptor) -> MethodConfig? { nil }
}
```
Note: confirm `ClientContext.init(descriptor:remotePeer:localPeer:)` labels against the resolved module.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter XPCClientTransportTests --scratch-path <scratch>/build`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/GRPCXPCTransport/XPCClientTransport.swift Tests/GRPCXPCTransportTests/XPCClientTransportTests.swift
git commit -m "feat(GRPCXPCTransport): XPCClientTransport connect + withStream"
```

---

### Task 6: `XPCServerTransport` — listen

**Files:**
- Modify: `Sources/GRPCXPCTransport/XPCServerTransport.swift`
- Test: `Tests/GRPCXPCTransportTests/XPCServerTransportTests.swift`

**Interfaces:**
- Consumes: `XPCConnection.acceptedStreams`, `registerServerStream`.
- Produces: `XPCServerTransport.listen(streamHandler:)` that, per accepted stream, builds the server `RPCStream` and runs the handler with a `ServerContext`.

- [ ] **Step 1: Write the failing test — an echo handler replies with one message + ok status**
```swift
import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class XPCServerTransportTests: XCTestCase {
    func testListenRunsHandlerAndHandlerCanReply() async throws {
        let harness = try XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let listenTask = Task {
            try await server.listen { stream, _ in
                for try await part in stream.inbound {
                    if case .message(let b) = part {
                        try? await stream.outbound.write(.message(b))   // echo
                    }
                }
                try? await stream.outbound.write(.status(Status(code: .ok, message: ""), Metadata()))
                await stream.outbound.finish()
            }
        }
        defer { listenTask.cancel(); server.beginGracefulShutdown() }

        var echoed: [UInt8]?
        try await client.withStream(descriptor: MethodDescriptor(fullyQualifiedService: "pkg.S", method: "Echo"),
                                     options: .defaults) { stream, _ in
            try await stream.outbound.write(.message([7]))
            await stream.outbound.finish()
            for try await part in stream.inbound { if case .message(let b) = part { echoed = b } }
        }
        XCTAssertEqual(echoed, [7])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter XPCServerTransportTests --scratch-path <scratch>/build`
Expected: FAIL.

- [ ] **Step 3: Implement `XPCServerTransport.listen`**
```swift
import GRPCCore

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class XPCServerTransport: ServerTransport {
    public typealias Bytes = [UInt8]
    private let connection: XPCConnection

    init(connection: XPCConnection) { self.connection = connection }

    public func listen(
        streamHandler: @escaping @Sendable (RPCStream<Inbound, Outbound>, ServerContext) async -> Void
    ) async throws {
        await withTaskGroup(of: Void.self) { group in
            for await (sid, descriptor) in connection.acceptedStreams {
                let stream = connection.registerServerStream(sid, descriptor: descriptor)
                let context = ServerContext(descriptor: descriptor, remotePeer: "xpc:peer",
                                            localPeer: "xpc:self", cancellation: .init())
                group.addTask { await streamHandler(stream, context) }
            }
        }
    }

    public func beginGracefulShutdown() {
        connection.failAll(RPCError(code: .unavailable, message: "server shutting down"))
    }
}
```
Note: confirm `ServerContext.init(...)` and `RPCCancellationHandle` construction against the resolved module (labels may differ; the 2.4.1 shape has `descriptor`, `remotePeer`, `localPeer`, `cancellation`, optional `transportSpecific`).

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter XPCServerTransportTests --scratch-path <scratch>/build`
Expected: PASS (full unary echo across two in-process XPC sessions).

- [ ] **Step 5: Commit**
```bash
git add Sources/GRPCXPCTransport/XPCServerTransport.swift Tests/GRPCXPCTransportTests/XPCServerTransportTests.swift
git commit -m "feat(GRPCXPCTransport): XPCServerTransport listen + unary echo end-to-end"
```

---

### Task 7: All four call types over the mux

**Files:**
- Test: `Tests/GRPCXPCTransportTests/CallTypeTests.swift`
- Modify (if a gap surfaces): `Sources/GRPCXPCTransport/StreamChannel.swift`, `XPCOutboundWriter.swift`

**Interfaces:**
- Consumes: everything from Tasks 4–6. No new production types expected; this task proves the streaming shapes work and fixes any ordering/half-close gaps they expose.

- [ ] **Step 1: Write failing tests for server-streaming, client-streaming, bidi using the raw transports**

`Tests/GRPCXPCTransportTests/CallTypeTests.swift` — three tests driving `withStream` directly (no generated stubs yet):
```swift
import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class CallTypeTests: XCTestCase {
    // Server-streaming: client sends 1 message + halfClose, server writes 3 messages + status.
    func testServerStreaming() async throws { try await run(clientMessages: [[1]], serverReplies: [[1],[2],[3]]) }
    // Client-streaming: client sends 3 messages + halfClose, server writes 1 aggregate + status.
    func testClientStreaming() async throws { try await run(clientMessages: [[1],[2],[3]], serverReplies: [[6]]) }
    // Bidi: 2 in, 2 out, interleaved.
    func testBidiStreaming() async throws { try await run(clientMessages: [[1],[2]], serverReplies: [[9],[8]]) }

    private func run(clientMessages: [[UInt8]], serverReplies: [[UInt8]]) async throws {
        let harness = try XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)
        let listen = Task {
            try await server.listen { stream, _ in
                for try await part in stream.inbound { _ = part }        // drain requests
                for r in serverReplies { try? await stream.outbound.write(.message(r)) }
                try? await stream.outbound.write(.status(Status(code: .ok, message: ""), Metadata()))
                await stream.outbound.finish()
            }
        }
        defer { listen.cancel() }
        var got: [[UInt8]] = []
        try await client.withStream(descriptor: .init(fullyQualifiedService: "p.S", method: "M"),
                                    options: .defaults) { stream, _ in
            for m in clientMessages { try await stream.outbound.write(.message(m)) }
            await stream.outbound.finish()
            for try await part in stream.inbound { if case .message(let b) = part { got.append(b) } }
        }
        XCTAssertEqual(got, serverReplies)
    }
}
```

- [ ] **Step 2: Run — expect failures or hangs that reveal half-close/ordering gaps**

Run: `swift test --filter CallTypeTests --scratch-path <scratch>/build`
Expected: some FAIL/hang if `halfClose` handling on the server-inbound side or seq numbering across mixed parts is off.

- [ ] **Step 3: Fix the gaps surfaced (half-close finishes only the request direction; message seq is per-direction)**

Ensure `XPCOutboundWriter`'s `seq` counts only `.message` frames (metadata/status don't consume seq), and that server-side `halfClose` finishes the request sequence without terminating the response direction. Adjust `StreamChannel.accept`/`XPCOutboundWriter.write` accordingly (the message-seq guard in `StreamChannel` must only increment on `.message`).

- [ ] **Step 4: Run to verify all pass**

Run: `swift test --filter CallTypeTests --scratch-path <scratch>/build`
Expected: all three PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/GRPCXPCTransport Tests/GRPCXPCTransportTests/CallTypeTests.swift
git commit -m "feat(GRPCXPCTransport): all four call types over the mux"
```

---

### Task 8: Backpressure — reply-as-credit via handoffReply

**Files:**
- Create: `Sources/GRPCXPCTransport/Backpressure.swift`
- Modify: `Sources/GRPCXPCTransport/XPCConnection.swift` (send-with-reply, credit on consume), `XPCOutboundWriter.swift` (await credit)
- Test: `Tests/GRPCXPCTransportTests/BackpressureTests.swift`

**Interfaces:**
- Consumes: `XPCReceivedMessage.handoffReply(to:_:)` (confirm return shape at implementation — fall back to an explicit `.credit` frame if it cannot carry the reply, per spec risk).
- Produces:
  - `XPCConnection.sendAwaitingCredit(_ frame:) async throws` — sends a `message` frame expecting a credit reply and suspends until it arrives.
  - `StreamChannel` gains a demand signal: a credit is produced when the consumer pulls the next element.

- [ ] **Step 1: Write the failing test — a slow reader bounds the writer's in-flight count**
```swift
import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class BackpressureTests: XCTestCase {
    func testSlowReaderSuspendsWriter() async throws {
        let harness = try XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let gate = AsyncGate()   // test helper: server reads only when opened
        let listen = Task {
            try await server.listen { stream, _ in
                for try await part in stream.inbound { _ = part; await gate.wait() }
            }
        }
        defer { listen.cancel() }

        let inFlight = Atomic<Int>(0)
        let writer = Task {
            try await client.withStream(descriptor: .init(fullyQualifiedService: "p.S", method: "M"),
                                        options: .defaults) { stream, _ in
                for i in 0..<100 {
                    inFlight.wrappingAdd(1, ordering: .relaxed)
                    try await stream.outbound.write(.message([UInt8(i & 0xFF)]))
                    inFlight.wrappingSubtract(1, ordering: .relaxed)
                }
            }
        }
        // With no credit, writes suspend: only a bounded number get in-flight before blocking.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(inFlight.load(ordering: .relaxed), 100, "writer should be suspended by backpressure")
        gate.openForever(); _ = try await writer.value
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BackpressureTests --scratch-path <scratch>/build`
Expected: FAIL (writes never suspend; inFlight reaches 100).

- [ ] **Step 3: Implement reply-as-credit**

`Sources/GRPCXPCTransport/Backpressure.swift` holds the `AsyncGate` production analog if needed and the credit continuation registry. In `XPCConnection`:
- `sendAwaitingCredit`: send the `message` via `XPCSession.send(_:replyHandler:)` (the reply is the credit); suspend on a `CheckedContinuation` resumed when the reply handler fires.
- On the receive side, when a `message` frame arrives, defer its reply with `handoffReply(to: queue) { produce credit when consumer pulls }`. Wire the "consumer pulled" signal from `StreamChannel` (yield-with-demand): the credit closure runs after the reader consumes the element (bridge `AsyncThrowingStream`'s buffering/`onTermination`, or use a bounded buffer with an explicit ack).

`XPCOutboundWriter.write(_ message:)` calls `connection.sendAwaitingCredit(frame)` for `.message` parts; metadata/status/halfClose stay one-way via `connection.send`.

Note: confirm `XPCSession.send(_:replyHandler:)` and `XPCReceivedMessage.handoffReply(to:_:)` exact signatures at this step (the reply value type). If `handoffReply` cannot carry the credit as its return, switch to sending an explicit `.credit(streamID, n:)` frame from the consumer side and have `sendAwaitingCredit` await a per-stream credit counter instead — the wire already defines `.credit`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter BackpressureTests --scratch-path <scratch>/build`
Expected: PASS (inFlight bounded while the reader is gated).

- [ ] **Step 5: Add C1–C4 guards and a balance test**

Add the suspend/resume valve as a guarded `enum State { case running, suspended }` under a `Mutex` (C1), driven only off-actor (C2). Add a test that opening/closing the coarse valve never over-resumes (assert no crash across 50 toggles). Document C3 (connection-near) and C4 (bidi credit) inline; add a bidi credit test asserting a slow *client* reader suspends the *server* writer.

- [ ] **Step 6: Run and commit**

Run: `swift test --filter BackpressureTests --scratch-path <scratch>/build`
Expected: all PASS.
```bash
git add Sources/GRPCXPCTransport Tests/GRPCXPCTransportTests/BackpressureTests.swift
git commit -m "feat(GRPCXPCTransport): reply-as-credit backpressure via handoffReply"
```

---

### Task 9: Cancellation, deadlines, graceful shutdown, peer death

**Files:**
- Modify: `Sources/GRPCXPCTransport/XPCConnection.swift`, `XPCClientTransport.swift`, `XPCServerTransport.swift`
- Test: `Tests/GRPCXPCTransportTests/LifecycleTests.swift`

**Interfaces:**
- Consumes: `CallOptions.timeout`, `ServerContext.cancellation`, the `XPCSession` cancellation handler.
- Produces: `cancel`/`goAway` frame handling; deadline timers; peer-death failure.

- [ ] **Step 1: Write failing tests**
```swift
import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class LifecycleTests: XCTestCase {
    func testClientCancelFailsServerInbound() async throws { /* client sends .cancel; server's inbound throws RPCError(.cancelled) */ }
    func testPeerDeathFailsAllStreams() async throws { /* cancel the client session; server streams fail with .unavailable */ }
    func testDeadlineFiresCancel() async throws { /* CallOptions.timeout small; both sides unblock with .deadlineExceeded */ }
    func testGracefulShutdownRefusesNewStreams() async throws { /* after beginGracefulShutdown, openStream is rejected */ }
}
```
Fill each body concretely following the Task 6/8 harness pattern (drive `withStream`/`listen`, assert the thrown `RPCError.code`). Each test is self-contained.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter LifecycleTests --scratch-path <scratch>/build`
Expected: FAIL.

- [ ] **Step 3: Implement**
- Route `.cancel` → `failStream(id, RPCError(code: .cancelled, ...))` (already stubbed in Task 4; verify).
- Install the `XPCSession` cancellation handler → `failAll(RPCError(code: .unavailable, ...))` (reuse the XPCActors death-channel pattern).
- In `withStream`, if `options.timeout != nil`, start a `Task.sleep` timer that sends `.cancel(sid, reason: "deadline")` and fails the local inbound with `RPCError(code: .deadlineExceeded, ...)`; cancel the timer when the closure returns.
- `beginGracefulShutdown` sets a `draining` flag (reject new `openClientStream`/accept), sends `.goAway`, drains, then tears down.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter LifecycleTests --scratch-path <scratch>/build`
Expected: all PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/GRPCXPCTransport Tests/GRPCXPCTransportTests/LifecycleTests.swift
git commit -m "feat(GRPCXPCTransport): cancel, deadlines, graceful shutdown, peer death"
```

---

### Task 10: End-to-end with generated stubs (echo.proto)

**Files:**
- Create: `Tests/GRPCXPCTransportTests/Generated/echo.proto` (reference)
- Create: `Tests/GRPCXPCTransportTests/Generated/echo.pb.swift`, `echo.grpc.swift` (checked-in `protoc` output)
- Test: `Tests/GRPCXPCTransportTests/EchoServiceTests.swift`

**Interfaces:**
- Consumes: `XPCClientTransport`, `XPCServerTransport`, generated `Echo` client/server, `GRPCServer`/`GRPCClient` from GRPCCore.
- Produces: the top-level `XPCTransport` convenience that pairs a server+client (mirroring `InProcessTransport`), used by the service test.

- [ ] **Step 1: Author `echo.proto` with one method per call type**
```proto
syntax = "proto3";
package echo;
message EchoRequest { string text = 1; }
message EchoResponse { string text = 1; }
service Echo {
  rpc Unary(EchoRequest) returns (EchoResponse);
  rpc ServerStream(EchoRequest) returns (stream EchoResponse);
  rpc ClientStream(stream EchoRequest) returns (EchoResponse);
  rpc Bidi(stream EchoRequest) returns (stream EchoResponse);
}
```

- [ ] **Step 2: Generate and check in the stubs**

Run `protoc` with the grpc-swift plugin (matching 2.4.1) to produce `echo.pb.swift` and `echo.grpc.swift`; commit them. Document the exact `protoc`/plugin invocation in a comment header of `echo.grpc.swift`.

- [ ] **Step 3: Write the failing service-level test (all four methods)**
```swift
import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class EchoServiceTests: XCTestCase {
    func testAllFourMethodsOverXPC() async throws {
        let harness = try XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = GRPCServer(transport: XPCServerTransport(connection: serverConn),
                                services: [EchoServiceImpl()])
        let client = GRPCClient(transport: XPCClientTransport(connection: clientConn))
        async let _ = server.serve()
        async let _ = client.runConnections()
        let echo = Echo.Client(wrapping: client)
        // Unary
        let u = try await echo.unary(.with { $0.text = "hi" })
        XCTAssertEqual(u.text, "hi")
        // ... server-stream, client-stream, bidi assertions ...
        server.beginGracefulShutdown(); client.beginGracefulShutdown()
    }
}
```
Fill the streaming assertions and `EchoServiceImpl` concretely against the generated protocol (the generated `Echo.SimpleServiceProtocol`/`Echo.Client` names come from the plugin; confirm while implementing).

- [ ] **Step 4: Run to verify fail, implement `XPCTransport` convenience + service impl, run to pass**

Run: `swift test --filter EchoServiceTests --scratch-path <scratch>/build`
Expected: PASS — a real grpc-swift service round-trips all four call types over XPC.

- [ ] **Step 5: Commit**
```bash
git add Tests/GRPCXPCTransportTests/Generated Tests/GRPCXPCTransportTests/EchoServiceTests.swift Sources/GRPCXPCTransport
git commit -m "test(GRPCXPCTransport): echo service, all four call types over XPC end-to-end"
```

---

### Task 11: Full-suite + Swift 6 verification

**Files:** none (verification only)

- [ ] **Step 1: Full build + tests, both language modes intact**

Run:
```bash
swift build --scratch-path <scratch>/build
swift test --scratch-path <scratch>/build
```
Expected: all targets build; `GRPCXPCTransportTests` green alongside the existing 342 XPCActors + 25 CodableXPC tests.

- [ ] **Step 2: Confirm per-target language modes unchanged**

Run: `swift build -v --scratch-path <scratch>/build 2>&1 | grep -oE "module-name [A-Za-z]+ .*-swift-version [0-9]" | grep -oE "module-name [A-Za-z]+|swift-version [0-9]" | paste - - | sort -u`
Expected: `GRPCXPCTransport` and `XPCActors` = 6; the rest = 5.

- [ ] **Step 3: Confirm no strict-concurrency regressions in GRPCXPCTransport**

Run: `swift build --target GRPCXPCTransport --scratch-path <scratch>/build 2>&1 | grep -c warning:`
Expected: `0`.

- [ ] **Step 4: Commit any final touch-ups, then open the PR when ready.**
```bash
git commit --allow-empty -m "chore(GRPCXPCTransport): milestone 1 complete (all four call types over XPC)"
```
```

---

### Task 12: Standard gRPC framing for payloads, metadata and status

**Inserted 2026-08-19 by user decision** ("make the byte-frame encoding as standard as possible").
Executed **before Task 5**, so Tasks 5–10 and their tests are written against the standard shape
instead of being retrofitted. Reverses spec deviation D4 and adds D5 — read both in the spec.

**Files:**
- Create: `Sources/GRPCXPCTransport/GRPCMessageFraming.swift`
- Modify: `Sources/GRPCXPCTransport/XPCFrame.swift` (WireMetadata: drop `tag`, adopt `-bin`)
- Modify: `Sources/GRPCXPCTransport/XPCOutboundWriter.swift` (frame payloads on write)
- Modify: `Sources/GRPCXPCTransport/StreamChannel.swift` (unframe payloads on accept)
- Test: `Tests/GRPCXPCTransportTests/GRPCMessageFramingTests.swift`
- Test: `Tests/GRPCXPCTransportTests/XPCFrameTests.swift` (metadata cases)

**Interfaces:**
- Consumes: `XPCFrame`, `WireMetadata`, `StreamChannel`, `XPCOutboundWriter` as built in Tasks 2–4.
- Produces:
  - `enum GRPCMessageFraming` with
    `static func frame(_ payload: [UInt8]) -> Data` and
    `static func unframe(_ data: Data) throws -> [UInt8]`.
  - `WireMetadata` without a `tag` field: binary-vs-string is decided by the `-bin` key suffix.
  - `XPCFrame.message`'s `bytes` now carries the length-prefixed form.

- [ ] **Step 1: Write the failing framing tests**

`Tests/GRPCXPCTransportTests/GRPCMessageFramingTests.swift`:
```swift
import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class GRPCMessageFramingTests: XCTestCase {

    /// The standard envelope: 1 byte compressed-flag (0), then 4 bytes big-endian length.
    func testFramingProducesTheStandardFiveBytePrefix() {
        let framed = GRPCMessageFraming.frame([0xAA, 0xBB, 0xCC])
        XCTAssertEqual([UInt8](framed), [0x00, 0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC])
    }

    func testAnEmptyPayloadStillCarriesThePrefix() {
        XCTAssertEqual([UInt8](GRPCMessageFraming.frame([])), [0x00, 0x00, 0x00, 0x00, 0x00])
    }

    func testRoundTrip() throws {
        let payload: [UInt8] = Array(0..<200)
        XCTAssertEqual(try GRPCMessageFraming.unframe(GRPCMessageFraming.frame(payload)), payload)
    }

    /// Length is big-endian, so a payload longer than 255 bytes must not fit in the last byte.
    func testLengthIsBigEndian() {
        let framed = GRPCMessageFraming.frame([UInt8](repeating: 7, count: 300))
        XCTAssertEqual([UInt8](framed.prefix(5)), [0x00, 0x00, 0x00, 0x01, 0x2C])
    }

    func testATruncatedFrameIsRejected() {
        XCTAssertThrowsError(try GRPCMessageFraming.unframe(Data([0x00, 0x00, 0x00])))
    }

    /// Declared length longer than the bytes present.
    func testALengthMismatchIsRejected() {
        XCTAssertThrowsError(
            try GRPCMessageFraming.unframe(Data([0x00, 0x00, 0x00, 0x00, 0x09, 0x01])))
    }

    /// Compression is not implemented in v1; a set flag must be refused, not ignored.
    func testACompressedFlagIsRejected() {
        XCTAssertThrowsError(
            try GRPCMessageFraming.unframe(Data([0x01, 0x00, 0x00, 0x00, 0x01, 0x41])))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GRPCMessageFramingTests --scratch-path <scratch>/build`
Expected: FAIL — `GRPCMessageFraming` not defined.

- [ ] **Step 3: Implement the framing**

`Sources/GRPCXPCTransport/GRPCMessageFraming.swift`:
```swift
import Foundation
import GRPCCore

/// gRPC's standard `Length-Prefixed-Message`:
///
///     Compressed-Flag (1 byte) | Message-Length (4 bytes, big-endian) | Message
///
/// This is the exact byte sequence gRPC carries in an HTTP/2 DATA frame, so a payload framed here
/// is byte-identical to one from any other gRPC implementation. XPC already delimits messages, so
/// the prefix is redundant for *correctness* — it is here for interoperability (see spec D4).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum GRPCMessageFraming {

    static let prefixLength = 5

    static func frame(_ payload: [UInt8]) -> Data {
        var out = Data(capacity: prefixLength + payload.count)
        out.append(0)                                   // compressed-flag: v1 never compresses
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
        out.append(contentsOf: payload)
        return out
    }

    static func unframe(_ data: Data) throws -> [UInt8] {
        guard data.count >= prefixLength else {
            throw RPCError(code: .internalError,
                           message: "gRPC message frame is \(data.count) bytes, shorter than its "
                                  + "\(prefixLength)-byte prefix")
        }
        let bytes = [UInt8](data)
        guard bytes[0] == 0 else {
            throw RPCError(code: .unimplemented,
                           message: "compressed gRPC messages are not supported (flag \(bytes[0]))")
        }
        let declared = (UInt32(bytes[1]) << 24) | (UInt32(bytes[2]) << 16)
                     | (UInt32(bytes[3]) << 8)  |  UInt32(bytes[4])
        let payload = bytes.dropFirst(prefixLength)
        guard payload.count == Int(declared) else {
            throw RPCError(code: .internalError,
                           message: "gRPC message frame declares \(declared) bytes but carries "
                                  + "\(payload.count)")
        }
        return Array(payload)
    }
}
```

- [ ] **Step 4: Run to verify the framing tests pass**

Run: `swift test --filter GRPCMessageFramingTests --scratch-path <scratch>/build`
Expected: PASS (7/7).

- [ ] **Step 5: Write the failing metadata test for the `-bin` discriminator**

Append to `Tests/GRPCXPCTransportTests/XPCFrameTests.swift`:
```swift
@available(macOS 15.0, *)
extension XPCFrameTests {

    /// gRPC's own discriminator is the key suffix, not a private tag: `-bin` means the value is
    /// raw binary, anything else is UTF-8 text.
    func testTheBinSuffixDiscriminatesBinaryFromString() throws {
        var md = Metadata()
        md.addString("plain", forKey: "a")
        md.addBinary([0x00, 0xFF], forKey: "b-bin")
        let restored = WireMetadata(md).asMetadata()
        XCTAssertEqual(Array(restored[stringValues: "a"]), ["plain"])
        XCTAssertEqual(Array(restored[binaryValues: "b-bin"]).first, [0x00, 0xFF])
    }

    /// gRPC requires lowercase keys; a mixed-case key must normalize, not round-trip verbatim.
    func testKeysAreNormalizedToLowercase() throws {
        var md = Metadata()
        md.addString("v", forKey: "Mixed-Case")
        let restored = WireMetadata(md).asMetadata()
        XCTAssertEqual(Array(restored[stringValues: "mixed-case"]), ["v"])
    }

    /// Order and repeats survive, through the real xpc encoder this time.
    func testRepeatedKeysAndOrderSurviveTheXPCRoundTrip() throws {
        var md = Metadata()
        md.addString("1", forKey: "k")
        md.addString("2", forKey: "k")
        md.addBinary([0x09], forKey: "raw-bin")
        let frame = XPCFrame.metadata(1, WireMetadata(md))
        let back = try XPCFrame.decode(from: try frame.encodeToXPC())
        guard case .metadata(_, let wire) = back else { return XCTFail("wrong case: \(back)") }
        let restored = wire.asMetadata()
        XCTAssertEqual(Array(restored[stringValues: "k"]), ["1", "2"])
        XCTAssertEqual(Array(restored[binaryValues: "raw-bin"]).first, [0x09])
    }
}
```

- [ ] **Step 6: Run to verify these fail, then drop `tag` from `WireMetadata`**

Run: `swift test --filter XPCFrameTests --scratch-path <scratch>/build`
Expected: FAIL on the lowercase and/or `-bin` expectations while `tag` still decides the kind.

Then change `WireMetadata` so `Entry` is `{ key: String; bytes: Data }` — no `tag` — with `init(_:)`
lowercasing keys and `asMetadata()` choosing `addBinary` when `key.hasSuffix("-bin")` and
`addString` otherwise. Keep it an ordered array so repeats and order survive (that property is
already tested).

- [ ] **Step 7: Run to verify all frame tests pass**

Run: `swift test --filter XPCFrameTests --scratch-path <scratch>/build`
Expected: PASS.

- [ ] **Step 8: Move payload framing to the transport boundary**

`XPCOutboundWriter`: where a `.message` part becomes a `.message` frame, wrap the payload —
`bytes: GRPCMessageFraming.frame(payloadBytes)`. `StreamChannel.accept`: where a `.message` frame
becomes a `.message` part, unwrap it — `try GRPCMessageFraming.unframe(bytes)` — and let a framing
error travel the same path as a grammar violation (fail the stream, do not deliver). Nothing else
changes: `seq` accounting, the ordering grammar and the terminal rules stay exactly as they are.

- [ ] **Step 9: Run the full suite**

Run: `swift test --scratch-path <scratch>/build`
Expected: every existing test still green — the mux and connection tests now carry standard-framed
payloads end to end, which is the real proof this landed.

- [ ] **Step 10: Commit**
```bash
git add Sources/GRPCXPCTransport Tests/GRPCXPCTransportTests
git commit -m "feat(GRPCXPCTransport): standard gRPC framing for payloads, metadata and status"
```
