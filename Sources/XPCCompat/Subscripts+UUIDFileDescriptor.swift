import XPC
import Foundation
import System

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

@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
extension XPCCompat.Dictionary {

    /// Reads a file descriptor. The returned descriptor is a duplicate owned by the
    /// caller and must be closed.
    public subscript(key: String, as type: FileDescriptor.Type = FileDescriptor.self) -> FileDescriptor? {
        let raw = xpc_dictionary_dup_fd(underlying, key)
        guard raw >= 0 else { return nil }
        return FileDescriptor(rawValue: raw)
    }

    /// Reads or writes a file descriptor. The descriptor is duplicated on write.
    /// Assigning `nil` removes the key.
    public subscript(key: String) -> FileDescriptor? {
        get { self[key, as: FileDescriptor.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_fd(underlying, key, newValue.rawValue)
        }
    }

    /// Reads a file descriptor, falling back to `defaultValue`.
    public subscript(
        key: String,
        as type: FileDescriptor.Type = FileDescriptor.self,
        default defaultValue: @autoclosure () -> FileDescriptor
    ) -> FileDescriptor {
        self[key, as: FileDescriptor.self] ?? defaultValue()
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

@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
extension XPCCompat.Array {

    /// Reads a file descriptor at `index`. The caller owns and must close it.
    public subscript(index: Int, as type: FileDescriptor.Type = FileDescriptor.self) -> FileDescriptor? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        let raw = xpc_array_dup_fd(underlying, index)
        guard raw >= 0 else { return nil }
        return FileDescriptor(rawValue: raw)
    }

    /// Reads or writes a file descriptor at `index`.
    public subscript(index: Int) -> FileDescriptor? {
        get { self[index, as: FileDescriptor.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_fd(underlying, index, newValue.rawValue)
        }
    }

    /// Reads a file descriptor at `index`, falling back to `defaultValue`.
    public subscript(
        index: Int,
        as type: FileDescriptor.Type = FileDescriptor.self,
        default defaultValue: @autoclosure () -> FileDescriptor
    ) -> FileDescriptor {
        self[index, as: FileDescriptor.self] ?? defaultValue()
    }
}
