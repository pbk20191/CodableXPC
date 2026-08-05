import XCTest
import XPC
@testable import XPCCompat

final class BoolSubscriptTests: XCTestCase {

    func testRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["flag"] = true
        XCTAssertEqual(d["flag"], true)
        d["flag"] = false
        XCTAssertEqual(d["flag"], false)
    }

    func testMissingKeyIsNil() {
        let d = XPCCompat.Dictionary()
        let value: Bool? = d["absent"]
        XCTAssertNil(value)
    }

    // Apple's Bool subscript accepts only XPC_TYPE_BOOL. An int64 0/1 must read as nil.
    func testIntegerDoesNotCoerceToBool() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        let d = XPCCompat.Dictionary(raw)
        let value: Bool? = d["n"]
        XCTAssertNil(value, "Bool subscript must not coerce int64 1 to true")
    }

    func testDefaultUsedForMissingKey() {
        let d = XPCCompat.Dictionary()
        XCTAssertTrue(d["absent", default: true])
    }

    // The default also covers a present-but-wrong-typed value.
    func testDefaultUsedForWrongType() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(raw, "s", "not a bool")
        let d = XPCCompat.Dictionary(raw)
        XCTAssertTrue(d["s", default: true])
    }

    func testDefaultAutoclosureIsLazy() {
        var evaluated = false
        func makeDefault() -> Bool { evaluated = true; return false }
        var d = XPCCompat.Dictionary()
        d["flag"] = true
        _ = d["flag", default: makeDefault()]
        XCTAssertFalse(evaluated, "default must not be evaluated when the key resolves")
    }

    // Assigning nil removes the key on every subscript. This is a deliberate
    // divergence: Apple's Bool setter silently ignores nil.
    func testAssigningNilRemovesKey() {
        var d = XPCCompat.Dictionary()
        d["flag"] = true
        d["flag"] = Bool?.none
        XCTAssertEqual(d.count, 0, "nil assignment must remove the key")
    }

    func testArrayRoundTrip() {
        var a = XPCCompat.Array()
        a.withUnsafeUnderlyingArray { xpc_array_append_value($0, xpc_bool_create(false)) }
        a[0] = true
        XCTAssertEqual(a[0], true)
    }

    func testArrayOutOfBoundsIsNil() {
        let a = XPCCompat.Array()
        let value: Bool? = a[5]
        XCTAssertNil(value)
    }
}
