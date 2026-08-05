import XPC

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads a boolean. Returns `nil` if the key is absent or the value is not a boolean.
    ///
    /// Only `XPC_TYPE_BOOL` is accepted; an integer `0`/`1` reads as `nil`.
    public subscript(key: String, as type: Bool.Type = Bool.self) -> Bool? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == XPC_TYPE_BOOL else { return nil }
        return xpc_bool_get_value(value)
    }

    /// Reads or writes a boolean. Assigning `nil` removes the key.
    public subscript(key: String) -> Bool? {
        get { self[key, as: Bool.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_bool(underlying, key, newValue)
        }
    }

    /// Reads a boolean, falling back to `defaultValue` when the key is absent,
    /// the value is not a boolean, or conversion fails.
    public subscript(
        key: String,
        as type: Bool.Type = Bool.self,
        default defaultValue: @autoclosure () -> Bool
    ) -> Bool {
        self[key, as: Bool.self] ?? defaultValue()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads a boolean. Returns `nil` if the index is out of range or the value is not a boolean.
    public subscript(index: Int, as type: Bool.Type = Bool.self) -> Bool? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        let value = xpc_array_get_value(underlying, index)
        guard xpc_get_type(value) == XPC_TYPE_BOOL else { return nil }
        return xpc_bool_get_value(value)
    }

    /// Reads or writes a boolean at `index`.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps rather
    ///   than doing nothing: `a[0] = someOptionalValue` is a crash when the optional
    ///   is empty.
    public subscript(index: Int) -> Bool? {
        get { self[index, as: Bool.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_bool(underlying, index, newValue)
        }
    }

    /// Reads a boolean, falling back to `defaultValue`.
    public subscript(
        index: Int,
        as type: Bool.Type = Bool.self,
        default defaultValue: @autoclosure () -> Bool
    ) -> Bool {
        self[index, as: Bool.self] ?? defaultValue()
    }
}
