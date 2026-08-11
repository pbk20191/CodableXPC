#if NSXPCPrivateAPI
import XCTest
@testable import XPCCodable

/// Whether boxing can move out of the generated shim signature and into the coder.
///
/// `@XPCService` currently names `NSXPCCodableBridgeBox` in the `@objc` shim it generates, and
/// generates the boxing and unboxing around it. The alternative is a shim that takes `id` and a
/// coder that substitutes: the encoder's delegate hook boxes on the way out, and the box hands
/// back the decoded value on the way in.
///
/// **Nothing here changes the shipping design.** These tests use their own carrier
/// (``ProbeBox``) rather than `NSXPCCodableBridgeBox`, on purpose: giving the real box an
/// `awakeAfter(using:)` that returns its payload would break every existing adapter, which
/// unboxes explicitly and casts to the box type. What is being established is that the
/// mechanism works, so the macro change can be decided on evidence instead of on a guess.
///
///     swift test --traits NSXPCPrivateAPI --filter CoderLevelBoxing
@available(macOS 10.13, *)
final class CoderLevelBoxingTests: XCTestCase {

    /// A plain Swift `Codable` struct crosses an `id`-typed shim in both directions, and
    /// neither side ever sees a box.
    ///
    /// This is the whole proposition in one test. If it holds, a generated shim never has to
    /// name a box type, and a `Codable` value nested anywhere the macro did not enumerate
    /// crosses anyway.
    func testASwiftStructCrossesAnIDShimAndNeitherSideSeesABox() throws {
        let link = try Link()
        defer { link.tearDown() }

        let proxy = try XCTUnwrap(link.proxy)
        let reply = Outcome()
        proxy.take(Person(name: "ada", age: 36)) { value, _ in reply.set(value) }

        XCTAssertTrue(waitFor { reply.value != nil }, "no reply arrived")

        // Outbound: the service was handed the struct, not the carrier.
        XCTAssertEqual(link.service.seen as? Person, Person(name: "ada", age: 36))
        XCTAssertFalse(link.service.seen is ProbeBox,
                       "the service saw the carrier; decode-side substitution did not run")

        // Inbound: the reply came back the same way.
        XCTAssertEqual(reply.value as? Person, Person(name: "replied", age: 2))
        XCTAssertFalse(reply.value is ProbeBox)
    }

    /// A Swift value reaches the hook as `__SwiftValue`, and casts back.
    ///
    /// The one fact the encode half rests on. A Swift struct handed to an `@objc` method as
    /// `Any` is bridged to an opaque `__SwiftValue`, so a hook that switched on Objective-C
    /// class would see nothing useful -- but `as?` goes through the bridge, so the hook can ask
    /// "is this the thing I am supposed to box" and get a straight answer.
    func testTheHookSeesSwiftValueAndCanCastItBack() throws {
        let link = try Link()
        defer { link.tearDown() }

        let proxy = try XCTUnwrap(link.proxy)
        let reply = Outcome()
        proxy.take(Person(name: "x", age: 1)) { value, _ in reply.set(value) }
        XCTAssertTrue(waitFor { reply.value != nil })

        let firstSeen = try XCTUnwrap(link.clientHook.classNamesSeen.first)
        XCTAssertEqual(firstSeen, "__SwiftValue",
                       "a bridged Swift struct no longer arrives as __SwiftValue")
        XCTAssertTrue(link.clientHook.castSucceeded,
                      "the hook could not cast the bridged value back to its Swift type")
    }

    /// The hook fires again for objects encoded *inside* a replacement.
    ///
    /// Measured, and it is the trap in this design: substituting a `Person` with a carrier makes
    /// the carrier encode its own payload, and that payload arrives at the hook too -- as
    /// `__NSSwiftData`. An implementation that boxed indiscriminately would box the box's
    /// insides, forever. Boxing only what a marker marks is not a convenience here, it is what
    /// makes the recursion terminate.
    func testTheHookIsCalledRecursivelyForAReplacementsOwnContents() throws {
        let link = try Link()
        defer { link.tearDown() }

        let proxy = try XCTUnwrap(link.proxy)
        let reply = Outcome()
        proxy.take(Person(name: "y", age: 1)) { value, _ in reply.set(value) }
        XCTAssertTrue(waitFor { reply.value != nil })

        let seen = link.clientHook.classNamesSeen
        XCTAssertGreaterThan(seen.count, 1,
                             "expected the hook to see the carrier's payload as well: \(seen)")
        XCTAssertTrue(seen.contains { $0.contains("Data") },
                      "the carrier's payload never reached the hook: \(seen)")
    }

    /// The decode half needs **no private API**.
    ///
    /// `awakeAfter(using:)` is `NSObject`, fully public: `NSCoder` asks a freshly decoded object
    /// for a replacement and uses what it returns. So only the *encode* direction depends on
    /// `NSXPCConnection.delegate` -- which is worth knowing, because it bounds how much of this
    /// design is exposed to a private symbol going away.
    func testUnboxingUsesOnlyPublicAPI() throws {
        let box = ProbeBox(Person(name: "offline", age: 9))
        let data = try NSKeyedArchiver.archivedData(withRootObject: try XCTUnwrap(box),
                                                   requiringSecureCoding: true)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        // No connection, no delegate, no NSXPC at all -- and the value still comes back.
        let decoded = unarchiver.decodeObject(of: [ProbeBox.self, NSData.self],
                                              forKey: NSKeyedArchiveRootObjectKey)
        XCTAssertEqual(decoded as? Person, Person(name: "offline", age: 9),
                       "awakeAfter(using:) did not substitute outside NSXPC")
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

// MARK: - fixtures

private struct Person: Codable, Hashable {
    let name: String
    let age: Int
}

/// A carrier, deliberately **not** `NSXPCCodableBridgeBox`.
///
/// The real box must not grow an `awakeAfter(using:)`: every generated adapter today receives
/// the box and unboxes it explicitly, so a box that substituted itself for its payload during
/// decode would make those casts fail. This one exists so the mechanism can be measured without
/// changing what ships.
@objc(CXPCProbeBox)
private final class ProbeBox: NSObject, NSSecureCoding {

    let payload: Data

    init?(_ value: some Encodable) {
        guard let payload = try? JSONEncoder().encode(value) else { return nil }
        self.payload = payload
    }

    static var supportsSecureCoding: Bool { true }

    func encode(with coder: NSCoder) {
        coder.encode(payload as NSData, forKey: "p")
    }

    init?(coder: NSCoder) {
        guard let data = coder.decodeObject(of: NSData.self, forKey: "p") else { return nil }
        payload = data as Data
    }

    /// The decode-side substitution, and the reason this design is symmetric without a second
    /// private hook. `NSCoder` calls this on the freshly decoded object and uses the result.
    ///
    /// Returning `self` on failure rather than nil: nil from `awakeAfter(using:)` means "the
    /// object is gone", which would surface at the call site as a missing argument rather than
    /// as a decode error.
    override func awakeAfter(using coder: NSCoder) -> Any? {
        (try? JSONDecoder().decode(Person.self, from: payload)) ?? self
    }
}

/// `Any`, i.e. `id` -- the signature the coder-level design would let the macro generate. The
/// selector is identical to the one a box-typed parameter produces, which is what makes the two
/// designs wire-compatible.
@objc private protocol BoxlessService {
    func take(_ thing: Any, reply: @escaping (Any?, Error?) -> Void)
}

private final class ServiceImpl: NSObject, BoxlessService, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: Any?
    var seen: Any? { lock.withLock { _seen } }

    func take(_ thing: Any, reply: @escaping (Any?, Error?) -> Void) {
        lock.withLock { _seen = thing }
        reply(Person(name: "replied", age: 2), nil)
    }
}

/// Boxes what it recognises and records everything it was shown.
private final class BoxingHook: NSObject, NSXPCConnectionPrivateDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _classNames: [String] = []
    private var _cast = false

    var classNamesSeen: [String] { lock.withLock { _classNames } }
    var castSucceeded: Bool { lock.withLock { _cast } }

    func replacementObject(
        for connection: NSXPCConnection, encoder: NSXPCCoder, object: Any
    ) -> Any? {
        lock.withLock { _classNames.append("\(type(of: object))") }
        // Only what is recognised. See the recursion test: boxing anything at all would box the
        // carrier's own payload and never terminate.
        guard let person = object as? Person, let box = ProbeBox(person) else { return object }
        lock.withLock { _cast = true }
        return box
    }
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Any?
    var value: Any? { lock.withLock { _value } }
    func set(_ value: Any?) { lock.withLock { _value = value } }
}

private final class Link: NSObject, NSXPCListenerDelegate, @unchecked Sendable {

    let listener = NSXPCListener.anonymous()
    let connection: NSXPCConnection
    let service = ServiceImpl()
    let clientHook = BoxingHook()
    let serverHook = BoxingHook()
    private var serverConnection: NSXPCConnection?

    var proxy: BoxlessService? {
        connection.remoteObjectProxyWithErrorHandler { _ in } as? BoxlessService
    }

    /// An `id` parameter needs an allow-list on both the argument and the reply, or NSXPC
    /// refuses the class it is handed. This is the one piece of bookkeeping the design does not
    /// remove -- the macro already generates it.
    private static func interface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: BoxlessService.self)
        // `NSSet(array:) as! Set<AnyHashable>`, which is how the macro spells it too: a
        // Swift set literal of metatypes does not typecheck, because `AnyClass` is not
        // `Hashable`.
        let allowed = NSSet(array: [ProbeBox.self, NSData.self, NSString.self]) as! Set<AnyHashable>
        let selector = #selector(BoxlessService.take(_:reply:))
        interface.setClasses(allowed, for: selector, argumentIndex: 0, ofReply: false)
        interface.setClasses(allowed, for: selector, argumentIndex: 0, ofReply: true)
        return interface
    }

    override init() {
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        super.init()
        listener.delegate = self
        listener.resume()
        connection.remoteObjectInterface = Self.interface()
        connection.delegate = clientHook
        connection.resume()
    }

    convenience init(_ unused: Void = ()) throws { self.init() }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection new: NSXPCConnection) -> Bool {
        new.exportedInterface = Self.interface()
        new.exportedObject = service
        new.delegate = serverHook
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
