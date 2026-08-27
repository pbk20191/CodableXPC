import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

/// **L6**: nothing libxpc retains points back at the objects that own it, so dropping the last
/// Swift reference really does run `deinit` all the way down to `session.cancel()`.
///
/// This is the measurement task-7 §9 item 3 could not make and Task 8a deferred. It matters more
/// than "no memory leak": the thing that leaks when `deinit` is unreachable is a **native XPC
/// session and its Mach port pair**, and the failure mode Task 5 measured for exactly this
/// (`onReceive` capturing its pipe strongly) is a pipe that stays alive forever.
///
/// # What is reachable from a test, and what is not
///
/// | object | weak reference possible? |
/// |---|---|
/// | `XPCClientTransport` | yes |
/// | `XPCServerTransport` | yes |
/// | the client's `RPCTransportCore` | yes, via ``InspectableXPCPair`` |
/// | the client's `XPCPipe` | yes, via ``InspectableXPCPair`` |
/// | the **server's** per-connection core and pipe | **no** -- built inside the private
///   `XPCServerTransport.Acceptor.accept`, and never handed out |
/// | the `XPCListener` | **no** -- a `private let` on `XPCServerTransport` |
///
/// The last two are covered behaviourally instead, by
/// ``testReleasingTheServerTransportTakesItsListenerWithIt()``: a leaked listener is a listener
/// that still answers a dial, and a leaked accepted core is a session that never hangs up. Neither
/// is as strong as a weak reference, and the task report says so rather than claiming otherwise.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class OwnershipTests: XCTestCase {

    // =======================================================================================
    // MARK: - deinit reachability
    // =======================================================================================

    /// Both transports, the client's core and the client's pipe all `deinit` after a completed
    /// drain and the last strong reference going away.
    ///
    /// - Important: **built with ``XPCTransportPair/make()`` (through ``InspectableXPCPair``), never
    ///   through `withPair`/`withTransports`.** Both harness entry points pin the pair for the whole
    ///   of the body, so a weak reference taken inside one can never nil -- the measurement in Task
    ///   8a §1.1, and the trap this test would otherwise have walked into.
    ///
    /// The scope discipline is the test: everything strong lives inside the `do { }`, including the
    /// task group, so leaving it is what drops the last reference. A weak reference that is still
    /// non-`nil` afterwards names precisely which link in
    /// `libxpc → session → handlers → Delivery → …` grew a strong edge back.
    func testBothTransportsAndTheClientsCoreAndPipeAllDeinit() throws {
        try runBounded("deinit reachability", timeout: 20) {
            weak var weakServer: XPCServerTransport?
            weak var weakClient: XPCClientTransport?
            weak var weakCore: RPCTransportCore?
            weak var weakPipe: XPCPipe?

            do {
                let pair = try InspectableXPCPair.make(label: "deinitReach")
                weakServer = pair.server
                weakClient = pair.client
                weakCore = pair.clientCore
                weakPipe = pair.clientPipe

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await pair.server.listen(streamHandler: RawSeamHandlers.echoing())
                    }
                    group.addTask { try await pair.client.connect() }

                    // A real RPC, so every object under test has actually been used: a transport
                    // that was never exercised could `deinit` cleanly while a live one leaked.
                    let bodies = try await pair.client.completeOneEchoRPC(
                        payload: lifecyclePayload(400))
                    XCTAssertEqual(
                        bodies,
                        ["echo:" + String(decoding: Array(lifecyclePayload(400)), as: UTF8.self)])

                    pair.client.beginGracefulShutdown()
                    pair.server.beginGracefulShutdown()
                    try await group.waitForAll()
                }
            }

            XCTAssertNil(
                weakClient,
                "XPCClientTransport did not deinit: something outside it holds a strong reference")
            XCTAssertNil(
                weakCore,
                "the client's RPCTransportCore did not deinit. The usual cause is a strong edge "
                    + "back into it -- a pipe handler, an outbound writer, or a cancellation "
                    + "observer that captured the core instead of only the handle (a self-cycle, "
                    + "invisible to every other check here)")
            XCTAssertNil(
                weakPipe,
                "the client's XPCPipe did not deinit, so its XPCSession and Mach port pair are "
                    + "leaked. Measured cause in Task 5: an onReceive handler capturing the pipe "
                    + "strongly, which libxpc then holds forever")
            XCTAssertNil(
                weakServer,
                "XPCServerTransport did not deinit, so its listener was never cancelled")
        }
    }

    /// Releasing the `XPCServerTransport` stops its endpoint serving RPCs.
    ///
    /// The behavioural stand-in for a weak reference to `XPCListener`, which is a `private let` and
    /// cannot be reached from a test. Four mutations were needed to establish what it actually
    /// measures, and the answer is not what its first name suggested:
    ///
    /// * removing `listener.cancel()` from `deinit` leaves it green (M21) -- ARC releases the
    ///   listener with the transport anyway, and `XPCListener`'s own `deinit` finishes the job;
    /// * leaking the listener object (M21b) fails, but on the *dial*, not on the RPC: a cancelled
    ///   listener's endpoint refuses `activate()` outright;
    /// * leaking it **and** removing `listener.cancel()` still leaves it green (M21c) -- because
    ///   `deinit`'s other line, `acceptor.closeAll()`, has already cleared `admitting`, so the
    ///   surviving listener refuses every new peer with `XPCPipe.rejecting`;
    /// * only removing **both** lines and leaking the listener (M21d) fails, by timeout: the
    ///   latecomer is admitted onto a transport nobody is `listen()`ing on.
    ///
    /// So this test's property is precisely *"a released `XPCServerTransport` serves nobody"*, and
    /// `deinit` has two independent ways of keeping it. It does **not** show that the `XPCListener`
    /// object was freed; `testBothTransportsAndTheClientsCoreAndPipeAllDeinit` shows that for the
    /// transport that solely owns it, which is as close as the seam allows.
    ///
    /// The endpoint's type is never named here, deliberately: `XPCEndpoint` would force
    /// `import XPC` into this file, and the whole point of `XPCPipe.swift` and
    /// `XPCServerTransport.swift` being the only two files that may name libxpc types is that the
    /// set does not creep. The optional-`var`-set-to-`nil` shape is what lets the endpoint outlive
    /// its server without a type annotation.
    func testReleasingTheServerTransportTakesItsListenerWithIt() throws {
        try runBounded("releasing the server kills the listener", timeout: 20) {
            var server: XPCServerTransport? = try XPCServerTransport.anonymous()
            weak var weakServer: XPCServerTransport?
            weakServer = server
            guard let endpoint = server?.endpoint else {
                XCTFail("an anonymous XPCServerTransport must have an endpoint")
                return
            }

            server = nil
            XCTAssertNil(weakServer, "the server transport did not deinit")

            // Dial the endpoint of a listener that should no longer exist, and try an RPC on it.
            //
            // **Both stages may be where it fails, and which one is race-dependent.** Measured over
            // a 25-run sweep: usually the dial succeeds (libxpc resolves lazily) and the RPC fails
            // with peer death; once in ~25 runs `activate()` itself throws
            // `"could not activate the XPC session: ... Bad file descriptor"`. Both are the same
            // fact about the same dead listener, so the `do` covers the dial *and* the call and the
            // assertion is on the code. Matching only the RPC's failure made this test flaky, which
            // is how the second outcome was found.
            let queue = DispatchSerialQueue(label: "GRPCXPCTransportTests.orphanEndpoint.client")
            var pipe: XPCPipe?
            var connectTask: Task<Void, any Error>?
            var client: XPCClientTransport?
            do {
                var built: RPCTransportCore?
                pipe = try XPCPipe.connecting(to: endpoint, queue: queue) { pipe in
                    built = RPCTransportCore(pipe: pipe, codec: CompactWireCodec(), role: .client)
                }
                guard let core = built else {
                    XCTFail("XPCPipe.connecting did not run its `building` closure")
                    return
                }
                let transport = XPCClientTransport(core: core)
                client = transport
                connectTask = Task { try await transport.connect() }

                _ = try await transport.completeOneEchoRPC(payload: lifecyclePayload(410))
                XCTFail(
                    "the endpoint of a released XPCServerTransport still served an RPC, so its "
                        + "listener outlived it")
            } catch let error as RPCError {
                XCTAssertEqual(
                    error.code, .unavailable,
                    "a dead listener's endpoint must refuse with .unavailable, whether the dial or "
                        + "the call is what notices: \(error.message)")
            }

            client?.beginGracefulShutdown()
            connectTask?.cancel()
            _ = try? await connectTask?.value
            withExtendedLifetime(pipe) {}
        }
    }

    // =======================================================================================
    // MARK: - cancel() before activate(), from the public factory
    // =======================================================================================

    /// `XPCPipe.connecting(to:queue:) { $0.cancel() }` must throw, not trap.
    ///
    /// Before Task 5's fix this killed the process, and the reason is the sharpest corner of
    /// `XPCPipe`'s disposal matrix: `cancel()` on an `.idle` (dialled, never-activated) pipe cannot
    /// cancel the session -- cancelling a never-activated session traps -- but it cannot skip it
    /// either, because *releasing* a never-activated session traps just as hard. The debt is settled
    /// by `activate()`'s `.shutDown` arm, which activates the session anyway purely so that it can
    /// be cancelled, and only then throws.
    ///
    /// Both trap directions are pinned out-of-process by rows **D1** and **D2** of the disposal
    /// matrix, which is what makes this in-process test meaningful rather than circular: the rows
    /// prove that the wrong answer really is a process death, and this proves the wrapper does not
    /// give it.
    ///
    /// 50 iterations, because a leak-shaped regression (never activating, never cancelling, just
    /// dropping) would be silent at one.
    ///
    /// - Note: this test's failure mode is a **process death**, so it belongs in a suite run where
    ///   that is visible. It is in-process on purpose: the expected answer is "no trap", and an
    ///   XCTest that traps is a loud crash, not a swallowed assertion.
    func testCancellingInsideTheDialFactoryThrowsRatherThanTrapping() throws {
        try runBounded("cancel before activate", timeout: 20) {
            let server = try XPCServerTransport.anonymous()
            guard let endpoint = server.endpoint else {
                XCTFail("an anonymous XPCServerTransport must have an endpoint")
                return
            }

            for iteration in 0..<50 {
                let queue = DispatchSerialQueue(
                    label: "GRPCXPCTransportTests.cancelBeforeActivate.\(iteration)")
                do {
                    _ = try XPCPipe.connecting(to: endpoint, queue: queue) { pipe in
                        pipe.cancel()
                    }
                    XCTFail("a pipe cancelled inside `building` must not be handed back")
                } catch let error as RPCError {
                    XCTAssertEqual(
                        error.code, .unavailable,
                        "iteration \(iteration): a pipe cancelled before activation must report "
                            + ".unavailable")
                    XCTAssertTrue(
                        error.message.contains("cancelled before it could be activated"),
                        "iteration \(iteration): the error must be the one activate()'s "
                            + ".shutDown arm throws, not a dial failure: \(error.message)")
                }
            }

            withExtendedLifetime(server) {}
        }
    }
}
