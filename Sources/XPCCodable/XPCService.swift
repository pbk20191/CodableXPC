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
/// **Cancellation does not reach the peer.** The generated calls are `async` but a
/// cancelled `Task` does not cancel an in-flight NSXPC call — the reply block is the
/// only thing that can resume the continuation.
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
/// `CheckedContinuation` twice traps, so generated code routes every resume through
/// one of these.
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


extension NSXPCConnection {
    @objc(remoteObjectProxyWithTimeout:errorHandler:)
    @NSManaged func remoteObjectProxy(with timeout: TimeInterval, errorHandler: @convention(block) @escaping (Error) -> Void) -> NSObjectProtocol
    
    @objc(remoteObjectProxyWithUserInfo:errorHandler:)
    @NSManaged func remoteObjectProxy(with userInfo: NSObjectProtocol?, errorHandler: @convention(block) @escaping (Error) -> Void) -> NSObjectProtocol
    @NSManaged weak var delegate: NSXPCConnectionDelegate?
    
//    +(void)_handoffCurrentReplyToQueue:(id)arg1 block:(/*^block*/id)arg2 ;
    
    func asdf() {
//        NSXPCConnection.trans
    }

}




@objc(NSXPCConnectionDelegate)
protocol NSXPCConnectionDelegate {
    @available(*, unavailable)
    @objc(connection:handleInvocation:isReply:)
    optional func connection(_ connection: NSXPCConnection, handleInvocation: NSInvocation, isReply: Bool)
    
    @objc(replacementObjectForXPCConnection:encoder:object:)
    optional func replacementObject(for: NSXPCConnection, encoder: NSXPCCoder, object: Any) -> Any?
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
