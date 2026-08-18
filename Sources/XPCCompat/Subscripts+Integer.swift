import XPC

// Shared reader: an integer may have been stored as int64, uint64 or double.
// Conversion is always range-checked with init(exactly:), so out-of-range and
// fractional values yield nil rather than a truncated result.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal func xpcReadInteger<T: BinaryInteger>(_ value: xpc_object_t?, as type: T.Type) -> T? {
    guard let value else { return nil }
    switch xpc_get_type(value) {
    case XPC_TYPE_INT64:
        return T(exactly: xpc_int64_get_value(value))
    case XPC_TYPE_UINT64:
        return T(exactly: xpc_uint64_get_value(value))
    case XPC_TYPE_DOUBLE:
        return T(exactly: xpc_double_get_value(value))
    default:
        return nil
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads any integer type. Accepts int64, uint64 and whole-valued double storage.
    /// Returns `nil` when absent, wrongly typed, or out of range for `T`.
    public subscript<T: BinaryInteger>(key: String, as type: T.Type = T.self) -> T? {
        xpcReadInteger(xpc_dictionary_get_value(underlying, key), as: T.self)
    }

    /// Reads or writes a signed integer, stored as `int64`. Assigning `nil` removes the key.
    public subscript<T: SignedInteger>(key: String) -> T? {
        get { self[key, as: T.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            guard let wide = Int64(exactly: newValue) else {
                preconditionFailure("\(newValue) cannot be represented as Int64")
            }
            xpc_dictionary_set_int64(underlying, key, wide)
        }
    }

    /// Reads or writes an unsigned integer, stored as `uint64`. Assigning `nil` removes the key.
    public subscript<T: UnsignedInteger>(key: String) -> T? {
        get { self[key, as: T.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            guard let wide = UInt64(exactly: newValue) else {
                preconditionFailure("\(newValue) cannot be represented as UInt64")
            }
            xpc_dictionary_set_uint64(underlying, key, wide)
        }
    }

    /// Reads an integer, falling back to `defaultValue` on absence, wrong type or overflow.
    public subscript<T: BinaryInteger>(
        key: String,
        as type: T.Type = T.self,
        default defaultValue: @autoclosure () -> T
    ) -> T {
        self[key, as: T.self] ?? defaultValue()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads any integer type at `index`.
    public subscript<T: BinaryInteger>(index: Int, as type: T.Type = T.self) -> T? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        return xpcReadInteger(xpc_array_get_value(underlying, index), as: T.self)
    }

    /// Reads or writes a signed integer at `index`.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps rather
    ///   than doing nothing: `a[0] = someOptionalValue` is a crash when the optional
    ///   is empty.
    public subscript<T: SignedInteger>(index: Int) -> T? {
        get { self[index, as: T.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            guard let wide = Int64(exactly: newValue) else {
                preconditionFailure("\(newValue) cannot be represented as Int64")
            }
            xpc_array_set_int64(underlying, index, wide)
        }
    }

    /// Reads or writes an unsigned integer at `index`.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps rather
    ///   than doing nothing: `a[0] = someOptionalValue` is a crash when the optional
    ///   is empty.
    public subscript<T: UnsignedInteger>(index: Int) -> T? {
        get { self[index, as: T.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            guard let wide = UInt64(exactly: newValue) else {
                preconditionFailure("\(newValue) cannot be represented as UInt64")
            }
            xpc_array_set_uint64(underlying, index, wide)
        }
    }

    /// Reads an integer at `index`, falling back to `defaultValue`.
    public subscript<T: BinaryInteger>(
        index: Int,
        as type: T.Type = T.self,
        default defaultValue: @autoclosure () -> T
    ) -> T {
        self[index, as: T.self] ?? defaultValue()
    }
}
