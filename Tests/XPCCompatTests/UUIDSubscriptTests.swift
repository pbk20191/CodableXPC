import XCTest
import XPC
import Foundation
@testable import XPCCompat

// FileDescriptor subscripts are tested in XPCCompatSystemTests: they live in the
// separate XPCCompatSystem target so that XPCCompat never links libswiftSystem.
final class UUIDSubscriptTests: XCTestCase {

    private let sample: uuid_t = (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)

    private func bytesEqual(_ lhs: uuid_t, _ rhs: uuid_t) -> Bool {
        withUnsafeBytes(of: lhs) { a in withUnsafeBytes(of: rhs) { b in a.elementsEqual(b) } }
    }

    func testUUIDRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["id"] = sample
        let read = d["id", as: uuid_t.self]
        XCTAssertNotNil(read)
        XCTAssertTrue(bytesEqual(sample, read!))
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
        d["id"] = nil as uuid_t?
        XCTAssertEqual(d.count, 0)
    }

    // The Array uuid_t getter has its own bounds check and 16-byte copy.

    func testArrayUUIDRoundTrip() throws {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_int64_create(0))
        var a = XPCCompat.Array(raw)
        a[0] = sample
        let read = try XCTUnwrap(a[0, as: uuid_t.self])
        XCTAssertTrue(bytesEqual(sample, read), "all 16 bytes must survive the round trip")
    }

    func testArrayUUIDWrongTypeIsNil() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_int64_create(1))
        XCTAssertNil(XPCCompat.Array(raw)[0, as: uuid_t.self])
    }

    func testArrayUUIDOutOfRangeIsNil() {
        let a = XPCCompat.Array()
        XCTAssertNil(a[0, as: uuid_t.self])
        XCTAssertNil(a[-1, as: uuid_t.self])
    }

    func testArrayUUIDDefaultOnOutOfRangeAndWrongType() {
        let fallback: uuid_t = (9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9)
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_int64_create(1))
        let a = XPCCompat.Array(raw)
        XCTAssertTrue(bytesEqual(a[0, as: uuid_t.self, default: fallback], fallback))
        XCTAssertTrue(bytesEqual(a[7, as: uuid_t.self, default: fallback], fallback))
    }
}
