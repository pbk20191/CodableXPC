import XPC
import Foundation

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads a string. Returns `nil` if the key is absent or the value is not a string.
    ///
    /// Ill-formed UTF-8 is repaired with U+FFFD rather than returning `nil`, matching
    /// Apple's use of `String(cString:)`.
    public subscript(key: String, as type: String.Type = String.self) -> String? {
        guard let pointer = xpc_dictionary_get_string(underlying, key) else { return nil }
        return String(cString: pointer)
    }

    /// Reads or writes a string. Assigning `nil` removes the key.
    public subscript(key: String) -> String? {
        get { self[key, as: String.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_string(underlying, key, newValue)
        }
    }

    /// Reads binary data. Returns `nil` if the key is absent or the value is not data.
    public subscript(key: String, as type: Data.Type = Data.self) -> Data? {
        var length = 0
        let base = xpc_dictionary_get_data(underlying, key, &length)
        if base == nil && length == 0 {
            // Distinguish between "key not found" and "valid empty data"
            if let value = xpc_dictionary_get_value(underlying, key),
               xpc_get_type(value) == XPC_TYPE_DATA {
                return Data()
            }
            return nil
        }
        guard let base = base else { return nil }
        return Data(bytes: base, count: length)
    }

    /// Reads or writes binary data. Assigning `nil` removes the key.
    public subscript(key: String) -> Data? {
        get { self[key, as: Data.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            newValue.withUnsafeBytes { buffer in
                xpc_dictionary_set_data(underlying, key, buffer.baseAddress, buffer.count)
            }
        }
    }

    /// Calls `body` with the raw bytes stored under `key`, without copying.
    ///
    /// Returns `nil` without calling `body` when the key is absent or is not data.
    /// This replaces Apple's macOS 27 `RawSpan` subscript, which cannot be backported.
    public func withUnsafeBytes<ReturnType>(
        forKey key: String,
        _ body: (UnsafeRawBufferPointer) throws -> ReturnType
    ) rethrows -> ReturnType? {
        var length = 0
        let base = xpc_dictionary_get_data(underlying, key, &length)
        if base == nil && length == 0 {
            // Distinguish between "key not found" and "valid empty data"
            if let value = xpc_dictionary_get_value(underlying, key),
               xpc_get_type(value) == XPC_TYPE_DATA {
                return try body(UnsafeRawBufferPointer(start: nil, count: 0))
            }
            return nil
        }
        guard let base = base else { return nil }
        return try body(UnsafeRawBufferPointer(start: base, count: length))
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads a string at `index`.
    public subscript(index: Int, as type: String.Type = String.self) -> String? {
        guard index >= 0, index < xpc_array_get_count(underlying),
              let pointer = xpc_array_get_string(underlying, index) else { return nil }
        return String(cString: pointer)
    }

    /// Reads or writes a string at `index`.
    public subscript(index: Int) -> String? {
        get { self[index, as: String.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_string(underlying, index, newValue)
        }
    }

    /// Reads binary data at `index`.
    public subscript(index: Int, as type: Data.Type = Data.self) -> Data? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        var length = 0
        let base = xpc_array_get_data(underlying, index, &length)
        if base == nil && length == 0 {
            // Distinguish between "index out of range" and "valid empty data"
            let value = xpc_array_get_value(underlying, index)
            if xpc_get_type(value) == XPC_TYPE_DATA {
                return Data()
            }
            return nil
        }
        guard let base = base else { return nil }
        return Data(bytes: base, count: length)
    }

    /// Reads or writes binary data at `index`.
    public subscript(index: Int) -> Data? {
        get { self[index, as: Data.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            newValue.withUnsafeBytes { buffer in
                xpc_array_set_data(underlying, index, buffer.baseAddress, buffer.count)
            }
        }
    }
}
