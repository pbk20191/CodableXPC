#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCOverlayCoder

/// Capture the envelope Apple's own encoder produces for a value.
///
/// Two test files need this and a third will, so it lives here rather than being
/// copied again.
///
/// Every step is public API — there is no `dlsym` and no calling convention to get
/// right, unlike ``AppleCoderBridge``, because this needs `encodeMessage`'s *output*
/// rather than the symbol. The one non-obvious part is the handler: the typed
/// `accept` overloads run Apple's *decoder* and hand back a decoded value, which
/// cannot answer a question about bytes. The untyped overload on
/// `XPCListener.IncomingSessionRequest` hands over the `XPCDictionary` itself,
/// before any decoder runs, and that is the message as it would have gone on a real
/// wire.
@available(macOS 15, macCatalyst 18, *)
extension XCTestCase {

    /// The whole message Apple encoded, copied out of the handler.
    func captureAppleEnvelope(
        _ value: some Encodable,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> xpc_object_t {
        let received = XCTestExpectation(description: "the message arrives")
        let box = AppleEnvelopeBox()

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
        return try XCTUnwrap(box.envelope, "no message arrived", file: file, line: line)
    }

    /// The `_CodableBody` of that message, with the side arrays asserted empty.
    ///
    /// A fixture carrying `Data` or a live object would put part of itself in a side
    /// array, and then a byte comparison of the body alone could miss a disagreement.
    /// Callers that want such a fixture should use ``captureAppleEnvelope(_:file:line:)``
    /// and compare the arrays too.
    func captureAppleBody(
        _ value: some Encodable,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Data {
        let envelope = try captureAppleEnvelope(value, file: file, line: line)

        if let array = xpc_dictionary_get_value(envelope, OverlayEnvelope.outOfLine) {
            XCTAssertEqual(xpc_array_get_count(array), 0,
                           "a side array would make the body partial",
                           file: file, line: line)
        }
        let raw = try XCTUnwrap(xpc_dictionary_get_value(envelope, OverlayEnvelope.body),
                                "no \(OverlayEnvelope.body)", file: file, line: line)
        let pointer = try XCTUnwrap(xpc_data_get_bytes_ptr(raw),
                                    "\(OverlayEnvelope.body) is not data",
                                    file: file, line: line)
        return Data(bytes: pointer, count: xpc_data_get_length(raw))
    }
}

/// The captured object has to escape the handler closure. `wait(for:)` establishes the
/// ordering: nothing reads this until `fulfill()` has happened.
private final class AppleEnvelopeBox: @unchecked Sendable {
    var envelope: xpc_object_t?
}
#endif
