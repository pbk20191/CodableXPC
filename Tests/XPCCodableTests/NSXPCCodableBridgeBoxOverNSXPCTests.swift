#if canImport(Darwin)
import XCTest
@testable import XPCCodable

private struct Person: Codable, Equatable {
    let name: String
    let age: Int
}

/// The box is passed as a *direct* parameter, which is what lets this work with no
/// `setClasses(_:for:argumentIndex:ofReply:)` call anywhere: NSXPC allows classes
/// named in an `@objc` signature automatically. Nest a box inside a collection and
/// that stops being true.
@objc private protocol Aging {
    func birthday(_ person: NSXPCCodableBridgeBox, reply: @escaping (NSXPCCodableBridgeBox?, Error?) -> Void)
}

private final class AgingService: NSObject, Aging {
    func birthday(_ person: NSXPCCodableBridgeBox, reply: @escaping (NSXPCCodableBridgeBox?, Error?) -> Void) {
        do {
            let p = try person.decode(Person.self)
            reply(try NSXPCCodableBridgeBox(Person(name: p.name, age: p.age + 1)), nil)
        } catch {
            reply(nil, error)
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: Aging.self)
        connection.exportedObject = AgingService()
        connection.resume()
        return true
    }
}

/// Real NSXPC, one process: an anonymous listener dialled from the same binary.
/// No installed service, no second process, but a genuine `NSXPCConnection` and a
/// genuine `NSXPCDecoder` on the far side.
final class NSXPCCodableBridgeBoxOverNSXPCTests: XCTestCase {

    func testRoundTripsOverARealConnection() throws {
        let listener = NSXPCListener.anonymous()
        let delegate = ListenerDelegate()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: Aging.self)
        connection.resume()
        defer { connection.invalidate() }

        let replied = expectation(description: "reply arrives")
        var received: Person?
        var failure: Error?

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            failure = error
            replied.fulfill()
        } as? Aging
        let service = try XCTUnwrap(proxy)

        service.birthday(try NSXPCCodableBridgeBox(Person(name: "Ada", age: 36))) { box, error in
            defer { replied.fulfill() }
            if let error { failure = error; return }
            received = try? box?.decode(Person.self)
        }

        wait(for: [replied], timeout: 10)
        XCTAssertNil(failure, "connection failed: \(String(describing: failure))")
        XCTAssertEqual(received, Person(name: "Ada", age: 37))
    }
}
#endif
