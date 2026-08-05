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
