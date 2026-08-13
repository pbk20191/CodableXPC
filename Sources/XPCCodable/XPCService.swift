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
/// ## Inheritance
///
/// Only `AnyObject` and `Sendable` may be inherited, and anything else is refused at compile
/// time. The macro is syntactic: it is handed this protocol's text and nothing else, so it cannot
/// resolve an inherited protocol, cannot see its requirements, and would generate a client that
/// silently did not carry them. Copy the requirements you need into the protocol.
///
/// `AnyObject` is admitted and changes what is generated -- the client becomes a `final class`
/// rather than a struct, since a class-bound protocol cannot be satisfied by a value type. That
/// is the one place where the generated client has reference semantics.
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
public final class XPCCallResumption<Value>: XPCFailureObservationHost, @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var outcome: Result<Value, any Error>?
    private var resumed = false
    /// Failure observations kept alive while the call is in flight. Dropped -- which
    /// withdraws them -- on the resumed transition, in `park` or `finish`, whichever
    /// delivers. See ``XPCFailureObservationHost``.
    private var observations: [XPCFailureObservation] = []

    public init() {}

    /// Hand over the continuation. Resumes it at once if an outcome already arrived.
    public func park(_ continuation: CheckedContinuation<Value, any Error>) {
        let pending: Result<Value, any Error>? = lock.withLock {
            guard !resumed else { return nil }
            if let outcome {
                resumed = true
                observations = []
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

    /// Carries one `Result` across the lock boundary to `resume(with:)`.
    ///
    /// `@unchecked Sendable`, and the argument is exclusivity rather than immutability:
    /// `finish` is the only writer, the value inside is written once and read once, and the
    /// lock is what orders the two. The region checker cannot follow a hand-off through a
    /// lock -- it flagged `continuation?.resume(with: result)` as sending a value that "may
    /// race", when the whole type exists to make exactly that race impossible. The envelope
    /// states the invariant at the one boundary the checker cannot see across.
    private struct Handoff: @unchecked Sendable {
        let result: Result<Value, any Error>
        let continuation: CheckedContinuation<Value, any Error>
    }

    public func retainUntilFinished(_ observation: XPCFailureObservation) {
        let alreadyFinished: Bool = lock.withLock {
            guard !resumed else { return true }
            observations.append(observation)
            return false
        }
        // Dropping it here runs its deinit, which withdraws the registration.
        if alreadyFinished { observation.cancel() }
    }

    private func finish(_ result: Result<Value, any Error>) {
        let handoff: Handoff? = lock.withLock {
            guard !resumed else { return nil }
            guard let parked = self.continuation else {
                // Nothing to resume yet. Remember it for `park(_:)`; first writer wins, so a
                // reply that races cancellation reports whichever actually happened first.
                if outcome == nil { outcome = result }
                return nil
            }
            resumed = true
            self.continuation = nil
            observations = []
            return Handoff(result: result, continuation: parked)
        }
        guard let handoff else { return }
        handoff.continuation.resume(with: handoff.result)
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
public final class XPCSyncOutcome<Value>: XPCFailureObservationHost, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, any Error>?
    private let arrived = DispatchSemaphore(value: 0)
    /// See ``XPCFailureObservationHost`` -- dropped, and thereby withdrawn, on the
    /// first `set`.
    private var observations: [XPCFailureObservation] = []

    public init() {}

    public func set(_ result: Result<Value, any Error>) {
        lock.lock()
        let first = stored == nil
        if first {
            stored = result
            observations = []
        }
        lock.unlock()
        if first { arrived.signal() }
    }

    public func retainUntilFinished(_ observation: XPCFailureObservation) {
        let alreadyFinished: Bool = lock.withLock {
            guard stored == nil else { return true }
            observations.append(observation)
            return false
        }
        if alreadyFinished { observation.cancel() }
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
        let drained: [@Sendable (any Error) -> Void]
        if failure == nil {
            failure = error
            callbacks = waiting
            waiting = []
            drained = Array(observed.values)
            observed = [:]
        } else {
            callbacks = []
            drained = []
        }
        lock.unlock()
        for callback in callbacks { callback(error) }
        for callback in drained { callback(error) }
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
    ///
    /// **The registration is permanent** -- there is no way to withdraw it, so a
    /// long-lived proxy making many calls grows this lifetime's list by one closure
    /// per call, forever. That is why generated code no longer uses this entry
    /// point: it uses ``observe(_:)``, whose registration is withdrawn when the
    /// call completes. This stays for a hand-written observer that genuinely wants
    /// to be told once, whenever the failure comes.
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

    /// Registers `onFailure` and hands back the registration, so it can be
    /// withdrawn when the call it protects completes.
    ///
    /// This is what bounds the lifetime's footprint by *in-flight* calls rather
    /// than by all calls ever made: ``onFailure(_:)`` above appends a closure that
    /// nothing removes, so every completed call left its callback -- and everything
    /// the callback captured, a whole `XPCCallResumption` and its continuation
    /// environment -- pinned until the connection died. Measured against the shape
    /// generated code actually has: one registration per call, withdrawal on
    /// completion via ``XPCFailureObservationHost/retainUntilFinished(_:)``.
    ///
    /// The closure is held **strongly** until withdrawn, deliberately. A weak
    /// registration was considered and rejected: the failure callback is what
    /// resolves an in-flight call when the connection dies, and NSXPC releases its
    /// pending reply blocks *around* the same invalidation -- so a weakly-held
    /// callback could be gone by the time `fail` fires, and the call would hang.
    /// Exactly the hang this type exists to prevent.
    public func observe(_ onFailure: @escaping @Sendable (any Error) -> Void) -> XPCFailureObservation {
        lock.lock()
        if let failure {
            lock.unlock()
            onFailure(failure)
            return XPCFailureObservation(lifetime: nil, key: 0)
        }
        nextObservationKey += 1
        let key = nextObservationKey
        observed[key] = onFailure
        lock.unlock()
        return XPCFailureObservation(lifetime: self, key: key)
    }

    fileprivate func withdraw(_ key: UInt64) {
        lock.lock()
        observed.removeValue(forKey: key)
        lock.unlock()
    }

    /// One lifetime per connection, shared.
    ///
    /// ``init(watching:)`` chains a layer onto the connection's single
    /// `invalidationHandler` slot, and it has no way to unchain -- so a caller that
    /// built one per proxy-returning call grew the chain by one closure per call
    /// for the life of the connection, which is what the generated client used to
    /// do. Stored on the connection itself (an associated object), so the chain is
    /// one layer deep no matter how many clients or calls share the connection --
    /// and the lifetime now lives exactly as long as the connection, where the
    /// per-call one could be deallocated with calls still in flight.
    public static func watching(_ connection: NSXPCConnection?) -> XPCProxyLifetime {
        guard let connection else { return .unbounded }
        associationLock.lock()
        defer { associationLock.unlock() }
        if let existing = objc_getAssociatedObject(connection, associationKey) as? XPCProxyLifetime {
            return existing
        }
        let lifetime = XPCProxyLifetime(watching: connection)
        objc_setAssociatedObject(connection, associationKey, lifetime, .OBJC_ASSOCIATION_RETAIN)
        return lifetime
    }

    private static let associationLock = NSLock()
    /// A stable, unique address for the association. One retained object, leaked on
    /// purpose: an associated-object key is compared by address and must never move
    /// or be reused for the life of the process.
    /// `nonisolated(unsafe)` because `UnsafeRawPointer` is not `Sendable` -- but this one is
    /// a `let` whose only use is its *address identity* as an associated-object key. Nothing
    /// ever dereferences it.
    nonisolated(unsafe) private static let associationKey: UnsafeRawPointer =
        UnsafeRawPointer(Unmanaged.passRetained(NSObject()).toOpaque())

    private var observed: [UInt64: @Sendable (any Error) -> Void] = [:]
    private var nextObservationKey: UInt64 = 0

    /// Test seam: how many withdrawable registrations are live right now. The leak
    /// this design closes is precisely "this number only ever grew", so a test can
    /// pin that it returns to zero when calls complete.
    public var observationCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return observed.count
    }
}

/// A withdrawable registration on an ``XPCProxyLifetime``.
///
/// Withdrawal happens on `cancel()` or when the observation is released,
/// whichever comes first -- so tying one to an object that dies when the call
/// completes (see ``XPCFailureObservationHost``) is what keeps a lifetime's
/// registry bounded by in-flight calls.
public final class XPCFailureObservation: @unchecked Sendable {
    private weak var lifetime: XPCProxyLifetime?
    private let key: UInt64

    fileprivate init(lifetime: XPCProxyLifetime?, key: UInt64) {
        self.lifetime = lifetime
        self.key = key
    }

    public func cancel() {
        lifetime?.withdraw(key)
        lifetime = nil
    }

    deinit { lifetime?.withdraw(key) }
}

/// Something that can keep failure observations alive until its call completes.
///
/// ``XPCCallResumption`` and ``XPCSyncOutcome`` conform: they hold the
/// observation strongly while the call is in flight and drop it on the first
/// resume -- dropping is withdrawal, via ``XPCFailureObservation``'s deinit.
public protocol XPCFailureObservationHost: AnyObject {
    func retainUntilFinished(_ observation: XPCFailureObservation)
}
