#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCOverlayCoder

// MARK: - fixtures
//
// Each pair below writes the *same* value two ways, and the difference is the only
// thing under test: which `encode` overload the containers resolve to.
//
// `try container.encode(value)` where `value` is `any Encodable` opens the
// existential, and opening picks the **generic** `encode<T: Encodable>` witness --
// never `encode(Int)`, even when the dynamic type is `Int`. The generic witness gives
// the value a child node and `Int.encode(to:)` then opens a single-value container
// inside it, so the value lands as a *nested single-value node*. Written through the
// concrete overload the same `Int` is inline.
//
// Both forms are legal Codable. Which one Apple emits is not a matter of taste -- it
// decides whether this package's bytes are the bytes a peer would have produced.

/// One value through the generic witness, under a key.
@available(macOS 15, macCatalyst 18, *)
private struct KeyedExistential: Encodable {
    let value: any Encodable
    enum Key: String, CodingKey { case value }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(value, forKey: .value)
    }
}

/// The same `Int` under the same key, through the concrete `encode(Int, forKey:)`.
/// The control: if this one ever disagrees, the disagreement is not about
/// existentials.
@available(macOS 15, macCatalyst 18, *)
private struct KeyedConcrete: Encodable {
    let value: Int
    enum Key: String, CodingKey { case value }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(value, forKey: .value)
    }
}

/// Positional arguments, which is the shape `XPCActors.InvocationBody` writes: an
/// unkeyed container fed from `[any Codable]`, one generic `encode` per element.
@available(macOS 15, macCatalyst 18, *)
private struct UnkeyedExistential: Encodable {
    let values: [any Encodable]
    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in values { try container.encode(value) }
    }
}

/// Apple's encoder, byte for byte, on the shapes that turn on overload resolution.
///
/// `AppleRoundTripTests.testOurBodyIsByteIdenticalToApples` already pins this for a
/// value whose every property is a stored primitive, and those resolve to the
/// *concrete* `encode` overloads. That leaves the case this file exists for
/// untested: a value reached through the **generic** witness, which is what opening
/// an existential picks and therefore what every `[any Codable]` argument list hits.
///
/// It is worth its own file because it settled a real question rather than
/// documenting a settled one. This package's decoder could not read its own
/// encoder's output for exactly these shapes -- the container requests saw through
/// the encoder's single-value wrapper and the primitive path did not. Two fixes were
/// available and they are not equivalent: loosen the decoder, or make the encoder
/// stop emitting the wrapper. Only one of them keeps our bytes equal to Apple's, and
/// nothing internal to this package can say which. These tests say which.
///
/// ## Why no private symbol is needed
///
/// `XPCReceivedMessage.encodeMessage` is exported under no name at all, so unlike
/// ``AppleCoderBridge`` there is nothing to `dlsym` and no calling convention to get
/// right. Its *output* needs no bridge: anything Apple sends went through it. An
/// anonymous `XPCListener` accepted with the `(XPCDictionary) -> XPCDictionary?`
/// handler -- the untyped overload on `IncomingSessionRequest`, which hands over the
/// message before any decoder runs -- yields the raw dictionary Apple built. Every
/// call below is public XPC overlay API.
///
/// macOS 15 is the floor because the anonymous `XPCListener()` initialiser, the
/// `endpoint` property, and `XPCSession(endpoint:)` all arrived there. That is a
/// limit on the test, not on the coder.
@available(macOS 15, macCatalyst 18, *)
final class AppleEncoderParityTests: XCTestCase {

    // MARK: reaching Apple's encoder


    /// Assert the two encoders agree, and render both as hex when they do not --
    /// a `Data` inequality failure alone says nothing about *where* they diverged.
    private func assertParity(
        _ value: some Encodable, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let theirs = try captureAppleBody(value)
        let ours = try XPCOverlayEncoder().encode(value).body
        XCTAssertEqual(ours, theirs, """
            \(message)
              apple: \(hex(theirs))
              ours:  \(hex(ours))
            """, file: file, line: line)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    // MARK: the environment

    /// A live anonymous listener is the one thing here that can be unavailable --
    /// a restricted sandbox can refuse to stand one up. Checked once, so a refusal
    /// reports as a skip rather than as four failures about byte equality.
    private static let canStandUpALocalSession: Bool = {
        do {
            let listener = XPCListener(targetQueue: nil, options: .inactive) { request in
                request.accept { (_: XPCDictionary) -> XPCDictionary? in nil }
            }
            try listener.activate()
            defer { listener.cancel() }
            let session = try XPCSession(endpoint: listener.endpoint, options: .inactive)
            try session.activate()
            session.cancel(reason: "probe")
            return true
        } catch {
            return false
        }
    }()

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.canStandUpALocalSession,
                          "an anonymous XPCListener/XPCSession pair cannot be created here")
    }

    // MARK: parity

    /// The case the whole file is for. If Apple wrote the value inline here, this
    /// package's encoder would be emitting a wrapper node no peer expects, and the
    /// decoder fix that taught us to read it would have cemented the divergence
    /// instead of removing one.
    func testAKeyedGenericPrimitiveMatchesApple() throws {
        try assertParity(KeyedExistential(value: 7 as Int),
                         "a generic-witness Int under a key")
    }

    /// The control. Same key, same value, concrete overload.
    func testAKeyedConcretePrimitiveMatchesApple() throws {
        try assertParity(KeyedConcrete(value: 7),
                         "a concrete-overload Int under a key")
    }

    /// The two forms must also differ from *each other*, or the pair above proves
    /// nothing: if the encoder emitted the same bytes either way, both tests would
    /// pass while the distinction they exist to check had quietly disappeared.
    func testTheTwoFormsAreGenuinelyDifferentBytes() throws {
        let generic = try XPCOverlayEncoder().encode(KeyedExistential(value: 7 as Int)).body
        let concrete = try XPCOverlayEncoder().encode(KeyedConcrete(value: 7)).body
        XCTAssertNotEqual(generic, concrete, """
            the generic and concrete overloads are supposed to encode differently; \
            if they no longer do, the parity tests above are vacuous
            """)
    }

    /// Positional arguments: the shape `XPCActors` puts every invocation argument
    /// through, and mixed types so a per-element tag error cannot cancel out.
    func testAnUnkeyedGenericPairMatchesApple() throws {
        try assertParity(UnkeyedExistential(values: [7 as Int, "hi" as String]),
                         "generic-witness Int and String in an unkeyed container")
    }

    /// `[UInt8]` reaches the generic witness once per element -- `Array`'s
    /// conformance calls `decode(Element.self)` on a generic parameter -- so every
    /// byte is its own nested node. Included because it is the shape most likely to
    /// tempt someone into a bulk-bytes shortcut, and `Data` (which really does go
    /// out of line) encodes nothing like it.
    func testAnArrayOfBytesMatchesApple() throws {
        try assertParity([UInt8]([1, 2, 3]),
                         "an array of UInt8, one generic-witness element each")
    }
}
#endif
