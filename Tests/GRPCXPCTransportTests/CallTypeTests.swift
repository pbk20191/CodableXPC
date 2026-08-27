import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

/// The end-to-end spine: a real `GRPCClient` and a real `GRPCServer` talking over two real XPC
/// sessions in this process, and all four gRPC call types across it.
///
/// Every case here is the first observation of behaviour that seven previous tasks could only
/// argue for by reading. They assert **payloads**, not merely that nothing threw: a transport that
/// completed every call while delivering the wrong bytes would pass a "did it throw" suite.
///
/// Payloads are all comfortably past `Data`'s 14-byte inline-storage threshold, so the messages
/// that cross libxpc are the ones `GRPCSwiftData` actually borrows rather than copies. That does
/// not *prove* the borrow (`GRPCSwiftDataTests` does that, by comparing base addresses) but it
/// keeps these cases on the same side of the boundary as real traffic.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class CallTypeTests: XCTestCase {

    // =======================================================================================
    // MARK: - The service
    // =======================================================================================

    private static let serviceName = "xpc.spine.Echo"

    private static let unary = MethodDescriptor(
        fullyQualifiedService: serviceName, method: "Unary")
    private static let metadataEcho = MethodDescriptor(
        fullyQualifiedService: serviceName, method: "MetadataEcho")
    private static let failing = MethodDescriptor(
        fullyQualifiedService: serviceName, method: "Failing")
    private static let clientStream = MethodDescriptor(
        fullyQualifiedService: serviceName, method: "ClientStream")
    private static let serverStream = MethodDescriptor(
        fullyQualifiedService: serviceName, method: "ServerStream")
    private static let bidi = MethodDescriptor(
        fullyQualifiedService: serviceName, method: "Bidi")

    /// Long enough that every message crossing the wire is past `Data`'s 14-byte inline threshold.
    private static func payload(_ n: Int) -> String { "spine-payload-\(String(format: "%04d", n))" }

    /// The reply the failing method rejects with. `.permissionDenied` rather than `.unavailable` or
    /// `.internalError` on purpose: those two are what the *transport* produces when something has
    /// gone wrong, so a test asserting one of them could pass on a broken connection. Nothing in
    /// the transport ever synthesises `.permissionDenied`, so seeing it at the client proves the
    /// handler's status crossed the wire.
    private static let refusal = RPCError(
        code: .permissionDenied, message: "the spine refuses this call on purpose")

    /// How many messages the server-streaming and bidi methods exchange.
    private static let streamLength = 5

    /// One router serving all six methods.
    ///
    /// Handlers read `request.messages` to completion before replying wherever the call type allows
    /// it, which is what makes the client's `halfClose` observable: a handler that replied without
    /// draining would pass even if `halfClose` never arrived.
    private static func router() -> RPCRouter<XPCServerTransport> {
        var router = RPCRouter<XPCServerTransport>()

        // --- unary: one message in, one message out ---
        router.registerHandler(
            forMethod: unary,
            deserializer: UTF8Deserializer(),
            serializer: UTF8Serializer()
        ) { request, _ in
            var received: [String] = []
            for try await message in request.messages { received.append(message) }
            return StreamingServerResponse(
                single: ServerResponse(message: "echo:" + received.joined(separator: "|")))
        }

        // --- metadata, both directions ---
        //
        // The request's metadata is echoed back in *both* the initial and the trailing response
        // metadata, so one call observes all three crossings: request headers out, initial
        // response headers back, trailers back.
        router.registerHandler(
            forMethod: metadataEcho,
            deserializer: UTF8Deserializer(),
            serializer: UTF8Serializer()
        ) { request, _ in
            let seenStrings = request.metadata[stringValues: Keys.requestString].joined(
                separator: ",")
            // `Array(...)` first: `BinaryValues` is a bespoke sequence whose bare `.first` binds
            // to `first(where:)`, not to the `Collection` property.
            let seenBinary = Array(request.metadata[binaryValues: Keys.requestBinary]).first ?? []

            for try await _ in request.messages {}

            var initial = Metadata()
            initial.addString(seenStrings, forKey: Keys.seenString)
            initial.addBinary(seenBinary, forKey: Keys.seenBinary)

            var trailing = Metadata()
            trailing.addString(seenStrings, forKey: Keys.trailerString)

            return StreamingServerResponse(
                single: ServerResponse(
                    message: "metadata-observed",
                    metadata: initial,
                    trailingMetadata: trailing))
        }

        // --- a non-ok status ---
        router.registerHandler(
            forMethod: failing,
            deserializer: UTF8Deserializer(),
            serializer: UTF8Serializer()
        ) { request, _ in
            for try await _ in request.messages {}
            return StreamingServerResponse(of: String.self, error: refusal)
        }

        // --- client-streaming: N messages in, one out, and the reply needs `halfClose` ---
        router.registerHandler(
            forMethod: clientStream,
            deserializer: UTF8Deserializer(),
            serializer: UTF8Serializer()
        ) { request, _ in
            var received: [String] = []
            for try await message in request.messages { received.append(message) }
            return StreamingServerResponse(
                single: ServerResponse(
                    message: "\(received.count)/" + received.joined(separator: "|")))
        }

        // --- server-streaming: one message in, N out, in order ---
        router.registerHandler(
            forMethod: serverStream,
            deserializer: UTF8Deserializer(),
            serializer: UTF8Serializer()
        ) { request, _ in
            var received = ""
            for try await message in request.messages { received = message }
            // Copied into a `let` for the producer closure: capturing the `var` is a data race
            // the Swift 6 checker rejects.
            let seed = received
            return StreamingServerResponse(of: String.self) { writer in
                for index in 0..<streamLength {
                    try await writer.write("\(seed)#\(index)")
                }
                return [:]
            }
        }

        // --- bidi: genuinely interleaved. Reply to N before reading N+1. ---
        //
        // This is the only case where both directions of one stream are live at the same time,
        // which is why it is the most valuable of the four: it is the shape that a mux which
        // serialises the two directions, or a flow-control window that never refills, breaks.
        router.registerHandler(
            forMethod: bidi,
            deserializer: UTF8Deserializer(),
            serializer: UTF8Serializer()
        ) { request, _ in
            StreamingServerResponse(of: String.self) { writer in
                for try await message in request.messages {
                    try await writer.write("echo:" + message)
                }
                return [:]
            }
        }

        return router
    }

    /// Metadata keys. All lowercase and none `grpc-`-prefixed or a pseudo-header:
    /// `GRPCWireHeaders` strips reserved names on both emit and parse, so a reserved key would
    /// vanish and the test would be asserting nothing.
    private enum Keys {
        static let requestString = "x-spine-request"
        static let requestBinary = "x-spine-request-bin"
        static let seenString = "x-spine-seen"
        static let seenBinary = "x-spine-seen-bin"
        static let trailerString = "x-spine-trailer"
    }

    // =======================================================================================
    // MARK: - Unary
    // =======================================================================================

    /// **The single most load-bearing test in the package.** Nothing before this had made a gRPC
    /// call over the op transport at all: not the codec, not the mux, not the state machines, not
    /// the XPC substrate. If this fails, none of the rest is meaningful.
    func testUnaryCallRoundTripsThePayload() throws {
        let request = Self.payload(1)
        let reply = try runBounded("unary") {
            try await XPCPairHarness.withPair(router: Self.router()) { pair in
                try await pair.client.unary(
                    request: ClientRequest(message: request),
                    descriptor: Self.unary,
                    serializer: UTF8Serializer(),
                    deserializer: UTF8Deserializer(),
                    options: .defaults
                ) { response in try response.message }
            }
        }
        XCTAssertEqual(reply, "echo:" + request)
    }

    /// Metadata in **both** directions on one call: the client's request headers reach the handler,
    /// and the handler's initial *and* trailing metadata reach the client.
    ///
    /// The binary value is deliberately long enough (32 bytes) that its base64 round trip cannot be
    /// confused with an ASCII passthrough, and its key ends `-bin` because `Metadata.addBinary`
    /// **asserts** that and traps rather than throwing.
    func testMetadataTravelsInBothDirections() throws {
        let sentString = "request-metadata-value"
        let sentBinary = [UInt8](0..<32)

        // `let`, not `var`: the value is captured by the concurrently-executing bounded body, and
        // a captured `var` is a data race the Swift 6 checker rejects outright.
        let metadata: Metadata = {
            var metadata = Metadata()
            metadata.addString(sentString, forKey: Keys.requestString)
            metadata.addBinary(sentBinary, forKey: Keys.requestBinary)
            return metadata
        }()

        struct Observed: Sendable {
            var message: String
            var initialSeenString: [String]
            var initialSeenBinary: [[UInt8]]
            var trailingSeenString: [String]
        }

        let observed = try runBounded("metadata") {
            try await XPCPairHarness.withPair(router: Self.router()) { pair in
                try await pair.client.unary(
                    request: ClientRequest(message: Self.payload(2), metadata: metadata),
                    descriptor: Self.metadataEcho,
                    serializer: UTF8Serializer(),
                    deserializer: UTF8Deserializer(),
                    options: .defaults
                ) { response in
                    Observed(
                        message: try response.message,
                        initialSeenString: Array(response.metadata[stringValues: Keys.seenString]),
                        initialSeenBinary: Array(response.metadata[binaryValues: Keys.seenBinary]),
                        trailingSeenString: Array(
                            response.trailingMetadata[stringValues: Keys.trailerString]))
                }
            }
        }

        XCTAssertEqual(observed.message, "metadata-observed")
        // Outbound: the handler saw exactly what the client sent.
        XCTAssertEqual(observed.initialSeenString, [sentString])
        XCTAssertEqual(observed.initialSeenBinary, [sentBinary])
        // Inbound: initial and trailing metadata are separate crossings, so assert both.
        XCTAssertEqual(observed.trailingSeenString, [sentString])
    }

    /// A non-`ok` status reaches the caller as an `RPCError` with the handler's own code and
    /// message -- not as a transport error, and not as a success with an empty body.
    func testNonOKStatusReachesTheCaller() throws {
        let outcome = try runBounded("non-ok status") {
            try await XPCPairHarness.withPair(router: Self.router()) { pair in
                try await pair.client.unary(
                    request: ClientRequest(message: Self.payload(3)),
                    descriptor: Self.failing,
                    serializer: UTF8Serializer(),
                    deserializer: UTF8Deserializer(),
                    options: .defaults
                ) { response -> Result<String, RPCError> in
                    switch response.accepted {
                    case .success(let contents): return contents.message
                    case .failure(let error): return .failure(error)
                    }
                }
            }
        }

        switch outcome {
        case .success(let message):
            XCTFail("expected the handler's status, got a successful reply: \(message)")
        case .failure(let error):
            XCTAssertEqual(error.code, Self.refusal.code)
            XCTAssertEqual(error.message, Self.refusal.message)
        }
    }

    // =======================================================================================
    // MARK: - Client-streaming
    // =======================================================================================

    /// N request messages then `halfClose`, one reply.
    ///
    /// The reply carries the **count and the concatenation in order**, so this fails if a message
    /// is dropped, duplicated or reordered -- not only if the call as a whole breaks. It also can
    /// only complete if `halfClose` arrives: the handler's `for try await` does not end otherwise,
    /// and the test would time out rather than pass.
    func testClientStreamingDeliversEveryMessageInOrder() throws {
        let sent = (0..<Self.streamLength).map { Self.payload($0) }
        let reply = try runBounded("client-streaming") {
            try await XPCPairHarness.withPair(router: Self.router()) { pair in
                try await pair.client.clientStreaming(
                    request: StreamingClientRequest(of: String.self) { writer in
                        for message in sent { try await writer.write(message) }
                    },
                    descriptor: Self.clientStream,
                    serializer: UTF8Serializer(),
                    deserializer: UTF8Deserializer(),
                    options: .defaults
                ) { response in try response.message }
            }
        }
        XCTAssertEqual(reply, "\(sent.count)/" + sent.joined(separator: "|"))
    }

    // =======================================================================================
    // MARK: - Server-streaming
    // =======================================================================================

    /// One request, N replies, in order, then an ok status.
    ///
    /// Asserts the whole array rather than its count: a mux that reordered the response messages
    /// against each other, or that lost one and replaced it with a duplicate, keeps the count.
    func testServerStreamingDeliversEveryReplyInOrder() throws {
        let seed = Self.payload(7)
        let replies = try runBounded("server-streaming") {
            try await XPCPairHarness.withPair(router: Self.router()) { pair in
                try await pair.client.serverStreaming(
                    request: ClientRequest(message: seed),
                    descriptor: Self.serverStream,
                    serializer: UTF8Serializer(),
                    deserializer: UTF8Deserializer(),
                    options: .defaults
                ) { response in
                    var received: [String] = []
                    for try await message in response.messages { received.append(message) }
                    return received
                }
            }
        }
        XCTAssertEqual(replies, (0..<Self.streamLength).map { "\(seed)#\($0)" })
    }

    // =======================================================================================
    // MARK: - Bidirectional streaming
    // =======================================================================================

    /// Both directions of one stream live at the same time: the handler echoes message N before
    /// reading N+1, and the client's producer and response handler run concurrently.
    ///
    /// This is the case the old suite called its most valuable, and the one a mux that serialised
    /// the two directions would deadlock rather than fail.
    func testBidirectionalStreamingInterleavesBothDirections() throws {
        let sent = (0..<Self.streamLength).map { Self.payload(100 + $0) }
        let replies = try runBounded("bidi") {
            try await XPCPairHarness.withPair(router: Self.router()) { pair in
                try await pair.client.bidirectionalStreaming(
                    request: StreamingClientRequest(of: String.self) { writer in
                        for message in sent { try await writer.write(message) }
                    },
                    descriptor: Self.bidi,
                    serializer: UTF8Serializer(),
                    deserializer: UTF8Deserializer(),
                    options: .defaults
                ) { response in
                    var received: [String] = []
                    for try await message in response.messages { received.append(message) }
                    return received
                }
            }
        }
        XCTAssertEqual(replies, sent.map { "echo:" + $0 })
    }

    // =======================================================================================
    // MARK: - More than one stream on one connection
    // =======================================================================================

    /// Two RPCs of **different call types** in flight on the same connection at the same time, each
    /// asserting its own payload.
    ///
    /// Every case above makes exactly one call per pair, which leaves the mux's whole reason for
    /// existing unexercised: a router that ignored the stream id, or an id allocator that handed out
    /// the same id twice, would pass all of them. Here a crossover is visible -- the
    /// server-streaming call would receive the unary reply, or one of the two would hang.
    ///
    /// The two calls run in a task group so they overlap rather than merely follow one another; the
    /// bounded runner's timeout is the only thing standing between a routing deadlock and a hung
    /// suite.
    func testTwoConcurrentCallsOnOneConnectionDoNotCrossOver() throws {
        let unaryRequest = Self.payload(300)
        let streamSeed = Self.payload(301)

        struct Both: Sendable {
            var unary: String
            var streamed: [String]
        }

        let both = try runBounded("two concurrent calls") {
            try await XPCPairHarness.withPair(router: Self.router()) { pair in
                try await withThrowingTaskGroup(of: Both?.self, returning: Both.self) { group in
                    group.addTask {
                        let reply = try await pair.client.unary(
                            request: ClientRequest(message: unaryRequest),
                            descriptor: Self.unary,
                            serializer: UTF8Serializer(),
                            deserializer: UTF8Deserializer(),
                            options: .defaults
                        ) { response in try response.message }
                        return Both(unary: reply, streamed: [])
                    }
                    group.addTask {
                        let replies = try await pair.client.serverStreaming(
                            request: ClientRequest(message: streamSeed),
                            descriptor: Self.serverStream,
                            serializer: UTF8Serializer(),
                            deserializer: UTF8Deserializer(),
                            options: .defaults
                        ) { response in
                            var received: [String] = []
                            for try await message in response.messages { received.append(message) }
                            return received
                        }
                        return Both(unary: "", streamed: replies)
                    }

                    var merged = Both(unary: "", streamed: [])
                    for try await outcome in group {
                        guard let outcome else { continue }
                        if !outcome.unary.isEmpty { merged.unary = outcome.unary }
                        if !outcome.streamed.isEmpty { merged.streamed = outcome.streamed }
                    }
                    return merged
                }
            }
        }

        XCTAssertEqual(both.unary, "echo:" + unaryRequest)
        XCTAssertEqual(both.streamed, (0..<Self.streamLength).map { "\(streamSeed)#\($0)" })
    }

    // =======================================================================================
    // MARK: - The raw transport seam
    // =======================================================================================

    /// The harness's *other* entry point, which the lifecycle and flow-control slices will use:
    /// `XPCServerTransport.listen(streamHandler:)` and `XPCClientTransport.withStream` directly,
    /// with no gRPC runtime in between.
    ///
    /// It is here rather than deferred because a harness API that has never been run is exactly the
    /// kind of thing the next slice would have to debug before it could write its first test. It
    /// also pins the one bidi shape the `GRPCClient` API cannot express -- **write everything, then
    /// read** -- which with real flow control is a genuine deadlock risk rather than a formality.
    func testRawStreamSeamCarriesAWholeRPCWithoutTheGRPCRuntime() throws {
        let descriptor = Self.unary
        let sent = (0..<Self.streamLength).map { Self.payload(200 + $0) }

        let handler:
            @Sendable (
                RPCStream<XPCServerTransport.Inbound, XPCServerTransport.Outbound>, ServerContext
            ) async -> Void = { stream, _ in
                var bodies: [String] = []
                do {
                    for try await part in stream.inbound {
                        switch part {
                        case .metadata:
                            try await stream.outbound.write(.metadata([:]))
                        case .message(let bytes):
                            bodies.append(String(decoding: Array(bytes), as: UTF8.self))
                        }
                    }
                    for body in bodies {
                        let reply = GRPCSwiftData(Array(("echo:" + body).utf8))
                        try await stream.outbound.write(.message(reply))
                    }
                    try await stream.outbound.write(.status(Status(code: .ok, message: ""), [:]))
                } catch {
                    // Reported through the assertion on the client side: a handler that threw
                    // writes no status, and the client then sees the transport's own failure.
                    return
                }
                await stream.outbound.finish()
            }

        let received = try runBounded("raw seam") {
            try await XPCPairHarness.withTransports(streamHandler: handler) { pair in
                try await pair.client.withStream(descriptor: descriptor, options: .defaults) {
                    stream, _ in
                    try await stream.outbound.write(.metadata([:]))
                    for message in sent {
                        let body = GRPCSwiftData(Array(message.utf8))
                        try await stream.outbound.write(.message(body))
                    }
                    await stream.outbound.finish()

                    var messages: [String] = []
                    var status: Status?
                    for try await part in stream.inbound {
                        switch part {
                        case .metadata:
                            break
                        case .message(let bytes):
                            messages.append(String(decoding: Array(bytes), as: UTF8.self))
                        case .status(let received, _):
                            status = received
                        }
                    }
                    return (messages, status?.code)
                }
            }
        }

        XCTAssertEqual(received.0, sent.map { "echo:" + $0 })
        XCTAssertEqual(received.1, .ok)
    }
}
