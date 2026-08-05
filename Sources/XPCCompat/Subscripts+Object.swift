import XPC

// Untyped setters mirror Apple's connection special case: a connection object
// must be stored with xpc_dictionary_set_connection, not set_value.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal func xpcSetObject(_ container: xpc_object_t, _ key: String, _ value: xpc_object_t) {
    if xpc_get_type(value) == XPC_TYPE_CONNECTION {
        xpc_dictionary_set_connection(container, key, value)
    } else {
        xpc_dictionary_set_value(container, key, value)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Reads a nested dictionary.
    public subscript(key: String, as type: XPCCompat.Dictionary.Type = XPCCompat.Dictionary.self) -> XPCCompat.Dictionary? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == XPC_TYPE_DICTIONARY else { return nil }
        return XPCCompat.Dictionary(value)
    }

    /// Reads or writes a nested dictionary. The child is stored by reference, not copied.
    public subscript(key: String) -> XPCCompat.Dictionary? {
        get { self[key, as: XPCCompat.Dictionary.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_value(underlying, key, newValue.underlying)
        }
    }

    /// Reads a nested array.
    public subscript(key: String, as type: XPCCompat.Array.Type = XPCCompat.Array.self) -> XPCCompat.Array? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == XPC_TYPE_ARRAY else { return nil }
        return XPCCompat.Array(value)
    }

    /// Reads or writes a nested array. The child is stored by reference, not copied.
    public subscript(key: String) -> XPCCompat.Array? {
        get { self[key, as: XPCCompat.Array.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_value(underlying, key, newValue.underlying)
        }
    }

    /// Reads an endpoint.
    public subscript(key: String, as type: XPCCompat.Endpoint.Type = XPCCompat.Endpoint.self) -> XPCCompat.Endpoint? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == XPC_TYPE_ENDPOINT else { return nil }
        return XPCCompat.Endpoint(value)
    }

    /// Reads or writes an endpoint.
    public subscript(key: String) -> XPCCompat.Endpoint? {
        get { self[key, as: XPCCompat.Endpoint.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_value(underlying, key, newValue.underlying)
        }
    }

    /// Reads a shared memory object.
    public subscript(key: String, as type: XPCCompat.SharedMemory.Type = XPCCompat.SharedMemory.self) -> XPCCompat.SharedMemory? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == XPC_TYPE_SHMEM else { return nil }
        return XPCCompat.SharedMemory(value)
    }

    /// Reads or writes a shared memory object.
    public subscript(key: String) -> XPCCompat.SharedMemory? {
        get { self[key, as: XPCCompat.SharedMemory.self] }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpc_dictionary_set_value(underlying, key, newValue.underlying)
        }
    }

    /// Reads the raw object stored under `key`, whatever its type.
    public subscript(key: String, as type: xpc_object_t.Type = xpc_object_t.self) -> xpc_object_t? {
        xpc_dictionary_get_value(underlying, key)
    }

    /// Reads the raw object stored under `key`, but only if it has the given XPC type.
    public subscript(key: String, as type: xpc_type_t) -> xpc_object_t? {
        guard let value = xpc_dictionary_get_value(underlying, key),
              xpc_get_type(value) == type else { return nil }
        return value
    }

    /// Reads or writes a raw object. Assigning `nil` removes the key.
    public subscript(key: String) -> xpc_object_t? {
        get { xpc_dictionary_get_value(underlying, key) }
        set {
            guard let newValue else {
                xpc_dictionary_set_value(underlying, key, nil)
                return
            }
            xpcSetObject(underlying, key, newValue)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Reads a nested dictionary at `index`.
    public subscript(index: Int, as type: XPCCompat.Dictionary.Type = XPCCompat.Dictionary.self) -> XPCCompat.Dictionary? {
        guard let value = self[index, as: xpc_object_t.self],
              xpc_get_type(value) == XPC_TYPE_DICTIONARY else { return nil }
        return XPCCompat.Dictionary(value)
    }

    /// Reads or writes a nested dictionary at `index`. The child is stored by reference, not copied.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps rather
    ///   than doing nothing: `a[0] = someOptionalValue` is a crash when the optional
    ///   is empty.
    public subscript(index: Int) -> XPCCompat.Dictionary? {
        get { self[index, as: XPCCompat.Dictionary.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_value(underlying, index, newValue.underlying)
        }
    }

    /// Reads a nested array at `index`.
    public subscript(index: Int, as type: XPCCompat.Array.Type = XPCCompat.Array.self) -> XPCCompat.Array? {
        guard let value = self[index, as: xpc_object_t.self],
              xpc_get_type(value) == XPC_TYPE_ARRAY else { return nil }
        return XPCCompat.Array(value)
    }

    /// Reads or writes a nested array at `index`. The child is stored by reference, not copied.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps rather
    ///   than doing nothing: `a[0] = someOptionalValue` is a crash when the optional
    ///   is empty.
    public subscript(index: Int) -> XPCCompat.Array? {
        get { self[index, as: XPCCompat.Array.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_value(underlying, index, newValue.underlying)
        }
    }

    /// Reads an endpoint at `index`.
    public subscript(index: Int, as type: XPCCompat.Endpoint.Type = XPCCompat.Endpoint.self) -> XPCCompat.Endpoint? {
        guard let value = self[index, as: xpc_object_t.self],
              xpc_get_type(value) == XPC_TYPE_ENDPOINT else { return nil }
        return XPCCompat.Endpoint(value)
    }

    /// Reads or writes an endpoint at `index`.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps rather
    ///   than doing nothing: `a[0] = someOptionalValue` is a crash when the optional
    ///   is empty.
    public subscript(index: Int) -> XPCCompat.Endpoint? {
        get { self[index, as: XPCCompat.Endpoint.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_value(underlying, index, newValue.underlying)
        }
    }

    /// Reads a shared memory object at `index`.
    public subscript(index: Int, as type: XPCCompat.SharedMemory.Type = XPCCompat.SharedMemory.self) -> XPCCompat.SharedMemory? {
        guard let value = self[index, as: xpc_object_t.self],
              xpc_get_type(value) == XPC_TYPE_SHMEM else { return nil }
        return XPCCompat.SharedMemory(value)
    }

    /// Reads or writes a shared memory object at `index`.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps rather
    ///   than doing nothing: `a[0] = someOptionalValue` is a crash when the optional
    ///   is empty.
    public subscript(index: Int) -> XPCCompat.SharedMemory? {
        get { self[index, as: XPCCompat.SharedMemory.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            xpc_array_set_value(underlying, index, newValue.underlying)
        }
    }

    /// Reads the raw object at `index`.
    public subscript(index: Int, as type: xpc_object_t.Type = xpc_object_t.self) -> xpc_object_t? {
        guard index >= 0, index < xpc_array_get_count(underlying) else { return nil }
        return xpc_array_get_value(underlying, index)
    }

    /// Reads the raw object at `index`, but only if it has the given XPC type.
    public subscript(index: Int, as type: xpc_type_t) -> xpc_object_t? {
        guard let value = self[index, as: xpc_object_t.self],
              xpc_get_type(value) == type else { return nil }
        return value
    }

    /// Reads or writes a raw object at `index`.
    /// - Precondition: on set, `index` is within bounds and `newValue` is non-nil.
    ///   An `XPCCompat.Array` cannot remove elements, so assigning `nil` traps rather
    ///   than doing nothing: `a[0] = someOptionalValue` is a crash when the optional
    ///   is empty.
    public subscript(index: Int) -> xpc_object_t? {
        get { self[index, as: xpc_object_t.self] }
        set {
            guard let newValue else {
                preconditionFailure("XPCCompat.Array does not support removing elements by assigning nil")
            }
            precondition(index >= 0 && index < xpc_array_get_count(underlying), "index out of range")
            if xpc_get_type(newValue) == XPC_TYPE_CONNECTION {
                xpc_array_set_connection(underlying, index, newValue)
            } else {
                xpc_array_set_value(underlying, index, newValue)
            }
        }
    }

    /// Appends a raw object.
    public func append(_ value: xpc_object_t) {
        xpc_array_append_value(underlying, value)
    }
}
