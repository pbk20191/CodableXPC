import Foundation
import GRPCCore
import GRPCXPCTransport
import DemoProto
import os

/// The service half. launchd starts this process on demand when the host dials the `.xpc`
/// bundle's identifier; nothing installs it and nothing has to clean it up.
///
/// **Where the output goes.** A bundled XPC service has no terminal: launchd gives it
/// `/dev/null` for stdout and stderr, so `print` and `FileHandle.standardError` both vanish. Every
/// diagnostic here therefore goes to the unified log, and `run.sh` reads it back with
///
///     log show --last 2m --predicate 'subsystem == "com.example.GRPCXPCDemo"' --info
///
/// which is the only way to see anything this process says.
let log = Logger(subsystem: "com.example.GRPCXPCDemo", category: "CalcService")

/// The generated `SimpleServiceProtocol` -- the shape that hides `RPCAsyncSequence` request
/// handling behind plain values where it can. All four methods are the four call types.
struct Calculator: Demo_V1_Calculator.SimpleServiceProtocol {

    /// Unary.
    func double(
        request: Demo_V1_CalcRequest,
        context: ServerContext
    ) async throws -> Demo_V1_CalcReply {
        log.info("double(\(request.value, privacy: .public))")
        return .with {
            $0.value = request.value * 2
            $0.responderPid = getpid()
        }
    }

    /// Client-streaming: drain the whole request stream, answer once.
    func sum(
        request: RPCAsyncSequence<Demo_V1_CalcRequest, any Error>,
        context: ServerContext
    ) async throws -> Demo_V1_CalcReply {
        var total: Int32 = 0
        for try await message in request { total &+= message.value }
        log.info("sum -> \(total, privacy: .public)")
        return .with {
            $0.value = total
            $0.responderPid = getpid()
        }
    }

    /// Server-streaming: one request, `value` responses.
    func countTo(
        request: Demo_V1_CalcRequest,
        response: RPCWriter<Demo_V1_CalcReply>,
        context: ServerContext
    ) async throws {
        log.info("countTo(\(request.value, privacy: .public))")
        let pid = getpid()
        // `calc.proto` says "Counts up from 1 to `value`", and for a value below 1 that
        // range is empty -- so the response stream is empty and the call ends OK. Clamping
        // with `max(value, 1)` answered CountTo(0) with [1] instead, which is neither what
        // the proto documents nor a count of anything.
        guard request.value >= 1 else { return }
        for i in 1...request.value {
            try await response.write(.with { $0.value = i; $0.responderPid = pid })
        }
    }

    /// Bidirectional-streaming: one response per request, written as each arrives rather than
    /// after the request stream ends. That is what makes it genuinely bidirectional -- the host
    /// checks that it saw a reply before it had finished sending.
    func runningTotal(
        request: RPCAsyncSequence<Demo_V1_CalcRequest, any Error>,
        response: RPCWriter<Demo_V1_CalcReply>,
        context: ServerContext
    ) async throws {
        let pid = getpid()
        var total: Int32 = 0
        for try await message in request {
            total &+= message.value
            try await response.write(.with { $0.value = total; $0.responderPid = pid })
        }
        log.info("runningTotal -> \(total, privacy: .public)")
    }
}

/// **No `xpc_main`.** `XPCServerTransport.service(named:)` builds an `XPCListener(service:)`, and
/// `xpc_listener_create`'s own header says its `service` parameter is "The Mach service or XPC
/// Service name" -- so the listener performs the launchd check-in that `xpc_main` would otherwise
/// do, and this process keeps its own `main`. `serve()` then never returns, which is what holds
/// the process open for launchd.
@main
enum Main {
    static func main() async {
        log.info("starting, pid \(getpid(), privacy: .public)")
        do {
            let transport = try XPCServerTransport.service(named: DemoService.bundleIdentifier)
            log.info("listening on \(DemoService.bundleIdentifier, privacy: .public)")
            let server = GRPCServer(transport: transport, services: [Calculator()])
            try await server.serve()
            log.info("serve() returned")
        } catch {
            log.error("failed: \(String(describing: error), privacy: .public)")
            exit(1)
        }
    }
}
