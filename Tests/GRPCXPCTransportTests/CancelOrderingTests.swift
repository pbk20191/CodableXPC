import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

/// Three properties of `cancel`, all of them about a **removal that happens under a live writer**.
///
/// 1. **Nothing may follow the `cancel` for a stream the peer has never heard of.** `openStream`
///    is deferred to the writer's first write, so between `RPCTransportCore.openStream(...)` --
///    which registers the entry and arms the deadline -- and that first write, the stream exists
///    locally and nowhere else. A removal inside that gap (a fired deadline is the reachable one)
///    sends `cancel(id)` for an id the peer will drop, and the write that follows would then open
///    the stream *behind* it.
/// 2. **That holds when the removal lands *during* the write, not only before it.** The two tests
///    for this are the ones that matter, because the sequential case above was already closed by a
///    check taken immediately before the send while the concurrent case was not. There are exactly
///    two places a removal can land inside a write, and there is one test for each:
///    ``testARemovalDuringTheEncodeCannotBeOvertakenByTheOpenStream()`` puts it between the encode
///    and the decision, ``testARemovalDuringTheSubmissionCannotOvertakeTheOpenStream()`` puts it
///    after the decision and inside `pipe.send`. **Neither samples a race**: each stops the write
///    at the instant in question and holds it there (`TestPipe.onEachSend`, and a `WireCodec` whose
///    `encode` runs a hook) rather than retrying until it happens to interleave.
/// 3. **The peer's `cancel` reason is peer-chosen input**, and the local `RPCError` built from it
///    is bounded like every other sink for peer text in `RPCTransportCore`.
///
/// All are driven through `TestPipe` rather than a real XPC pair: the subject is which ops reached
/// the wire and in what order, which is exactly what `TestPipe.takeSentOps()` reports and what an
/// end-to-end pair hides.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class CancelOrderingTests: XCTestCase {

    private static let method = MethodDescriptor(
        fullyQualifiedService: "xpc.grpc.Order", method: "Push")

    // ---------------------------------------------------------------------------------------
    // MARK: - The deferred openStream must not overtake the cancel
    // ---------------------------------------------------------------------------------------

    /// A deadline fires before the client writes anything; the first write must then be **refused**
    /// rather than emit `[openStream, metadata]` after the `cancel` that has already gone out.
    ///
    /// A 1 ms deadline is the reachable shape of the gap, not a contrivance: the writer's first
    /// write happens whenever the application gets round to it, and the deadline timer runs on the
    /// pipe's queue regardless. The wait is on the `cancel` actually reaching the wire, so the
    /// assertions afterwards are about a completed removal rather than a race.
    ///
    /// Both halves of the writer are exercised, because both emit the deferred `openStream`:
    /// `write(_:)` prepends it to the first part, and `finish()` prepends it to `halfClose` for a
    /// request that never wrote a part at all.
    ///
    /// What makes this discriminating: `metadata` carries **no flow-control charge**, so it
    /// consults nothing else on the way out. Before the fix the write succeeded outright -- there
    /// was no table lookup on that path and `isDead` was never set -- and the peer would admit a
    /// stream whose client had already abandoned it, holding a `maxConcurrentInboundStreams` slot
    /// until the connection was torn down.
    func testAWriteAfterTheDeadlineFiredCannotOpenTheStreamBehindTheCancel() throws {
        try runBounded("a write after the deadline fired", timeout: 20) {
            let core = CoreUnderTest(role: .client, label: "deferred-open-after-cancel")
            defer { core.shutDown() }

            let opened = try core.core.openStream(
                descriptor: Self.method, timeout: .milliseconds(1))
            XCTAssertEqual(opened.id, 1, "a client core allocates odd ids from 1")

            try await waitUntil("the deadline's cancel reached the wire") {
                !core.pipe.sentBlobs.isEmpty
            }
            XCTAssertEqual(
                core.pipe.takeSentOps().testDescriptions,
                ["cancel(1, reason: deadline exceeded)"],
                "the deadline's removal sends exactly one op, and it is the cancel")

            var thrown: (any Error)?
            do {
                try await opened.stream.outbound.write(.metadata(Metadata()))
            } catch {
                thrown = error
            }
            XCTAssertEqual(
                (thrown as? RPCError)?.code, .unavailable,
                "a write to a stream that is no longer in the registry must be refused, not sent: "
                    + "it carries the deferred openStream")

            // The other half: `finish()` on a request that never wrote a part emits
            // `[openStream, halfClose]`. Silent by protocol, so the assertion is on the wire.
            await opened.stream.outbound.finish()

            XCTAssertEqual(
                core.pipe.takeSentOps().testDescriptions, [],
                "no op may follow the cancel for a stream the peer has never been told about")
        }
    }

    /// The same refusal, with the removal driven by the peer rather than by a deadline, and with
    /// the stream already open on the wire.
    ///
    /// This is the wider class the fix covers: once the entry is gone, the writer is finished --
    /// not only on the first write. It also pins that the refusal is *permanent* for that writer
    /// (`isDead`), so a caller that keeps writing gets an error each time rather than one refusal
    /// followed by a resumed stream.
    func testOnceTheEntryIsGoneEveryFurtherWriteIsRefused() throws {
        try runBounded("writes after a peer cancel", timeout: 20) {
            let core = CoreUnderTest(role: .client, label: "writes-after-peer-cancel")
            defer { core.shutDown() }

            let opened = try core.core.openStream(descriptor: Self.method, timeout: nil)
            try await opened.stream.outbound.write(.metadata(Metadata()))
            XCTAssertEqual(
                core.pipe.takeSentOps().testDescriptions,
                ["openStream(1, method: xpc.grpc.Order/Push, timeout: nil)", "metadata(1, [])"],
                "the control: while the entry is live the deferred openStream does go out")

            try core.pipe.deliver([.cancel(1, reason: "the peer gave up")])
            _ = core.pipe.takeSentOps()  // line 6: a peer cancel is never echoed; nothing to check here

            for attempt in 1...2 {
                var thrown: (any Error)?
                do {
                    try await opened.stream.outbound.write(.message(GRPCSwiftData([1, 2, 3])))
                } catch {
                    thrown = error
                }
                XCTAssertEqual(
                    (thrown as? RPCError)?.code, .unavailable,
                    "write \(attempt) after the peer's cancel must be refused")
            }
            await opened.stream.outbound.finish()

            XCTAssertEqual(
                core.pipe.takeSentOps().testDescriptions, [],
                "a removed stream's writer may put nothing further on the wire")
        }
    }

    // ---------------------------------------------------------------------------------------
    // MARK: - The removal lands *inside* the write
    // ---------------------------------------------------------------------------------------

    /// **Window 1 of 2: the removal completes between the encode and the decision.**
    ///
    /// `RPCTransportCore.send(_:forStream:)` encodes outside the submission lock and then, inside
    /// it, decides whether the stream is still registered. This test performs the *entire* removal
    /// -- table entry gone, `cancel` on the wire -- from inside `encode`, so by the time the
    /// decision is taken the `cancel` has already been submitted. The only correct outcome is a
    /// refusal: `openStream` must not follow it.
    ///
    /// # Why this is deterministic
    ///
    /// The hook does not race the write; it *is* the write, on the write's own thread, at the one
    /// instant of interest. Nothing here is retried, timed or load-sensitive. (The suite has been
    /// burned once by a retry-until-it-races design that turned out to sample a warmth-dependent
    /// distribution, so "held open" rather than "sampled" is the house rule.)
    ///
    /// # What it discriminates
    ///
    /// Move the registry check back *before* the encode -- i.e. ask "is the stream open?" and then
    /// encode and submit -- and this test fails with `[cancel(1), openStream(1), metadata(1)]`: the
    /// check saw a live stream, the removal happened while the bytes were being built, and the
    /// deferred `openStream` opened a stream on the peer that the client had already abandoned.
    /// That is the whole defect, reproduced on demand.
    func testARemovalDuringTheEncodeCannotBeOvertakenByTheOpenStream() throws {
        try runBounded("a removal during the encode", timeout: 20) {
            let pipe = TestPipe(label: "removal-during-encode")
            let codec = HookedCodec()
            let core = RPCTransportCore(pipe: pipe, codec: codec, role: .client)
            defer { core.close() }

            let opened = try core.openStream(descriptor: Self.method, timeout: nil)
            XCTAssertEqual(opened.id, 1, "a client core allocates odd ids from 1")

            // Fires once, inside the encode of the writer's first batch, and returns only after the
            // removal has run to completion -- including its own encode, which passes straight
            // through because the hook takes itself out of the slot before running.
            codec.onNextEncode { [weak core] in
                core?.cancelStream(1, reason: "a deadline that fired mid-encode")
            }

            var thrown: (any Error)?
            do {
                try await opened.stream.outbound.write(.metadata(Metadata()))
            } catch {
                thrown = error
            }

            XCTAssertEqual(
                (thrown as? RPCError)?.code, .unavailable,
                "the write must be refused: its `openStream` would open a stream the `cancel` "
                    + "already closed")
            XCTAssertEqual(
                pipe.takeSentOps().testDescriptions,
                ["cancel(1, reason: a deadline that fired mid-encode)"],
                "the cancel must be the only op on the wire for stream 1")
        }
    }

    /// **Window 2 of 2: the removal lands after the decision, while the bytes are being submitted.**
    ///
    /// Here the write is *entitled* to go out -- the stream was registered when the decision was
    /// taken -- so the property is the other one: the `cancel` of a removal that happens during the
    /// submission must land **behind** the `openStream`, never in front of it. It is the half a
    /// check-then-send cannot supply, however tightly the two are packed: at the moment
    /// `TestPipe.onEachSend` runs, the write has passed its check and the remover has already taken
    /// the entry out of the registry, which in the pre-fix build was enough for its `cancel` to
    /// reach the wire first.
    ///
    /// # Why this is deterministic in both directions
    ///
    /// The hook holds the write inside `pipe.send` and does not return until:
    ///
    /// * `core.liveStreamCount` has reached 0 -- the remover is provably past the registry and has
    ///   nothing left to do but submit its `cancel`; and
    /// * either the remover has finished (which is what the **pre-fix** build does, and it then
    ///   fails on order) or ``Self/removerSubmissionWindow`` has elapsed (which is what the fixed
    ///   build does, because the remover cannot acquire the submission lock while this send holds
    ///   it). The wait is not a race sample: with the fix it is *expected* to expire, and
    ///   expiring is the observation.
    ///
    /// # What it discriminates
    ///
    /// Move `pipe.send` outside the submission lock -- keeping the check inside it -- and this test
    /// fails with `[cancel(1), openStream(1), metadata(1)]`.
    func testARemovalDuringTheSubmissionCannotOvertakeTheOpenStream() throws {
        try runBounded("a removal during the submission", timeout: 30) {
            let pipe = TestPipe(label: "removal-during-submission")
            let core = RPCTransportCore(pipe: pipe, codec: CompactWireCodec(), role: .client)
            defer { core.close() }

            let opened = try core.openStream(descriptor: Self.method, timeout: nil)
            XCTAssertEqual(opened.id, 1, "a client core allocates odd ids from 1")

            let hookHasFired = Observed(false)
            let removerFinished = DispatchSemaphore(value: 0)
            let entryWasGone = Observed(false)

            pipe.onEachSend { [weak core] _ in
                // The removal's own `cancel` comes through here too; only the first send -- the
                // writer's `[openStream, metadata]` -- is the one to stand inside.
                guard !hookHasFired.mutate({ was -> Bool in
                    let seen = was
                    was = true
                    return seen
                }) else { return }
                guard let core else { return }

                // A separate *thread*, not a `Task`: this hook parks the thread it is running on,
                // and parking one of the cooperative pool's threads would risk starving the work
                // that is supposed to release it.
                DispatchQueue.global().async {
                    core.cancelStream(1, reason: "a deadline that fired mid-submission")
                    removerFinished.signal()
                }

                // Phase 1: wait until the entry has left the registry. That is the instant the
                // `cancel` becomes submittable, and the instant the pre-fix build lost the order.
                let deadline = DispatchTime.now() + .seconds(10)
                while core.liveStreamCount > 0, DispatchTime.now() < deadline {
                    usleep(200)
                }
                entryWasGone.mutate { $0 = core.liveStreamCount == 0 }

                // Phase 2: give the remover every chance to submit ahead of us. It cannot, because
                // this send holds the submission lock -- so this wait is expected to expire.
                _ = removerFinished.wait(timeout: .now() + Self.removerSubmissionWindow)
            }

            try await opened.stream.outbound.write(.metadata(Metadata()))

            XCTAssertTrue(
                entryWasGone.isSet,
                "the premise: the remover must have taken the entry out of the registry while the "
                    + "write was inside `pipe.send`, or this test proves nothing about ordering")

            // Bound the read on the remover rather than reading straight away: its `cancel` is
            // submitted after this write released the lock, which is a different thread.
            try await waitUntil("the removal's cancel reached the wire") {
                pipe.sentBlobs.count >= 2
            }
            XCTAssertEqual(
                pipe.takeSentOps().testDescriptions,
                [
                    "openStream(1, method: xpc.grpc.Order/Push, timeout: nil)",
                    "metadata(1, [])",
                    "cancel(1, reason: a deadline that fired mid-submission)",
                ],
                "a cancel decided during the submission must land behind the openStream, not in "
                    + "front of it")
        }
    }

    /// How long ``testARemovalDuringTheSubmissionCannotOvertakeTheOpenStream()`` lets the remover
    /// try to submit before concluding that it cannot.
    ///
    /// The same 250 ms, and the same reasoning, as `negativeAssertionSettleWindow`: "the cancel did
    /// **not** get out in front" is only meaningful after giving it a real chance to, and 250 ms is
    /// three orders of magnitude past what a submission costs on this substrate. Restated as a
    /// `DispatchTimeInterval` because the wait is on a `DispatchSemaphore`, on a thread that is
    /// deliberately blocked.
    private static let removerSubmissionWindow: DispatchTimeInterval = .milliseconds(250)

    // ---------------------------------------------------------------------------------------
    // MARK: - The peer's cancel reason is bounded
    // ---------------------------------------------------------------------------------------

    /// `route(.cancel)` builds the local `RPCError` the application sees out of the **peer's**
    /// `reason`, and the decode path caps that field only at `CompactWireCodec`'s 16 MiB body
    /// length. Unbounded, a peer's `cancel` becomes a 16 MiB error message held in the inbound
    /// sequence and in every log that prints it -- the same unbounded in-process allocation
    /// `failStream` and `cancelStream` already refuse.
    ///
    /// The pathological value is **one grapheme cluster** (a base character plus 100 000 combining
    /// marks), which is what makes this discriminating rather than decorative: `prefix(512)` --
    /// which this file's history shows is the natural wrong answer -- bounds `Character`s and
    /// would pass the whole 200 KB through untouched. Only a bound on UTF-8 *bytes* shortens it.
    func testAPeersCancelReasonCannotDriveTheSizeOfTheLocalError() throws {
        let pathological = "a" + String(repeating: "\u{0301}", count: 100_000)
        XCTAssertEqual(pathological.count, 1, "the whole value must be a single grapheme cluster")

        let message = try runBounded("the peer's cancel reason", timeout: 30) { () -> String in
            let core = CoreUnderTest(role: .client, label: "peer-cancel-reason")
            defer { core.shutDown() }

            let opened = try core.core.openStream(descriptor: Self.method, timeout: nil)
            try await opened.stream.outbound.write(.metadata(Metadata()))
            _ = core.pipe.takeSentOps()

            try core.pipe.deliver([.cancel(1, reason: pathological)])

            var thrown: (any Error)?
            do {
                for try await _ in opened.stream.inbound {}
            } catch {
                thrown = error
            }
            guard let error = thrown as? RPCError else {
                XCTFail("the peer's cancel must fail the inbound sequence; got \(thrown as Any)")
                return ""
            }
            XCTAssertEqual(error.code, .cancelled)
            return error.message
        }

        XCTAssertTrue(
            message.hasPrefix("the peer cancelled stream 1: "),
            "the local error must still say what happened; got \(message.prefix(64))")
        XCTAssertLessThan(
            message.utf8.count, 2 * TestPipeCore.maxWireReasonLength,
            "the local error came back at \(message.utf8.count) byte(s) from a "
                + "\(pathological.utf8.count)-byte peer reason; the peer's input size is driving "
                + "the size of an allocation this process holds")
    }
}

// ===========================================================================================
// MARK: - A codec that lets a test stand inside the encode
// ===========================================================================================

/// `CompactWireCodec` with a one-shot hook run **inside** ``encode(_:)``.
///
/// This is the suite's only way to occupy the gap between "the ops for this write exist" and "the
/// core has decided whether it is still allowed to send them" -- `RPCTransportCore` encodes outside
/// its submission lock and decides inside it, deliberately, and that gap is where the last of the
/// outbound-ordering race lived. `TestPipe.onEachSend` is one instant too late to see it: by then
/// the decision has already been taken.
///
/// The hook is **taken out of its slot before it runs**, so the removal a hook performs can encode
/// its own `cancel` through this same codec without recursing.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class HookedCodec: WireCodec {

    private let inner = CompactWireCodec()
    private let pending = Mutex<(@Sendable () -> Void)?>(nil)

    /// Installs the hook for the next ``encode(_:)`` only. Overwrites any hook not yet fired.
    func onNextEncode(_ body: @escaping @Sendable () -> Void) {
        pending.withLock { $0 = body }
    }

    func encode(_ ops: [RPCOp]) throws(RPCError) -> GRPCSwiftData {
        let hook = pending.withLock { slot -> (@Sendable () -> Void)? in
            let taken = slot
            slot = nil
            return taken
        }
        hook?()
        return try inner.encode(ops)
    }

    func decode(_ blob: GRPCSwiftData) throws(RPCError) -> [WireDecodeItem] { try inner.decode(blob) }
}
