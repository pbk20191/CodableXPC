import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

// §O4's receive-window **enforcement** at the mux, its exact boundary, and the two blast radii it
// splits into. Every case here drives an `RPCTransportCore` over a ``TestPipe``, because the
// subject is a peer that **ignores credit** -- something a conforming `GRPCClient` cannot be made
// to do, and something the real-XPC harness therefore cannot express.
//
// The arithmetic these cases are written against, restated once so each assertion reads as a
// consequence rather than a re-derivation:
//
// * only `message` bodies are charged; every control op is charged 0;
// * a `message`'s charge is `FlowControl.charge(for: payload.count)` = `max(1, min(count, 65_535))`;
// * `Registry.connectionUnconsumed` is incremented by the charge **whatever the stream id**, and
//   decremented by credit *emitted*, so `> 65_535` means literally "the peer's own connection
//   window went negative";
// * `StreamEntry.unconsumedCharge` is incremented by the charge and decremented on *consumption*,
//   which makes it up to 32 766 bytes more **lenient** than the peer's real entitlement -- never
//   stricter;
// * both checks are `> initialWindow`, so **65 535 exactly is legal and 65 536 fires**;
// * the checks are narrowest-first: a stream over its own window fails *that stream*, and only an
//   overrun no single stream accounts for fails the connection.

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class ReceiveWindowTests: XCTestCase {

    private static let method = "xpc.flowcontrol.Window/Push"

    /// Opens `id` as an inbound stream on a server-role core.
    ///
    /// `static`, and called as `Self.open(...)`, because the bodies below run inside `runBounded`'s
    /// `@Sendable` closure and an `XCTestCase` is not `Sendable`.
    private static func open(
        _ core: CoreUnderTest, _ id: RPCStreamID, timeout: Duration? = nil
    ) throws {
        try core.pipe.deliver([.openStream(id, method: method, timeout: timeout)])
    }

    // =======================================================================================
    // MARK: - The boundary
    // =======================================================================================

    /// **65 535 exactly is legal; 65 536 fires.** Both checks in `deliver(_:toStream:)` are
    /// `> FlowControl.initialWindow`, and an off-by-one in either direction is a real defect: one
    /// way a conforming peer that fills its window exactly gets killed, the other way the bound is
    /// not a bound.
    ///
    /// Nothing consumes the stream's inbound sequence here -- that is the whole point. The accept
    /// loop pulls the `AcceptedRPCStream` (which releases its slot against
    /// `maxConcurrentInboundStreams`) and then never iterates it, so no credit is ever emitted and
    /// the received-but-uncredited count only goes up.
    ///
    /// Two messages rather than one 65 536-byte message, deliberately: a single oversize message is
    /// *clamped* to 65 535 by the charge rule and can never overrun on its own (that is
    /// `testTheCreditEmittedForAnOversizeMessageIsTheChargeNotTheLength`'s subject). The only way
    /// to push a stream past its window is to send it more than one.
    func testTheReceiveWindowBoundaryIsExactlyInitialWindow() throws {
        XCTAssertEqual(
            WindowSizes.initial, FlowControl.initialWindow,
            "this file's arithmetic is written against §O4's initial window")

        try runBounded("the receive-window boundary", timeout: 20) {
            let core = CoreUnderTest(role: .server, label: "boundary")
            defer { core.shutDown() }

            try Self.open(core, 1)
            try await core.waitForAccepts(1)
            XCTAssertEqual(core.pipe.takeSentOps().testDescriptions, [], "an accept answers nothing")

            // Exactly the window: legal.
            try core.pipe.deliver([.message(1, payload: WindowSizes.payload(FlowControl.initialWindow))])
            XCTAssertEqual(
                core.pipe.takeSentOps().testDescriptions, [],
                "\(FlowControl.initialWindow) byte(s) received and uncredited is exactly the "
                    + "window, and the check is `>`, so nothing may be failed here")
            XCTAssertEqual(
                core.core.liveStreamCount, 1, "the stream must still be live at the boundary")

            // One byte more: fires, and fails **that stream**.
            try core.pipe.deliver([.message(1, payload: WindowSizes.payload(1))])
            let ops = core.pipe.takeSentOps()
            XCTAssertEqual(
                ops.cancels(forStream: 1), ["stream receive-window overrun"],
                "one byte past the window must fail that stream with a `cancel`; got "
                    + "\(ops.testDescriptions)")
            XCTAssertEqual(
                core.core.liveStreamCount, 0, "an overrun stream must be removed from the table")
            XCTAssertFalse(
                core.pipe.isCancelled,
                "a stream-level overrun must NOT take the connection with it (§O2's blast radius)")
        }
    }

    /// The half of the arithmetic argument that reading the code could not settle: after a
    /// stream-level overrun, **a different stream on the same connection can still send**.
    ///
    /// It is not obvious from the code, because the overrun stream's whole outstanding charge is
    /// handed back to the *connection* accountant by `removeStream` -- so whether the connection
    /// recovers at all depends on that hand-back actually emitting. Here the residue is 65 536
    /// bytes, which is past the accountant's 32 767-byte batching threshold, so it is
    /// `flushConnection`'s `consumed(_:)` call that emits and the `flush()` beside it returns `nil`.
    ///
    /// **That distinction is measured, not assumed**: deleting the `flush()` leaves this case green
    /// (mutation P6). The `flush()` is load-bearing only for a *sub-threshold* residue, and
    /// ``testAStreamRemovedWithASubThresholdResidueStillReturnsIt()`` is the case that covers it.
    /// This one covers the recovery, which is the property the connection's survival depends on.
    func testAStreamLevelOverrunLeavesADifferentStreamAbleToKeepSending() throws {
        try runBounded("a stream overrun does not stop its neighbour", timeout: 20) {
            let core = CoreUnderTest(role: .server, label: "neighbour")
            defer { core.shutDown() }

            try Self.open(core, 1)
            try Self.open(core, 3)
            try await core.waitForAccepts(2)
            _ = core.pipe.takeSentOps()

            // Overrun stream 1.
            try core.pipe.deliver([.message(1, payload: WindowSizes.payload(FlowControl.initialWindow))])
            try core.pipe.deliver([.message(1, payload: WindowSizes.payload(1))])
            let overrunOps = core.pipe.takeSentOps()
            XCTAssertEqual(overrunOps.cancels(forStream: 1), ["stream receive-window overrun"])
            XCTAssertEqual(
                overrunOps.cancels(forStream: 3), [],
                "stream 3 did nothing wrong and must not be cancelled")
            // The hand-back is observable: the connection's whole 65 536-byte residue goes back as
            // credit, which is what makes the next assertion possible at all.
            XCTAssertEqual(
                overrunOps.credits.map(\.id), [0],
                "the removal must emit exactly one connection credit; got "
                    + "\(overrunOps.credits.map { "credit(\($0.id), \($0.bytes))" })")
            XCTAssertEqual(overrunOps.credits.first?.bytes, UInt32(FlowControl.initialWindow + 1))

            // Now stream 3 sends a message that would have been fatal had the connection not
            // recovered: 40 000 bytes on top of a stranded 65 536 would be 105 536.
            let survivor = try XCTUnwrap(core.acceptedStream(3))
            try core.pipe.deliver([.message(3, payload: WindowSizes.payload(40_000))])

            XCTAssertFalse(
                core.pipe.isCancelled,
                "the connection must have recovered from the stream-level overrun; it did not, so "
                    + "the removal's flush deferred the residue instead of emitting it")
            XCTAssertEqual(core.core.liveStreamCount, 1)

            // And the message really reached stream 3's application half, not merely "was not
            // rejected".
            var iterator = survivor.stream.inbound.makeAsyncIterator()
            let leading = try await iterator.next()
            guard case .metadata = leading else {
                return XCTFail("expected the leading metadata part, got \(String(describing: leading))")
            }
            let delivered = try await iterator.next()
            guard case .message(let body) = delivered else {
                return XCTFail("expected a message part, got \(String(describing: delivered))")
            }
            XCTAssertEqual(body.count, 40_000)
        }
    }

    /// **L3, one layer down: a stream removed with a residue *below* the batching threshold must
    /// still return it to the connection window.**
    ///
    /// `WindowAccountant.consumed(_:)` returns `nil` below half the initial window and carries the
    /// remainder for a later delivery. At a stream removal that promise expires -- there is no later
    /// delivery for that stream -- so `flushConnection(recording:)` calls `flush()`, which ignores
    /// the threshold. Without it, up to 32 766 bytes of the peer's connection window are stranded
    /// **per removed stream**, and the connection wedges after a handful of RPCs with the peer's
    /// writer parked on credit that is never coming.
    ///
    /// This case exists because mutation P6 -- deleting that `flush()` call -- survived
    /// ``testAStreamLevelOverrunLeavesADifferentStreamAbleToKeepSending()``, whose residue is
    /// 65 536 bytes and therefore emitted by `consumed(_:)` alone. **A sub-threshold residue is the
    /// only shape that reaches the flush**, so it is the only shape that can test it.
    ///
    /// 20 000 bytes received on stream 1 and never consumed, then stream 1 is cancelled. Two
    /// observables, and both are needed: the `credit` op itself, and stream 3 then surviving a
    /// 50 000-byte message that would take the connection to 70 000 if the residue were stranded.
    func testAStreamRemovedWithASubThresholdResidueStillReturnsIt() throws {
        let residue = 20_000
        XCTAssertLessThan(
            residue, FlowControl.initialWindow / 2,
            "the residue must be below the batching threshold, or `consumed(_:)` emits it and the "
                + "flush is never reached -- which is exactly how mutation P6 survived")

        try runBounded("a sub-threshold residue at removal", timeout: 20) {
            let core = CoreUnderTest(role: .server, label: "sub-threshold-flush")
            defer { core.shutDown() }

            try Self.open(core, 1)
            try Self.open(core, 3)
            try await core.waitForAccepts(2)
            _ = core.pipe.takeSentOps()

            try core.pipe.deliver([.message(1, payload: WindowSizes.payload(residue))])
            XCTAssertEqual(
                core.pipe.takeSentOps().credits.count, 0,
                "\(residue) bytes is below the 32 767-byte threshold, so nothing is credited yet")

            // The peer retires stream 1. Its 20 000 uncredited bytes have nowhere else to go.
            try core.pipe.deliver([.cancel(1, reason: "the peer is done with this stream")])
            let atRemoval = core.pipe.takeSentOps()
            XCTAssertEqual(
                atRemoval.credits.map { "credit(\($0.id), \($0.bytes))" },
                ["credit(0, \(residue))"],
                "a removal must flush its whole residue back to the connection window regardless "
                    + "of the batching threshold; got \(atRemoval.testDescriptions)")

            // And the connection really has that window back.
            try core.pipe.deliver([.message(3, payload: WindowSizes.payload(50_000))])
            XCTAssertFalse(
                core.pipe.isCancelled,
                "50 000 bytes on stream 3 must be legal; if the connection failed, stream 1's "
                    + "\(residue)-byte residue was stranded (\(residue) + 50 000 = "
                    + "\(residue + 50_000) > \(FlowControl.initialWindow))")
            XCTAssertEqual(core.core.liveStreamCount, 1)
        }
    }

    /// The connection-level radius: an overrun that **no single stream accounts for** fails the
    /// connection.
    ///
    /// Two streams at 40 000 bytes each. Neither is anywhere near its own 65 535, so the
    /// narrowest-first check falls through to the connection's, whose total is 80 000. That is
    /// reachable only when the peer's own connection window went negative, which a conforming peer
    /// cannot do -- and it is the one flow-control failure that is a genuine peer-triggered
    /// teardown.
    func testAConnectionLevelOverrunNoSingleStreamAccountsForFailsTheConnection() throws {
        try runBounded("a connection-level overrun", timeout: 20) {
            let core = CoreUnderTest(role: .server, label: "connection-overrun")
            defer { core.shutDown() }

            try Self.open(core, 1)
            try Self.open(core, 3)
            try await core.waitForAccepts(2)
            let victim = try XCTUnwrap(core.acceptedStream(1))
            _ = core.pipe.takeSentOps()

            try core.pipe.deliver([.message(1, payload: WindowSizes.payload(40_000))])
            XCTAssertEqual(
                core.pipe.takeSentOps().testDescriptions, [],
                "40 000 bytes on one stream is under both bounds")
            XCTAssertFalse(core.pipe.isCancelled)

            try core.pipe.deliver([.message(3, payload: WindowSizes.payload(40_000))])

            XCTAssertTrue(
                core.pipe.isCancelled,
                "80 000 uncredited byte(s) on the connection, with no single stream over its own "
                    + "window, must fail the connection")
            XCTAssertEqual(core.core.liveStreamCount, 0, "failAll sweeps the whole table")

            // Every live stream is failed with the connection's own error, not a per-stream one.
            var iterator = victim.stream.inbound.makeAsyncIterator()
            var thrown: (any Error)?
            do {
                while try await iterator.next() != nil {}
            } catch {
                thrown = error
            }
            let error = try XCTUnwrap(thrown as? RPCError, "stream 1's inbound must have been failed")
            XCTAssertEqual(error.code, .internalError)
            XCTAssertTrue(
                error.message.contains("connection's receive window"),
                "the failure must name the connection bound, not a stream's; got '\(error.message)'")
        }
    }

    // =======================================================================================
    // MARK: - The charge rule, as production code applies it
    // =======================================================================================

    /// **The drift test at the mux.** An oversize message is charged `min(payload.count, 65 535)`,
    /// and the *credit the core actually puts on the wire* is that same number -- not the payload's
    /// length.
    ///
    /// This is the half of the one-definition rule that `FlowControlWindowTests` cannot reach: there
    /// the test itself calls `FlowControl.charge`, so a receive side that had drifted would drift
    /// with it. Here production code computes the receive-side value and this assertion reads the
    /// bytes that came out. A receive side crediting `payload.count` would emit 100 000 and inflate
    /// the peer's window by 34 465 bytes it never spent; one crediting the raw count *clamped
    /// differently* would deflate it. Either is invisible until a stall.
    ///
    /// It also pins the consequence §O4 calls out and a reader is likely to misread: the clamp is
    /// the **whole connection window**, not just the stream's, so an oversize message serialises the
    /// connection. Head-of-line blocking, not deadlock -- and the credit for it comes back only when
    /// the application consumes.
    func testTheCreditEmittedForAnOversizeMessageIsTheChargeNotTheLength() throws {
        try runBounded("the oversize charge, as emitted", timeout: 20) {
            let core = CoreUnderTest(role: .server, label: "oversize")
            defer { core.shutDown() }

            try Self.open(core, 1)
            try await core.waitForAccepts(1)
            let accepted = try XCTUnwrap(core.acceptedStream(1))
            _ = core.pipe.takeSentOps()

            let oversize = 100_000
            let charge = FlowControl.charge(for: oversize)
            XCTAssertEqual(charge, FlowControl.initialWindow, "100 000 bytes clamps to the window")

            try core.pipe.deliver([.message(1, payload: WindowSizes.payload(oversize))])
            XCTAssertEqual(
                core.pipe.takeSentOps().testDescriptions, [],
                "the charge is clamped to exactly the window, so an oversize message is legal on "
                    + "arrival and nothing is failed")

            // Consume it. `CreditingInbound` credits *after* handing the element over, so the
            // credit ops are on the wire by the time `next()` returns.
            var iterator = accepted.stream.inbound.makeAsyncIterator()
            _ = try await iterator.next()                     // the leading metadata part
            let delivered = try await iterator.next()
            guard case .message(let body) = delivered else {
                return XCTFail("expected a message part, got \(String(describing: delivered))")
            }
            XCTAssertEqual(body.count, oversize, "the payload itself is not clamped, only its charge")

            let credits = core.pipe.takeSentOps().credits
            XCTAssertEqual(
                credits.map { "credit(\($0.id), \($0.bytes))" },
                ["credit(1, \(charge))", "credit(0, \(charge))"],
                "consumption must credit the **charge** to both the stream and the connection; "
                    + "\(oversize) would mean the receive side used the payload length")
        }
    }

    /// §O4's floor, measured through the enforcement bound rather than through the function.
    ///
    /// A `message` charge floors at 1, so a zero-length message costs window. Without the floor a
    /// ten-byte wire op buys unbounded receiver buffering **and survives the enforcement rule**,
    /// because a correct enforcement still charges a zero-length payload nothing --
    /// `google.protobuf.Empty` makes that shape common, not exotic.
    ///
    /// So the test is the bound itself: 65 535 empty messages is exactly the window, and the
    /// 65 536th fires. With `charge == 0` no number of them would ever fire.
    func testAZeroLengthMessageCostsWindow() throws {
        XCTAssertEqual(FlowControl.charge(for: 0), 1, "§O4's floor")

        try runBounded("zero-length messages cost window", timeout: 60) {
            let core = CoreUnderTest(role: .server, label: "empty-flood")
            defer { core.shutDown() }

            try Self.open(core, 1)
            try await core.waitForAccepts(1)
            _ = core.pipe.takeSentOps()

            let empty = GRPCDispatchDataPayload([])
            XCTAssertEqual(empty.count, 0)

            // Exactly the window's worth, in one blob, as a peer would pack them.
            try core.pipe.deliver(
                (0..<FlowControl.initialWindow).map { _ in RPCOp.message(1, payload: empty) })
            XCTAssertEqual(
                core.pipe.takeSentOps().testDescriptions, [],
                "\(FlowControl.initialWindow) empty messages is exactly the window")
            XCTAssertEqual(core.core.liveStreamCount, 1)

            try core.pipe.deliver([.message(1, payload: empty)])
            XCTAssertEqual(
                core.pipe.takeSentOps().cancels(forStream: 1), ["stream receive-window overrun"],
                "the \(FlowControl.initialWindow + 1)th empty message must overrun the stream; if "
                    + "it does not, the charge floor is gone and an empty-payload flood is free")
        }
    }

    // =======================================================================================
    // MARK: - The send side, with the window at zero
    // =======================================================================================

    /// One accepted server stream whose **stream and connection send windows are both exhausted**,
    /// with a second write parked on them.
    ///
    /// Deterministic, and that is the point of doing it over a ``TestPipe`` rather than real XPC: no
    /// `credit` op can arrive unless this test sends one, so "the window is at zero" is a fact for as
    /// long as the test wants it, rather than a race against the peer's consumption.
    ///
    /// - Returns: the core, the stream, and a box that stays `nil` for as long as the second write is
    ///   still parked. The caller owns `core.shutDown()`, which is also what releases the parked
    ///   write (`failAll` fails both windows).
    private static func withExhaustedSendWindows(
        label: String
    ) async throws -> (
        core: CoreUnderTest, stream: ServerRPCStream,
        parkedOutcome: Observed<String?>
    ) {
        let core = CoreUnderTest(role: .server, label: label)
        try Self.open(core, 1)
        try await core.waitForAccepts(1)
        let accepted = try XCTUnwrap(core.acceptedStream(1))

        // A control op: no flow control, so it always goes straight out.
        try await accepted.stream.outbound.write(.metadata([:]))

        // Exactly one window's worth, which empties the stream's window *and* the connection's --
        // §O4 reserves the stream then the connection, both for the same charge.
        try await accepted.stream.outbound.write(
            .message(WindowSizes.payload(FlowControl.initialWindow)))

        // A second message now has nothing to reserve from and must park.
        let parkedOutcome = Observed<String?>(nil)
        let stream = accepted.stream
        Task.detached {
            do {
                try await stream.outbound.write(.message(WindowSizes.payload(100)))
                parkedOutcome.mutate { $0 = "completed" }
            } catch {
                parkedOutcome.mutate { $0 = "\((error as? RPCError)?.code.description ?? "\(type(of: error))")|\((error as? RPCError)?.message ?? "")" }
            }
        }
        try await Task.sleep(for: negativeAssertionSettleWindow)
        XCTAssertNil(
            parkedOutcome.value,
            "\(label): the second write must still be parked -- if it completed, the windows were "
                + "not actually exhausted and everything this helper sets up is void")
        return (core, accepted.stream, parkedOutcome)
    }

    /// **§O4's terminal-op clause, on the op that matters most: `status`.**
    ///
    /// "Control ops are never flow-controlled, so a stalled window can never starve a stream's
    /// terminal op" is load-bearing, not incidental: if `status` had to wait for credit, a peer that
    /// stopped reading could make a stream **unclosable**. Only `halfClose` and `metadata` were
    /// proven before this -- `BackpressureTests.testAGatedReaderBoundsTheWritersInFlightBytes` covers
    /// the client's terminator; the server's is `status`, and it is the one a stuck handler is
    /// blocked on.
    ///
    /// Both terminal ops are covered here, because §O5.3 makes `cancel` the abort op in both
    /// directions and it goes out through a different path (`cancelStream`, not the writer):
    ///
    /// 1. with both send windows at zero and a message write parked on them, `status` reaches the
    ///    wire;
    /// 2. and on a second, independently exhausted stream, `finish(throwing:)` puts a `cancel` on the
    ///    wire from the same state.
    func testATerminalStatusAndCancelGetThroughWithTheSendWindowAtZero() throws {
        try runBounded("terminal ops with the window at zero", timeout: 60) {
            // ---- 1. `status` ----
            let statusCase = try await Self.withExhaustedSendWindows(label: "terminal-status")
            defer { statusCase.core.shutDown() }
            _ = statusCase.core.pipe.takeSentOps()

            try await statusCase.stream.outbound.write(
                .status(Status(code: .ok, message: ""), [:]))

            let afterStatus = statusCase.core.pipe.takeSentOps()
            XCTAssertEqual(
                afterStatus.statuses(forStream: 1).map { "\($0.code)|\($0.message)" },
                ["\(Status.Code.ok.rawValue)|"],
                "the `status` op must reach the wire with both send windows at zero; got "
                    + "\(afterStatus.testDescriptions)")
            XCTAssertNil(
                statusCase.parkedOutcome.value,
                "and the parked *message* write must still be parked -- otherwise the window was "
                    + "not at zero when the status went out and this proves nothing")

            // ---- 2. `cancel` ----
            let cancelCase = try await Self.withExhaustedSendWindows(label: "terminal-cancel")
            defer { cancelCase.core.shutDown() }
            _ = cancelCase.core.pipe.takeSentOps()

            await cancelCase.stream.outbound.finish(
                throwing: RPCError(code: .aborted, message: "the handler gave up"))

            let afterCancel = cancelCase.core.pipe.takeSentOps()
            XCTAssertEqual(
                afterCancel.cancels(forStream: 1).count, 1,
                "the `cancel` op must reach the wire with both send windows at zero; got "
                    + "\(afterCancel.testDescriptions)")
            XCTAssertEqual(
                cancelCase.core.core.liveStreamCount, 0,
                "and the stream is removed, which is what wakes its parked writer")
        }
    }

    /// Contract line 9 at the mux: **peer death sweeps the table, fails every stream's inbound, and
    /// wakes a writer parked on the send windows.**
    ///
    /// Slice 2 proved the waking half over real XPC (`TeardownTests.testPeerDeathWakesWritersParked
    /// OnBothWindows`). What it could not see is the table: `liveStreamCount` and the accept
    /// sequence's termination are only reachable from a core the test built, and the server's
    /// per-connection core is private two layers down. This case is that half, and it is also the
    /// only reader of ``TestPipe/killPeer()`` -- without it the pipe's whole `onPeerDeath` path is
    /// dead support code that looks like coverage.
    func testPeerDeathSweepsTheTableAndWakesAParkedWriter() throws {
        try runBounded("peer death at the mux", timeout: 60) {
            let subject = try await Self.withExhaustedSendWindows(label: "mux-peer-death")
            defer { subject.core.shutDown() }
            XCTAssertEqual(subject.core.core.liveStreamCount, 1)

            subject.core.pipe.killPeer()

            // The parked writer is woken, with the peer-death error rather than a generic one.
            try await waitUntil("the parked writer to be woken") {
                subject.parkedOutcome.value != nil
            }
            let outcome = try XCTUnwrap(subject.parkedOutcome.value)
            XCTAssertTrue(
                outcome.hasPrefix("unavailable|"),
                "a writer parked on credit that can no longer arrive must be failed, not left "
                    + "suspended forever; got '\(outcome)'")
            XCTAssertTrue(
                outcome.contains("the peer process is no longer available"),
                "and it must be failed with the peer-death reason, so a coincidental "
                    + "`.unavailable` from something else cannot pass this; got '\(outcome)'")

            // The table is swept -- the half slice 2's real-XPC case cannot observe.
            XCTAssertEqual(
                subject.core.core.liveStreamCount, 0,
                "`failAll` must remove every entry: a core that kept them would leak one per "
                    + "disconnected peer")

            // And the stream's inbound is failed with the same error rather than ended cleanly.
            var thrown: (any Error)?
            do {
                for try await _ in subject.stream.inbound {}
            } catch {
                thrown = error
            }
            let error = try XCTUnwrap(thrown as? RPCError, "the inbound must have been failed")
            XCTAssertEqual(error.code, .unavailable)
            XCTAssertTrue(error.message.contains("the peer process is no longer available"))
        }
    }

    // =======================================================================================
    // MARK: - Hostile control ops
    // =======================================================================================

    /// Three peer-controlled control-op shapes that must all be inert.
    ///
    /// * **`credit(id, bytes: 0)`** -- legal arithmetic, zero effect. It must not throw, must not
    ///   wake anything and must not be answered. (The legacy stack sent exactly this shape as an
    ///   inert nudge blob, which is why it is worth pinning that the current core simply absorbs it.)
    /// * **a `credit` for an unknown stream** -- the ordinary race where the peer credited a stream
    ///   this side just retired. There is no window left to grow, and answering would hand the peer
    ///   an amplification lever.
    /// * **a `cancel` for an unknown id** -- likewise silent. `removeStream` finds nothing, returns
    ///   `false`, and builds no op.
    /// * **a `cancel` for a *live* id** -- also silent, for a different reason: contract line 6 says
    ///   the stream is failed and removed and **no `cancel` is echoed**, because echoing a `cancel`
    ///   at the peer that just sent one is pointless and lets two peers volley. This arm was added
    ///   after mutation P19 (make `route(.cancel)` pass its reason to `sendingCancel:`) survived the
    ///   unknown-id arm alone -- an unknown id sends nothing whatever the code does, so it cannot
    ///   test the no-echo rule at all.
    ///
    /// All three in one core, because the assertion that matters for all three is the same one --
    /// **nothing went out and the connection is untouched** -- and running them in sequence also
    /// proves none of them left residue that the next one could trip over.
    func testAZeroByteCreditAnUnknownCreditAndAnUnknownCancelAreAllInert() throws {
        try runBounded("inert control ops", timeout: 20) {
            let core = CoreUnderTest(role: .server, label: "inert-control")
            defer { core.shutDown() }

            try Self.open(core, 1)
            try await core.waitForAccepts(1)
            _ = core.pipe.takeSentOps()

            try core.pipe.deliver([.credit(1, bytes: 0)])
            try core.pipe.deliver([.credit(0, bytes: 0)])
            try core.pipe.deliver([.credit(9_999, bytes: 4_096)])
            try core.pipe.deliver([.cancel(9_999, reason: "a stream that never existed")])

            XCTAssertEqual(
                core.pipe.takeSentOps().testDescriptions, [],
                "none of a zero-byte credit, a credit for an unknown stream, or a cancel for an "
                    + "unknown id may be answered")
            XCTAssertFalse(core.pipe.isCancelled, "and none of them may fail the connection")
            XCTAssertEqual(
                core.core.liveStreamCount, 1,
                "stream 1 is a bystander and must be untouched")

            // The live stream still works afterwards, which is what rules out "inert" meaning
            // "wedged".
            try core.pipe.deliver([.message(1, payload: WindowSizes.payload(100))])
            let accepted = try XCTUnwrap(core.acceptedStream(1))
            var iterator = accepted.stream.inbound.makeAsyncIterator()
            _ = try await iterator.next()
            let delivered = try await iterator.next()
            guard case .message(let body) = delivered else {
                return XCTFail("expected a message part, got \(String(describing: delivered))")
            }
            XCTAssertEqual(body.count, 100)
            _ = core.pipe.takeSentOps()

            // Contract line 6: a `cancel` for a **live** stream removes it and echoes nothing.
            try core.pipe.deliver([.cancel(1, reason: "the peer is aborting this one")])
            let afterLiveCancel = core.pipe.takeSentOps()
            XCTAssertEqual(
                afterLiveCancel.cancels(forStream: 1), [],
                "a `cancel` must never be echoed back at the peer that sent it -- two peers would "
                    + "volley; got \(afterLiveCancel.testDescriptions)")
            XCTAssertEqual(core.core.liveStreamCount, 0, "and the stream must be removed")
        }
    }

    /// An op for an **unknown** stream still returns its charge to the connection window.
    ///
    /// Dropping the op is correct (see the file overview on anti-amplification), but dropping its
    /// *charge* would let a peer shrink the advertised connection window to nothing by writing to
    /// ids this side retired -- a slow, silent wedge with no error anywhere. `deliver`'s
    /// `.unknownStream` arm routes the charge through `creditConnection(_:)` for exactly that
    /// reason.
    ///
    /// Two 40 000-byte messages to an id that was never opened: if the charge were dropped, the
    /// second would take `connectionUnconsumed` to 80 000 and fail the connection.
    func testAnOpForAnUnknownStreamStillReturnsItsChargeToTheConnectionWindow() throws {
        try runBounded("an unknown stream's charge comes back", timeout: 20) {
            let core = CoreUnderTest(role: .server, label: "unknown-charge")
            defer { core.shutDown() }

            try core.pipe.deliver([.message(4_242, payload: WindowSizes.payload(40_000))])
            let first = core.pipe.takeSentOps()
            XCTAssertEqual(
                first.credits.map { "credit(\($0.id), \($0.bytes))" }, ["credit(0, 40000)"],
                "a dropped op's charge must go straight back to the connection window")
            XCTAssertEqual(
                first.cancels(forStream: 4_242), [],
                "and the op itself must be dropped, not answered")

            try core.pipe.deliver([.message(4_242, payload: WindowSizes.payload(40_000))])
            XCTAssertFalse(
                core.pipe.isCancelled,
                "the second 40 000 bytes must not fail the connection; if it did, the first "
                    + "message's charge was never returned")
        }
    }

    /// Contract line 3: an **overflowing** credit is a §O4 protocol error and fails the connection.
    ///
    /// Its own core, because it is a teardown. `grant` validates in `Int64` and leaves the window
    /// untouched, so the connection dies for the right reason rather than with a wrapped counter.
    func testAnOverflowingCreditFailsTheConnection() throws {
        try runBounded("an overflowing credit", timeout: 20) {
            let core = CoreUnderTest(role: .server, label: "credit-overflow")
            defer { core.shutDown() }

            try Self.open(core, 1)
            try await core.waitForAccepts(1)
            let victim = try XCTUnwrap(core.acceptedStream(1))
            _ = core.pipe.takeSentOps()

            try core.pipe.deliver([.credit(0, bytes: UInt32.max)])

            XCTAssertTrue(
                core.pipe.isCancelled,
                "a credit that would take the connection window above 2^31-1 must fail the "
                    + "connection")
            XCTAssertEqual(core.core.liveStreamCount, 0)

            var iterator = victim.stream.inbound.makeAsyncIterator()
            var thrown: (any Error)?
            do {
                while try await iterator.next() != nil {}
            } catch {
                thrown = error
            }
            let error = try XCTUnwrap(thrown as? RPCError)
            XCTAssertTrue(
                error.message.contains("overflow"),
                "the failure must name the overflowing credit; got '\(error.message)'")
        }
    }
}
