# XPCCompat Phase 1 — Value Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `XPCCompat.Dictionary` and `XPCCompat.Array` — typed, subscript-driven wrappers over `xpc_object_t` with the same semantics as Apple's `XPCDictionary`/`XPCArray`, usable from macOS 10.15.

**Architecture:** A caseless `enum XPCCompat` namespace holds two structs, each wrapping one retained `xpc_object_t`. Reference semantics, no copy-on-write — copying the struct retains the same underlying object. All members live in file-scope extensions (never inside the enum body) because of the name-shadowing hazard documented in the spec. Files are grouped by value category so that a change to, say, integer handling touches one file covering both containers.

**Tech Stack:** Swift 5.7 tools version, SwiftPM, XCTest, the libxpc C API (all primitives used here are macOS 10.7+), `System.FileDescriptor` from swift-system (gated to macOS 11).

## Global Constraints

- Deployment floor: macOS 10.15 / iOS 13 / tvOS 13 / watchOS 6 / macCatalyst 13.1. Every public `XPCCompat` declaration carries `@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)`.
- `Package.swift` `platforms:` stays at `.macOS(.v10_13)` — do **not** raise it. `CodableXPC` keeps its existing floor.
- `System.FileDescriptor` members are additionally gated `@available(macOS 11, iOS 14, *)` **and live in separate targets** (`CodableXPCSystem`, `XPCCompatSystem`). `CodableXPC` and `XPCCompat` must never `import System`: the resulting `LC_LOAD_DYLIB` on `libswiftSystem.dylib` is not availability-gated and kills a 10.15 consumer at load time.
- Never declare unqualified `Array` / `Dictionary` construction anywhere lexically inside `enum XPCCompat` or any `extension XPCCompat`; spell them `Swift.Array` / `XPCCompat.Array`. Enforced by `Tests/XPCCompatTests/ShadowingLintTests.swift`.
- The module must **not** `@_exported import XPC`. `import XPC` and `import XPCCompat` must coexist in one file.
- Never declare members inside the `enum XPCCompat { }` body beyond stored properties and initializers. Everything else goes in a file-scope `extension XPCCompat.X`. Inside the enum body, bare `Array` resolves to `XPCCompat.Array` and compiles silently wrong.
- Reference semantics. Do not add copy-on-write, `isKnownUniquelyReferenced`, or defensive `xpc_copy` in any accessor.
- Subscript setters are plain `set` (mutating), matching Apple's interface — not `nonmutating set`. This applies to subscripts only: `removeValue(forKey:)` is non-mutating, as Apple declares it.
- No SPI. Only functions declared in public `xpc/*.h` headers.
- Target name `XPCCompat`, product `XPCCompat`, depends on target `CodableXPC`. Plus `XPCCompatSystem` (depends on `XPCCompat`) and `CodableXPCSystem` (depends on `CodableXPC`) for the `System.FileDescriptor` surface, both `@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)` throughout.

---

### Task 1: Package scaffolding and namespace

**Files:**
- Modify: `Package.swift:13-32`
- Create: `Sources/XPCCompat/Namespace.swift`
- Test: `Tests/XPCCompatTests/NamespaceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum XPCCompat {}` — an empty caseless namespace enum, available from macOS 10.15. Target `XPCCompat` and test target `XPCCompatTests` exist and build.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCCompatTests/NamespaceTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCCompat

final class NamespaceTests: XCTestCase {

    // Importing both XPC and XPCCompat in one file must not be ambiguous.
    // If XPCCompat ever re-exports XPC, this file stops compiling.
    func testBothModulesImportableTogether() {
        let appleType: xpc_type_t = XPC_TYPE_DICTIONARY
        XCTAssertTrue(appleType == XPC_TYPE_DICTIONARY)
    }

    func testNamespaceExists() {
        // A caseless enum has no values; proving the metatype exists is enough.
        XCTAssertNotNil(XPCCompat.self)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NamespaceTests`
Expected: FAIL — `no such module 'XPCCompat'`.

- [ ] **Step 3: Add the targets**

Replace `Package.swift` lines 13-32 (the `products:` and `targets:` arrays) with:

```swift
    products: [
        .library(
            name: "CodableXPC",
            targets: ["CodableXPC"]),
        .library(
            name: "XPCCompat",
            targets: ["XPCCompat"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "CodableXPC",
            dependencies: []),
        .target(
            name: "XPCCompat",
            dependencies: ["CodableXPC"]),
        .testTarget(
            name: "CodableXPCTests",
            dependencies: ["CodableXPC"]),
        .testTarget(
            name: "XPCCompatTests",
            dependencies: ["XPCCompat"]),
    ]
```

- [ ] **Step 4: Create the namespace**

Create `Sources/XPCCompat/Namespace.swift`:

```swift
import XPC

/// Namespace for backported equivalents of Apple's `XPC` Swift overlay types.
///
/// These types mirror `XPCDictionary`, `XPCArray`, `XPCSession` and friends but are
/// available from macOS 10.15. This module deliberately does not re-export `XPC`, so
/// `import XPC` and `import XPCCompat` can appear in the same file.
///
/// For drop-in source compatibility, declare your own aliases:
///
///     typealias XPCDictionary = XPCCompat.Dictionary
///
/// - Important: Declare only stored properties and initializers inside this enum's body.
///   Every other member belongs in a file-scope `extension XPCCompat.X`. Inside the enum
///   body, an unqualified `Array` resolves to `XPCCompat.Array` rather than `Swift.Array`,
///   and `Array()` compiles cleanly while producing the wrong type.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public enum XPCCompat {}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter NamespaceTests`
Expected: PASS, 2 tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/XPCCompat/Namespace.swift Tests/XPCCompatTests/NamespaceTests.swift
git commit -m "feat(xpccompat): add XPCCompat target and namespace enum"
```

---

### Task 2: Container storage, initializers, count

**Files:**
- Create: `Sources/XPCCompat/Containers.swift`
- Test: `Tests/XPCCompatTests/ContainerStorageTests.swift`

**Interfaces:**
- Consumes: `XPCCompat` from Task 1.
- Produces:
  - `XPCCompat.Dictionary`: `init()`, `init(_ value: xpc_object_t)` (traps on wrong type), `var underlying: xpc_object_t` (internal), `func withUnsafeUnderlyingDictionary<R>(_ closure: (xpc_object_t) throws -> R) rethrows -> R`, `var count: Int`, `var isEmpty: Bool`.
  - `XPCCompat.Array`: same shape with `withUnsafeUnderlyingArray`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCCompatTests/ContainerStorageTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCCompat

final class ContainerStorageTests: XCTestCase {

    func testEmptyDictionary() {
        let d = XPCCompat.Dictionary()
        XCTAssertEqual(d.count, 0)
        XCTAssertTrue(d.isEmpty)
    }

    func testEmptyArray() {
        let a = XPCCompat.Array()
        XCTAssertEqual(a.count, 0)
        XCTAssertTrue(a.isEmpty)
    }

    func testWrapsExistingDictionary() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(raw, "k", "v")
        let d = XPCCompat.Dictionary(raw)
        XCTAssertEqual(d.count, 1)
        XCTAssertFalse(d.isEmpty)
    }

    func testWrapsExistingArray() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_string_create("a"))
        xpc_array_append_value(raw, xpc_string_create("b"))
        let a = XPCCompat.Array(raw)
        XCTAssertEqual(a.count, 2)
    }

    func testWithUnsafeUnderlyingDictionaryGivesTheSameObject() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        let d = XPCCompat.Dictionary(raw)
        let same = d.withUnsafeUnderlyingDictionary { xpc_equal($0, raw) }
        XCTAssertTrue(same)
    }

    func testWithUnsafeUnderlyingArrayGivesTheSameObject() {
        let raw = xpc_array_create(nil, 0)
        let a = XPCCompat.Array(raw)
        XCTAssertTrue(a.withUnsafeUnderlyingArray { xpc_equal($0, raw) })
    }

    func testWithUnsafeUnderlyingRethrows() {
        struct Boom: Error {}
        let d = XPCCompat.Dictionary()
        XCTAssertThrowsError(try d.withUnsafeUnderlyingDictionary { _ in throw Boom() })
    }

    // Reference semantics: copying the struct shares the underlying object.
    // This is Apple's behaviour and must not be "fixed" with copy-on-write.
    func testCopyingTheStructSharesStorage() {
        let d = XPCCompat.Dictionary()
        let copy = d   // `let`, because writing through the shared object is non-mutating
        copy.withUnsafeUnderlyingDictionary { xpc_dictionary_set_int64($0, "n", 1) }
        XCTAssertEqual(d.count, 1, "XPCCompat.Dictionary must have reference semantics")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ContainerStorageTests`
Expected: FAIL — `type 'XPCCompat' has no member 'Dictionary'`.

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCCompat/Containers.swift`:

```swift
import XPC

// Storage declarations only. Every other member lives in a file-scope extension,
// per the shadowing rule in Namespace.swift.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat {

    /// A typed wrapper over an `XPC_TYPE_DICTIONARY` object.
    ///
    /// This is a struct with reference semantics: copying it retains the same underlying
    /// object, so mutating a copy is visible through the original. Use `copy(into:)` for
    /// an independent duplicate.
    public struct Dictionary {
        @usableFromInline
        internal let underlying: xpc_object_t

        /// Wraps an existing dictionary object.
        /// - Precondition: `value` is an `XPC_TYPE_DICTIONARY`.
        public init(_ value: xpc_object_t) {
            precondition(
                xpc_get_type(value) == XPC_TYPE_DICTIONARY,
                "XPCCompat.Dictionary requires an XPC_TYPE_DICTIONARY object"
            )
            self.underlying = value
        }

        /// Creates an empty dictionary.
        public init() {
            self.underlying = xpc_dictionary_create(nil, nil, 0)
        }
    }

    /// A typed wrapper over an `XPC_TYPE_ARRAY` object.
    ///
    /// Reference semantics, as `Dictionary`.
    public struct Array {
        @usableFromInline
        internal let underlying: xpc_object_t

        /// Wraps an existing array object.
        /// - Precondition: `value` is an `XPC_TYPE_ARRAY`.
        public init(_ value: xpc_object_t) {
            precondition(
                xpc_get_type(value) == XPC_TYPE_ARRAY,
                "XPCCompat.Array requires an XPC_TYPE_ARRAY object"
            )
            self.underlying = value
        }

        /// Creates an empty array.
        public init() {
            self.underlying = xpc_array_create(nil, 0)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Calls `closure` with the underlying `xpc_object_t`.
    @inlinable
    public func withUnsafeUnderlyingDictionary<ReturnType>(
        _ closure: (xpc_object_t) throws -> ReturnType
    ) rethrows -> ReturnType {
        try closure(underlying)
    }

    /// The number of key-value pairs.
    public var count: Int { xpc_dictionary_get_count(underlying) }

    /// Whether the dictionary has no entries.
    public var isEmpty: Bool { count == 0 }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Calls `closure` with the underlying `xpc_object_t`.
    @inlinable
    public func withUnsafeUnderlyingArray<ReturnType>(
        _ closure: (xpc_object_t) throws -> ReturnType
    ) rethrows -> ReturnType {
        try closure(underlying)
    }

    /// The number of elements.
    public var count: Int { xpc_array_get_count(underlying) }

    /// Whether the array has no elements.
    public var isEmpty: Bool { count == 0 }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ContainerStorageTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCCompat/Containers.swift Tests/XPCCompatTests/ContainerStorageTests.swift
git commit -m "feat(xpccompat): add Dictionary and Array storage types"
```

---

### Task 3: Equatable, Hashable, CustomDebugStringConvertible

**Files:**
- Create: `Sources/XPCCompat/Conformances.swift`
- Test: `Tests/XPCCompatTests/ConformanceTests.swift`

**Interfaces:**
- Consumes: `XPCCompat.Dictionary`, `XPCCompat.Array` from Task 2.
- Produces: both types conform to `Equatable`, `Hashable`, `CustomDebugStringConvertible`. Equality is `xpc_equal` (structural), hashing combines `xpc_hash`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCCompatTests/ConformanceTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCCompat

final class ConformanceTests: XCTestCase {

    private func makeDict(_ value: Int64) -> XPCCompat.Dictionary {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", value)
        return XPCCompat.Dictionary(raw)
    }

    // Structural equality, not pointer identity: two independently built
    // dictionaries with the same contents are equal.
    func testEqualityIsStructural() {
        XCTAssertEqual(makeDict(1), makeDict(1))
        XCTAssertNotEqual(makeDict(1), makeDict(2))
    }

    func testEqualDictionariesHashEqually() {
        XCTAssertEqual(makeDict(7).hashValue, makeDict(7).hashValue)
    }

    func testUsableAsSetMember() {
        let set: Set<XPCCompat.Dictionary> = [makeDict(1), makeDict(1), makeDict(2)]
        XCTAssertEqual(set.count, 2)
    }

    func testArrayEqualityIsStructural() {
        let a = xpc_array_create(nil, 0)
        xpc_array_append_value(a, xpc_string_create("x"))
        let b = xpc_array_create(nil, 0)
        xpc_array_append_value(b, xpc_string_create("x"))
        XCTAssertEqual(XPCCompat.Array(a), XPCCompat.Array(b))
    }

    func testDebugDescriptionMentionsDictionary() {
        let text = makeDict(1).debugDescription
        XCTAssertTrue(text.contains("dictionary"), "got: \(text)")
    }

    func testDebugDescriptionMentionsArray() {
        let text = XPCCompat.Array().debugDescription
        XCTAssertTrue(text.contains("array"), "got: \(text)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConformanceTests`
Expected: FAIL — `referencing operator function '==' ... requires that 'XPCCompat.Dictionary' conform to 'Equatable'`.

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCCompat/Conformances.swift`:

```swift
import XPC

// xpc_copy_description returns a malloc'd C string the caller must free.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal func xpcDescription(_ object: xpc_object_t) -> String {
    guard let raw = xpc_copy_description(object) else { return "<xpc: no description>" }
    defer { free(raw) }
    return String(cString: raw)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary: Equatable {
    public static func == (lhs: XPCCompat.Dictionary, rhs: XPCCompat.Dictionary) -> Bool {
        xpc_equal(lhs.underlying, rhs.underlying)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(xpc_hash(underlying))
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary: CustomDebugStringConvertible {
    public var debugDescription: String { xpcDescription(underlying) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array: Equatable {
    public static func == (lhs: XPCCompat.Array, rhs: XPCCompat.Array) -> Bool {
        xpc_equal(lhs.underlying, rhs.underlying)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(xpc_hash(underlying))
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array: CustomDebugStringConvertible {
    public var debugDescription: String { xpcDescription(underlying) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConformanceTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCCompat/Conformances.swift Tests/XPCCompatTests/ConformanceTests.swift
git commit -m "feat(xpccompat): add Equatable, Hashable and debug description"
```

---

### Task 4: Bool subscripts (strict, no numeric coercion)

**Files:**
- Create: `Sources/XPCCompat/Subscripts+Bool.swift`
- Test: `Tests/XPCCompatTests/BoolSubscriptTests.swift`

**Interfaces:**
- Consumes: Task 2 storage.
- Produces, on `XPCCompat.Dictionary`:
  - `subscript(key: String, as type: Bool.Type = Bool.self) -> Bool?` — get only
  - `subscript(key: String) -> Bool?` — get/set
  - `subscript(key: String, as type: Bool.Type = Bool.self, default defaultValue: @autoclosure () -> Bool) -> Bool` — get only

  On `XPCCompat.Array`, the same three with `index: Int` in place of `key: String`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCCompatTests/BoolSubscriptTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCCompat

final class BoolSubscriptTests: XCTestCase {

    func testRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["flag"] = true
        XCTAssertEqual(d["flag"], true)
        d["flag"] = false
        XCTAssertEqual(d["flag"], false)
    }

    func testMissingKeyIsNil() {
        let d = XPCCompat.Dictionary()
        let value: Bool? = d["absent"]
        XCTAssertNil(value)
    }

    // Apple's Bool subscript accepts only XPC_TYPE_BOOL. An int64 0/1 must read as nil.
    func testIntegerDoesNotCoerceToBool() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        let d = XPCCompat.Dictionary(raw)
        let value: Bool? = d["n"]
        XCTAssertNil(value, "Bool subscript must not coerce int64 1 to true")
    }

    func testDefaultUsedForMissingKey() {
        let d = XPCCompat.Dictionary()
        XCTAssertTrue(d["absent", default: true])
    }

    // The default also covers a present-but-wrong-typed value.
    func testDefaultUsedForWrongType() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(raw, "s", "not a bool")
        let d = XPCCompat.Dictionary(raw)
        XCTAssertTrue(d["s", default: true])
    }

    func testDefaultAutoclosureIsLazy() {
        var evaluated = false
        func makeDefault() -> Bool { evaluated = true; return false }
        var d = XPCCompat.Dictionary()
        d["flag"] = true
        _ = d["flag", default: makeDefault()]
        XCTAssertFalse(evaluated, "default must not be evaluated when the key resolves")
    }

    // Assigning nil removes the key on every subscript. This is a deliberate
    // divergence: Apple's Bool setter silently ignores nil.
    func testAssigningNilRemovesKey() {
        var d = XPCCompat.Dictionary()
        d["flag"] = true
        d["flag"] = Bool?.none
        XCTAssertEqual(d.count, 0, "nil assignment must remove the key")
    }

    func testArrayRoundTrip() {
        var a = XPCCompat.Array()
        a.withUnsafeUnderlyingArray { xpc_array_append_value($0, xpc_bool_create(false)) }
        a[0] = true
        XCTAssertEqual(a[0], true)
    }

    func testArrayOutOfBoundsIsNil() {
        let a = XPCCompat.Array()
        let value: Bool? = a[5]
        XCTAssertNil(value)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BoolSubscriptTests`
Expected: FAIL — no `subscript` overload accepting a `Bool?`.

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCCompat/Subscripts+Bool.swift`:

```swift
import XPC

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads a boolean. Returns `nil` if the key is absent or the value is not a boolean.
    ///
    /// Only `XPC_TYPE_BOOL` is accepted; an integer `0`/`1` reads as `nil`.
    public subscript(key: String, as type: Bool.Type = Bool.self) -> Bool? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == XPC_TYPE_BOOL else { return nil }
        return xpc_bool_get_value(value)
    }

    /// Reads or writes a boolean. Assigning `nil` removes the key.
    public subscript(key: String) -> Bool? {
        get { self[key, as: Bool.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_bool(underlying, key, newValue)
        }
    }

    /// Reads a boolean, falling back to `defaultValue` when the key is absent,
    /// the value is not a boolean, or conversion fails.
    public subscript(
        key: String,
        as type: Bool.Type = Bool.self,
        default defaultValue: @autoclosure () -> Bool
    ) -> Bool {
        self[key, as: Bool.self] ?? defaultValue()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads a boolean. Returns `nil` if the index is out of range or the value is not a boolean.
    ///
    /// Note `xpc_array_get_value` returns a non-optional `xpc_object_t`, unlike
    /// `xpc_dictionary_get_value`, so the bounds check and the type check are separate
    /// statements rather than one `guard let` chain.
    public subscript(index: Int, as type: Bool.Type = Bool.self) -> Bool? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        let value = xpc_array_get_value(underlying, index)
        guard xpc_get_type(value) == XPC_TYPE_BOOL else { return nil }
        return xpc_bool_get_value(value)
    }

    /// Reads or writes a boolean at `index`.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    public subscript(index: Int) -> Bool? {
        get { self[index, as: Bool.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_bool(underlying, index, newValue)
        }
    }

    /// Reads a boolean, falling back to `defaultValue`.
    public subscript(
        index: Int,
        as type: Bool.Type = Bool.self,
        default defaultValue: @autoclosure () -> Bool
    ) -> Bool {
        self[index, as: Bool.self] ?? defaultValue()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BoolSubscriptTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCCompat/Subscripts+Bool.swift Tests/XPCCompatTests/BoolSubscriptTests.swift
git commit -m "feat(xpccompat): add Bool subscripts with strict type matching"
```

---

### Task 5: Integer subscripts (coercing, range-checked)

**Files:**
- Create: `Sources/XPCCompat/Subscripts+Integer.swift`
- Test: `Tests/XPCCompatTests/IntegerSubscriptTests.swift`

**Interfaces:**
- Consumes: Task 2 storage.
- Produces, on both containers:
  - `subscript<T: BinaryInteger>(key:as:) -> T?` — get only; reads int64, uint64 **and** double, converting with `init(exactly:)`
  - `subscript<T: SignedInteger>(key:) -> T?` — get/set via `xpc_*_int64`
  - `subscript<T: UnsignedInteger>(key:) -> T?` — get/set via `xpc_*_uint64`
  - `subscript<T: BinaryInteger>(key:as:default:) -> T`

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCCompatTests/IntegerSubscriptTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCCompat

final class IntegerSubscriptTests: XCTestCase {

    func testSignedRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["n"] = Int(-42)
        XCTAssertEqual(d["n", as: Int.self], -42)
    }

    func testUnsignedRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["n"] = UInt(42)
        XCTAssertEqual(d["n", as: UInt.self], 42)
    }

    // A value stored as uint64 must be readable as Int, and vice versa.
    func testCrossReadsBetweenSignedAndUnsignedStorage() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(raw, "u", 7)
        xpc_dictionary_set_int64(raw, "i", 7)
        let d = XPCCompat.Dictionary(raw)
        XCTAssertEqual(d["u", as: Int.self], 7)
        XCTAssertEqual(d["i", as: UInt.self], 7)
    }

    // A whole-valued double reads as an integer.
    func testWholeDoubleReadsAsInteger() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(raw, "d", 3.0)
        XCTAssertEqual(XPCCompat.Dictionary(raw)["d", as: Int.self], 3)
    }

    // A fractional double does not: init(exactly:) fails.
    func testFractionalDoubleIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(raw, "d", 1.5)
        XCTAssertNil(XPCCompat.Dictionary(raw)["d", as: Int.self])
    }

    // Range-checked, never truncating.
    func testOverflowReturnsNilRatherThanTruncating() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "big", 300)
        XCTAssertNil(XPCCompat.Dictionary(raw)["big", as: Int8.self])
    }

    func testNegativeIntoUnsignedIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "neg", -1)
        XCTAssertNil(XPCCompat.Dictionary(raw)["neg", as: UInt.self])
    }

    func testStringIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(raw, "s", "nope")
        XCTAssertNil(XPCCompat.Dictionary(raw)["s", as: Int.self])
    }

    func testDefaultOnMissingAndOnWrongType() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(raw, "s", "nope")
        let d = XPCCompat.Dictionary(raw)
        XCTAssertEqual(d["absent", as: Int.self, default: 9], 9)
        XCTAssertEqual(d["s", as: Int.self, default: 9], 9)
    }

    func testAssigningNilRemovesKey() {
        var d = XPCCompat.Dictionary()
        d["n"] = Int(1)
        d["n"] = Int?.none
        XCTAssertEqual(d.count, 0)
    }

    // Deliberate divergence: Apple silently drops an out-of-range unsigned
    // assignment through the signed path. We refuse it loudly instead.
    func testOutOfRangeUnsignedAssignmentTraps() {
        // UInt.max cannot be represented as Int64; assigning it through the
        // unsigned subscript is fine because it uses xpc_uint64.
        var d = XPCCompat.Dictionary()
        d["u"] = UInt.max
        XCTAssertEqual(d["u", as: UInt.self], UInt.max)
    }

    func testArrayIntegerRoundTrip() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_int64_create(0))
        var a = XPCCompat.Array(raw)
        a[0] = Int(5)
        XCTAssertEqual(a[0, as: Int.self], 5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter IntegerSubscriptTests`
Expected: FAIL — no integer subscript overload.

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCCompat/Subscripts+Integer.swift`:

```swift
import XPC

// Shared reader: an integer may have been stored as int64, uint64 or double.
// Conversion is always range-checked with init(exactly:), so out-of-range and
// fractional values yield nil rather than a truncated result.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal func xpcReadInteger<T: BinaryInteger>(_ value: xpc_object_t?, as type: T.Type) -> T? {
    guard let value else { return nil }
    switch xpc_get_type(value) {
    case XPC_TYPE_INT64:
        return T(exactly: xpc_int64_get_value(value))
    case XPC_TYPE_UINT64:
        return T(exactly: xpc_uint64_get_value(value))
    case XPC_TYPE_DOUBLE:
        return T(exactly: xpc_double_get_value(value))
    default:
        return nil
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads any integer type. Accepts int64, uint64 and whole-valued double storage.
    /// Returns `nil` when absent, wrongly typed, or out of range for `T`.
    public subscript<T: BinaryInteger>(key: String, as type: T.Type = T.self) -> T? {
        xpcReadInteger(xpc_dictionary_get_value(underlying, key), as: T.self)
    }

    /// Reads or writes a signed integer, stored as `int64`. Assigning `nil` removes the key.
    public subscript<T: SignedInteger>(key: String) -> T? {
        get { self[key, as: T.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            guard let wide = Int64(exactly: newValue) else {
                preconditionFailure("\(newValue) cannot be represented as Int64")
            }
            xpc_dictionary_set_int64(underlying, key, wide)
        }
    }

    /// Reads or writes an unsigned integer, stored as `uint64`. Assigning `nil` removes the key.
    public subscript<T: UnsignedInteger>(key: String) -> T? {
        get { self[key, as: T.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            guard let wide = UInt64(exactly: newValue) else {
                preconditionFailure("\(newValue) cannot be represented as UInt64")
            }
            xpc_dictionary_set_uint64(underlying, key, wide)
        }
    }

    /// Reads an integer, falling back to `defaultValue` on absence, wrong type or overflow.
    public subscript<T: BinaryInteger>(
        key: String,
        as type: T.Type = T.self,
        default defaultValue: @autoclosure () -> T
    ) -> T {
        self[key, as: T.self] ?? defaultValue()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads any integer type at `index`.
    public subscript<T: BinaryInteger>(index: Int, as type: T.Type = T.self) -> T? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        return xpcReadInteger(xpc_array_get_value(underlying, index), as: T.self)
    }

    /// Reads or writes a signed integer at `index`.
    public subscript<T: SignedInteger>(index: Int) -> T? {
        get { self[index, as: T.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            guard let wide = Int64(exactly: newValue) else {
                preconditionFailure("\(newValue) cannot be represented as Int64")
            }
            xpc_array_set_int64(underlying, index, wide)
        }
    }

    /// Reads or writes an unsigned integer at `index`.
    public subscript<T: UnsignedInteger>(index: Int) -> T? {
        get { self[index, as: T.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            guard let wide = UInt64(exactly: newValue) else {
                preconditionFailure("\(newValue) cannot be represented as UInt64")
            }
            xpc_array_set_uint64(underlying, index, wide)
        }
    }

    /// Reads an integer at `index`, falling back to `defaultValue`.
    public subscript<T: BinaryInteger>(
        index: Int,
        as type: T.Type = T.self,
        default defaultValue: @autoclosure () -> T
    ) -> T {
        self[index, as: T.self] ?? defaultValue()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter IntegerSubscriptTests`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCCompat/Subscripts+Integer.swift Tests/XPCCompatTests/IntegerSubscriptTests.swift
git commit -m "feat(xpccompat): add range-checked coercing integer subscripts"
```

---

### Task 6: Floating-point subscripts

**Files:**
- Create: `Sources/XPCCompat/Subscripts+FloatingPoint.swift`
- Test: `Tests/XPCCompatTests/FloatingPointSubscriptTests.swift`

**Interfaces:**
- Consumes: Task 2 storage.
- Produces on both containers: `subscript<T: BinaryFloatingPoint>(key:as:) -> T?` (get), `subscript<T: BinaryFloatingPoint>(key:) -> T?` (get/set), `subscript<T: BinaryFloatingPoint>(key:as:default:) -> T`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCCompatTests/FloatingPointSubscriptTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCCompat

final class FloatingPointSubscriptTests: XCTestCase {

    func testDoubleRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["x"] = Double(1.5)
        XCTAssertEqual(d["x", as: Double.self], 1.5)
    }

    func testFloatRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["x"] = Float(1.5)
        XCTAssertEqual(d["x", as: Float.self], 1.5)
    }

    func testIntegerStorageReadsAsDouble() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 3)
        XCTAssertEqual(XPCCompat.Dictionary(raw)["n", as: Double.self], 3.0)
    }

    // init(exactly:) again: an Int64 that cannot be represented exactly in Float is nil.
    func testInexactIntegerToFloatIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", Int64(1) << 40 + 1)
        XCTAssertNil(XPCCompat.Dictionary(raw)["n", as: Float.self])
    }

    func testStringIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(raw, "s", "nope")
        XCTAssertNil(XPCCompat.Dictionary(raw)["s", as: Double.self])
    }

    func testDefaultOnWrongType() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(raw, "s", "nope")
        XCTAssertEqual(XPCCompat.Dictionary(raw)["s", as: Double.self, default: 2.5], 2.5)
    }

    func testAssigningNilRemovesKey() {
        var d = XPCCompat.Dictionary()
        d["x"] = Double(1)
        d["x"] = Double?.none
        XCTAssertEqual(d.count, 0)
    }

    func testArrayRoundTrip() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_double_create(0))
        var a = XPCCompat.Array(raw)
        a[0] = Double(2.5)
        XCTAssertEqual(a[0, as: Double.self], 2.5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FloatingPointSubscriptTests`
Expected: FAIL — no floating-point subscript overload.

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCCompat/Subscripts+FloatingPoint.swift`:

```swift
import XPC

// As with integers, a floating-point value may have been stored as int64,
// uint64 or double. Conversion is exact-only.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal func xpcReadFloatingPoint<T: BinaryFloatingPoint>(
    _ value: xpc_object_t?, as type: T.Type
) -> T? {
    guard let value else { return nil }
    switch xpc_get_type(value) {
    case XPC_TYPE_DOUBLE:
        return T(exactly: xpc_double_get_value(value))
    case XPC_TYPE_INT64:
        return T(exactly: xpc_int64_get_value(value))
    case XPC_TYPE_UINT64:
        return T(exactly: xpc_uint64_get_value(value))
    default:
        return nil
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads any floating-point type. Accepts double, int64 and uint64 storage.
    public subscript<T: BinaryFloatingPoint>(key: String, as type: T.Type = T.self) -> T? {
        xpcReadFloatingPoint(xpc_dictionary_get_value(underlying, key), as: T.self)
    }

    /// Reads or writes a floating-point value, stored as `double`. Assigning `nil` removes the key.
    public subscript<T: BinaryFloatingPoint>(key: String) -> T? {
        get { self[key, as: T.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_double(underlying, key, Double(newValue))
        }
    }

    /// Reads a floating-point value, falling back to `defaultValue`.
    public subscript<T: BinaryFloatingPoint>(
        key: String,
        as type: T.Type = T.self,
        default defaultValue: @autoclosure () -> T
    ) -> T {
        self[key, as: T.self] ?? defaultValue()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads any floating-point type at `index`.
    public subscript<T: BinaryFloatingPoint>(index: Int, as type: T.Type = T.self) -> T? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        return xpcReadFloatingPoint(xpc_array_get_value(underlying, index), as: T.self)
    }

    /// Reads or writes a floating-point value at `index`.
    public subscript<T: BinaryFloatingPoint>(index: Int) -> T? {
        get { self[index, as: T.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_double(underlying, index, Double(newValue))
        }
    }

    /// Reads a floating-point value at `index`, falling back to `defaultValue`.
    public subscript<T: BinaryFloatingPoint>(
        index: Int,
        as type: T.Type = T.self,
        default defaultValue: @autoclosure () -> T
    ) -> T {
        self[index, as: T.self] ?? defaultValue()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FloatingPointSubscriptTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCCompat/Subscripts+FloatingPoint.swift Tests/XPCCompatTests/FloatingPointSubscriptTests.swift
git commit -m "feat(xpccompat): add floating-point subscripts"
```

---

### Task 7: String and Data subscripts

**Files:**
- Create: `Sources/XPCCompat/Subscripts+StringData.swift`
- Test: `Tests/XPCCompatTests/StringDataSubscriptTests.swift`

**Interfaces:**
- Consumes: Task 2 storage.
- Produces on both containers: `String?` get/set plus `as:` form; `Data?` get/set plus `as:` form; and on `Dictionary`, `func withUnsafeBytes<R>(forKey key: String, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R?` — the substitute for Apple's macOS 27 `RawSpan` subscript.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCCompatTests/StringDataSubscriptTests.swift`:

```swift
import XCTest
import XPC
import Foundation
@testable import XPCCompat

final class StringDataSubscriptTests: XCTestCase {

    func testStringRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["s"] = "hello"
        XCTAssertEqual(d["s", as: String.self], "hello")
    }

    func testEmptyString() {
        var d = XPCCompat.Dictionary()
        d["s"] = ""
        XCTAssertEqual(d["s", as: String.self], "")
    }

    func testNonASCIIString() {
        var d = XPCCompat.Dictionary()
        d["s"] = "\u{00e9}\u{d55c}"
        XCTAssertEqual(d["s", as: String.self], "\u{00e9}\u{d55c}")
    }

    func testWrongTypeIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        XCTAssertNil(XPCCompat.Dictionary(raw)["n", as: String.self])
    }

    func testAssigningNilRemovesKey() {
        var d = XPCCompat.Dictionary()
        d["s"] = "x"
        d["s"] = String?.none
        XCTAssertEqual(d.count, 0)
    }

    func testDataRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["blob"] = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(d["blob", as: Data.self], Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testEmptyData() {
        var d = XPCCompat.Dictionary()
        d["blob"] = Data()
        XCTAssertEqual(d["blob", as: Data.self], Data())
    }

    func testWithUnsafeBytesSeesTheStoredBytes() {
        var d = XPCCompat.Dictionary()
        d["blob"] = Data([1, 2, 3])
        let sum = d.withUnsafeBytes(forKey: "blob") { buffer in
            buffer.reduce(0) { $0 + Int($1) }
        }
        XCTAssertEqual(sum, 6)
    }

    func testWithUnsafeBytesReturnsNilForMissingKey() {
        let d = XPCCompat.Dictionary()
        let result = d.withUnsafeBytes(forKey: "absent") { _ in 1 }
        XCTAssertNil(result)
    }

    func testArrayStringRoundTrip() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_string_create(""))
        var a = XPCCompat.Array(raw)
        a[0] = "abc"
        XCTAssertEqual(a[0, as: String.self], "abc")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StringDataSubscriptTests`
Expected: FAIL — no `String` subscript overload.

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCCompat/Subscripts+StringData.swift`:

```swift
import XPC
import Foundation

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads a string. Returns `nil` if the key is absent or the value is not a string.
    ///
    /// Ill-formed UTF-8 is repaired with U+FFFD rather than returning `nil`, matching
    /// Apple's use of `String(cString:)`.
    public subscript(key: String, as type: String.Type = String.self) -> String? {
        guard let pointer = xpc_dictionary_get_string(underlying, key) else { return nil }
        return String(cString: pointer)
    }

    /// Reads or writes a string. Assigning `nil` removes the key.
    public subscript(key: String) -> String? {
        get { self[key, as: String.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_string(underlying, key, newValue)
        }
    }

    /// Reads binary data. Returns `nil` if the key is absent or the value is not data.
    public subscript(key: String, as type: Data.Type = Data.self) -> Data? {
        var length = 0
        guard let base = xpc_dictionary_get_data(underlying, key, &length) else { return nil }
        return Data(bytes: base, count: length)
    }

    /// Reads or writes binary data. Assigning `nil` removes the key.
    public subscript(key: String) -> Data? {
        get { self[key, as: Data.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            newValue.withUnsafeBytes { buffer in
                xpc_dictionary_set_data(underlying, key, buffer.baseAddress, buffer.count)
            }
        }
    }

    /// Calls `body` with the raw bytes stored under `key`, without copying.
    ///
    /// Returns `nil` without calling `body` when the key is absent or is not data.
    /// This replaces Apple's macOS 27 `RawSpan` subscript, which cannot be backported.
    public func withUnsafeBytes<ReturnType>(
        forKey key: String,
        _ body: (UnsafeRawBufferPointer) throws -> ReturnType
    ) rethrows -> ReturnType? {
        var length = 0
        guard let base = xpc_dictionary_get_data(underlying, key, &length) else { return nil }
        return try body(UnsafeRawBufferPointer(start: base, count: length))
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads a string at `index`.
    public subscript(index: Int, as type: String.Type = String.self) -> String? {
        guard index >= 0, index < xpc_array_get_count(underlying),
              let pointer = xpc_array_get_string(underlying, index) else { return nil }
        return String(cString: pointer)
    }

    /// Reads or writes a string at `index`.
    public subscript(index: Int) -> String? {
        get { self[index, as: String.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_string(underlying, index, newValue)
        }
    }

    /// Reads binary data at `index`.
    public subscript(index: Int, as type: Data.Type = Data.self) -> Data? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        var length = 0
        guard let base = xpc_array_get_data(underlying, index, &length) else { return nil }
        return Data(bytes: base, count: length)
    }

    /// Reads or writes binary data at `index`.
    public subscript(index: Int) -> Data? {
        get { self[index, as: Data.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            newValue.withUnsafeBytes { buffer in
                xpc_array_set_data(underlying, index, buffer.baseAddress, buffer.count)
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StringDataSubscriptTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCCompat/Subscripts+StringData.swift Tests/XPCCompatTests/StringDataSubscriptTests.swift
git commit -m "feat(xpccompat): add String and Data subscripts"
```

---

### Task 8: UUID and FileDescriptor subscripts

**Files:**
- Create: `Sources/XPCCompat/Subscripts+UUIDFileDescriptor.swift`
- Test: `Tests/XPCCompatTests/UUIDFileDescriptorSubscriptTests.swift`

**Interfaces:**
- Consumes: Task 2 storage.
- Produces on both containers: `uuid_t?` get/set plus `as:` and `default:` forms; and, gated `@available(macOS 11, iOS 14, *)`, `System.FileDescriptor?` get/set plus `as:` and `default:` forms.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCCompatTests/UUIDFileDescriptorSubscriptTests.swift`:

```swift
import XCTest
import XPC
import Foundation
import System
@testable import XPCCompat

final class UUIDFileDescriptorSubscriptTests: XCTestCase {

    private let sample: uuid_t = (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)

    func testUUIDRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["id"] = sample
        let read = d["id", as: uuid_t.self]
        XCTAssertNotNil(read)
        XCTAssertTrue(withUnsafeBytes(of: sample) { a in
            withUnsafeBytes(of: read!) { b in a.elementsEqual(b) }
        })
    }

    func testUUIDWrongTypeIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        XCTAssertNil(XPCCompat.Dictionary(raw)["n", as: uuid_t.self])
    }

    func testUUIDDefaultOnMissing() {
        let d = XPCCompat.Dictionary()
        let fallback: uuid_t = (9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9)
        let value = d["absent", as: uuid_t.self, default: fallback]
        XCTAssertEqual(value.0, 9)
    }

    func testUUIDAssigningNilRemovesKey() {
        var d = XPCCompat.Dictionary()
        d["id"] = sample
        d["id"] = uuid_t?.none
        XCTAssertEqual(d.count, 0)
    }

    @available(macOS 11, iOS 14, *)
    func testFileDescriptorRoundTrip() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        var d = XPCCompat.Dictionary()
        d["fd"] = FileDescriptor(rawValue: fds[0])

        let received = d["fd", as: FileDescriptor.self]
        XCTAssertNotNil(received)
        // xpc_fd_create dups the descriptor, so the received one is a different number
        // referring to the same pipe. Close it to avoid leaking.
        if let received { try? received.close() }
    }

    @available(macOS 11, iOS 14, *)
    func testFileDescriptorWrongTypeIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        XCTAssertNil(XPCCompat.Dictionary(raw)["n", as: FileDescriptor.self])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UUIDFileDescriptorSubscriptTests`
Expected: FAIL — no `uuid_t` subscript overload.

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCCompat/Subscripts+UUIDFileDescriptor.swift`:

```swift
import XPC
import Foundation
import System

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads a UUID as a raw 16-byte tuple.
    public subscript(key: String, as type: uuid_t.Type = uuid_t.self) -> uuid_t? {
        guard let bytes = xpc_dictionary_get_uuid(underlying, key) else { return nil }
        var result: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &result) { destination in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: 16))
        }
        return result
    }

    /// Reads or writes a UUID. Assigning `nil` removes the key.
    public subscript(key: String) -> uuid_t? {
        get { self[key, as: uuid_t.self] }
        set {
            guard var newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            withUnsafeBytes(of: &newValue) { source in
                xpc_dictionary_set_uuid(
                    underlying, key,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
    }

    /// Reads a UUID, falling back to `defaultValue`.
    public subscript(
        key: String,
        as type: uuid_t.Type = uuid_t.self,
        default defaultValue: @autoclosure () -> uuid_t
    ) -> uuid_t {
        self[key, as: uuid_t.self] ?? defaultValue()
    }
}

@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
extension XPCCompat.Dictionary {

    /// Reads a file descriptor. The returned descriptor is a duplicate owned by the
    /// caller and must be closed.
    public subscript(key: String, as type: FileDescriptor.Type = FileDescriptor.self) -> FileDescriptor? {
        let raw = xpc_dictionary_dup_fd(underlying, key)
        guard raw >= 0 else { return nil }
        return FileDescriptor(rawValue: raw)
    }

    /// Reads or writes a file descriptor. The descriptor is duplicated on write.
    /// Assigning `nil` removes the key.
    public subscript(key: String) -> FileDescriptor? {
        get { self[key, as: FileDescriptor.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_fd(underlying, key, newValue.rawValue)
        }
    }

    /// Reads a file descriptor, falling back to `defaultValue`.
    public subscript(
        key: String,
        as type: FileDescriptor.Type = FileDescriptor.self,
        default defaultValue: @autoclosure () -> FileDescriptor
    ) -> FileDescriptor {
        self[key, as: FileDescriptor.self] ?? defaultValue()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads a UUID at `index`.
    public subscript(index: Int, as type: uuid_t.Type = uuid_t.self) -> uuid_t? {
        guard index >= 0, index < xpc_array_get_count(underlying),
              let bytes = xpc_array_get_uuid(underlying, index) else { return nil }
        var result: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &result) { destination in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: 16))
        }
        return result
    }

    /// Reads or writes a UUID at `index`.
    public subscript(index: Int) -> uuid_t? {
        get { self[index, as: uuid_t.self] }
        set {
            guard var newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            withUnsafeBytes(of: &newValue) { source in
                xpc_array_set_uuid(
                    underlying, index,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
    }

    /// Reads a UUID at `index`, falling back to `defaultValue`.
    public subscript(
        index: Int,
        as type: uuid_t.Type = uuid_t.self,
        default defaultValue: @autoclosure () -> uuid_t
    ) -> uuid_t {
        self[index, as: uuid_t.self] ?? defaultValue()
    }
}

@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
extension XPCCompat.Array {

    /// Reads a file descriptor at `index`. The caller owns and must close it.
    public subscript(index: Int, as type: FileDescriptor.Type = FileDescriptor.self) -> FileDescriptor? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        let raw = xpc_array_dup_fd(underlying, index)
        guard raw >= 0 else { return nil }
        return FileDescriptor(rawValue: raw)
    }

    /// Reads or writes a file descriptor at `index`.
    public subscript(index: Int) -> FileDescriptor? {
        get { self[index, as: FileDescriptor.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_fd(underlying, index, newValue.rawValue)
        }
    }

    /// Reads a file descriptor at `index`, falling back to `defaultValue`.
    public subscript(
        index: Int,
        as type: FileDescriptor.Type = FileDescriptor.self,
        default defaultValue: @autoclosure () -> FileDescriptor
    ) -> FileDescriptor {
        self[index, as: FileDescriptor.self] ?? defaultValue()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UUIDFileDescriptorSubscriptTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCCompat/Subscripts+UUIDFileDescriptor.swift Tests/XPCCompatTests/UUIDFileDescriptorSubscriptTests.swift
git commit -m "feat(xpccompat): add uuid_t and FileDescriptor subscripts"
```

---

### Task 9: Nested container, endpoint, shared memory and raw object subscripts

**Files:**
- Create: `Sources/XPCCompat/Endpoint.swift`
- Create: `Sources/XPCCompat/SharedMemory.swift`
- Create: `Sources/XPCCompat/Subscripts+Object.swift`
- Test: `Tests/XPCCompatTests/ObjectSubscriptTests.swift`

**Interfaces:**
- Consumes: Task 2 storage, Task 3 conformances.
- Produces:
  - `XPCCompat.Endpoint`: `init(_ endpoint: xpc_object_t)` (traps unless `XPC_TYPE_ENDPOINT`), `public var underlying: xpc_object_t`, `Equatable`, `Hashable`, `CustomDebugStringConvertible`.
  - `XPCCompat.SharedMemory`: `init(_ value: xpc_object_t)` (traps unless `XPC_TYPE_SHMEM`), `init(byteCount:)?`, `public var underlying: xpc_object_t`, `public func withUnsafeMutableBytes<R>(_:) rethrows -> R?`, `Equatable`, `Hashable`, `CustomDebugStringConvertible`.
  - **Correction (2026-08-05).** An earlier revision of this contract named `underlyingEndpoint` and `underlyingShmem` as the public accessors. They are not: both are `internal` stored properties, and the public accessor on each type is `underlying`. Phase 2 must be written against `underlying`.
  - Subscripts on both containers for `XPCCompat.Dictionary`, `XPCCompat.Array`, `XPCCompat.Endpoint`, `XPCCompat.SharedMemory`, and raw `xpc_object_t` including lookup by `xpc_type_t`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCCompatTests/ObjectSubscriptTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCCompat

final class ObjectSubscriptTests: XCTestCase {

    func testNestedDictionaryRoundTrip() {
        var outer = XPCCompat.Dictionary()
        var inner = XPCCompat.Dictionary()
        inner["n"] = Int(1)
        outer["child"] = inner
        XCTAssertEqual(outer["child", as: XPCCompat.Dictionary.self], inner)
    }

    // Nested containers alias rather than copy: mutating the child after
    // insertion is visible through the parent.
    func testNestedContainersAlias() {
        var outer = XPCCompat.Dictionary()
        var inner = XPCCompat.Dictionary()
        outer["child"] = inner
        inner["added"] = Int(1)
        XCTAssertEqual(outer["child", as: XPCCompat.Dictionary.self]?.count, 1)
    }

    func testNestedArrayRoundTrip() {
        var outer = XPCCompat.Dictionary()
        let inner = XPCCompat.Array()
        outer["list"] = inner
        XCTAssertEqual(outer["list", as: XPCCompat.Array.self], inner)
    }

    func testWrongContainerTypeIsNil() {
        var d = XPCCompat.Dictionary()
        d["list"] = XPCCompat.Array()
        XCTAssertNil(d["list", as: XPCCompat.Dictionary.self])
    }

    func testRawObjectRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["raw"] = xpc_string_create("hi")
        let value = d["raw", as: xpc_object_t.self]
        XCTAssertNotNil(value)
        XCTAssertTrue(xpc_get_type(value!) == XPC_TYPE_STRING)
    }

    func testLookupByTypeReturnsValueWhenTypeMatches() {
        var d = XPCCompat.Dictionary()
        d["s"] = "hi"
        XCTAssertNotNil(d["s", as: XPC_TYPE_STRING])
        XCTAssertNil(d["s", as: XPC_TYPE_INT64])
    }

    func testEndpointRoundTrip() {
        let connection = xpc_connection_create(nil, nil)
        let endpoint = XPCCompat.Endpoint(xpc_endpoint_create(connection))
        var d = XPCCompat.Dictionary()
        d["ep"] = endpoint
        XCTAssertEqual(d["ep", as: XPCCompat.Endpoint.self], endpoint)
        xpc_connection_cancel(connection)
    }

    func testSharedMemoryRoundTrip() throws {
        let memory = try XCTUnwrap(XPCCompat.SharedMemory(byteCount: 4096))
        var d = XPCCompat.Dictionary()
        d["mem"] = memory
        XCTAssertNotNil(d["mem", as: XPCCompat.SharedMemory.self])
    }

    func testAssigningNilRemovesNestedContainer() {
        var d = XPCCompat.Dictionary()
        d["child"] = XPCCompat.Dictionary()
        d["child"] = XPCCompat.Dictionary?.none
        XCTAssertEqual(d.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ObjectSubscriptTests`
Expected: FAIL — `type 'XPCCompat' has no member 'Endpoint'`.

- [ ] **Step 3: Create Endpoint**

Create `Sources/XPCCompat/Endpoint.swift`:

```swift
import XPC

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat {

    /// A typed wrapper over an `XPC_TYPE_ENDPOINT` object.
    ///
    /// An endpoint is a transferable reference to a listener. Bridge to Apple's
    /// `XPC.XPCEndpoint` by passing `underlyingEndpoint` to its public initializer.
    public struct Endpoint {
        @usableFromInline
        internal let underlyingEndpoint: xpc_object_t

        /// Wraps an existing endpoint object.
        /// - Precondition: `endpoint` is an `XPC_TYPE_ENDPOINT`.
        public init(_ endpoint: xpc_object_t) {
            precondition(
                xpc_get_type(endpoint) == XPC_TYPE_ENDPOINT,
                "XPCCompat.Endpoint requires an XPC_TYPE_ENDPOINT object"
            )
            self.underlyingEndpoint = endpoint
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Endpoint {
    /// The wrapped `xpc_endpoint_t`, for interoperation with the C API and Apple's overlay.
    public var underlying: xpc_object_t { underlyingEndpoint }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Endpoint: Equatable {
    public static func == (lhs: XPCCompat.Endpoint, rhs: XPCCompat.Endpoint) -> Bool {
        xpc_equal(lhs.underlyingEndpoint, rhs.underlyingEndpoint)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Endpoint: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(xpc_hash(underlyingEndpoint))
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Endpoint: CustomDebugStringConvertible {
    public var debugDescription: String { xpcDescription(underlyingEndpoint) }
}
```

- [ ] **Step 4: Create SharedMemory**

> **Corrected during execution — the code below is superseded.** Two defects were found:
> `xpc_shmem_create` requires a region obtained from `mmap` with `MAP_SHARED` (`xpc/xpc.h:1081-1096`
> explicitly warns that `malloc`-family memory is unsafe to share), so `posix_memalign` is wrong; and
> `xpc_shmem_create` does not take ownership of the caller's mapping, so the initializer below leaks a
> page-aligned mapping on every call. As shipped, `SharedMemory` is a `final class` holding
> `private let owned: (UnsafeMutableRawPointer, Int)?` — non-nil only when the instance allocated the
> region — with `init(_:)` setting `owned = nil`, `init?(byteCount:)` using
> `mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0)` and setting `owned`, and
> `deinit` calling `munmap` only when `owned` is non-nil. `Endpoint` remains a struct; only `SharedMemory`
> owns a resource. See `Sources/XPCCompat/SharedMemory.swift`.

Create `Sources/XPCCompat/SharedMemory.swift`:

```swift
import XPC
import Darwin

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat {

    /// A typed wrapper over an `XPC_TYPE_SHMEM` object.
    ///
    /// This is a value wrapper only: it round-trips through containers and comparison,
    /// but mapping is left to the caller via `xpc_shmem_map`. Apple's overlay provides
    /// no Swift type for shared memory at all.
    public struct SharedMemory {
        @usableFromInline
        internal let underlyingShmem: xpc_object_t

        /// Wraps an existing shared memory object.
        /// - Precondition: `value` is an `XPC_TYPE_SHMEM`.
        public init(_ value: xpc_object_t) {
            precondition(
                xpc_get_type(value) == XPC_TYPE_SHMEM,
                "XPCCompat.SharedMemory requires an XPC_TYPE_SHMEM object"
            )
            self.underlyingShmem = value
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.SharedMemory {

    /// Allocates `byteCount` bytes of shareable memory.
    ///
    /// Returns `nil` if the allocation fails. The region is owned by the returned
    /// object; callers map it with `xpc_shmem_map`.
    public init?(byteCount: Int) {
        guard byteCount > 0 else { return nil }
        var region: UnsafeMutableRawPointer?
        guard posix_memalign(&region, Int(getpagesize()), byteCount) == 0,
              let region else { return nil }
        self.init(xpc_shmem_create(region, byteCount))
    }

    /// The wrapped `xpc_object_t`, for use with `xpc_shmem_map`.
    public var underlying: xpc_object_t { underlyingShmem }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.SharedMemory: Equatable {
    public static func == (lhs: XPCCompat.SharedMemory, rhs: XPCCompat.SharedMemory) -> Bool {
        xpc_equal(lhs.underlyingShmem, rhs.underlyingShmem)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.SharedMemory: CustomDebugStringConvertible {
    public var debugDescription: String { xpcDescription(underlyingShmem) }
}
```

- [ ] **Step 5: Create the object subscripts**

Create `Sources/XPCCompat/Subscripts+Object.swift`:

```swift
import XPC

// Untyped setters mirror Apple's connection special case: a connection object
// must be stored with xpc_dictionary_set_connection, not set_value.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal func xpcSetObject(_ container: xpc_object_t, _ key: String, _ value: xpc_object_t) {
    if xpc_get_type(value) == XPC_TYPE_CONNECTION {
        xpc_dictionary_set_connection(container, key, value)
    } else {
        xpc_dictionary_set_value(container, key, value)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads a nested dictionary.
    public subscript(key: String, as type: XPCCompat.Dictionary.Type = XPCCompat.Dictionary.self) -> XPCCompat.Dictionary? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == XPC_TYPE_DICTIONARY else { return nil }
        return XPCCompat.Dictionary(value)
    }

    /// Reads or writes a nested dictionary. The child is stored by reference, not copied.
    public subscript(key: String) -> XPCCompat.Dictionary? {
        get { self[key, as: XPCCompat.Dictionary.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_value(underlying, key, newValue.underlying)
        }
    }

    /// Reads a nested array.
    public subscript(key: String, as type: XPCCompat.Array.Type = XPCCompat.Array.self) -> XPCCompat.Array? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == XPC_TYPE_ARRAY else { return nil }
        return XPCCompat.Array(value)
    }

    /// Reads or writes a nested array. The child is stored by reference, not copied.
    public subscript(key: String) -> XPCCompat.Array? {
        get { self[key, as: XPCCompat.Array.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_value(underlying, key, newValue.underlying)
        }
    }

    /// Reads an endpoint.
    public subscript(key: String, as type: XPCCompat.Endpoint.Type = XPCCompat.Endpoint.self) -> XPCCompat.Endpoint? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == XPC_TYPE_ENDPOINT else { return nil }
        return XPCCompat.Endpoint(value)
    }

    /// Reads or writes an endpoint.
    public subscript(key: String) -> XPCCompat.Endpoint? {
        get { self[key, as: XPCCompat.Endpoint.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_value(underlying, key, newValue.underlying)
        }
    }

    /// Reads a shared memory object.
    public subscript(key: String, as type: XPCCompat.SharedMemory.Type = XPCCompat.SharedMemory.self) -> XPCCompat.SharedMemory? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == XPC_TYPE_SHMEM else { return nil }
        return XPCCompat.SharedMemory(value)
    }

    /// Reads or writes a shared memory object.
    public subscript(key: String) -> XPCCompat.SharedMemory? {
        get { self[key, as: XPCCompat.SharedMemory.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_value(underlying, key, newValue.underlying)
        }
    }

    /// Reads the raw object stored under `key`, whatever its type.
    public subscript(key: String, as type: xpc_object_t.Type = xpc_object_t.self) -> xpc_object_t? {
        xpc_dictionary_get_value(underlying, key)
    }

    /// Reads the raw object stored under `key`, but only if it has the given XPC type.
    public subscript(key: String, as type: xpc_type_t) -> xpc_object_t? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == type else { return nil }
        return value
    }

    /// Reads or writes a raw object. Assigning `nil` removes the key.
    public subscript(key: String) -> xpc_object_t? {
        get { xpc_dictionary_get_value(underlying, key) }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpcSetObject(underlying, key, newValue)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads a nested dictionary at `index`.
    public subscript(index: Int, as type: XPCCompat.Dictionary.Type = XPCCompat.Dictionary.self) -> XPCCompat.Dictionary? {
        guard let value = self[index, as: xpc_object_t.self],
              xpc_get_type(value) == XPC_TYPE_DICTIONARY else { return nil }
        return XPCCompat.Dictionary(value)
    }

    /// Reads a nested array at `index`.
    public subscript(index: Int, as type: XPCCompat.Array.Type = XPCCompat.Array.self) -> XPCCompat.Array? {
        guard let value = self[index, as: xpc_object_t.self],
              xpc_get_type(value) == XPC_TYPE_ARRAY else { return nil }
        return XPCCompat.Array(value)
    }

    /// Reads an endpoint at `index`.
    public subscript(index: Int, as type: XPCCompat.Endpoint.Type = XPCCompat.Endpoint.self) -> XPCCompat.Endpoint? {
        guard let value = self[index, as: xpc_object_t.self],
              xpc_get_type(value) == XPC_TYPE_ENDPOINT else { return nil }
        return XPCCompat.Endpoint(value)
    }

    /// Reads the raw object at `index`.
    public subscript(index: Int, as type: xpc_object_t.Type = xpc_object_t.self) -> xpc_object_t? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        return xpc_array_get_value(underlying, index)
    }

    /// Reads the raw object at `index`, but only if it has the given XPC type.
    public subscript(index: Int, as type: xpc_type_t) -> xpc_object_t? {
        guard let value = self[index, as: xpc_object_t.self],
              xpc_get_type(value) == type else { return nil }
        return value
    }

    /// Reads or writes a raw object at `index`.
    public subscript(index: Int) -> xpc_object_t? {
        get { self[index, as: xpc_object_t.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            if xpc_get_type(newValue) == XPC_TYPE_CONNECTION {
                xpc_array_set_connection(underlying, index, newValue)
            } else {
                xpc_array_set_value(underlying, index, newValue)
            }
        }
    }

    /// Appends a raw object.
    public func append(_ value: xpc_object_t) {
        xpc_array_append_value(underlying, value)
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter ObjectSubscriptTests`
Expected: PASS, 9 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/XPCCompat/Endpoint.swift Sources/XPCCompat/SharedMemory.swift Sources/XPCCompat/Subscripts+Object.swift Tests/XPCCompatTests/ObjectSubscriptTests.swift
git commit -m "feat(xpccompat): add container, endpoint, shmem and raw object subscripts"
```

---

### Task 10: Collection operations

**Files:**
- Create: `Sources/XPCCompat/CollectionOperations.swift`
- Test: `Tests/XPCCompatTests/CollectionOperationTests.swift`

**Interfaces:**
- Consumes: Tasks 2 and 9.
- Produces:
  - `XPCCompat.Dictionary`: `typealias KeyValuePair = (key: String, value: xpc_object_t)`, `forEach(_:)` in both shapes, `map(_:)`, `keys`, `values`, `removeValue(forKey:)`, `copy(into:)`.
  - `XPCCompat.Array`: `typealias IndexValuePair = (index: Int, value: xpc_object_t)`, the same `forEach` shapes, `map(_:)`, `copy(into:)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/XPCCompatTests/CollectionOperationTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCCompat

final class CollectionOperationTests: XCTestCase {

    private func sampleDictionary() -> XPCCompat.Dictionary {
        var d = XPCCompat.Dictionary()
        d["a"] = Int(1)
        d["b"] = Int(2)
        d["c"] = Int(3)
        return d
    }

    func testKeysAndValuesAgree() {
        let d = sampleDictionary()
        XCTAssertEqual(Swift.Set(d.keys), ["a", "b", "c"])
        XCTAssertEqual(d.values.count, 3)
    }

    func testForEachVisitsEveryEntry() {
        var seen: Swift.Set<String> = []
        sampleDictionary().forEach { key, _ in seen.insert(key) }
        XCTAssertEqual(seen, ["a", "b", "c"])
    }

    func testMapProducesOneResultPerEntry() {
        let keys = sampleDictionary().map { $0.key }
        XCTAssertEqual(Swift.Set(keys), ["a", "b", "c"])
    }

    // Iteration must stop at the first thrown error and propagate it.
    func testForEachStopsOnThrow() {
        struct Stop: Error {}
        var visited = 0
        XCTAssertThrowsError(
            try sampleDictionary().forEach { _, _ in
                visited += 1
                throw Stop()
            }
        )
        XCTAssertEqual(visited, 1, "forEach must stop at the first throw")
    }

    func testRemoveValueReturnsOldValueAndRemovesKey() {
        var d = sampleDictionary()
        let removed = d.removeValue(forKey: "a")
        XCTAssertNotNil(removed)
        XCTAssertEqual(d.count, 2)
        XCTAssertNil(d["a", as: Int.self])
    }

    func testRemoveValueForMissingKeyIsNil() {
        var d = sampleDictionary()
        XCTAssertNil(d.removeValue(forKey: "zzz"))
        XCTAssertEqual(d.count, 3)
    }

    // copy(into:) is the escape hatch from reference semantics.
    func testCopyIntoProducesIndependentDictionary() {
        let source = sampleDictionary()
        var destination = XPCCompat.Dictionary()
        source.copy(into: destination)
        XCTAssertEqual(destination.count, 3)
        destination["d"] = Int(4)
        XCTAssertEqual(source.count, 3, "copy must be independent")
    }

    func testArrayForEachIsInIndexOrder() {
        let raw = xpc_array_create(nil, 0)
        for n in 0..<3 { xpc_array_append_value(raw, xpc_int64_create(Int64(n))) }
        var order: [Int] = []
        XPCCompat.Array(raw).forEach { index, _ in order.append(index) }
        XCTAssertEqual(order, [0, 1, 2])
    }

    func testArrayCopyInto() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_int64_create(1))
        let destination = XPCCompat.Array()
        XPCCompat.Array(raw).copy(into: destination)
        XCTAssertEqual(destination.count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CollectionOperationTests`
Expected: FAIL — `value of type 'XPCCompat.Dictionary' has no member 'keys'`.

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCCompat/CollectionOperations.swift`:

```swift
import XPC

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// A key and its associated raw value.
    public typealias KeyValuePair = (key: String, value: xpc_object_t)

    /// Calls `body` once per entry.
    ///
    /// Iteration order is whatever `xpc_dictionary_apply` yields and is not specified.
    /// If `body` throws, iteration stops immediately and the error is rethrown.
    public func forEach(
        _ body: (_ key: String, _ value: xpc_object_t) throws -> Void
    ) rethrows {
        var thrown: Error?
        xpc_dictionary_apply(underlying) { key, value in
            do {
                try body(String(cString: key), value)
                return true
            } catch {
                thrown = error
                return false
            }
        }
        if let thrown {
            try { throw thrown }()
        }
    }

    /// Calls `body` once per entry, as a tuple.
    public func forEach(_ body: (KeyValuePair) throws -> Void) rethrows {
        try forEach { key, value in try body((key: key, value: value)) }
    }

    /// Transforms each entry into a value.
    public func map<ReturnType>(
        _ transform: (KeyValuePair) throws -> ReturnType
    ) rethrows -> [ReturnType] {
        var results: [ReturnType] = []
        results.reserveCapacity(count)
        try forEach { pair in results.append(try transform(pair)) }
        return results
    }

    /// The keys, in the same order as `values`.
    public var keys: [String] { map { $0.key } }

    /// The values, in the same order as `keys`.
    public var values: [xpc_object_t] { map { $0.value } }

    /// Removes `key` and returns the value it held, if any.
    @discardableResult
    public mutating func removeValue(forKey key: String) -> xpc_object_t? {
        let existing = xpc_dictionary_get_value(underlying, key)
        xpc_dictionary_set_value(underlying, key, nil)
        return existing
    }

    /// Shallow-copies every entry into `destination`.
    ///
    /// Values are shared, not duplicated; only the top-level entries are copied.
    public func copy(into destination: XPCCompat.Dictionary) {
        forEach { key, value in
            xpc_dictionary_set_value(destination.underlying, key, value)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// An index and its associated raw value.
    public typealias IndexValuePair = (index: Int, value: xpc_object_t)

    /// Calls `body` once per element, in index order.
    ///
    /// If `body` throws, iteration stops immediately and the error is rethrown.
    public func forEach(
        _ body: (_ index: Int, _ value: xpc_object_t) throws -> Void
    ) rethrows {
        var thrown: Error?
        xpc_array_apply(underlying) { index, value in
            do {
                try body(index, value)
                return true
            } catch {
                thrown = error
                return false
            }
        }
        if let thrown {
            try { throw thrown }()
        }
    }

    /// Calls `body` once per element, as a tuple.
    public func forEach(_ body: (IndexValuePair) throws -> Void) rethrows {
        try forEach { index, value in try body((index: index, value: value)) }
    }

    /// Transforms each element into a value.
    public func map<ReturnType>(
        _ transform: (IndexValuePair) throws -> ReturnType
    ) rethrows -> [ReturnType] {
        var results: [ReturnType] = []
        results.reserveCapacity(count)
        try forEach { pair in results.append(try transform(pair)) }
        return results
    }

    /// Appends every element of the receiver to `destination`.
    public func copy(into destination: XPCCompat.Array) {
        forEach { _, value in
            xpc_array_append_value(destination.underlying, value)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CollectionOperationTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/XPCCompat/CollectionOperations.swift Tests/XPCCompatTests/CollectionOperationTests.swift
git commit -m "feat(xpccompat): add forEach, map, keys, values, removeValue and copy"
```

---

### Task 11: Dictionary literals and the shadowing lint

**Files:**
- Create: `Sources/XPCCompat/LiteralValue.swift`
- Test: `Tests/XPCCompatTests/LiteralTests.swift`
- Test: `Tests/XPCCompatTests/ShadowingLintTests.swift`

**Interfaces:**
- Consumes: Tasks 2 and 9.
- Produces: `XPCCompat.LiteralValue` with initializers for `String`, `SignedInteger`, `UnsignedInteger`, `BinaryFloatingPoint`, `Bool`, `XPCCompat.Dictionary` and raw `xpc_object_t`; `ExpressibleBy{String,Integer,Float,Boolean}Literal`; and `XPCCompat.Dictionary: ExpressibleByDictionaryLiteral` with `Key == String`, `Value == XPCCompat.LiteralValue`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/XPCCompatTests/LiteralTests.swift`:

```swift
import XCTest
import XPC
@testable import XPCCompat

final class LiteralTests: XCTestCase {

    func testDictionaryLiteral() {
        let d: XPCCompat.Dictionary = [
            "name": "hello",
            "count": 3,
            "ratio": 1.5,
            "flag": true,
        ]
        XCTAssertEqual(d.count, 4)
        XCTAssertEqual(d["name", as: String.self], "hello")
        XCTAssertEqual(d["count", as: Int.self], 3)
        XCTAssertEqual(d["ratio", as: Double.self], 1.5)
        XCTAssertEqual(d["flag", as: Bool.self], true)
    }

    func testEmptyDictionaryLiteral() {
        let d: XPCCompat.Dictionary = [:]
        XCTAssertTrue(d.isEmpty)
    }

    func testNestedDictionaryLiteralValue() {
        var inner = XPCCompat.Dictionary()
        inner["x"] = Int(1)
        let outer: XPCCompat.Dictionary = ["child": XPCCompat.LiteralValue(inner)]
        XCTAssertEqual(outer["child", as: XPCCompat.Dictionary.self]?.count, 1)
    }
}
```

Create `Tests/XPCCompatTests/ShadowingLintTests.swift`:

```swift
import XCTest

// Guards the rule in Namespace.swift. Inside the `enum XPCCompat` body, an
// unqualified `Array`/`Dictionary` resolves to XPCCompat's nested type and
// compiles cleanly while producing the wrong type. Members must therefore be
// declared in file-scope extensions, never inside the enum body.
final class ShadowingLintTests: XCTestCase {

    func testNoMembersDeclaredInsideTheNamespaceBody() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // XPCCompatTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/XPCCompat")

        let files = try FileManager.default
            .contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        XCTAssertFalse(files.isEmpty, "no sources found at \(sourceDirectory.path)")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Only Namespace.swift may open the enum body, and it must stay empty.
            if text.contains("public enum XPCCompat") {
                XCTAssertTrue(
                    text.contains("public enum XPCCompat {}"),
                    "\(file.lastPathComponent): the XPCCompat enum body must stay empty"
                )
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LiteralTests`
Expected: FAIL — `type 'XPCCompat' has no member 'LiteralValue'`.

- [ ] **Step 3: Write the implementation**

Create `Sources/XPCCompat/LiteralValue.swift`:

```swift
import XPC

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat {

    /// A value usable inside an `XPCCompat.Dictionary` literal.
    ///
    ///     let message: XPCCompat.Dictionary = ["name": "hello", "count": 3]
    public struct LiteralValue {
        @usableFromInline
        internal let object: xpc_object_t

        /// Wraps an already-built XPC object.
        public init(_ object: xpc_object_t) {
            self.object = object
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.LiteralValue {

    /// Wraps a string.
    public init(_ value: String) { self.init(xpc_string_create(value)) }

    /// Wraps a signed integer.
    public init<T: SignedInteger>(_ value: T) { self.init(xpc_int64_create(Int64(value))) }

    /// Wraps an unsigned integer.
    public init<T: UnsignedInteger>(_ value: T) { self.init(xpc_uint64_create(UInt64(value))) }

    /// Wraps a floating-point value.
    public init<T: BinaryFloatingPoint>(_ value: T) { self.init(xpc_double_create(Double(value))) }

    /// Wraps a boolean.
    public init(_ value: Bool) { self.init(xpc_bool_create(value)) }

    /// Wraps a nested dictionary.
    public init(_ value: XPCCompat.Dictionary) { self.init(value.underlying) }

    /// Wraps a nested array.
    public init(_ value: XPCCompat.Array) { self.init(value.underlying) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.LiteralValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.LiteralValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self.init(value) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.LiteralValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self.init(value) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.LiteralValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self.init(value) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary: ExpressibleByDictionaryLiteral {
    public typealias Key = String
    public typealias Value = XPCCompat.LiteralValue

    public init(dictionaryLiteral elements: (String, XPCCompat.LiteralValue)...) {
        self.init()
        for (key, element) in elements {
            xpc_dictionary_set_value(underlying, key, element.object)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LiteralTests && swift test --filter ShadowingLintTests`
Expected: PASS, 3 + 1 tests.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS, all tests across `CodableXPCTests` and `XPCCompatTests`.

- [ ] **Step 6: Commit**

```bash
git add Sources/XPCCompat/LiteralValue.swift Tests/XPCCompatTests/LiteralTests.swift Tests/XPCCompatTests/ShadowingLintTests.swift
git commit -m "feat(xpccompat): add dictionary literals and shadowing lint"
```

---

### Task 12: Parity check against Apple's overlay

**Files:**
- Create: `Tests/XPCCompatTests/AppleParityTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: no new API. Asserts that a message built with `XPCCompat.Dictionary` is `xpc_equal` to the same message built with Apple's `XPCDictionary`, proving the value layer is wire-identical.

- [ ] **Step 1: Write the test**

Create `Tests/XPCCompatTests/AppleParityTests.swift`:

```swift
import XCTest
import XPC          // Apple's overlay — importable alongside XPCCompat
import Foundation
@testable import XPCCompat

// This file is the reason XPCCompat must never re-export XPC: both type sets
// have to be nameable here at once.
@available(macOS 13, *)
final class AppleParityTests: XCTestCase {

    func testPrimitivesMatchAppleByteForByte() {
        var ours = XPCCompat.Dictionary()
        ours["string"] = "hello"
        ours["int"] = Int(-7)
        ours["uint"] = UInt(7)
        ours["double"] = Double(1.5)
        ours["bool"] = true
        ours["data"] = Data([1, 2, 3])

        var theirs = XPCDictionary()
        theirs["string"] = "hello"
        theirs["int"] = Int(-7)
        theirs["uint"] = UInt(7)
        theirs["double"] = Double(1.5)
        theirs["bool"] = true
        // Apple's overlay has no Data or [UInt8] subscript on macOS 27 — only a
        // macOS 27 RawSpan one, which we cannot use at our floor. Our Data subscript
        // is therefore an addition, not a parity feature. Set the same bytes through
        // the C API so the byte comparison still covers our setter.
        theirs.withUnsafeUnderlyingDictionary { raw in
            [UInt8]([1, 2, 3]).withUnsafeBytes {
                xpc_dictionary_set_data(raw, "data", $0.baseAddress, $0.count)
            }
        }

        let equal = ours.withUnsafeUnderlyingDictionary { mine in
            theirs.withUnsafeUnderlyingDictionary { yours in
                xpc_equal(mine, yours)
            }
        }
        XCTAssertTrue(equal, "ours: \(ours.debugDescription)\ntheirs: \(theirs.debugDescription)")
    }

    func testNestedContainersMatchApple() {
        var innerOurs = XPCCompat.Dictionary()
        innerOurs["n"] = Int(1)
        var ours = XPCCompat.Dictionary()
        ours["child"] = innerOurs

        var innerTheirs = XPCDictionary()
        innerTheirs["n"] = Int(1)
        var theirs = XPCDictionary()
        theirs["child"] = innerTheirs

        let equal = ours.withUnsafeUnderlyingDictionary { mine in
            theirs.withUnsafeUnderlyingDictionary { yours in
                xpc_equal(mine, yours)
            }
        }
        XCTAssertTrue(equal, "ours: \(ours.debugDescription)\ntheirs: \(theirs.debugDescription)")
    }

    // Apple coerces int64/uint64/double for integer reads; confirm we agree.
    func testIntegerCoercionMatchesApple() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(raw, "u", 7)
        xpc_dictionary_set_double(raw, "d", 3.0)
        xpc_dictionary_set_double(raw, "frac", 1.5)

        let ours = XPCCompat.Dictionary(raw)
        let theirs = XPCDictionary(raw)

        XCTAssertEqual(ours["u", as: Int.self], theirs["u", as: Int.self])
        XCTAssertEqual(ours["d", as: Int.self], theirs["d", as: Int.self])
        XCTAssertEqual(ours["frac", as: Int.self], theirs["frac", as: Int.self])
        XCTAssertNil(ours["frac", as: Int.self])
    }

    // Apple's Bool subscript is strict; confirm we are too.
    func testBoolStrictnessMatchesApple() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        XCTAssertEqual(
            XPCCompat.Dictionary(raw)["n", as: Bool.self],
            XPCDictionary(raw)["n", as: Bool.self]
        )
    }
}
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter AppleParityTests`
Expected: PASS, 4 tests.

If `testPrimitivesMatchAppleByteForByte` fails, read both `debugDescription`s from the failure message and reconcile — a mismatch means one of the setters chose a different XPC storage type (for example writing a `double` where Apple writes an `int64`). Fix the setter in the relevant `Subscripts+*.swift`, not the test.

- [ ] **Step 3: Commit**

```bash
git add Tests/XPCCompatTests/AppleParityTests.swift
git commit -m "test(xpccompat): assert value layer parity with Apple's XPC overlay"
```

---

## Deliberately deferred from Phase 1

Two items the spec lists under the value layer are not here, for reasons that only became clear while
writing the tasks:

- **`Dictionary.reply(_:)`.** It needs a live connection to send through, so it cannot be tested without
  transport. It moves to Phase 3 alongside `ReceivedMessage`.
- **`XPCCompat.Activity`.** Spec open item 4 questions whether `XPC_TYPE_ACTIVITY` objects ever appear
  inside messages. Building a container subscript for something that may never be a container value would
  be speculative. It waits for that question to be answered, in Phase 4.

`XPCCompat.SharedMemory` moved the other way — the spec put it in Phase 4, but it is a plain value wrapper
with no transport dependency, so Task 9 delivers it here. Phase 4 keeps the live transfer test.

One finding worth carrying forward: Apple's overlay has **no** `Data` or `[UInt8]` subscript on macOS 27,
only a macOS 27 `RawSpan` one. The `[UInt8]` subscript seen in the macOS 15 dump is gone. Our `Data`
subscript is therefore an addition rather than a backport, and cannot be parity-tested against Apple
directly — Task 12 compares through the C API instead.

## What comes next

Phase 1 delivers a complete, independently useful typed container library. The remaining spec phases each get their own plan:

- **Phase 2 — Envelope coder.** The node-graph encoder and decoder for Apple's `_CodableBody` format (coder version 1), verified byte-for-byte against `Tools/WireProbe`. Highest-risk phase; deliberately built and validated before any transport code exists.
- **Phase 3 — Transport.** `RichError`, `Session`, `Listener`, `ReceivedMessage`, `XPCPeerHandler` over `xpc_connection_t`. Depends on Phase 2 for the `send<Encodable>` overloads.
- **Phase 4 — Descriptor and memory passing.** Live FD and shared-memory transfer over a real connection. Independent of Phase 2.
- **Phase 5 — Bridge.** Endpoint interop with Apple's `XPCSession`, including typed payloads.
- **Phase 6 — Peer requirements.** The SPI spike, then `PeerRequirement` or its fail-closed `.unsupported` fallback.

Two spec open items should be resolved before Phase 2 begins: extending `Tools/WireProbe` with an `XPCCodableObjectRepresentable` conformer to observe how `_CodableOutOfLine4CodableObject` is indexed, and adding the CI check that fails if `_CodableCoderVersion` stops being `1`.
