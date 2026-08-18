#if canImport(Darwin)
import XCTest
import Dispatch
import XPC
@testable import CodableXPC

private struct Payload: Codable { let name: String; let blob: XPCNativeObject }

/// A large payload can cross without being copied, and the graph preserves that.
///
/// `xpc_data_create` takes a pointer and a length, so it copies — 12 ms for
/// 64 MiB on this machine, plus a second copy of the memory.
/// `xpc_data_create_with_dispatch_data` is public API and takes ownership of the
/// buffer instead: 0 ms, and `xpc_data_get_bytes_ptr` returns the original pages.
///
/// This module does not do that conversion for you. Swift `Data` cannot be
/// turned into a `dispatch_data_t` without either copying or promising that its
/// storage outlives the call, and `Data` makes no such promise — small values
/// live inline in the struct. A caller who has a `DispatchData` already knows its
/// lifetime, so the zero-copy object is theirs to build, and ``XPCNativeObject``
/// carries it the rest of the way.
final class ZeroCopyDataTests: XCTestCase {

    private func makePages(_ size: Int, fill: UInt8) throws -> UnsafeMutableRawPointer {
        let page = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        let region = try XCTUnwrap(page == MAP_FAILED ? nil : page)
        memset(region, Int32(fill), size)
        addTeardownBlock { munmap(region, size) }
        return region
    }

    func testTheGraphDoesNotCopyADispatchDataBackedBlob() throws {
        let size = 8 << 20
        let region = try makePages(size, fill: 0xCD)
        let data = DispatchData(bytesNoCopy: UnsafeRawBufferPointer(start: region, count: size),
                                deallocator: .custom(nil, {}))
        let blob = xpc_data_create_with_dispatch_data(data as __DispatchData)

        // Zero copy on the way in: the xpc object points at our pages.
        XCTAssertEqual(UnsafeRawPointer(try XCTUnwrap(xpc_data_get_bytes_ptr(blob))),
                       UnsafeRawPointer(region))

        let graph = try XPCEncoder().encode(Payload(name: "big", blob: XPCNativeObject(blob)))
        let back = try XPCDecoder().decode(Payload.self, from: graph)

        // …and still on the way out, so nothing in the coder materialised it.
        XCTAssertEqual(UnsafeRawPointer(try XCTUnwrap(xpc_data_get_bytes_ptr(back.blob.object))),
                       UnsafeRawPointer(region))
        XCTAssertEqual(xpc_data_get_length(back.blob.object), size)
        XCTAssertEqual(back.name, "big")
    }

    /// The contrast, so the difference is recorded rather than assumed: a `Data`
    /// field is copied, which is correct for a value type and is the reason the
    /// other path exists.
    func testAPlainDataFieldIsCopied() throws {
        let size = 1 << 20
        let region = try makePages(size, fill: 0xAB)
        struct Copied: Codable, Equatable { let blob: Data }

        let value = Copied(blob: Data(bytesNoCopy: region, count: size, deallocator: .none))
        let graph = try XPCEncoder().encode(value)

        let stored = try XCTUnwrap(xpc_dictionary_get_value(graph, "blob"))
        XCTAssertEqual(xpc_get_type(stored), XPC_TYPE_DATA)
        XCTAssertNotEqual(UnsafeRawPointer(try XCTUnwrap(xpc_data_get_bytes_ptr(stored))),
                          UnsafeRawPointer(region),
                          "a Data field is expected to be copied")
        XCTAssertEqual(try XPCDecoder().decode(Copied.self, from: graph), value)
    }
}
#endif
