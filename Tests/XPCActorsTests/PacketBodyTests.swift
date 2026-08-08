import XCTest
import XPC
import CodableXPC
import XPCOverlayCoder
@testable import XPCActors

/// Where the shape work of R1--R3 meets the encoder that actually runs.
///
/// Those rounds pinned the invocation bodies at the `Codable` level, through a
/// native-xpc encoder. That was a legitimate way to pin *shape* -- which containers
/// each conformance opens, which keys it writes, which optionals it omits -- and it is
/// not the wire. The wire is `XPCDictionary.encode(_:forKey:withUserInfo:)`, which
/// routes through the XPC overlay's Codable coder and produces one `xpc_data` byte
/// stream. This file drives the same bodies through that path.
///
/// The strongest check available here is the last one in each pair: `AppleCoderBridge`
/// runs Apple's own decoder in-process against the bytes we produced. It is as close to
/// a real peer as this repository can get.
@available(macOS 14, *)
private final class StubSession: SessionCoding, @unchecked Sendable {
    func shareDynamically(_ local: RawActorID.Local) -> SharedActorKey? {
        .dynamic(ID64(rawValue: 1))
    }
    func remoteID(for key: SharedActorKey) -> ActorID {
        ActorID(raw: .remote(.init(session: self, key: key)))
    }
}

@available(macOS 14, *)
final class PacketBodyTests: XCTestCase {

    private static let request = RemoteInvocationRequest(
        id: ID64(rawValue: 17),
        basePriority: .high,
        targetedSharedActor: .dynamic(ID64(rawValue: 3)),
        remoteCallIdentifier: "$s4Demo7GreeterC5greet4nameSSSS_tYaKFTE",
        contents: InvocationBody(
            protocolStub: nil,
            genericSubsitutions: [],
            arguments: [42 as Int, "hello" as String],
            errorType: SwiftType(mangledTypeName: "s5Error_p"),
            returnType: SwiftType(mangledTypeName: "SS")))

    /// The overlay envelope inside a payload -- what a peer's coder is handed.
    private func envelope(of payload: Packet.Payload) throws -> xpc_object_t {
        try XCTUnwrap(xpc_dictionary_get_value(payload.object, EnvelopeKey.payload))
    }

    private func assertBodyIsAByteStream(
        _ payload: Packet.Payload, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let body = try XCTUnwrap(
            xpc_dictionary_get_value(try envelope(of: payload), OverlayEnvelope.body),
            file: file, line: line)
        XCTAssertEqual(xpc_get_type(body), XPC_TYPE_DATA,
                       "the body must be a byte stream, not an xpc structure",
                       file: file, line: line)
    }

    // MARK: the request

    func testARequestSurvivesTheRealEncoder() throws {
        let payload = try Packet.Payload(encoding: Self.request)
        try assertBodyIsAByteStream(payload)

        let decoded = try payload.decode(as: InboundRequest.self)
        XCTAssertEqual(decoded.id, ID64(rawValue: 17))
        XCTAssertEqual(decoded.basePriority, .high)
        XCTAssertEqual(decoded.targetedSharedActor, .dynamic(ID64(rawValue: 3)))
        XCTAssertEqual(decoded.remoteCallIdentifier,
                       "$s4Demo7GreeterC5greet4nameSSSS_tYaKFTE")
        XCTAssertEqual(decoded.contents.errorType?.mangledTypeName, "s5Error_p")
        XCTAssertEqual(decoded.contents.returnType?.mangledTypeName, "SS")
        XCTAssertNil(decoded.contents.protocolStub)
        XCTAssertEqual(decoded.contents.genericSubsitutions, [])

        var arguments = decoded.contents.argumentsContainer
        XCTAssertEqual(try arguments.decode(Int.self), 42)
        XCTAssertEqual(try arguments.decode(String.self), "hello")
    }

    func testAppleDecodesARequestWeEncoded() throws {
        try XCTSkipUnless(AppleCoderBridge.isAvailable,
                          "XPCReceivedMessage.init(dictionary:) no longer resolves")
        let payload = try Packet.Payload(encoding: Self.request)
        let decoded = try XCTUnwrap(
            AppleCoderBridge.decode(InboundRequest.self, from: try envelope(of: payload)))
        XCTAssertEqual(decoded.id, ID64(rawValue: 17))
        XCTAssertEqual(decoded.remoteCallIdentifier,
                       "$s4Demo7GreeterC5greet4nameSSSS_tYaKFTE")
        XCTAssertEqual(decoded.targetedSharedActor, .dynamic(ID64(rawValue: 3)))
    }

    /// An `ActorID` codes itself against the session in `userInfo`, and the payload is
    /// the only place that `userInfo` can enter. If threading it broke, this argument
    /// would trap rather than encode.
    func testUserInfoStillCarriesTheSessionThroughARealBody() throws {
        let session = StubSession()
        let local = RawActorID.Local(systemID: ID64(rawValue: 1),
                                     instanceID: ID64(rawValue: 2))
        let request = RemoteInvocationRequest(
            id: ID64(rawValue: 1), basePriority: nil,
            targetedSharedActor: .dynamic(ID64(rawValue: 3)),
            remoteCallIdentifier: "target",
            contents: InvocationBody(
                protocolStub: nil, genericSubsitutions: [],
                arguments: [ActorID(raw: .local(local))],
                errorType: nil, returnType: nil))

        let payload = try Packet.Payload(
            encoding: request, userInfo: [.xpcActorSession: session])
        var arguments = try payload
            .decode(as: InboundRequest.self, userInfo: [.xpcActorSession: session])
            .contents.argumentsContainer
        // The local id was shared dynamically and comes back as a remote proxy id.
        let recovered = try arguments.decode(ActorID.self)
        guard case .remote(let remote) = recovered.raw else {
            return XCTFail("expected a remote id, got \(recovered.raw)")
        }
        XCTAssertEqual(remote.key, .dynamic(ID64(rawValue: 1)))
    }

    // MARK: the response

    func testAResponseFailureSurvivesTheRealEncoder() throws {
        let payload = try Packet.Payload(
            encoding: RemoteInvocationResponse(executionFailure: "boom"))
        try assertBodyIsAByteStream(payload)
        XCTAssertEqual(try payload.decode(as: RemoteInvocationResponse.self),
                       .failure(.executionFailed("boom")))
    }

    func testAPropagationFailureSurvivesTheRealEncoder() throws {
        let payload = try Packet.Payload(
            encoding: RemoteInvocationResponse(resultPropagationFailure: "no reply"))
        try assertBodyIsAByteStream(payload)
        XCTAssertEqual(try payload.decode(as: RemoteInvocationResponse.self),
                       .failure(.resultPropagationFailed("no reply")))
    }

    func testAppleDecodesAResponseFailureWeEncoded() throws {
        try XCTSkipUnless(AppleCoderBridge.isAvailable,
                          "XPCReceivedMessage.init(dictionary:) no longer resolves")
        let payload = try Packet.Payload(
            encoding: RemoteInvocationResponse(executionFailure: "boom"))
        XCTAssertEqual(
            try AppleCoderBridge.decode(RemoteInvocationResponse.self,
                                        from: try envelope(of: payload)),
            .failure(.executionFailed("boom")))
    }

    /// **A defect pinned, not a behaviour endorsed.**
    ///
    /// The failure half of a response crosses the real encoder; the success half does
    /// not, and cannot. `RemoteInvocationResponse.result` carries an `XPCNativeObject`,
    /// whose `Codable` conformance throws for every coder but `CodableXPC`'s
    /// `XPCEncoder` -- deliberately, because no other coder can place a live xpc object
    /// in a graph it does not build. The R4 brief's §4.5 asks for a Void success to
    /// survive `Payload(encoding:)`, and that is not reachable without changing the
    /// response type, which R4 is told not to touch.
    ///
    /// The reasoning behind `XPCNativeObject` was "our transport decodes the envelope
    /// before the call site's return type is in scope, so hold the result undecoded".
    /// That reasoning was sound against a native-xpc body and does not survive a byte
    /// stream: there is no live object to hold. Apple does not have the problem because
    /// `RemoteInvocationResponse<A>` is generic and `sendInvocation<A>` decodes at the
    /// call site, where `A` is known.
    ///
    /// So the fix belongs with whoever owns the response type: make it generic over the
    /// result, as Apple's is. Until then this asserts the exact wall, so that the day
    /// the type changes this test fails and says why.
    func testTheSuccessHalfOfAResponseCannotYetCrossTheRealEncoder() {
        let cases: [(String, RemoteInvocationResponse)] = [
            ("void", .void),
            ("result", try! RemoteInvocationResponse(result: 42 as Int, userInfo: [:])),
        ]
        for (label, response) in cases {
            XCTAssertThrowsError(try Packet.Payload(encoding: response), label) { error in
                guard case EncodingError.invalidValue(let value, _) = error else {
                    return XCTFail("\(label): expected an EncodingError, got \(error)")
                }
                XCTAssertTrue(value is XPCNativeObject,
                              "\(label): the wall is XPCNativeObject, not something new: \(value)")
            }
        }
    }

    /// And the shape is still right, which is what makes the wall an encoder problem
    /// rather than a wire one: `[0, <result>]`, tag first. Pinned through the same
    /// native-xpc coder R1--R3 used, since that is the only coder that can run it.
    func testTheSuccessShapeIsStillTheUnkeyedPair() throws {
        XCTAssertEqual(
            normalizedDescription(try XPCEncoder().encode(RemoteInvocationResponse.void)),
            "[uint64(0),dict{}]")
    }

    // MARK: the notification

    func testANotificationBodySurvivesTheRealEncoder() throws {
        let payload = try Packet.Payload(
            encoding: RemoteNotification.invocationCancelled(id: ID64(rawValue: 17)))
        try assertBodyIsAByteStream(payload)
        XCTAssertEqual(try payload.decode(as: RemoteNotification.self),
                       .invocationCancelled(id: ID64(rawValue: 17)))
    }

    func testAppleDecodesANotificationWeEncoded() throws {
        try XCTSkipUnless(AppleCoderBridge.isAvailable,
                          "XPCReceivedMessage.init(dictionary:) no longer resolves")
        let payload = try Packet.Payload(
            encoding: RemoteNotification.invocationEscalated(id: ID64(rawValue: 5),
                                                             priority: .background))
        XCTAssertEqual(
            try AppleCoderBridge.decode(RemoteNotification.self,
                                        from: try envelope(of: payload)),
            .invocationEscalated(id: ID64(rawValue: 5), priority: .background))
    }
}
