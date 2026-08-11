// Re-exported on purpose. Everything `@XPCService` generates names Foundation
// types -- `@objc`, `NSObject`, `NSXPCConnection`, `NSXPCInterface` -- so a file
// that uses the macro without importing Foundation fails with "@objc attribute
// used without importing module 'Foundation'" pointing into generated code the
// author never wrote. A macro cannot introduce an import, so the module carries it.
@_exported import Foundation

/// Generates the NSXPC plumbing for a protocol written in ordinary Swift types.
///
/// NSXPC can only carry `NSSecureCoding` objects across a connection, so using it
/// with `Codable` normally means hand-writing an `@objc` shadow protocol whose
/// parameters are boxes, plus a client that encodes and a server adapter that
/// decodes. This macro writes all three.
///
///     @XPCService
///     protocol Greeter {
///         func greet(_ person: Person) async throws -> Greeting
///         func note(_ line: String)
///     }
///
/// Server:
///
///     connection.exportedInterface = GreeterXPC.interface
///     connection.exportedObject    = GreeterXPC.exported(MyGreeter())
///
/// Client:
///
///     connection.remoteObjectInterface = GreeterXPC.interface
///     let greeter = GreeterXPC.remote(connection)
///     let greeting = try await greeter.greet(person)
///
/// ## Which method shapes are allowed
///
/// | Declaration | Becomes |
/// |---|---|
/// | `func f(…) async throws -> R` | two-way, replies with a value or an error |
/// | `func f(…) async throws` | two-way, replies with an error or nothing |
/// | `func f(…)` | one-way, no reply |
///
/// Anything else is rejected at compile time. In particular a method that returns a
/// value but does not `throw` is refused: an XPC connection can drop at any moment,
/// and such a method has no way to say so.
///
/// ## What this does not do
///
/// **Cancellation ends the call, but does not reach the peer.** A cancelled `Task` makes an
/// `async throws` call throw `CancellationError` instead of waiting; the service still runs to
/// completion and its reply is discarded. NSXPC has no way to withdraw an in-flight invocation,
/// so that half is not a gap that can be closed here.
///
/// What it *does* close is the wait. Before, a peer that was alive and simply not answering
/// parked the caller forever -- the reply block never ran and the connection's error handler
/// never fired -- so no caller-imposed timeout was possible either. Now one is, with nothing but
/// `Task.cancel()`; which is why no timeout is baked in, since a deadline is a policy and
/// policies belong to callers.
///
/// **The synchronous shapes are not cancellable.** `throws` and `throws -> T` without `async`
/// block the calling thread in a semaphore, and a blocked thread has no task to cancel. They end
/// when the peer replies or the connection dies -- see ``XPCSyncOutcome/wait()``.
///
/// **Thrown error types do not survive.** NSXPC delivers an `NSError`, so a caller
/// catches that rather than the original Swift error.
///
/// **Conformance is not checked here.** The macro is syntactic and cannot see
/// whether your parameter types are `Codable`; if they are not, the generated code
/// fails to compile.
/// The four generated names are declared with `suffixed(…)` rather than
/// `arbitrary`. That is not a stylistic choice: a peer macro that introduces
/// arbitrary names is rejected outright on a top-level declaration, and a protocol
/// is almost always top-level. Naming them also means `GreeterXPC` and friends
/// resolve in an editor before the macro has ever run.
@attached(peer, names: suffixed(XPCShim), suffixed(XPCClient), suffixed(XPCAdapter), suffixed(XPC))
@attached(extension, names: arbitrary)
public macro XPCService(objcName: String? = nil) =
    #externalMacro(module: "XPCCodableMacros", type: "XPCServiceMacro")

/// Failures raised by generated client code, as opposed to by the peer.
public enum XPCServiceError: Error, Equatable, Sendable {
    /// The connection handed back a proxy that does not speak the expected shim
    /// protocol. In practice this means `remoteObjectInterface` was never set, or
    /// was set to a different service's interface.
    case proxyUnavailable

    /// The peer replied with neither a value nor an error. A correct peer cannot do
    /// this; a crashed or mismatched one can.
    case missingReply

    /// The connection an `XPCProxyMarker` argument arrived over was invalidated,
    /// so nothing further can be called on it. Without this a call on such a
    /// proxy never completes at all -- see ``XPCProxyLifetime``.
    case proxyConnectionInvalidated
}

/// Lets exactly one of several racing callbacks resume a continuation.
///
/// NSXPC gives a call two independent ways to finish — the reply block and the
/// connection's error handler — and nothing stops both from firing. Resuming a
/// `CheckedContinuation` twice traps, so a resume has to be arbitrated.
///
/// **Generated code no longer uses this**; it uses ``XPCCallResumption``, which arbitrates the
/// same two callbacks *and* holds the continuation so a cancellation handler can resume it. This
/// remains for a hand-written client that arbitrates its own continuation and does not need the
/// third path.
public final class XPCOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    public init() {}

    /// Returns `true` to exactly one caller, ever.
    public func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}


/// The single outcome of an `async` call, resumable from three racing places.
///
/// An NSXPC call has two ways to finish -- the reply block and the connection's error handler --
/// and nothing stops both from firing. ``XPCOneShot`` exists for exactly that. This type adds
/// the third: **the calling task being cancelled**.
///
/// That third one is why `XPCOneShot` is not enough. `withTaskCancellationHandler` runs its
/// `onCancel` outside the continuation's closure, so the handler needs something that *holds*
/// the continuation rather than something that merely arbitrates a flag. Without it a call to a
/// peer that is alive and simply not answering never comes back: the reply block never runs, the
/// connection is healthy so the error handler never runs, and the continuation is parked forever
/// -- past its own task's cancellation, which is what makes a caller-imposed timeout impossible.
///
/// **`park(_:)` can resume immediately, and must.** `withTaskCancellationHandler` invokes
/// `onCancel` at once when the task is already cancelled -- before the operation body runs -- so
/// ``cancel()`` can land before there is any continuation to resume. The outcome is remembered
/// and handed to whoever parks next.
public final class XPCCallResumption<Value>: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var outcome: Result<Value, any Error>?
    private var resumed = false

    public init() {}

    /// Hand over the continuation. Resumes it at once if an outcome already arrived.
    public func park(_ continuation: CheckedContinuation<Value, any Error>) {
        let pending: Result<Value, any Error>? = lock.withLock {
            guard !resumed else { return nil }
            if let outcome {
                resumed = true
                return outcome
            }
            self.continuation = continuation
            return nil
        }
        guard let pending else { return }
        continuation.resume(with: pending)
    }

    public func succeed(_ value: Value) { finish(.success(value)) }

    public func fail(_ error: any Error) { finish(.failure(error)) }

    /// The calling task was cancelled. Ends the call with `CancellationError`.
    ///
    /// The peer is **not** told, and cannot be: NSXPC has no way to withdraw an in-flight
    /// invocation, so the service runs to completion and its reply is discarded. What changes is
    /// that the caller stops waiting -- which is the part a caller can act on.
    public func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = lock.withLock {
            guard !resumed else { return nil }
            guard let parked = self.continuation else {
                // Nothing to resume yet. Remember it for `park(_:)`; first writer wins, so a
                // reply that races cancellation reports whichever actually happened first.
                if outcome == nil { outcome = result }
                return nil
            }
            resumed = true
            self.continuation = nil
            return parked
        }
        continuation?.resume(with: result)
    }
}

/// Collects the single outcome of a synchronous call.
///
/// `synchronousRemoteObjectProxyWithErrorHandler` runs the reply block — or the
/// error handler — before the proxy call returns, so a blocking client only has
/// to read the result afterwards. Two things can still race to fill it: a peer
/// that replies while the connection is failing reaches both paths. First write
/// wins, matching ``XPCOneShot``, so the caller sees whichever outcome actually
/// happened first rather than the last one to be written.
public final class XPCSyncOutcome<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, any Error>?
    private let arrived = DispatchSemaphore(value: 0)

    public init() {}

    public func set(_ result: Result<Value, any Error>) {
        lock.lock()
        let first = stored == nil
        if first { stored = result }
        lock.unlock()
        if first { arrived.signal() }
    }

    /// Blocks until something is written.
    ///
    /// Over a connection this returns at once: the synchronous proxy has already
    /// run the reply block or the error handler by the time the call returns. It
    /// only waits for a service reached as an `XPCProxyMarker` argument, whose
    /// reply arrives afterwards and whose failures come from its
    /// ``XPCProxyLifetime``.
    ///
    /// - Warning: unbounded, like every other wait here. It ends when the peer
    ///   replies or the proxy's connection is invalidated. Two peers that each
    ///   make a synchronous call to the other satisfy neither.
    public func wait() {
        arrived.wait()
        arrived.signal()
    }

    /// - Throws: ``XPCServiceError/missingReply`` when neither path ran, which
    ///   means the proxy returned without replying and without reporting why.
    public func take() throws -> Value {
        lock.lock()
        let result = stored
        lock.unlock()
        guard let result else { throw XPCServiceError.missingReply }
        return try result.get()
    }
}

extension XPCServiceError {
    /// The declaration order, which is what a bridged `NSError` reports as its
    /// code. Exposed so a test can name the case instead of hardcoding an index
    /// that silently shifts when a case is inserted above it.
    public static var allCasesForTesting: [XPCServiceError] {
        [.proxyUnavailable, .missingReply, .proxyConnectionInvalidated]
    }
}

/// The failure channel an `XPCProxyMarker` argument does not otherwise have.
///
/// A proxy delivered as an argument is not a connection: it has no error handler,
/// and when the connection it arrived over dies, calls on it neither reply nor
/// fail — they simply never complete. The adapter that received it *does* know
/// the connection, though, because `NSXPCConnection.current()` is set while the
/// call is being handled. Recording invalidation there gives every later call on
/// that proxy something to fail with.
///
/// - Note: `current()` is only valid in the synchronous part of the method. It
///   returns `nil` inside a `Task`, and reading it from an async context is an
///   error under the Swift 6 language mode, so the adapter captures it first.
public final class XPCProxyLifetime: @unchecked Sendable {

    private let lock = NSLock()
    private var failure: (any Error)?
    private var waiting: [(any Error) -> Void] = []

    /// A lifetime for a proxy whose connection is unknown. It never fails, which
    /// is the old behaviour, and is what a locally constructed client gets.
    public static let unbounded = XPCProxyLifetime()

    public init() {}

    /// Chains onto whatever the connection already had rather than replacing it:
    /// the handler is a single slot, and it belongs to whoever made the
    /// connection, not to us.
    public convenience init(watching connection: NSXPCConnection?) {
        self.init()
        guard let connection else { return }
        let existing = connection.invalidationHandler
        connection.invalidationHandler = { [weak self] in
            self?.fail(XPCServiceError.proxyConnectionInvalidated)
            existing?()
        }
    }

    public func fail(_ error: any Error) {
        lock.lock()
        let callbacks: [(any Error) -> Void]
        if failure == nil {
            failure = error
            callbacks = waiting
            waiting = []
        } else {
            callbacks = []
        }
        lock.unlock()
        for callback in callbacks { callback(error) }
    }

    /// The failure already recorded, or `nil` while the connection stands.
    ///
    /// A synchronous read, for a caller with nowhere to put an asynchronous one --
    /// a one-way method has no reply block and cannot throw.
    public var recordedFailure: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// Registers `onFailure`, calling it immediately if the connection is already
    /// gone. Every call over the proxy registers, so an in-flight one is resolved
    /// rather than left waiting forever.
    public func onFailure(_ onFailure: @escaping (any Error) -> Void) {
        lock.lock()
        if let failure {
            lock.unlock()
            onFailure(failure)
            return
        }
        waiting.append(onFailure)
        lock.unlock()
    }
}
