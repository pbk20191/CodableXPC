import XPC
import Foundation

// This file must not `import System`. See the `XPCCompatSystem` target — the
// `System.FileDescriptor` subscripts live there so that `XPCCompat` itself
// never links `libswiftSystem.dylib` (macOS 11+, not back-deployable), which
// would abort a consumer at dyld time on macOS 10.15.

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads a UUID as a raw 16-byte tuple.
    public subscript(key: String, as type: uuid_t.Type = uuid_t.self) -> uuid_t? {
        guard let bytes = xpc_dictionary_get_uuid(underlying, key) else { return nil }
        var result: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        Swift.withUnsafeMutableBytes(of: &result) { destination in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: 16))
        }
        return result
    }

    /// Reads or writes a UUID. Assigning `nil` removes the key.
    public subscript(key: String) -> uuid_t? {
        get { self[key, as: uuid_t.self] }
        set {
            guard var newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            Swift.withUnsafeBytes(of: &newValue) { source in
                xpc_dictionary_set_uuid(
                    underlying, key,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
    }

    /// Reads a UUID, falling back to `defaultValue`.
    public subscript(
        key: String,
        as type: uuid_t.Type = uuid_t.self,
        default defaultValue: @autoclosure () -> uuid_t
    ) -> uuid_t {
        self[key, as: uuid_t.self] ?? defaultValue()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads a UUID at `index`.
    public subscript(index: Int, as type: uuid_t.Type = uuid_t.self) -> uuid_t? {
        guard index >= 0, index < xpc_array_get_count(underlying),
              let bytes = xpc_array_get_uuid(underlying, index) else { return nil }
        var result: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        Swift.withUnsafeMutableBytes(of: &result) { destination in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: 16))
        }
        return result
    }

    /// Reads or writes a UUID at `index`.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps
    ///   rather than doing nothing: `a[0] = someOptionalUUID` is a crash when the
    ///   optional is empty.
    public subscript(index: Int) -> uuid_t? {
        get { self[index, as: uuid_t.self] }
        set {
            guard var newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            Swift.withUnsafeBytes(of: &newValue) { source in
                xpc_array_set_uuid(
                    underlying, index,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
    }

    /// Reads a UUID at `index`, falling back to `defaultValue`.
    public subscript(
        index: Int,
        as type: uuid_t.Type = uuid_t.self,
        default defaultValue: @autoclosure () -> uuid_t
    ) -> uuid_t {
        self[index, as: uuid_t.self] ?? defaultValue()
    }
}
