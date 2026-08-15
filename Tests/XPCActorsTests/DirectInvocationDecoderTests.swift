import XCTest
import Distributed
@testable import XPCActors

/// The direct half of Apple's `{ encoded | direct }` invocation decoder: it hands back the
/// caller's own recorded values, cast to the type the runtime asks for, without encoding or
/// decoding a byte. The foundation of the same-process optimization's direct-invocation path.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class DirectInvocationDecoderTests: XCTestCase {

    private func encoderRecording(_ record: (inout InvocationEncoder) throws -> Void) rethrows
        -> InvocationEncoder {
        var encoder = InvocationEncoder()
        try record(&encoder)
        try? encoder.doneRecording()
        return encoder
    }

    func testDirectDecoderHandsBackRecordedArgumentsInOrder() throws {
        let encoder = try encoderRecording {
            try $0.recordArgument(RemoteCallArgument(label: nil, name: "a", value: 41))
            try $0.recordArgument(RemoteCallArgument(label: nil, name: "b", value: "hi"))
        }
        var decoder = InvocationDecoder(direct: encoder)
        XCTAssertEqual(try decoder.decodeNextArgument() as Int, 41)
        XCTAssertEqual(try decoder.decodeNextArgument() as String, "hi")
    }

    func testDirectDecoderReportsExhaustionLikeTheEncodedContainer() throws {
        let encoder = try encoderRecording {
            try $0.recordArgument(RemoteCallArgument(label: nil, name: "a", value: 1))
        }
        var decoder = InvocationDecoder(direct: encoder)
        _ = try decoder.decodeNextArgument() as Int
        XCTAssertThrowsError(try decoder.decodeNextArgument() as Int) { error in
            XCTAssertTrue("\(error)".contains("Found no arguments"), "\(error)")
        }
    }

    /// The return/error types are forwarded from the encoder's `SwiftType` and resolved the
    /// same way the encoded path resolves them (validated end to end by the real-call tests);
    /// the direct-path-specific behaviour is the argument handoff above.

    /// A type mismatch on the direct path is a bug in this process, and it says so rather
    /// than handing the runtime a value of the wrong type.
    func testDirectDecoderRefusesAWrongType() throws {
        let encoder = try encoderRecording {
            try $0.recordArgument(RemoteCallArgument(label: nil, name: "a", value: 7))
        }
        var decoder = InvocationDecoder(direct: encoder)
        XCTAssertThrowsError(try decoder.decodeNextArgument() as String)
    }

    // MARK: The direct result handler

    func testDirectResultHandlerCapturesAValue() async throws {
        let handler = DirectResultHandler()
        try await handler.onReturn(value: 99)
        guard case .value(let captured) = handler.capturedResult else {
            return XCTFail("expected a captured value, got \(String(describing: handler.capturedResult))")
        }
        XCTAssertEqual(captured as? Int, 99)
    }

    func testDirectResultHandlerCapturesVoid() async throws {
        let handler = DirectResultHandler()
        try await handler.onReturnVoid()
        guard case .void = handler.capturedResult else { return XCTFail("expected void") }
    }

    func testDirectResultHandlerCapturesAThrow() async throws {
        struct Boom: Error {}
        let handler = DirectResultHandler()
        try await handler.onThrow(error: Boom())
        guard case .failure(let error) = handler.capturedResult else {
            return XCTFail("expected a captured failure")
        }
        XCTAssertTrue(error is Boom)
    }
}
