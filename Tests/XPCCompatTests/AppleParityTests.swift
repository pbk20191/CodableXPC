import XCTest
import XPC          // Apple's overlay — importable alongside XPCCompat
import Foundation
@testable import XPCCompat

// This file is the reason XPCCompat must never re-export XPC: both type sets
// have to be nameable here at once.
@available(macOS 13, *)
final class AppleParityTests: XCTestCase {

    func testPrimitivesMatchAppleByteForByte() {
        var ours = XPCCompat.Dictionary()
        ours["string"] = "hello"
        ours["int"] = Int(-7)
        ours["uint"] = UInt(7)
        ours["double"] = Double(1.5)
        ours["bool"] = true
        ours["data"] = Data([1, 2, 3])

        var theirs = XPCDictionary()
        theirs["string"] = "hello"
        theirs["int"] = Int(-7)
        theirs["uint"] = UInt(7)
        theirs["double"] = Double(1.5)
        theirs["bool"] = true
        // Apple's overlay has no Data or [UInt8] subscript on macOS 27 — only a
        // macOS 27 RawSpan one, which we cannot use at our floor. Our Data subscript
        // is therefore an addition, not a parity feature. Set the same bytes through
        // the C API so the byte comparison still covers our setter.
        theirs.withUnsafeUnderlyingDictionary { raw in
            [UInt8]([1, 2, 3]).withUnsafeBytes {
                xpc_dictionary_set_data(raw, "data", $0.baseAddress, $0.count)
            }
        }

        let equal = ours.withUnsafeUnderlyingDictionary { mine in
            theirs.withUnsafeUnderlyingDictionary { yours in
                xpc_equal(mine, yours)
            }
        }
        XCTAssertTrue(equal, "ours: \(ours.debugDescription)\ntheirs: \(theirs.debugDescription)")
    }

    func testNestedContainersMatchApple() {
        var innerOurs = XPCCompat.Dictionary()
        innerOurs["n"] = Int(1)
        var ours = XPCCompat.Dictionary()
        ours["child"] = innerOurs

        var innerTheirs = XPCDictionary()
        innerTheirs["n"] = Int(1)
        var theirs = XPCDictionary()
        theirs["child"] = innerTheirs

        let equal = ours.withUnsafeUnderlyingDictionary { mine in
            theirs.withUnsafeUnderlyingDictionary { yours in
                xpc_equal(mine, yours)
            }
        }
        XCTAssertTrue(equal, "ours: \(ours.debugDescription)\ntheirs: \(theirs.debugDescription)")
    }

    // Apple coerces int64/uint64/double for integer reads; confirm we agree.
    func testIntegerCoercionMatchesApple() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(raw, "u", 7)
        xpc_dictionary_set_double(raw, "d", 3.0)
        xpc_dictionary_set_double(raw, "frac", 1.5)

        let ours = XPCCompat.Dictionary(raw)
        let theirs = XPCDictionary(raw)

        // Cross-comparisons alone would pass on mutual nil, so anchor each key
        // absolutely as well as against Apple.
        XCTAssertEqual(ours["u", as: Int.self], theirs["u", as: Int.self])
        XCTAssertEqual(ours["u", as: Int.self], 7, "uint64 storage must coerce to Int")
        XCTAssertEqual(theirs["u", as: Int.self], 7)

        XCTAssertEqual(ours["d", as: Int.self], theirs["d", as: Int.self])
        XCTAssertEqual(ours["d", as: Int.self], 3, "a whole double must coerce to Int")
        XCTAssertEqual(theirs["d", as: Int.self], 3)

        // A fractional double is the one that must be nil, on both sides.
        XCTAssertEqual(ours["frac", as: Int.self], theirs["frac", as: Int.self])
        XCTAssertNil(ours["frac", as: Int.self])
        XCTAssertNil(theirs["frac", as: Int.self])
    }

    // Apple's Bool subscript is strict; confirm we are too.
    func testBoolStrictnessMatchesApple() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        xpc_dictionary_set_bool(raw, "b", true)

        let ours = XPCCompat.Dictionary(raw)
        let theirs = XPCDictionary(raw)

        // Strictness: an int64 1 is not a Bool. Both must say nil — and asserting the
        // absolute value matters, because equal-and-both-nil is also what a subscript
        // that never worked at all would produce.
        XCTAssertEqual(ours["n", as: Bool.self], theirs["n", as: Bool.self])
        XCTAssertNil(ours["n", as: Bool.self], "an int64 1 must not read as Bool")
        XCTAssertNil(theirs["n", as: Bool.self])

        // Positive control: a real xpc_bool does read, on both sides.
        XCTAssertEqual(ours["b", as: Bool.self], theirs["b", as: Bool.self])
        XCTAssertEqual(ours["b", as: Bool.self], true, "a real xpc_bool must read as true")
        XCTAssertEqual(theirs["b", as: Bool.self], true)
    }
}
