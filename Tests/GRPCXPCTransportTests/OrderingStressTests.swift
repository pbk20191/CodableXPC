import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

// **The one measurement the whole design rests on.**
//
// §O2 gives the op model no sequence number, on the grounds that XPC guarantees ordering, and
// `MessagePipe`'s own contract makes that a requirement of any substrate rather than an observation
// about this one: "a conformer MUST deliver blobs to the `onReceive` handler in the same order they
// were handed to the peer's `send(_:)` -- there is no sequence number anywhere in the op model,
// because the core's per-stream state machines are serial and assume in-order delivery outright".
//
// Task 5 pinned that at the **pipe** level (3 x 10 001 blobs, exact order) and Task 8a's reviewer
// added 8 threads x 1 000 concurrent sends with 0 per-thread reorderings. What neither exercised is
// the layer where it actually matters: **the mux**, where ops belonging to many streams interleave
// on one blob channel and each stream's grammar machine assumes it sees its own ops in order.
//
// Two cases, because the interleaving has to be both *real* and *measured*:
//
// * ``testTenThousandMessagesArriveInExactOrderThroughTheMux()`` -- 10 000 messages over **two real
//   XPC sessions**, 10 streams writing concurrently, one blob per message. This is the load-bearing
//   one. The interleaving is real but emergent, so the case measures how much of it actually
//   happened and asserts that it happened at all.
// * ``testInterleavedBlobsPreserveEveryStreamsOrderThroughTheMux()`` -- the same 10 000 ops through
//   the mux over a ``TestPipe``, delivered in 1 000 blobs that each carry one op for **every** one
//   of the 10 streams. The interleaving is there by construction rather than by scheduling luck, so
//   this is the case that cannot silently stop interleaving.
//
// **If either fails, that is a STOP-and-report, not a bug to work around.** A single reordering
// invalidates a design decision that runs through every file in the target. Do not add sequence
// numbers, do not retry until green, and do not soften an assertion here.

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class OrderingStressTests: XCTestCase {

    private static let ordered = MethodDescriptor(
        fullyQualifiedService: "xpc.flowcontrol.Ordering", method: "Ordered")

    /// 10 streams x 1 000 messages = 10 000, and one `message` op per `write` means **one blob per
    /// message** (`OutboundOpWriter.write` → `sendEncoded([op])` → `pipe.send`).
    private static let streamCount = 10
    private static let messagesPerStream = 1_000
    private static var totalMessages: Int { streamCount * messagesPerStream }

    /// `"ord-<tag>-<seq>-pad12345"`: 20-21 bytes, so every message is past `Data`'s 14-byte inline
    /// threshold and crosses libxpc on the borrowing side of the boundary, like real traffic.
    ///
    /// The sequence number is **in the payload**, not inferred from arrival: that is what makes a
    /// reorder detectable at all. A test that trusted arrival order to define the sequence could not
    /// fail.
    private static func payload(tag: Int, seq: Int) -> GRPCSwiftData {
        GRPCSwiftData(Array("ord-\(tag)-\(String(format: "%04d", seq))-pad12345".utf8))
    }

    /// Recovers `(tag, seq)`, or `nil` if the body is not one of ours.
    private static func parse(_ body: GRPCSwiftData) -> (tag: Int, seq: Int)? {
        let text = String(decoding: Array(body), as: UTF8.self)
        let parts = text.split(separator: "-")
        guard parts.count == 4, parts[0] == "ord",
            let tag = Int(parts[1]), let seq = Int(parts[2])
        else { return nil }
        return (tag, seq)
    }

    /// Everything the two cases observe. One box, so a failure can report the whole picture.
    private struct Arrivals: Sendable {
        /// Per stream tag, the sequence numbers in the order they were consumed. **The assertion.**
        var perStream: [Int: [Int]] = [:]
        /// Every arrival's stream tag, in global consumption order. Used only to *measure* how much
        /// interleaving actually happened -- see each case's own note on what that can and cannot
        /// establish.
        var globalTags: [Int] = []
        /// Bodies that did not parse: a corruption, not a reorder, and worth separating.
        var unparseable = 0
        var liveHandlers = 0
        var maxLiveHandlers = 0

        mutating func record(tag: Int, seq: Int) {
            perStream[tag, default: []].append(seq)
            globalTags.append(tag)
        }

        /// How many times the consumed stream changed from one arrival to the next. This is the
        /// interleaving measurement.
        var streamSwitches: Int {
            guard globalTags.count > 1 else { return 0 }
            return zip(globalTags, globalTags.dropFirst()).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        }

        /// The reorder report: for each stream, the first index at which the sequence is not `i`.
        var reorderings: [String] {
            perStream.sorted { $0.key < $1.key }.compactMap { tag, seen in
                guard let bad = seen.indices.first(where: { seen[$0] != $0 }) else { return nil }
                let window = seen[max(0, bad - 3)..<min(seen.count, bad + 4)]
                return "stream \(tag): position \(bad) carries seq \(seen[bad]); around it "
                    + "\(Array(window))"
            }
        }
    }

    // =======================================================================================
    // MARK: - The load-bearing case: 10 000 messages over two real XPC sessions
    // =======================================================================================

    /// **10 000 messages, 10 concurrent streams, one blob each, through the mux over two real XPC
    /// sessions. Every stream's messages arrive in exact order.**
    ///
    /// # What the assertion is
    ///
    /// For every stream, the sequence numbers *carried in the payloads* must be `0, 1, 2, … 999` in
    /// the order the server's application half consumed them. Not "all 1 000 arrived" -- a set
    /// comparison would pass on any permutation, which is the entire failure mode under test. The
    /// per-stream list is compared element for element, and a mismatch is reported with the
    /// surrounding window so the shape of the reordering is visible rather than merely its
    /// existence.
    ///
    /// # What the interleaving measurement can and cannot establish
    ///
    /// Ten writer tasks share one blob channel, so the *wire* is genuinely interleaved -- but a test
    /// cannot observe wire order from up here, only consumption order, and consumption order is also
    /// a function of handler scheduling. So the two numbers this case reports are **evidence, not
    /// proof**: `maxLiveHandlers` (how many streams were open on the one connection at once) and
    /// `streamSwitches` (how often consumption crossed from one stream to another). Both are
    /// asserted, because a run where they collapsed to 1 and 9 would be ten streams executed
    /// end-to-end one after another -- a valid RPC test and a worthless ordering test, and it must
    /// fail loudly rather than pass quietly.
    ///
    /// ``testInterleavedBlobsPreserveEveryStreamsOrderThroughTheMux()`` is where the interleaving is
    /// by construction instead.
    ///
    /// # Flow control is in the loop, not bypassed
    ///
    /// 10 000 x ~20 bytes is ~200 000 bytes per direction against a 65 535-byte connection window,
    /// so credit really does have to flow for this to finish at all. A reorder introduced by the
    /// credit path -- a `credit` op overtaking a `message`, say -- is inside this case's reach.
    func testTenThousandMessagesArriveInExactOrderThroughTheMux() throws {
        let arrivals = Observed<Arrivals>(Arrivals())
        let expected = Array(0..<Self.messagesPerStream)

        let handler: RawSeamHandler = { stream, _ in
            arrivals.mutate {
                $0.liveHandlers += 1
                $0.maxLiveHandlers = max($0.maxLiveHandlers, $0.liveHandlers)
            }
            defer { arrivals.mutate { $0.liveHandlers -= 1 } }
            do {
                for try await part in stream.inbound {
                    guard case .message(let body) = part else { continue }
                    if let parsed = Self.parse(body) {
                        arrivals.mutate { $0.record(tag: parsed.tag, seq: parsed.seq) }
                    } else {
                        arrivals.mutate { $0.unparseable += 1 }
                    }
                }
                try await stream.outbound.write(.status(Status(code: .ok, message: ""), [:]))
            } catch {
                return
            }
            await stream.outbound.finish()
        }

        let statuses = try runBounded("10 000 messages in order", timeout: 300) { () -> [Int] in
            try await XPCPairHarness.withTransports(streamHandler: handler) { pair in
                try await withThrowingTaskGroup(of: Int.self, returning: [Int].self) { group in
                    for tag in 0..<Self.streamCount {
                        group.addTask {
                            try await pair.client.withStream(
                                descriptor: Self.ordered, options: .defaults
                            ) { stream, _ -> Int in
                                try await stream.outbound.write(.metadata([:]))
                                for seq in 0..<Self.messagesPerStream {
                                    try await stream.outbound.write(
                                        .message(Self.payload(tag: tag, seq: seq)))
                                }
                                await stream.outbound.finish()

                                var code = -1
                                for try await part in stream.inbound {
                                    if case .status(let status, _) = part {
                                        code = status.code.rawValue
                                    }
                                }
                                return code
                            }
                        }
                    }
                    var codes: [Int] = []
                    for try await code in group { codes.append(code) }
                    return codes.sorted()
                }
            }
        }

        let seen = arrivals.value

        // ---------------------------------------------------------------------------------
        // The ordering assertion. STOP and report if this fails.
        // ---------------------------------------------------------------------------------
        XCTAssertEqual(
            seen.reorderings, [],
            "A REORDERING WAS OBSERVED THROUGH THE MUX OVER TWO REAL XPC SESSIONS. §O2 has no "
                + "sequence number because XPC is assumed to guarantee ordering. Do not add one to "
                + "make this pass -- STOP and report.")
        XCTAssertEqual(
            seen.unparseable, 0, "a message body was corrupted, which is not the same as reordered")

        XCTAssertEqual(
            seen.perStream.count, Self.streamCount,
            "all \(Self.streamCount) streams must have delivered something")
        for tag in 0..<Self.streamCount {
            XCTAssertEqual(
                seen.perStream[tag] ?? [], expected,
                "stream \(tag) did not deliver 0...\(Self.messagesPerStream - 1) in exact order")
        }
        XCTAssertEqual(
            seen.globalTags.count, Self.totalMessages,
            "\(seen.globalTags.count) of \(Self.totalMessages) messages arrived")
        XCTAssertEqual(
            statuses, Array(repeating: Status.Code.ok.rawValue, count: Self.streamCount),
            "every stream must have completed with ok")

        // ---------------------------------------------------------------------------------
        // L9: the channel must actually have interleaved, or this measured nothing.
        // ---------------------------------------------------------------------------------
        XCTAssertGreaterThanOrEqual(
            seen.maxLiveHandlers, 2,
            "only \(seen.maxLiveHandlers) stream(s) were ever open on the connection at once, so "
                + "no two streams' ops ever shared the blob channel and this test measured "
                + "\(Self.streamCount) sequential RPCs")
        XCTAssertGreaterThanOrEqual(
            seen.streamSwitches, 100,
            "consumption crossed between streams only \(seen.streamSwitches) time(s) in "
                + "\(Self.totalMessages) arrivals, so the streams were effectively drained one "
                + "after another. Re-tune the concurrency; do not lower this bound.")
    }

    // =======================================================================================
    // MARK: - The measured-interleaving case: 1 000 blobs, 10 streams per blob
    // =======================================================================================

    /// **The same 10 000 ops through the mux, delivered in 1 000 blobs that each carry one op for
    /// every one of the 10 streams.**
    ///
    /// The real-XPC case above has emergent interleaving, which means a scheduler change could
    /// quietly turn it into ten sequential RPCs -- it asserts against that, but the assertion is a
    /// threshold rather than a construction. Here the interleaving is in the input: **every blob
    /// carries ops for all ten streams**, so `receive(_:)` routes ten different streams' ops inside
    /// a single routing turn, 1 000 times over. That is exactly the shape §O2 relies on ordering for
    /// and the shape a sequence number would exist to repair.
    ///
    /// # Lock-step, and why
    ///
    /// The test pulls exactly one part per stream after each blob rather than draining at the end.
    /// That is not cosmetic: with nothing consuming, 10 000 charged messages would take the
    /// connection's received-but-uncredited count far past 65 535 and the *receive-window
    /// enforcement* would fail the connection long before any ordering could be observed. Lock-step
    /// keeps flow control satisfied, keeps the interleaving deliberate, and makes the whole case
    /// deterministic -- there is no scheduling left for it to depend on.
    func testInterleavedBlobsPreserveEveryStreamsOrderThroughTheMux() throws {
        typealias PartIterator = RPCAsyncSequence<
            RPCRequestPart<GRPCSwiftData>, any Error
        >.AsyncIterator

        // Stream ids are odd and client-allocated (§O1): 1, 3, 5 … 19.
        let ids: [RPCStreamID] = (0..<Self.streamCount).map { RPCStreamID(1 + 2 * $0) }

        let outcome = try runBounded("interleaved blobs, exact order", timeout: 300) {
            () -> Arrivals in
            let core = CoreUnderTest(role: .server, label: "ordering-interleaved")
            defer { core.shutDown() }

            for id in ids {
                try core.pipe.deliver([
                    .openStream(id, method: "xpc.flowcontrol.Ordering/Ordered", timeout: nil)
                ])
            }
            try await core.waitForAccepts(Self.streamCount)

            var iterators: [PartIterator] = try ids.map { id in
                try XCTUnwrap(core.acceptedStream(id)).stream.inbound.makeAsyncIterator()
            }

            var arrivals = Arrivals()
            for seq in 0..<Self.messagesPerStream {
                // One blob, ten streams. This is the interleaving, by construction.
                let blob = ids.enumerated().map { index, id in
                    RPCOp.message(id, payload: Self.payload(tag: index, seq: seq))
                }
                try core.pipe.deliver(blob)

                for index in iterators.indices {
                    var iterator = iterators[index]
                    // Round 0 also carries `RequestOpDecoder`'s synthesised leading `.metadata`
                    // part (ruling 2), which arrives ahead of the first message.
                    if seq == 0 {
                        guard case .metadata = try await iterator.next() else {
                            XCTFail("stream \(ids[index]): expected the leading metadata part")
                            iterators[index] = iterator
                            continue
                        }
                    }
                    guard case .message(let body) = try await iterator.next() else {
                        XCTFail("stream \(ids[index]): expected a message part at seq \(seq)")
                        iterators[index] = iterator
                        continue
                    }
                    iterators[index] = iterator

                    if let parsed = Self.parse(body) {
                        arrivals.record(tag: parsed.tag, seq: parsed.seq)
                    } else {
                        arrivals.unparseable += 1
                    }
                }

                // The credit ops this consumption emits are the only outbound traffic; drop them so
                // the pipe's capture does not grow across 1 000 rounds.
                _ = core.pipe.takeSentOps()
            }

            XCTAssertFalse(
                core.pipe.isCancelled,
                "the connection must have survived 10 000 interleaved messages; it did not, which "
                    + "means flow control failed it rather than the ordering breaking")

            // **The construction assertion**, and it is not redundant: a mutation that sent the
            // same ops as ten single-op blobs per round instead of one ten-op blob left every other
            // assertion in this case green, because round-robin *consumption* is unchanged by it.
            // The only observable that can tell the two apart is how many blobs were delivered.
            XCTAssertEqual(
                core.pipe.deliveredBlobCount,
                Self.streamCount + Self.messagesPerStream,
                "\(Self.streamCount) openStream blobs plus \(Self.messagesPerStream) blobs that "
                    + "each carry one op for every stream. A different count means the ops were "
                    + "not packed together and `receive(_:)` never routed ten streams in one turn.")
            return arrivals
        }

        XCTAssertEqual(
            outcome.reorderings, [],
            "A REORDERING WAS OBSERVED THROUGH THE MUX with ten streams' ops interleaved in every "
                + "blob. §O2 has no sequence number. Do not add one -- STOP and report.")
        XCTAssertEqual(outcome.unparseable, 0)
        for tag in 0..<Self.streamCount {
            XCTAssertEqual(
                outcome.perStream[tag] ?? [], Array(0..<Self.messagesPerStream),
                "stream tag \(tag) did not deliver its sequence in exact order")
        }
        XCTAssertEqual(outcome.globalTags.count, Self.totalMessages)

        // By construction, consumption crosses streams on every single arrival except where a round
        // wraps. Asserting it anyway is what keeps the *construction* honest: if the blob builder
        // were ever changed to send one stream at a time, this is the assertion that notices.
        XCTAssertEqual(
            outcome.streamSwitches, Self.totalMessages - 1,
            "every adjacent pair of arrivals must belong to different streams; \(outcome.streamSwitches)"
                + " of \(Self.totalMessages - 1) did, so the blobs were not interleaved as intended")
    }
}
