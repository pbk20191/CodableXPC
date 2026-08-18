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

    /// The wrapper around a ``DirectInvocationDecoder`` built from the encoder's recorded
    /// values -- the same construction `InvocationEncoder.makeDirectInvocationDecoder` performs,
    /// without the two `Session`s that method takes only to match Apple's signature (see its
    /// doc). Isolates the decoder's argument handoff from session plumbing.
    private func directDecoder(_ encoder: InvocationEncoder) -> InvocationDecoder {
        InvocationDecoder(direct: DirectInvocationDecoder(
            arguments: encoder.arguments,
            protocolStub: encoder.protocolStub,
            genericSubsitutions: encoder.genericSubsitutions,
            returnType: encoder.returnType,
            errorType: encoder.errorType))
    }

    func testDirectDecoderHandsBackRecordedArgumentsInOrder() throws {
        let encoder = try encoderRecording {
            try $0.recordArgument(RemoteCallArgument(label: nil, name: "a", value: 41))
            try $0.recordArgument(RemoteCallArgument(label: nil, name: "b", value: "hi"))
        }
        var decoder = directDecoder(encoder)
        XCTAssertEqual(try decoder.decodeNextArgument() as Int, 41)
        XCTAssertEqual(try decoder.decodeNextArgument() as String, "hi")
    }

    func testDirectDecoderReportsExhaustionLikeTheEncodedContainer() throws {
        let encoder = try encoderRecording {
            try $0.recordArgument(RemoteCallArgument(label: nil, name: "a", value: 1))
        }
        var decoder = directDecoder(encoder)
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
        var decoder = directDecoder(encoder)
        XCTAssertThrowsError(try decoder.decodeNextArgument() as String)
    }

    // MARK: The direct result handler

    func testDirectResultHandlerCapturesAValue() async throws {
        let handler = ResultHandler.direct()
        try await handler.onReturn(value: 99)
        guard case .success(let captured) = handler.capturedResult else {
            return XCTFail("expected a captured value, got \(String(describing: handler.capturedResult))")
        }
        XCTAssertEqual(captured as? Int, 99)
    }

    func testDirectResultHandlerCapturesVoid() async throws {
        let handler = ResultHandler.direct()
        try await handler.onReturnVoid()
        // A void return folds into `.success(Ack())`, Apple's `DirectResultHandler` shape.
        guard case .success(let captured) = handler.capturedResult, captured is Ack else {
            return XCTFail("expected a captured void (Ack), got \(String(describing: handler.capturedResult))")
        }
    }

    func testDirectResultHandlerCapturesAThrow() async throws {
        struct Boom: Error {}
        let handler = ResultHandler.direct()
        try await handler.onThrow(error: Boom())
        guard case .failure(let error) = handler.capturedResult else {
            return XCTFail("expected a captured failure")
        }
        XCTAssertTrue(error is Boom)
    }
}
