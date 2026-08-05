import XPC

// As with integers, a floating-point value may have been stored as int64,
// uint64 or double. Conversion is exact-only.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal func xpcReadFloatingPoint<T: BinaryFloatingPoint>(
    _ value: xpc_object_t?, as type: T.Type
) -> T? {
    guard let value else { return nil }
    switch xpc_get_type(value) {
    case XPC_TYPE_DOUBLE:
        return T(exactly: xpc_double_get_value(value))
    case XPC_TYPE_INT64:
        return T(exactly: xpc_int64_get_value(value))
    case XPC_TYPE_UINT64:
        return T(exactly: xpc_uint64_get_value(value))
    default:
        return nil
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads any floating-point type. Accepts double, int64 and uint64 storage.
    public subscript<T: BinaryFloatingPoint>(key: String, as type: T.Type = T.self) -> T? {
        xpcReadFloatingPoint(xpc_dictionary_get_value(underlying, key), as: T.self)
    }

    /// Reads or writes a floating-point value, stored as `double`. Assigning `nil` removes the key.
    public subscript<T: BinaryFloatingPoint>(key: String) -> T? {
        get { self[key, as: T.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_double(underlying, key, Double(newValue))
        }
    }

    /// Reads a floating-point value, falling back to `defaultValue`.
    public subscript<T: BinaryFloatingPoint>(
        key: String,
        as type: T.Type = T.self,
        default defaultValue: @autoclosure () -> T
    ) -> T {
        self[key, as: T.self] ?? defaultValue()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads any floating-point type at `index`.
    public subscript<T: BinaryFloatingPoint>(index: Int, as type: T.Type = T.self) -> T? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        return xpcReadFloatingPoint(xpc_array_get_value(underlying, index), as: T.self)
    }

    /// Reads or writes a floating-point value at `index`.
    public subscript<T: BinaryFloatingPoint>(index: Int) -> T? {
        get { self[index, as: T.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_double(underlying, index, Double(newValue))
        }
    }

    /// Reads a floating-point value at `index`, falling back to `defaultValue`.
    public subscript<T: BinaryFloatingPoint>(
        index: Int,
        as type: T.Type = T.self,
        default defaultValue: @autoclosure () -> T
    ) -> T {
        self[index, as: T.self] ?? defaultValue()
    }
}
