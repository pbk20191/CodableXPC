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

    // xpc_dictionary_get_data reports empty Data exactly as it reports "nothing here":
    // null base, zero length. The getter has to re-read the raw value to tell them
    // apart, so both the empty-Data path and the wrong-type path need their own tests.

    func testWithUnsafeBytesOnEmptyDataCallsBodyWithAnEmptyBuffer() {
        var d = XPCCompat.Dictionary()
        d["blob"] = Data()

        var bodyRan = false
        let count = d.withUnsafeBytes(forKey: "blob") { buffer -> Int in
            bodyRan = true
            return buffer.count
        }
        XCTAssertTrue(bodyRan, "empty Data is present, so body must run")
        XCTAssertEqual(count, 0)
    }

    func testWithUnsafeBytesReturnsNilForWrongType() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)

        var bodyRan = false
        let result = XPCCompat.Dictionary(raw).withUnsafeBytes(forKey: "n") { _ -> Int in
            bodyRan = true
            return 1
        }
        XCTAssertNil(result)
        XCTAssertFalse(bodyRan)
    }

    func testDataWrongTypeIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        xpc_dictionary_set_string(raw, "s", "not data")
        let d = XPCCompat.Dictionary(raw)
        XCTAssertNil(d["n", as: Data.self])
        XCTAssertNil(d["s", as: Data.self])
    }

    func testDataMissingKeyIsNil() {
        XCTAssertNil(XPCCompat.Dictionary()["absent", as: Data.self])
    }

    func testArrayStringRoundTrip() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_string_create(""))
        var a = XPCCompat.Array(raw)
        a[0] = "abc"
        XCTAssertEqual(a[0, as: String.self], "abc")
    }

    func testArrayDataRoundTrip() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_bool_create(false))
        var a = XPCCompat.Array(raw)
        a[0] = Data([9, 8, 7])
        XCTAssertEqual(a[0, as: Data.self], Data([9, 8, 7]))
    }

    // The Array getter's empty-Data branch: bounds are already checked by the time it
    // runs, so what it actually disambiguates is a wrongly-typed element from real
    // empty Data. Both outcomes need asserting.
    func testArrayEmptyData() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_bool_create(false))
        var a = XPCCompat.Array(raw)
        a[0] = Data()
        XCTAssertEqual(a[0, as: Data.self], Data(), "empty Data must read back as empty, not nil")
    }

    func testArrayDataWrongTypeIsNil() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_int64_create(1))
        xpc_array_append_value(raw, xpc_string_create("not data"))
        let a = XPCCompat.Array(raw)
        XCTAssertNil(a[0, as: Data.self])
        XCTAssertNil(a[1, as: Data.self])
    }

    func testArrayDataOutOfRangeIsNil() {
        let a = XPCCompat.Array()
        XCTAssertNil(a[0, as: Data.self])
        XCTAssertNil(a[-1, as: Data.self])
    }
}
