import XPC
import System
import XPCCompat

// `System.FileDescriptor` subscripts live in this separate target because
// `import System` forces an `LC_LOAD_DYLIB` on `/usr/lib/swift/libswiftSystem.dylib`,
// which first shipped in macOS 11 and is absent from every Swift back-deployment
// set. `@available` gates compilation, not the load command, so a consumer of
// `XPCCompat` that linked it would be killed by dyld on macOS 10.15 before any
// availability check could run. Keeping these members out of `XPCCompat` is what
// makes the 10.15 floor real.
//
// These extensions reach the wrapped `xpc_object_t` through the public
// `withUnsafeUnderlyingDictionary` / `withUnsafeUnderlyingArray` accessors, since
// the stored property itself is internal to `XPCCompat`.

@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
extension XPCCompat.Dictionary {

    /// Reads a file descriptor. The returned descriptor is a duplicate owned by the
    /// caller and must be closed.
    public subscript(key: String, as type: FileDescriptor.Type = FileDescriptor.self) -> FileDescriptor? {
        withUnsafeUnderlyingDictionary { underlying in
            let raw = xpc_dictionary_dup_fd(underlying, key)
            guard raw >= 0 else { return nil }
            return FileDescriptor(rawValue: raw)
        }
    }

    /// Reads or writes a file descriptor. The descriptor is duplicated on write.
    /// Assigning `nil` removes the key.
    public subscript(key: String) -> FileDescriptor? {
        get { self[key, as: FileDescriptor.self] }
        set {
            withUnsafeUnderlyingDictionary { underlying in
                guard let newValue else {
                    xpc_dictionary_set_value(underlying, key, nil)
                    return
                }
                xpc_dictionary_set_fd(underlying, key, newValue.rawValue)
            }
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

@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
extension XPCCompat.Array {

    /// Reads a file descriptor at `index`. The caller owns and must close it.
    public subscript(index: Int, as type: FileDescriptor.Type = FileDescriptor.self) -> FileDescriptor? {
        withUnsafeUnderlyingArray { underlying in
            guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
            let raw = xpc_array_dup_fd(underlying, index)
            guard raw >= 0 else { return nil }
            return FileDescriptor(rawValue: raw)
        }
    }

    /// Reads or writes a file descriptor at `index`.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps
    ///   rather than doing nothing: `a[0] = someOptionalDescriptor` is a crash when
    ///   the optional is empty.
    public subscript(index: Int) -> FileDescriptor? {
        get { self[index, as: FileDescriptor.self] }
        set {
            withUnsafeUnderlyingArray { underlying in
                guard let newValue else {
                    preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
                }
                precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
                xpc_array_set_fd(underlying, index, newValue.rawValue)
            }
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
