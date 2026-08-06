import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class PacketEnvelopeTests: XCTestCase {

    private func emptyBody() -> Packet.Payload {
        Packet.Payload(unchecked: xpc_dictionary_create(nil, nil, 0))
    }

    // MARK: header contract

    func testRequestRequiresSeqAndRealVersion() {
        XCTAssertNotNil(PacketHeader(version: .v1, kind: .request, seq: 7))
        XCTAssertNil(PacketHeader(version: .v1, kind: .request, seq: nil))
        XCTAssertNil(PacketHeader(version: .unnegotiated, kind: .request, seq: 7))
    }

    func testNotificationForbidsSeq() {
        XCTAssertNotNil(PacketHeader(version: .v1, kind: .notification, seq: nil))
        // A notification with a seq would be ambiguous with a request.
        XCTAssertNil(PacketHeader(version: .v1, kind: .notification, seq: 7))
    }

    func testHandshakeRequiresUnnegotiatedVersionAndNoSeq() {
        XCTAssertNotNil(PacketHeader(version: .unnegotiated, kind: .hello, seq: nil))
        XCTAssertNotNil(PacketHeader(version: .unnegotiated, kind: .helloAck, seq: nil))
        XCTAssertNil(PacketHeader(version: .v1, kind: .hello, seq: nil))
        XCTAssertNil(PacketHeader(version: .unnegotiated, kind: .hello, seq: 1))
    }

    // MARK: round trip

    func testRequestRoundTrips() throws {
        let header = try XCTUnwrap(PacketHeader(version: .v1, kind: .request, seq: 42))
        let packet = Packet(header: header, payload: emptyBody())
        let decoded = try XCTUnwrap(Packet(rawValue: packet.rawValue))
        XCTAssertEqual(decoded.header, header)
    }

    func testNotificationRoundTripsWithoutSeq() throws {
        let header = try XCTUnwrap(PacketHeader(version: .v1, kind: .notification, seq: nil))
        let packet = Packet(header: header, payload: emptyBody())
        let raw = packet.rawValue
        XCTAssertNil(xpc_dictionary_get_value(raw, EnvelopeKey.seq), "seq must be absent, not zero")
        let decoded = try XCTUnwrap(Packet(rawValue: raw))
        XCTAssertNil(decoded.header.seq)
    }

    // MARK: golden fixtures — pin the wire format
    //
    // The spec promises to pin "the envelope and every body type". If any assertion
    // below fails, the wire format changed. That is allowed, but it must be
    // deliberate: bump ProtocolVersion.current in the same commit.

    func testRequestEnvelopeGoldenFixture() throws {
        let header = try XCTUnwrap(PacketHeader(version: .v1, kind: .request, seq: 42))
        let packet = Packet(header: header, payload: emptyBody())
        XCTAssertEqual(
            normalizedDescription(packet.rawValue),
            "{body=dict{},kind=uint64(0),seq=uint64(42),version=uint64(1)}"
        )
    }

    func testReplyEnvelopeGoldenFixture() throws {
        let header = try XCTUnwrap(PacketHeader(version: .v1, kind: .reply, seq: 42))
        let packet = Packet(header: header, payload: emptyBody())
        XCTAssertEqual(
            normalizedDescription(packet.rawValue),
            "{body=dict{},kind=uint64(1),seq=uint64(42),version=uint64(1)}"
        )
    }

    func testNotificationEnvelopeGoldenFixture() throws {
        let header = try XCTUnwrap(PacketHeader(version: .v1, kind: .notification, seq: nil))
        let packet = Packet(header: header, payload: emptyBody())
        XCTAssertEqual(
            normalizedDescription(packet.rawValue),
            "{body=dict{},kind=uint64(2),version=uint64(1)}"
        )
    }

    func testHelloEnvelopeGoldenFixture() throws {
        // The shape whose rules are easiest to break: version 0 ("not yet negotiated")
        // and no seq at all. A `seq` appearing here would make it a request; a real
        // version here would mean the sender had already negotiated one.
        let header = try XCTUnwrap(PacketHeader(version: .unnegotiated, kind: .hello, seq: nil))
        let packet = Packet(header: header, payload: emptyBody())
        XCTAssertEqual(
            normalizedDescription(packet.rawValue),
            "{body=dict{},kind=uint64(3),version=uint64(0)}"
        )
    }

    func testHelloAckEnvelopeGoldenFixture() throws {
        let header = try XCTUnwrap(PacketHeader(version: .unnegotiated, kind: .helloAck, seq: nil))
        let packet = Packet(header: header, payload: emptyBody())
        XCTAssertEqual(
            normalizedDescription(packet.rawValue),
            "{body=dict{},kind=uint64(4),version=uint64(0)}"
        )
    }

    func testHelloBodyGoldenFixture() throws {
        let payload = try Packet.Payload(encoding: HelloBody(min: 1, max: 1))
        XCTAssertEqual(
            normalizedDescription(payload.object),
            "{max=uint64(1),min=uint64(1)}"
        )
        // The value actually shipped today, so a change to the supported range shows up
        // here rather than only in a live handshake.
        XCTAssertEqual(
            normalizedDescription(try Packet.Payload(encoding: HelloBody.current).object),
            "{max=uint64(1),min=uint64(1)}"
        )
    }

    func testHelloAckBodyGoldenFixture() throws {
        XCTAssertEqual(
            normalizedDescription(try Packet.Payload(encoding: HelloAckBody(version: 1)).object),
            "{version=uint64(1)}"
        )
        // version 0 in the *body* is the rejection sentinel -- distinct from the
        // envelope's version 0, which only means "not yet negotiated".
        XCTAssertEqual(
            normalizedDescription(try Packet.Payload(encoding: HelloAckBody(version: 0)).object),
            "{version=uint64(0)}"
        )
    }

    // MARK: rejection

    func testRejectsNonDictionary() {
        XCTAssertNil(Packet(rawValue: xpc_string_create("nope")))
    }

    func testRejectsMissingKind() {
        let dict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.version, 1)
        xpc_dictionary_set_value(dict, EnvelopeKey.body, xpc_dictionary_create(nil, nil, 0))
        XCTAssertNil(Packet(rawValue: dict))
    }

    func testRejectsUnknownKind() {
        let dict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.version, 1)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.kind, 99)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.seq, 1)
        xpc_dictionary_set_value(dict, EnvelopeKey.body, xpc_dictionary_create(nil, nil, 0))
        XCTAssertNil(Packet(rawValue: dict))
    }

    func testRejectsWrongTypeForKind() {
        // A string where a uint64 belongs. xpc_dictionary_get_uint64 would silently
        // return 0 here and decode this as a valid request -- which is exactly why
        // the implementation must type-check instead.
        let dict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.version, 1)
        xpc_dictionary_set_string(dict, EnvelopeKey.kind, "0")
        xpc_dictionary_set_uint64(dict, EnvelopeKey.seq, 1)
        xpc_dictionary_set_value(dict, EnvelopeKey.body, xpc_dictionary_create(nil, nil, 0))
        XCTAssertNil(Packet(rawValue: dict))
    }

    func testRejectsBodyThatIsNotADictionary() {
        let dict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.version, 1)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.kind, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.seq, 1)
        xpc_dictionary_set_string(dict, EnvelopeKey.body, "not a dictionary")
        XCTAssertNil(Packet(rawValue: dict))
    }

    func testRejectsMissingBody() {
        let dict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.version, 1)
        xpc_dictionary_set_uint64(dict, EnvelopeKey.kind, 2)
        XCTAssertNil(Packet(rawValue: dict))
    }
}
