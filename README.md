# CodableXPC

Transform plain Codable swift type to xpc_object and vice versa.

## Products

| product | what it is | minimum OS |
| --- | --- | --- |
| `CodableXPC` | `XPCEncoder` / `XPCDecoder`, mapping `Codable` types to natural XPC containers | macOS 10.13 |
| `CodableXPCSystem` | adds the `System.FileDescriptor: XPCFileDescriptorProtocol` conformance | macOS 11 / iOS 14 / tvOS 14 / watchOS 7 |
| `XPCCompat` | a backport of Apple's `XPC` Swift overlay value layer | macOS 10.15 / iOS 13 / tvOS 13 / watchOS 6 |
| `XPCCompatSystem` | adds the `System.FileDescriptor` container subscripts to `XPCCompat` | macOS 11 / iOS 14 / tvOS 14 / watchOS 7 |

## XPCCompat

Apple ships a Swift overlay for libxpc as the module `XPC`, giving typed wrappers —
`XPCDictionary`, `XPCArray` and friends — over the untyped `xpc_object_t` C API. Its
availability floors are high: containers at macOS 13, endpoint at 15, literals at 27.
Code targeting anything older gets none of it.

`XPCCompat` provides the equivalent value layer down to **macOS 10.15 / iOS 13 /
tvOS 13 / watchOS 6 / macCatalyst 13.1**: `XPCCompat.Dictionary`, `XPCCompat.Array`,
`XPCCompat.Endpoint`, `XPCCompat.SharedMemory` and the full typed-subscript matrix
(`Bool`, every `BinaryInteger` and `BinaryFloatingPoint` width, `String`, `Data`,
`uuid_t`, nested containers, endpoints, shared memory, and raw `xpc_object_t`
including lookup by `xpc_type_t`).

The module deliberately does **not** re-export `XPC`, so `import XPC` and
`import XPCCompat` can coexist in one file. For drop-in source compatibility, alias
the types yourself:

```swift
typealias XPCDictionary = XPCCompat.Dictionary
typealias XPCArray = XPCCompat.Array
```

### That floor is real, and it is why the `System` products are separate

`import System` puts a hard `LC_LOAD_DYLIB` on `/usr/lib/swift/libswiftSystem.dylib`
into the consumer's binary. That dylib first shipped in macOS 11 and is in no Swift
back-deployment set, and `@available` gates compilation rather than the load command —
so a binary that links it is killed by dyld on macOS 10.15 before any code runs.

`CodableXPC` and `XPCCompat` therefore never `import System`. Everything needing
`System.FileDescriptor` lives in `CodableXPCSystem` / `XPCCompatSystem`. Depend on
those only if your own floor is already macOS 11 or later.

### Two deliberate divergences from Apple

`XPCCompat` matches Apple's semantics — including the ones a naive port gets wrong:
numeric getters coerce across int64/uint64/double but are range-checked with
`init(exactly:)` and never truncate, `Bool` is strict (an int64 `0`/`1` reads as `nil`),
`default:` fires on missing key *and* wrong type *and* failed conversion, strings are
repaired with U+FFFD rather than returning `nil`, and equality and hashing are
structural via `xpc_equal` / `xpc_hash`.

Two behaviours differ on purpose:

1. **Assigning `nil` always removes the key.** Apple is inconsistent here: `nil` through
   the `String?` subscript removes the key, but through `Bool?`, `BinaryInteger`,
   `BinaryFloatingPoint` and the untyped object subscript it is a silent no-op. We make
   removal uniform.
2. **An out-of-range integer assignment traps.** Apple silently writes nothing when you
   assign a `UInt` greater than `Int64.max` through the signed overload. We raise a
   `preconditionFailure` rather than dropping the value.

There is no way to remove an element from an `XPCCompat.Array`, so assigning `nil`
through *any* array subscript is a `preconditionFailure`, not a no-op:

```swift
var a = XPCCompat.Array(existingArrayObject)
a[0] = someOptionalString   // crashes if someOptionalString is nil
```

An untyped integer literal is ambiguous on assignment, because it fits both the
`SignedInteger` and the `UnsignedInteger` setter. This is inherent to matching Apple's
overload shape. Say which you mean:

```swift
d["n"] = 42        // does not compile
d["n"] = Int(42)   // xpc_int64
d["n"] = UInt(42)  // xpc_uint64
```

### Reference semantics — no copy-on-write

> **Warning**
> `XPCCompat.Dictionary` and `XPCCompat.Array` are structs, but they have **reference
> semantics**. They wrap one retained `xpc_object_t`, and there is no copy-on-write.
> Assigning one to a new variable does not copy anything, and mutating the "copy" is
> visible through the original. Nested containers alias rather than copy too.

This matches Apple's overlay exactly and is not a bug, but it will surprise anyone who
reads `struct` and expects value semantics:

```swift
var a = XPCCompat.Dictionary()
var b = a
b["x"] = Int(1)
a.count            // 1 — not 0
```

`copy(into:)` is the escape hatch:

```swift
let independent = XPCCompat.Dictionary()
original.copy(into: independent)
```

It is a **shallow** copy: top-level entries are copied, but the values themselves are
shared, so a nested child is still the same object on both sides.

### File descriptor ownership

The `FileDescriptor` subscripts are in `XPCCompatSystem` (macOS 11+).

Reading a descriptor out of a container returns a **duplicate that the caller owns and
must close**. It is a different descriptor number from the one that was written, backed
by `xpc_dictionary_dup_fd` / `xpc_array_dup_fd`. Failing to close it leaks a descriptor:

```swift
import XPCCompat
import XPCCompatSystem
import System

if let received = message["fd", as: FileDescriptor.self] {
    defer { try? received.close() }
    // ... use it ...
}
```

Writing is symmetric: `xpc_dictionary_set_fd` duplicates the descriptor you hand it, so
you keep ownership of the original and remain responsible for closing that.

### Shared memory

`XPCCompat.SharedMemory(byteCount:)` allocates a shareable `mmap`ed region and unmaps it
on deinit. Fill it in through the scoped accessor:

```swift
let memory = XPCCompat.SharedMemory(byteCount: 4096)!
memory.withUnsafeMutableBytes { buffer in
    buffer.copyBytes(from: payload)
}
```

`withUnsafeMutableBytes` returns `nil` without running the body on an instance built
with `init(_:)`, which wraps someone else's object and owns no region. To reach that
region, map it yourself with `xpc_shmem_map(memory.underlying, …)`.

### Two coders, two purposes

`CodableXPC`'s `XPCEncoder` / `XPCDecoder` map `Codable` types onto natural XPC
containers — a struct becomes an `xpc_dictionary` with one key per property. That is
this package's original feature and is unchanged.

`XPCCompat` is about the container *value layer* itself. A separate coder reproducing
Apple's own Codable-over-XPC envelope is planned for a later phase; the two formats are
not interchangeable.
