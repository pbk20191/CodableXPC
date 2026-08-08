import XCTest
import Distributed
import CodableXPC
@testable import XPCActors

private struct Payload: Codable, Equatable { let n: Int }
private struct Boom: Error, Codable {}

@available(macOS 14, *)
final class InvocationEncoderTests: XCTestCase {

    func testRecordingBuildsARequestBody() throws {
        var encoder = InvocationEncoder()
        try encoder.recordGenericSubstitution(Int.self)
        try encoder.recordArgument(RemoteCallArgument(label: "name", name: "name", value: "hi"))
        try encoder.recordArgument(RemoteCallArgument(label: nil, name: "n", value: Payload(n: 3)))
        try encoder.recordErrorType(Boom.self)
        try encoder.recordReturnType(String.self)
        try encoder.doneRecording()

        let body = encoder.makeRequestBody(actor: .exportedRawValue("primary"), target: "t", basePriority: nil)
        XCTAssertEqual(body.actor, .exportedRawValue("primary"))
        XCTAssertEqual(body.target, "t")
        XCTAssertEqual(body.generics, [try XCTUnwrap(TypeName.mangled(for: Int.self))])
        XCTAssertEqual(body.args.count, 2)
        XCTAssertEqual(body.errorType, try XCTUnwrap(TypeName.mangled(for: Boom.self)))
        XCTAssertEqual(body.returnType, try XCTUnwrap(TypeName.mangled(for: String.self)))
    }

    /// Labels are discarded deliberately: the receiver knows them statically, so
    /// putting them on the wire would be pure overhead.
    func testArgumentLabelsAreDiscarded() throws {
        var encoder = InvocationEncoder()
        try encoder.recordArgument(RemoteCallArgument(label: "greeting", name: "g", value: "hi"))
        try encoder.doneRecording()
        let rendered = normalizedDescription(
            try XPCEncoder().encode(encoder.makeRequestBody(actor: .dynamic(ID64(rawValue: 1)), target: "t",
                                                            basePriority: nil)))
        XCTAssertFalse(rendered.contains("greeting"))
        XCTAssertTrue(rendered.contains("args=[string(hi)]"))
    }

    func testArgumentOrderIsPreserved() throws {
        var encoder = InvocationEncoder()
        for n in 0..<5 {
            try encoder.recordArgument(RemoteCallArgument(label: nil, name: "", value: n))
        }
        try encoder.doneRecording()
        let body = encoder.makeRequestBody(actor: .dynamic(ID64(rawValue: 1)), target: "t", basePriority: nil)
        XCTAssertEqual(normalizedDescription(try XPCEncoder().encode(body)).contains(
            "args=[int64(0),int64(1),int64(2),int64(3),int64(4)]"), true)
    }

    func testNoErrorTypeMeansTheTargetDoesNotThrow() throws {
        var encoder = InvocationEncoder()
        try encoder.doneRecording()
        XCTAssertNil(encoder.makeRequestBody(actor: .dynamic(ID64(rawValue: 1)), target: "t",
                                             basePriority: nil).errorType)
    }

    func testBasePriorityIsCarriedThrough() throws {
        var encoder = InvocationEncoder()
        try encoder.doneRecording()
        let body = encoder.makeRequestBody(actor: .dynamic(ID64(rawValue: 1)), target: "t",
                                           basePriority: UInt64(TaskPriority.high.rawValue))
        XCTAssertEqual(body.basePriority, UInt64(TaskPriority.high.rawValue))
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
