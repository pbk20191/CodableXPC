#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCActors

/// Proves the `@_silgen_name` binding to Apple's `XPCDictionary.encode/decode(...withUserInfo:)`
/// actually links and runs -- the load-bearing assumption before routing `Payload` through it.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class AppleCoderProbeTests: XCTestCase {

    private struct Value: Codable, Equatable {
        let n: Int
        let s: String
        let xs: [Int]
    }

    func testAppleCoderRoundTripsAValue() throws {
        let dictionary = XPCDictionary(xpc_dictionary_create(nil, nil, 0))
        let value = Value(n: 42, s: "hi", xs: [1, 2, 3])

        try dictionary.appleEncode(value, forKey: "payload", withUserInfo: [:])
        let back: Value = try dictionary.appleDecode(
            as: Value.self, forKey: "payload", withUserInfo: [:])

        XCTAssertEqual(back, value)
    }
}
#endif
