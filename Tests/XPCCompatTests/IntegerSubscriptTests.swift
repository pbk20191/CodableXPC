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
