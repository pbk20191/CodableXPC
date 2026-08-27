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
        /// Parts that arrived on a stream whose *earlier* parts carried a different tag -- i.e. a
        /// part routed to the wrong stream.
        ///
        /// `perStream` is keyed by the **payload's** tag, so on its own it proves "each writer's
        /// sequence was reassembled in order *somewhere*", not "on its own stream": a part routed to
        /// the wrong `RequestOpDecoder` would still land in the right bucket here and would only
        /// show up indirectly, as an apparent reordering. This is the direct observable. Each
        /// handler latches the tag of its first message and every later part on that stream must
        /// match it.
        var crossRouted: [String] = []
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
    /// cannot observe wire order from up here, only **consumption** order, and consumption order is
    /// taken downstream of ten buffered inbound sequences. With ~21-byte messages, roughly 3 100 can
    /// sit received-but-unconsumed inside the 65 535-byte connection window, so **a wire that
    /// delivered long contiguous per-stream runs would still yield ~9 900 consumption switches.**
    /// The number is therefore evidence that this test exercised a shared, concurrently-consumed
    /// channel -- not a measurement of wire interleaving, and it must not be quoted as one.
    ///
    /// What is asserted is exactly what that supports: `maxLiveHandlers == 10` (ten streams really
    /// were open on one connection at once) and a `streamSwitches` floor an order of magnitude under
    /// every observed run. Both exist to make the *worthless* shape fail loudly -- ten streams run
    /// end to end, one after another, which is a valid RPC test and no ordering test at all.
    ///
    /// ``testInterleavedBlobsPreserveEveryStreamsOrderThroughTheMux()`` is where the interleaving is
    /// present by construction instead, and where `deliveredBlobCount` can say so.
    ///
    /// # Flow control is in the loop, not bypassed -- and that is asserted, not asserted-in-a-comment
    ///
    /// The **connection** window is where it bites, not any one stream's: 10 x 1 000 x 19 bytes is
    /// ~190 000 bytes against 65 535, so the shared window turns over roughly three times and credit
    /// has to flow for this case to finish at all. (One stream's 19 000 bytes on its own would fit
    /// inside its per-stream window with room to spare -- which is why the premise below is written
    /// against the total, and why it is asserted rather than left in a comment: shrinking either
    /// dimension could otherwise take credit out of the loop silently.) A reorder introduced by the
    /// credit path -- a `credit` op overtaking a `message` -- is inside this case's reach.
    func testTenThousandMessagesArriveInExactOrderThroughTheMux() throws {
        let arrivals = Observed<Arrivals>(Arrivals())
        let expected = Array(0..<Self.messagesPerStream)

        // The premise, measured from the real payload rather than a remembered constant. It is
        // written against the **connection** window, which all ten streams share -- one stream's
        // 19 000 bytes would fit inside its own 65 535-byte window and prove nothing.
        let bodySize = Self.payload(tag: 0, seq: 0).count
        let totalCharge = Self.totalMessages * FlowControl.charge(for: bodySize)
        XCTAssertGreaterThan(
            totalCharge, 2 * FlowControl.initialWindow,
            "\(Self.totalMessages) x \(bodySize) bytes = \(totalCharge) must turn the shared "
                + "\(FlowControl.initialWindow)-byte connection window over at least twice, or "
                + "credit barely has to flow and this case stops exercising the credit path")

        let handler: RawSeamHandler = { stream, _ in
            arrivals.mutate {
                $0.liveHandlers += 1
                $0.maxLiveHandlers = max($0.maxLiveHandlers, $0.liveHandlers)
            }
            defer { arrivals.mutate { $0.liveHandlers -= 1 } }
            // Latched from this handler's *first* message. Every later part on this stream must
            // carry the same tag, or a part was routed to the wrong stream -- see
            // `Arrivals.crossRouted`.
            var handlerTag: Int?
            do {
                for try await part in stream.inbound {
                    guard case .message(let body) = part else { continue }
                    if let parsed = Self.parse(body) {
                        if let expected = handlerTag {
                            if parsed.tag != expected {
                                arrivals.mutate {
                                    $0.crossRouted.append(
                                        "a part tagged \(parsed.tag) (seq \(parsed.seq)) arrived on "
                                            + "the stream whose earlier parts were tagged \(expected)")
                                }
                            }
                        } else {
                            handlerTag = parsed.tag
                        }
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
            seen.crossRouted, [],
            "a part was routed to the wrong stream. `perStream` is keyed by the payload's tag, so "
                + "it would have reassembled that part into the right bucket and shown this only "
                + "indirectly; this is the direct observable.")

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
        // `maxLiveHandlers` is nearly free -- all ten handlers start together whatever the wire
        // does -- so it is asserted at its full value rather than at 2, and the real guard is the
        // switch count below.
        XCTAssertEqual(
            seen.maxLiveHandlers, Self.streamCount,
            "only \(seen.maxLiveHandlers) of \(Self.streamCount) stream(s) were open on the "
                + "connection at once, so this test measured sequential RPCs sharing nothing")
        // Measured minimum across six runs: 9 849 of a possible 9 999. A floor of 1 000 is an
        // order of magnitude under every observed run and still rules out the shape that would make
        // this case worthless -- ten streams drained one after another.
        XCTAssertGreaterThanOrEqual(
            seen.streamSwitches, 1_000,
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
    /// The real-XPC case above has emergent interleaving, and its switch count is a *consumption*
    /// measurement taken downstream of ten buffered sequences -- so it cannot say what the wire did.
    /// Here the interleaving is in the input: **every blob carries ops for all ten streams**, so
    /// `receive(_:)` routes ten different streams' ops inside a single routing turn, 1 000 times
    /// over. That is exactly the shape §O2 relies on ordering for and the shape a sequence number
    /// would exist to repair.
    ///
    /// **The observable that carries that claim is `TestPipe.deliveredBlobCount`, and nothing else
    /// can.** No assertion on the decoded parts distinguishes ten ops in one blob from the same ten
    /// ops in ten blobs -- a mutation proved it (M5), which is why that counter exists.
    ///
    /// Cross-routing is also a *direct* assertion here, unlike in the real-XPC case: the stream each
    /// part arrived on is known, so a part carrying another stream's tag is caught as itself rather
    /// than as apparent reordering.
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
                        // Here the stream a part arrived on is *known*, so cross-routing is a
                        // direct assertion rather than an inference from apparent reordering: this
                        // stream may only ever carry the tag it was seeded with.
                        if parsed.tag != index {
                            arrivals.crossRouted.append(
                                "stream \(ids[index]) (tag \(index)) received a part tagged "
                                    + "\(parsed.tag) at seq \(parsed.seq)")
                        }
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
        XCTAssertEqual(
            outcome.crossRouted, [],
            "a part was routed to a stream it does not belong to")
        for tag in 0..<Self.streamCount {
            XCTAssertEqual(
                outcome.perStream[tag] ?? [], Array(0..<Self.messagesPerStream),
                "stream tag \(tag) did not deliver its sequence in exact order")
        }
        XCTAssertEqual(outcome.globalTags.count, Self.totalMessages)

        // **This is a tautology of this case's own round-robin consumption loop, and it is kept as
        // one deliberately -- it is not the construction guard.** A blob builder changed to send one
        // stream at a time does not change consumption order at all (measured: under that mutation
        // only `deliveredBlobCount` fired), and a builder changed to send *fewer* streams per round
        // deadlocks the lock-step loop, which `runBounded` reports. What this assertion actually
        // guards is the consumption loop itself: if it were ever rewritten to drain one stream
        // before moving to the next, the case would silently stop consuming in round-robin and this
        // is what notices.
        //
        // The construction claim -- that ten streams' ops really shared one routing turn -- is
        // carried entirely by `deliveredBlobCount` below.
        XCTAssertEqual(
            outcome.streamSwitches, Self.totalMessages - 1,
            "the consumption loop must still be round-robin: \(outcome.streamSwitches) of "
                + "\(Self.totalMessages - 1) adjacent arrival pairs crossed streams")
    }
}
