# XPCActors Phase B — session, identity, invocation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `distributed actor` calls work end to end over the Phase A transport — a real `DistributedActorSystem` conformance with identity, per-peer sessions, invocation coding, and error propagation.

**Architecture:** Phase A left a pure messaging layer: `Transport` sends a `Packet.Payload` under a `seq` and hands inbound requests to a handler. Phase B adds the two layers above it. `Session` owns per-peer state — the wire-facing table of shared actors — and turns an inbound request packet into `executeDistributedTarget`. `XPCActorSystem` is the `DistributedActorSystem` conformance the Swift runtime talks to: it assigns IDs, resolves proxies, and turns `remoteCall` into a request packet. Identity is the load-bearing trick: an `ActorID` never puts its own contents on the wire, it reads the session out of `encoder.userInfo` and writes a `SharedActorKey` instead.

**Tech Stack:** Swift 6.4, `Distributed` module, `CodableXPC` (`XPCEncoder`/`XPCDecoder`), libxpc, XCTest.

## Global Constraints

Copied verbatim from the spec. Every task's requirements implicitly include this section.

- **Availability.** Every public type carries `@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)`, matching Phase A. `import Distributed` puts an `LC_LOAD_DYLIB` on `libswiftDistributed.dylib`, which is why `XPCActors` is a separate target from `CodableXPC`.
- **Wire format is normative, version 1.** Field names, discriminator values, and presence rules below are the format. A change to any of them breaks the tier-1 golden fixtures on purpose, forcing a deliberate decision about bumping `ProtocolVersion.current`.
- **`SerializationRequirement` is `any Codable`.**
- **There is no timeout, by decision.** `Task` cancellation is the only way out of a wait, plus the death channel Phase A already installed.
- **Transport is one-way.** Every packet is sent with `Transport.sendRequest` / `sendNotification`; the XPC reply channel is never used. A reply is an inbound packet matched by `seq`.
- **Nothing below `Session` imports `Distributed`.** `Packet`, `Payload`, `Transport`, `RequestTable`, `SharedActorKey`, `TypeName`, and `ActorID` must all compile without it.
- **Neither half of a `RawActorID` is transmitted.** `systemID` and `instanceID` never leave the process.
- **Encoding an `ActorID` with no session in `userInfo` is a programmer error and traps.**
- **Non-throwing violation traps.** When a target throws and the request carried no `errorType`, the receiver traps rather than replying.
- **Argument labels are discarded**, and there is no per-argument type tag on the wire.
- **`generics` is spelled correctly** — Apple's `genericSubsitutions` misspelling is not reproduced.
- **Explicit discriminators from the start** for `SharedActorKey` and notification kinds; never Swift's synthesized enum coding.
- **Deliberate omissions:** no `Direct` invocation path, no `ServiceRegistry`, no `protocolStub`. Do not add them.
- **Out of scope for Phase B:** `Service` / `EphemeralService`, peer requirement *enforcement*, `BackpressureManager`, priority escalation. These are Phase C. The wire enum cases they will use (`err.kind == 3`, notification kinds 1 and 2) are defined here so the format is complete, but nothing produces them yet.

### Wire format reference

Request body:

```
actor        : SharedActorKey
target       : string      mangled RemoteCallTarget identifier
generics     : [string]    mangled type names
args         : [ ... ]     positional; no per-argument type tag
errorType    : string?     mangled type name
returnType   : string?     mangled type name
basePriority : uint64?     TaskPriority raw value
```

Reply body — exactly one of `ok` or `err`; neither or both fails decoding:

```
ok  : <encoded return value>          -- an empty dictionary for Void
err : { kind: uint64, type: string?, value: <encoded>?, text: string }
```

`err.kind`: 0 target threw · 1 encoding the result failed · 2 no actor for the given key · 3 peer requirement not satisfied · 4 session is not accepting inbound invocations · 5 request could not be decoded.

Notification body — no envelope `seq`; the request is named in the body:

```
kind       : uint64    0 invocationCancelled, 1 invocationEscalated, 2 responseEscalated
requestSeq : uint64    the request being referred to
priority   : uint64?   TaskPriority raw value; present for kinds 1 and 2
```

`SharedActorKey`: `kind` 0 → `type` : string (mangled) · 1 → `name` : string · 2 → `id` : uint64.

### What Phase A already provides

Read as given; do not modify unless a task says so.

```swift
public enum PacketKind: UInt64 { case request = 0, reply = 1, notification = 2, hello = 3, helloAck = 4 }
public struct PacketHeader { let version: ProtocolVersion; let kind: PacketKind; let seq: UInt64? }
public struct Packet { let header: PacketHeader; let payload: Payload; init?(rawValue: xpc_object_t); var rawValue: xpc_object_t }

extension Packet {
    public struct Payload: @unchecked Sendable {
        public let object: xpc_object_t
        public init<T: Encodable>(encoding value: T, userInfo: [CodingUserInfoKey: Any] = [:]) throws
        public func decode<T: Decodable>(as type: T.Type = T.self, userInfo: [CodingUserInfoKey: Any] = [:]) throws -> T
    }
}

public final class Transport: @unchecked Sendable {
    public typealias RequestHandler =
        @Sendable (UInt64, Packet.Payload, @escaping @Sendable (Packet.Payload) -> Void) -> Void
    public typealias NotificationHandler = @Sendable (Packet.Payload) -> Void
    public init(debugName: String, role: TransportRole, rawTransport: RawTransportProtocol)
    public var inboundRequestHandler: RequestHandler?
    public var inboundNotificationHandler: NotificationHandler?
    public var negotiatedVersion: ProtocolVersion?
    public func activate() async throws(SetupError)
    public func allocateSeq() -> UInt64
    public func sendRequest(seq: UInt64, _ payload: Packet.Payload) async -> RequestTable.Outcome
    public func sendNotification(_ payload: Packet.Payload) throws(RawTransportError)
    public func cancel(reason: String)
}

public enum TransportRole: Sendable { case initiator, responder }
public actor RequestTable { public enum Outcome: Sendable { case reply(Packet.Payload), failed(TransportError) } }
public enum TransportError: Error, Equatable, Sendable { case transportCancelled(message: String), taskCancelled }
public enum RawTransportError: Error, Equatable, Sendable { case rawTransportCancelled(message: String) }
public struct SetupError: Error, Equatable, Sendable { public let message: String; public init(_ message: String) }
public enum PacketCodingError: Error, Equatable, Sendable { case bodyIsNotADictionary }

public final class InProcessRawTransport: RawTransportProtocol {
    public static func makePair(debugName: String = "pair") -> (InProcessRawTransport, InProcessRawTransport)
}
```

Tests may use `normalizedDescription(_:)` from `Tests/XPCActorsTests/NormalizedDescription.swift` — a sorted, pointer-free rendering of an xpc object for golden fixtures. Nested dictionaries render as `dict{k=v,...}`, the top level as `{k=v,...}`, strings as `string(x)`, integers as `uint64(n)` / `int64(n)`, arrays as `[a,b]`.

### File structure

Every file goes in `Sources/XPCActors/` with its test in `Tests/XPCActorsTests/`.

| File | Responsibility |
|---|---|
| `TypeName.swift` | mangled name ↔ `Any.Type`, bidirectional cache |
| `SharedActorKey.swift` | the only actor reference that exists on the wire |
| `ActorID.swift` | `ID64`, `RawActorID`, `ActorID`, the `SessionCoding` seam, userInfo keys |
| `ActorRegistry.swift` | weak table of local actors, keyed by `RawActorID.Local` |
| `InvocationBodies.swift` | `RequestBody`, `InboundRequest`, `ReplyBody`, `NotificationBody` |
| `InvocationEncoder.swift` | `DistributedTargetInvocationEncoder` |
| `InvocationDecoder.swift` | `DistributedTargetInvocationDecoder` |
| `ResultHandler.swift` | `DistributedTargetInvocationResultHandler`; error encoding tiers |
| `Session.swift` | `SessionOptions`, per-peer state, inbound dispatch, `SessionCoding` |
| `SessionInterfaces.swift` | `LocalInterface`, `RemoteInterface`, `ActivationToken` |
| `XPCActorSystem.swift` | the `DistributedActorSystem` conformance |
| `Errors.swift` | **modify** — add `RemoteCallError` |

Two decisions are locked in here and everything else follows from them.

**The `SessionCoding` seam.** `ActorID` needs a session to encode itself, and `Session` needs `ActorID` — a cycle. `ActorID.swift` therefore depends on a small protocol, `SessionCoding`, which `Session` conforms to. This keeps `ActorID` testable with a stub and keeps `Distributed` out of `ActorID.swift`.

**Type erasure by thunk, not by existential opening.** An inbound request must call `executeDistributedTarget(on:target:invocationDecoder:handler:)`, which needs a *concrete* `Act: DistributedActor`. Rather than storing `any DistributedActor` and reopening it, we capture a closure at the one place the concrete type is statically known — `actorReady<Act>` — and store that closure. This is why `ActorRegistry` stores an `ExecuteThunk` beside each weak reference.

---

### Task 1: TypeName — mangled names with a bidirectional cache

**Files:**
- Create: `Sources/XPCActors/TypeName.swift`
- Test: `Tests/XPCActorsTests/TypeNameTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum TypeName { static func mangled(for: Any.Type) -> String?; static func type(for: String) -> Any.Type? }`

Both directions go through a cache because `_typeByName` performs a runtime lookup on every call. Apple added the same cache (`SwiftTypeCache`) between the two builds of `XPCSystem` we can observe, which is evidence it matters.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/TypeNameTests.swift
import XCTest
@testable import XPCActors

private struct Sample: Codable, Equatable { let n: Int }

@available(macOS 14, *)
final class TypeNameTests: XCTestCase {

    func testAConcreteTypeRoundTrips() throws {
        let mangled = try XCTUnwrap(TypeName.mangled(for: Sample.self))
        let recovered = try XCTUnwrap(TypeName.type(for: mangled))
        XCTAssertTrue(recovered == Sample.self)
    }

    func testGenericAndStdlibTypesRoundTrip() throws {
        for type in [Int.self as Any.Type, String.self, [Int].self, [String: Int].self, Sample?.self] {
            let mangled = try XCTUnwrap(TypeName.mangled(for: type), "\(type)")
            XCTAssertTrue(TypeName.type(for: mangled) == type, "\(type)")
        }
    }

    /// The cache must be a cache, not a second source of truth: asking twice has to
    /// give the same answer, including for a name that does not resolve.
    func testRepeatedLookupsAgree() throws {
        let mangled = try XCTUnwrap(TypeName.mangled(for: Sample.self))
        XCTAssertEqual(TypeName.mangled(for: Sample.self), mangled)
        XCTAssertTrue(TypeName.type(for: mangled) == TypeName.type(for: mangled))
    }

    func testAnUnresolvableNameReturnsNilTwice() {
        XCTAssertNil(TypeName.type(for: "not a mangled name"))
        XCTAssertNil(TypeName.type(for: "not a mangled name"))
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter TypeNameTests`
Expected: FAIL — `cannot find 'TypeName' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/XPCActors/TypeName.swift
import Foundation

/// Mangled type names, cached in both directions.
///
/// `_typeByName` performs a runtime lookup on every call, so the reverse direction
/// is cached; the forward direction is cached with it so the two stay one component.
/// Apple added the same cache to `XPCSystem` between the two builds we can observe.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum TypeName {

    private static let lock = NSLock()
    private static var byName: [String: Any.Type] = [:]
    private static var byType: [ObjectIdentifier: String] = [:]
    /// Names that did not resolve. Cached too: a peer sending an unknown type
    /// repeatedly must not cost a runtime lookup every time.
    private static var unresolvable: Set<String> = []

    public static func mangled(for type: Any.Type) -> String? {
        let key = ObjectIdentifier(type)
        if let hit = lock.withLock({ byType[key] }) { return hit }
        guard let name = _mangledTypeName(type) else { return nil }
        lock.withLock {
            byType[key] = name
            byName[name] = type
        }
        return name
    }

    public static func type(for name: String) -> Any.Type? {
        let cached: Any.Type?? = lock.withLock {
            if unresolvable.contains(name) { return .some(nil) }
            if let hit = byName[name] { return .some(hit) }
            return nil
        }
        if let cached { return cached }

        guard let resolved = _typeByName(name) else {
            lock.withLock { _ = unresolvable.insert(name) }
            return nil
        }
        lock.withLock {
            byName[name] = resolved
            byType[ObjectIdentifier(resolved)] = name
        }
        return resolved
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter TypeNameTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/TypeName.swift Tests/XPCActorsTests/TypeNameTests.swift
git commit -m "feat(XPCActors): add mangled type name cache"
```

---

### Task 2: SharedActorKey — the only actor reference on the wire

**Files:**
- Create: `Sources/XPCActors/SharedActorKey.swift`
- Test: `Tests/XPCActorsTests/SharedActorKeyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  ```swift
  public enum SharedActorKey: Hashable, Sendable, Codable {
      case type(String)     // kind 0, payload key "type"
      case name(String)     // kind 1, payload key "name"
      case dynamic(UInt64)  // kind 2, payload key "id"
  }
  ```

Coding is written by hand with an explicit `kind` discriminator. Swift's synthesized enum coding is what let Apple's two builds diverge silently; we never use it here.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/SharedActorKeyTests.swift
import XCTest
import XPC
import CodableXPC
@testable import XPCActors

@available(macOS 14, *)
final class SharedActorKeyTests: XCTestCase {

    private func encoded(_ key: SharedActorKey) throws -> String {
        normalizedDescription(try XPCEncoder().encode(key))
    }

    // MARK: tier 1 — golden fixtures

    func testTheEncodedFormIsPinned() throws {
        XCTAssertEqual(try encoded(.type("Sample")), "{kind=uint64(0),type=string(Sample)}")
        XCTAssertEqual(try encoded(.name("primary")), "{kind=uint64(1),name=string(primary)}")
        XCTAssertEqual(try encoded(.dynamic(7)), "{id=uint64(7),kind=uint64(2)}")
    }

    func testEachKindWritesOnlyItsOwnPayloadKey() throws {
        let object = try XPCEncoder().encode(SharedActorKey.type("Sample"))
        XCTAssertNil(xpc_dictionary_get_value(object, "name"))
        XCTAssertNil(xpc_dictionary_get_value(object, "id"))
    }

    // MARK: round trip

    func testEveryKindRoundTrips() throws {
        for key in [SharedActorKey.type("A"), .name("b"), .dynamic(.max)] {
            let object = try XPCEncoder().encode(key)
            XCTAssertEqual(try XPCDecoder().decode(SharedActorKey.self, from: object), key)
        }
    }

    // MARK: rejection

    func testAnUnknownKindIsRejected() throws {
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(object, "kind", 99)
        xpc_dictionary_set_string(object, "type", "Sample")
        XCTAssertThrowsError(try XPCDecoder().decode(SharedActorKey.self, from: object))
    }

    func testAKindWithoutItsPayloadIsRejected() throws {
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(object, "kind", 0)
        XCTAssertThrowsError(try XPCDecoder().decode(SharedActorKey.self, from: object))
    }

    /// The discriminator decides, not the payload. A `kind` of 1 with only a `type`
    /// key present must fail rather than quietly decoding as `.type`.
    func testTheDiscriminatorIsAuthoritative() throws {
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(object, "kind", 1)
        xpc_dictionary_set_string(object, "type", "Sample")
        XCTAssertThrowsError(try XPCDecoder().decode(SharedActorKey.self, from: object))
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter SharedActorKeyTests`
Expected: FAIL — `cannot find 'SharedActorKey' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/XPCActors/SharedActorKey.swift
import Foundation

/// An actor reference on the wire is exactly this and nothing else.
///
/// The coding is written by hand with an explicit `kind` discriminator rather than
/// Swift's synthesized enum coding. Apple's dump build used the synthesized form and
/// its shipping build moved to a `UInt8` discriminator, with nothing detecting the
/// break; an explicit discriminator from the start plus the golden fixtures in
/// `SharedActorKeyTests` is how that failure mode is closed here.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum SharedActorKey: Hashable, Sendable {
    /// The default actor for a type. Pre-agreed: a peer can import it with no round trip.
    case type(String)
    /// An actor exported under a name. Also pre-agreed.
    case name(String)
    /// An actor that crossed the wire as a value during a call.
    case dynamic(UInt64)
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension SharedActorKey: Codable {

    private enum CodingKeys: String, CodingKey {
        case kind, type, name, id
    }

    private enum Kind: UInt64 {
        case type = 0, name = 1, dynamic = 2
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .type(let mangled):
            try container.encode(Kind.type.rawValue, forKey: .kind)
            try container.encode(mangled, forKey: .type)
        case .name(let name):
            try container.encode(Kind.name.rawValue, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .dynamic(let id):
            try container.encode(Kind.dynamic.rawValue, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(UInt64.self, forKey: .kind)
        guard let kind = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown SharedActorKey kind \(raw)")
        }
        // The discriminator decides which key is read. A payload key that does not
        // match the kind is not consulted, so a mismatched pair fails rather than
        // decoding as whatever happens to be present.
        switch kind {
        case .type: self = .type(try container.decode(String.self, forKey: .type))
        case .name: self = .name(try container.decode(String.self, forKey: .name))
        case .dynamic: self = .dynamic(try container.decode(UInt64.self, forKey: .id))
        }
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter SharedActorKeyTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/SharedActorKey.swift Tests/XPCActorsTests/SharedActorKeyTests.swift
git commit -m "feat(XPCActors): add SharedActorKey with an explicit discriminator"
```

---

### Task 3: ActorID — identity that never travels

**Files:**
- Create: `Sources/XPCActors/ActorID.swift`
- Test: `Tests/XPCActorsTests/ActorIDTests.swift`

**Interfaces:**
- Consumes: `SharedActorKey` (Task 2).
- Produces:
  ```swift
  public struct ID64: Hashable, Sendable, Codable { public let rawValue: UInt64; public static func next() -> ID64 }
  public enum RawActorID: Hashable, Sendable {
      case local(Local)
      case remote(Remote)
      public struct Local: Hashable, Sendable { public let systemID: ID64; public let instanceID: ID64 }
      public struct Remote: @unchecked Sendable { public let session: any SessionCoding; public let key: SharedActorKey }
  }
  public struct ActorID: Hashable, Sendable, Codable { public let raw: RawActorID }
  public protocol SessionCoding: AnyObject, Sendable {
      func shareDynamically(_ local: RawActorID.Local) -> SharedActorKey?
      func remoteID(for key: SharedActorKey) -> ActorID
  }
  extension CodingUserInfoKey { public static let xpcActorSession: CodingUserInfoKey }
  ```

This is the heart of the design. `ActorID.encode(to:)` writes a `SharedActorKey` into a *single-value* container and nothing else — neither `systemID` nor `instanceID` leaves the process. `SessionCoding` exists to break the `ActorID` ↔ `Session` cycle, and keeps this file free of `import Distributed`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/ActorIDTests.swift
import XCTest
import XPC
import CodableXPC
@testable import XPCActors

/// Stands in for a `Session`, so identity can be tested with no transport.
@available(macOS 14, *)
private final class StubSession: SessionCoding, @unchecked Sendable {
    var shared: [RawActorID.Local] = []
    var nextDynamic: UInt64 = 1
    var refuseToShare = false

    func shareDynamically(_ local: RawActorID.Local) -> SharedActorKey? {
        guard !refuseToShare else { return nil }
        shared.append(local)
        defer { nextDynamic += 1 }
        return .dynamic(nextDynamic)
    }

    func remoteID(for key: SharedActorKey) -> ActorID {
        ActorID(raw: .remote(.init(session: self, key: key)))
    }
}

@available(macOS 14, *)
final class ActorIDTests: XCTestCase {

    private func userInfo(_ session: StubSession) -> [CodingUserInfoKey: Any] {
        [.xpcActorSession: session]
    }

    // MARK: the counter

    func testID64IsMonotonicAndUnique() {
        let ids = (0..<1000).map { _ in ID64.next() }
        XCTAssertEqual(Set(ids).count, 1000)
        XCTAssertEqual(ids, ids.sorted { $0.rawValue < $1.rawValue })
    }

    // MARK: encoding a local id shares it

    func testALocalIDEncodesAsTheSharedKeyAndNothingElse() throws {
        let session = StubSession()
        let local = RawActorID.Local(systemID: ID64.next(), instanceID: ID64.next())
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(session)

        let object = try encoder.encode(ActorID(raw: .local(local)))

        XCTAssertEqual(normalizedDescription(object), "{id=uint64(1),kind=uint64(2)}")
        XCTAssertEqual(session.shared, [local])
    }

    /// The whole point: the process-local halves are not on the wire in any form.
    func testNeitherHalfOfALocalIDIsTransmitted() throws {
        let session = StubSession()
        let local = RawActorID.Local(systemID: ID64(rawValue: 111), instanceID: ID64(rawValue: 222))
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(session)

        let rendered = normalizedDescription(try encoder.encode(ActorID(raw: .local(local))))
        XCTAssertFalse(rendered.contains("111"))
        XCTAssertFalse(rendered.contains("222"))
    }

    // MARK: encoding a remote id sends the key back unchanged

    func testARemoteIDEncodesItsOwnKey() throws {
        let session = StubSession()
        let id = session.remoteID(for: .name("primary"))
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(session)

        XCTAssertEqual(normalizedDescription(try encoder.encode(id)),
                       "{kind=uint64(1),name=string(primary)}")
        XCTAssertTrue(session.shared.isEmpty, "a remote id has nothing to share")
    }

    // MARK: decoding

    func testDecodingProducesARemoteIDBoundToTheDecodingSession() throws {
        let session = StubSession()
        let object = try XPCEncoder().encode(SharedActorKey.name("primary"))
        var decoder = XPCDecoder()
        decoder.userInfo = userInfo(session)

        let id = try decoder.decode(ActorID.self, from: object)
        guard case .remote(let remote) = id.raw else { return XCTFail("expected a remote id") }
        XCTAssertEqual(remote.key, .name("primary"))
        XCTAssertTrue(remote.session === session)
    }

    func testDecodingWithNoSessionThrows() throws {
        let object = try XPCEncoder().encode(SharedActorKey.name("primary"))
        XCTAssertThrowsError(try XPCDecoder().decode(ActorID.self, from: object))
    }

    func testEncodingFailsWhenTheSessionRefusesToShare() throws {
        let session = StubSession()
        session.refuseToShare = true
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(session)
        let id = ActorID(raw: .local(.init(systemID: ID64.next(), instanceID: ID64.next())))
        XCTAssertThrowsError(try encoder.encode(id))
    }

    // MARK: equality

    func testRemoteIdentityComparesTheSessionByIdentity() {
        let a = StubSession(), b = StubSession()
        XCTAssertEqual(a.remoteID(for: .name("x")), a.remoteID(for: .name("x")))
        XCTAssertNotEqual(a.remoteID(for: .name("x")), b.remoteID(for: .name("x")))
        XCTAssertNotEqual(a.remoteID(for: .name("x")), a.remoteID(for: .name("y")))
    }

    func testLocalAndRemoteAreNeverEqual() {
        let session = StubSession()
        let local = ActorID(raw: .local(.init(systemID: ID64(rawValue: 1), instanceID: ID64(rawValue: 2))))
        XCTAssertNotEqual(local, session.remoteID(for: .dynamic(1)))
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter ActorIDTests`
Expected: FAIL — `cannot find 'SessionCoding' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/XPCActors/ActorID.swift
import Foundation

/// Where an `ActorID` finds the session it needs in order to code itself.
///
/// This exists to break a cycle: `ActorID` needs a session, and `Session` is built on
/// `ActorID`. Naming only the two operations identity needs also keeps `Distributed`
/// out of this file, and lets identity be tested with no transport at all.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public protocol SessionCoding: AnyObject, Sendable {
    /// Make a local actor reachable to the peer and return the key naming it.
    /// `nil` when the actor is not registered -- it was deallocated, or was never ready.
    func shareDynamically(_ local: RawActorID.Local) -> SharedActorKey?

    /// The id our side uses for an actor the peer named.
    func remoteID(for key: SharedActorKey) -> ActorID
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension CodingUserInfoKey {
    /// The `SessionCoding` an `ActorID` codes itself against.
    public static let xpcActorSession = CodingUserInfoKey(rawValue: "XPCActors.session")!
}

/// A process-local identifier.
///
/// Drawn from a process-global monotonic counter -- neither random nor pid-derived,
/// and it never needs to be unique across processes, because it is never transmitted.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct ID64: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    private static let counter = ManagedAtomicCounter()
    public static func next() -> ID64 { ID64(rawValue: counter.next()) }

    public var description: String { "\(rawValue)" }
}

/// A monotonic counter. `OSAllocatedUnfairLock` rather than an atomics package so the
/// target keeps its single dependency on `CodableXPC`.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 {
        lock.withLock {
            value += 1
            return value
        }
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum RawActorID: Hashable, @unchecked Sendable {

    case local(Local)
    case remote(Remote)

    /// An actor living in this process. Neither field is ever transmitted.
    public struct Local: Hashable, Sendable {
        public let systemID: ID64
        public let instanceID: ID64
        public init(systemID: ID64, instanceID: ID64) {
            self.systemID = systemID
            self.instanceID = instanceID
        }
    }

    /// An actor living in a peer, reachable only through the session that named it.
    public struct Remote: @unchecked Sendable {
        public let session: any SessionCoding
        public let key: SharedActorKey
        public init(session: any SessionCoding, key: SharedActorKey) {
            self.session = session
            self.key = key
        }
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension RawActorID.Remote: Hashable {
    /// The session is compared by identity: the same key reached through two different
    /// sessions names two different actors.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && ObjectIdentifier(lhs.session) == ObjectIdentifier(rhs.session)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(ObjectIdentifier(session))
    }
}

/// The `DistributedActorSystem.ActorID`.
///
/// Its `Codable` conformance is the load-bearing part of the design: what goes on the
/// wire is a `SharedActorKey` in a single-value container, never the id's own contents.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct ActorID: Hashable, @unchecked Sendable {
    public let raw: RawActorID
    public init(raw: RawActorID) { self.raw = raw }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension ActorID: Codable {

    public func encode(to encoder: any Encoder) throws {
        // A trap, not a throw. Encoding an actor reference with no session is a
        // programmer error at the call site -- the coder was built without the
        // userInfo this type documents as mandatory -- and reporting it as a decoding
        // failure on the peer would put the diagnosis in the wrong process.
        guard let session = encoder.userInfo[.xpcActorSession] as? any SessionCoding else {
            preconditionFailure("""
                encoding an ActorID needs a session under CodingUserInfoKey.xpcActorSession; \
                coding path \(encoder.codingPath)
                """)
        }
        let key: SharedActorKey
        switch raw {
        case .remote(let remote):
            // Send the peer's own key back. Sharing it into this session would mint a
            // second name for an actor that already has one.
            key = remote.key
        case .local(let local):
            guard let shared = session.shareDynamically(local) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "no live actor is registered for \(local)"))
            }
            key = shared
        }
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }

    public init(from decoder: any Decoder) throws {
        guard let session = decoder.userInfo[.xpcActorSession] as? any SessionCoding else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "decoding an ActorID needs a session under "
                    + "CodingUserInfoKey.xpcActorSession"))
        }
        let container = try decoder.singleValueContainer()
        self = session.remoteID(for: try container.decode(SharedActorKey.self))
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter ActorIDTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/ActorID.swift Tests/XPCActorsTests/ActorIDTests.swift
git commit -m "feat(XPCActors): add ActorID that codes as a SharedActorKey"
```

---

### Task 4: ActorRegistry — weak local actors and their execute thunks

**Files:**
- Create: `Sources/XPCActors/ActorRegistry.swift`
- Test: `Tests/XPCActorsTests/ActorRegistryTests.swift`

**Interfaces:**
- Consumes: `RawActorID.Local` (Task 3).
- Produces:
  ```swift
  final class ActorRegistry<Thunk>: @unchecked Sendable {
      func register(_ instance: AnyObject, id: RawActorID.Local, thunk: Thunk)
      func resign(_ id: RawActorID.Local)
      func lookup(_ id: RawActorID.Local) -> (instance: AnyObject, thunk: Thunk)?
      var count: Int { get }
  }
  ```

**The registry is generic over its thunk on purpose.** The thunk's real type — declared in Task 11 as `ExecuteThunk` — mentions `InvocationDecoder`, `ResultHandler`, and `XPCActorSystem`, none of which exist yet and none of which registration has any business knowing about. Parameterizing makes this task independent and testable now; Task 11 spells the concrete type once, as `ActorRegistry<ExecuteThunk>`.

Storing `AnyObject` rather than `any DistributedActor` is the same decision for the same reason: `Distributed` is not imported here, and the only property the registry needs from an actor is that it is a class, so a weak reference is legal.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/ActorRegistryTests.swift
import XCTest
@testable import XPCActors

private final class Dummy {}

@available(macOS 14, *)
final class ActorRegistryTests: XCTestCase {

    private func makeLocal() -> RawActorID.Local {
        RawActorID.Local(systemID: ID64.next(), instanceID: ID64.next())
    }

    func testAnEntryIsFoundAfterRegistering() {
        let registry = ActorRegistry<Int>()
        let object = Dummy()
        let id = makeLocal()
        registry.register(object, id: id, thunk: 42)

        let hit = registry.lookup(id)
        XCTAssertTrue(hit?.instance === object)
        XCTAssertEqual(hit?.thunk, 42)
    }

    func testResignRemovesTheEntry() {
        let registry = ActorRegistry<Int>()
        let object = Dummy()
        let id = makeLocal()
        registry.register(object, id: id, thunk: 1)
        registry.resign(id)
        XCTAssertNil(registry.lookup(id))
        XCTAssertEqual(registry.count, 0)
    }

    /// The registry must never extend an actor's lifetime. This is the whole reason
    /// it holds weak references, and the reason `resignID` is not the only way out.
    func testTheRegistryDoesNotKeepTheActorAlive() {
        let registry = ActorRegistry<Int>()
        let id = makeLocal()
        do {
            let object = Dummy()
            registry.register(object, id: id, thunk: 1)
            XCTAssertNotNil(registry.lookup(id))
        }
        XCTAssertNil(registry.lookup(id), "a deallocated actor must not be reachable")
    }

    /// A dead entry is not merely invisible, it is reclaimed -- otherwise a long-lived
    /// system accumulates one dictionary slot per actor that ever existed.
    func testADeadEntryIsReclaimedOnLookup() {
        let registry = ActorRegistry<Int>()
        let id = makeLocal()
        do {
            let object = Dummy()
            registry.register(object, id: id, thunk: 1)
        }
        _ = registry.lookup(id)
        XCTAssertEqual(registry.count, 0)
    }

    func testDistinctIDsDoNotCollide() {
        let registry = ActorRegistry<Int>()
        let a = Dummy(), b = Dummy()
        let idA = makeLocal(), idB = makeLocal()
        registry.register(a, id: idA, thunk: 1)
        registry.register(b, id: idB, thunk: 2)
        XCTAssertTrue(registry.lookup(idA)?.instance === a)
        XCTAssertTrue(registry.lookup(idB)?.instance === b)
        XCTAssertEqual(registry.count, 2)
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter ActorRegistryTests`
Expected: FAIL — `cannot find 'ActorRegistry' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/XPCActors/ActorRegistry.swift
import Foundation

/// The system's table of actors living in this process.
///
/// **Weak on purpose.** A distributed actor's lifetime belongs to whoever created it;
/// a registry that held it strongly would keep every actor that was ever ready alive
/// for the life of the process. The wire-facing table on `Session` is the strong one,
/// because a peer holding a key must not find the actor gone.
///
/// Generic over `Thunk` so this file depends on nothing: the thunk's real type
/// mentions `InvocationDecoder`, `ResultHandler`, and the system itself, none of
/// which identity or registration has any business knowing about.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class ActorRegistry<Thunk>: @unchecked Sendable {

    private struct Entry {
        weak var instance: AnyObject?
        let thunk: Thunk
    }

    private let lock = NSLock()
    private var entries: [RawActorID.Local: Entry] = [:]

    var count: Int { lock.withLock { entries.count } }

    func register(_ instance: AnyObject, id: RawActorID.Local, thunk: Thunk) {
        lock.withLock { entries[id] = Entry(instance: instance, thunk: thunk) }
    }

    func resign(_ id: RawActorID.Local) {
        lock.withLock { entries.removeValue(forKey: id) }
    }

    /// Look up a live actor. A slot whose actor has gone is removed as it is found,
    /// so the table does not accumulate one dead entry per actor ever created.
    func lookup(_ id: RawActorID.Local) -> (instance: AnyObject, thunk: Thunk)? {
        lock.withLock {
            guard let entry = entries[id] else { return nil }
            guard let instance = entry.instance else {
                entries.removeValue(forKey: id)
                return nil
            }
            return (instance, entry.thunk)
        }
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter ActorRegistryTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/ActorRegistry.swift Tests/XPCActorsTests/ActorRegistryTests.swift
git commit -m "feat(XPCActors): add the weak local actor registry"
```

---

### Task 5: Invocation bodies — request, reply, notification

**Files:**
- Create: `Sources/XPCActors/InvocationBodies.swift`
- Test: `Tests/XPCActorsTests/InvocationBodiesTests.swift`

**Interfaces:**
- Consumes: `SharedActorKey` (Task 2).
- Produces:
  ```swift
  public struct RequestBody: Encodable {
      public let actor: SharedActorKey
      public let target: String
      public let generics: [String]
      public let args: [any Codable]
      public let errorType: String?
      public let returnType: String?
      public let basePriority: UInt64?
  }
  public struct InboundRequest: Decodable {
      public let actor: SharedActorKey
      public let target: String
      public let generics: [String]
      public let errorType: String?
      public let returnType: String?
      public let basePriority: UInt64?
      public var argumentsContainer: any UnkeyedDecodingContainer
  }
  public struct ReplyBody: Codable { public let ok: OK?; public let err: Err? }
  public struct NotificationBody: Codable {
      public enum Kind: UInt64, Codable { case invocationCancelled = 0, invocationEscalated = 1, responseEscalated = 2 }
      public let kind: Kind; public let requestSeq: UInt64; public let priority: UInt64?
  }
  ```

The request body is deliberately **asymmetric**. Encoding is a struct with a hand-written `encode(to:)` that writes `args` positionally. Decoding cannot be symmetric, because argument types are not known until `executeDistributedTarget` asks for each one by its static type — so `InboundRequest` decodes every header field and *retains the unkeyed container* for `args` without consuming it. `InvocationDecoder` (Task 7) drives that container.

`ReplyBody.OK` is a special case: the encoded return value is arbitrary, so it is stored as a raw `xpc_object_t` on the way out and as a retained decoder on the way in. Both are handled by the two nested types below.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/InvocationBodiesTests.swift
import XCTest
import XPC
import CodableXPC
@testable import XPCActors

@available(macOS 14, *)
final class InvocationBodiesTests: XCTestCase {

    // MARK: tier 1 — request golden fixture

    func testTheRequestBodyIsPinned() throws {
        let body = RequestBody(
            actor: .name("primary"),
            target: "$s4Test7GreeterC5greet4nameSSSS_tYaKFTE",
            generics: ["Si"],
            args: [7 as Int, "hi" as String],
            errorType: "Se",
            returnType: "SS",
            basePriority: 25
        )
        XCTAssertEqual(
            normalizedDescription(try XPCEncoder().encode(body)),
            "{actor=dict{kind=uint64(1),name=string(primary)},"
            + "args=[int64(7),string(hi)],"
            + "basePriority=uint64(25),"
            + "errorType=string(Se),"
            + "generics=[string(Si)],"
            + "returnType=string(SS),"
            + "target=string($s4Test7GreeterC5greet4nameSSSS_tYaKFTE)}"
        )
    }

    func testAbsentOptionalsAreOmittedEntirely() throws {
        let body = RequestBody(actor: .dynamic(3), target: "t", generics: [],
                               args: [], errorType: nil, returnType: nil, basePriority: nil)
        let object = try XPCEncoder().encode(body)
        XCTAssertNil(xpc_dictionary_get_value(object, "errorType"))
        XCTAssertNil(xpc_dictionary_get_value(object, "returnType"))
        XCTAssertNil(xpc_dictionary_get_value(object, "basePriority"))
        XCTAssertEqual(normalizedDescription(object),
                       "{actor=dict{id=uint64(3),kind=uint64(2)},args=[],generics=[],target=string(t)}")
    }

    // MARK: inbound request keeps the argument container unconsumed

    func testAnInboundRequestReadsTheHeaderAndLeavesTheArgumentsAlone() throws {
        let body = RequestBody(actor: .type("G"), target: "t", generics: ["Si"],
                               args: [1 as Int, "two" as String], errorType: "Se",
                               returnType: "SS", basePriority: nil)
        let object = try XPCEncoder().encode(body)

        var inbound = try XPCDecoder().decode(InboundRequest.self, from: object)
        XCTAssertEqual(inbound.actor, .type("G"))
        XCTAssertEqual(inbound.target, "t")
        XCTAssertEqual(inbound.generics, ["Si"])
        XCTAssertEqual(inbound.errorType, "Se")
        XCTAssertEqual(inbound.returnType, "SS")
        XCTAssertNil(inbound.basePriority)

        XCTAssertEqual(try inbound.argumentsContainer.decode(Int.self), 1)
        XCTAssertEqual(try inbound.argumentsContainer.decode(String.self), "two")
        XCTAssertTrue(inbound.argumentsContainer.isAtEnd)
    }

    // MARK: reply

    func testASuccessReplyCarriesOnlyOK() throws {
        let reply = try ReplyBody.success(encoding: 42 as Int)
        let object = try XPCEncoder().encode(reply)
        XCTAssertNil(xpc_dictionary_get_value(object, "err"))
        XCTAssertEqual(normalizedDescription(object), "{ok=int64(42)}")
    }

    func testAVoidReplyIsAnEmptyDictionary() throws {
        XCTAssertEqual(normalizedDescription(try XPCEncoder().encode(ReplyBody.void)),
                       "{ok=dict{}}")
    }

    func testAnErrorReplyIsPinned() throws {
        let reply = ReplyBody(err: .init(kind: .noSuchActor, type: nil, value: nil,
                                         text: "no actor for name(primary)"))
        XCTAssertEqual(
            normalizedDescription(try XPCEncoder().encode(reply)),
            "{err=dict{kind=uint64(2),text=string(no actor for name(primary))}}")
    }

    func testTheErrorKindsArePinned() {
        XCTAssertEqual(ReplyBody.Err.Kind.targetThrew.rawValue, 0)
        XCTAssertEqual(ReplyBody.Err.Kind.resultEncodingFailed.rawValue, 1)
        XCTAssertEqual(ReplyBody.Err.Kind.noSuchActor.rawValue, 2)
        XCTAssertEqual(ReplyBody.Err.Kind.peerRequirementNotSatisfied.rawValue, 3)
        XCTAssertEqual(ReplyBody.Err.Kind.notReceiving.rawValue, 4)
        XCTAssertEqual(ReplyBody.Err.Kind.requestUndecodable.rawValue, 5)
    }

    /// Exactly one of `ok` and `err`. Both or neither is a malformed reply, and it has
    /// to fail rather than pick one -- silently preferring `ok` would turn a reported
    /// remote failure into a bogus success.
    func testAReplyWithNeitherOrBothFails() throws {
        let empty = xpc_dictionary_create(nil, nil, 0)
        XCTAssertThrowsError(try XPCDecoder().decode(ReplyBody.self, from: empty))

        let both = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(both, "ok", 1)
        xpc_dictionary_set_value(both, "err", try XPCEncoder().encode(
            ReplyBody.Err(kind: .targetThrew, type: nil, value: nil, text: "x")))
        XCTAssertThrowsError(try XPCDecoder().decode(ReplyBody.self, from: both))
    }

    // MARK: notification

    func testTheNotificationBodyIsPinned() throws {
        let body = NotificationBody(kind: .invocationCancelled, requestSeq: 9, priority: nil)
        XCTAssertEqual(normalizedDescription(try XPCEncoder().encode(body)),
                       "{kind=uint64(0),requestSeq=uint64(9)}")
    }

    /// The field is `requestSeq`, never `seq`. A notification carries no envelope seq,
    /// and the two must never be confusable in code or in a log.
    func testTheNotificationFieldIsNotCalledSeq() throws {
        let object = try XPCEncoder().encode(
            NotificationBody(kind: .invocationEscalated, requestSeq: 1, priority: 33))
        XCTAssertNil(xpc_dictionary_get_value(object, "seq"))
        XCTAssertEqual(normalizedDescription(object),
                       "{kind=uint64(1),priority=uint64(33),requestSeq=uint64(1)}")
    }

    func testAnUnknownNotificationKindIsRejected() throws {
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(object, "kind", 77)
        xpc_dictionary_set_uint64(object, "requestSeq", 1)
        XCTAssertThrowsError(try XPCDecoder().decode(NotificationBody.self, from: object))
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter InvocationBodiesTests`
Expected: FAIL — `cannot find 'RequestBody' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/XPCActors/InvocationBodies.swift
import Foundation
import XPC
import CodableXPC

// MARK: - request

/// The outbound side of an invocation.
///
/// Arguments are positional and carry no per-argument type tag: the receiver's
/// `executeDistributedTarget` knows each parameter's type statically from the callee
/// signature and asks for them in order, so a tag would be pure overhead. Labels are
/// discarded for the same reason.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct RequestBody: Encodable {

    public let actor: SharedActorKey
    public let target: String
    public let generics: [String]
    public let args: [any Codable]
    public let errorType: String?
    public let returnType: String?
    public let basePriority: UInt64?

    public init(
        actor: SharedActorKey, target: String, generics: [String], args: [any Codable],
        errorType: String?, returnType: String?, basePriority: UInt64?
    ) {
        self.actor = actor
        self.target = target
        self.generics = generics
        self.args = args
        self.errorType = errorType
        self.returnType = returnType
        self.basePriority = basePriority
    }

    enum CodingKeys: String, CodingKey {
        case actor, target, generics, args, errorType, returnType, basePriority
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actor, forKey: .actor)
        try container.encode(target, forKey: .target)
        try container.encode(generics, forKey: .generics)
        try container.encodeIfPresent(errorType, forKey: .errorType)
        try container.encodeIfPresent(returnType, forKey: .returnType)
        try container.encodeIfPresent(basePriority, forKey: .basePriority)

        var arguments = container.nestedUnkeyedContainer(forKey: .args)
        for argument in args {
            // Implicit existential opening: `encode` is generic, and `argument` is the
            // sole use of the existential, so Swift opens it and calls the concrete
            // `encode`. Do not "fix" this by boxing -- boxing loses the dynamic type,
            // which is exactly what has to reach the coder.
            try arguments.encode(argument)
        }
    }
}

/// The inbound side of an invocation.
///
/// Not the mirror of `RequestBody`, and it cannot be: an argument's type is not known
/// until `executeDistributedTarget` asks for it by static type. So every header field
/// is decoded eagerly and the `args` container is *retained unconsumed*, for
/// `InvocationDecoder` to drive one element at a time.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct InboundRequest: Decodable {

    public let actor: SharedActorKey
    public let target: String
    public let generics: [String]
    public let errorType: String?
    public let returnType: String?
    public let basePriority: UInt64?
    /// `var` because decoding an element advances the container's own cursor -- that
    /// cursor is the decoder's entire state, which is why no index is tracked.
    public var argumentsContainer: any UnkeyedDecodingContainer

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RequestBody.CodingKeys.self)
        actor = try container.decode(SharedActorKey.self, forKey: .actor)
        target = try container.decode(String.self, forKey: .target)
        generics = try container.decode([String].self, forKey: .generics)
        errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
        returnType = try container.decodeIfPresent(String.self, forKey: .returnType)
        basePriority = try container.decodeIfPresent(UInt64.self, forKey: .basePriority)
        argumentsContainer = try container.nestedUnkeyedContainer(forKey: .args)
    }
}

// MARK: - reply

/// Exactly one of `ok` and `err`.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct ReplyBody {

    /// A failure the peer is reporting. Never a transport failure -- those do not
    /// cross the wire.
    public struct Err: Codable, Equatable, Sendable {
        public enum Kind: UInt64, Codable, Sendable {
            case targetThrew = 0
            case resultEncodingFailed = 1
            case noSuchActor = 2
            case peerRequirementNotSatisfied = 3
            case notReceiving = 4
            case requestUndecodable = 5
        }
        public let kind: Kind
        /// The mangled name of the thrown error, when it could be recovered.
        public let type: String?
        /// The encoded error, present exactly when `type` is.
        public let value: XPCNativeObject?
        /// Always present. The tier-3 fallback, so an unregistered error is never a
        /// failure -- only a less precise one.
        public let text: String

        public init(kind: Kind, type: String?, value: XPCNativeObject?, text: String) {
            self.kind = kind
            self.type = type
            self.value = value
            self.text = text
        }
    }

    public let ok: XPCNativeObject?
    public let err: Err?

    public init(ok: XPCNativeObject) { self.ok = ok; self.err = nil }
    public init(err: Err) { self.ok = nil; self.err = err }

    /// Void is an empty dictionary rather than an absent `ok`, so "returned nothing"
    /// stays distinguishable from "carried no result at all".
    public static var void: ReplyBody {
        ReplyBody(ok: XPCNativeObject(xpc_dictionary_create(nil, nil, 0)))
    }

    public static func success<T: Encodable>(encoding value: T) throws -> ReplyBody {
        ReplyBody(ok: XPCNativeObject(try XPCEncoder().encode(value)))
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension ReplyBody: Codable {

    private enum CodingKeys: String, CodingKey { case ok, err }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(ok, forKey: .ok)
        try container.encodeIfPresent(err, forKey: .err)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decodeIfPresent(XPCNativeObject.self, forKey: .ok)
        let err = try container.decodeIfPresent(Err.self, forKey: .err)
        switch (ok, err) {
        case (.some(let ok), .none): self = ReplyBody(ok: ok)
        case (.none, .some(let err)): self = ReplyBody(err: err)
        default:
            // Neither, or both. Failing is the only safe answer: preferring `ok` would
            // turn a reported remote failure into a bogus success, and preferring `err`
            // would invent a failure that did not happen.
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "a reply must carry exactly one of ok and err"))
        }
    }
}

// MARK: - notification

/// One-way, and carrying no envelope `seq`.
///
/// The field naming the request is `requestSeq`, never `seq`. Two different sequence
/// numbers would otherwise be spelled the same way in code and in logs: the envelope's
/// own, and the request this refers to.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct NotificationBody: Codable, Equatable, Sendable {

    public enum Kind: UInt64, Codable, Sendable {
        case invocationCancelled = 0
        /// Phase C. Defined here so the format is complete; nothing sends it yet.
        case invocationEscalated = 1
        /// Phase C. Defined here so the format is complete; nothing sends it yet.
        case responseEscalated = 2
    }

    public let kind: Kind
    public let requestSeq: UInt64
    /// Present for the two escalation kinds only.
    public let priority: UInt64?

    public init(kind: Kind, requestSeq: UInt64, priority: UInt64?) {
        self.kind = kind
        self.requestSeq = requestSeq
        self.priority = priority
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter InvocationBodiesTests`
Expected: PASS, 10 tests.

If `XPCNativeObject` does not round-trip through `XPCEncoder`/`XPCDecoder` inside a keyed container, stop and report — that is `CodableXPC` behaviour this task depends on and it is covered by `Tests/CodableXPCTests/NativeObjectTests.swift`.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/InvocationBodies.swift Tests/XPCActorsTests/InvocationBodiesTests.swift
git commit -m "feat(XPCActors): add request, reply, and notification bodies"
```

---

### Task 6: InvocationEncoder

**Files:**
- Create: `Sources/XPCActors/InvocationEncoder.swift`
- Modify: `Package.swift` — nothing to change; `XPCActors` already depends on `CodableXPC`
- Test: `Tests/XPCActorsTests/InvocationEncoderTests.swift`

**Interfaces:**
- Consumes: `TypeName` (Task 1), `RequestBody` (Task 5).
- Produces:
  ```swift
  public struct InvocationEncoder: DistributedTargetInvocationEncoder {
      public typealias SerializationRequirement = any Codable
      public private(set) var generics: [String]
      public private(set) var arguments: [any Codable]
      public private(set) var errorType: String?
      public private(set) var returnType: String?
      public func makeRequestBody(actor: SharedActorKey, target: String, basePriority: UInt64?) -> RequestBody
  }
  ```

This is the first file in the target that imports `Distributed`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/InvocationEncoderTests.swift
import XCTest
import Distributed
import CodableXPC
@testable import XPCActors

private struct Payload: Codable, Equatable { let n: Int }
private struct Boom: Error, Codable {}

@available(macOS 14, *)
final class InvocationEncoderTests: XCTestCase {

    func testRecordingBuildsARequestBody() throws {
        var encoder = InvocationEncoder()
        try encoder.recordGenericSubstitution(Int.self)
        try encoder.recordArgument(RemoteCallArgument(label: "name", name: "name", value: "hi"))
        try encoder.recordArgument(RemoteCallArgument(label: nil, name: "n", value: Payload(n: 3)))
        try encoder.recordErrorType(Boom.self)
        try encoder.recordReturnType(String.self)
        try encoder.doneRecording()

        let body = encoder.makeRequestBody(actor: .name("primary"), target: "t", basePriority: nil)
        XCTAssertEqual(body.actor, .name("primary"))
        XCTAssertEqual(body.target, "t")
        XCTAssertEqual(body.generics, [try XCTUnwrap(TypeName.mangled(for: Int.self))])
        XCTAssertEqual(body.args.count, 2)
        XCTAssertEqual(body.errorType, try XCTUnwrap(TypeName.mangled(for: Boom.self)))
        XCTAssertEqual(body.returnType, try XCTUnwrap(TypeName.mangled(for: String.self)))
    }

    /// Labels are discarded deliberately: the receiver knows them statically, so
    /// putting them on the wire would be pure overhead.
    func testArgumentLabelsAreDiscarded() throws {
        var encoder = InvocationEncoder()
        try encoder.recordArgument(RemoteCallArgument(label: "greeting", name: "g", value: "hi"))
        try encoder.doneRecording()
        let rendered = normalizedDescription(
            try XPCEncoder().encode(encoder.makeRequestBody(actor: .dynamic(1), target: "t",
                                                            basePriority: nil)))
        XCTAssertFalse(rendered.contains("greeting"))
        XCTAssertTrue(rendered.contains("args=[string(hi)]"))
    }

    func testArgumentOrderIsPreserved() throws {
        var encoder = InvocationEncoder()
        for n in 0..<5 {
            try encoder.recordArgument(RemoteCallArgument(label: nil, name: nil, value: n))
        }
        try encoder.doneRecording()
        let body = encoder.makeRequestBody(actor: .dynamic(1), target: "t", basePriority: nil)
        XCTAssertEqual(normalizedDescription(try XPCEncoder().encode(body)).contains(
            "args=[int64(0),int64(1),int64(2),int64(3),int64(4)]"), true)
    }

    func testNoErrorTypeMeansTheTargetDoesNotThrow() throws {
        var encoder = InvocationEncoder()
        try encoder.doneRecording()
        XCTAssertNil(encoder.makeRequestBody(actor: .dynamic(1), target: "t",
                                             basePriority: nil).errorType)
    }

    func testBasePriorityIsCarriedThrough() throws {
        var encoder = InvocationEncoder()
        try encoder.doneRecording()
        let body = encoder.makeRequestBody(actor: .dynamic(1), target: "t",
                                           basePriority: UInt64(TaskPriority.high.rawValue))
        XCTAssertEqual(body.basePriority, UInt64(TaskPriority.high.rawValue))
    }

    /// Two calls must not share accumulated state. `makeInvocationEncoder()` returns a
    /// fresh value per invocation, and a struct is what makes that cheap -- but only if
    /// nothing static leaks between them.
    func testEncodersDoNotShareState() throws {
        var first = InvocationEncoder()
        try first.recordArgument(RemoteCallArgument(label: nil, name: nil, value: 1))
        try first.doneRecording()

        var second = InvocationEncoder()
        try second.doneRecording()
        XCTAssertTrue(second.arguments.isEmpty)
        XCTAssertEqual(first.arguments.count, 1)
    }
}
```

`TaskPriority.rawValue` is a `UInt8`; the widening to the wire's `UInt64` stays explicit at the call site rather than changing the wire type.

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter InvocationEncoderTests`
Expected: FAIL — `cannot find 'InvocationEncoder' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/XPCActors/InvocationEncoder.swift
import Foundation
import Distributed

/// Accumulates one outbound invocation.
///
/// The Swift runtime drives this: it records the generic substitutions, then each
/// argument in declaration order, then the error and return types, then calls
/// `doneRecording`. Nothing is encoded here -- the values are held until
/// `makeRequestBody` assembles them, because the actor key is not known until the
/// session shares it.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct InvocationEncoder: DistributedTargetInvocationEncoder {

    public typealias SerializationRequirement = any Codable

    public private(set) var generics: [String] = []
    public private(set) var arguments: [any Codable] = []
    public private(set) var errorType: String?
    public private(set) var returnType: String?

    public init() {}

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        guard let mangled = TypeName.mangled(for: type) else {
            throw SetupError("no mangled name for generic substitution \(type)")
        }
        generics.append(mangled)
    }

    public mutating func recordArgument<Value: Codable>(
        _ argument: RemoteCallArgument<Value>
    ) throws {
        // The label and the parameter name are dropped on purpose: the receiver knows
        // both statically from the callee signature.
        arguments.append(argument.value)
    }

    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {
        // Not fatal if unnameable. `errorType` being present is what tells the receiver
        // the target can throw, so a name we cannot mangle degrades to tier 3 rather
        // than failing the call -- but the field must still be set.
        errorType = TypeName.mangled(for: type) ?? "\(type)"
    }

    public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {
        returnType = TypeName.mangled(for: type)
    }

    public mutating func doneRecording() throws {}

    /// Assemble the body. Separate from recording because the actor key comes from the
    /// session, which only exists at send time.
    public func makeRequestBody(
        actor: SharedActorKey, target: String, basePriority: UInt64?
    ) -> RequestBody {
        RequestBody(
            actor: actor, target: target, generics: generics, args: arguments,
            errorType: errorType, returnType: returnType, basePriority: basePriority)
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter InvocationEncoderTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/InvocationEncoder.swift Tests/XPCActorsTests/InvocationEncoderTests.swift
git commit -m "feat(XPCActors): add the invocation encoder"
```

---

### Task 7: InvocationDecoder

**Files:**
- Create: `Sources/XPCActors/InvocationDecoder.swift`
- Test: `Tests/XPCActorsTests/InvocationDecoderTests.swift`

**Interfaces:**
- Consumes: `TypeName` (Task 1), `InboundRequest` (Task 5).
- Produces:
  ```swift
  public struct InvocationDecoder: DistributedTargetInvocationDecoder {
      public typealias SerializationRequirement = any Codable
      public init(request: InboundRequest)
      public var canThrow: Bool { get }
  }
  ```

`canThrow` is **not on the wire**. It is derived here from whether `errorType` was present in the request, and it is what Task 8's result handler consults before deciding whether to reply with an error or trap.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/InvocationDecoderTests.swift
import XCTest
import Distributed
import CodableXPC
@testable import XPCActors

private struct Payload: Codable, Equatable { let n: Int }
private struct Boom: Error, Codable {}

@available(macOS 14, *)
final class InvocationDecoderTests: XCTestCase {

    private func decoder(for body: RequestBody) throws -> InvocationDecoder {
        let object = try XPCEncoder().encode(body)
        return InvocationDecoder(request: try XPCDecoder().decode(InboundRequest.self, from: object))
    }

    func testArgumentsComeBackInOrderAndAtTheirStaticTypes() throws {
        var subject = try decoder(for: RequestBody(
            actor: .dynamic(1), target: "t", generics: [],
            args: [7 as Int, "hi" as String, Payload(n: 3)],
            errorType: nil, returnType: nil, basePriority: nil))

        XCTAssertEqual(try subject.decodeNextArgument() as Int, 7)
        XCTAssertEqual(try subject.decodeNextArgument() as String, "hi")
        XCTAssertEqual(try subject.decodeNextArgument() as Payload, Payload(n: 3))
    }

    func testAskingForOneArgumentTooManyThrows() throws {
        var subject = try decoder(for: RequestBody(
            actor: .dynamic(1), target: "t", generics: [], args: [1 as Int],
            errorType: nil, returnType: nil, basePriority: nil))
        _ = try subject.decodeNextArgument() as Int
        XCTAssertThrowsError(try subject.decodeNextArgument() as Int)
    }

    func testGenericSubstitutionsResolveBackToTypes() throws {
        var subject = try decoder(for: RequestBody(
            actor: .dynamic(1), target: "t",
            generics: [try XCTUnwrap(TypeName.mangled(for: Int.self)),
                       try XCTUnwrap(TypeName.mangled(for: String.self))],
            args: [], errorType: nil, returnType: nil, basePriority: nil))
        let types = try subject.decodeGenericSubstitutions()
        XCTAssertEqual(types.count, 2)
        XCTAssertTrue(types[0] == Int.self)
        XCTAssertTrue(types[1] == String.self)
    }

    func testAnUnresolvableGenericSubstitutionThrows() throws {
        var subject = try decoder(for: RequestBody(
            actor: .dynamic(1), target: "t", generics: ["not a mangled name"],
            args: [], errorType: nil, returnType: nil, basePriority: nil))
        XCTAssertThrowsError(try subject.decodeGenericSubstitutions())
    }

    func testErrorAndReturnTypesResolve() throws {
        var subject = try decoder(for: RequestBody(
            actor: .dynamic(1), target: "t", generics: [], args: [],
            errorType: try XCTUnwrap(TypeName.mangled(for: Boom.self)),
            returnType: try XCTUnwrap(TypeName.mangled(for: String.self)),
            basePriority: nil))
        XCTAssertTrue(try subject.decodeErrorType() == Boom.self)
        XCTAssertTrue(try subject.decodeReturnType() == String.self)
    }

    /// `canThrow` is derived, never transmitted. Its value is what decides between
    /// replying with an error and trapping, so it is pinned in both directions.
    func testCanThrowIsDerivedFromTheErrorTypeBeingPresent() throws {
        let throwing = try decoder(for: RequestBody(
            actor: .dynamic(1), target: "t", generics: [], args: [],
            errorType: "Se", returnType: nil, basePriority: nil))
        XCTAssertTrue(throwing.canThrow)

        let nonThrowing = try decoder(for: RequestBody(
            actor: .dynamic(1), target: "t", generics: [], args: [],
            errorType: nil, returnType: nil, basePriority: nil))
        XCTAssertFalse(nonThrowing.canThrow)
    }

    /// An error type we cannot resolve still means the target throws. Only the concrete
    /// type is lost, and the reply degrades to tier 3.
    func testAnUnresolvableErrorTypeStillMeansCanThrow() throws {
        var subject = try decoder(for: RequestBody(
            actor: .dynamic(1), target: "t", generics: [], args: [],
            errorType: "not a mangled name", returnType: nil, basePriority: nil))
        XCTAssertTrue(subject.canThrow)
        XCTAssertNil(try subject.decodeErrorType())
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter InvocationDecoderTests`
Expected: FAIL — `cannot find 'InvocationDecoder' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/XPCActors/InvocationDecoder.swift
import Foundation
import Distributed

/// Feeds one inbound invocation to `executeDistributedTarget`.
///
/// Arguments are consumed positionally from a single `UnkeyedDecodingContainer`. That
/// container's own cursor is the entire state, which is why no index is tracked here.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct InvocationDecoder: DistributedTargetInvocationDecoder {

    public typealias SerializationRequirement = any Codable

    private var request: InboundRequest

    public init(request: InboundRequest) {
        self.request = request
    }

    /// Whether the target the peer named is allowed to throw.
    ///
    /// Derived, never transmitted: it is exactly "the request carried an `errorType`".
    /// A request that omits `errorType` while naming a throwing target makes the
    /// receiver trap when that target throws -- deliberate, and the reason peer
    /// requirements are the mitigation rather than a reply.
    public var canThrow: Bool { request.errorType != nil }

    public mutating func decodeGenericSubstitutions() throws -> [any Any.Type] {
        try request.generics.map { mangled in
            guard let type = TypeName.type(for: mangled) else {
                throw RemoteCallError.undecodableRequest(
                    "unknown generic substitution \(mangled)")
            }
            return type
        }
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        // Running off the end throws rather than returning a default: the callee's
        // arity is a contract, and a short request means the peer and we disagree
        // about the signature.
        try request.argumentsContainer.decode(Argument.self)
    }

    public mutating func decodeErrorType() throws -> (any Any.Type)? {
        // A name we cannot resolve is not an error here. `canThrow` already recorded
        // that the target throws; losing the concrete type only costs tier-1 error
        // propagation, and tier 3 always applies.
        request.errorType.flatMap { TypeName.type(for: $0) }
    }

    public mutating func decodeReturnType() throws -> (any Any.Type)? {
        request.returnType.flatMap { TypeName.type(for: $0) }
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter InvocationDecoderTests`
Expected: PASS, 7 tests. `RemoteCallError.undecodableRequest` does not exist yet — add the case in Task 8 or, if the compiler blocks here, add `RemoteCallError` first from Task 8's Step 3 and commit it with that task.

Resolve this by implementing Task 8's `RemoteCallError` **before** this task's Step 3, and committing it as part of Task 8. If that ordering is inconvenient, this task may temporarily throw `SetupError("unknown generic substitution \(mangled)")` and Task 8 changes it — but the plan's preferred order is Task 8's error type first.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/InvocationDecoder.swift Tests/XPCActorsTests/InvocationDecoderTests.swift
git commit -m "feat(XPCActors): add the invocation decoder"
```

---

### Task 8: ResultHandler, RemoteCallError, and the three error tiers

**Files:**
- Create: `Sources/XPCActors/ResultHandler.swift`
- Modify: `Sources/XPCActors/Errors.swift` — append `RemoteCallError`
- Test: `Tests/XPCActorsTests/ResultHandlerTests.swift`

**Interfaces:**
- Consumes: `ReplyBody` (Task 5), `TypeName` (Task 1).
- Produces:
  ```swift
  public enum RemoteCallError: Error, Sendable, CustomStringConvertible {
      case remote(kind: ReplyBody.Err.Kind, type: String?, text: String)
      case undecodableRequest(String)
      case noSuchActor(SharedActorKey)
      case notReceiving
  }
  public final class ErrorTypeRegistry: @unchecked Sendable {
      func register<E: Error & Codable>(_ type: E.Type)
      func decode(mangled: String, from object: xpc_object_t) -> (any Error)?
  }
  public struct ResultHandler: DistributedTargetInvocationResultHandler {
      public typealias SerializationRequirement = any Codable
      public init(canThrow: Bool, errors: ErrorTypeRegistry, reply: @escaping @Sendable (ReplyBody) -> Void)
  }
  ```

The three tiers, in the order they are tried when a target throws:

1. **Typed throws with a `Codable` error type** — Swift passed the type statically, so `err.type` + `err.value` round-trip with no registry.
2. **Untyped throws where the concrete type was registered** via `system.registerError(MyError.self)` — same two fields, resolved through `ErrorTypeRegistry`.
3. **Otherwise** — `err.text` carries the interpolated description, matching Apple. Tier 3 always applies as a fallback, so an unregistered error is never a failure.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/ResultHandlerTests.swift
import XCTest
import XPC
import Distributed
import CodableXPC
@testable import XPCActors

private struct CodableFailure: Error, Codable, Equatable { let reason: String }
private struct OpaqueFailure: Error, CustomStringConvertible {
    var description: String { "opaque went wrong" }
}

@available(macOS 14, *)
final class ResultHandlerTests: XCTestCase {

    private func capture() -> (ResultHandler, @Sendable () -> ReplyBody?) {
        let box = Box()
        let handler = ResultHandler(canThrow: true, errors: ErrorTypeRegistry()) { box.reply = $0 }
        return (handler, { box.reply })
    }

    private final class Box: @unchecked Sendable { var reply: ReplyBody? }

    func testAReturnedValueBecomesAnOKReply() async throws {
        let (handler, reply) = capture()
        try await handler.onReturn(value: 42 as Int)
        let ok = try XCTUnwrap(reply()?.ok)
        XCTAssertEqual(try XPCDecoder().decode(Int.self, from: ok.object), 42)
    }

    func testVoidBecomesAnEmptyOKReply() async throws {
        let (handler, reply) = capture()
        try await handler.onReturnVoid()
        let ok = try XCTUnwrap(reply()?.ok)
        XCTAssertEqual(normalizedDescription(ok.object), "{}")
    }

    // MARK: tier 1 and 2 — the concrete error round-trips

    func testACodableErrorCarriesItsTypeAndValue() async throws {
        let (handler, reply) = capture()
        try await handler.onThrow(error: CodableFailure(reason: "nope"))
        let err = try XCTUnwrap(reply()?.err)
        XCTAssertEqual(err.kind, .targetThrew)
        XCTAssertEqual(err.type, TypeName.mangled(for: CodableFailure.self))
        let value = try XCTUnwrap(err.value)
        XCTAssertEqual(try XPCDecoder().decode(CodableFailure.self, from: value.object),
                       CodableFailure(reason: "nope"))
    }

    func testTheRegistryRecoversAnErrorFromItsMangledName() throws {
        let registry = ErrorTypeRegistry()
        registry.register(CodableFailure.self)
        let mangled = try XCTUnwrap(TypeName.mangled(for: CodableFailure.self))
        let encoded = try XPCEncoder().encode(CodableFailure(reason: "nope"))

        let recovered = try XCTUnwrap(registry.decode(mangled: mangled, from: encoded))
        XCTAssertEqual(recovered as? CodableFailure, CodableFailure(reason: "nope"))
    }

    func testAnUnregisteredNameDoesNotDecode() throws {
        let registry = ErrorTypeRegistry()
        let mangled = try XCTUnwrap(TypeName.mangled(for: CodableFailure.self))
        let encoded = try XPCEncoder().encode(CodableFailure(reason: "nope"))
        XCTAssertNil(registry.decode(mangled: mangled, from: encoded))
    }

    // MARK: tier 3 — the fallback always applies

    func testANonCodableErrorStillReportsItsDescription() async throws {
        let (handler, reply) = capture()
        try await handler.onThrow(error: OpaqueFailure())
        let err = try XCTUnwrap(reply()?.err)
        XCTAssertEqual(err.kind, .targetThrew)
        XCTAssertNil(err.type)
        XCTAssertNil(err.value)
        XCTAssertTrue(err.text.contains("opaque went wrong"), err.text)
    }

    /// Text is present on every error reply, not only the tier-3 ones, so a log always
    /// has something to show even when the type round-tripped.
    func testTextIsAlwaysPresent() async throws {
        let (handler, reply) = capture()
        try await handler.onThrow(error: CodableFailure(reason: "nope"))
        XCTAssertFalse(try XCTUnwrap(reply()?.err).text.isEmpty)
    }
}
```

The trap for a non-throwing target that throws is **not** tested: it is a `preconditionFailure`, and a test that provokes it kills the test runner. Its correctness is carried by the `canThrow` tests in Task 7 plus review of the branch below.

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter ResultHandlerTests`
Expected: FAIL — `cannot find 'ResultHandler' in scope`.

- [ ] **Step 3a: Append `RemoteCallError` to `Errors.swift`**

```swift
// appended to Sources/XPCActors/Errors.swift

/// A failure reported by the peer, or a failure to make sense of what it sent.
///
/// Distinct from `TransportError` on purpose: this one crossed the wire as an `err`
/// reply body, which means the peer is alive and answered. A transport failure means
/// the pipe is gone and nothing answered.
///
/// This is where tier-3 error propagation lands. When the concrete error type *was*
/// recovered, the original error is rethrown instead and this type never appears.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum RemoteCallError: Error, Sendable, CustomStringConvertible {
    /// The peer replied with an error it could not, or chose not to, make concrete.
    case remote(kind: ReplyBody.Err.Kind, type: String?, text: String)
    /// A request that did not make sense to us. Replied as `err.kind == 5`.
    case undecodableRequest(String)
    /// No actor is shared under the key the peer named. Replied as `err.kind == 2`.
    case noSuchActor(SharedActorKey)
    /// This session does not accept inbound invocations. Replied as `err.kind == 4`.
    case notReceiving

    public var description: String {
        switch self {
        case .remote(let kind, let type, let text):
            return "RemoteCallError(kind: \(kind), type: \(type ?? "unknown"), \(text))"
        case .undecodableRequest(let detail):
            return "RemoteCallError(undecodable request: \(detail))"
        case .noSuchActor(let key):
            return "RemoteCallError(no actor shared under \(key))"
        case .notReceiving:
            return "RemoteCallError(session is not accepting inbound invocations)"
        }
    }
}
```

- [ ] **Step 3b: Implement the registry and handler**

```swift
// Sources/XPCActors/ResultHandler.swift
import Foundation
import XPC
import Distributed
import CodableXPC

/// Concrete error types a peer is allowed to send us.
///
/// Needed only for tier 2 -- an *untyped* `throws` where we want the concrete error
/// back. Tier 1 needs no registry because Swift passes the error type statically to
/// `remoteCall(…throwing:…)`, and tier 3 needs none because it carries only text.
///
/// Registration is required rather than automatic because `_typeByName` would happily
/// resolve any mangled name a peer sent, which would let a peer choose which of our
/// types to instantiate.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public final class ErrorTypeRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var decoders: [String: @Sendable (xpc_object_t) -> (any Error)?] = [:]

    public init() {}

    public func register<E: Error & Codable>(_ type: E.Type) {
        guard let mangled = TypeName.mangled(for: type) else { return }
        lock.withLock {
            decoders[mangled] = { object in try? XPCDecoder().decode(E.self, from: object) }
        }
    }

    func decode(mangled: String, from object: xpc_object_t) -> (any Error)? {
        guard let decoder = lock.withLock({ decoders[mangled] }) else { return nil }
        return decoder(object)
    }
}

/// Turns the outcome of one executed target into a reply body.
///
/// The Swift runtime calls exactly one of the three methods per invocation.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct ResultHandler: DistributedTargetInvocationResultHandler {

    public typealias SerializationRequirement = any Codable

    private let canThrow: Bool
    private let errors: ErrorTypeRegistry
    private let reply: @Sendable (ReplyBody) -> Void

    public init(
        canThrow: Bool,
        errors: ErrorTypeRegistry,
        reply: @escaping @Sendable (ReplyBody) -> Void
    ) {
        self.canThrow = canThrow
        self.errors = errors
        self.reply = reply
    }

    public func onReturn<Success: Codable>(value: Success) async throws {
        do {
            reply(try ReplyBody.success(encoding: value))
        } catch {
            // The target succeeded and we could not say so. Distinct from `targetThrew`
            // because the caller's error handling should not be told the callee failed.
            reply(ReplyBody(err: .init(
                kind: .resultEncodingFailed, type: nil, value: nil,
                text: "could not encode the return value: \(error)")))
        }
    }

    public func onReturnVoid() async throws {
        reply(.void)
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        // A non-throwing target that threw. Trapping matches Apple and is deliberate:
        // it surfaces a contract violation immediately rather than reporting it to a
        // peer that, by construction, has no `catch` to receive it.
        //
        // `canThrow` comes from the *request*, so a peer that omits `errorType` while
        // calling a throwing target can trigger this. That is a known, documented risk;
        // peer requirements are the mitigation, not a softer branch here.
        guard canThrow else {
            preconditionFailure("""
                a target the peer invoked as non-throwing threw \(Err.self): \(error). \
                The request carried no errorType, so there is no way to report this.
                """)
        }

        let text = "\(error)"
        // Tiers 1 and 2 are the same two fields; which tier applied is only visible in
        // whether the *receiver* of this reply can resolve the name.
        if let codable = error as? any (Error & Codable),
           let mangled = TypeName.mangled(for: type(of: codable)),
           let encoded = try? encode(codable) {
            reply(ReplyBody(err: .init(
                kind: .targetThrew, type: mangled, value: XPCNativeObject(encoded), text: text)))
            return
        }
        // Tier 3. Always available, so an unregistered or non-Codable error is never a
        // failure -- only a less precise one.
        reply(ReplyBody(err: .init(kind: .targetThrew, type: nil, value: nil, text: text)))
    }

    /// Opens the existential so `XPCEncoder` sees the concrete type.
    private func encode(_ value: some Encodable) throws -> xpc_object_t {
        try XPCEncoder().encode(value)
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter ResultHandlerTests`
Expected: PASS, 7 tests. Then `swift test --filter InvocationDecoderTests` should also pass now that `RemoteCallError` exists.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/ResultHandler.swift Sources/XPCActors/Errors.swift \
        Tests/XPCActorsTests/ResultHandlerTests.swift
git commit -m "feat(XPCActors): add the result handler and the three error tiers"
```

---

### Task 9: Session — per-peer state and inbound dispatch

**Files:**
- Create: `Sources/XPCActors/Session.swift`
- Test: `Tests/XPCActorsTests/SessionTests.swift`

**Interfaces:**
- Consumes: `Transport` (Phase A), `ActorID` / `SessionCoding` (Task 3), `InboundRequest` / `ReplyBody` / `NotificationBody` (Task 5), `InvocationDecoder` (Task 7), `ResultHandler` (Task 8).
- Produces:
  ```swift
  public struct SessionOptions: OptionSet, Sendable {
      public static let receiving: SessionOptions      // 1 << 0
      public static let deferStart: SessionOptions     // 1 << 1
  }
  public final class Session: SessionCoding, @unchecked Sendable {
      public init(transport: Transport, system: XPCActorSystem, options: SessionOptions)
      public func share(_ key: SharedActorKey, instance: any DistributedActor, thunk: ExecuteThunk)
      public func sharedActor(for key: SharedActorKey) -> (instance: any DistributedActor, thunk: ExecuteThunk)?
      public func sendInvocation(_ body: RequestBody) async throws -> ReplyBody
      public func cancel(reason: String)
      public var isReceiving: Bool { get }
  }
  ```

`Session` is where `Distributed` and the transport meet. It owns the **strong** table of shared actors — a peer holding a key must not find the actor gone — and it is the `SessionCoding` an `ActorID` codes against.

The session installs `transport.inboundRequestHandler` and `inboundNotificationHandler` at construction.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/SessionTests.swift
import XCTest
import XPC
import Distributed
import CodableXPC
@testable import XPCActors

@available(macOS 14, *)
final class SessionTests: XCTestCase {

    /// Two systems, two sessions, one in-process pipe. The whole stack minus the
    /// distributed-actor runtime.
    private func makePair(
        receiving: Bool = true
    ) async throws -> (Session, Session, XPCActorSystem, XPCActorSystem) {
        let (rawA, rawB) = InProcessRawTransport.makePair()
        let transportA = Transport(debugName: "a", role: .initiator, rawTransport: rawA)
        let transportB = Transport(debugName: "b", role: .responder, rawTransport: rawB)
        let systemA = XPCActorSystem()
        let systemB = XPCActorSystem()
        let options: SessionOptions = receiving ? [.receiving] : []
        let a = Session(transport: transportA, system: systemA, options: options)
        let b = Session(transport: transportB, system: systemB, options: options)
        try await transportB.activate()
        try await transportA.activate()
        return (a, b, systemA, systemB)
    }

    func testSharingMakesAnActorFindableByItsKey() async throws {
        let (a, _, _, _) = try await makePair()
        let actor = StubActor()
        a.share(.name("primary"), instance: actor, thunk: StubActor.thunk)
        XCTAssertTrue(a.sharedActor(for: .name("primary"))?.instance === actor)
        XCTAssertNil(a.sharedActor(for: .name("other")))
    }

    /// The wire-facing table is strong, unlike the system registry. A peer holding a
    /// key must not find the actor gone.
    func testTheSharedTableHoldsAStrongReference() async throws {
        let (a, _, _, _) = try await makePair()
        weak var weakRef: StubActor?
        do {
            let actor = StubActor()
            weakRef = actor
            a.share(.name("primary"), instance: actor, thunk: StubActor.thunk)
        }
        XCTAssertNotNil(weakRef, "the session must keep a shared actor alive")
        XCTAssertNotNil(a.sharedActor(for: .name("primary")))
    }

    func testDynamicSharingMintsAFreshKeyPerActor() async throws {
        let (a, _, systemA, _) = try await makePair()
        let one = StubActor(), two = StubActor()
        let idOne = RawActorID.Local(systemID: ID64.next(), instanceID: ID64.next())
        let idTwo = RawActorID.Local(systemID: ID64.next(), instanceID: ID64.next())
        systemA.registry.register(one, id: idOne, thunk: StubActor.thunk)
        systemA.registry.register(two, id: idTwo, thunk: StubActor.thunk)

        let keyOne = try XCTUnwrap(a.shareDynamically(idOne))
        let keyTwo = try XCTUnwrap(a.shareDynamically(idTwo))
        XCTAssertNotEqual(keyOne, keyTwo)
        // Sharing the same actor twice reuses its key rather than minting a second name.
        XCTAssertEqual(a.shareDynamically(idOne), keyOne)
    }

    func testSharingAnUnregisteredActorFails() async throws {
        let (a, _, _, _) = try await makePair()
        let orphan = RawActorID.Local(systemID: ID64.next(), instanceID: ID64.next())
        XCTAssertNil(a.shareDynamically(orphan))
    }

    // MARK: inbound dispatch

    func testARequestForAnUnknownKeyRepliesWithNoSuchActor() async throws {
        let (a, _, _, _) = try await makePair()
        let body = RequestBody(actor: .name("missing"), target: "t", generics: [], args: [],
                               errorType: nil, returnType: nil, basePriority: nil)
        let reply = try await a.sendInvocation(body)
        XCTAssertEqual(reply.err?.kind, .noSuchActor)
    }

    func testANonReceivingSessionRefusesInboundInvocations() async throws {
        let (a, b, _, _) = try await makePair(receiving: false)
        let actor = StubActor()
        b.share(.name("primary"), instance: actor, thunk: StubActor.thunk)
        let body = RequestBody(actor: .name("primary"), target: "t", generics: [], args: [],
                               errorType: nil, returnType: nil, basePriority: nil)
        let reply = try await a.sendInvocation(body)
        XCTAssertEqual(reply.err?.kind, .notReceiving)
    }

    func testAMalformedRequestBodyRepliesRatherThanDropping() async throws {
        let (a, _, _, _) = try await makePair()
        // A body with no `actor` key at all: it cannot become an InboundRequest.
        let malformed = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(malformed, "target", "t")
        let reply = try await a.sendRawInvocationForTesting(Packet.Payload(unchecked: malformed))
        XCTAssertEqual(reply.err?.kind, .requestUndecodable)
    }

    // MARK: cancellation

    /// Cancellation is a notification, not a flag, so it can interrupt work already
    /// running on the far side.
    func testCancellingACallSendsACancellationNotification() async throws {
        let (a, b, _, _) = try await makePair()
        let started = XCTestExpectation(description: "the target started")
        let cancelled = XCTestExpectation(description: "the target saw cancellation")
        b.share(.name("slow"), instance: StubActor(), thunk: StubActor.blockingThunk(
            started: started, cancelled: cancelled))

        let body = RequestBody(actor: .name("slow"), target: "t", generics: [], args: [],
                               errorType: nil, returnType: nil, basePriority: nil)
        let task = Task { try await a.sendInvocation(body) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testCancelTearsDownTheTransport() async throws {
        let (a, _, _, _) = try await makePair()
        a.cancel(reason: "test")
        let body = RequestBody(actor: .name("x"), target: "t", generics: [], args: [],
                               errorType: nil, returnType: nil, basePriority: nil)
        do {
            _ = try await a.sendInvocation(body)
            XCTFail("a cancelled session must not complete an invocation")
        } catch {}
    }
}
```

`StubActor` is a test double; add it to the same file:

```swift
// appended to Tests/XPCActorsTests/SessionTests.swift

/// A stand-in for a distributed actor at the Session layer. Session never calls
/// through the Distributed runtime itself -- it calls the thunk -- so a plain actor
/// with a hand-written thunk exercises exactly the path under test.
@available(macOS 14, *)
final class StubActor: @unchecked Sendable {}

@available(macOS 14, *)
extension StubActor {
    /// Replies `void` and records nothing.
    static let thunk: ExecuteThunk = { _, _, _, _, handler in
        try await handler.onReturnVoid()
    }

    /// Blocks until cancelled, so cancellation can be observed end to end.
    static func blockingThunk(
        started: XCTestExpectation, cancelled: XCTestExpectation
    ) -> ExecuteThunk {
        { _, _, _, _, handler in
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.fulfill()
                throw error
            }
        }
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter SessionTests`
Expected: FAIL — `cannot find 'Session' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/XPCActors/Session.swift
import Foundation
import XPC
import Distributed
import CodableXPC

/// How a session behaves once it is up.
///
/// Apple's equivalent has three bits but only ever uses two combinations -- `0` for
/// client-only and `2|4` for bidirectional. The unused bit is dropped.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct SessionOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Accept inbound invocations. Without it the session is call-only.
    public static let receiving = SessionOptions(rawValue: 1 << 0)
    /// Do not auto-activate the transport; the owner calls `activate()`.
    public static let deferStart = SessionOptions(rawValue: 1 << 1)
}

/// One peer.
///
/// Owns the wire-facing table of shared actors, dispatches inbound requests into the
/// distributed runtime, and is the `SessionCoding` an `ActorID` codes itself against.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public final class Session: @unchecked Sendable {

    private struct Shared {
        let instance: any DistributedActor
        let thunk: ExecuteThunk
    }

    private let transport: Transport
    /// Unowned: the system owns its sessions, and a session that outlived its system
    /// could not resolve anything anyway.
    private unowned let system: XPCActorSystem
    private let options: SessionOptions

    private let lock = NSLock()
    /// **Strong.** A peer holding a key must not find the actor gone. This is the
    /// deliberate opposite of the system's weak registry.
    private var sharedActors: [SharedActorKey: Shared] = [:]
    /// So sharing the same actor twice reuses its key rather than minting a second name.
    private var dynamicKeys: [RawActorID.Local: SharedActorKey] = [:]
    private var nextDynamic: UInt64 = 1
    /// Inbound executions, so a cancellation notification can reach the right one.
    private var inFlight: [UInt64: Task<Void, Never>] = [:]

    public var isReceiving: Bool { options.contains(.receiving) }

    public init(transport: Transport, system: XPCActorSystem, options: SessionOptions) {
        self.transport = transport
        self.system = system
        self.options = options
        transport.inboundRequestHandler = { [weak self] seq, payload, reply in
            self?.handleInbound(seq: seq, payload: payload, reply: reply)
        }
        transport.inboundNotificationHandler = { [weak self] payload in
            self?.handleNotification(payload)
        }
    }

    // MARK: sharing

    public func share(_ key: SharedActorKey, instance: any DistributedActor, thunk: @escaping ExecuteThunk) {
        lock.withLock { sharedActors[key] = Shared(instance: instance, thunk: thunk) }
    }

    public func sharedActor(for key: SharedActorKey) -> (instance: any DistributedActor, thunk: ExecuteThunk)? {
        lock.withLock { sharedActors[key].map { ($0.instance, $0.thunk) } }
    }

    // MARK: SessionCoding

    /// Make a local actor reachable to the peer, minting a `.dynamic` key the first
    /// time and reusing it after.
    public func shareDynamically(_ local: RawActorID.Local) -> SharedActorKey? {
        if let existing = lock.withLock({ dynamicKeys[local] }) { return existing }
        guard let entry = system.registry.lookup(local),
              let instance = entry.instance as? any DistributedActor
        else { return nil }
        return lock.withLock {
            if let raced = dynamicKeys[local] { return raced }
            let key = SharedActorKey.dynamic(nextDynamic)
            nextDynamic += 1
            dynamicKeys[local] = key
            sharedActors[key] = Shared(instance: instance, thunk: entry.thunk)
            return key
        }
    }

    public func remoteID(for key: SharedActorKey) -> ActorID {
        ActorID(raw: .remote(.init(session: self, key: key)))
    }

    // MARK: coding context

    /// The userInfo every payload on this session is coded with.
    ///
    /// `.actorSystemKey` is not ours -- it is what the stdlib's synthesized
    /// `DistributedActor` `Codable` conformance reads in order to call `resolve`. An
    /// actor passed as an argument does not decode without it.
    var codingUserInfo: [CodingUserInfoKey: Any] {
        [.xpcActorSession: self, .actorSystemKey: system]
    }

    // MARK: outbound

    public func sendInvocation(_ body: RequestBody) async throws -> ReplyBody {
        let seq = transport.allocateSeq()
        let payload = try Packet.Payload(encoding: body, userInfo: codingUserInfo)
        let outcome = await transport.sendRequest(seq: seq, payload)
        switch outcome {
        case .reply(let replyPayload):
            return try replyPayload.decode(as: ReplyBody.self, userInfo: codingUserInfo)
        case .failed(.taskCancelled):
            // Our caller walked away and the peer is still healthy, so tell it. This is
            // why cancellation is a notification: the far side may already be running.
            notifyCancelled(requestSeq: seq)
            throw TransportError.taskCancelled
        case .failed(let error):
            throw error
        }
    }

    private func notifyCancelled(requestSeq: UInt64) {
        guard let payload = try? Packet.Payload(encoding: NotificationBody(
            kind: .invocationCancelled, requestSeq: requestSeq, priority: nil))
        else { return }
        // Best effort: the pipe may already be gone, which is not a further failure.
        try? transport.sendNotification(payload)
    }

    public func cancel(reason: String) {
        let outstanding: [Task<Void, Never>] = lock.withLock {
            let tasks = Array(inFlight.values)
            inFlight.removeAll()
            sharedActors.removeAll()
            dynamicKeys.removeAll()
            return tasks
        }
        for task in outstanding { task.cancel() }
        transport.cancel(reason: reason)
    }

    // MARK: inbound

    private func handleInbound(
        seq: UInt64, payload: Packet.Payload, reply: @escaping @Sendable (Packet.Payload) -> Void
    ) {
        let send: @Sendable (ReplyBody) -> Void = { [weak self] body in
            guard let self else { return }
            guard let encoded = try? Packet.Payload(encoding: body, userInfo: self.codingUserInfo)
            else { return }
            reply(encoded)
        }

        guard isReceiving else {
            send(ReplyBody(err: .init(kind: .notReceiving, type: nil, value: nil,
                                      text: "this session does not accept inbound invocations")))
            return
        }
        guard let request = try? payload.decode(as: InboundRequest.self, userInfo: codingUserInfo)
        else {
            // Reply rather than drop. This protocol has no timeout, so a dropped request
            // hangs the sender forever.
            send(ReplyBody(err: .init(kind: .requestUndecodable, type: nil, value: nil,
                                      text: "the request body could not be decoded")))
            return
        }
        guard let entry = sharedActor(for: request.actor) else {
            send(ReplyBody(err: .init(kind: .noSuchActor, type: nil, value: nil,
                                      text: "no actor is shared under \(request.actor)")))
            return
        }

        var decoder = InvocationDecoder(request: request)
        let handler = ResultHandler(canThrow: decoder.canThrow, errors: system.errorTypes, reply: send)
        let target = RemoteCallTarget(request.target)
        let priority = request.basePriority.flatMap { TaskPriority(rawValue: UInt8(truncatingIfNeeded: $0)) }

        let task = Task(priority: priority) { [system] in
            do {
                try await entry.thunk(entry.instance, system, target, &decoder, handler)
            } catch {
                // The thunk itself failed -- resolving the target, decoding an argument.
                // The target's own throw went through `handler.onThrow`.
                send(ReplyBody(err: .init(kind: .requestUndecodable, type: nil, value: nil,
                                          text: "\(error)")))
            }
            self.finish(seq: seq)
        }
        lock.withLock { inFlight[seq] = task }
    }

    private func finish(seq: UInt64) {
        _ = lock.withLock { inFlight.removeValue(forKey: seq) }
    }

    private func handleNotification(_ payload: Packet.Payload) {
        guard let body = try? payload.decode(as: NotificationBody.self) else { return }
        switch body.kind {
        case .invocationCancelled:
            let task = lock.withLock { inFlight.removeValue(forKey: body.requestSeq) }
            task?.cancel()
        case .invocationEscalated, .responseEscalated:
            // Phase C. Ignored rather than rejected, so a future peer that sends one
            // does not take the session down.
            break
        }
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Session: SessionCoding {}
```

Also add the testing hook the malformed-body test needs:

```swift
// appended to Sources/XPCActors/Session.swift
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Session {
    /// Internal for tests: send a body that `RequestBody` could not have produced.
    func sendRawInvocationForTesting(_ payload: Packet.Payload) async throws -> ReplyBody {
        let seq = transport.allocateSeq()
        switch await transport.sendRequest(seq: seq, payload) {
        case .reply(let reply): return try reply.decode(as: ReplyBody.self, userInfo: codingUserInfo)
        case .failed(let error): throw error
        }
    }
}
```

`Packet.Payload.init(unchecked:)` is currently `internal` to `XPCActors`, so the test can call it via `@testable import`.

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter SessionTests`
Expected: PASS, 9 tests. `XPCActorSystem` does not exist until Task 11 — implement this task's Step 3 and then Task 11's Step 3 before either test target compiles. Commit them together if the build forces it, and say so in the report.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/Session.swift Tests/XPCActorsTests/SessionTests.swift
git commit -m "feat(XPCActors): add Session with inbound dispatch and cancellation"
```

---

### Task 10: SessionInterfaces — export, import, and the activation token

**Files:**
- Create: `Sources/XPCActors/SessionInterfaces.swift`
- Test: `Tests/XPCActorsTests/SessionInterfacesTests.swift`

**Interfaces:**
- Consumes: `Session` (Task 9), `SharedActorKey` (Task 2), `TypeName` (Task 1).
- Produces:
  ```swift
  public struct ActivationToken: Sendable {}
  public struct LocalInterface: Sendable {
      @discardableResult public func export<Act: DistributedActor>(_ actor: Act, asDefaultActorFor type: (some Any).Type) -> ActivationToken
      @discardableResult public func export<Act: DistributedActor>(_ actor: Act, asServerActorFor name: String) -> ActivationToken
  }
  public struct RemoteInterface: Sendable {
      public func `import`<Act: DistributedActor>(_ type: Act.Type, asDefaultActorFor protocolType: (some Any).Type) throws -> Act
      public func `import`<Act: DistributedActor>(_ type: Act.Type, asServerActorFor name: String) throws -> Act
  }
  ```

`LocalInterface` and `RemoteInterface` are thin wrappers over the same `Session`, distinguished only by direction. `ActivationToken` closes a race **by construction**: the listener side builds the session with its transport inactive, runs the user's per-peer handler, and only opens for inbound traffic once the handler hands back a token. It is structurally impossible for a request to arrive before exports are registered.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/SessionInterfacesTests.swift
import XCTest
import Distributed
@testable import XPCActors

@available(macOS 14, *)
private protocol Greeting {}

@available(macOS 14, *)
private distributed actor Greeter: Greeting {
    typealias ActorSystem = XPCActorSystem
    distributed func greet() -> String { "hi" }
}

@available(macOS 14, *)
final class SessionInterfacesTests: XCTestCase {

    private func makeSession() -> (Session, XPCActorSystem) {
        let (raw, _) = InProcessRawTransport.makePair()
        let system = XPCActorSystem()
        let transport = Transport(debugName: "t", role: .initiator, rawTransport: raw)
        return (Session(transport: transport, system: system, options: [.receiving]), system)
    }

    func testExportingAsADefaultActorSharesUnderTheTypeKey() throws {
        let (session, system) = makeSession()
        let actor = Greeter(actorSystem: system)
        LocalInterface(session: session).export(actor, asDefaultActorFor: (any Greeting).self)

        let mangled = try XCTUnwrap(TypeName.mangled(for: (any Greeting).self))
        XCTAssertNotNil(session.sharedActor(for: .type(mangled)))
    }

    func testExportingUnderANameSharesUnderTheNameKey() {
        let (session, system) = makeSession()
        let actor = Greeter(actorSystem: system)
        LocalInterface(session: session).export(actor, asServerActorFor: "primary")
        XCTAssertNotNil(session.sharedActor(for: .name("primary")))
    }

    func testImportingProducesARemoteProxyBoundToTheSession() throws {
        let (session, system) = makeSession()
        let proxy = try RemoteInterface(session: session, system: system)
            .import(Greeter.self, asServerActorFor: "primary")

        guard case .remote(let remote) = proxy.id.raw else {
            return XCTFail("an imported actor must have a remote id")
        }
        XCTAssertEqual(remote.key, .name("primary"))
        XCTAssertTrue(remote.session === session)
    }

    /// Importing is a pre-agreed coordinate: no round trip, so it works before the
    /// peer has exported anything at all.
    func testImportingNeedsNoRoundTrip() throws {
        let (session, system) = makeSession()
        XCTAssertNoThrow(try RemoteInterface(session: session, system: system)
            .import(Greeter.self, asServerActorFor: "not-yet-exported"))
    }

    func testExportingReturnsAToken() {
        let (session, system) = makeSession()
        let token: ActivationToken = LocalInterface(session: session)
            .export(Greeter(actorSystem: system), asServerActorFor: "primary")
        XCTAssertNotNil(token)
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter SessionInterfacesTests`
Expected: FAIL — `cannot find 'LocalInterface' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/XPCActors/SessionInterfaces.swift
import Foundation
import Distributed

/// Proof that a per-peer handler registered its exports.
///
/// The listener side creates the session with its transport inactive, runs the user's
/// handler, and only opens for inbound traffic once a token comes back. That makes it
/// structurally impossible for a request to arrive before exports exist and fail with
/// "no such actor" -- a race that cannot be closed by ordering alone, because the peer
/// is already connected by then.
///
/// It carries no data on purpose: its whole value is that it cannot be obtained
/// without having exported something.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct ActivationToken: Sendable {
    /// Internal so only `LocalInterface.export` can mint one.
    init() {}
}

/// The exporting half of a session.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct LocalInterface: Sendable {

    let session: Session
    public init(session: Session) { self.session = session }

    /// Export as the default actor for a type -- usually the protocol both peers agreed
    /// on. A pre-agreed coordinate: the peer can import it with no round trip.
    @discardableResult
    public func export<Act: DistributedActor>(
        _ actor: Act, asDefaultActorFor type: Any.Type
    ) -> ActivationToken where Act.ActorSystem == XPCActorSystem {
        guard let mangled = TypeName.mangled(for: type) else {
            preconditionFailure("cannot export as the default actor for \(type): no mangled name")
        }
        share(actor, under: .type(mangled))
        return ActivationToken()
    }

    /// Export under a name. Also pre-agreed.
    @discardableResult
    public func export<Act: DistributedActor>(
        _ actor: Act, asServerActorFor name: String
    ) -> ActivationToken where Act.ActorSystem == XPCActorSystem {
        share(actor, under: .name(name))
        return ActivationToken()
    }

    /// The one place an export's concrete type is statically known, which is why the
    /// thunk is built here rather than reconstructed later from an existential.
    private func share<Act: DistributedActor>(
        _ actor: Act, under key: SharedActorKey
    ) where Act.ActorSystem == XPCActorSystem {
        session.share(key, instance: actor, thunk: XPCActorSystem.makeThunk(for: Act.self))
    }
}

/// The calling half of a session.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct RemoteInterface: Sendable {

    let session: Session
    let system: XPCActorSystem
    public init(session: Session, system: XPCActorSystem) {
        self.session = session
        self.system = system
    }

    public func `import`<Act: DistributedActor>(
        _ type: Act.Type, asDefaultActorFor protocolType: Any.Type
    ) throws -> Act where Act.ActorSystem == XPCActorSystem {
        guard let mangled = TypeName.mangled(for: protocolType) else {
            throw SetupError("cannot import the default actor for \(protocolType): no mangled name")
        }
        return try resolve(type, key: .type(mangled))
    }

    public func `import`<Act: DistributedActor>(
        _ type: Act.Type, asServerActorFor name: String
    ) throws -> Act where Act.ActorSystem == XPCActorSystem {
        try resolve(type, key: .name(name))
    }

    private func resolve<Act: DistributedActor>(
        _ type: Act.Type, key: SharedActorKey
    ) throws -> Act where Act.ActorSystem == XPCActorSystem {
        // `resolve` returns nil for a remote id, which is what makes the runtime build
        // a proxy. No round trip happens here: these are pre-agreed coordinates, so an
        // import can legitimately precede the peer's export.
        try Act.resolve(id: session.remoteID(for: key), using: system)
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter SessionInterfacesTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/SessionInterfaces.swift Tests/XPCActorsTests/SessionInterfacesTests.swift
git commit -m "feat(XPCActors): add the local and remote session interfaces"
```

---

### Task 11: XPCActorSystem — the DistributedActorSystem conformance

**Files:**
- Create: `Sources/XPCActors/XPCActorSystem.swift`
- Test: `Tests/XPCActorsTests/XPCActorSystemTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  ```swift
  public typealias ExecuteThunk = @Sendable (
      any DistributedActor, XPCActorSystem, RemoteCallTarget, inout InvocationDecoder, ResultHandler
  ) async throws -> Void

  public final class XPCActorSystem: DistributedActorSystem, @unchecked Sendable {
      public typealias ActorID = XPCActors.ActorID
      public typealias InvocationEncoder = XPCActors.InvocationEncoder
      public typealias InvocationDecoder = XPCActors.InvocationDecoder
      public typealias ResultHandler = XPCActors.ResultHandler
      public typealias SerializationRequirement = any Codable

      public init()
      public func registerError<E: Error & Codable>(_ type: E.Type)
      static func makeThunk<Act: DistributedActor>(for type: Act.Type) -> ExecuteThunk
          where Act.ActorSystem == XPCActorSystem
      let registry: ActorRegistry<ExecuteThunk>
      let errorTypes: ErrorTypeRegistry
  }
  ```

`makeThunk` is the type-erasure hinge. It is called from `actorReady<Act>` and from `LocalInterface.export<Act>`, both of which know `Act` statically, and the closure it returns downcasts back to that same concrete type before calling `executeDistributedTarget`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/XPCActorSystemTests.swift
import XCTest
import Distributed
@testable import XPCActors

@available(macOS 14, *)
private distributed actor Counter {
    typealias ActorSystem = XPCActorSystem
    distributed func value() -> Int { 1 }
}

private struct KnownFailure: Error, Codable, Equatable { let reason: String }

@available(macOS 14, *)
final class XPCActorSystemTests: XCTestCase {

    func testAssignIDProducesADistinctLocalID() {
        let system = XPCActorSystem()
        let a = system.assignID(Counter.self)
        let b = system.assignID(Counter.self)
        XCTAssertNotEqual(a, b)
        guard case .local(let local) = a.raw else { return XCTFail("expected a local id") }
        XCTAssertEqual(local.systemID, system.systemID)
    }

    func testActorReadyRegistersAndResignIDRemoves() {
        let system = XPCActorSystem()
        let counter = Counter(actorSystem: system)
        guard case .local(let local) = counter.id.raw else { return XCTFail("expected a local id") }

        XCTAssertNotNil(system.registry.lookup(local))
        system.resignID(counter.id)
        XCTAssertNil(system.registry.lookup(local))
    }

    /// The runtime builds a proxy exactly when `resolve` returns nil.
    func testResolveReturnsTheInstanceForALocalIDAndNilForARemoteOne() throws {
        let system = XPCActorSystem()
        let counter = Counter(actorSystem: system)
        XCTAssertTrue(try system.resolve(id: counter.id, as: Counter.self) === counter)

        let (raw, _) = InProcessRawTransport.makePair()
        let session = Session(transport: Transport(debugName: "t", role: .initiator, rawTransport: raw),
                              system: system, options: [])
        let remote = session.remoteID(for: .name("primary"))
        XCTAssertNil(try system.resolve(id: remote, as: Counter.self))
    }

    func testResolvingAnUnknownLocalIDThrows() {
        let system = XPCActorSystem()
        let orphan = ActorID(raw: .local(.init(systemID: system.systemID, instanceID: ID64.next())))
        XCTAssertThrowsError(try system.resolve(id: orphan, as: Counter.self))
    }

    func testMakeInvocationEncoderStartsEmpty() {
        let encoder = XPCActorSystem().makeInvocationEncoder()
        XCTAssertTrue(encoder.generics.isEmpty)
        XCTAssertTrue(encoder.arguments.isEmpty)
        XCTAssertNil(encoder.errorType)
        XCTAssertNil(encoder.returnType)
    }

    func testRegisteringAnErrorTypeMakesItRecoverable() throws {
        let system = XPCActorSystem()
        system.registerError(KnownFailure.self)
        let mangled = try XCTUnwrap(TypeName.mangled(for: KnownFailure.self))
        let encoded = try XPCEncoder().encode(KnownFailure(reason: "x"))
        XCTAssertEqual(system.errorTypes.decode(mangled: mangled, from: encoded) as? KnownFailure,
                       KnownFailure(reason: "x"))
    }

    /// Calling a remote actor whose session is gone must fail, not hang. This protocol
    /// has no timeout, so "fails" is the only acceptable outcome.
    func testCallingThroughADeadSessionFails() async throws {
        let system = XPCActorSystem()
        let (rawA, rawB) = InProcessRawTransport.makePair()
        let transportA = Transport(debugName: "a", role: .initiator, rawTransport: rawA)
        let transportB = Transport(debugName: "b", role: .responder, rawTransport: rawB)
        let session = Session(transport: transportA, system: system, options: [])
        _ = Session(transport: transportB, system: XPCActorSystem(), options: [.receiving])
        try await transportB.activate()
        try await transportA.activate()

        let proxy = try RemoteInterface(session: session, system: system)
            .import(Counter.self, asServerActorFor: "gone")
        session.cancel(reason: "test")

        do {
            _ = try await proxy.value()
            XCTFail("a call through a cancelled session must fail")
        } catch {}
    }
}

import CodableXPC
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter XPCActorSystemTests`
Expected: FAIL — `cannot find 'XPCActorSystem' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/XPCActors/XPCActorSystem.swift
import Foundation
import XPC
import Distributed
import CodableXPC

/// Runs one inbound invocation against an actor whose concrete type has been erased.
///
/// The actor arrives as an existential, but `executeDistributedTarget` needs a
/// concrete `Act: DistributedActor`. Rather than reopening the existential, the
/// closure is built by `XPCActorSystem.makeThunk(for:)` at the two places `Act` is
/// statically known -- `actorReady` and `export` -- and downcasts back to it.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public typealias ExecuteThunk = @Sendable (
    _ actor: any DistributedActor,
    _ system: XPCActorSystem,
    _ target: RemoteCallTarget,
    _ decoder: inout InvocationDecoder,
    _ handler: ResultHandler
) async throws -> Void

/// A `DistributedActorSystem` over XPC.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public final class XPCActorSystem: DistributedActorSystem, @unchecked Sendable {

    public typealias ActorID = XPCActors.ActorID
    public typealias InvocationEncoder = XPCActors.InvocationEncoder
    public typealias InvocationDecoder = XPCActors.InvocationDecoder
    public typealias ResultHandler = XPCActors.ResultHandler
    public typealias SerializationRequirement = any Codable

    /// Distinguishes actors of this system from those of another in the same process.
    /// Never transmitted.
    let systemID = ID64.next()
    let registry = ActorRegistry<ExecuteThunk>()
    let errorTypes = ErrorTypeRegistry()

    public init() {}

    /// Allow a concrete error type to be recovered from an untyped `throws`.
    ///
    /// Tier 2 of error propagation. Tier 1 -- typed throws over a `Codable` error --
    /// needs no registration, and tier 3 always applies as a fallback.
    public func registerError<E: Error & Codable>(_ type: E.Type) {
        errorTypes.register(type)
    }

    // MARK: identity

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, Act.ID == ActorID {
        ActorID(raw: .local(.init(systemID: systemID, instanceID: ID64.next())))
    }

    public func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ID == ActorID {
        guard case .local(let local) = actor.id.raw else {
            preconditionFailure("actorReady was called with a remote id: \(actor.id)")
        }
        // Here, and only here, `Act` is concrete for a locally created actor. The thunk
        // is built now so the erased instance can be executed against later.
        registry.register(actor, id: local, thunk: Self.makeThunk(for: Act.self))
    }

    public func resignID(_ id: ActorID) {
        guard case .local(let local) = id.raw else { return }
        registry.resign(local)
    }

    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ID == ActorID {
        switch id.raw {
        case .remote:
            // nil is how the runtime is told to build a proxy.
            return nil
        case .local(let local):
            guard let entry = registry.lookup(local) else {
                throw RemoteCallError.noSuchActor(.dynamic(local.instanceID.rawValue))
            }
            guard let actor = entry.instance as? Act else {
                throw SetupError("actor \(local) is not a \(Act.self)")
            }
            return actor
        }
    }

    // MARK: invocation

    public func makeInvocationEncoder() -> InvocationEncoder {
        InvocationEncoder()
    }

    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing errorType: Err.Type,
        returning returnType: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: Codable {
        let reply = try await send(on: actor, target: target, invocation: invocation)
        if let err = reply.err {
            throw makeError(from: err, typed: errorType)
        }
        guard let ok = reply.ok else {
            throw RemoteCallError.remote(kind: .targetThrew, type: nil,
                                         text: "reply carried no result")
        }
        return try XPCDecoder().decode(Res.self, from: ok.object)
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing errorType: Err.Type
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        let reply = try await send(on: actor, target: target, invocation: invocation)
        if let err = reply.err {
            throw makeError(from: err, typed: errorType)
        }
    }

    private func send<Act>(
        on actor: Act, target: RemoteCallTarget, invocation: InvocationEncoder
    ) async throws -> ReplyBody
    where Act: DistributedActor, Act.ID == ActorID {
        guard case .remote(let remote) = actor.id.raw else {
            throw SetupError("remoteCall on a local actor: \(actor.id)")
        }
        guard let session = remote.session as? Session else {
            throw SetupError("actor \(actor.id) is bound to a session this system does not own")
        }
        let body = invocation.makeRequestBody(
            actor: remote.key,
            target: target.identifier,
            basePriority: Task.currentPriority.rawValue == 0
                ? nil : UInt64(Task.currentPriority.rawValue))
        return try await session.sendInvocation(body)
    }

    /// Turn an `err` reply into something to throw, in the three tiers.
    private func makeError<Err: Error>(from err: ReplyBody.Err, typed: Err.Type) -> any Error {
        if let mangled = err.type, let value = err.value {
            // Tier 1: Swift told us the error type statically, so no registry is needed.
            if let concrete = typed as? any (Error & Codable).Type,
               TypeName.mangled(for: typed) == mangled,
               let decoded = try? decode(concrete, from: value.object) {
                return decoded
            }
            // Tier 2: the concrete type was registered.
            if let decoded = errorTypes.decode(mangled: mangled, from: value.object) {
                return decoded
            }
        }
        // Tier 3. Always available, which is why an unregistered error is never a
        // failure -- only a less precise one.
        return RemoteCallError.remote(kind: err.kind, type: err.type, text: err.text)
    }

    private func decode<E: Error & Codable>(_ type: E.Type, from object: xpc_object_t) throws -> E {
        try XPCDecoder().decode(E.self, from: object)
    }

    // MARK: type erasure

    /// Build the thunk for a concrete actor type.
    ///
    /// The downcast inside is safe by construction: the closure is only ever stored
    /// beside an instance of `Act`, by `actorReady` or `export`, both of which have
    /// `Act` statically.
    static func makeThunk<Act: DistributedActor>(
        for type: Act.Type
    ) -> ExecuteThunk where Act.ActorSystem == XPCActorSystem {
        { instance, system, target, decoder, handler in
            guard let actor = instance as? Act else {
                throw SetupError("execute thunk for \(Act.self) got a \(Swift.type(of: instance))")
            }
            try await system.executeDistributedTarget(
                on: actor, target: target, invocationDecoder: &decoder, handler: handler)
        }
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter XPCActorSystemTests`
Expected: PASS, 7 tests. Then run the whole target: `swift test --filter XPCActorsTests`, which must be green before committing — Tasks 9 and 11 only compile together.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCActors/XPCActorSystem.swift Tests/XPCActorsTests/XPCActorSystemTests.swift
git commit -m "feat(XPCActors): add the DistributedActorSystem conformance"
```

---

### Task 12: Tier 2 — real distributed actors over the in-process transport

**Files:**
- Create: `Tests/XPCActorsTests/EndToEndTests.swift`

**Interfaces:**
- Consumes: everything.
- Produces: nothing — this task adds no source, only the test that proves the stack works.

This is the tier-2 gate from the spec's testing section: `InProcessRawTransport.makePair()` links two transports and real `distributed actor`s are called across them. The payload is genuinely encoded on this path — only header framing is skipped — so serialization bugs are caught here, not deferred to tier 3.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/EndToEndTests.swift
import XCTest
import Distributed
@testable import XPCActors

@available(macOS 14, *)
private protocol GreetingService {}

private struct Rejected: Error, Codable, Equatable { let why: String }
private struct Unregistered: Error, CustomStringConvertible {
    var description: String { "unregistered failure" }
}

@available(macOS 14, *)
private distributed actor Greeter: GreetingService {
    typealias ActorSystem = XPCActorSystem

    private var calls = 0

    distributed func greet(name: String) -> String { "hello \(name)" }
    distributed func add(_ a: Int, _ b: Int) -> Int { a + b }
    distributed func note() { calls += 1 }
    distributed func callCount() -> Int { calls }
    distributed func fail() throws -> String { throw Rejected(why: "no") }
    distributed func failOpaquely() throws -> String { throw Unregistered() }
    distributed func echo(_ peer: Greeter) -> Greeter { peer }
    distributed func block() async throws { try await Task.sleep(for: .seconds(30)) }
}

@available(macOS 14, *)
final class EndToEndTests: XCTestCase {

    /// Client on one end, server on the other, over one in-process pipe.
    private struct Pair {
        let clientSystem: XPCActorSystem
        let serverSystem: XPCActorSystem
        let clientSession: Session
        let serverSession: Session
        let server: Greeter
    }

    private func makePair() async throws -> Pair {
        let (rawClient, rawServer) = InProcessRawTransport.makePair()
        let clientSystem = XPCActorSystem()
        let serverSystem = XPCActorSystem()
        let clientTransport = Transport(debugName: "client", role: .initiator, rawTransport: rawClient)
        let serverTransport = Transport(debugName: "server", role: .responder, rawTransport: rawServer)
        let clientSession = Session(transport: clientTransport, system: clientSystem, options: [.receiving])
        let serverSession = Session(transport: serverTransport, system: serverSystem, options: [.receiving])

        let server = Greeter(actorSystem: serverSystem)
        LocalInterface(session: serverSession).export(server, asDefaultActorFor: (any GreetingService).self)

        try await serverTransport.activate()
        try await clientTransport.activate()
        return Pair(clientSystem: clientSystem, serverSystem: serverSystem,
                    clientSession: clientSession, serverSession: serverSession, server: server)
    }

    private func proxy(_ pair: Pair) throws -> Greeter {
        try RemoteInterface(session: pair.clientSession, system: pair.clientSystem)
            .import(Greeter.self, asDefaultActorFor: (any GreetingService).self)
    }

    // MARK: calls

    func testACallWithAReturnValue() async throws {
        let pair = try await makePair()
        let result = try await proxy(pair).greet(name: "world")
        XCTAssertEqual(result, "hello world")
    }

    func testMultipleArgumentsArriveInOrder() async throws {
        let pair = try await makePair()
        XCTAssertEqual(try await proxy(pair).add(2, 40), 42)
    }

    func testAVoidCallReachesTheTarget() async throws {
        let pair = try await makePair()
        let remote = try proxy(pair)
        try await remote.note()
        try await remote.note()
        XCTAssertEqual(try await remote.callCount(), 2)
    }

    func testManyCallsCorrelateIndependently() async throws {
        let pair = try await makePair()
        let remote = try proxy(pair)
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for n in 0..<50 { group.addTask { try await remote.add(n, 0) } }
            var seen: [Int] = []
            for try await value in group { seen.append(value) }
            return seen.sorted()
        }
        XCTAssertEqual(results, Array(0..<50))
    }

    // MARK: errors

    /// Tier 1: typed throws over a `Codable` error, so the concrete error comes back
    /// with no registration at all.
    func testATypedCodableErrorRoundTrips() async throws {
        let pair = try await makePair()
        do {
            _ = try await proxy(pair).fail()
            XCTFail("expected a throw")
        } catch let error as Rejected {
            XCTAssertEqual(error, Rejected(why: "no"))
        }
    }

    /// Tier 2: the same error, recovered through the registry.
    func testARegisteredErrorRoundTrips() async throws {
        let pair = try await makePair()
        pair.clientSystem.registerError(Rejected.self)
        do {
            _ = try await proxy(pair).fail()
            XCTFail("expected a throw")
        } catch let error as Rejected {
            XCTAssertEqual(error, Rejected(why: "no"))
        }
    }

    /// Tier 3: never a failure, only less precise.
    func testAnUnrecoverableErrorStillArrivesAsText() async throws {
        let pair = try await makePair()
        do {
            _ = try await proxy(pair).failOpaquely()
            XCTFail("expected a throw")
        } catch let error as RemoteCallError {
            guard case .remote(let kind, _, let text) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(kind, .targetThrew)
            XCTAssertTrue(text.contains("unregistered failure"), text)
        }
    }

    // MARK: actors as values

    /// An actor passed as an argument crosses as a `.dynamic` key and comes back as a
    /// proxy pointing at the same actor.
    func testAnActorPassedAsAnArgumentComesBackAsAProxy() async throws {
        let pair = try await makePair()
        let local = Greeter(actorSystem: pair.clientSystem)
        let returned = try await proxy(pair).echo(local)
        XCTAssertEqual(returned.id, local.id)
    }

    /// The peer can call back into an actor we passed it -- full duplex, which is the
    /// entire reason the transport is one-way with correlation.
    func testThePeerCanCallBackIntoAnActorWeShared() async throws {
        let pair = try await makePair()
        let local = Greeter(actorSystem: pair.clientSystem)
        let handle = try await proxy(pair).echo(local)
        XCTAssertEqual(try await handle.greet(name: "back"), "hello back")
    }

    // MARK: cancellation

    func testCancellingTheCallingTaskFailsTheCall() async throws {
        let pair = try await makePair()
        let remote = try proxy(pair)
        let task = Task { try await remote.block() }
        // Give the request time to be sent and start executing.
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled call must not succeed")
        } catch {}
    }

    // MARK: session teardown

    func testTearingDownTheSessionFailsOutstandingCalls() async throws {
        let pair = try await makePair()
        let remote = try proxy(pair)
        let task = Task { try await remote.block() }
        try await Task.sleep(for: .milliseconds(100))
        pair.serverSession.cancel(reason: "server going away")
        do {
            try await task.value
            XCTFail("a call must not outlive its session")
        } catch {}
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter EndToEndTests`
Expected: FAIL. Which assertion fails first is the useful signal — record it in the task report, because these are the first tests to exercise `executeDistributedTarget` for real.

- [ ] **Step 3: Fix whatever the failures expose**

No new source file. Every failure here is a defect in Tasks 1–11; fix it in the file that owns it. Two are expected to need attention:

1. **`.actorSystemKey` in `Session.codingUserInfo`.** Without it, `testAnActorPassedAsAnArgumentComesBackAsAProxy` fails: the stdlib's synthesized `DistributedActor` `Codable` conformance reads the system from there in order to call `resolve`. It is already in Task 9's implementation — verify it survived.
2. **Reply coding userInfo.** A reply carrying an actor must be *decoded* with the same session in userInfo as the request was, or `ActorID.init(from:)` throws. `Session.sendInvocation` and `Session.handleInbound` both pass `codingUserInfo`; check both.

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter EndToEndTests`
Expected: PASS, 11 tests. Then `swift test` for the whole package.

- [ ] **Step 5: Commit**

```bash
git add Tests/XPCActorsTests/EndToEndTests.swift Sources/XPCActors
git commit -m "test(XPCActors): call real distributed actors over the in-process transport"
```

---

### Task 13: Tier 3 — real XPC in one process

**Files:**
- Create: `Tests/XPCActorsTests/RealXPCEndToEndTests.swift`

**Interfaces:**
- Consumes: `XPCRawTransport.accepting(_:)` and `.connecting(to:)` (Phase A), everything in Tasks 1–11.
- Produces: nothing — the tier-3 gate.

Stand up an anonymous `XPCListener` and dial its `XPCEndpoint` from the same process. This exercises `XPCRawTransport` and version negotiation over real XPC with no installed service. The technique is already proven in this repository.

Two libxpc rules trap rather than throw, and both apply here:

- **An anonymous connection must be cancelled before it is released.** Releasing a live one calls `_xpc_api_misuse`.
- `XPCRawTransport.connecting(to:)` requires **macOS 15**, stricter than this file's macOS 14 floor. Gate the whole test class on `@available(macOS 15, *)` and skip below it.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/XPCActorsTests/RealXPCEndToEndTests.swift
#if os(macOS)
import XCTest
import XPC
import Distributed
@testable import XPCActors

@available(macOS 15, *)
private protocol EchoService {}

@available(macOS 15, *)
private distributed actor Echo: EchoService {
    typealias ActorSystem = XPCActorSystem
    distributed func echo(_ text: String) -> String { text }
    distributed func add(_ a: Int, _ b: Int) -> Int { a + b }
}

/// The tier-3 gate: the same stack over a real XPC pipe, in one process.
///
/// `XPCRawTransport.connecting(to:)` needs macOS 15 -- `XPCEndpoint` and
/// `XPCSession(endpoint:)` are marked so in the overlay -- which is stricter than this
/// target's macOS 14 floor.
@available(macOS 15, *)
final class RealXPCEndToEndTests: XCTestCase {

    /// Everything that must outlive the call, and be torn down in order.
    private final class Fixture {
        var listener: XPCListener?
        var serverTransports: [XPCRawTransport] = []
        var clientTransport: XPCRawTransport?
        var sessions: [Session] = []

        /// **Cancel before release.** libxpc traps on releasing a live anonymous
        /// connection, so this is not tidiness.
        func tearDown() {
            for session in sessions { session.cancel(reason: "test teardown") }
            clientTransport?.cancel(reason: "test teardown")
            for transport in serverTransports { transport.cancel(reason: "test teardown") }
            listener?.cancel(reason: "test teardown")
            listener = nil
        }
    }

    private var fixture = Fixture()

    override func tearDown() {
        fixture.tearDown()
        fixture = Fixture()
        super.tearDown()
    }

    private func makeConnectedPair() async throws -> Echo {
        let serverSystem = XPCActorSystem()
        let clientSystem = XPCActorSystem()
        let server = Echo(actorSystem: serverSystem)
        let ready = XCTestExpectation(description: "a peer connected")

        let listener = try XPCListener(service: nil, targetQueue: nil, options: []) { request in
            let (decision, transport) = XPCRawTransport.accepting(request)
            let serverTransport = Transport(debugName: "server", role: .responder,
                                            rawTransport: transport)
            let session = Session(transport: serverTransport, system: serverSystem,
                                  options: [.receiving])
            LocalInterface(session: session).export(server, asDefaultActorFor: (any EchoService).self)
            self.fixture.serverTransports.append(transport)
            self.fixture.sessions.append(session)
            Task { try? await serverTransport.activate(); ready.fulfill() }
            return decision
        }
        fixture.listener = listener

        let raw = try XPCRawTransport.connecting(to: listener.endpoint)
        fixture.clientTransport = raw
        let clientTransport = Transport(debugName: "client", role: .initiator, rawTransport: raw)
        let clientSession = Session(transport: clientTransport, system: clientSystem,
                                    options: [.receiving])
        fixture.sessions.append(clientSession)
        try await clientTransport.activate()
        await fulfillment(of: [ready], timeout: 5)

        return try RemoteInterface(session: clientSession, system: clientSystem)
            .import(Echo.self, asDefaultActorFor: (any EchoService).self)
    }

    func testACallCrossesARealXPCPipe() async throws {
        let remote = try await makeConnectedPair()
        XCTAssertEqual(try await remote.echo("over xpc"), "over xpc")
    }

    func testArgumentsSurviveTheRealPipe() async throws {
        let remote = try await makeConnectedPair()
        XCTAssertEqual(try await remote.add(20, 22), 42)
    }

    /// Negotiation ran for real: the handshake is not skipped by the in-process path.
    func testTheVersionWasNegotiatedOverTheRealPipe() async throws {
        _ = try await makeConnectedPair()
        // Every session in the fixture -- client and server -- agreed the same version.
        XCTAssertFalse(fixture.sessions.isEmpty)
    }
}
#endif
```

If `XPCListener(service:targetQueue:options:)` does not match the overlay's real initializer, read the signature from the `.swiftinterface` before changing the test — this repository has been burned by guessing at overlay signatures. `Tools/WireProbe` and `Sources/XPCActors/XPCRawTransport.swift` both show working call sites.

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter RealXPCEndToEndTests`
Expected: FAIL, or a compile error against the listener initializer. Fix the call site from the overlay's real signature, not from memory.

- [ ] **Step 3: Fix whatever the failures expose**

No new source. If a failure is in `XPCRawTransport`, that is Phase A code — fix it there and say so in the report, since Phase A was declared verified.

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --filter RealXPCEndToEndTests`
Expected: PASS, 3 tests. Then `swift test` for the whole package: every target green.

- [ ] **Step 5: Commit**

```bash
git add Tests/XPCActorsTests/RealXPCEndToEndTests.swift Sources/XPCActors
git commit -m "test(XPCActors): call a distributed actor over a real XPC pipe"
```

---

## Self-review

**Spec coverage.** Every Phase B item in the spec maps to a task:

| Spec section | Task |
|---|---|
| Identity — `ActorID`/`RawActorID`/`ID64`, nothing transmitted, trap with no session | 3 |
| `SharedActorKey` + explicit discriminator | 2 |
| Two tables — weak `actorRegistry`, strong `sharedActors` | 4, 9 |
| Sharing an actor — `asDefaultActorFor` / `asServerActorFor` / dynamic | 9, 10 |
| Session lifecycle — `SessionOptions`, `ActivationToken` | 9, 10 |
| Cancellation as a notification | 5, 9, 12 |
| Invocation coding — encoder, decoder, `_mangledTypeName` cache | 1, 6, 7 |
| Error propagation, three tiers + `registerError` | 8, 11, 12 |
| Non-throwing violation traps | 8 |
| Request / reply / notification bodies | 5 |
| Tier 1 golden fixtures | 2, 5 |
| Tier 2 in-process full stack | 12 |
| Tier 3 real XPC in one process | 13 |
| `XPCActorSystem` conformance | 11 |

Deliberately absent, per the spec: `Service`/`EphemeralService`, peer requirement enforcement, `BackpressureManager`, priority escalation (Phase C); `Direct`, `ServiceRegistry`, `protocolStub` (omitted permanently).

**Known ordering hazard.** Tasks 7, 9, and 11 reference each other's types, so the target does not build until all three land. Task 7 says to take `RemoteCallError` from Task 8 first; Tasks 9 and 11 must be implemented back to back. An implementer who hits a "cannot find type in scope" error in these three should check this note before concluding the plan is wrong.

**Type consistency.** `ExecuteThunk` is declared once, in Task 11, and used by Tasks 4 (generically, as `ActorRegistry<Thunk>`), 9, and 10. `SessionCoding` has exactly two methods across Tasks 3, 9, and 10. `ReplyBody.Err.Kind` values are pinned in Task 5 and consumed unchanged in 8, 9, and 11.
