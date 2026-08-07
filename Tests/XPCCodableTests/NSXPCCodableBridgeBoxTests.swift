import XCTest
@testable import XPCCodable

private struct Person: Codable, Equatable {
    let name: String
    let age: Int
}

final class NSXPCCodableBridgeBoxTests: XCTestCase {

    // MARK: value round trip

    func testRoundTripsAStruct() throws {
        let person = Person(name: "Ada", age: 36)
        XCTAssertEqual(try NSXPCCodableBridgeBox(person).decode(Person.self), person)
    }

    func testRoundTripsTopLevelFragments() throws {
        // The whole reason this box uses JSON. PropertyListEncoder rejects every one
        // of these with "the data couldn't be written because it isn't in the correct
        // format", which a generated XPC shim would hit on its first String argument.
        XCTAssertEqual(try NSXPCCodableBridgeBox("hello").decode(String.self), "hello")
        XCTAssertEqual(try NSXPCCodableBridgeBox(42).decode(Int.self), 42)
        XCTAssertEqual(try NSXPCCodableBridgeBox([1, 2, 3]).decode([Int].self), [1, 2, 3])
        XCTAssertNil(try NSXPCCodableBridgeBox(Int?.none).decode(Int?.self))
    }

    func testDecodingTheWrongTypeThrows() throws {
        let box = try NSXPCCodableBridgeBox(Person(name: "Ada", age: 36))
        XCTAssertThrowsError(try box.decode([String].self))
    }

    func testHonoursACallerSuppliedCoderPair() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        struct Wrapper: Codable, Equatable { let userName: String }
        let box = try NSXPCCodableBridgeBox(Wrapper(userName: "ada"), encoder: encoder)
        XCTAssertTrue(String(decoding: try XCTUnwrap(box.payload), as: UTF8.self).contains("user_name"))
        XCTAssertEqual(try box.decode(Wrapper.self, decoder: decoder), Wrapper(userName: "ada"))
    }

    // MARK: ObjC identity

    func testObjCNameIsPinned() {
        // Not the mangled Swift name. An archive embeds this string, so it has to
        // survive a module rename -- and it can only be pinned because the class is
        // not generic.
        XCTAssertEqual(NSStringFromClass(NSXPCCodableBridgeBox.self), "NSXPCCodableBridgeBox")
        XCTAssertTrue(NSXPCCodableBridgeBox.self === NSClassFromString("NSXPCCodableBridgeBox"))
    }

    func testDefaultEncodingIsReproducible() throws {
        // Without .sortedKeys this is flaky rather than wrong: JSONEncoder emits keys
        // in Swift Dictionary order, which is seeded per process, so the same value
        // can encode to {"name":…,"age":…} in one run and {"age":…,"name":…} in the
        // next. A caller who caches or diffs on the bytes needs this to hold.
        let a = try NSXPCCodableBridgeBox(Person(name: "Ada", age: 36))
        let b = try NSXPCCodableBridgeBox(Person(name: "Ada", age: 36))
        XCTAssertEqual(a.payload, b.payload)
        XCTAssertEqual(String(decoding: try XCTUnwrap(a.payload), as: UTF8.self),
                       #"{"age":36,"name":"Ada"}"#)
    }

    func testEqualityIsIdentityNotPayload() throws {
        // Two boxes holding the same value are NOT equal, on purpose -- see the note
        // in NSXPCCodableBridgeBox. Byte equality would be right only until someone passed a
        // custom encoder.
        let a = try NSXPCCodableBridgeBox(Person(name: "Ada", age: 36))
        let b = try NSXPCCodableBridgeBox(Person(name: "Ada", age: 36))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, a)
    }

    // MARK: NSKeyedArchiver

    func testSurvivesSecureKeyedArchiving() throws {
        let person = Person(name: "Ada", age: 36)
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: try NSXPCCodableBridgeBox(person), requiringSecureCoding: true)
        let box = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: NSXPCCodableBridgeBox.self, from: data))
        XCTAssertEqual(try box.decode(Person.self), person)
    }

    func testArchiveEmbedsThePinnedName() throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: try NSXPCCodableBridgeBox(Person(name: "Ada", age: 36)),
            requiringSecureCoding: true)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        let names = objects.compactMap { ($0 as? [String: Any])?["$classname"] as? String }
        XCTAssertTrue(names.contains("NSXPCCodableBridgeBox"),
                      "expected the pinned name in the archive, got \(names)")
    }
}
