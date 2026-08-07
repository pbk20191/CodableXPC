#if canImport(Darwin)
import XCTest
@testable import XPCCodable

private struct Reading: Codable, Equatable {
    let sensor: String
    let value: Double
}

/// Reports what the box was actually holding when it arrived, which is the only way
/// to tell the native path from the JSON fallback -- both produce the same value.
private struct Arrival: Codable, Equatable {
    let heldNativeXPC: Bool
    let decoded: Reading
}

@objc private protocol Probe {
    func inspect(_ box: CodableBox, reply: @escaping (CodableBox?, (any Error)?) -> Void)
}

private final class ProbeService: NSObject, Probe {
    func inspect(_ box: CodableBox, reply: @escaping (CodableBox?, (any Error)?) -> Void) {
        do {
            // `payload` is nil exactly when the box is carrying an xpc_object_t,
            // because no public API can turn one into bytes.
            let arrival = Arrival(heldNativeXPC: box.payload == nil,
                                  decoded: try box.decode(Reading.self))
            reply(try CodableBox(arrival), nil)
        } catch {
            reply(nil, error)
        }
    }
}

private final class ProbeDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: Probe.self)
        c.exportedObject = ProbeService()
        c.resume()
        return true
    }
}

final class NativeXPCPathTests: XCTestCase {

    func testNSXPCUsesTheNativeXPCPathNotJSON() async throws {
        let delegate = ProbeDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: Probe.self)
        connection.resume()
        defer { connection.invalidate() }

        let reading = Reading(sensor: "thermistor", value: 21.5)
        let arrival: Arrival = try await withCheckedThrowingContinuation { continuation in
            let once = XPCOneShot()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                if once.claim() { continuation.resume(throwing: error) }
            } as? Probe
            do {
                try proxy?.inspect(CodableBox(reading)) { box, error in
                    guard once.claim() else { return }
                    if let error { continuation.resume(throwing: error); return }
                    do { continuation.resume(returning: try box!.decode(Arrival.self)) }
                    catch { continuation.resume(throwing: error) }
                }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }

        XCTAssertEqual(arrival.decoded, reading)
        XCTAssertTrue(arrival.heldNativeXPC,
                      "the box fell back to JSON bytes; the NSXPCCoder path was not taken")
    }

    func testKeyedArchivingStillFallsBackToBytes() throws {
        // NSKeyedArchiver has no encodeXPCObject:forKey:, so the same box must take
        // the bytes path. Both routes have to keep working.
        let reading = Reading(sensor: "thermistor", value: 21.5)
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: try CodableBox(reading), requiringSecureCoding: true)
        let box = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: CodableBox.self, from: data))
        XCTAssertNotNil(box.payload, "an archived box must arrive holding bytes")
        XCTAssertEqual(try box.decode(Reading.self), reading)
    }
}
#endif
