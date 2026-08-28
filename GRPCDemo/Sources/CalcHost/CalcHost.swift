import Foundation
import GRPCCore
import GRPCXPCTransport
import DemoProto

/// The host half: the "application". It dials the `.xpc` bundle sitting inside its own bundle by
/// bundle identifier, drives all four call types through the generated client, and checks the
/// answers.
///
/// Every reply carries the responding process's pid, and every check below insists it is not this
/// one. That assertion is the reason this demo exists: the 635 tests behind this transport all run
/// two XPC sessions inside a single test process, so none of them can tell a real process boundary
/// from a very convincing in-process one.
@main
enum Main {
    static let hostPID = getpid()

    static func main() async {
        print("host      pid \(hostPID)")
        do {
            let transport = try XPCClientTransport.connecting(
                toXPCService: DemoService.bundleIdentifier)
            let grpc = GRPCClient(transport: transport)
            let calc = Demo_V1_Calculator.Client(wrapping: grpc)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await grpc.runConnections() }

                let outcome: Result<Void, any Error>
                do {
                    try await runAllFour(calc)
                    outcome = .success(())
                } catch {
                    outcome = .failure(error)
                }
                // Shut down on the failing path too, or `runConnections()` never returns and this
                // process hangs on a task group instead of reporting the error it already has.
                grpc.beginGracefulShutdown()
                try await group.waitForAll()
                try outcome.get()
            }

            print("OK -- all four call types crossed a real process boundary.")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    /// Fails by throwing, so `main` shuts the client down before reporting.
    struct Wrong: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    static func expect(_ condition: Bool, _ what: @autoclosure () -> String) throws {
        if !condition { throw Wrong(what: what()) }
    }

    /// Asserts the answer came from somewhere else. Called on every reply.
    static func expectRemote(_ pid: Int32) throws {
        try expect(
            pid != hostPID,
            "a reply was computed in this process (pid \(pid)); nothing crossed")
    }

    static func runAllFour(_ calc: Demo_V1_Calculator.Client<XPCClientTransport>) async throws {

        // ---- 1. unary -------------------------------------------------------------------
        let doubled = try await calc.double(.with { $0.value = 21 })
        try expectRemote(doubled.responderPid)
        try expect(doubled.value == 42, "Double(21) == \(doubled.value), expected 42")
        print("service   pid \(doubled.responderPid)")
        print("unary     Double(21) = \(doubled.value)")

        // ---- 2. client-streaming --------------------------------------------------------
        let summed = try await calc.sum { writer in
            for i in Int32(1)...10 { try await writer.write(.with { $0.value = i }) }
        }
        try expectRemote(summed.responderPid)
        try expect(summed.value == 55, "Sum(1...10) == \(summed.value), expected 55")
        print("client<<  Sum(1...10) = \(summed.value)")

        // ---- 3. server-streaming --------------------------------------------------------
        let counted: [Int32] = try await calc.countTo(.with { $0.value = 5 }) { response in
            var values: [Int32] = []
            for try await reply in response.messages {
                try expectRemote(reply.responderPid)
                values.append(reply.value)
            }
            return values
        }
        try expect(counted == [1, 2, 3, 4, 5], "CountTo(5) == \(counted), expected [1,2,3,4,5]")
        print("server>>  CountTo(5) = \(counted)")

        // ---- 4. bidirectional-streaming -------------------------------------------------
        //
        // A real gate, not an observation. The producer sends request 1 and then **waits for the
        // first reply before sending request 2**; the response reader opens the gate when it sees
        // it. Nothing here consults a clock, and there is no timeout: if this transport were
        // half-duplex -- if the server could not answer until the request stream closed -- this
        // would deadlock, in the open, instead of quietly printing "correct but not demonstrated".
        //
        // An earlier version merely counted how many requests had gone out when each reply landed
        // and reported what it saw. It always saw "all six already sent", because six tiny writes
        // with nothing awaited between them finish long before the first reply is routed back --
        // so the check was structurally incapable of failing and proved nothing.
        let firstReply = Gate()
        let running: [Int32] = try await calc.runningTotal { writer in
            try await writer.write(.with { $0.value = 1 })
            await firstReply.wait()
            for i in Int32(2)...6 { try await writer.write(.with { $0.value = i }) }
        } onResponse: { response in
            // Opened on the way out too: an RPC that fails before any message arrives must not
            // leave the producer parked forever.
            defer { firstReply.open() }
            var totals: [Int32] = []
            for try await reply in response.messages {
                try expectRemote(reply.responderPid)
                totals.append(reply.value)
                firstReply.open()
            }
            return totals
        }
        try expect(
            running == [1, 3, 6, 10, 15, 21],
            "RunningTotal(1...6) == \(running), expected [1,3,6,10,15,21]")
        print("bidi<<>>  RunningTotal(1...6) = \(running)")
        print("          the 2nd request was not sent until the 1st reply had arrived, so both "
            + "directions were open at once")
    }
}

/// A one-shot latch: ``wait()`` suspends until the first ``open()``, and every call after that
/// returns immediately. Opening twice is normal here -- the response reader opens it per message
/// and again on the way out -- so the second and later opens are no-ops rather than a precondition
/// failure.
///
/// A lock rather than an `actor` because ``open()`` has to be callable from a `defer`, which
/// cannot `await`. The lock is never held across a resume.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyOpen = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }

    func open() {
        let resuming = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isOpen else { return [] }
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for continuation in resuming { continuation.resume() }
    }
}
