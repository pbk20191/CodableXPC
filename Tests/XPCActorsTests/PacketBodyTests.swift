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
        let payload = try Packet.Payload(encoding: Self.request, userInfo: [:])
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
        let payload = try Packet.Payload(encoding: Self.request, userInfo: [:])
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
            encoding: RemoteInvocationResponse<Never>(executionFailure: "boom"), userInfo: [:])
        try assertBodyIsAByteStream(payload)
        XCTAssertEqual(try payload.decode(as: RemoteInvocationResponse<Never>.self),
                       .failure(.executionFailed("boom")))
    }

    func testAPropagationFailureSurvivesTheRealEncoder() throws {
        let payload = try Packet.Payload(
            encoding: RemoteInvocationResponse<Never>(resultPropagationFailure: "no reply"), userInfo: [:])
        try assertBodyIsAByteStream(payload)
        XCTAssertEqual(try payload.decode(as: RemoteInvocationResponse<Never>.self),
                       .failure(.resultPropagationFailed("no reply")))
    }

    func testAppleDecodesAResponseFailureWeEncoded() throws {
        try XCTSkipUnless(AppleCoderBridge.isAvailable,
                          "XPCReceivedMessage.init(dictionary:) no longer resolves")
        let payload = try Packet.Payload(
            encoding: RemoteInvocationResponse<Never>(executionFailure: "boom"), userInfo: [:])
        XCTAssertEqual(
            try AppleCoderBridge.decode(RemoteInvocationResponse<Never>.self,
                                        from: try envelope(of: payload)),
            .failure(.executionFailed("boom")))
    }

    /// **The wall from R4 is gone.**
    ///
    /// This replaces `testTheSuccessHalfOfAResponseCannotYetCrossTheRealEncoder`, which
    /// asserted the opposite and was right to: `RemoteInvocationResponse.result` held an
    /// `XPCNativeObject`, whose `Codable` conformance throws for every coder but
    /// `CodableXPC`'s native-xpc `XPCEncoder`, so a success response could not cross the
    /// byte-stream encoder at all. The response is generic over its success type now, as
    /// Apple's `RemoteInvocationResponse<A>` is, and there is no erased object left to
    /// refuse. The old test is deliberately deleted, not disabled -- its subject no
    /// longer exists.
    func testTheSuccessHalfOfAResponseCrossesTheRealEncoder() throws {
        let payload = try Packet.Payload(encoding: RemoteInvocationResponse<Int>.result(42), userInfo: [:])
        try assertBodyIsAByteStream(payload)
        XCTAssertEqual(try payload.decode(as: RemoteInvocationResponse<Int>.self),
                       .result(42))

        let text = try Packet.Payload(encoding: RemoteInvocationResponse<String>.result("hi"), userInfo: [:])
        try assertBodyIsAByteStream(text)
        XCTAssertEqual(try text.decode(as: RemoteInvocationResponse<String>.self),
                       .result("hi"))
    }

    /// And a void success, which is the case the R4 brief asked for and could not have.
    /// The payload is Apple's `Ack` -- see
    /// `InvocationBodiesTests.testAVoidSuccessIsTagZeroAndAnEmptyDictionary` for the
    /// call chain that resolves it.
    func testAVoidSuccessCrossesTheRealEncoder() throws {
        let payload = try Packet.Payload(encoding: RemoteInvocationResponse<Ack>.void, userInfo: [:])
        try assertBodyIsAByteStream(payload)
        XCTAssertEqual(try payload.decode(as: RemoteInvocationResponse<Ack>.self), .void)
    }

    /// The case that could not exist before R5: Apple's own decoder reading a *success*
    /// response we encoded. Every earlier response check through this bridge was a
    /// failure, because the success half could not be encoded.
    func testAppleDecodesASuccessResponseWeEncoded() throws {
        try XCTSkipUnless(AppleCoderBridge.isAvailable,
                          "XPCReceivedMessage.init(dictionary:) no longer resolves")
        let payload = try Packet.Payload(encoding: RemoteInvocationResponse<Int>.result(42), userInfo: [:])
        XCTAssertEqual(
            try AppleCoderBridge.decode(RemoteInvocationResponse<Int>.self,
                                        from: try envelope(of: payload)),
            .result(42))

        let void = try Packet.Payload(encoding: RemoteInvocationResponse<Ack>.void, userInfo: [:])
        XCTAssertEqual(
            try AppleCoderBridge.decode(RemoteInvocationResponse<Ack>.self,
                                        from: try envelope(of: void)),
            .void)
    }

    /// A result carrying an `ActorID` still codes against the session in `userInfo`.
    ///
    /// This is the property `init(result:userInfo:)` existed to protect. That
    /// initializer pre-encoded the value so that its `userInfo` was the only one the
    /// value would ever see, and trapped loudly if a session was missing. With the
    /// erasure gone there is nothing to pre-encode: the response is encoded once, here,
    /// against the payload's `userInfo`, exactly like a request's arguments.
    func testAResultCarryingAnActorIDCodesAgainstTheSessionInUserInfo() throws {
        let session = StubSession()
        let local = ActorID(raw: .local(.init(systemID: ID64(rawValue: 1),
                                              instanceID: ID64(rawValue: 2))))
        let payload = try Packet.Payload(
            encoding: RemoteInvocationResponse<ActorID>.result(local),
            userInfo: [.xpcActorSession: session])
        try assertBodyIsAByteStream(payload)

        let decoded = try payload.decode(as: RemoteInvocationResponse<ActorID>.self,
                                         userInfo: [.xpcActorSession: session])
        guard case .result(let recovered) = decoded,
              case .remote(let remote) = recovered.raw else {
            return XCTFail("expected a remote id, got \(decoded)")
        }
        XCTAssertEqual(remote.key, .dynamic(ID64(rawValue: 1)))
    }

    /// The wire shape is unchanged by the redesign: `[0, <result>]`, tag first. Pinned
    /// through the native-xpc coder R1--R3 used, which is where the golden fixtures live.
    func testTheSuccessShapeIsStillTheUnkeyedPair() throws {
        XCTAssertEqual(
            normalizedDescription(
                try XPCEncoder().encode(RemoteInvocationResponse<Ack>.void)),
            "[uint64(0),dict{}]")
        XCTAssertEqual(
            normalizedDescription(
                try XPCEncoder().encode(RemoteInvocationResponse<Int>.result(42))),
            "[uint64(0),int64(42)]")
    }

    // MARK: the notification

    func testANotificationBodySurvivesTheRealEncoder() throws {
        let payload = try Packet.Payload(
            encoding: RemoteNotification.invocationCancelled(id: ID64(rawValue: 17)), userInfo: [:])
        try assertBodyIsAByteStream(payload)
        XCTAssertEqual(try payload.decode(as: RemoteNotification.self),
                       .invocationCancelled(id: ID64(rawValue: 17)))
    }

    func testAppleDecodesANotificationWeEncoded() throws {
        try XCTSkipUnless(AppleCoderBridge.isAvailable,
                          "XPCReceivedMessage.init(dictionary:) no longer resolves")
        let payload = try Packet.Payload(
            encoding: RemoteNotification.invocationEscalated(id: ID64(rawValue: 5),
                                                             priority: .background), userInfo: [:])
        XCTAssertEqual(
            try AppleCoderBridge.decode(RemoteNotification.self,
                                        from: try envelope(of: payload)),
            .invocationEscalated(id: ID64(rawValue: 5), priority: .background))
    }
}
