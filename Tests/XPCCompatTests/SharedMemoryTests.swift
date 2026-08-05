import XCTest
import XPC
@testable import XPCCompat

final class SharedMemoryTests: XCTestCase {

    // init(byteCount:) allocates a region the caller must be able to fill in.
    // withUnsafeMutableBytes is the only route to it, `owned` being private.
    func testWithUnsafeMutableBytesWritesAndReadsBack() throws {
        let memory = try XCTUnwrap(XPCCompat.SharedMemory(byteCount: 4096))

        let written = memory.withUnsafeMutableBytes { buffer -> Int in
            XCTAssertEqual(buffer.count, 4096)
            for index in 0..<16 {
                buffer[index] = UInt8(index &* 3)
            }
            return buffer.count
        }
        XCTAssertEqual(written, 4096, "body must run for an owning instance")

        let readBack = memory.withUnsafeMutableBytes { buffer in
            (0..<16).map { buffer[$0] }
        }
        XCTAssertEqual(readBack, (0..<16).map { UInt8($0 * 3) })
    }

    // A wrapped instance owns nothing, so there is no region to hand out.
    func testWithUnsafeMutableBytesReturnsNilForWrappedInstance() throws {
        let owner = try XCTUnwrap(XPCCompat.SharedMemory(byteCount: 4096))
        let wrapped = XPCCompat.SharedMemory(owner.underlying)

        var bodyRan = false
        let result = wrapped.withUnsafeMutableBytes { _ -> Int in
            bodyRan = true
            return 1
        }
        XCTAssertNil(result)
        XCTAssertFalse(bodyRan, "body must not be called for a non-owning instance")
    }

    func testWithUnsafeMutableBytesRethrows() throws {
        struct Boom: Error {}
        let memory = try XCTUnwrap(XPCCompat.SharedMemory(byteCount: 64))
        XCTAssertThrowsError(try memory.withUnsafeMutableBytes { _ in throw Boom() })
    }

    func testZeroByteCountIsNil() {
        XCTAssertNil(XPCCompat.SharedMemory(byteCount: 0))
        XCTAssertNil(XPCCompat.SharedMemory(byteCount: -1))
    }

    // Hashable, for consistency with Dictionary, Array and Endpoint. Structural,
    // via xpc_hash, so it must agree with the xpc_equal-based ==.
    func testHashingAgreesWithEquality() throws {
        let owner = try XCTUnwrap(XPCCompat.SharedMemory(byteCount: 4096))
        let wrapped = XPCCompat.SharedMemory(owner.underlying)

        XCTAssertEqual(owner, wrapped)
        XCTAssertEqual(owner.hashValue, wrapped.hashValue)

        var set: Swift.Set<XPCCompat.SharedMemory> = []
        set.insert(owner)
        set.insert(wrapped)
        XCTAssertEqual(set.count, 1, "equal instances must collapse in a Set")
    }
}
