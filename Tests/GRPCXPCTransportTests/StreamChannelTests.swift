import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class StreamChannelTests: XCTestCase {
    func testServerInboundDeliversMetadataThenMessagesInOrder() async throws {
        let (channel, inbound) = StreamChannel<RPCRequestPart<[UInt8]>>.serverInbound(streamID: 1)
        try channel.accept(.metadata(1, WireMetadata(Metadata())))
        try channel.accept(.message(1, seq: 0, bytes: GRPCMessageFraming.frame([10])))
        try channel.accept(.message(1, seq: 1, bytes: GRPCMessageFraming.frame([11])))
        try channel.accept(.halfClose(1))            // finishes the request stream

        var kinds: [String] = []
        for try await part in inbound {
            switch part {
            case .metadata: kinds.append("md")
            case .message(let b): kinds.append("msg(\(b.first ?? 0))")
            }
        }
        XCTAssertEqual(kinds, ["md", "msg(10)", "msg(11)"])
    }

    func testARequestStreamHasNoStatusTerminator() async throws {
        // Requests terminate with halfClose, not status; a status on a request stream is a violation.
        let (channel, _) = StreamChannel<RPCRequestPart<[UInt8]>>.serverInbound(streamID: 2)
        XCTAssertThrowsError(try channel.accept(.status(2, code: 0, message: "", trailers: WireMetadata(Metadata()))))
    }
}

@available(macOS 15.0, *)
extension StreamChannelTests {
    func testClientInboundRejectsMessageAfterStatus() throws {
        let (channel, _) = StreamChannel<RPCResponsePart<[UInt8]>>.clientInbound(streamID: 3)
        try channel.accept(.message(3, seq: 0, bytes: GRPCMessageFraming.frame([1])))
        try channel.accept(.status(3, code: 0, message: "ok", trailers: WireMetadata(Metadata())))
        XCTAssertThrowsError(try channel.accept(.message(3, seq: 1, bytes: GRPCMessageFraming.frame([2]))))
    }

    func testClientInboundRejectsOutOfOrderSeq() throws {
        let (channel, _) = StreamChannel<RPCResponsePart<[UInt8]>>.clientInbound(streamID: 4)
        XCTAssertThrowsError(try channel.accept(.message(4, seq: 5, bytes: GRPCMessageFraming.frame([1]))))
    }

    func testServerInboundRejectsMetadataAfterMessage() throws {
        // The grammar is sequential (metadata* -> message*), not interleaved: once the first
        // message has arrived, a later metadata frame is a violation, not a second leading burst.
        let (channel, _) = StreamChannel<RPCRequestPart<[UInt8]>>.serverInbound(streamID: 5)
        try channel.accept(.message(5, seq: 0, bytes: GRPCMessageFraming.frame([1])))
        XCTAssertThrowsError(try channel.accept(.metadata(5, WireMetadata(Metadata()))))
    }

    func testClientInboundRejectsHalfCloseOnResponseStream() throws {
        // halfClose ends the request direction only; a response stream never legitimately sees it.
        let (channel, _) = StreamChannel<RPCResponsePart<[UInt8]>>.clientInbound(streamID: 6)
        XCTAssertThrowsError(try channel.accept(.halfClose(6)))
    }

    func testFailInboundFinishesWithTheGivenError() async throws {
        struct Boom: Error {}
        let (channel, inbound) = StreamChannel<RPCResponsePart<[UInt8]>>.clientInbound(streamID: 7)
        channel.failInbound(Boom())
        do {
            for try await _ in inbound {}
            XCTFail("expected failInbound's error to propagate")
        } catch is Boom {
            // expected
        }
    }
}
