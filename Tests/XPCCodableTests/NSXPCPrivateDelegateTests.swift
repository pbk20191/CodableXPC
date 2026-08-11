#if NSXPCPrivateAPI
import XCTest
@testable import XPCCodable

/// What `NSXPCConnection`'s private delegate hook actually does.
///
/// These exist because the hook is the whole premise of moving `@XPCService`'s boxing out of
/// the generated shim signature and into the coder. It is private API, so nothing about it is
/// documented and nothing about it is guaranteed; the only responsible way to build on it is to
/// pin what was observed, on a real connection, and find out loudly when an OS changes it.
///
/// The suite runs only with the `NSXPCPrivateAPI` trait:
///
///     swift test --traits NSXPCPrivateAPI --filter NSXPCPrivateDelegate
@available(macOS 10.13, *)
final class NSXPCPrivateDelegateTests: XCTestCase {

    /// The hook fires on the **sending** side, and what it returns is what the peer decodes.
    ///
    /// This is the one fact the coder-level design needs. If substitution did not cross, the
    /// generated shim would still have to name the box in its signature and the whole idea
    /// would be pointless.
    func testASubstitutedArgumentIsWhatThePeerReceives() throws {
        let link = try Link()
        defer { link.tearDown() }

        link.clientRecorder.substitute = { object in
            (object as? String) == "original" ? NSString(string: "substituted") : object
        }

        let proxy = try XCTUnwrap(link.proxy)
        proxy.send(NSString(string: "original")) { _, _ in }

        // Poll rather than block on a semaphore: a hook that stops firing must fail this
        // test, not wedge the suite.
        XCTAssertTrue(waitFor { link.service.lastReceived != nil },
                      "the peer never received anything")
        XCTAssertEqual(link.service.lastReceived as? String, "substituted",
                       "the substitution did not cross")
        XCTAssertTrue(link.clientRecorder.sawEncode,
                      "the hook was never consulted on the sending side")
    }

    /// It fires for the **reply** as well, from the replying side.
    ///
    /// Which is what makes the design symmetric: a return value could be boxed by the coder
    /// too, rather than by generated code on the service.
    func testTheHookAlsoFiresForAReplyValue() throws {
        let link = try Link()
        defer { link.tearDown() }

        link.serverRecorder.substitute = { object in
            (object as? String) == "ack" ? NSString(string: "server-substituted") : object
        }

        let reply = XPCSyncOutcome<String>()
        let proxy = try XCTUnwrap(link.proxy)
        proxy.send(NSString(string: "x")) { value, _ in
            reply.set(.success(value.map { "\($0)" } ?? "nil"))
        }

        XCTAssertTrue(waitFor { (try? reply.take()) != nil }, "no reply arrived")
        XCTAssertEqual(try reply.take(), "server-substituted",
                       "the reply was not substituted on the replying side")
        XCTAssertTrue(link.serverRecorder.sawEncode,
                      "the hook was never consulted for the reply")
    }

    /// Returning the object unchanged is how "leave this alone" is spelled.
    ///
    /// **The negative half of this cannot be tested here.** Returning `nil` raises
    /// `NSInvalidArgumentException` from `-[NSXPCEncoder _replaceObject:]` -- *"The replacement
    /// object must not be nil"* -- which is an Objective-C exception thrown through Swift
    /// frames, so it terminates the process rather than being catchable. It was observed once,
    /// by writing the obvious `return nil` and watching the crash, and that observation is
    /// recorded in `NSXPCPrivateAPI.swift`. What is checked here is that the *correct* spelling
    /// works, which is what a regression would break.
    func testReturningTheObjectUnchangedLeavesItAlone() throws {
        let link = try Link()
        defer { link.tearDown() }

        link.clientRecorder.substitute = { $0 }

        let proxy = try XCTUnwrap(link.proxy)
        proxy.send(NSString(string: "untouched")) { _, _ in }

        XCTAssertTrue(waitFor { link.service.lastReceived != nil })
        XCTAssertEqual(link.service.lastReceived as? String, "untouched")
    }

    /// `setDelegate:` sticks, and `delegate` reads it back.
    ///
    /// Cheap, and it is the binding everything above rests on: a `@NSManaged` accessor that
    /// silently did nothing would make every other test here pass for the wrong reason -- the
    /// hook would never fire and `sawEncode` would be false, so in fact they would fail. This
    /// says which of the two broke.
    func testThePrivateDelegateAccessorRoundTrips() throws {
        let link = try Link()
        defer { link.tearDown() }
        XCTAssertTrue(link.connection.delegate === link.clientRecorder)
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(2_000)
        }
        return condition()
    }
}

// MARK: - the shim, deliberately taking `id`

/// `Any` rather than a box type, because that is the signature the coder-level design would
/// let `@XPCService` generate. `Any` bridges to `id`, so the selector is identical to the one a
/// box-typed parameter produces -- which is why the two designs are wire-compatible.
@objc private protocol PrivateHookEcho {
    func send(_ thing: Any, reply: @escaping (Any?, Error?) -> Void)
}

private final class EchoService: NSObject, PrivateHookEcho, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastReceived: Any?
    var lastReceived: Any? { lock.withLock { _lastReceived } }

    func send(_ thing: Any, reply: @escaping (Any?, Error?) -> Void) {
        lock.withLock { _lastReceived = thing }
        reply(NSString(string: "ack"), nil)
    }
}

/// Records that the hook ran and optionally substitutes.
private final class Recorder: NSObject, NSXPCConnectionPrivateDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _sawEncode = false
    var sawEncode: Bool { lock.withLock { _sawEncode } }

    /// Must return an object. See the type documentation on `NSXPCConnectionPrivateDelegate`.
    var substitute: ((Any) -> Any)?

    func replacementObject(
        for connection: NSXPCConnection, encoder: NSXPCCoder, object: Any
    ) -> Any? {
        lock.withLock { _sawEncode = true }
        return substitute?(object) ?? object
    }
}

/// An anonymous NSXPC listener dialled from this same process, with a private delegate on each
/// end.
private final class Link: NSObject, NSXPCListenerDelegate, @unchecked Sendable {

    let listener = NSXPCListener.anonymous()
    let connection: NSXPCConnection
    let service = EchoService()
    let clientRecorder = Recorder()
    let serverRecorder = Recorder()
    private var serverConnection: NSXPCConnection?

    var proxy: PrivateHookEcho? {
        connection.remoteObjectProxyWithErrorHandler { _ in } as? PrivateHookEcho
    }

    override init() {
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        super.init()
        listener.delegate = self
        listener.resume()
        connection.remoteObjectInterface = NSXPCInterface(with: PrivateHookEcho.self)
        connection.delegate = clientRecorder
        connection.resume()
    }

    convenience init(_ unused: Void = ()) throws { self.init() }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection new: NSXPCConnection) -> Bool {
        new.exportedInterface = NSXPCInterface(with: PrivateHookEcho.self)
        new.exportedObject = service
        new.delegate = serverRecorder
        serverConnection = new
        new.resume()
        return true
    }

    func tearDown() {
        connection.invalidate()
        serverConnection?.invalidate()
        listener.invalidate()
    }
}
#endif
