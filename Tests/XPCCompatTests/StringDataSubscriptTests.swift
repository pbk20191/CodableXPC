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
