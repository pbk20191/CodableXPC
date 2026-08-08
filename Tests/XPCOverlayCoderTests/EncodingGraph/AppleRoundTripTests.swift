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

/// Decodes what Apple actually encoded.
///
/// Everything else in this module is checked against captured byte fixtures. This
/// closes the loop: an anonymous listener receives a message that Apple's own
/// overlay encoded moments earlier, and our decoder has to recover the value.
@available(macOS 15, macCatalyst 18, *)
final class AppleRoundTripTests: XCTestCase {

    /// Sends `value` through a real XPCSession and returns the raw envelope pieces.
    private func capture(_ value: some Encodable) throws -> (body: Data, outOfLine: [Data]) {
        let received = XCTestExpectation(description: "message arrives")
        let box = CaptureBox()

        let listener = XPCListener(targetQueue: nil, options: .inactive) { request in
            request.accept { (message: XPCDictionary) -> XPCDictionary? in
                message.withUnsafeUnderlyingDictionary { raw in
                    box.envelope = xpc_copy(raw)
                    if let body = xpc_dictionary_get_value(raw, OverlayEnvelope.body),
                       let pointer = xpc_data_get_bytes_ptr(body) {
                        box.body = Data(bytes: pointer, count: xpc_data_get_length(body))
                    }
                    if let array = xpc_dictionary_get_value(raw, OverlayEnvelope.outOfLine) {
                        for index in 0..<xpc_array_get_count(array) {
                            let element = xpc_array_get_value(array, index)
                            if let pointer = xpc_data_get_bytes_ptr(element) {
                                box.outOfLine.append(
                                    Data(bytes: pointer, count: xpc_data_get_length(element)))
                            }
                        }
                    }
                }
                received.fulfill()
                return nil
            }
        }
        try listener.activate()
        defer { listener.cancel() }

        let session = try XPCSession(endpoint: listener.endpoint, options: .inactive)
        try session.activate()
        defer { session.cancel(reason: "captured") }
        try session.send(value)

        wait(for: [received], timeout: 10)
        return (box.body, box.outOfLine)
    }

    private final class CaptureBox: @unchecked Sendable {
        var body = Data()
        var outOfLine: [Data] = []
        /// The whole envelope Apple's `encodeMessage` produced, kept so its shape
        /// can be compared against ours and not just its contents.
        var envelope: xpc_object_t?
    }

    /// Sends `value` and returns the entire envelope Apple built for it.
    private func captureEnvelope(_ value: some Encodable) throws -> xpc_object_t {
        let received = XCTestExpectation(description: "message arrives")
        let box = CaptureBox()

        let listener = XPCListener(targetQueue: nil, options: .inactive) { request in
            request.accept { (message: XPCDictionary) -> XPCDictionary? in
                message.withUnsafeUnderlyingDictionary { box.envelope = xpc_copy($0) }
                received.fulfill()
                return nil
            }
        }
        try listener.activate()
        defer { listener.cancel() }

        let session = try XPCSession(endpoint: listener.endpoint, options: .inactive)
        try session.activate()
        defer { session.cancel(reason: "captured") }
        try session.send(value)

        wait(for: [received], timeout: 10)
        return try XCTUnwrap(box.envelope)
    }

    /// Every key in `message`, with the xpc type of its value.
    private func shape(_ message: xpc_object_t) -> [String: xpc_type_t] {
        var found: [String: xpc_type_t] = [:]
        xpc_dictionary_apply(message) { key, value in
            found[String(cString: key)] = xpc_get_type(value)
            return true
        }
        return found
    }

    /// `XPCReceivedMessage.encodeMessage` is exported under no name -- it is in
    /// neither the linker's `.tbd` nor the runtime export trie -- so it cannot be
    /// called directly. Its *output* is reachable, though: anything Apple sends
    /// went through it. This pins `OverlayEnvelope.message` against the real
    /// thing rather than against a reading of the disassembly.
    func testOurEnvelopeHasTheSameShapeAsApples() throws {
        let value = Scalars(flag: true, small: -3, wide: 70_000, name: "overlay", ratio: 0.5)
        let theirs = try captureEnvelope(value)
        let ours = try XPCOverlayEncoder().message(value)

        XCTAssertEqual(shape(ours), shape(theirs))
        XCTAssertEqual(
            xpc_dictionary_get_int64(ours, OverlayEnvelope.coderVersion),
            xpc_dictionary_get_int64(theirs, OverlayEnvelope.coderVersion))
        XCTAssertEqual(
            xpc_dictionary_get_bool(ours, OverlayEnvelope.isSync),
            xpc_dictionary_get_bool(theirs, OverlayEnvelope.isSync))
    }

    /// The bytes too, not only the key set. A value with no `Data` and no live
    /// object leaves both side arrays empty, so the body is the entire message
    /// and any disagreement about the stream shows up here.
    func testOurBodyIsByteIdenticalToApples() throws {
        let value = Outer(inner: Inner(value: 9), list: [1, 2, 3], optional: "here")
        let theirs = try captureEnvelope(value)
        let ours = try XPCOverlayEncoder().encode(value)

        let raw = try XCTUnwrap(xpc_dictionary_get_value(theirs, OverlayEnvelope.body))
        let pointer = try XCTUnwrap(xpc_data_get_bytes_ptr(raw))
        XCTAssertEqual(ours.body, Data(bytes: pointer, count: xpc_data_get_length(raw)))
    }

    func testScalars() throws {
        let original = Scalars(flag: true, small: -3, wide: 70_000,
                               name: "overlay", ratio: 0.5)
        let (body, ool) = try capture(original)
        XCTAssertEqual(try XPCOverlayDecoder().decode(Scalars.self, from: body, outOfLine: ool),
                       original)
    }

    func testNestedAndOptional() throws {
        let original = Outer(inner: Inner(value: 9), list: [1, 2, 3], optional: nil)
        let (body, ool) = try capture(original)
        XCTAssertEqual(try XPCOverlayDecoder().decode(Outer.self, from: body, outOfLine: ool),
                       original)
    }

    func testPresentOptional() throws {
        let original = Outer(inner: Inner(value: 0), list: [], optional: "here")
        let (body, ool) = try capture(original)
        XCTAssertEqual(try XPCOverlayDecoder().decode(Outer.self, from: body, outOfLine: ool),
                       original)
    }

    func testDataTravelsOutOfLine() throws {
        // Data does not go in the byte stream: the encoder puts the bytes in
        // _CodableOutOfLine and writes an index. Recovering it needs the shape
        // check, not Data.init(from:).
        let original = WithData(label: "payload", blob: Data((0..<200).map { UInt8($0 % 251) }))
        let (body, ool) = try capture(original)
        XCTAssertEqual(ool.count, 1, "expected the blob to be out-of-line")
        XCTAssertEqual(try XPCOverlayDecoder().decode(WithData.self, from: body, outOfLine: ool),
                       original)
    }

    func testTopLevelArray() throws {
        let original = [Inner(value: 1), Inner(value: 2)]
        let (body, ool) = try capture(original)
        XCTAssertEqual(try XPCOverlayDecoder().decode([Inner].self, from: body, outOfLine: ool),
                       original)
    }
}
#endif
