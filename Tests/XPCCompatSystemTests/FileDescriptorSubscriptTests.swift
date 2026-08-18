import XCTest
import XPC
import Foundation
import System
import XPCCompat
@testable import XPCCompatSystem

@available(macOS 11, iOS 14, *)
final class FileDescriptorSubscriptTests: XCTestCase {

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

    func testFileDescriptorWrongTypeIsNil() {
        let raw = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(raw, "n", 1)
        XCTAssertNil(XPCCompat.Dictionary(raw)["n", as: FileDescriptor.self])
    }

    func testFileDescriptorAssigningNilRemovesKey() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        var d = XPCCompat.Dictionary()
        d["fd"] = FileDescriptor(rawValue: fds[0])
        XCTAssertEqual(d.count, 1)
        d["fd"] = nil as FileDescriptor?
        XCTAssertEqual(d.count, 0)
    }

    // The descriptor the getter hands back is a duplicate: it is a different
    // number from the one written, and closing it leaves the original usable.
    func testGetterReturnsADuplicateTheCallerOwns() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        var d = XPCCompat.Dictionary()
        d["fd"] = FileDescriptor(rawValue: fds[0])

        let received = try XCTUnwrap(d["fd", as: FileDescriptor.self])
        XCTAssertNotEqual(received.rawValue, fds[0], "the getter must return a dup, not the original")
        try received.close()

        // The original is still open: writing then reading through it works.
        let payload: [UInt8] = [7]
        XCTAssertEqual(payload.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }, 1)
        var readBack: UInt8 = 0
        XCTAssertEqual(read(fds[0], &readBack, 1), 1)
        XCTAssertEqual(readBack, 7)
    }

    func testArrayFileDescriptorRoundTrip() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_int64_create(0))
        var a = XPCCompat.Array(raw)
        a[0] = FileDescriptor(rawValue: fds[0])

        let received = try XCTUnwrap(a[0, as: FileDescriptor.self])
        XCTAssertNotEqual(received.rawValue, fds[0])
        try received.close()
    }

    func testArrayFileDescriptorWrongTypeIsNil() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_int64_create(1))
        XCTAssertNil(XPCCompat.Array(raw)[0, as: FileDescriptor.self])
    }

    func testArrayFileDescriptorOutOfRangeIsNil() {
        let a = XPCCompat.Array()
        XCTAssertNil(a[0, as: FileDescriptor.self])
        XCTAssertNil(a[-1, as: FileDescriptor.self])
    }

    func testArrayFileDescriptorDefaultOnWrongType() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_int64_create(1))
        let fallback = FileDescriptor(rawValue: fds[0])
        XCTAssertEqual(
            XPCCompat.Array(raw)[0, as: FileDescriptor.self, default: fallback].rawValue,
            fds[0]
        )
    }
}
