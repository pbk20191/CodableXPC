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
/// that cross libxpc are the ones `GRPCDispatchDataPayload` actually borrows rather than copies. That does
/// not *prove* the borrow (`GRPCDispatchDataPayloadTests` does that, by comparing base addresses) but it
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
            // Keeps only the **last** inbound message, so a duplicated single request is
            // invisible here. That is deliberate rather than an oversight -- this method's job is
            // the response direction -- and `testUnaryCallRoundTripsThePayload` is what would
            // catch a duplicated request.
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
        // The `for try await` + `write` inside one loop is load-bearing, not stylistic: it is the
        // server half of the ping-pong that
        // `testBidirectionalStreamingPingPongsBothDirections` forces. Rewriting this to drain
        // `request.messages` fully and *then* write the replies makes that test hang, which is
        // exactly the discrimination it exists for -- do not "simplify" it.
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
        static let rawSeamMarker = "x-spine-raw-seam"
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

    /// Both directions of one stream carrying traffic **at the same time**, asserted as a
    /// **ping-pong**: the client writes message N+1 only after its response handler has *read* the
    /// reply to N.
    ///
    /// # Why the obvious version of this test is worthless
    ///
    /// The first version of this case wrote all five requests through `StreamingClientRequest` and
    /// then read all five replies, against a handler that echoed inside its `for try await`. It
    /// passed -- and it **kept passing** when the handler was changed to drain every request before
    /// writing anything, i.e. when the interleaving it named was removed outright. A strictly
    /// half-duplex stack satisfies every assertion of that shape, so the name and the doc comment
    /// were claiming a property nothing tested. (Nor does the payload mutation M8 cover it: that
    /// only breaks the bytes.)
    ///
    /// The gate below is what makes the claim real. `ticks` carries one token per reply the
    /// response handler has read; the request producer awaits a token before every write after the
    /// first. So the wire order is forced to be
    /// `req0, rep0, req1, rep1, …` -- and a stack that drains one direction before starting the
    /// other **cannot complete it**: the producer waits for a reply that needs a request that the
    /// producer is not going to send. Measured: against the real handler this passes in ~3 ms;
    /// against the drain-all-then-write-all handler it times out at 5 s.
    ///
    /// `AsyncStream` rather than a semaphore or a continuation: the iterator lives entirely inside
    /// the producer closure (single consumer, no sharing), `finish()` releases a producer parked on
    /// a reply that is never coming, and there is no continuation to leak or double-resume.
    func testBidirectionalStreamingPingPongsBothDirections() throws {
        let sent = (0..<Self.streamLength).map { Self.payload(100 + $0) }
        let replies = try runBounded("bidi ping-pong") {
            let (ticks, tick) = AsyncStream.makeStream(of: Void.self)
            return try await XPCPairHarness.withPair(router: Self.router()) { pair in
                try await pair.client.bidirectionalStreaming(
                    request: StreamingClientRequest(of: String.self) { writer in
                        var replies = ticks.makeAsyncIterator()
                        for (index, message) in sent.enumerated() {
                            // Every message but the first waits for the previous reply to have
                            // been *read* by the response handler below. `nil` means the response
                            // side finished early, so there is nothing left to ping-pong with.
                            if index > 0, await replies.next() == nil { return }
                            try await writer.write(message)
                        }
                    },
                    descriptor: Self.bidi,
                    serializer: UTF8Serializer(),
                    deserializer: UTF8Deserializer(),
                    options: .defaults
                ) { response in
                    var received: [String] = []
                    for try await message in response.messages {
                        received.append(message)
                        tick.yield(())
                    }
                    // Releases a producer still parked, so a broken run fails on the assertion
                    // below rather than only on the bounded runner's timeout.
                    tick.finish()
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

                    // Discriminating the two tasks by `isEmpty` is correct only because both
                    // payloads are non-empty by construction. A future edit that legitimately
                    // expects an empty reply would silently lose that observation here rather
                    // than fail -- add a tag to `Both` if that day comes.
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
    /// read**.
    ///
    /// It pins the *shape*, not the risk: five bodies of ~33 bytes are three orders of magnitude
    /// under the 65 535-byte send window, so nothing here ever parks on credit. Making
    /// write-all-then-read actually deadlock needs payloads sized past the window, which is slice
    /// 3's job -- this case must not be cited as evidence that backpressure was exercised.
    func testRawStreamSeamCarriesAWholeRPCWithoutTheGRPCRuntime() throws {
        let descriptor = Self.unary
        let sent = (0..<Self.streamLength).map { Self.payload(200 + $0) }
        let rawSeamRequestMetadata = "raw-seam-request-metadata"

        let handler:
            @Sendable (
                RPCStream<XPCServerTransport.Inbound, XPCServerTransport.Outbound>, ServerContext
            ) async -> Void = { stream, _ in
                var bodies: [String] = []
                do {
                    for try await part in stream.inbound {
                        switch part {
                        case .metadata(let inbound):
                            // Echoes **what it saw**, not a constant, so the client's assertion
                            // below covers the request direction too. The first version wrote
                            // `.metadata([:])` here and the client did `case .metadata: break`,
                            // which left the whole metadata part unasserted at this layer.
                            let seen = inbound[stringValues: Keys.requestString]
                                .joined(separator: ",")
                            try await stream.outbound.write(
                                .metadata([Keys.rawSeamMarker: .string(seen)]))
                        case .message(let bytes):
                            bodies.append(String(decoding: Array(bytes), as: UTF8.self))
                        }
                    }
                    for body in bodies {
                        let reply = GRPCDispatchDataPayload(Array(("echo:" + body).utf8))
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
                    try await stream.outbound.write(
                        .metadata([Keys.requestString: .string(rawSeamRequestMetadata)]))
                    for message in sent {
                        let body = GRPCDispatchDataPayload(Array(message.utf8))
                        try await stream.outbound.write(.message(body))
                    }
                    await stream.outbound.finish()

                    var messages: [String] = []
                    var status: Status?
                    var marker: [String] = []
                    for try await part in stream.inbound {
                        switch part {
                        case .metadata(let metadata):
                            marker = Array(metadata[stringValues: Keys.rawSeamMarker])
                        case .message(let bytes):
                            messages.append(String(decoding: Array(bytes), as: UTF8.self))
                        case .status(let received, _):
                            status = received
                        }
                    }
                    return (messages, status?.code, marker)
                }
            }
        }

        XCTAssertEqual(received.0, sent.map { "echo:" + $0 })
        XCTAssertEqual(received.1, .ok)
        // Both directions of the metadata part at a layer with no gRPC runtime to do it for us:
        // the handler echoes the value it *read* out of the request, so this fails if the request
        // metadata's contents are lost as well as if the response metadata's are.
        //
        // Note what it cannot catch, because the transport makes it uncatchable by design: the
        // *presence* of the leading `.metadata` part. `RequestOpDecoder` **synthesises** an empty
        // one when the first op proves none is coming (`StreamStateMachines.swift`, ruling 2), so a
        // client that writes no metadata part still produces one on the server. That is why this
        // assertion had to carry a value -- with a constant marker, deleting the client's
        // `.metadata` write left the test green.
        XCTAssertEqual(received.2, [rawSeamRequestMetadata])
    }
}
