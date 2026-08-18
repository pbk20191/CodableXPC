// Tests/XPCActorsTests/ActorIDTests.swift
import XCTest
import XPC
import CodableXPC
@testable import XPCActors

/// Stands in for a `Session`, so identity can be tested with no transport.
@available(macOS 26, *)
final class ActorIDTests: XCTestCase {

    private func userInfo(_ session: StubSession) -> [CodingUserInfoKey: Any] {
        [.xpcActorSession: session]
    }

    // MARK: the counter

    func testID64IsMonotonicAndUnique() {
        let ids = (0..<1000).map { _ in ID64.next() }
        XCTAssertEqual(Set(ids).count, 1000)
        XCTAssertEqual(ids, ids.sorted { $0.rawValue < $1.rawValue })
    }

    // MARK: encoding a local id shares it

    func testALocalIDEncodesAsTheSharedKeyAndNothingElse() throws {
        let session = StubSession()
        let local = RawActorID.Local(systemID: ID64.next(), instanceID: ID64.next())
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(session)

        let object = try encoder.encode(ActorID(raw: .local(local)))

        XCTAssertEqual(normalizedDescription(object), "[uint64(2),uint64(1)]")
        XCTAssertEqual(session.shared, [local])
    }

    /// The whole point: the process-local halves are not on the wire in any form.
    func testNeitherHalfOfALocalIDIsTransmitted() throws {
        let session = StubSession()
        let local = RawActorID.Local(systemID: ID64(rawValue: 111), instanceID: ID64(rawValue: 222))
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(session)

        let rendered = normalizedDescription(try encoder.encode(ActorID(raw: .local(local))))
        XCTAssertFalse(rendered.contains("111"))
        XCTAssertFalse(rendered.contains("222"))
    }

    // MARK: encoding a remote id is refused

    /// This test used to assert the opposite -- that a remote id sends its own key
    /// back unchanged. That was the bug. A `SharedActorKey` is only meaningful in the
    /// key space of the side that minted it, and both sides' `dynamic` counters start
    /// at 1, so writing a proxy's key into any session lies about which actor it names.
    ///
    /// Apple's `ActorID.encode(to:)` traps here (`"Cannot send remote actor proxies
    /// over an session."`). We keep the rule and throw instead: the value shape is
    /// peer-influenced, so it has to be diagnosable rather than fatal.
    ///
    /// The cost is Apple's too and is worth naming: a proxy cannot be passed on, to
    /// the peer it came from or to a third party. Supporting that needs the two key
    /// spaces made attributable first, which is a feature, not a repair.
    func testARemoteIDRefusesToEncode() throws {
        let session = StubSession()
        let id = session.remoteID(for: .exportedRawValue("primary"))
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(session)

        XCTAssertThrowsError(try encoder.encode(id)) { error in
            guard case EncodingError.invalidValue = error else {
                return XCTFail("expected EncodingError.invalidValue, got \(error)")
            }
        }
        XCTAssertTrue(session.shared.isEmpty, "and it must not be shared as a way round it")
    }

    // MARK: decoding

    func testDecodingProducesARemoteIDBoundToTheDecodingSession() throws {
        let session = StubSession()
        let object = try XPCEncoder().encode(SharedActorKey.exportedRawValue("primary"))
        var decoder = XPCDecoder()
        decoder.userInfo = userInfo(session)

        let id = try decoder.decode(ActorID.self, from: object)
        guard case .remote(let remote) = id.raw else { return XCTFail("expected a remote id") }
        XCTAssertEqual(remote.key, .exportedRawValue("primary"))
        XCTAssertTrue(remote.session === session)
    }

    func testDecodingWithNoSessionThrows() throws {
        let object = try XPCEncoder().encode(SharedActorKey.exportedRawValue("primary"))
        XCTAssertThrowsError(try XPCDecoder().decode(ActorID.self, from: object))
    }

    func testEncodingFailsWhenTheSessionRefusesToShare() throws {
        let session = StubSession()
        session.refuseToShare = true
        var encoder = XPCEncoder()
        encoder.userInfo = userInfo(session)
        let id = ActorID(raw: .local(.init(systemID: ID64.next(), instanceID: ID64.next())))
        XCTAssertThrowsError(try encoder.encode(id))
    }

    // MARK: equality

    func testRemoteIdentityComparesTheSessionByIdentity() {
        let a = StubSession(), b = StubSession()
        XCTAssertEqual(a.remoteID(for: .exportedRawValue("x")), a.remoteID(for: .exportedRawValue("x")))
        XCTAssertNotEqual(a.remoteID(for: .exportedRawValue("x")), b.remoteID(for: .exportedRawValue("x")))
        XCTAssertNotEqual(a.remoteID(for: .exportedRawValue("x")), a.remoteID(for: .exportedRawValue("y")))
    }

    func testLocalAndRemoteAreNeverEqual() {
        let session = StubSession()
        let local = ActorID(raw: .local(.init(systemID: ID64(rawValue: 1), instanceID: ID64(rawValue: 2))))
        XCTAssertNotEqual(local, session.remoteID(for: .dynamic(ID64(rawValue: 1))))
    }
}
