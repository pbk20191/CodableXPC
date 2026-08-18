import XPC
import Foundation

/// Whether a raw value that `xpc_*_get_data` refused to hand bytes for is nonetheless
/// an empty `Data`.
///
/// `xpc_dictionary_get_data` and `xpc_array_get_data` both signal "no bytes" by
/// returning a null base pointer with a length of 0, and they do that for two
/// unrelated situations: there is nothing readable there (missing key, or a value of
/// some other type), and there is a real but empty `Data`. The out-parameters cannot
/// distinguish the two, so the raw value has to be fetched separately and its type
/// checked. Returns `true` only for the empty-`Data` case.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private func xpcIsEmptyData(_ value: xpc_object_t?) -> Bool {
    guard let value else { return false }
    return xpc_get_type(value) == XPC_TYPE_DATA
}

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
            guard xpcIsEmptyData(xpc_dictionary_get_value(underlying, key)) else { return nil }
            return Data()
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
            guard xpcIsEmptyData(xpc_dictionary_get_value(underlying, key)) else { return nil }
            return try body(UnsafeRawBufferPointer(start: nil, count: 0))
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
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps rather
    ///   than doing nothing: `a[0] = someOptionalValue` is a crash when the optional
    ///   is empty.
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
            // Bounds were already checked above, so what is left to disambiguate here
            // is a wrongly-typed element from a genuinely empty Data.
            guard xpcIsEmptyData(xpc_array_get_value(underlying, index)) else { return nil }
            return Data()
        }
        guard let base = base else { return nil }
        return Data(bytes: base, count: length)
    }

    /// Reads or writes binary data at `index`.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps rather
    ///   than doing nothing: `a[0] = someOptionalValue` is a crash when the optional
    ///   is empty.
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
