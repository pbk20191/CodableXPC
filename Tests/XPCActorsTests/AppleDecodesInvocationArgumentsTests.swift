import XCTest
import XPC
import XPCOverlayCoder
@testable import XPCActors

/// Apple's decoder, driven all the way through an invocation's **arguments**.
///
/// `PacketBodyTests.testAppleDecodesARequestWeEncoded` stops short of this, and it
/// cannot help it: it decodes ``InboundRequest``, and ``EncodedInvocationDecoder`` retains
/// its arguments container *unconsumed* by design -- an argument's static type is not
/// known until `executeDistributedTarget` asks for it. So Apple's decoder opens the
/// `arguments` container there and never reads an element from it, and the header
/// fields it does read (`id`, `remoteCallIdentifier`, `targetedSharedActor`) are all
/// written through concrete overloads.
///
/// That left the interesting half unchecked. `InvocationBody.arguments` is
/// `[any Codable]`, and opening an existential picks the **generic** `encode<T>`
/// witness, so every argument lands as a nested single-value node rather than an
/// inline value. Whether Apple's decoder reads that form back is the question R4
/// turns on, and no test in this package reached it.
///
/// The vehicle is therefore a test-local `Decodable` that decodes the arguments
/// *eagerly*, which the shipping inbound types deliberately do not.
///
/// This is the decode direction only. That Apple's *encoder* produces these same
/// bytes is pinned separately, in `XPCOverlayCoderTests.AppleEncoderParityTests`.
@available(macOS 26, *)
private struct EagerRequest: Decodable, Equatable {
    let id: UInt64
    let target: String
    let firstArgument: Int
    let secondArgument: String
    let thirdArgument: Point

    struct Point: Codable, Equatable {
        let x: Int
        let y: Int
    }

    enum Top: String, CodingKey { case id, remoteCallIdentifier, contents }
    enum Contents: String, CodingKey { case arguments }

    /// Spelled out because `init(from:)` below suppresses the memberwise one.
    init(id: UInt64, target: String,
         firstArgument: Int, secondArgument: String, thirdArgument: Point) {
        self.id = id
        self.target = target
        self.firstArgument = firstArgument
        self.secondArgument = secondArgument
        self.thirdArgument = thirdArgument
    }

    init(from decoder: any Decoder) throws {
        let top = try decoder.container(keyedBy: Top.self)
        // `id` is an `ID64`, which codes as a bare UInt64 through its own
        // single-value conformance -- so reading it as `UInt64` here is the wire
        // fact, not a shortcut.
        id = try top.decode(UInt64.self, forKey: .id)
        target = try top.decode(String.self, forKey: .remoteCallIdentifier)

        let contents = try top.nestedContainer(keyedBy: Contents.self, forKey: .contents)
        var arguments = try contents.nestedUnkeyedContainer(forKey: .arguments)
        // The concrete overloads, on values written through the generic witness.
        // That mismatch is the whole point: it is the combination that failed
        // before the overlay decoder learned to see through the wrapper.
        firstArgument = try arguments.decode(Int.self)
        secondArgument = try arguments.decode(String.self)
        // And a non-primitive argument, which reaches the generic overload on both
        // sides and so exercises a different path through the same container.
        thirdArgument = try arguments.decode(Point.self)
    }
}

@available(macOS 26, *)
final class AppleDecodesInvocationArgumentsTests: XCTestCase {

    private static let request = RemoteInvocationRequest(
        id: ID64(rawValue: 17),
        basePriority: .high,
        targetedSharedActor: .dynamic(ID64(rawValue: 3)),
        remoteCallIdentifier: "$s4Demo7GreeterC5greet4nameSSSS_tYaKFTE",
        contents: InvocationBody(
            protocolStub: nil,
            genericSubsitutions: [],
            arguments: [42 as Int,
                        "hello" as String,
                        EagerRequest.Point(x: 3, y: -4)],
            errorType: SwiftType(mangledTypeName: "s5Error_p"),
            returnType: SwiftType(mangledTypeName: "SS")))

    private static let expected = EagerRequest(
        id: 17,
        target: "$s4Demo7GreeterC5greet4nameSSSS_tYaKFTE",
        firstArgument: 42,
        secondArgument: "hello",
        thirdArgument: .init(x: 3, y: -4))

    override func setUpWithError() throws {
        try XCTSkipUnless(AppleCoderBridge.isAvailable,
                          "XPCReceivedMessage.init(dictionary:) no longer resolves")
    }

    /// The overlay envelope inside the payload -- what a peer's coder is handed.
    private func envelope(of payload: Packet.Payload) throws -> xpc_object_t {
        try XCTUnwrap(xpc_dictionary_get_value(payload.object, EnvelopeKey.payload))
    }

    /// The check the R4 brief called the point of the task: a real invocation, its
    /// arguments included, read back by Apple's own coder.
    func testAppleDecodesTheArgumentsOfARequestWeEncoded() throws {
        let payload = try Packet.Payload(encoding: Self.request, userInfo: [:])
        let decoded = try XCTUnwrap(
            AppleCoderBridge.decode(EagerRequest.self, from: try envelope(of: payload)))
        XCTAssertEqual(decoded, Self.expected)
    }

    /// The same bytes through this package's own decoder, asserted against the same
    /// expectation. Alone it would prove only self-consistency; next to the test
    /// above it says the two decoders agree rather than merely that each works.
    func testOurDecoderAgreesWithAppleOnTheSameBytes() throws {
        let payload = try Packet.Payload(encoding: Self.request, userInfo: [:])
        XCTAssertEqual(try payload.decode(as: EagerRequest.self), Self.expected)
    }
}
