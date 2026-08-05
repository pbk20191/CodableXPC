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
