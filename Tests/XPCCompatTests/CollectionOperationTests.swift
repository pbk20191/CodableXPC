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

    // `keys` and `values` are documented as being in the same order as each other.
    // Iteration order itself is whatever xpc_dictionary_apply yields and is not
    // specified, so this pins the pairing rather than a particular order: element i
    // of `keys` and element i of `values` must be the same entry a single forEach
    // pass sees at position i.
    func testKeysAndValuesAgree() throws {
        let d = sampleDictionary()
        XCTAssertEqual(Swift.Set(d.keys), ["a", "b", "c"])
        XCTAssertEqual(d.values.count, 3)

        var expectedKeys: [String] = []
        var expectedValues: [xpc_object_t] = []
        d.forEach { key, value in
            expectedKeys.append(key)
            expectedValues.append(value)
        }

        let keys = d.keys
        let values = d.values
        XCTAssertEqual(keys, expectedKeys)
        XCTAssertEqual(keys.count, values.count)

        for (index, (key, value)) in zip(keys, values).enumerated() {
            XCTAssertEqual(key, expectedKeys[index], "keys[\(index)] out of step")
            XCTAssertTrue(
                xpc_equal(value, expectedValues[index]),
                "values[\(index)] does not pair with keys[\(index)]"
            )
            // And the pair really is the entry stored under that key.
            let stored = try XCTUnwrap(d[key, as: xpc_object_t.self])
            XCTAssertTrue(
                xpc_equal(value, stored),
                "values[\(index)] is not the value stored under \(key)"
            )
        }
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

    // removeValue(forKey:) is non-mutating, as in Apple's overlay: nothing in the
    // struct changes, only the C object behind it. `let` here is the assertion — it
    // would not compile if the method were marked `mutating`.
    func testRemoveValueReturnsOldValueAndRemovesKey() {
        let d = sampleDictionary()
        let removed = d.removeValue(forKey: "a")
        XCTAssertNotNil(removed)
        XCTAssertEqual(d.count, 2)
        XCTAssertNil(d["a", as: Int.self])
    }

    func testRemoveValueForMissingKeyIsNil() {
        let d = sampleDictionary()
        XCTAssertNil(d.removeValue(forKey: "zzz"))
        XCTAssertEqual(d.count, 3)
    }

    // copy(into:) is the escape hatch from reference semantics.
    func testCopyIntoProducesIndependentDictionary() throws {
        var source = sampleDictionary()
        let child = XPCCompat.Dictionary()
        source["child"] = child

        var destination = XPCCompat.Dictionary()
        source.copy(into: destination)
        XCTAssertEqual(destination.count, 4)

        // Top level is independent: adding to one does not touch the other.
        destination["d"] = Int(4)
        XCTAssertEqual(source.count, 4, "copy must be independent")

        // But the copy is shallow: nested values are shared, not duplicated. The child
        // is the same xpc object on both sides, so mutating it is visible through both.
        let sourceChild = try XCTUnwrap(source["child", as: xpc_object_t.self])
        let destinationChild = try XCTUnwrap(destination["child", as: xpc_object_t.self])
        XCTAssertTrue(
            xpc_equal(sourceChild, destinationChild),
            "copy(into:) is documented as shallow: the child must be the same object"
        )

        var mutableChild = try XCTUnwrap(destination["child", as: XPCCompat.Dictionary.self])
        mutableChild["added"] = Int(1)
        XCTAssertEqual(
            source["child", as: XPCCompat.Dictionary.self]?.count, 1,
            "the shared child must be visible as mutated through the source too"
        )
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
