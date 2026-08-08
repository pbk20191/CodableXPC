#if canImport(Darwin)
import XCTest
import XPC
import MachO
@testable import CodableXPC
import XPCDispatchDataBridge

/// `Data` is encoded by whichever of two copies is cheaper. Which one runs must
/// not be observable in the result.
final class DispatchDataBridgeTests: XCTestCase {

    private func plainPath(_ data: Data) -> xpc_object_t {
        data.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
    }

    private func bytes(_ object: xpc_object_t) -> Data {
        guard let pointer = xpc_data_get_bytes_ptr(object) else { return Data() }
        return Data(bytes: pointer, count: xpc_data_get_length(object))
    }

    /// The whole safety argument: losing the SPI costs speed and nothing else.
    func testBothPathsProduceIdenticalBytes() throws {
        for size in [0, 1, 64, 4 << 10, 64 << 10, 1 << 20, 4 << 20] {
            var value = Data(count: size)
            value.withUnsafeMutableBytes { raw in
                for i in 0..<size { raw[i] = UInt8((i &* 31) & 0xFF) }
            }

            let bridged = DispatchDataBridge.xpcData(for: value)
            let plain = plainPath(value)

            XCTAssertEqual(xpc_get_type(bridged), XPC_TYPE_DATA, "\(size)")
            XCTAssertEqual(xpc_data_get_length(bridged), size, "\(size)")
            XCTAssertEqual(bytes(bridged), value, "\(size) did not survive the bridge")
            XCTAssertEqual(bytes(bridged), bytes(plain), "\(size) differs between paths")
            XCTAssertTrue(xpc_equal(bridged, plain), "\(size) not xpc_equal")
        }
    }

    /// The substitution is real at size and skipped below it — Apple's own
    /// threshold, asked rather than guessed. Recorded so a change in it shows up
    /// here rather than as an unexplained slowdown.
    /// The substitution is real at size and skipped below it — Apple's threshold,
    /// asked rather than guessed. Pinned so a change in it surfaces here rather
    /// than as an unexplained slowdown.
    func testTheSubstitutionHappensOnlyWhereItPays() throws {
        try XCTSkipUnless(DispatchDataBridge.isAvailable,
                          "the private selectors are gone; everything falls back")

        XCTAssertNil(DispatchDataBridge.substituting(Data(count: 64)),
                     "a tiny Data should take the plain path")
        XCTAssertNil(DispatchDataBridge.substituting(Data(count: 4 << 10)),
                     "4 KiB is still below where it pays")
        XCTAssertNotNil(DispatchDataBridge.substituting(Data(count: 1 << 20)),
                        "a megabyte is what the substitution exists for")
    }

    /// The substituted object is +1 and has to be consumed. Declaring
    /// `_createDispatchData` as returning `NSData` rather than
    /// `Unmanaged<NSData>` compiles, runs, produces correct bytes — and leaks
    /// every buffer. Forty 8 MiB calls grew the footprint by 320.8 MiB that way.
    func testTheSubstitutionDoesNotLeak() throws {
        try XCTSkipUnless(DispatchDataBridge.isAvailable, "always falls back here")

        func footprintMiB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<Int32>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1024 / 1024 : -1
        }

        var blob = Data(count: 8 << 20)
        blob.withUnsafeMutableBytes { memset($0.baseAddress, 0x5A, $0.count) }

        _ = DispatchDataBridge.substituting(blob)   // warm, so the first call is not counted
        let before = footprintMiB()
        for _ in 0..<40 { autoreleasepool { _ = DispatchDataBridge.substituting(blob) } }
        let growth = footprintMiB() - before

        // Leaking would be 320 MiB. A generous ceiling still catches it.
        XCTAssertLessThan(growth, 64, "grew \(growth) MiB over 40 x 8 MiB — the +1 is not consumed")
    }

    /// Encoding a `Data` field goes through it, and comes back equal.
    func testDataFieldsStillRoundTrip() throws {
        struct Holder: Codable, Equatable { let small: Data; let large: Data }
        var large = Data(count: 2 << 20)
        large.withUnsafeMutableBytes { memset($0.baseAddress, 0x5A, $0.count) }

        let value = Holder(small: Data([1, 2, 3]), large: large)
        let graph = try XPCEncoder().encode(value)
        XCTAssertEqual(try XPCDecoder().decode(Holder.self, from: graph), value)
    }
}
#endif
