import XCTest
import XPC
import CodableXPC
@testable import XPCActors

@available(macOS 14, *)
final class InvocationBodiesTests: XCTestCase {

    // MARK: tier 1 — request golden fixture

    func testTheRequestBodyIsPinned() throws {
        let body = RequestBody(
            actor: .name("primary"),
            target: "$s4Test7GreeterC5greet4nameSSSS_tYaKFTE",
            generics: ["Si"],
            args: [7 as Int, "hi" as String],
            errorType: "Se",
            returnType: "SS",
            basePriority: 25
        )
        XCTAssertEqual(
            normalizedDescription(try XPCEncoder().encode(body)),
            "{actor=dict{kind=uint64(1),name=string(primary)},"
            + "args=[int64(7),string(hi)],"
            + "basePriority=uint64(25),"
            + "errorType=string(Se),"
            + "generics=[string(Si)],"
            + "returnType=string(SS),"
            + "target=string($s4Test7GreeterC5greet4nameSSSS_tYaKFTE)}"
        )
    }

    func testAbsentOptionalsAreOmittedEntirely() throws {
        let body = RequestBody(actor: .dynamic(3), target: "t", generics: [],
                               args: [], errorType: nil, returnType: nil, basePriority: nil)
        let object = try XPCEncoder().encode(body)
        XCTAssertNil(xpc_dictionary_get_value(object, "errorType"))
        XCTAssertNil(xpc_dictionary_get_value(object, "returnType"))
        XCTAssertNil(xpc_dictionary_get_value(object, "basePriority"))
        XCTAssertEqual(normalizedDescription(object),
                       "{actor=dict{id=uint64(3),kind=uint64(2)},args=[],generics=[],target=string(t)}")
    }

    // MARK: inbound request keeps the argument container unconsumed

    func testAnInboundRequestReadsTheHeaderAndLeavesTheArgumentsAlone() throws {
        let body = RequestBody(actor: .type("G"), target: "t", generics: ["Si"],
                               args: [1 as Int, "two" as String], errorType: "Se",
                               returnType: "SS", basePriority: nil)
        let object = try XPCEncoder().encode(body)

        var inbound = try XPCDecoder().decode(InboundRequest.self, from: object)
        XCTAssertEqual(inbound.actor, .type("G"))
        XCTAssertEqual(inbound.target, "t")
        XCTAssertEqual(inbound.generics, ["Si"])
        XCTAssertEqual(inbound.errorType, "Se")
        XCTAssertEqual(inbound.returnType, "SS")
        XCTAssertNil(inbound.basePriority)

        XCTAssertEqual(try inbound.argumentsContainer.decode(Int.self), 1)
        XCTAssertEqual(try inbound.argumentsContainer.decode(String.self), "two")
        XCTAssertTrue(inbound.argumentsContainer.isAtEnd)
    }

    // MARK: reply

    func testASuccessReplyCarriesOnlyOK() throws {
        let reply = try ReplyBody.success(encoding: 42 as Int)
        let object = try XPCEncoder().encode(reply)
        XCTAssertNil(xpc_dictionary_get_value(object, "err"))
        XCTAssertEqual(normalizedDescription(object), "{ok=int64(42)}")
    }

    func testAVoidReplyIsAnEmptyDictionary() throws {
        XCTAssertEqual(normalizedDescription(try XPCEncoder().encode(ReplyBody.void)),
                       "{ok=dict{}}")
    }

    func testAnErrorReplyIsPinned() throws {
        let reply = ReplyBody(err: .init(kind: .noSuchActor, type: nil, value: nil,
                                         text: "no actor for name(primary)"))
        XCTAssertEqual(
            normalizedDescription(try XPCEncoder().encode(reply)),
            "{err=dict{kind=uint64(2),text=string(no actor for name(primary))}}")
    }

    func testTheErrorKindsArePinned() {
        XCTAssertEqual(ReplyBody.Err.Kind.targetThrew.rawValue, 0)
        XCTAssertEqual(ReplyBody.Err.Kind.resultEncodingFailed.rawValue, 1)
        XCTAssertEqual(ReplyBody.Err.Kind.noSuchActor.rawValue, 2)
        XCTAssertEqual(ReplyBody.Err.Kind.peerRequirementNotSatisfied.rawValue, 3)
        XCTAssertEqual(ReplyBody.Err.Kind.notReceiving.rawValue, 4)
        XCTAssertEqual(ReplyBody.Err.Kind.requestUndecodable.rawValue, 5)
    }

    /// Exactly one of `ok` and `err`. Both or neither is a malformed reply, and it has
    /// to fail rather than pick one -- silently preferring `ok` would turn a reported
    /// remote failure into a bogus success.
    func testAReplyWithNeitherOrBothFails() throws {
        let empty = xpc_dictionary_create(nil, nil, 0)
        XCTAssertThrowsError(try XPCDecoder().decode(ReplyBody.self, from: empty))

        let both = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(both, "ok", 1)
        xpc_dictionary_set_value(both, "err", try XPCEncoder().encode(
            ReplyBody.Err(kind: .targetThrew, type: nil, value: nil, text: "x")))
        XCTAssertThrowsError(try XPCDecoder().decode(ReplyBody.self, from: both))
    }

    // MARK: notification

    func testTheNotificationBodyIsPinned() throws {
        let body = NotificationBody(kind: .invocationCancelled, requestSeq: 9, priority: nil)
        XCTAssertEqual(normalizedDescription(try XPCEncoder().encode(body)),
                       "{kind=uint64(0),requestSeq=uint64(9)}")
    }

    /// The field is `requestSeq`, never `seq`. A notification carries no envelope seq,
    /// and the two must never be confusable in code or in a log.
    func testTheNotificationFieldIsNotCalledSeq() throws {
        let object = try XPCEncoder().encode(
            NotificationBody(kind: .invocationEscalated, requestSeq: 1, priority: 33))
        XCTAssertNil(xpc_dictionary_get_value(object, "seq"))
        XCTAssertEqual(normalizedDescription(object),
                       "{kind=uint64(1),priority=uint64(33),requestSeq=uint64(1)}")
    }

    func testAnUnknownNotificationKindIsRejected() throws {
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(object, "kind", 77)
        xpc_dictionary_set_uint64(object, "requestSeq", 1)
        XCTAssertThrowsError(try XPCDecoder().decode(NotificationBody.self, from: object))
    }
}
