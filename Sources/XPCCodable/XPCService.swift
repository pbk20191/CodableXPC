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
}


@objc(NSXPCConnectionDelegate)
protocol NSXPCConnectionDelegate {
    @available(*, unavailable)
    @objc(connection:handleInvocation:isReply:)
    optional func connection(_ connection: NSXPCConnection, handleInvocation: NSInvocation, isReply: Bool)
    
    @objc(replacementObjectForXPCConnection:encoder:object:)
    optional func replacementObject(for: NSXPCConnection, encoder: NSXPCCoder, object: Any) -> Any?
}
