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

    // MARK: - dispatchData(_:)

    private func allBytes(_ value: DispatchData) -> Data {
        var out = Data(count: value.count)
        let copied: Int = out.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return value.copyBytes(to: UnsafeMutableBufferPointer(start: base, count: value.count),
                                   count: value.count)
        }
        XCTAssertEqual(copied, value.count)
        return out
    }

    /// Whatever the object is, the bytes come back. This is the only guarantee the
    /// three paths -- already dispatch data, the SPI substitution, the plain copy --
    /// share, and the only one a caller may depend on.
    func testDispatchDataPreservesBytesForEveryObjectShape() {
        var shapes: [(String, NSData)] = [
            ("empty", NSData()),
            ("inline", Data([1, 2, 3]) as NSData),
            ("swift 64 KiB", Data(repeating: 0x5A, count: 64 << 10) as NSData),
            ("swift 1 MiB", Data(repeating: 0x5A, count: 1 << 20) as NSData),
        ]
        let mutable = NSMutableData(length: 1 << 20)!
        memset(mutable.mutableBytes, 0xAA, mutable.length)
        shapes.append(("NSMutableData 1 MiB", mutable))
        shapes.append(("dispatch, flat", dispatchBacked(repeating: 0x11, count: 4096)))
        var joined = dispatchData(repeating: 0x22, count: 8)
        joined.append(dispatchData(repeating: 0x33, count: 8))
        shapes.append(("dispatch, concatenated", (joined as AnyObject) as! NSData))

        for (name, object) in shapes {
            let result = DispatchDataBridge.dispatchData(object)
            XCTAssertEqual(result.count, object.length, name)
            XCTAssertEqual(allBytes(result), object as Data, name)
        }
    }

    /// An object that already *is* a dispatch data is returned, not rebuilt. The
    /// working tree asked a private selector and then force-cast on the answer --
    /// a cast the compiler said "always fails" -- where the runtime's own answer
    /// does the job and cannot go missing.
    func testDispatchDataDoesNotRebuildSomethingThatAlreadyIsOne() {
        let original = dispatchData(repeating: 0x7E, count: 4096)
        let asNSData = (original as AnyObject) as! NSData

        let result = DispatchDataBridge.dispatchData(asNSData)

        XCTAssertTrue((result as AnyObject) === asNSData,
                      "a dispatch data should come back as itself, not as a copy")
    }

    /// The result must not be a view onto a buffer someone else can still write to.
    /// It is a copy on every path here, and mutating the source afterwards proves it.
    func testDispatchDataDoesNotAliasAMutableSource() {
        for size in [4 << 10, 1 << 20] {
            let source = NSMutableData(length: size)!
            memset(source.mutableBytes, 0xAA, size)

            let result = DispatchDataBridge.dispatchData(source)
            let snapshot = allBytes(result)
            memset(source.mutableBytes, 0xBB, size)

            XCTAssertEqual(allBytes(result), snapshot,
                           "\(size): the result changed when the source was written to")
            XCTAssertEqual(snapshot.first, 0xAA, "\(size)")
        }
    }

    /// `isAvailable` has to cover every selector this type sends, because
    /// `@NSManaged` sends them without asking. If a selector were sent from outside
    /// that gate, losing it under an OS update would be an unrecognised-selector
    /// crash rather than the documented fallback.
    func testAvailabilityCoversEverySelectorTheTypeSends() {
        let probe = NSData()
        let sent = ["_canReplaceWithDispatchDataForXPCCoder", "_createDispatchData"]
        let covered = sent.allSatisfy { probe.responds(to: NSSelectorFromString($0)) }
        XCTAssertEqual(DispatchDataBridge.isAvailable, covered,
                       "isAvailable must be exactly 'every selector sent is present'")
    }

    private func dispatchData(repeating byte: UInt8, count: Int) -> DispatchData {
        let bytes = [UInt8](repeating: byte, count: count)
        return bytes.withUnsafeBytes { DispatchData(bytes: $0) }
    }

    private func dispatchBacked(repeating byte: UInt8, count: Int) -> NSData {
        (dispatchData(repeating: byte, count: count) as AnyObject) as! NSData
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
