import XCTest
import XPC
@testable import XPCCompat

final class LiteralTests: XCTestCase {

    func testDictionaryLiteral() {
        let d: XPCCompat.Dictionary = [
            "name": "hello",
            "count": 3,
            "ratio": 1.5,
            "flag": true,
        ]
        XCTAssertEqual(d.count, 4)
        XCTAssertEqual(d["name", as: String.self], "hello")
        XCTAssertEqual(d["count", as: Int.self], 3)
        XCTAssertEqual(d["ratio", as: Double.self], 1.5)
        XCTAssertEqual(d["flag", as: Bool.self], true)
    }

    func testEmptyDictionaryLiteral() {
        let d: XPCCompat.Dictionary = [:]
        XCTAssertTrue(d.isEmpty)
    }

    func testNestedDictionaryLiteralValue() {
        var inner = XPCCompat.Dictionary()
        inner["x"] = Int(1)
        let outer: XPCCompat.Dictionary = ["child": XPCCompat.LiteralValue(inner)]
        XCTAssertEqual(outer["child", as: XPCCompat.Dictionary.self]?.count, 1)
    }
}
