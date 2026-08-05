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
