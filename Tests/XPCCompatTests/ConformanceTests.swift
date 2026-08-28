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

    /// A dictionary key is bytes, not text. libxpc never UTF-8-validates one, so a
    /// peer that sets a key through the C API can put 0xFF in it, and
    /// `xpc_copy_description` prints it back verbatim. Describing that dictionary has
    /// to produce a string, not end the process -- `debugDescription` is what you
    /// reach for *after* something has already gone wrong.
    ///
    /// This is an assertion the test runner cannot survive failing: the way it fails
    /// is a trap, so a regression here shows up as the whole XPCCompatTests bundle
    /// dying rather than as a red case.
    func testDebugDescriptionSurvivesANonUTF8Key() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        let key: [CChar] = [CChar(bitPattern: 0xFF), CChar(bitPattern: 0xFE), 0]
        key.withUnsafeBufferPointer { xpc_dictionary_set_int64(raw, $0.baseAddress!, 1) }

        let text = XPCCompat.Dictionary(raw).debugDescription

        XCTAssertTrue(text.contains("dictionary"), "got: \(text)")
        // The invalid bytes are repaired rather than dropped or fatal.
        XCTAssertTrue(text.contains("\u{FFFD}"), "invalid bytes should decode to U+FFFD; got: \(text)")
    }

    /// The valid path still describes what it was given, and still frees what it was
    /// given -- the buffer is adopted by CoreFoundation on that path and freed by hand
    /// on the other, so exercising both many times is what would surface a leak or a
    /// double free.
    func testDescribingRepeatedlyIsStable() {
        for _ in 0..<5_000 {
            XCTAssertTrue(makeDict(3).debugDescription.contains("dictionary"))
        }

        let raw = xpc_dictionary_create(nil, nil, 0)
        let key: [CChar] = [CChar(bitPattern: 0xC3), 0]   // a truncated 2-byte sequence
        key.withUnsafeBufferPointer { xpc_dictionary_set_int64(raw, $0.baseAddress!, 1) }
        let invalid = XPCCompat.Dictionary(raw)
        for _ in 0..<5_000 {
            XCTAssertTrue(invalid.debugDescription.contains("dictionary"))
        }
    }
}
