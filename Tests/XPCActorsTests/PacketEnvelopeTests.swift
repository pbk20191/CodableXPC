import XCTest
import XPC
@testable import XPCActors

/// The envelope, pinned against the spec's *Envelope* section.
///
/// Every fixture below is written from
/// `docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md`, which read
/// the shapes out of `Packet.(Header).write(to:)` (`0x2ad4e134c`) and
/// `Packet.(Header).init(from:)` (`0x2ad4e71c0`) in the shipping macOS 27 framework.
/// They are not transcriptions of this package's own output.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class PacketEnvelopeTests: XCTestCase {

    /// A stand-in for the overlay-encoded body.
    ///
    /// The envelope neither reads nor validates the payload -- Apple's
    /// `Packet.init(rawValue:)` only asks `contains(key: "payload")` -- so a marker
    /// keeps these fixtures about the three header entries and nothing else.
    /// `PacketBodyTests` pins what a real body looks like.
    private func markerPayload() -> Packet.Payload {
        Packet.Payload(body: xpc_string_create("BODY"))
    }

    // MARK: golden fixtures

    func testRequestEnvelopeGoldenFixture() {
        let packet = Packet(header: .request(ID64(rawValue: 42)), payload: markerPayload())
        XCTAssertEqual(
            normalizedDescription(packet.rawValue),
            "{headerCategory=uint64(1),headerID=uint64(42),payload=string(BODY)}"
        )
    }

    func testResponseEnvelopeGoldenFixture() {
        let packet = Packet(header: .response(ID64(rawValue: 42)), payload: markerPayload())
        XCTAssertEqual(
            normalizedDescription(packet.rawValue),
            "{headerCategory=uint64(2),headerID=uint64(42),payload=string(BODY)}"
        )
    }

    func testNotificationEnvelopeGoldenFixture() {
        let packet = Packet(header: .notification, payload: markerPayload())
        XCTAssertEqual(
            normalizedDescription(packet.rawValue),
            "{headerCategory=uint64(0),payload=string(BODY)}"
        )
    }

    /// Absent, not null, and therefore two entries rather than three.
    ///
    /// `write(to:)` assigns `nil` through `XPCDictionary`'s subscript, which leaves the
    /// key out; the measurement is recorded in the spec. A written null would be a
    /// third entry and a peer would read a present `headerID`.
    func testANotificationHasTwoEntriesAndARequestHasThree() {
        let notification = Packet(header: .notification, payload: markerPayload()).rawValue
        XCTAssertEqual(xpc_dictionary_get_count(notification), 2)
        XCTAssertNil(xpc_dictionary_get_value(notification, EnvelopeKey.headerID),
                     "headerID must be absent on a notification, not null and not zero")

        let request = Packet(header: .request(ID64(rawValue: 1)),
                             payload: markerPayload()).rawValue
        XCTAssertEqual(xpc_dictionary_get_count(request), 3)
    }

    // MARK: the renumbering
    //
    // The single most breakable fact in this file. `Packet.Header` is a multi-payload
    // enum whose tags are request 0, response 1, notification 2 -- and `write(to:)`
    // renumbers to 1, 2, 0. A test that would still pass if someone "simplified" the
    // writer to emit the enum's own tag is worthless, so this asserts the values
    // directly rather than round-tripping.

    func testTheWireCategoryIsNotTheEnumTag() {
        XCTAssertEqual(PacketHeader.request(ID64(rawValue: 1)).category.rawValue, 1,
                       "a request is 1 on the wire; its enum tag is 0")
        XCTAssertEqual(PacketHeader.response(ID64(rawValue: 1)).category.rawValue, 2,
                       "a response is 2 on the wire; its enum tag is 1")
        XCTAssertEqual(PacketHeader.notification.category.rawValue, 0,
                       "a notification is 0 on the wire; its enum tag is 2")
    }

    func testTheWrittenCategoryMatchesTheRenumbering() {
        let request = Packet(header: .request(ID64(rawValue: 9)), payload: markerPayload())
        XCTAssertEqual(
            Packet.uint64(request.rawValue, EnvelopeKey.headerCategory), 1,
            "a request that writes 0 would be read by a peer as a notification"
        )
    }

    // MARK: round trips

    func testRequestRoundTrips() throws {
        let packet = Packet(header: .request(ID64(rawValue: 42)), payload: markerPayload())
        let decoded = try XCTUnwrap(Packet(rawValue: packet.rawValue))
        XCTAssertEqual(decoded.header, .request(ID64(rawValue: 42)))
    }

    func testResponseRoundTrips() throws {
        let packet = Packet(header: .response(ID64(rawValue: 7)), payload: markerPayload())
        let decoded = try XCTUnwrap(Packet(rawValue: packet.rawValue))
        XCTAssertEqual(decoded.header, .response(ID64(rawValue: 7)))
    }

    func testNotificationRoundTrips() throws {
        let packet = Packet(header: .notification, payload: markerPayload())
        let decoded = try XCTUnwrap(Packet(rawValue: packet.rawValue))
        XCTAssertEqual(decoded.header, .notification)
        XCTAssertNil(decoded.header.id)
    }

    func testTheBodySurvivesTheRoundTrip() throws {
        let packet = Packet(header: .notification, payload: markerPayload())
        let decoded = try XCTUnwrap(Packet(rawValue: packet.rawValue))
        XCTAssertEqual(normalizedDescription(decoded.payload.object), "{payload=string(BODY)}")
    }

    // MARK: decoding messages nobody here built
    //
    // Built as raw `xpc_*` objects rather than by `Packet.rawValue`. This is the tier
    // that caught the R1 hole: a decoder tested only against its own encoder agrees
    // with itself no matter what either of them does.

    private func handBuilt(
        category: UInt64?, id: UInt64?, payload: xpc_object_t? = xpc_string_create("BODY")
    ) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        if let category { xpc_dictionary_set_uint64(message, "headerCategory", category) }
        if let id { xpc_dictionary_set_uint64(message, "headerID", id) }
        if let payload { xpc_dictionary_set_value(message, "payload", payload) }
        return message
    }

    func testDecodesAHandBuiltRequest() throws {
        let packet = try XCTUnwrap(Packet(rawValue: handBuilt(category: 1, id: 5)))
        XCTAssertEqual(packet.header, .request(ID64(rawValue: 5)))
    }

    func testDecodesAHandBuiltResponse() throws {
        let packet = try XCTUnwrap(Packet(rawValue: handBuilt(category: 2, id: 5)))
        XCTAssertEqual(packet.header, .response(ID64(rawValue: 5)))
    }

    func testDecodesAHandBuiltNotification() throws {
        let packet = try XCTUnwrap(Packet(rawValue: handBuilt(category: 0, id: nil)))
        XCTAssertEqual(packet.header, .notification)
    }

    /// `headerCategory == 0` yields `notification` and `headerID` is never even read.
    /// A decoder that read it anyway and rejected the surplus would drop traffic a
    /// real peer accepts.
    func testANotificationCarryingAHeaderIDIsStillANotification() throws {
        let packet = try XCTUnwrap(Packet(rawValue: handBuilt(category: 0, id: 99)))
        XCTAssertEqual(packet.header, .notification)
    }

    /// `xpc_int64` is what a peer built on a signed getter would emit. Apple's
    /// getters accept it; ours does not, and that is a deliberate narrowing recorded
    /// in the report rather than an oversight -- we only ever *emit* `xpc_uint64`.
    func testAnInt64CategoryIsRejected() {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(message, "headerCategory", 1)
        xpc_dictionary_set_int64(message, "headerID", 5)
        xpc_dictionary_set_value(message, "payload", xpc_string_create("BODY"))
        XCTAssertNil(Packet(rawValue: message))
    }

    // MARK: rejection
    //
    // Every rule in `Header.init(from:)` is a rejection rather than a default.

    func testRejectsANonDictionary() {
        XCTAssertNil(Packet(rawValue: xpc_string_create("nope")))
    }

    func testRejectsAMissingHeaderCategory() {
        XCTAssertNil(Packet(rawValue: handBuilt(category: nil, id: 5)))
    }

    func testRejectsAHeaderCategoryOfThree() {
        XCTAssertNil(Packet(rawValue: handBuilt(category: 3, id: 5)))
    }

    func testRejectsARequestWithNoHeaderID() {
        XCTAssertNil(Packet(rawValue: handBuilt(category: 1, id: nil)))
    }

    func testRejectsAResponseWithNoHeaderID() {
        XCTAssertNil(Packet(rawValue: handBuilt(category: 2, id: nil)))
    }

    func testRejectsAMessageWithNoPayload() {
        XCTAssertNil(Packet(rawValue: handBuilt(category: 1, id: 5, payload: nil)))
        XCTAssertNil(Packet(rawValue: handBuilt(category: 0, id: nil, payload: nil)))
    }

    /// `xpc_dictionary_get_uint64` returns 0 for both "missing" and "wrong type", so a
    /// decoder built on it would read this string as `headerCategory == 0` and turn a
    /// malformed message into a notification.
    func testRejectsAHeaderCategoryOfTheWrongXPCType() {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "headerCategory", "1")
        xpc_dictionary_set_uint64(message, "headerID", 5)
        xpc_dictionary_set_value(message, "payload", xpc_string_create("BODY"))
        XCTAssertNil(Packet(rawValue: message))
    }

    func testRejectsAHeaderIDOfTheWrongXPCType() {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, "headerCategory", 1)
        xpc_dictionary_set_string(message, "headerID", "5")
        xpc_dictionary_set_value(message, "payload", xpc_string_create("BODY"))
        XCTAssertNil(Packet(rawValue: message))
    }

    // MARK: leniency

    /// Unknown keys are ignored rather than rejected, which is what Apple's decoder
    /// does: it checks the three it wants and looks at nothing else.
    func testUnknownKeysAreIgnored() throws {
        let message = handBuilt(category: 1, id: 5)
        xpc_dictionary_set_string(message, "somethingNewer", "from a later peer")
        let packet = try XCTUnwrap(Packet(rawValue: message))
        XCTAssertEqual(packet.header, .request(ID64(rawValue: 5)))
    }

    // MARK: the handshake is gone

    /// Nothing named `hello`, `helloAck`, or `version` survives in the envelope.
    ///
    /// Apple's `XPCDistributed` has no such packet kinds and no version field; a real
    /// peer receiving one fails to decode a category it has no case for. Asserted over
    /// the written keys rather than by grepping the source, so a re-introduction shows
    /// up as a wire fact.
    func testTheEnvelopeCarriesNoVersionAndNoHandshake() {
        for header in [PacketHeader.request(ID64(rawValue: 1)),
                       .response(ID64(rawValue: 1)),
                       .notification] {
            let raw = Packet(header: header, payload: markerPayload()).rawValue
            var keys: Set<String> = []
            xpc_dictionary_apply(raw) { key, _ in
                keys.insert(String(cString: key))
                return true
            }
            XCTAssertTrue(keys.isSubset(of: ["headerCategory", "headerID", "payload"]),
                          "unexpected envelope keys: \(keys)")
            for gone in ["version", "kind", "seq", "body", "hello", "helloAck"] {
                XCTAssertFalse(keys.contains(gone), "\(gone) must not be on the wire")
            }
        }
    }

    /// The three key names, spelled out. Both header names are Swift small strings
    /// built from `movz`/`movk` immediates in the shipping binary, so they appear in no
    /// string table and were decoded from the immediates at their call sites; that is
    /// exactly the kind of fact a constant can drift away from unnoticed.
    func testTheEnvelopeKeyNames() {
        XCTAssertEqual(EnvelopeKey.headerCategory, "headerCategory")
        XCTAssertEqual(EnvelopeKey.headerID, "headerID")
        XCTAssertEqual(EnvelopeKey.payload, "payload")
    }
}
