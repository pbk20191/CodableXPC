# XPCActors Phase A — Codec and Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the packet framing, correlation, and transport layer of `XPCActors` — a complete, tested messaging substrate that imports nothing from `Distributed`.

**Architecture:** A `Packet` is a validating view over an `xpc_object_t` dictionary carrying a four-key envelope plus a Codable body. `RawTransportProtocol` abstracts the byte pipe so the same `Transport` runs over real XPC or an in-process loopback. Replies are ordinary inbound packets matched by `seq` against a local table; the XPC reply channel is never used.

**Tech Stack:** Swift 6.0+ compiler in `-swift-version 5` mode, SwiftPM tools-version 5.7, XCTest, Apple's `XPC` overlay (macOS 14+), `CodableXPC`'s `XPCEncoder` / `XPCDecoder`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-06-xpc-distributed-actor-system-design.md`. Phase A only.
- Every declaration in `Sources/XPCActors` carries `@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)`. Every test class carries the same.
- Package-wide `platforms:` stays `.macOS(.v10_13)` / `.macCatalyst("13.1")`. Do not change it.
- `swift-tools-version: 5.7` stays. Do not raise it.
- `XPCActors` depends on `CodableXPC` only, plus `import XPC` and `import Foundation`. **Never** depend on `XPCCompat` (its `Dictionary` collides with the overlay) and **never** `import Distributed` in Phase A.
- All wire integers are XPC `uint64`. Narrower Swift types are range-checked on decode.
- Envelope keys are exactly `version`, `kind`, `seq`, `body`. `seq` is present only for `kind ∈ {request, reply}`.
- `version` is `0` on `hello` / `helloAck` and the negotiated value on everything else. `0` is never a valid negotiated version.
- Never read an integer with `xpc_dictionary_get_uint64`: it returns `0` for a missing key and cannot distinguish absent from zero. Always `xpc_dictionary_get_value` + `xpc_get_type` check.
- Test style follows the existing repo: `import XCTest`, `final class NameTests: XCTestCase`, `func testThing()`.

---

### Task 1: Package target and transport error types

**Files:**
- Modify: `Package.swift`
- Create: `Sources/XPCActors/Errors.swift`
- Test: `Tests/XPCActorsTests/ErrorsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `RawTransportError`, `TransportError`, `SetupError`, `PacketCodingError` — all `Error`, all `Equatable`, all `Sendable`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCActorsTests/ErrorsTests.swift`:

```swift
import XCTest
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class ErrorsTests: XCTestCase {

    func testRawTransportErrorCarriesMessage() {
        let error = RawTransportError.rawTransportCancelled(message: "peer went away")
        XCTAssertEqual(error, .rawTransportCancelled(message: "peer went away"))
        XCTAssertNotEqual(error, .rawTransportCancelled(message: "something else"))
    }

    func testTransportErrorDistinguishesCancellationSources() {
        // These are different failures and must never compare equal: one means the
        // pipe died, the other means our own caller walked away.
        XCTAssertNotEqual(
            TransportError.transportCancelled(message: "closed"),
            TransportError.taskCancelled
        )
    }

    func testSetupErrorDescriptionIncludesMessage() {
        let error = SetupError("version 9 unsupported")
        XCTAssertTrue(error.description.contains("version 9 unsupported"))
    }

    func testPacketCodingErrorCasesAreDistinct() {
        XCTAssertNotEqual(PacketCodingError.bodyIsNotADictionary, .malformedEnvelope)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ErrorsTests`
Expected: FAIL — the `XPCActors` module does not exist, so the build fails with "no such module 'XPCActors'".

- [ ] **Step 3: Add the target to Package.swift**

In `Package.swift`, add to `products:` after the `XPCCompatSystem` library:

```swift
        .library(
            name: "XPCActors",
            targets: ["XPCActors"]),
```

Add to `targets:` after the `XPCCompatSystem` target:

```swift
        // macOS 14+ only: a DistributedActorSystem over XPC. Split out because
        // `import Distributed` puts an LC_LOAD_DYLIB on libswiftDistributed.dylib,
        // which is macOS 13+ and in no back-deployment set -- the same trap
        // `import System` set for CodableXPC. A 10.15 consumer links CodableXPC
        // and never loads it.
        .target(
            name: "XPCActors",
            dependencies: ["CodableXPC"]),
```

Add to `targets:` after the `XPCCompatSystemTests` test target:

```swift
        .testTarget(
            name: "XPCActorsTests",
            dependencies: ["XPCActors"]),
```

- [ ] **Step 4: Write the error types**

Create `Sources/XPCActors/Errors.swift`:

```swift
import Foundation

/// A failure of the byte pipe itself, below any notion of a request.
///
/// These never cross the wire. A failure reported *by the peer* arrives as an
/// `err` reply body instead, and is surfaced in Phase B as `RemoteCallError`.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum RawTransportError: Error, Equatable, Sendable {
    case rawTransportCancelled(message: String)
}

/// A failure of a correlated exchange.
///
/// `taskCancelled` is deliberately distinct from `transportCancelled`: the first
/// means our own caller walked away and the peer is still healthy, the second
/// means the pipe is gone. Only the first should provoke a cancellation
/// notification to the peer.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum TransportError: Error, Equatable, Sendable {
    case transportCancelled(message: String)
    case taskCancelled
}

/// A failure to bring a session up: connecting, activating, or agreeing a version.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct SetupError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "SetupError(\(message))" }
}

/// A packet or body that does not satisfy the wire contract.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum PacketCodingError: Error, Equatable, Sendable {
    /// A body encoded to something other than an xpc dictionary. Every body type
    /// in this protocol is a struct, so this means a programming error.
    case bodyIsNotADictionary
    /// The envelope was absent, mistyped, or violated the presence rules for its kind.
    case malformedEnvelope
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ErrorsTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Verify the deployment floor did not move**

Run: `swift build 2>&1 | tail -5`
Expected: builds clean. If you see errors about `XPCActors` requiring a newer platform, an `@available` annotation is missing — every top-level declaration in the module needs one.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/XPCActors/Errors.swift Tests/XPCActorsTests/ErrorsTests.swift
git commit -m "feat(XPCActors): add target and transport error types"
```

---

### Task 2: Protocol version

**Files:**
- Create: `Sources/XPCActors/ProtocolVersion.swift`
- Test: `Tests/XPCActorsTests/ProtocolVersionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ProtocolVersion` — `RawRepresentable` over `UInt64`, `Hashable`, `Comparable`, `Sendable`. Statics: `.unnegotiated` (0), `.v1` (1), `.minimumSupported`, `.current`. Method: `static func negotiate(peerMin:peerMax:) -> ProtocolVersion?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCActorsTests/ProtocolVersionTests.swift`:

```swift
import XCTest
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class ProtocolVersionTests: XCTestCase {

    func testUnnegotiatedIsZeroAndIsNotSupported() {
        XCTAssertEqual(ProtocolVersion.unnegotiated.rawValue, 0)
        // Zero is reserved to mean "no version agreed yet" on hello/helloAck.
        // If it ever became negotiable, a malformed packet would be indistinguishable
        // from a handshake packet.
        XCTAssertLessThan(ProtocolVersion.unnegotiated, ProtocolVersion.minimumSupported)
    }

    func testCurrentIsV1() {
        XCTAssertEqual(ProtocolVersion.current, .v1)
        XCTAssertEqual(ProtocolVersion.v1.rawValue, 1)
    }

    func testNegotiatePicksHighestCommonVersion() {
        XCTAssertEqual(ProtocolVersion.negotiate(peerMin: 1, peerMax: 1), .v1)
        XCTAssertEqual(ProtocolVersion.negotiate(peerMin: 1, peerMax: 99), .current)
    }

    func testNegotiateFailsWhenRangesDoNotOverlap() {
        // Peer is from the future and dropped support for everything we speak.
        XCTAssertNil(ProtocolVersion.negotiate(peerMin: 50, peerMax: 99))
        // Peer only speaks the reserved sentinel.
        XCTAssertNil(ProtocolVersion.negotiate(peerMin: 0, peerMax: 0))
    }

    func testNegotiateRejectsInvertedRange() {
        XCTAssertNil(ProtocolVersion.negotiate(peerMin: 9, peerMax: 1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProtocolVersionTests`
Expected: FAIL — "cannot find 'ProtocolVersion' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCActors/ProtocolVersion.swift`:

```swift
import Foundation

/// The wire protocol version.
///
/// Apple's `XPCSystem` ships no version field and no handshake, which is how two
/// observable builds of it came to disagree on `SharedActorKey` coding without
/// anything detecting the break. This type exists so that cannot happen here.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct ProtocolVersion: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Reserved: "no version agreed yet". Valid only on `hello` and `helloAck`,
    /// and never the result of a successful negotiation.
    public static let unnegotiated = ProtocolVersion(rawValue: 0)

    public static let v1 = ProtocolVersion(rawValue: 1)

    public static let minimumSupported = v1
    public static let current = v1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The highest version both ends speak, or `nil` if there is none.
    public static func negotiate(peerMin: UInt64, peerMax: UInt64) -> ProtocolVersion? {
        guard peerMin <= peerMax else { return nil }
        let low = Swift.max(peerMin, minimumSupported.rawValue)
        let high = Swift.min(peerMax, current.rawValue)
        guard low <= high else { return nil }
        return ProtocolVersion(rawValue: high)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProtocolVersionTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/ProtocolVersion.swift Tests/XPCActorsTests/ProtocolVersionTests.swift
git commit -m "feat(XPCActors): add ProtocolVersion with negotiation"
```

---

### Task 3: Packet envelope

**Files:**
- Create: `Sources/XPCActors/Packet.swift`
- Test: `Tests/XPCActorsTests/PacketEnvelopeTests.swift`

**Interfaces:**
- Consumes: `ProtocolVersion`, `PacketCodingError`.
- Produces:
  - `enum PacketKind: UInt64` — `.request` 0, `.reply` 1, `.notification` 2, `.hello` 3, `.helloAck` 4.
  - `struct PacketHeader` — `var version: ProtocolVersion`, `var kind: PacketKind`, `var seq: UInt64?`; `init?(version:kind:seq:)` returning `nil` on a contract violation.
  - `struct Packet` — `var header: PacketHeader`, `var payload: Packet.Payload`; `init(header:payload:)`, `init?(rawValue: xpc_object_t)`, `var rawValue: xpc_object_t`.
  - `enum EnvelopeKey` with `static let version/kind/seq/body: String`.
  - `Packet.Payload` is defined in Task 4; for this task use the stub given in Step 3.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCActorsTests/PacketEnvelopeTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class PacketEnvelopeTests: XCTestCase {

    private func emptyBody() -> Packet.Payload {
        Packet.Payload(unchecked: xpc_dictionary_create(nil, nil, 0))
    }

    // MARK: header contract

    func testRequestRequiresSeqAndRealVersion() {
        XCTAssertNotNil(PacketHeader(version: .v1, kind: .request, seq: 7))
        XCTAssertNil(PacketHeader(version: .v1, kind: .request, seq: nil))
        XCTAssertNil(PacketHeader(version: .unnegotiated, kind: .request, seq: 7))
    }

    func testNotificationForbidsSeq() {
        XCTAssertNotNil(PacketHeader(version: .v1, kind: .notification, seq: nil))
        // A notification with a seq would be ambiguous with a request.
        XCTAssertNil(PacketHeader(version: .v1, kind: .notification, seq: 7))
    }

    func testHandshakeRequiresUnnegotiatedVersionAndNoSeq() {
        XCTAssertNotNil(PacketHeader(version: .unnegotiated, kind: .hello, seq: nil))
        XCTAssertNotNil(PacketHeader(version: .unnegotiated, kind: .helloAck, seq: nil))
        XCTAssertNil(PacketHeader(version: .v1, kind: .hello, seq: nil))
        XCTAssertNil(PacketHeader(version: .unnegotiated, kind: .hello, seq: 1))
    }

    // MARK: round trip

    func testRequestRoundTrips() throws {
        let header = try XCTUnwrap(PacketHeader(version: .v1, kind: .request, seq: 42))
        let packet = Packet(header: header, payload: emptyBody())
        let decoded = try XCTUnwrap(Packet(rawValue: packet.rawValue))
        XCTAssertEqual(decoded.header, header)
    }

    func testNotificationRoundTripsWithoutSeq() throws {
        let header = try XCTUnwrap(PacketHeader(version: .v1, kind: .notification, seq: nil))
        let packet = Packet(header: header, payload: emptyBody())
        let raw = packet.rawValue
        XCTAssertNil(xpc_dictionary_get_value(raw, EnvelopeKey.seq), "seq must be absent, not zero")
        let decoded = try XCTUnwrap(Packet(rawValue: raw))
        XCTAssertNil(decoded.header.seq)
    }

    // MARK: golden fixture — pins the wire format

    func testEnvelopeGoldenFixture() throws {
        let header = try XCTUnwrap(PacketHeader(version: .v1, kind: .request, seq: 42))
        let packet = Packet(header: header, payload: emptyBody())
        // If this assertion fails, the wire format changed. That is allowed, but it
        // must be deliberate: bump ProtocolVersion.current in the same commit.
        XCTAssertEqual(
            normalizedDescription(packet.rawValue),
            "{body=dict{},kind=uint64(0),seq=uint64(42),version=uint64(1)}"
        )
    }

    // MARK: rejection

    func testRejectsNonDictionary() {
        XCTAssertNil(Packet(rawValue: xpc_string_create("nope")))
    }

    func testRejectsMissingKind() {
        let dict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.version, 1)
        xpc_dictionary_set_value(dict, EnvelopeKey.body, xpc_dictionary_create(nil, nil, 0))
        XCTAssertNil(Packet(rawValue: dict))
    }

    func testRejectsUnknownKind() {
        let dict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.version, 1)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.kind, 99)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.seq, 1)
        xpc_dictionary_set_value(dict, EnvelopeKey.body, xpc_dictionary_create(nil, nil, 0))
        XCTAssertNil(Packet(rawValue: dict))
    }

    func testRejectsWrongTypeForKind() {
        // A string where a uint64 belongs. xpc_dictionary_get_uint64 would silently
        // return 0 here and decode this as a valid request -- which is exactly why
        // the implementation must type-check instead.
        let dict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.version, 1)
        xpc_dictionary_set_string(dict, EnvelopeKey.kind, "0")
        xpc_dictionary_set_uint64(dict, EnvelopeKey.seq, 1)
        xpc_dictionary_set_value(dict, EnvelopeKey.body, xpc_dictionary_create(nil, nil, 0))
        XCTAssertNil(Packet(rawValue: dict))
    }

    func testRejectsBodyThatIsNotADictionary() {
        let dict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.version, 1)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.kind, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.seq, 1)
        xpc_dictionary_set_string(dict, EnvelopeKey.body, "not a dictionary")
        XCTAssertNil(Packet(rawValue: dict))
    }

    func testRejectsMissingBody() {
        let dict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.version, 1)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.kind, 2)
        XCTAssertNil(Packet(rawValue: dict))
    }
}
```

- [ ] **Step 2: Add the golden-fixture helper**

Create `Tests/XPCActorsTests/NormalizedDescription.swift`:

```swift
import Foundation
import XPC

/// A stable, sorted rendering of an xpc object, for golden-fixture assertions.
///
/// `xpc_copy_description` is not usable for this: its output includes pointer
/// values and its dictionary ordering is unspecified.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
func normalizedDescription(_ object: xpc_object_t, topLevel: Bool = true) -> String {
    switch xpc_get_type(object) {
    case XPC_TYPE_DICTIONARY:
        var pairs: [String] = []
        xpc_dictionary_apply(object) { key, value in
            pairs.append("\(String(cString: key))=\(normalizedDescription(value, topLevel: false))")
            return true
        }
        // The outermost object is always the thing under test, so it needs no type
        // tag; nested values do, to keep a dictionary distinguishable from an array
        // at a glance. Do not invert this: the golden fixtures are written to it.
        let prefix = topLevel ? "" : "dict"
        return prefix + "{" + pairs.sorted().joined(separator: ",") + "}"
    case XPC_TYPE_ARRAY:
        var items: [String] = []
        xpc_array_apply(object) { _, value in
            items.append(normalizedDescription(value))
            return true
        }
        return "[" + items.joined(separator: ",") + "]"
    case XPC_TYPE_UINT64:
        return "uint64(\(xpc_uint64_get_value(object)))"
    case XPC_TYPE_INT64:
        return "int64(\(xpc_int64_get_value(object)))"
    case XPC_TYPE_STRING:
        return "string(\(String(cString: xpc_string_get_string_ptr(object)!)))"
    case XPC_TYPE_BOOL:
        return "bool(\(xpc_bool_get_value(object)))"
    case XPC_TYPE_DOUBLE:
        return "double(\(xpc_double_get_value(object)))"
    case XPC_TYPE_NULL:
        return "null"
    default:
        return "other"
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter PacketEnvelopeTests`
Expected: FAIL — "cannot find 'Packet' in scope".

- [ ] **Step 4: Write the implementation**

Create `Sources/XPCActors/Packet.swift`:

```swift
import Foundation
import XPC

/// The four envelope keys. Exhaustive: a packet dictionary carries nothing else.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum EnvelopeKey {
    public static let version = "version"
    public static let kind = "kind"
    public static let seq = "seq"
    public static let body = "body"
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum PacketKind: UInt64, Sendable, Hashable {
    case request = 0
    case reply = 1
    case notification = 2
    case hello = 3
    case helloAck = 4
}

/// The envelope. Construction is failable because the presence rules are a
/// contract, not a convention: a notification carrying a `seq` would be
/// indistinguishable from a request, and a `hello` carrying a real version would
/// mean the sender had already negotiated one.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct PacketHeader: Hashable, Sendable {
    public let version: ProtocolVersion
    public let kind: PacketKind
    public let seq: UInt64?

    public init?(version: ProtocolVersion, kind: PacketKind, seq: UInt64?) {
        switch kind {
        case .request, .reply:
            guard seq != nil, version != .unnegotiated else { return nil }
        case .notification:
            guard seq == nil, version != .unnegotiated else { return nil }
        case .hello, .helloAck:
            guard seq == nil, version == .unnegotiated else { return nil }
        }
        self.version = version
        self.kind = kind
        self.seq = seq
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct Packet: @unchecked Sendable {
    public let header: PacketHeader
    public let payload: Payload

    public init(header: PacketHeader, payload: Payload) {
        self.header = header
        self.payload = payload
    }

    /// Parse and validate. Returns `nil` for anything that does not satisfy the
    /// envelope contract; the caller drops such packets.
    public init?(rawValue: xpc_object_t) {
        guard xpc_get_type(rawValue) == XPC_TYPE_DICTIONARY,
              let rawVersion = Packet.uint64(rawValue, EnvelopeKey.version),
              let rawKind = Packet.uint64(rawValue, EnvelopeKey.kind),
              let kind = PacketKind(rawValue: rawKind),
              let header = PacketHeader(
                  version: ProtocolVersion(rawValue: rawVersion),
                  kind: kind,
                  seq: Packet.uint64(rawValue, EnvelopeKey.seq)
              ),
              let body = xpc_dictionary_get_value(rawValue, EnvelopeKey.body),
              xpc_get_type(body) == XPC_TYPE_DICTIONARY
        else { return nil }
        self.header = header
        self.payload = Payload(unchecked: body)
    }

    public var rawValue: xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dictionary, EnvelopeKey.version, header.version.rawValue)
        xpc_dictionary_set_uint64(dictionary, EnvelopeKey.kind, header.kind.rawValue)
        if let seq = header.seq {
            xpc_dictionary_set_uint64(dictionary, EnvelopeKey.seq, seq)
        }
        xpc_dictionary_set_value(dictionary, EnvelopeKey.body, payload.object)
        return dictionary
    }

    /// Read a uint64, distinguishing "absent" from "zero".
    ///
    /// `xpc_dictionary_get_uint64` returns 0 for a missing key and for a key of the
    /// wrong type, so it cannot be used here: a packet with no `kind` would parse
    /// as a request.
    static func uint64(_ dictionary: xpc_object_t, _ key: String) -> UInt64? {
        guard let value = xpc_dictionary_get_value(dictionary, key),
              xpc_get_type(value) == XPC_TYPE_UINT64
        else { return nil }
        return xpc_uint64_get_value(value)
    }
}
```

Append a temporary stub at the end of the same file, to be replaced in Task 4:

```swift
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Packet {
    public struct Payload: @unchecked Sendable {
        let object: xpc_object_t
        init(unchecked object: xpc_object_t) { self.object = object }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PacketEnvelopeTests`
Expected: PASS, 11 tests. If the golden fixture fails, compare the two strings character by character — do not edit the expectation without understanding which key changed.

- [ ] **Step 6: Commit**

```bash
git add Sources/XPCActors/Packet.swift Tests/XPCActorsTests/PacketEnvelopeTests.swift Tests/XPCActorsTests/NormalizedDescription.swift
git commit -m "feat(XPCActors): add Packet envelope with validating parse"
```

---

### Task 4: Packet payload

**Files:**
- Create: `Sources/XPCActors/Payload.swift`
- Modify: `Sources/XPCActors/Packet.swift` — delete the `Payload` stub added in Task 3
- Test: `Tests/XPCActorsTests/PayloadTests.swift`

**Interfaces:**
- Consumes: `PacketCodingError`, `CodableXPC.XPCEncoder`, `CodableXPC.XPCDecoder`.
- Produces: `Packet.Payload` with `init(unchecked: xpc_object_t)`, `init<T: Encodable>(encoding:userInfo:) throws`, `func decode<T: Decodable>(as:userInfo:) throws -> T`, `var object: xpc_object_t`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCActorsTests/PayloadTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class PayloadTests: XCTestCase {

    struct Body: Codable, Equatable {
        let name: String
        let count: Int
    }

    func testRoundTrips() throws {
        let original = Body(name: "hello", count: 3)
        let payload = try Packet.Payload(encoding: original)
        XCTAssertEqual(try payload.decode(as: Body.self), original)
    }

    func testEncodesToADictionary() throws {
        let payload = try Packet.Payload(encoding: Body(name: "x", count: 1))
        XCTAssertEqual(xpc_get_type(payload.object), XPC_TYPE_DICTIONARY)
    }

    func testTopLevelNonDictionaryIsRejected() {
        // Every body in this protocol is a struct. A bare Int would encode to an
        // xpc int64, which the envelope's `body` slot cannot hold.
        XCTAssertThrowsError(try Packet.Payload(encoding: 42)) { error in
            XCTAssertEqual(error as? PacketCodingError, .bodyIsNotADictionary)
        }
    }

    func testUserInfoReachesTheEncoder() throws {
        let key = CodingUserInfoKey(rawValue: "test.marker")!

        struct Probe: Encodable {
            let key: CodingUserInfoKey
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(encoder.userInfo[key] as? String ?? "absent", forKey: .seen)
            }
            enum Key: String, CodingKey { case seen }
        }

        let payload = try Packet.Payload(encoding: Probe(key: key), userInfo: [key: "present"])
        // Unprefixed: this is a top-level call on the payload dictionary itself.
        XCTAssertEqual(normalizedDescription(payload.object), "{seen=string(present)}")
    }

    func testUserInfoReachesTheDecoder() throws {
        let key = CodingUserInfoKey(rawValue: "test.marker")!

        struct Probe: Decodable {
            let seen: String
            init(from decoder: Decoder) throws {
                seen = decoder.userInfo[CodingUserInfoKey(rawValue: "test.marker")!] as? String ?? "absent"
            }
        }

        let payload = try Packet.Payload(encoding: Body(name: "x", count: 1))
        let probe = try payload.decode(as: Probe.self, userInfo: [key: "present"])
        // This is the mechanism Phase B relies on to inject the session so that
        // ActorID can encode itself as a SharedActorKey.
        XCTAssertEqual(probe.seen, "present")
    }

    func testDecodingTheWrongTypeThrows() throws {
        struct Other: Codable { let totallyDifferent: [String] }
        let payload = try Packet.Payload(encoding: Body(name: "x", count: 1))
        XCTAssertThrowsError(try payload.decode(as: Other.self))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PayloadTests`
Expected: FAIL — `Packet.Payload` has no `init(encoding:)`.

- [ ] **Step 3: Delete the stub from Packet.swift**

Remove this block from the end of `Sources/XPCActors/Packet.swift`:

```swift
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Packet {
    public struct Payload: @unchecked Sendable {
        let object: xpc_object_t
        init(unchecked object: xpc_object_t) { self.object = object }
    }
}
```

- [ ] **Step 4: Write the implementation**

Create `Sources/XPCActors/Payload.swift`:

```swift
import Foundation
import XPC
import CodableXPC

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Packet {

    /// The body of a packet: an xpc dictionary produced by `CodableXPC`'s coder.
    ///
    /// `userInfo` is threaded through both directions on purpose. Phase B puts the
    /// owning session in there, which is how an `ActorID` encodes itself as a
    /// `SharedActorKey` and how a decoded key is turned back into a proxy.
    public struct Payload: @unchecked Sendable {
        public let object: xpc_object_t

        /// Wrap an object already known to be a dictionary. Only the envelope
        /// parser and tests should use this.
        init(unchecked object: xpc_object_t) {
            self.object = object
        }

        public init<T: Encodable>(
            encoding value: T,
            userInfo: [CodingUserInfoKey: Any] = [:]
        ) throws {
            var encoder = XPCEncoder()
            encoder.userInfo = userInfo
            let encoded = try encoder.encode(value)
            guard xpc_get_type(encoded) == XPC_TYPE_DICTIONARY else {
                throw PacketCodingError.bodyIsNotADictionary
            }
            self.object = encoded
        }

        public func decode<T: Decodable>(
            as type: T.Type = T.self,
            userInfo: [CodingUserInfoKey: Any] = [:]
        ) throws -> T {
            var decoder = XPCDecoder()
            decoder.userInfo = userInfo
            return try decoder.decode(type, from: object)
        }
    }
}
```

If `XPCDecoder.decode` has a different label order than `decode(_:from:)`, check
`Sources/CodableXPC/XPCDecoder.swift:16` and match it exactly rather than guessing.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PayloadTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the whole suite to check nothing regressed**

Run: `swift test`
Expected: all tests pass, including `PacketEnvelopeTests` which uses `Payload(unchecked:)`.

- [ ] **Step 7: Commit**

```bash
git add Sources/XPCActors/Payload.swift Sources/XPCActors/Packet.swift Tests/XPCActorsTests/PayloadTests.swift
git commit -m "feat(XPCActors): add Packet.Payload with userInfo-threading coder"
```

---

### Task 5: RawTransport protocol and in-process loopback

**Files:**
- Create: `Sources/XPCActors/RawTransport.swift`
- Create: `Sources/XPCActors/InProcessRawTransport.swift`
- Test: `Tests/XPCActorsTests/InProcessRawTransportTests.swift`

**Interfaces:**
- Consumes: `Packet`, `RawTransportError`.
- Produces:
  - `protocol RawTransportProtocol: AnyObject, Sendable` with `func setPacketHandler(_:)`, `func activate() throws(RawTransportError)`, `func send(packet:) throws(RawTransportError)`, `func cancel(reason:)`.
  - `final class InProcessRawTransport: RawTransportProtocol` with `static func makePair(debugName:) -> (InProcessRawTransport, InProcessRawTransport)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCActorsTests/InProcessRawTransportTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class InProcessRawTransportTests: XCTestCase {

    private func notification(_ marker: UInt64) throws -> Packet {
        let header = try XCTUnwrap(PacketHeader(version: .v1, kind: .notification, seq: nil))
        let body = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(body, "marker", marker)
        return Packet(header: header, payload: Packet.Payload(unchecked: body))
    }

    func testPacketCrossesToTheOtherEnd() throws {
        let (a, b) = InProcessRawTransport.makePair(debugName: "test")
        let received = expectation(description: "b receives")
        b.setPacketHandler { packet in
            XCTAssertEqual(Packet.uint64(packet.payload.object, "marker"), 99)
            received.fulfill()
        }
        try a.activate()
        try b.activate()
        try a.send(packet: notification(99))
        wait(for: [received], timeout: 2)
    }

    func testDeliveryIsBidirectional() throws {
        let (a, b) = InProcessRawTransport.makePair(debugName: "test")
        let atA = expectation(description: "a receives")
        a.setPacketHandler { _ in atA.fulfill() }
        try a.activate()
        try b.activate()
        try b.send(packet: notification(1))
        wait(for: [atA], timeout: 2)
    }

    func testHandlerCanReplyWithoutRecursingIntoTheSender() throws {
        // Delivery must hop queues. If it did not, a handler that sends a reply
        // would recurse into the sender's stack and deadlock under the lock.
        let (a, b) = InProcessRawTransport.makePair(debugName: "test")
        let done = expectation(description: "reply arrives")
        // Build both packets up front: the handler closure is @Sendable and must
        // not capture the XCTestCase.
        let outbound = try notification(1)
        let replyPacket = try notification(2)
        b.setPacketHandler { [weak b] _ in
            try? b?.send(packet: replyPacket)
        }
        a.setPacketHandler { packet in
            XCTAssertEqual(Packet.uint64(packet.payload.object, "marker"), 2)
            done.fulfill()
        }
        try a.activate()
        try b.activate()
        try a.send(packet: outbound)
        wait(for: [done], timeout: 2)
    }

    func testSendAfterCancelThrows() throws {
        let (a, b) = InProcessRawTransport.makePair(debugName: "test")
        try a.activate()
        try b.activate()
        a.cancel(reason: "test over")
        XCTAssertThrowsError(try a.send(packet: notification(1))) { error in
            XCTAssertEqual(
                error as? RawTransportError,
                .rawTransportCancelled(message: "test over")
            )
        }
    }

    func testCancellingOneEndStopsDeliveryToTheOther() throws {
        let (a, b) = InProcessRawTransport.makePair(debugName: "test")
        b.setPacketHandler { _ in XCTFail("must not deliver after cancel") }
        try a.activate()
        try b.activate()
        b.cancel(reason: "gone")
        XCTAssertThrowsError(try a.send(packet: notification(1)))
    }

    func testSendBeforeActivateThrows() throws {
        let (a, _) = InProcessRawTransport.makePair(debugName: "test")
        XCTAssertThrowsError(try a.send(packet: notification(1)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter InProcessRawTransportTests`
Expected: FAIL — "cannot find 'InProcessRawTransport' in scope".

- [ ] **Step 3: Write the protocol**

Create `Sources/XPCActors/RawTransport.swift`:

```swift
import Foundation

/// The byte pipe, with everything above it abstracted away.
///
/// This seam is why the whole stack is testable without XPC, a second process, or
/// an installed service, and it is where an `xpc_connection_t`-backed transport
/// would slot in later to lower the deployment floor to macOS 13.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public protocol RawTransportProtocol: AnyObject, Sendable {
    /// Install the inbound handler. Must be called before `activate()`; packets
    /// that arrive with no handler installed are dropped.
    func setPacketHandler(_ handler: @escaping @Sendable (Packet) -> Void)

    func activate() throws(RawTransportError)

    func send(packet: Packet) throws(RawTransportError)

    func cancel(reason: String)
}
```

- [ ] **Step 4: Write the loopback transport**

Create `Sources/XPCActors/InProcessRawTransport.swift`:

```swift
import Foundation
import XPC

/// Two transports wired to each other in one process.
///
/// Header framing is skipped -- the `Packet` value is handed across directly --
/// but the payload is a real encoded xpc dictionary, so serialization bugs still
/// surface on this path. That is what makes it a legitimate test substrate rather
/// than a mock.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public final class InProcessRawTransport: RawTransportProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var remoteEnd: InProcessRawTransport?
    private var handler: (@Sendable (Packet) -> Void)?
    private var activated = false
    private var cancellationReason: String?

    private init(debugName: String) {
        self.queue = DispatchQueue(label: "XPCActors.InProcess.\(debugName)")
    }

    public static func makePair(
        debugName: String = "pair"
    ) -> (InProcessRawTransport, InProcessRawTransport) {
        let a = InProcessRawTransport(debugName: "\(debugName).a")
        let b = InProcessRawTransport(debugName: "\(debugName).b")
        a.lock.withLock { a.remoteEnd = b }
        b.lock.withLock { b.remoteEnd = a }
        return (a, b)
    }

    public func setPacketHandler(_ handler: @escaping @Sendable (Packet) -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func activate() throws(RawTransportError) {
        // Explicit lock/unlock rather than `withLock`: that method is `rethrows`,
        // which cannot carry a typed `throws(RawTransportError)` out of the closure.
        lock.lock()
        let reason = cancellationReason
        if reason == nil { activated = true }
        lock.unlock()
        if let reason {
            throw RawTransportError.rawTransportCancelled(message: reason)
        }
    }

    public func send(packet: Packet) throws(RawTransportError) {
        lock.lock()
        let reason = cancellationReason
        let isActivated = activated
        let target = remoteEnd
        lock.unlock()

        if let reason {
            throw RawTransportError.rawTransportCancelled(message: reason)
        }
        guard isActivated else {
            throw RawTransportError.rawTransportCancelled(message: "not activated")
        }
        guard let target else {
            throw RawTransportError.rawTransportCancelled(message: "peer is gone")
        }
        // Hop to the peer's queue. Delivering inline would let a handler that
        // replies recurse into the sender's stack.
        target.queue.async { target.deliver(packet) }
    }

    private func deliver(_ packet: Packet) {
        let handler: (@Sendable (Packet) -> Void)? = lock.withLock {
            cancellationReason == nil && activated ? self.handler : nil
        }
        handler?(packet)
    }

    public func cancel(reason: String) {
        let peer: InProcessRawTransport? = lock.withLock {
            guard cancellationReason == nil else { return nil }
            cancellationReason = reason
            handler = nil
            let peer = remoteEnd
            remoteEnd = nil
            return peer
        }
        // Unlink from the far side so its next send fails rather than vanishing.
        peer?.lock.withLock { peer?.remoteEnd = nil }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter InProcessRawTransportTests`
Expected: PASS, 6 tests.

If `lock.withLock` with typed throws does not compile on your toolchain, replace those
blocks with explicit `lock.lock()` / `defer { lock.unlock() }` — do not widen the
thrown type to `any Error`.

- [ ] **Step 6: Commit**

```bash
git add Sources/XPCActors/RawTransport.swift Sources/XPCActors/InProcessRawTransport.swift Tests/XPCActorsTests/InProcessRawTransportTests.swift
git commit -m "feat(XPCActors): add RawTransport protocol and in-process loopback"
```

---

### Task 6: Request correlation table

**Files:**
- Create: `Sources/XPCActors/RequestTable.swift`
- Test: `Tests/XPCActorsTests/RequestTableTests.swift`

**Interfaces:**
- Consumes: `Packet`, `TransportError`.
- Produces: `actor RequestTable` with `enum Outcome { case reply(Packet.Payload), failed(TransportError) }`, `func waitForReply(seq: UInt64, sending: () throws(RawTransportError) -> Void) async -> Outcome`, `func complete(seq: UInt64, with: Outcome)`, `func failAll(with: TransportError)`, `var pendingCount: Int`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCActorsTests/RequestTableTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class RequestTableTests: XCTestCase {

    private func payload(_ marker: UInt64) -> Packet.Payload {
        let body = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(body, "marker", marker)
        return Packet.Payload(unchecked: body)
    }

    func testReplyResumesTheWaiter() async throws {
        let table = RequestTable()
        async let outcome = table.waitForReply(seq: 1, sending: {})
        // Poll until the waiter is registered, then complete it.
        while await table.pendingCount == 0 { await Task.yield() }
        await table.complete(seq: 1, with: .reply(payload(7)))
        guard case .reply(let got) = await outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(Packet.uint64(got.object, "marker"), 7)
    }

    func testCompletingAnUnknownSeqIsIgnored() async {
        let table = RequestTable()
        // A late or duplicated reply must not crash or corrupt state.
        await table.complete(seq: 999, with: .reply(payload(1)))
        let count = await table.pendingCount
        XCTAssertEqual(count, 0)
    }

    func testSecondReplyForTheSameSeqIsIgnored() async throws {
        let table = RequestTable()
        async let outcome = table.waitForReply(seq: 4, sending: {})
        while await table.pendingCount == 0 { await Task.yield() }
        await table.complete(seq: 4, with: .reply(payload(1)))
        _ = await outcome
        // Resuming a continuation twice would trap. This must be a no-op.
        await table.complete(seq: 4, with: .reply(payload(2)))
        let count = await table.pendingCount
        XCTAssertEqual(count, 0)
    }

    func testSendFailureCompletesImmediately() async {
        let table = RequestTable()
        let outcome = await table.waitForReply(seq: 2, sending: {
            throw RawTransportError.rawTransportCancelled(message: "pipe closed")
        })
        guard case .failed(.transportCancelled(let message)) = outcome else {
            return XCTFail("expected a transport failure")
        }
        XCTAssertTrue(message.contains("pipe closed"))
        let count = await table.pendingCount
        XCTAssertEqual(count, 0, "a failed send must not leave a waiter behind")
    }

    func testFailAllDrainsEveryWaiter() async throws {
        let table = RequestTable()
        async let first = table.waitForReply(seq: 10, sending: {})
        async let second = table.waitForReply(seq: 11, sending: {})
        while await table.pendingCount < 2 { await Task.yield() }
        await table.failAll(with: .transportCancelled(message: "peer died"))
        let firstOutcome = await first
        let secondOutcome = await second
        for outcome in [firstOutcome, secondOutcome] {
            guard case .failed(.transportCancelled) = outcome else {
                return XCTFail("expected a transport failure")
            }
        }
        let count = await table.pendingCount
        XCTAssertEqual(count, 0)
    }

    func testTaskCancellationUnblocksTheWaiter() async throws {
        let table = RequestTable()
        let task = Task { await table.waitForReply(seq: 20, sending: {}) }
        while await table.pendingCount == 0 { await Task.yield() }
        task.cancel()
        // There is no timeout in this protocol by design; Task cancellation is the
        // only way out of an unanswered request.
        let outcome = await task.value
        guard case .failed(.taskCancelled) = outcome else {
            return XCTFail("expected taskCancelled, got \(outcome)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RequestTableTests`
Expected: FAIL — "cannot find 'RequestTable' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCActors/RequestTable.swift`:

```swift
import Foundation

/// Correlates replies with the requests that are waiting for them.
///
/// This exists because the XPC reply channel is deliberately unused: every packet
/// goes out one-way, so a reply is just an inbound packet that happens to carry a
/// `seq` we recognise. That is what lets either side originate a call.
///
/// There is no timeout. A request waits until the peer replies, the calling task
/// is cancelled, or the transport dies.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public actor RequestTable {

    public enum Outcome: Sendable {
        case reply(Packet.Payload)
        case failed(TransportError)
    }

    private var waiters: [UInt64: CheckedContinuation<Outcome, Never>] = [:]

    public init() {}

    public var pendingCount: Int { waiters.count }

    /// Register `seq`, run `send`, and suspend until an outcome arrives.
    ///
    /// `send` runs while the actor is still synchronously executing, so a reply
    /// that lands on another task cannot slip in before the waiter is registered.
    /// Named `waitForReply` rather than `await` because `await` as a method name
    /// collides with the keyword at every call site.
    public func waitForReply(
        seq: UInt64,
        sending send: () throws(RawTransportError) -> Void
    ) async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .failed(.taskCancelled))
                    return
                }
                waiters[seq] = continuation
                do {
                    try send()
                } catch {
                    waiters.removeValue(forKey: seq)
                    continuation.resume(
                        returning: .failed(.transportCancelled(message: "\(error)"))
                    )
                }
            }
        } onCancel: {
            Task { await self.complete(seq: seq, with: .failed(.taskCancelled)) }
        }
    }

    /// Deliver an outcome. Unknown or already-completed `seq` values are ignored:
    /// a duplicated reply must not resume a continuation twice.
    public func complete(seq: UInt64, with outcome: Outcome) {
        guard let continuation = waiters.removeValue(forKey: seq) else { return }
        continuation.resume(returning: outcome)
    }

    /// Fail every outstanding request. Used when the transport dies.
    public func failAll(with error: TransportError) {
        let outstanding = waiters
        waiters.removeAll()
        for (_, continuation) in outstanding {
            continuation.resume(returning: .failed(error))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RequestTableTests`
Expected: PASS, 6 tests.

The cancellation test is the one most likely to be flaky. If it hangs, the
`onCancel` closure is not reaching `complete` — check that `RequestTable` is
declared `actor` and not `final class`.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/RequestTable.swift Tests/XPCActorsTests/RequestTableTests.swift
git commit -m "feat(XPCActors): add request correlation table"
```

---

### Task 7: Transport with version negotiation

**Files:**
- Create: `Sources/XPCActors/HandshakeBodies.swift`
- Create: `Sources/XPCActors/Transport.swift`
- Test: `Tests/XPCActorsTests/TransportTests.swift`

**Interfaces:**
- Consumes: `Packet`, `PacketHeader`, `PacketKind`, `ProtocolVersion`, `RawTransportProtocol`, `RequestTable`, `SetupError`, `TransportError`, `RawTransportError`.
- Produces:
  - `struct HelloBody: Codable` — `min: UInt64`, `max: UInt64`.
  - `struct HelloAckBody: Codable` — `version: UInt64`.
  - `enum TransportRole { case initiator, responder }`.
  - `final class Transport` with `init(debugName:role:rawTransport:)`, `var inboundRequestHandler`, `var inboundNotificationHandler`, `func activate() async throws(SetupError)`, `func sendRequest(_:) async -> RequestTable.Outcome`, `func sendNotification(_:) throws(RawTransportError)`, `func cancel(reason:)`, `var negotiatedVersion: ProtocolVersion?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCActorsTests/TransportTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class TransportTests: XCTestCase {

    struct Ping: Codable, Equatable { let value: Int }

    /// A negotiated pair, ready for traffic.
    private func makePair() async throws -> (Transport, Transport) {
        let (rawA, rawB) = InProcessRawTransport.makePair(debugName: "transport")
        let client = Transport(debugName: "client", role: .initiator, rawTransport: rawA)
        let server = Transport(debugName: "server", role: .responder, rawTransport: rawB)
        try await server.activate()
        try await client.activate()
        return (client, server)
    }

    func testNegotiationAgreesOnCurrentVersion() async throws {
        let (client, server) = try await makePair()
        XCTAssertEqual(client.negotiatedVersion, .current)
        XCTAssertEqual(server.negotiatedVersion, .current)
    }

    func testRequestGetsItsReply() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { payload, reply in
            let ping = try! payload.decode(as: Ping.self)
            reply(try! Packet.Payload(encoding: Ping(value: ping.value + 1)))
        }
        let outcome = await client.sendRequest(try Packet.Payload(encoding: Ping(value: 1)))
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 2))
    }

    func testEitherSideCanOriginateARequest() async throws {
        // This is the whole reason the XPC reply channel is unused.
        let (client, server) = try await makePair()
        client.inboundRequestHandler = { payload, reply in
            reply(try! Packet.Payload(encoding: Ping(value: 99)))
        }
        let outcome = await server.sendRequest(try Packet.Payload(encoding: Ping(value: 0)))
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 99))
    }

    func testConcurrentRequestsAreCorrelatedIndependently() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { payload, reply in
            let ping = try! payload.decode(as: Ping.self)
            reply(try! Packet.Payload(encoding: Ping(value: ping.value * 10)))
        }
        let results = await withTaskGroup(of: Int?.self) { group in
            for i in 1...20 {
                group.addTask {
                    let outcome = await client.sendRequest(
                        try! Packet.Payload(encoding: Ping(value: i))
                    )
                    guard case .reply(let p) = outcome else { return nil }
                    return try? p.decode(as: Ping.self).value
                }
            }
            return await group.reduce(into: [Int?]()) { $0.append($1) }
        }
        XCTAssertEqual(results.compactMap { $0 }.sorted(), (1...20).map { $0 * 10 })
    }

    func testNotificationArrivesWithNoReply() async throws {
        let (client, server) = try await makePair()
        let arrived = expectation(description: "notification arrives")
        server.inboundNotificationHandler = { payload in
            XCTAssertEqual(try? payload.decode(as: Ping.self), Ping(value: 5))
            arrived.fulfill()
        }
        try client.sendNotification(try Packet.Payload(encoding: Ping(value: 5)))
        await fulfillment(of: [arrived], timeout: 2)
    }

    func testCancellingTheTransportFailsOutstandingRequests() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { _, _ in }   // never replies
        let task = Task { await client.sendRequest(try! Packet.Payload(encoding: Ping(value: 1))) }
        try await Task.sleep(nanoseconds: 50_000_000)
        client.cancel(reason: "shutting down")
        guard case .failed(.transportCancelled) = await task.value else {
            return XCTFail("expected a transport failure")
        }
    }

    func testTrafficBeforeNegotiationIsRejected() async throws {
        let (rawA, rawB) = InProcessRawTransport.makePair(debugName: "unnegotiated")
        let client = Transport(debugName: "client", role: .initiator, rawTransport: rawA)
        _ = Transport(debugName: "server", role: .responder, rawTransport: rawB)
        // No activate() -- no version has been agreed.
        XCTAssertThrowsError(try client.sendNotification(try Packet.Payload(encoding: Ping(value: 1))))
    }

    func testPacketWithWrongVersionIsDropped() async throws {
        let (client, server) = try await makePair()
        server.inboundNotificationHandler = { _ in XCTFail("must not deliver") }
        // Forge a packet claiming a version nobody negotiated.
        let header = try XCTUnwrap(
            PacketHeader(version: ProtocolVersion(rawValue: 77), kind: .notification, seq: nil)
        )
        let forged = Packet(header: header, payload: try Packet.Payload(encoding: Ping(value: 1)))
        server.handleReceived(packet: forged)
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TransportTests`
Expected: FAIL — "cannot find 'Transport' in scope".

- [ ] **Step 3: Write the handshake bodies**

Create `Sources/XPCActors/HandshakeBodies.swift`:

```swift
import Foundation

/// Sent by the dialing side before anything else.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct HelloBody: Codable, Equatable, Sendable {
    public let min: UInt64
    public let max: UInt64
    public init(min: UInt64, max: UInt64) {
        self.min = min
        self.max = max
    }
    public static let current = HelloBody(
        min: ProtocolVersion.minimumSupported.rawValue,
        max: ProtocolVersion.current.rawValue
    )
}

/// The chosen version. A responder that finds no overlap cancels instead of
/// replying, so there is no "rejected" case to represent here.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct HelloAckBody: Codable, Equatable, Sendable {
    public let version: UInt64
    public init(version: UInt64) { self.version = version }
}
```

- [ ] **Step 4: Write the transport**

Create `Sources/XPCActors/Transport.swift`:

```swift
import Foundation
import XPC

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum TransportRole: Sendable {
    /// Dials out and sends `hello`.
    case initiator
    /// Listens and answers `hello` with `helloAck`.
    case responder
}

/// Packet framing, version negotiation, and request correlation.
///
/// Every packet is sent one-way; a reply is an ordinary inbound packet matched by
/// `seq`. The XPC reply channel is never used, because it binds a response to the
/// requester and would make it impossible for a listener-side peer to originate a
/// call.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public final class Transport: @unchecked Sendable {

    public typealias RequestHandler =
        @Sendable (Packet.Payload, @escaping @Sendable (Packet.Payload) -> Void) -> Void
    public typealias NotificationHandler = @Sendable (Packet.Payload) -> Void

    private let debugName: String
    private let role: TransportRole
    private let rawTransport: RawTransportProtocol
    private let requests = RequestTable()

    private let lock = NSLock()
    private var _negotiatedVersion: ProtocolVersion?
    private var _nextSeq: UInt64 = 1
    private var helloWaiter: CheckedContinuation<Result<ProtocolVersion, SetupError>, Never>?
    private var cancelled = false

    public var inboundRequestHandler: RequestHandler?
    public var inboundNotificationHandler: NotificationHandler?

    public var negotiatedVersion: ProtocolVersion? {
        lock.withLock { _negotiatedVersion }
    }

    public init(debugName: String, role: TransportRole, rawTransport: RawTransportProtocol) {
        self.debugName = debugName
        self.role = role
        self.rawTransport = rawTransport
        rawTransport.setPacketHandler { [weak self] packet in
            self?.handleReceived(packet: packet)
        }
    }

    // MARK: activation

    /// Bring the pipe up. For an initiator this performs the `hello` exchange and
    /// does not return until a version is agreed; for a responder it returns as
    /// soon as the pipe is live, and the version is set when `hello` arrives.
    public func activate() async throws(SetupError) {
        do {
            try rawTransport.activate()
        } catch {
            throw SetupError("could not activate transport: \(error)")
        }
        guard role == .initiator else { return }

        let hello: Packet
        do {
            hello = try makePacket(kind: .hello, seq: nil,
                                   payload: Packet.Payload(encoding: HelloBody.current))
        } catch {
            throw SetupError("could not encode hello: \(error)")
        }

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<ProtocolVersion, SetupError>, Never>) in
            lock.withLock { helloWaiter = continuation }
            do {
                try rawTransport.send(packet: hello)
            } catch {
                resumeHelloWaiter(with: .failure(SetupError("could not send hello: \(error)")))
            }
        }
        switch result {
        case .success(let version):
            lock.withLock { _negotiatedVersion = version }
        case .failure(let error):
            throw error
        }
    }

    // MARK: sending

    public func sendRequest(_ payload: Packet.Payload) async -> RequestTable.Outcome {
        let seq = nextSeq()
        let packet: Packet
        do {
            packet = try makeNegotiatedPacket(kind: .request, seq: seq, payload: payload)
        } catch {
            // Typed throws: `error` is a RawTransportError here.
            return .failed(.transportCancelled(message: "\(error)"))
        }
        return await requests.waitForReply(seq: seq) { [rawTransport] in
            try rawTransport.send(packet: packet)
        }
    }

    public func sendNotification(_ payload: Packet.Payload) throws(RawTransportError) {
        let packet = try makeNegotiatedPacket(kind: .notification, seq: nil, payload: payload)
        try rawTransport.send(packet: packet)
    }

    public func cancel(reason: String) {
        let alreadyCancelled: Bool = lock.withLock {
            defer { cancelled = true }
            return cancelled
        }
        guard !alreadyCancelled else { return }
        rawTransport.cancel(reason: reason)
        resumeHelloWaiter(with: .failure(SetupError("transport cancelled: \(reason)")))
        Task { await requests.failAll(with: .transportCancelled(message: reason)) }
    }

    // MARK: receiving

    /// Internal for tests; the raw transport calls this for every inbound packet.
    func handleReceived(packet: Packet) {
        switch packet.header.kind {
        case .hello:
            handleHello(packet)
        case .helloAck:
            handleHelloAck(packet)
        case .request, .reply, .notification:
            guard packet.header.version == negotiatedVersion else { return }
            handleNegotiated(packet)
        }
    }

    private func handleNegotiated(_ packet: Packet) {
        switch packet.header.kind {
        case .request:
            guard let seq = packet.header.seq, let handler = inboundRequestHandler else { return }
            handler(packet.payload) { [weak self] reply in
                self?.sendReply(seq: seq, payload: reply)
            }
        case .reply:
            guard let seq = packet.header.seq else { return }
            Task { await requests.complete(seq: seq, with: .reply(packet.payload)) }
        case .notification:
            inboundNotificationHandler?(packet.payload)
        case .hello, .helloAck:
            break
        }
    }

    private func sendReply(seq: UInt64, payload: Packet.Payload) {
        guard let packet = try? makeNegotiatedPacket(kind: .reply, seq: seq, payload: payload)
        else { return }
        try? rawTransport.send(packet: packet)
    }

    private func handleHello(_ packet: Packet) {
        guard role == .responder else { return }
        guard let body = try? packet.payload.decode(as: HelloBody.self),
              let version = ProtocolVersion.negotiate(peerMin: body.min, peerMax: body.max)
        else {
            cancel(reason: "no common protocol version")
            return
        }
        guard let ack = try? makePacket(
            kind: .helloAck, seq: nil,
            payload: Packet.Payload(encoding: HelloAckBody(version: version.rawValue))
        ) else {
            cancel(reason: "could not encode helloAck")
            return
        }
        lock.withLock { _negotiatedVersion = version }
        try? rawTransport.send(packet: ack)
    }

    private func handleHelloAck(_ packet: Packet) {
        guard role == .initiator else { return }
        guard let body = try? packet.payload.decode(as: HelloAckBody.self) else {
            resumeHelloWaiter(with: .failure(SetupError("malformed helloAck")))
            return
        }
        let version = ProtocolVersion(rawValue: body.version)
        guard version >= ProtocolVersion.minimumSupported,
              version <= ProtocolVersion.current
        else {
            resumeHelloWaiter(
                with: .failure(SetupError("peer chose unsupported version \(body.version)"))
            )
            return
        }
        resumeHelloWaiter(with: .success(version))
    }

    private func resumeHelloWaiter(with result: Result<ProtocolVersion, SetupError>) {
        let waiter: CheckedContinuation<Result<ProtocolVersion, SetupError>, Never>? =
            lock.withLock {
                defer { helloWaiter = nil }
                return helloWaiter
            }
        waiter?.resume(returning: result)
    }

    // MARK: helpers

    private func nextSeq() -> UInt64 {
        lock.withLock {
            defer { _nextSeq += 1 }
            return _nextSeq
        }
    }

    private func makePacket(
        kind: PacketKind, seq: UInt64?, payload: Packet.Payload
    ) throws -> Packet {
        guard let header = PacketHeader(version: .unnegotiated, kind: kind, seq: seq) else {
            throw SetupError("invalid handshake header for \(kind)")
        }
        return Packet(header: header, payload: payload)
    }

    private func makeNegotiatedPacket(
        kind: PacketKind, seq: UInt64?, payload: Packet.Payload
    ) throws(RawTransportError) -> Packet {
        guard let version = negotiatedVersion else {
            throw RawTransportError.rawTransportCancelled(message: "no version negotiated yet")
        }
        guard let header = PacketHeader(version: version, kind: kind, seq: seq) else {
            throw RawTransportError.rawTransportCancelled(message: "invalid header for \(kind)")
        }
        return Packet(header: header, payload: payload)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter TransportTests`
Expected: PASS, 8 tests.

`testConcurrentRequestsAreCorrelatedIndependently` is the important one: if it
returns duplicated or missing values, `nextSeq()` is not actually atomic or a reply
is being routed to the wrong waiter.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: everything passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/XPCActors/HandshakeBodies.swift Sources/XPCActors/Transport.swift Tests/XPCActorsTests/TransportTests.swift
git commit -m "feat(XPCActors): add Transport with hello version negotiation"
```

---

### Task 8: XPC-backed transport

**Files:**
- Create: `Sources/XPCActors/XPCRawTransport.swift`
- Test: `Tests/XPCActorsTests/XPCRawTransportTests.swift`

**Interfaces:**
- Consumes: `RawTransportProtocol`, `Packet`, `RawTransportError`, Apple's `XPCSession` / `XPCListener` / `XPCDictionary` / `XPCEndpoint`.
- Produces: `final class XPCRawTransport: RawTransportProtocol` with
  `init(session: XPCSession, isAlreadyActive: Bool)`,
  `func handleIncoming(_ message: XPCDictionary)`,
  `static func connecting(to: XPCEndpoint, targetQueue: DispatchQueue?) throws -> XPCRawTransport`,
  `static func accepting(_ request: XPCListener.IncomingSessionRequest) -> (XPCListener.IncomingSessionRequest.Decision, XPCRawTransport)`.

**Read this before starting.** This task binds to Apple's overlay, which is the one
thing in Phase A that cannot be checked against the spec alone. Open
`/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/swift/XPC.swiftmodule/arm64e-apple-ios-macabi.swiftinterface`
and confirm these four before writing code — if a signature differs, follow the
interface file, not this plan:
- line ~190: `struct XPCDictionary` and `init(_ value: xpc_object_t)`, plus whatever
  property exposes the underlying `xpc_object_t`.
- line ~494: `accept(incomingMessageHandler: @Sendable (XPCDictionary) -> XPCDictionary?, cancellationHandler:) -> (Decision, XPCSession)`.
- line ~512: `XPCListener.init(targetQueue:options:incomingSessionHandler:)` — the
  anonymous, no-service-name initializer — and `XPCListener.endpoint`.
- line ~669: `XPCSession.send(message: XPCDictionary) throws`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCActorsTests/XPCRawTransportTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCActors

/// Tier 3: real XPC, one process.
///
/// An anonymous `XPCListener` publishes an endpoint that we dial from this same
/// process. That exercises the real overlay and real message passing without
/// needing an installed service or a second process.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class XPCRawTransportTests: XCTestCase {

    struct Ping: Codable, Equatable { let value: Int }

    /// Keeps the server side alive; it is built inside the listener callback.
    final class ServerBox: @unchecked Sendable {
        var transport: Transport?
    }

    func testRequestReplyOverRealXPC() async throws {
        let serverReady = expectation(description: "server transport built")
        let box = ServerBox()

        let listener = XPCListener(targetQueue: nil, options: .none) { request in
            let (decision, raw) = XPCRawTransport.accepting(request)
            let transport = Transport(debugName: "server", role: .responder, rawTransport: raw)
            transport.inboundRequestHandler = { payload, reply in
                guard let ping = try? payload.decode(as: Ping.self),
                      let body = try? Packet.Payload(encoding: Ping(value: ping.value + 1))
                else { return }
                reply(body)
            }
            box.transport = transport
            // A responder's activate() only brings the pipe up; it does not block
            // on a peer. The accepted session is already live, so this is a no-op
            // beyond installing the handler.
            Task { try? await transport.activate() }
            serverReady.fulfill()
            return decision
        }
        try listener.activate()

        let clientRaw = try XPCRawTransport.connecting(to: listener.endpoint)
        let client = Transport(debugName: "client", role: .initiator, rawTransport: clientRaw)
        try await client.activate()

        await fulfillment(of: [serverReady], timeout: 5)
        XCTAssertEqual(client.negotiatedVersion, .current, "hello must complete over real XPC")

        let outcome = await client.sendRequest(try Packet.Payload(encoding: Ping(value: 41)))
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 42))

        client.cancel(reason: "test over")
        listener.cancel()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter XPCRawTransportTests`
Expected: FAIL — "cannot find 'XPCRawTransport' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCActors/XPCRawTransport.swift`:

```swift
import Foundation
import XPC

/// A `RawTransport` over Apple's `XPCSession`.
///
/// Sends are one-way: `XPCSession.send(message:)`, never `send(message:replyHandler:)`.
/// The incoming-message handler always returns `nil`, so XPC's reply channel stays
/// unused and replies travel as ordinary inbound packets. That is what allows the
/// listener side to originate calls.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public final class XPCRawTransport: RawTransportProtocol, @unchecked Sendable {

    private let session: XPCSession
    private let isAlreadyActive: Bool
    private let lock = NSLock()
    private var handler: (@Sendable (Packet) -> Void)?
    private var cancellationReason: String?

    /// - Parameter isAlreadyActive: `true` for a session handed to us by
    ///   `IncomingSessionRequest.accept`, which is live on return. Activating such
    ///   a session a second time throws.
    public init(session: XPCSession, isAlreadyActive: Bool = false) {
        self.session = session
        self.isAlreadyActive = isAlreadyActive
    }

    public func setPacketHandler(_ handler: @escaping @Sendable (Packet) -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func activate() throws(RawTransportError) {
        guard !isAlreadyActive else { return }
        do {
            try session.activate()
        } catch {
            throw RawTransportError.rawTransportCancelled(
                message: "could not activate XPCSession: \(error)"
            )
        }
    }

    public func send(packet: Packet) throws(RawTransportError) {
        if let reason = lock.withLock({ cancellationReason }) {
            throw RawTransportError.rawTransportCancelled(message: reason)
        }
        do {
            try session.send(message: XPCDictionary(packet.rawValue))
        } catch {
            throw RawTransportError.rawTransportCancelled(message: "XPCSession send: \(error)")
        }
    }

    public func cancel(reason: String) {
        let shouldCancel: Bool = lock.withLock {
            guard cancellationReason == nil else { return false }
            cancellationReason = reason
            handler = nil
            return true
        }
        guard shouldCancel else { return }
        session.cancel(reason: reason)
    }

    /// Feed an inbound `XPCDictionary` in. Wire this to the session's or the
    /// listener's incoming-message handler, which must return `nil`.
    public func handleIncoming(_ message: XPCDictionary) {
        guard let packet = Packet(rawValue: message.xpcObject) else { return }
        let handler = lock.withLock { self.handler }
        handler?(packet)
    }
}
```

If `XPCDictionary` exposes its underlying object under a different property name than
`xpcObject`, use the real name from the swiftinterface you read at the top of this
task. Do not add a bridging shim; the overlay has `init(_ value: xpc_object_t)` so a
symmetric accessor exists.

- [ ] **Step 4: Add the two connection factories**

Both sides have the same chicken-and-egg problem: the incoming-message handler has to
reference the transport, and the transport needs the session the handler is installed
on. A small box breaks the cycle.

Append to `Sources/XPCActors/XPCRawTransport.swift`:

```swift
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension XPCRawTransport {

    /// Holds the transport so an incoming-message handler can reach it before the
    /// transport itself exists.
    final class Box: @unchecked Sendable {
        var transport: XPCRawTransport?
    }

    /// Dial `endpoint`. The session comes back inactive; `activate()` starts it.
    public static func connecting(
        to endpoint: XPCEndpoint,
        targetQueue: DispatchQueue? = nil
    ) throws -> XPCRawTransport {
        let box = Box()
        let session = try XPCSession(
            endpoint: endpoint,
            targetQueue: targetQueue,
            options: .inactive,
            incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                box.transport?.handleIncoming(message)
                return nil   // never use XPC's reply channel
            }
        )
        let transport = XPCRawTransport(session: session, isAlreadyActive: false)
        box.transport = transport
        return transport
    }

    /// Accept an inbound peer. The returned session is already live, so the
    /// transport is built with `isAlreadyActive: true`.
    public static func accepting(
        _ request: XPCListener.IncomingSessionRequest
    ) -> (XPCListener.IncomingSessionRequest.Decision, XPCRawTransport) {
        let box = Box()
        let (decision, session) = request.accept(
            incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                box.transport?.handleIncoming(message)
                return nil
            }
        )
        let transport = XPCRawTransport(session: session, isAlreadyActive: true)
        box.transport = transport
        return (decision, transport)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter XPCRawTransportTests`
Expected: PASS, 1 test.

This test talks to real XPC. If it hangs, the most likely cause is that the session
was created without `.inactive` and activated twice, or that the incoming-message
handler was never installed on one side.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: everything passes.

- [ ] **Step 7: Verify a back-deploying consumer is unaffected**

Run: `swift build --target CodableXPC 2>&1 | tail -3`
Expected: builds clean. `CodableXPC` must not have gained any dependency on `XPCActors`.

- [ ] **Step 8: Commit**

```bash
git add Sources/XPCActors/XPCRawTransport.swift Tests/XPCActorsTests/XPCRawTransportTests.swift
git commit -m "feat(XPCActors): add XPCSession-backed raw transport"
```

---

## Phase A completion criteria

Phase A is done when all of these hold:

- `swift test` passes with no filter.
- `Sources/XPCActors` contains no `import Distributed`. Verify: `grep -r "import Distributed" Sources/XPCActors` returns nothing.
- The golden fixture in `PacketEnvelopeTests.testEnvelopeGoldenFixture` is unmodified from Task 3, or was changed in a commit that also bumped `ProtocolVersion.current`.
- `Package.swift` still declares `.macOS(.v10_13)` and `swift-tools-version: 5.7`.

Phase B builds `Session`, `ActorID`, `SharedActorKey`, the invocation coders, and the
`DistributedActorSystem` conformance on top of this. It is the first phase that imports
`Distributed`.
