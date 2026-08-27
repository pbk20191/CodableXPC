import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

// The two cases whose subject is the **send** side of §O4, over two real XPC sessions:
//
// 1. ``BackpressureTests/testAGatedReaderBoundsTheWritersInFlightBytes()`` -- a reader that consumes
//    nothing bounds the writer at the exact byte count the window allows, and the terminal op still
//    gets through with the window at zero.
// 2. ``BackpressureTests/testConformingPeerIsNeverFailed()`` -- the **false-positive guard** for the
//    receive-window enforcement.
//
// Both use the real substrate rather than a ``TestPipe``, and that is the point: the send side's
// parking, the peer's credit emission and the credit's journey back are all in the loop, and a
// `TestPipe` would let the test choose when credit arrives, which is the one thing it must not do.
//
// Task 8a §6 note 1 is the standing warning these two answer: nothing in the earlier slices ever
// parked on credit, because five 33-byte bodies are three orders of magnitude under a 65 535-byte
// window. These size their payloads past the window deliberately.

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class BackpressureTests: XCTestCase {

    private static let service = "xpc.flowcontrol.Backpressure"
    private static let push = MethodDescriptor(fullyQualifiedService: service, method: "Push")
    private static let echo = MethodDescriptor(fullyQualifiedService: service, method: "Echo")

    // =======================================================================================
    // MARK: - The exact in-flight bound
    // =======================================================================================

    /// **A gated reader bounds the writer's in-flight bytes, and the bound is asserted exactly.**
    ///
    /// Per L9, "the writer suspends" is proven by asserting the bound, not by observing a delay --
    /// a delay is equally consistent with a slow machine, and a test that only checked "it did not
    /// deadlock" would pass against no flow control at all.
    ///
    /// # The arithmetic, which is the whole test
    ///
    /// The window is 65 535 bytes per stream *and* per connection, and only `message` bodies consume
    /// it. With 5 000-byte bodies:
    ///
    /// | write | charge taken | window left |
    /// |---|---|---|
    /// | 1 … 13 | 5 000 each | 65 535 − 65 000 = **535** |
    /// | 14 | takes the last 535, then parks for the remaining 4 465 | 0 |
    ///
    /// So **exactly 13 writes complete and 65 000 bytes are in flight**, and the 14th is suspended
    /// holding a partial reservation. 5 000 is chosen because it divides the window with a *non-zero*
    /// remainder: with a size that divided evenly, "the last write parks" and "the last write
    /// completes" would be indistinguishable at the boundary.
    ///
    /// # Three claims, not one
    ///
    /// 1. **The bound is exact.** 13 writes, asserted after a settle window so that "the 14th has
    ///    not completed" is a real negative rather than a race.
    /// 2. **The terminal op is not flow-controlled.** With the window at zero, the writer task is
    ///    cancelled and `finish()` is called: the `halfClose` crosses anyway, which is what §O4
    ///    means by "a peer that stopped reading cannot make a stream unclosable". If control ops
    ///    were flow-controlled this hangs, and `runBounded` reports it.
    /// 3. **It was a suspension, not a failure.** After the gate opens, the handler receives all 13
    ///    messages, in order, byte-intact -- so nothing was dropped, truncated or rejected while the
    ///    window was empty.
    func testAGatedReaderBoundsTheWritersInFlightBytes() throws {
        let size = WindowSizes.backpressureMessage
        let expectedWrites = WindowSizes.backpressureWritesThatFit
        let expectedBytes = WindowSizes.backpressureBytesThatFit
        XCTAssertEqual(expectedWrites, 13, "13 x 5 000 = 65 000")
        XCTAssertEqual(expectedBytes, 65_000)
        XCTAssertLessThanOrEqual(expectedBytes, FlowControl.initialWindow)
        XCTAssertGreaterThan(
            expectedBytes + size, FlowControl.initialWindow,
            "the (n+1)th write must not fit, or the bound is not a bound")

        // The gate the reader is held behind, and what the reader saw once released.
        let release = OneShotGate()
        let receivedSizes = Observed<[Int]>([])
        let inboundEnded = Observed<Bool>(false)

        let handler: RawSeamHandler = { stream, _ in
            // **Consumes nothing until released.** `CreditingInbound` credits on consumption, so
            // while this is parked no credit op is ever emitted and the peer's window only shrinks.
            await release.wait()
            do {
                for try await part in stream.inbound {
                    if case .message(let body) = part { receivedSizes.append(body.count) }
                }
                inboundEnded.set()
                try await stream.outbound.write(.status(Status(code: .ok, message: ""), [:]))
            } catch {
                return
            }
            await stream.outbound.finish()
        }

        struct Measured: Sendable {
            var completedAtBound = 0
            var completedAfterSettle = 0
            var writerError = ""
        }

        let measured = try runBounded("the in-flight bound", timeout: 60) { () -> Measured in
            try await XPCPairHarness.withTransports(streamHandler: handler) { pair in
                let completed = Observed<Int>(0)
                let writerError = Observed<String>("")
                var measured = Measured()

                try await pair.client.withStream(descriptor: Self.push, options: .defaults) {
                    stream, _ in
                    // Control op: never flow-controlled, so this always goes straight out.
                    try await stream.outbound.write(.metadata([:]))

                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            // Deliberately asks for far more than the window allows. The loop is
                            // ended by cancellation, not by reaching its own limit.
                            var written = 0
                            do {
                                while written < expectedWrites * 4 {
                                    try await stream.outbound.write(
                                        .message(WindowSizes.payload(size, seed: UInt8(written % 251))))
                                    written += 1
                                    completed.mutate { $0 = written }
                                }
                            } catch {
                                writerError.mutate { $0 = "\(type(of: error))" }
                            }
                        }

                        // Claim 1: the bound, and then the negative assertion behind a settle
                        // window three orders of magnitude past a full pair's ~265 µs.
                        try? await waitUntil("\(expectedWrites) writes to complete") {
                            completed.value >= expectedWrites
                        }
                        measured.completedAtBound = completed.value
                        try? await Task.sleep(for: negativeAssertionSettleWindow)
                        measured.completedAfterSettle = completed.value

                        // Claim 2: the window is at zero and the writer is parked. Cancel it and
                        // close the direction anyway.
                        group.cancelAll()
                        await group.waitForAll()
                    }

                    measured.writerError = writerError.value
                    // `halfClose`, with the send window at zero.
                    await stream.outbound.finish()

                    // Claim 3: release the reader and let the whole thing complete.
                    release.open()
                    var status: Status?
                    for try await part in stream.inbound {
                        if case .status(let received, _) = part { status = received }
                    }
                    XCTAssertEqual(
                        status?.code, .ok,
                        "the stream must complete cleanly once the reader drains: a bounded writer "
                            + "is backpressure, not failure")
                    return ()
                }
                return measured
            }
        }

        XCTAssertEqual(
            measured.completedAtBound, expectedWrites,
            "exactly \(expectedWrites) writes of \(size) bytes fit in a \(FlowControl.initialWindow)"
                + "-byte window; \(measured.completedAtBound) completed")
        XCTAssertEqual(
            measured.completedAfterSettle, expectedWrites,
            "after \(negativeAssertionSettleWindow) with the reader still gated, "
                + "\(measured.completedAfterSettle) writes had completed -- the "
                + "\(expectedWrites + 1)th was not bounded by the window at all")
        XCTAssertEqual(
            measured.completedAfterSettle * size, expectedBytes,
            "the in-flight byte total must be exactly \(expectedBytes)")
        XCTAssertEqual(
            measured.writerError, "CancellationError",
            "the parked write must have been suspended (and so cancellable), not failed with a "
                + "transport error")

        XCTAssertEqual(
            receivedSizes.value, Array(repeating: size, count: expectedWrites),
            "every bounded write must have arrived intact, in order, once the reader drained")
        XCTAssertTrue(
            inboundEnded.isSet,
            "the `halfClose` must have crossed with the send window at zero -- §O4's control ops "
                + "are never flow-controlled, so a stalled window can never make a stream "
                + "unclosable")
    }

    // =======================================================================================
    // MARK: - Head-of-line blocking, not deadlock
    // =======================================================================================

    /// **An oversize message serialises the *connection*, not just its own stream.**
    ///
    /// §O4's charge rule clamps a message to `min(payload.count, 65 535)`, and that clamp is the
    /// whole **connection** window as well as the whole stream window. So a single oversize message
    /// takes everything, and every other stream's `message` op waits behind it until the receiving
    /// application consumes. Task 3 §5.2 corrected its own first draft on exactly this point,
    /// because "serialises one at a time per stream" reads as if other streams are unaffected, and
    /// someone will size a retry or a timeout against that reading.
    ///
    /// The test is the discriminating shape for that claim, and it is not "two oversize senders both
    /// finish":
    ///
    /// * stream A writes one **100 000-byte** message. Its charge is 65 535 -- the entire connection
    ///   window -- and the write completes.
    /// * stream B then writes a **100-byte** message. Its *own* stream window is untouched at
    ///   65 535, so if the clamp only serialised per stream this would go straight out. It must
    ///   park, because the connection window is at zero.
    /// * the reader is released, A's message is consumed, credit comes back, and **B completes**.
    ///   Head-of-line blocking, not deadlock.
    ///
    /// The negative assertion on B is what carries the claim; without it the case would pass against
    /// a transport with no connection window at all.
    func testAnOversizeMessageSerialisesTheWholeConnectionNotJustItsStream() throws {
        let oversize = 100_000
        let small = 100
        XCTAssertEqual(
            FlowControl.charge(for: oversize), FlowControl.initialWindow,
            "the premise: an oversize message is charged the whole window")

        let release = OneShotGate()
        let drained = Observed<[Int]>([])

        let handler: RawSeamHandler = { stream, _ in
            await release.wait()
            do {
                for try await part in stream.inbound {
                    if case .message(let body) = part { drained.append(body.count) }
                }
                try await stream.outbound.write(.status(Status(code: .ok, message: ""), [:]))
            } catch {
                return
            }
            await stream.outbound.finish()
        }

        struct Measured: Sendable {
            var smallCompletedWhileBlocked = false
            var smallCompletedAfterRelease = false
        }

        let measured = try runBounded("oversize head-of-line blocking", timeout: 60) {
            () -> Measured in
            try await XPCPairHarness.withTransports(streamHandler: handler) { pair in
                let bigSent = Observed<Bool>(false)
                let smallSent = Observed<Bool>(false)
                var measured = Measured()

                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Stream A: the oversize message. Takes the whole connection window.
                    group.addTask {
                        try await pair.client.withStream(
                            descriptor: Self.push, options: .defaults
                        ) { stream, _ in
                            try await stream.outbound.write(.metadata([:]))
                            try await stream.outbound.write(
                                .message(WindowSizes.payload(oversize, seed: 0x41)))
                            bigSent.set()
                            await stream.outbound.finish()
                            for try await _ in stream.inbound {}
                        }
                    }

                    try await waitUntil("the oversize message to be sent") { bigSent.isSet }

                    // Stream B: a 100-byte message on a stream whose own window is untouched.
                    group.addTask {
                        try await pair.client.withStream(
                            descriptor: Self.push, options: .defaults
                        ) { stream, _ in
                            try await stream.outbound.write(.metadata([:]))
                            try await stream.outbound.write(
                                .message(WindowSizes.payload(small, seed: 0x42)))
                            smallSent.set()
                            await stream.outbound.finish()
                            for try await _ in stream.inbound {}
                        }
                    }

                    // The negative assertion, behind the shared settle window.
                    try await Task.sleep(for: negativeAssertionSettleWindow)
                    measured.smallCompletedWhileBlocked = smallSent.isSet

                    release.open()
                    try await group.waitForAll()
                    measured.smallCompletedAfterRelease = smallSent.isSet
                }
                return measured
            }
        }

        XCTAssertFalse(
            measured.smallCompletedWhileBlocked,
            "a \(small)-byte message on a *different* stream completed while one oversize message "
                + "held the connection window. The clamp is supposed to be the whole connection "
                + "window, not just the sending stream's.")
        XCTAssertTrue(
            measured.smallCompletedAfterRelease,
            "the blocked write must complete once the oversize message is consumed -- head-of-line "
                + "blocking, not deadlock")
        XCTAssertEqual(
            drained.value.sorted(), [small, oversize],
            "both messages must have arrived intact: the oversize one is clamped in its *charge*, "
                + "never in its payload")
    }

    // =======================================================================================
    // MARK: - The false-positive guard
    // =======================================================================================

    /// **`testConformingPeerIsNeverFailed`: the receive-window enforcement must never fire against a
    /// peer that behaves.**
    ///
    /// The enforcement debits `Registry.connectionUnconsumed` by credit **actually emitted**, not by
    /// what the application consumed, so `> initialWindow` means literally "the peer's own window
    /// went negative". That is the safe direction *provided* the arithmetic really mirrors the
    /// peer's. If the emitted-vs-consumed choice is wrong in the other direction -- a
    /// consumption-based debit, or a counter that forgets a flush -- then a perfectly conforming
    /// peer is killed, and the failure is a `cancel` or a dead connection in the middle of honest
    /// traffic.
    ///
    /// # Why this shape
    ///
    /// * **Batched credit is exercised, not bypassed.** Five 8 191-byte bodies per RPC is 40 955
    ///   bytes against a 32 767-byte batching threshold, so every RPC crosses it and the run crosses
    ///   it hundreds of times, in both directions. A test with tiny payloads would emit almost no credit at all and could
    ///   not distinguish an emitted-based debit from a consumption-based one.
    /// * **Concurrency is what puts the *connection* counter near its bound.** Eight streams each
    ///   demanding 32 764 bytes is 262 112 bytes of demand against one 65 535-byte connection
    ///   window, so `charged − credited` really does sit at the top of its range, repeatedly, for
    ///   the whole run (eight streams x 40 955 bytes = 327 640 bytes of demand). One stream at a time would never approach it and the connection bound would
    ///   go untested.
    /// * **Every RPC's payload is asserted**, so "nothing was failed" cannot pass by everything
    ///   quietly returning nothing.
    ///
    /// A final RPC after the run proves the *connection* survived, not merely that each stream did.
    func testConformingPeerIsNeverFailed() throws {
        let bodySize = 8_191            // 8 x 8 191 = 65 528, one shy of the window: deliberate
        let messagesPerRPC = 5   // 5 x 8 191 = 40 955, past the 32 767-byte batching threshold
        let totalRPCs = 200
        let concurrency = 8

        XCTAssertGreaterThan(
            messagesPerRPC * bodySize * concurrency, FlowControl.initialWindow,
            "the concurrent demand must exceed the connection window, or the connection counter "
                + "never approaches its bound and this test proves nothing about it")
        XCTAssertGreaterThan(
            messagesPerRPC * bodySize, FlowControl.initialWindow / 2,
            "each RPC must cross the batching threshold, or credit is never emitted")

        let handler = RawSeamHandlers.echoing()

        struct Report: Sendable {
            var completed = 0
            var failures: [String] = []
            var finalRPCBodies = 0
        }

        let report = try runBounded("a conforming peer is never failed", timeout: 300) {
            () -> Report in
            try await XPCPairHarness.withTransports(streamHandler: handler) { pair in
                let outcome = Observed<Report>(Report())

                /// One RPC: `messagesPerRPC` bodies out, the same number of `"echo:"`-prefixed
                /// bodies back, then `ok`.
                @Sendable func oneRPC(_ index: Int) async {
                    do {
                        let bodies = try await pair.client.withStream(
                            descriptor: Self.echo, options: .defaults
                        ) { stream, _ -> [Int] in
                            try await stream.outbound.write(.metadata([:]))
                            for message in 0..<messagesPerRPC {
                                try await stream.outbound.write(
                                    .message(
                                        WindowSizes.payload(
                                            bodySize, seed: UInt8((index + message) % 251))))
                            }
                            await stream.outbound.finish()

                            var sizes: [Int] = []
                            var status: Status?
                            for try await part in stream.inbound {
                                switch part {
                                case .message(let body): sizes.append(body.count)
                                case .status(let received, _): status = received
                                case .metadata: break
                                }
                            }
                            guard status?.code == .ok else {
                                throw RPCError(
                                    code: .internalError,
                                    message: "RPC \(index) ended with "
                                        + "\(status.map { "\($0.code)" } ?? "no status at all")")
                            }
                            return sizes
                        }
                        // "echo:" is 5 bytes, so a correct echo is `bodySize + 5`.
                        guard bodies == Array(repeating: bodySize + 5, count: messagesPerRPC) else {
                            outcome.mutate {
                                $0.failures.append("RPC \(index) got bodies \(bodies)")
                            }
                            return
                        }
                        outcome.mutate { $0.completed += 1 }
                    } catch {
                        // **This is the assertion.** Any failure at all -- a `cancel` from the
                        // stream-level enforcement, an `.unavailable` from a failed connection --
                        // lands here.
                        outcome.mutate { $0.failures.append("RPC \(index) failed: \(error)") }
                    }
                }

                var launched = 0
                while launched < totalRPCs {
                    let batch = min(concurrency, totalRPCs - launched)
                    await withTaskGroup(of: Void.self) { group in
                        for offset in 0..<batch {
                            let index = launched + offset
                            group.addTask { await oneRPC(index) }
                        }
                    }
                    launched += batch
                }

                // The connection itself, after all of that.
                let final = try await pair.client.completeOneEchoRPC(
                    descriptor: Self.echo, payload: lifecyclePayload(7))
                outcome.mutate { $0.finalRPCBodies = final.count }
                return outcome.value
            }
        }

        XCTAssertEqual(
            report.failures, [],
            "a conforming peer was failed. This is the false-positive direction of §O4's "
                + "receive-window enforcement, and it means honest traffic is being killed.")
        XCTAssertEqual(
            report.completed, totalRPCs,
            "\(report.completed) of \(totalRPCs) RPCs completed with the right payloads")
        XCTAssertEqual(
            report.finalRPCBodies, 1,
            "the connection must still carry an RPC after \(totalRPCs) of them; if this is 0 the "
                + "connection was failed at some point even though the individual RPCs looked fine")
    }
}
