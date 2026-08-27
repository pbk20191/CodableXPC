import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest
import XPC

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

/// `XPCPipe.accepting(_:queue:building:)` with a `building` closure that **cancels the pipe**, and
/// `XPCPipe.rejecting(_:reason:)` -- the two accept-side rows of the disposal matrix that live in
/// this package rather than in libxpc.
///
/// # ⚠️ This is the one file in the suite that builds its own accept path, and why
///
/// The brief's first hazard is "never drop the pipe `accepting` returns inside the accept window --
/// an unclosable process death. Drive `XPCServerTransport`; do not build a second accept path." That
/// rule exists so that no test has to re-derive the publish-before-you-return-the-`Decision`
/// discipline. Here the *subject* is `accepting` itself, so there is no way to drive it through
/// `XPCServerTransport` -- its `Acceptor` never cancels a pipe in `building`, which is the exact
/// behaviour under test.
///
/// The discipline is therefore reproduced explicitly and minimally:
///
/// 1. the returned pipe is written into a `Mutex` **before** the `Decision` is returned, so it is
///    never released inside the window;
/// 2. nothing else happens between the `accepting` call and the `return`;
/// 3. the connection's queue is minted per connection and is never the listener's, because
///    `accepting` does `queue.sync` and trips `dispatchPrecondition(.notOnQueue(queue))` otherwise;
/// 4. the pipes are released only after the listener has been cancelled and the whole test is over.
///
/// # What this pins
///
/// Before Task 5's fix, `accepting(request, queue:) { $0.cancel() }` **killed the process** (§5 fact
/// 23): the accepted pipe was seeded `sessionIsLive: true`, so `cancel()` called
/// `session.cancel(reason:)` from inside the incoming-session closure, which is `_xpc_api_misuse`.
/// The fix seeds it `false` and re-arms it in `acceptWindowClosed()`, after `building` returns.
/// Row **A1** of the out-of-process disposal matrix
/// (`scratchpad/matrix/XPCSessionDisposalMatrix.swift`) is the platform half of that -- it exits
/// 133 -- and this is the wrapper half.
///
/// The expected answer here is "no trap", so an in-process test is the right shape: a trap is a loud
/// crash of the whole run, not a swallowed assertion.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class AcceptWindowTests: XCTestCase {

    /// Everything the incoming-session closure needs, and the only strong home the accepted pipes
    /// ever have. A class so the escaping closure can publish into it.
    private final class AcceptedPipes: Sendable {
        /// Published **before** the `Decision` is returned. This is the whole safety argument.
        let pipes = Mutex<[XPCPipe]>([])
        let accepts = Mutex(0)
        let rejects = Mutex(0)
    }

    /// `building { $0.cancel() }` on the accept side must be a safe no-op, and `rejecting` must turn
    /// a peer away without creating a session at all.
    ///
    /// Both in one test because they are the two halves of one decision surface (admit / refuse) and
    /// because a single listener can serve both: the first peer is accepted-then-cancelled, the
    /// second is rejected outright.
    ///
    /// The assertions are deliberately modest -- the closure ran, the counts are right, and the
    /// process is still alive. The load-bearing observation is the last one, and it is not an
    /// `XCTAssert`: it is the fact that this method returns at all.
    func testCancellingInsideBuildingAndRejectingAreBothSafe() throws {
        let state = AcceptedPipes()

        let listenerQueue = DispatchSerialQueue(label: "GRPCXPCTransportTests.acceptWindow.listener")
        let listener = XPCListener(
            targetQueue: listenerQueue, options: .inactive,
            incomingSessionHandler: { request in
                // The first peer is admitted and its pipe is cancelled inside `building`; the
                // second is refused. `accepts` is bumped first so the branch is decided once.
                let index = state.accepts.withLock { count -> Int in
                    count += 1
                    return count
                }
                if index > 1 {
                    state.rejects.withLock { $0 += 1 }
                    return XPCPipe.rejecting(request, reason: "this test refuses the second peer")
                }
                // One queue per connection, and NOT the listener's: `accepting` blocks on the queue
                // it is handed.
                let queue = DispatchSerialQueue(
                    label: "GRPCXPCTransportTests.acceptWindow.connection.\(index)")
                let (decision, pipe) = XPCPipe.accepting(request, queue: queue) { pipe in
                    // The subject. Before Task 5's fix this line was the process death.
                    pipe.cancel()
                }
                // **Published before the Decision is returned**, and never dropped in that span.
                state.pipes.withLock { $0.append(pipe) }
                return decision
            })
        try listener.activate()

        // Two peers, each dialling and sending one blob -- which is what makes libxpc run the
        // incoming-session closure at all.
        var dialledPipes: [XPCPipe] = []
        for peer in 0..<2 {
            let queue = DispatchSerialQueue(
                label: "GRPCXPCTransportTests.acceptWindow.peer.\(peer)")
            let pipe = try XPCPipe.connecting(to: listener.endpoint, queue: queue) { _ in }
            dialledPipes.append(pipe)
            // A send may legitimately fail for the rejected peer, depending on when libxpc gets
            // round to refusing it; the blob only has to be *attempted* to wake the listener.
            try? pipe.send(lifecyclePayload(500))
        }

        try runBounded("accept window", timeout: 10) {
            try await waitUntil("both peers to reach the listener") {
                state.accepts.withLock { $0 } >= 2
            }
        }

        XCTAssertEqual(
            state.accepts.withLock { $0 }, 2, "both peers must reach the incoming-session closure")
        XCTAssertEqual(state.rejects.withLock { $0 }, 1, "exactly one peer must be refused")
        XCTAssertEqual(
            state.pipes.withLock { $0.count }, 1,
            "exactly one pipe must have been built: `rejecting` creates no session at all, which is "
                + "the reason it -- and not accept-then-cancel -- is how a peer is turned away")

        // Teardown order matters and is the one `XPCServerTransport.deinit` documents: the accepted
        // pipes are released first (they were cancelled in `building`, so their sessions are
        // released uncancelled, which for an *accepted* session is the measured-safe row A2/A4), and
        // the listener is cancelled last.
        for pipe in dialledPipes { pipe.cancel() }
        state.pipes.withLock { $0.removeAll() }
        listener.cancel()
    }
}
