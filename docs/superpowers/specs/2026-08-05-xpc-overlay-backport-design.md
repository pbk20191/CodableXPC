# XPCCompat — a backward-compatible Swift package port of Apple's `XPC` overlay

Date: 2026-08-05
Status: proposed, awaiting review
Revision: 2 — rewritten after reverse-engineering `xpcdump/libswiftXPC.m`

## Problem

Apple ships a Swift overlay for libxpc as the module `XPC` (`/usr/lib/swift/libswiftXPC.dylib`,
module-link-name `swiftXPC`, user-module-version 167.0.2). It provides typed wrappers — `XPCDictionary`,
`XPCArray`, `XPCSession`, `XPCListener`, `XPCReceivedMessage`, `XPCRichError` — over an untyped
`xpc_object_t` C API. Availability floors are high and uneven: containers at macOS 13, session/listener at
14, endpoint at 15, peer requirements at 26, literals and `RawSpan` subscripts at 27.

Code targeting macOS 10.15–12 gets none of it. This package provides equivalent API down to macOS 10.15.

## Evidence base

Three sources, all re-verified on this machine (macOS 27.0, build 26A5388g, Xcode-beta SDK 27.0):

- `XPC.swiftmodule/arm64e-apple-macos.swiftinterface` — 992 lines, the authoritative public API surface.
- `xpcdump/libswiftXPC.m` — 30,485 lines of Hex-Rays pseudocode. **This is a macOS 15.x-era build**
  (`XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT` and `xpc_listener_create_anonymous` present, no
  `XPCPeerRequirement`).
- `xpcdump/*.h` — RuntimeBrowser headers naming `TopLevelGraphEncodingNode`, `_KeyedGraphEncodingNode`,
  `UnkeyedGraphEncodingNode`, `SingleValueGraphEncodingNode`, `DecodedContainer`.

**The `.m` dump and the `.h` headers are from different generations of the dylib, and this matters.** The
current SDK's `libswiftXPC.tbd` exports `XPC.TopLevelGraphEncodingNode` metadata (8 mangled symbols,
demangled to confirm) and contains no `EncodingBuffer` / `_XPCKeyedEncodingContainer` symbols at all — while
the `.m` dump implements Codable entirely through `EncodingBuffer` and has zero occurrences of
`GraphEncodingNode`. See "Wire format" below for why this is the single most important finding in the
document.

## Decisions

### 1. Build on `xpc_connection_t`

The C session and listener APIs cannot be called from Swift. `xpc/base.h:69`:

```c
#define XPC_SWIFT_NOEXPORT XPC_SWIFT_UNAVAILABLE("Unavailable in Swift from the XPC C Module")
```

`xpc/session.h` applies it to 16 declarations, `xpc/listener.h` to 7. Apple's overlay works around this with
static C thunks named `swift_xpc_session_*` / `swift_xpc_listener_*` whose bodies are bare passthroughs.
Those thunks are local symbols, not exports: `libswiftXPC.tbd` exports 410 symbols, all Swift-mangled
`_$s3XPC…`, and `dlsym` returns NULL for every `swift_xpc_*` name both globally and against a loaded
`libswiftXPC.dylib` handle, while the underlying `xpc_session_set_incoming_message_handler` resolves.

Note this is a **behavioural divergence, not a reimplementation of the same thing**. Apple's `XPCSession` is
a 24-byte object holding exactly one `xpc_session_t` handle — no Swift-side state, no lock, no flags — and
it forwards double-activate and send-before-activate straight to libxpc, which traps. Ours holds an
`xpc_connection_t` plus lock-guarded state and throws `RichError` on misuse instead of trapping. That is a
deliberate improvement, and it must be documented as a difference rather than sold as parity.

All required C primitives are macOS 10.7 (`xpc_connection_create_mach_service`,
`send_message_with_reply`, `dictionary_create_reply`, `endpoint_create`, `create_from_endpoint`,
`shmem_create`, `fd_create`, `equal`, `hash`), except `xpc_connection_activate` at 10.12 — all below the
10.15 floor.

### 2. Codable wire format: reproduce Apple's envelope (coder version 1)

**Apple does not encode Codable into typed XPC containers.** It serializes the whole Codable graph into a
node-graph byte stream carried in a single `xpc_data`, inside an envelope. We reproduce it, so that
`XPCCompat` interoperates with peers using Apple's `XPCSession` Codable overloads.

The format below is **not** taken from the decompiled dump. It was measured directly on this machine
(macOS 27.0, build 26A5388g) by running Apple's real `XPCSession` against a plain C `xpc_connection`
listener and dumping the bytes that crossed the wire. The probe is committed at
`Tools/WireProbe/main.swift` and is the regression oracle for this decision.

This matters because the dump and the shipping binary disagree. The macOS 15-era dump implements an
`EncodingBuffer` TLV stream where keyed entries come out in Swift `Dictionary` hash order — per-process
seeded, so not even byte-stable run to run. The shipping macOS 26/27 build replaced that with the
`GraphEncodingNode` design the RuntimeBrowser headers name, and **that design emits keys in declaration
order**, which is what makes byte-exact reproduction achievable at all. Encoding against the dump would
have produced a format no current OS speaks.

#### Envelope

| key | type | value |
| --- | --- | --- |
| `_CodableBody` | `data` | the node-graph byte stream (below) |
| `_CodableCoderVersion` | `int64` | `1` on macOS 26/27; absent in the macOS 15 build |
| `_CodableIsSync` | `bool` | true when sent by `sendSync` |
| `_CodableOutOfLine` | `array` | large/opaque leaves referenced from the stream by index |
| `_CodableOutOfLine4CodableObject` | `array` | xpc-native handles (connections, endpoints, fds) |
| `_CodableError` | — | present only on the error-reply path |

`_CodableCoderVersion` is the compatibility lever: emit `1`, and refuse to decode a body whose version is
absent or greater than `1` rather than misparsing it.

#### Node graph

The payload is a flat sequence of nodes. The first node is the root; children are referenced by index and
appended after it.

```
node      := 0x13 kind body
kind      := 0x0a keyed | 0x0b unkeyed | 0x0c single-value
separator := 0x15                 ; between nodes, absent after the last
key       := 0x11 u64le(byteLen) utf8bytes 0x00      ; keyed nodes only
childref  := 0x14 u32le(index)    ; 0-based over the nodes following the root
```

Keyed nodes are a flat run of `key value` pairs; unkeyed nodes a run of values; single-value nodes exactly
one value. A value is either an inline primitive, a `childref`, or an out-of-line reference.

#### Value tags

| tag | type | payload | tag | type | payload |
| --- | --- | --- | --- | --- | --- |
| `0x00` | nil | none | `0x08` | `Int16` | 2 B LE |
| `0x01` | `Bool` true | none | `0x09` | `Int32` | 4 B LE |
| `0x02` | `Bool` false | none | `0x0a` | `Int64` | 8 B LE |
| `0x03` | `String` | u64le byteLen, utf8, `0x00` | `0x0b` | `UInt` | 8 B LE |
| `0x04` | `Float` | 4 B LE | `0x0c` | `UInt8` | 1 B |
| `0x05` | `Double` | 8 B LE | `0x0d` | `UInt16` | 2 B LE |
| `0x06` | `Int` | 8 B LE | `0x0e` | `UInt32` | 4 B LE |
| `0x07` | `Int8` | 1 B | `0x0f` | `UInt64` | 8 B LE |
| `0x12` | out-of-line | u32le index into `_CodableOutOfLine` | | | |

Details that a naive implementation gets wrong, each verified by probe:

- **`Int`, `Int64` and `UInt64` are distinct tags** (`0x06`, `0x0a`, `0x0f`) and never interconvert.
  Normalizing everything to int64 will fail to decode against Apple.
- **String length is UTF-8 *byte* count and excludes the trailing NUL.** `"é한"` encodes as
  `03 05 00000000 00000000 c3 a9 ed 95 9c 00`. The macOS 15 build used `count + 1`; this one does not.
- **`0x0a` is ambiguous by position** — keyed-node kind after `0x13`, `Int64` in a value slot.
- **`Data` always goes out-of-line**, at any size: a 3-byte `Data` and a 40-byte `Data` both encode as an
  unkeyed node holding `12 <u32 index>`, with the bytes in `_CodableOutOfLine`.
- **`Date` becomes a `Double`** of `timeIntervalSinceReferenceDate` (epoch 0 → `-978307200.0`), not an
  `xpc_date`. **`UUID` becomes a 36-character `String`.** Neither is special-cased — the overlay has no
  Foundation dependency, so both fall through to their stock `Codable` conformances.
- **A `nil` `Optional` property is omitted entirely**, because Swift's synthesized encoder calls
  `encodeIfPresent`. An explicit `encodeNil(forKey:)` does emit tag `0x00`.
- **The root node need not be keyed.** A top-level `Int` is `13 0c 06 …`; a top-level `[Int]` is
  `13 0b 14 … 15 …`.

`CodableXPC`'s existing `XPCEncoder`/`XPCDecoder`, which produce natural XPC containers, stay exactly as
they are and remain the package's other product. `XPCCompat` adds a second, separate coder for this
envelope. The two are not interchangeable and the README must say which is which.

### 3. `isSync` needs no SPI; `expectsReply` does

`XPCReceivedMessage.isSync` is not a C call — it reads a byte at metadata offset +17, populated from the
`_CodableIsSync` envelope key. It is a *protocol convention*, so adopting Apple's envelope gets it for free,
with no SPI. Absent key reads as `false`, so messages from non-Swift peers degrade cleanly.

Reproduce Apple's safety net too: when an incoming handler returns `nil` but the peer is blocked in
`sendSync`, Apple synthesizes an error reply under `_CodableError` so the peer does not hang.

`expectsReply` is the one place Apple uses a genuinely undeclared symbol. `xpc_dictionary_expects_reply` is
an exact export of libSystem (confirmed in `libSystem.B.tbd` and by `dlsym`) but appears in **no public
header**. `XPCCompat` uses the public `xpc_dictionary_get_remote_connection(msg) != nil` instead. If that
proves inaccurate in testing, the SPI is the documented fallback — but it is not the default.

### 4. Container semantics: match Apple exactly, with one fix

Reverse-engineering pinned down behaviour that a naive implementation would get wrong. `XPCCompat`
reproduces all of it:

- **Reference semantics, no COW.** `XPCDictionary`/`XPCArray` are structs wrapping one retained
  `xpc_object_t`; `isKnownUniquelyReferenced` appears nowhere in their accessors. `var a = dict; a["x"] = 1`
  mutates the original. Nested containers alias rather than copy. We must *not* add COW — `copy(into:)` is
  the provided escape hatch.
- **Numeric getters coerce, range-checked.** The `BinaryInteger` subscript reads int64, uint64 *and* double,
  converting with `init(exactly:)` — so it returns nil on overflow and on `1.5` read as `Int`, never
  truncates. Same shape for `BinaryFloatingPoint`.
- **`Bool` is strict** — only `XPC_TYPE_BOOL`; int64 `0`/`1` reads as nil.
- **Missing key and wrong type both return nil**, no trap. But `XPCDictionary.init(_:)` / `XPCArray.init(_:)`
  *do* trap on a wrong-typed object, and that is reachable from user code.
- **`default:` fires on missing key, wrong type, and failed conversion**, and the autoclosure is lazy.
- **Strings use `String(cString:)`** — copied, and ill-formed UTF-8 is repaired to U+FFFD rather than
  returning nil.
- **Equality and hashing are `xpc_equal` / `xpc_hash`** — structural, not pointer identity.
- **Untyped setters special-case connections**: `xpc_dictionary_set_connection` when
  `xpc_get_type(v) == XPC_TYPE_CONNECTION`, else `set_value`.

**The one intentional divergence.** Apple's nil-setter behaviour is inconsistent: assigning `nil` through
the `String?` subscript removes the key, but through `Bool?`, `BinaryInteger`, `BinaryFloatingPoint`,
`[UInt8]?` and the untyped object subscript it is a silent **no-op**. Separately, assigning a `UInt` greater
than `Int64.max` through the signed overload silently writes nothing. `XPCCompat` makes `nil` consistently
remove the key on every subscript, and makes an out-of-range integer assignment a precondition failure
rather than a silent drop. Both divergences are documented and covered by tests.

### 5. Namespace enum, no re-export

A caseless `public enum XPCCompat {}` holds every type: `XPCCompat.Session`, `XPCCompat.Dictionary`. The
module does **not** `@_exported import XPC`, so `import XPC` and `import XPCCompat` coexist in one file.
Drop-in source compatibility is opt-in, one `typealias` per type in the caller's own file.

Shadowing was compile-tested, and the hazard is narrower and stranger than expected. Inside a file-scope
`extension XPCCompat.Dictionary`, bare `Array()` resolves to `Swift.Array` — extensions do not inherit the
enclosing type's scope. But inside the nested body (`enum XPCCompat { struct Dictionary { … } }`),
`XPCCompat.Array` wins, and `let x = Array()` **compiles clean while producing the wrong type**; only
`Array(repeating:count:)` errors. Silent-wrong is the dangerous case.

Rule: each type declares only its stored property and initializers inside the enum body; every other member
goes in a file-scope `extension XPCCompat.X` block. This is also exactly how Apple's own interface is laid
out — `struct XPCArray` has two inits and one method, with fifteen separate extension blocks.

### 6. Package layout

`CodableXPC` ships unchanged as its own product. A new `XPCCompat` target depends on it.

```
Sources/
  CodableXPC/     XPCEncoder  XPCDecoder  XPCTransform  XPCCodingKey  XPCFileDescriptorProtocol
  XPCCompat/      Namespace  Dictionary  Array  LiteralValue  Endpoint
                  SharedMemory  Activity  FileDescriptor  RichError
                  Session  Listener  ReceivedMessage  PeerRequirement  PeerHandler  Bridge
                  Coder/  GraphEncoder  GraphDecoder  Envelope  OutOfLineTable  WireTag
Tools/
  WireProbe/      main.swift        # measures Apple's real output; oracle for test 4

products: [.library("CodableXPC"), .library("XPCCompat")]
```

### 7. Availability floor

Supported floor macOS 10.15 / iOS 13 / tvOS 13 / watchOS 6 / macCatalyst 13.1. `platforms:` in
`Package.swift` is package-wide, so it stays at `.macOS(.v10_13)` rather than being raised — raising it
would force existing `CodableXPC` adopters up for a target they may not use. Every public `XPCCompat`
declaration instead carries `@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)`.
`System.FileDescriptor` subscripts are gated to macOS 11 / iOS 14, matching swift-system.

## Architecture

### Layer 1 — Values

Structs wrapping one retained `xpc_object_t`: `Dictionary`, `Array`, `LiteralValue`, `Endpoint`,
`SharedMemory`, `Activity`, `FileDescriptor`. Full typed-subscript matrix from the overlay (`Bool`,
`BinaryInteger`, `SignedInteger`, `UnsignedInteger`, `BinaryFloatingPoint`, `String`, `uuid_t`,
`FileDescriptor`, nested containers, `Endpoint`, raw `xpc_object_t`, lookup by `xpc_type_t`), each in its
`as type:`, plain, and `default:` forms. Plus `copy(into:)`, `isEmpty`, `count`, both `forEach` shapes,
`map`, and on `Dictionary` also `removeValue(forKey:)`, `keys`, `values`, `reply(_:)`.

`SharedMemory` and `Activity` are typed values only — they round-trip through containers, Codable and
`debugDescription`, but callers drive `xpc_shmem_map` / `xpc_activity_register` themselves.

The macOS 27 `RawSpan` subscripts are not backported; `RawSpan` and `@_lifetime` need a toolchain and OS we
do not target. Substitute: a `Data` subscript plus `withUnsafeBytes(forKey:_:)`.

### Layer 2 — Transport

`Session`, `Listener`, `ReceivedMessage`, `RichError`, `PeerRequirement`, `XPCPeerHandler`, over
`xpc_connection_t`.

`Session` owns a connection plus lock-guarded state (`inactive → active → cancelled`), throwing on misuse.
Initializers mirror the overlay: `xpcService:`, `machService:`, `endpoint:`, in four handler flavors.
Auto-activate unless `.inactive` is passed, matching Apple.

`Listener` wraps `xpc_connection_create_mach_service` with `XPC_CONNECTION_MACH_SERVICE_LISTENER`, and
`xpc_connection_create(nil, queue)` for the anonymous case behind `endpoint`. `IncomingSessionRequest`
carries the tri-state accept/reject/undecided byte and traps on re-decision, as Apple does.

`ReceivedMessage` holds the incoming object and its reply connection, and replies via the public
`xpc_dictionary_create_reply` + `xpc_connection_send_message`. Apple uses the private
`xpc_dictionary_send_reply_4SWIFT`, which derives reply context from the message alone; ours must capture
the connection from the event handler, which is a structural difference with no user-visible effect.

`RichError` is a value struct `(canRetry: Bool, description: String)` snapshotted at construction — matching
Apple's layout exactly (24 bytes, `canRetry` a stored byte, no `xpc_rich_error_t` retained). Apple populates
it from `xpc_rich_error_can_retry`, but rich errors only ever arrive through the session C layer we are not
using. We receive `XPC_TYPE_ERROR` objects on the connection event handler and synthesize:
`XPC_ERROR_CONNECTION_INTERRUPTED → canRetry: true`; `XPC_ERROR_CONNECTION_INVALID` and
`XPC_ERROR_TERMINATION_IMMINENT → false`. **Apple's Swift code contains no such translation** — the C
session layer does it before Swift sees anything — so this mapping is ours and needs its own tests.

### Layer 3 — Codable

A new `EnvelopeCoder` implementing the node-graph format in decision 2: `GraphEncoder` / `GraphDecoder`
producing and consuming the `_CodableBody` byte stream, an out-of-line table manager for `Data` and
xpc-native handles, and the envelope assembly around them. `Session.send<Message: Encodable>`,
`sendSync<Message, Reply>` and `ReceivedMessage.decode(as:)` go through this.

This is the largest single piece of new code in the package, and unlike everything else it is validated
against an external oracle rather than against itself — see test 4.

`CodableXPC.XPCEncoder` / `XPCDecoder` are untouched and keep producing natural XPC containers for callers
who want that instead. Two coders, two purposes, both documented.

### Bridge — interop with the real overlay, SPI-free

On OSes where Apple's overlay exists, `XPCCompat` can hand off at the endpoint boundary using only public
API. `xpc_endpoint_create` and `xpc_connection_create_from_endpoint` are both macOS 10.7 public C, and
`XPCEndpoint` exposes both a public `init(_ endpoint: xpc_endpoint_t)` and a public `_endpoint` getter.

```
XPCCompat.Listener → xpc_endpoint_create(conn) → XPC.XPCEndpoint(_:) → XPC.XPCSession(endpoint:)
XPC.XPCListener.endpoint._endpoint → xpc_connection_create_from_endpoint → XPCCompat.Session
```

This makes the private `_xpc_session_{create_from,extract}_connection_4SWIFT` pair unnecessary. Those were
investigated: both are real libxpc exports that resolve via `dlsym`, and disassembly gives
`xpc_connection_t _xpc_session_extract_connection_4SWIFT(xpc_session_t)` and
`xpc_session_t _xpc_session_create_from_connection_4SWIFT(xpc_connection_t, dispatch_queue_t _Nullable, xpc_session_create_flags_t, xpc_rich_error_t *)`.
They are rejected on two grounds: they are undeclared SPI, and they only exist where `xpc_session_t` does
(macOS 13+), which is exactly where a caller could use Apple's overlay directly. They buy nothing a
backport needs.

Because decision 2 adopts Apple's envelope, the bridge carries Codable payloads too, not just raw
dictionaries — a `XPCCompat.Session` on one end and an `XPC.XPCSession` on the other can exchange typed
values in both directions. Test 10 asserts exactly that.

#### NSXPCConnection

A third bridge exists, to the older Foundation API. `NSXPCConnection` has a private ObjC method
`-_xpcConnection`, verified present and working on macOS 27:

```
type encoding: @16@0:8
returns:       OS_xpc_connection, xpc_get_type() == XPC_TYPE_CONNECTION
```

Because `XPCCompat.Session` is built on `xpc_connection_t`, this would allow
`XPCCompat.Session(nsxpcConnection:)` — letting a codebase already using `NSXPCConnection` adopt typed
messaging incrementally without replacing its transport.

It is private API, so it is **not** part of the committed scope. It is recorded here as a viable Phase 5
option, gated on the same question as `PeerRequirement`: whether this package is willing to ship private
API at all. If the answer there is no, this stays a documented recipe in the README rather than shipped
code. Note the asymmetry — the `XPCEndpoint` bridge above needs no SPI, so it ships regardless.

## Testing

1. **Value round-trip** — every XPC type through both container types, both subscript forms, `default:` on
   missing key.
2. **Semantics conformance** — the specific behaviours in decision 4: reference-semantics aliasing,
   `init(exactly:)` overflow returning nil, `Bool` strictness, `default:` firing on wrong type, U+FFFD
   repair, `xpc_equal`-based equality.
3. **Divergence tests** — nil-assignment removes on every subscript; out-of-range integer assignment traps.
   These assert our *intended difference* from Apple, so they must not be written as parity tests.
4. **Wire-format parity, byte for byte** — the load-bearing test for decision 2, and the reason
   `Tools/WireProbe` is committed. Gated `@available(macOS 26, *)`, since coder version 1 is what we
   implement. For a table of payloads covering every tag — each integer width, `Bool` both ways, empty and
   non-ASCII `String`, nested and empty containers, explicit nil, `Data`, `Date`, `UUID`, and a non-keyed
   root — encode through `XPCCompat` and through Apple's real `XPCSession`, then assert the `_CodableBody`
   bytes are **identical**, not merely equivalent. Also assert `_CodableCoderVersion == 1` and that the
   out-of-line arrays line up. Byte-exactness is only achievable because macOS 26/27 emits keys in
   declaration order; if a future OS bumps the version, this test is what will catch it.
   Round-trip the other direction too: decode Apple-produced bytes with our decoder.
5. **Live IPC** — anonymous `Listener` plus `Session` over its `endpoint`, in-process, no launchd job.
   Covers send, sendSync, reply, reject, cancellation.
6. **Sync safety net** — handler returns `nil` while peer is in `sendSync`; assert the peer gets an error
   rather than hanging.
7. **File descriptor passing** — send a pipe read end, write on the other end, assert bytes arrive.
8. **Shared memory** — create, write, send, map on receipt, assert contents.
9. **State-machine misuse** — double activate, send before activate, send after cancel: all throw.
10. **Endpoint bridge** — gated macOS 15+, `XPCCompat.Listener` accepting a connection from Apple's
    `XPCSession(endpoint:)` and vice versa.
11. **Shadowing lint** — no unqualified `Array(` / `Dictionary(` inside `Sources/XPCCompat`.

## Delivery order

1. **Values** — namespace, containers, subscript matrix, conformances. Tests 1, 2, 3, 11.
2. **Envelope coder** — the node-graph encoder and decoder, out-of-line tables, envelope assembly, and
   test 4 against the real overlay. Deliberately placed second and verified in isolation, before any
   transport code exists to confuse a failure: the oracle needs only two byte strings, not a live session.
3. **Transport** — `RichError`, `Session`, `Listener`, `ReceivedMessage`, `XPCPeerHandler`. Tests 5, 6, 9.
4. **Descriptor and memory passing** — `SharedMemory`, `Activity`, FD/shmem subscripts. Tests 7, 8.
5. **Bridge** — endpoint interop, including typed payloads across the boundary. Test 10.
6. **Peer requirements** — the spike below, then `PeerRequirement` or its `.unsupported` fallback.

Phase 1 gates everything. Phases 2 and 4 are independent of each other. Phase 3 depends on 2 (its
`send<Encodable>` overloads need the coder). Phases 5 and 6 depend on 3.

## Open items

1. **`PeerRequirement` below macOS 26.** The dump cannot help — it predates the API. The only candidate
   route is SPI: `xpc_connection_copy_entitlement_value` and `xpc_connection_get_audit_token` are exact
   libSystem exports with no public header declaration. Spike required. Documented fallback if rejected or
   unworkable: below macOS 26, `senderSatisfies` returns `false` and `setPeerRequirement` throws
   `.unsupported` — failing closed on a security boundary rather than admitting an unverified peer.
2. **`forEach` early-exit on throw.** Apple captures the error in a stack box and rethrows after
   `xpc_dictionary_apply` returns; whether the applier returns `false` to stop iteration could not be
   determined, as Hex-Rays did not model the `swifterror` register. `XPCCompat` stops iteration on throw,
   which is the behaviour Swift users expect; verify against the real overlay in test 4.
3. **Dictionary iteration order.** Determined by libxpc's `xpc_dictionary_apply`, not by the overlay.
   `keys` and `values` are consistent with each other because both derive from `forEach`. Document as
   unspecified; do not test for a specific order.
4. **`Activity` as a container value.** `XPC_TYPE_ACTIVITY` objects are delivered to activity handlers and
   are not known to appear inside messages. Confirm whether the container subscript is meaningful.
5. **`_CodableOutOfLine4CodableObject` contents.** Every probe so far produced an empty array, because no
   payload carried an xpc-native handle. Before implementing the out-of-line table, extend
   `Tools/WireProbe` with a type conforming to `XPCCodableObjectRepresentable` — the protocol is exported
   (`validXPCObjectTypes: Set<OpaquePointer>`, `init?(from: XPCCodable)`, `var xpcCodable: XPCCodable`) —
   and measure how handles are indexed and whether connections use a distinct path, as the macOS 15 dump's
   `xpc_array_set_connection` special case suggests.
6. **Coder version drift.** We pin to version 1. Add a CI check that runs `Tools/WireProbe` on the newest
   available OS and fails if `_CodableCoderVersion` is no longer `1`, so a format change is caught by us
   rather than by a user's broken IPC.

## Explicitly out of scope

- The macOS 15-era `EncodingBuffer` TLV format. We implement coder version 1 (macOS 26/27) only. A peer on
  macOS 14–15 sends a body with no `_CodableCoderVersion` key and a different stream layout; we reject it
  with a clear error rather than misparsing. Supporting it would mean a second encoder whose key order is
  unreproducible by construction.
- RAII shared-memory mapping and a typed activity-criteria builder.
- `RawSpan` subscripts.
- Re-exporting or shimming the `XPC` module.
- Any use of `swift_xpc_*` thunks (not linkable) or `_4SWIFT` SPI (unnecessary — see Bridge).
