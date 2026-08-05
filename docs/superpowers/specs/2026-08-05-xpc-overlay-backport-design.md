# XPCCompat — a backward-compatible Swift package port of Apple's `XPC` overlay

Date: 2026-08-05
Status: proposed, awaiting review

## Problem

Apple ships a Swift overlay for libxpc as the module `XPC` (binary `/usr/lib/swift/libswiftXPC.dylib`,
module-link-name `swiftXPC`, user-module-version 167.0.2). It provides typed, memory-safe wrappers —
`XPCDictionary`, `XPCArray`, `XPCSession`, `XPCListener`, `XPCReceivedMessage`, `XPCRichError` — over an
otherwise untyped `xpc_object_t` C API.

Its availability floors are high and uneven:

| Type | Floor |
| --- | --- |
| `XPCDictionary`, `XPCArray` | macOS 13.0 |
| `XPCSession`, `XPCReceivedMessage`, `XPCRichError` | macOS 14.0 |
| `XPCListener` | macOS 14.0 |
| `XPCEndpoint` | macOS 15.0 |
| `XPCPeerRequirement` | macOS 26.0 |
| `XPCLiteralValue`, `RawSpan` subscripts, `uuid_t`/`FileDescriptor` array subscripts | macOS 27.0 |

Code targeting macOS 10.15–12 gets none of it and must hand-roll `xpc_object_t` plumbing. This package
provides equivalent API down to macOS 10.15.

## Scope

Full parity with the overlay's public surface, plus typed value support for the four XPC object types the
overlay does not wrap at all: `XPC_TYPE_SHMEM`, `XPC_TYPE_ACTIVITY`, `XPC_TYPE_FD`, `XPC_TYPE_RICH_ERROR`.

Shared memory and activity are **typed values only** — they round-trip through containers, Codable, and
`debugDescription`, but callers drive `xpc_shmem_map` / `xpc_activity_register` themselves. No RAII mapping
wrapper, no criteria builder.

## Decisions

### 1. Build on `xpc_connection_t`, never on `xpc_session_*`

The C session and listener APIs cannot be called from Swift at all. `xpc/base.h:69`:

```c
#define XPC_SWIFT_NOEXPORT XPC_SWIFT_UNAVAILABLE("Unavailable in Swift from the XPC C Module")
```

`xpc/session.h` applies it to 16 declarations, `xpc/listener.h` to 7. Apple's overlay works around this with
static C thunks named `swift_xpc_session_*` / `swift_xpc_listener_*`, whose bodies are bare passthroughs.
Those thunks are **local symbols, not exports**:

- `libswiftXPC.tbd` exports 410 symbols, all Swift-mangled `_$s3XPC…`; no `swift_xpc_*` appears.
- `dlsym(RTLD_DEFAULT, "swift_xpc_session_set_incoming_message_handler")` → NULL.
- `dlsym(<libswiftXPC handle>, …)` → NULL, while `dlsym(…, "xpc_session_set_incoming_message_handler")`
  resolves to a real address.

So there is no "fast path on macOS 13+" available to us, and adding a C shim target to reach a 13.0+ API we
would still need a fallback from buys nothing. Everything is implemented once, on `xpc_connection_t`
(public and Swift-visible since macOS 10.7). One code path, uniform behavior across every supported OS,
one thing to test.

### 2. Namespace enum, no re-export

A caseless `public enum XPCCompat {}` holds every type. Callers write `XPCCompat.Session`,
`XPCCompat.Dictionary`. The module does **not** `@_exported import XPC`, so `import XPC` and
`import XPCCompat` coexist in one file with no ambiguity. Drop-in source compatibility is opt-in, one line
per type in the caller's own file:

```swift
typealias XPCSession = XPCCompat.Session
```

Hazard: inside the module, `XPCCompat.Dictionary` and `XPCCompat.Array` shadow `Swift.Dictionary` and
`Swift.Array` within their own nested scope. Array/dictionary *sugar* (`[String]`, `[String: Int]`) is
unaffected, but bare initializers are. Rule for the module: always spell `Swift.Array(…)` /
`Swift.Dictionary(…)` explicitly. Enforced by a test that greps the sources for unqualified use.

### 3. Package layout

`CodableXPC` ships unchanged as its own product. A new `XPCCompat` target depends on it for all Codable
bridging — `XPCEncoder`/`XPCDecoder` already do exactly what the overlay's Codable overloads need.

```
Sources/
  CodableXPC/     XPCEncoder  XPCDecoder  XPCTransform  XPCCodingKey  XPCFileDescriptorProtocol
  XPCCompat/      Namespace  Dictionary  Array  LiteralValue  Endpoint
                  SharedMemory  Activity  FileDescriptor  RichError
                  Session  Listener  ReceivedMessage  PeerRequirement  PeerHandler

products: [.library("CodableXPC"), .library("XPCCompat")]
```

### 4. Availability floor

Supported floor is macOS 10.15 / iOS 13 / tvOS 13 / watchOS 6 / macCatalyst 13.1.

`platforms:` in `Package.swift` is package-wide, so it stays at the current `.macOS(.v10_13)` rather than
being raised — raising it would force existing `CodableXPC` adopters up two releases for a target they may
not use. Instead every public `XPCCompat` declaration carries
`@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)`.

Narrower gates within the module:

- `System.FileDescriptor` subscripts → `@available(macOS 11, iOS 14, *)`, matching swift-system.
- `xpc_type_get_name` → 10.15+; `XPCTransform.swift` already carries the manual fallback switch.

## Architecture

Three layers, each usable without the one above it.

### Layer 1 — Values

Structs wrapping a single retained `xpc_object_t`: `Dictionary`, `Array`, `LiteralValue`, `Endpoint`,
`SharedMemory`, `Activity`, `FileDescriptor`.

`Dictionary` and `Array` carry the full typed-subscript matrix from the overlay: `Bool`, `BinaryInteger`,
`SignedInteger`, `UnsignedInteger`, `BinaryFloatingPoint`, `String`, `uuid_t`, `FileDescriptor`, nested
`Dictionary`/`Array`, `Endpoint`, raw `xpc_object_t`, and lookup by `xpc_type_t` — each in its
`get`-only `as type:`, its `get`/`set`, and where the overlay has one, its `default:` form. Plus
`copy(into:)`, `isEmpty`, `count`, both `forEach` shapes, `map`, and on `Dictionary`,
`removeValue(forKey:)`, `keys`, `values`, `reply(_:)`.

Conformances: `Equatable` via `xpc_equal`, `Hashable` via `xpc_hash`, `CustomDebugStringConvertible` via
`xpc_copy_description`, and `ExpressibleByDictionaryLiteral` through `LiteralValue`.

The overlay's macOS 27 `RawSpan` subscripts are **not** backported — `RawSpan` and `@_lifetime` need a
toolchain and OS we do not target. Substitute: a `Data` subscript, plus
`withUnsafeBytes(forKey:_:)` for the zero-copy case. This is the one intentional source-compatibility break;
it is documented in the README.

### Layer 2 — Transport

`Session`, `Listener`, `ReceivedMessage`, `RichError`, `PeerRequirement`, and the `XPCPeerHandler` protocol,
all over `xpc_connection_t`.

`Session` owns a connection plus a lock-guarded state (`inactive → active → cancelled`). The C API traps on
double-activate and on send-before-activate; `Session` checks state and throws `RichError` instead of
crashing. Initializers mirror the overlay: `xpcService:`, `machService:`, `endpoint:`, each in four handler
flavors (none, `Dictionary`, generic `Decodable`, `ReceivedMessage`). Send methods mirror
`send(message:)`, `send<Message: Encodable>`, `sendSync(message:)`, the two generic `sendSync` forms, and
the three `send(_:replyHandler:)` forms.

`Listener` wraps `xpc_connection_create_mach_service` with `XPC_CONNECTION_MACH_SERVICE_LISTENER`, and
`xpc_connection_create(nil, queue)` for the anonymous case that backs `endpoint`. `IncomingSessionRequest`
and its `Decision` reproduce the accept/reject protocol; `reject(reason:)` cancels the peer connection.

`ReceivedMessage` holds the incoming object and its reply connection. `expectsReply` is
`xpc_dictionary_get_remote_connection(msg) != nil`. `decode(as:)`, `reply(_:)`, and
`handoffReply(to:_:)` behave as documented.

`RichError` is our own struct conforming to `Error`, `Sendable`, `CustomDebugStringConvertible`, with the
overlay's `canRetry`. On macOS 14+ it wraps a real `xpc_rich_error_t` when one is available; otherwise it is
synthesized from the XPC error object, mapping `XPC_ERROR_CONNECTION_INTERRUPTED` to `canRetry == true` and
`XPC_ERROR_CONNECTION_INVALID` / `XPC_ERROR_TERMINATION_IMMINENT` to `false`.

### Layer 3 — Codable

No new machinery. `Session.send<Message: Encodable>`, `sendSync<Message, Reply>`, and
`ReceivedMessage.decode(as:)` call `CodableXPC.XPCEncoder` / `XPCDecoder` directly.

## Testing

1. **Value round-trip** — every XPC type in and out of `Dictionary` and `Array` through both the typed and
   the `as type:` subscripts, including the `default:` forms on a missing key.
2. **Parity against the real overlay** — gated `@available(macOS 14, *)`, build the same message through
   Apple's `XPC` and through `XPCCompat`, assert `xpc_equal` on the resulting wire objects. This is the test
   that makes "backward compatible" a checked claim rather than an assertion, and it is possible precisely
   because we do not re-export `XPC`, so both type sets are nameable in one file.
3. **Live IPC** — an anonymous `Listener` plus a `Session` over its `endpoint`, in-process, no installed
   launchd job. Covers `send`, `sendSync`, `send(_:replyHandler:)`, reject, and cancellation.
4. **File descriptor passing** — send the read end of a `pipe(2)`, write on the other end, assert the bytes
   arrive across the connection.
5. **Shared memory** — create, write, send, map on receipt, assert contents, unmap.
6. **State-machine misuse** — double `activate()`, send before activate, send after `cancel()` each throw
   rather than trap.
7. **Shadowing lint** — assert no unqualified `Array(` / `Dictionary(` in `Sources/XPCCompat`.

## Open items to resolve during implementation

1. **`PeerRequirement` below macOS 26.** No `xpc_peer_requirement` API exists. Needs a spike to determine
   whether `xpc_connection_copy_entitlement_value` is public and sufficient for the entitlement predicates,
   and whether team/platform identity can be checked via audit token plus Security.framework without SPI.
   Documented fallback if the spike fails: below macOS 26, `senderSatisfies` returns `false` and
   `setPeerRequirement` throws `.unsupported`, rather than silently admitting an unverified peer.
2. **`ReceivedMessage.isSync`.** No public C predicate distinguishes a synchronous send. Ship it returning
   `false` with a doc comment stating the limitation, unless the spike in (1) surfaces a public route.
3. **`Activity` as a container value.** `XPC_TYPE_ACTIVITY` objects are delivered to activity handlers and
   are not known to appear inside messages. Confirm whether the container subscript is meaningful or whether
   `Activity` should only be constructible from a handler callback.

## Delivery order

The surface is too large for one undifferentiated pass. Four phases, each independently shippable and each
leaving the package green:

1. **Values.** Namespace, `Dictionary`, `Array`, `LiteralValue`, `Endpoint`, `FileDescriptor`, conformances,
   the full subscript matrix. Tests 1, 2, 7. This alone already replaces most hand-rolled `xpc_object_t`
   code and is the lowest-risk piece.
2. **Transport.** `RichError`, `Session`, `Listener`, `ReceivedMessage`, `XPCPeerHandler`. Tests 3, 6.
3. **Descriptor and memory passing.** `SharedMemory`, `Activity`, and the FD/shmem container subscripts.
   Tests 4, 5.
4. **Peer requirements.** The spike from open item (1), then `PeerRequirement` or its documented
   `.unsupported` fallback.

Phase 1 is a prerequisite for all others. Phases 2 and 3 are independent of each other. Phase 4 depends on 2.

## Explicitly out of scope

- RAII shared-memory mapping and a typed activity-criteria builder (per scoping decision — typed values only).
- `RawSpan` subscripts.
- Re-exporting or shimming the `XPC` module.
- Any use of `swift_xpc_*` thunks; they are not linkable.
