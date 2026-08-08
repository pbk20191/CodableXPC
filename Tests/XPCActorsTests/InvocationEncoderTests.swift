import XCTest
import Distributed
import CodableXPC
@testable import XPCActors

private struct Payload: Codable, Equatable { let n: Int }
private struct Boom: Error, Codable {}

@available(macOS 14, *)
final class InvocationEncoderTests: XCTestCase {

    func testRecordingBuildsARequest() throws {
        var encoder = InvocationEncoder()
        try encoder.recordGenericSubstitution(Int.self)
        try encoder.recordArgument(RemoteCallArgument(label: "name", name: "name", value: "hi"))
        try encoder.recordArgument(RemoteCallArgument(label: nil, name: "n", value: Payload(n: 3)))
        try encoder.recordErrorType(Boom.self)
        try encoder.recordReturnType(String.self)
        try encoder.doneRecording()

        let request = encoder.makeRequest(id: ID64(rawValue: 5),
                                          actor: .exportedRawValue("primary"),
                                          target: "t", basePriority: nil)
        XCTAssertEqual(request.id, ID64(rawValue: 5))
        XCTAssertEqual(request.targetedSharedActor, .exportedRawValue("primary"))
        XCTAssertEqual(request.remoteCallIdentifier, "t")
        XCTAssertEqual(request.contents.genericSubsitutions,
                       [SwiftType(mangledTypeName: try XCTUnwrap(TypeName.mangled(for: Int.self)))])
        XCTAssertEqual(request.contents.arguments.count, 2)
        XCTAssertEqual(request.contents.errorType,
                       SwiftType(mangledTypeName: try XCTUnwrap(TypeName.mangled(for: Boom.self))))
        XCTAssertEqual(request.contents.returnType,
                       SwiftType(mangledTypeName: try XCTUnwrap(TypeName.mangled(for: String.self))))
        // R3 rewrites the encoder to record one; until then it is always absent.
        XCTAssertNil(request.contents.protocolStub)
    }

    /// Labels are discarded deliberately: the receiver knows them statically, so
    /// putting them on the wire would be pure overhead.
    func testArgumentLabelsAreDiscarded() throws {
        var encoder = InvocationEncoder()
        try encoder.recordArgument(RemoteCallArgument(label: "greeting", name: "g", value: "hi"))
        try encoder.doneRecording()
        let rendered = normalizedDescription(
            try XPCEncoder().encode(encoder.makeInvocationBody()))
        XCTAssertFalse(rendered.contains("greeting"))
        XCTAssertTrue(rendered.contains("arguments=[string(hi)]"))
    }

    func testArgumentOrderIsPreserved() throws {
        var encoder = InvocationEncoder()
        for n in 0..<5 {
            try encoder.recordArgument(RemoteCallArgument(label: nil, name: "", value: n))
        }
        try encoder.doneRecording()
        let body = encoder.makeInvocationBody()
        XCTAssertEqual(normalizedDescription(try XPCEncoder().encode(body)).contains(
            "arguments=[int64(0),int64(1),int64(2),int64(3),int64(4)]"), true)
    }

    func testNoErrorTypeMeansTheTargetDoesNotThrow() throws {
        var encoder = InvocationEncoder()
        try encoder.doneRecording()
        XCTAssertNil(encoder.makeInvocationBody().errorType)
    }

    func testBasePriorityIsCarriedThrough() throws {
        var encoder = InvocationEncoder()
        try encoder.doneRecording()
        let request = encoder.makeRequest(id: ID64(rawValue: 1),
                                          actor: .dynamic(ID64(rawValue: 1)), target: "t",
                                          basePriority: .high)
        XCTAssertEqual(request.basePriority, .high)
    }

    /// Two calls must not share accumulated state. `makeInvocationEncoder()` returns a
    /// fresh value per invocation, and a struct is what makes that cheap -- but only if
    /// nothing static leaks between them.
    func testEncodersDoNotShareState() throws {
        var first = InvocationEncoder()
        try first.recordArgument(RemoteCallArgument(label: nil, name: "", value: 1))
        try first.doneRecording()

        var second = InvocationEncoder()
        try second.doneRecording()
        XCTAssertTrue(second.arguments.isEmpty)
        XCTAssertEqual(first.arguments.count, 1)
    }
}
