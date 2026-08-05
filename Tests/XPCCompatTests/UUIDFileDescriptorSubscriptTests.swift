import XCTest
import XPC
import Foundation
import System
@testable import XPCCompat

final class UUIDFileDescriptorSubscriptTests: XCTestCase {

    private let sample: uuid_t = (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)

    func testUUIDRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["id"] = sample
        let read = d["id", as: uuid_t.self]
        XCTAssertNotNil(read)
        XCTAssertTrue(withUnsafeBytes(of: sample) { a in
            withUnsafeBytes(of: read!) { b in a.elementsEqual(b) }
        })
    }

    func testUUIDWrongTypeIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        XCTAssertNil(XPCCompat.Dictionary(raw)["n", as: uuid_t.self])
    }

    func testUUIDDefaultOnMissing() {
        let d = XPCCompat.Dictionary()
        let fallback: uuid_t = (9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9)
        let value = d["absent", as: uuid_t.self, default: fallback]
        XCTAssertEqual(value.0, 9)
    }

    func testUUIDAssigningNilRemovesKey() {
        var d = XPCCompat.Dictionary()
        d["id"] = sample
        d["id"] = nil as uuid_t?
        XCTAssertEqual(d.count, 0)
    }

    @available(macOS 11, iOS 14, *)
    func testFileDescriptorRoundTrip() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        var d = XPCCompat.Dictionary()
        d["fd"] = FileDescriptor(rawValue: fds[0])

        let received = d["fd", as: FileDescriptor.self]
        XCTAssertNotNil(received)
        // xpc_fd_create dups the descriptor, so the received one is a different number
        // referring to the same pipe. Close it to avoid leaking.
        if let received { try? received.close() }
    }

    @available(macOS 11, iOS 14, *)
    func testFileDescriptorWrongTypeIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        XCTAssertNil(XPCCompat.Dictionary(raw)["n", as: FileDescriptor.self])
    }
}
