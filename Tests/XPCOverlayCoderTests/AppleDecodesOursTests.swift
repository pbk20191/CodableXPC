#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCOverlayCoder

private struct Scalars: Codable, Equatable {
    let flag: Bool
    let small: Int8
    let wide: UInt32
    let name: String
    let ratio: Double
}
private struct Inner: Codable, Equatable { let value: Int }
private struct Outer: Codable, Equatable {
    let inner: Inner
    let list: [Int]
    let optional: String?
}
private struct WithData: Codable, Equatable {
    let label: String
    let blob: Data
}

/// The mirror of `AppleRoundTripTests`: there, Apple encoded and we decoded. Here
/// we encode and **Apple decodes**, by handing the listener a typed message
/// handler so the overlay's own decoder runs on our bytes.
///
/// Passing means the encoder is byte-compatible in the only sense that matters.
@available(macOS 15, macCatalyst 18, *)
final class AppleDecodesOursTests: XCTestCase {

    private final class Box<T>: @unchecked Sendable {
        var value: T?
        var failure: String?
    }

    /// Build an envelope by hand from our encoder's output and send it raw.
    private func send<T: Codable & Equatable>(_ value: T, expecting: T.Type) throws -> T? {
        let encoded = try XPCOverlayEncoder().encode(value)

        let arrived = XCTestExpectation(description: "Apple decoded it")
        let box = Box<T>()

        let listener = XPCListener(targetQueue: nil, options: .inactive) { request in
            // The typed overload: Apple's decoder runs here, not ours.
            request.accept { (message: T) -> (any Encodable)? in
                box.value = message
                arrived.fulfill()
                return nil
            }
        }
        try listener.activate()
        defer { listener.cancel() }

        let session = try XPCSession(endpoint: listener.endpoint, options: .inactive)
        try session.activate()
        defer { session.cancel(reason: "done") }

        let envelope = xpc_dictionary_create(nil, nil, 0)
        encoded.body.withUnsafeBytes { raw in
            xpc_dictionary_set_data(envelope, OverlayEnvelope.body, raw.baseAddress, raw.count)
        }
        xpc_dictionary_set_int64(envelope, OverlayEnvelope.coderVersion,
                                 OverlayWireFormat.coderVersion)
        xpc_dictionary_set_bool(envelope, OverlayEnvelope.isSync, false)

        let ool = xpc_array_create(nil, 0)
        for blob in encoded.outOfLine {
            blob.withUnsafeBytes { raw in
                xpc_array_append_value(ool, xpc_data_create(raw.baseAddress, raw.count))
            }
        }
        xpc_dictionary_set_value(envelope, OverlayEnvelope.outOfLine, ool)
        xpc_dictionary_set_value(envelope, OverlayEnvelope.outOfLineObjects,
                                 xpc_array_create(nil, 0))

        try session.send(message: XPCDictionary(envelope))
        wait(for: [arrived], timeout: 10)
        return box.value
    }

    func testAppleDecodesOurScalars() throws {
        let original = Scalars(flag: false, small: 127, wide: 4_000_000_000,
                               name: "round trip", ratio: -2.25)
        XCTAssertEqual(try send(original, expecting: Scalars.self), original)
    }

    func testAppleDecodesOurNestedContainers() throws {
        let original = Outer(inner: Inner(value: -5), list: [10, 20, 30], optional: "set")
        XCTAssertEqual(try send(original, expecting: Outer.self), original)
    }

    func testAppleDecodesOurAbsentOptional() throws {
        let original = Outer(inner: Inner(value: 1), list: [], optional: nil)
        XCTAssertEqual(try send(original, expecting: Outer.self), original)
    }

    func testAppleDecodesOurOutOfLineData() throws {
        // Proves the side array and the index in the stream line up the way Apple
        // expects, which nothing in our own round trip could establish.
        let original = WithData(label: "blob", blob: Data((0..<300).map { UInt8($0 % 256) }))
        XCTAssertEqual(try send(original, expecting: WithData.self), original)
    }
}
#endif
