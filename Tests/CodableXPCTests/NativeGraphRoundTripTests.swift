#if canImport(Darwin)
import XCTest
import XPC
@testable import CodableXPC

private struct Scalars: Codable, Equatable { let a: Int; let b: String }
private struct Optionals: Codable, Equatable { let present: String?; let absent: String? }
private struct Nested: Codable, Equatable {
    let inner: Scalars; let list: [Int]; let map: [String: Int]
}
private enum Choice: String, Codable, Equatable { case one, two }

/// Round trips through the native `xpc_object_t` graph.
///
/// This module had two tests for sixteen hundred lines, and a sweep of ordinary
/// Swift values found three defects on the first pass — two of them silent or
/// fatal rather than reported. The cases that found them are marked.
final class NativeGraphRoundTripTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(
        _ value: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let object = try XPCEncoder().encode(value)
        let back = try XPCDecoder().decode(T.self, from: object)
        XCTAssertEqual(back, value, message, file: file, line: line)
    }

    // MARK: values

    func testIntegerEdges() throws {
        try roundTrip(Int.max); try roundTrip(Int.min)
        try roundTrip(Int64.min); try roundTrip(UInt64.max)
        try roundTrip(Int8(-128)); try roundTrip(UInt8(255))
        try roundTrip(Int16.min); try roundTrip(UInt32.max)
    }

    func testFloatingPointEdges() throws {
        try roundTrip(Double.pi)
        try roundTrip(Float(-0.5))
        try roundTrip(Double.infinity)
        try roundTrip(Double.leastNonzeroMagnitude)
    }

    func testStringsAndBlobs() throws {
        try roundTrip("hello"); try roundTrip("")
        try roundTrip("한글 🎉 combining\u{0301}")
        try roundTrip(Data([0, 1, 2, 255])); try roundTrip(Data())
    }

    func testDateAndUUID() throws {
        try roundTrip(Date(timeIntervalSince1970: 1_700_000_000.123456))
        try roundTrip(UUID(uuidString: "12345678-1234-1234-1234-123456789012")!)
    }

    // MARK: shapes

    func testStructsContainersAndEnums() throws {
        try roundTrip(Scalars(a: -1, b: "x"))
        try roundTrip(Nested(inner: Scalars(a: 1, b: "y"), list: [1, 2, 3], map: ["k": 9]))
        try roundTrip(Choice.two)
        try roundTrip([Scalars(a: 1, b: "a"), Scalars(a: 2, b: "b")])
        try roundTrip([Int]()); try roundTrip([String: Int]())
        try roundTrip([[1, 2], [3]])
        try roundTrip(["x": ["y": true]])
    }

    /// Found a defect. A null in a *keyed* container was rejected before
    /// `Optional` could see it, so `[String: Int?]` failed while `[Int?]` — read
    /// straight out of the array — had always worked.
    func testOptionalsInBothContainerKinds() throws {
        try roundTrip(Optionals(present: "here", absent: nil))
        try roundTrip([1, nil, 3] as [Int?])
        try roundTrip(["a": nil, "b": 2] as [String: Int?], "a null value in a keyed container")
        try roundTrip(nil as Int?)
    }

    // MARK: what the format cannot carry

    /// Found a defect. `xpc_string_create` takes a C string and stops at the
    /// first NUL, so this used to encode and come back short — no error, just
    /// less data.
    func testAnEmbeddedNulIsRefusedRatherThanTruncated() {
        XCTAssertThrowsError(try XPCEncoder().encode("before\u{0}after")) { error in
            guard case EncodingError.invalidValue = error else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
        // Nested, so the coding path is what points at it.
        XCTAssertThrowsError(try XPCEncoder().encode(["key": "a\u{0}b"]))
    }

    /// Found a defect, and the worst kind: this used to trap. An xpc date is
    /// nanoseconds in an `Int64` — about ±292 years around 1970 — and `Date`
    /// hands out two constants far outside that.
    func testADateBeyondTheRangeThrowsRatherThanTrapping() {
        for out in [Date.distantPast, Date.distantFuture] {
            XCTAssertThrowsError(try XPCEncoder().encode(out), "\(out)") { error in
                guard case EncodingError.invalidValue = error else {
                    return XCTFail("expected invalidValue, got \(error)")
                }
            }
        }
        // The boundary itself still works.
        XCTAssertNoThrow(try XPCEncoder().encode(Date(timeIntervalSince1970: 9_000_000_000)))
    }

    // MARK: the graph is native

    /// The point of this coder: the output is an xpc object tree, not a blob.
    func testTheEncodedValueIsARealXPCGraph() throws {
        let object = try XPCEncoder().encode(Nested(inner: Scalars(a: 7, b: "s"),
                                                    list: [1, 2], map: ["k": 3]))
        XCTAssertEqual(xpc_get_type(object), XPC_TYPE_DICTIONARY)

        let inner = try XCTUnwrap(xpc_dictionary_get_value(object, "inner"))
        XCTAssertEqual(xpc_get_type(inner), XPC_TYPE_DICTIONARY)
        XCTAssertEqual(xpc_dictionary_get_int64(inner, "a"), 7)

        let list = try XCTUnwrap(xpc_dictionary_get_value(object, "list"))
        XCTAssertEqual(xpc_get_type(list), XPC_TYPE_ARRAY)
        XCTAssertEqual(xpc_array_get_count(list), 2)
    }
}
#endif
