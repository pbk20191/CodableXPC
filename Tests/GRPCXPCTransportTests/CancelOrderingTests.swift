import Foundation
import GRPCCore
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

/// Two properties of `cancel`, both of them about a **removal that happens under a live writer**.
///
/// 1. **Nothing may follow the `cancel` for a stream the peer has never heard of.** `openStream`
///    is deferred to the writer's first write, so between `RPCTransportCore.openStream(...)` --
///    which registers the entry and arms the deadline -- and that first write, the stream exists
///    locally and nowhere else. A removal inside that gap (a fired deadline is the reachable one)
///    sends `cancel(id)` for an id the peer will drop, and the write that follows would then open
///    the stream *behind* it.
/// 2. **The peer's `cancel` reason is peer-chosen input**, and the local `RPCError` built from it
///    is bounded like every other sink for peer text in `RPCTransportCore`.
///
/// Both are driven through `CoreUnderTest`/`TestPipe` rather than a real XPC pair: the subject is
/// which ops reached the wire and in what order, which is exactly what `TestPipe.takeSentOps()`
/// reports and what an end-to-end pair hides.
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
            message.utf8.count, 2 * RPCTransportCore.maxWireReasonLength,
            "the local error came back at \(message.utf8.count) byte(s) from a "
                + "\(pathological.utf8.count)-byte peer reason; the peer's input size is driving "
                + "the size of an allocation this process holds")
    }
}
