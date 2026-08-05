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

        XCTAssertEqual(ours["u", as: Int.self], theirs["u", as: Int.self])
        XCTAssertEqual(ours["d", as: Int.self], theirs["d", as: Int.self])
        XCTAssertEqual(ours["frac", as: Int.self], theirs["frac", as: Int.self])
        XCTAssertNil(ours["frac", as: Int.self])
    }

    // Apple's Bool subscript is strict; confirm we are too.
    func testBoolStrictnessMatchesApple() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        XCTAssertEqual(
            XPCCompat.Dictionary(raw)["n", as: Bool.self],
            XPCDictionary(raw)["n", as: Bool.self]
        )
    }
}
