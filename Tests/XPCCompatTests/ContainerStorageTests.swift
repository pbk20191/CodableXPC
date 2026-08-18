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
