import XPC

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// A key and its associated raw value.
    public typealias KeyValuePair = (key: String, value: xpc_object_t)

    /// Calls `body` once per entry.
    ///
    /// Iteration order is whatever `xpc_dictionary_apply` yields and is not specified.
    /// If `body` throws, iteration stops immediately and the error is rethrown.
    public func forEach(
        _ body: (_ key: String, _ value: xpc_object_t) throws -> Void
    ) rethrows {
        var thrown: Error?
        xpc_dictionary_apply(underlying) { key, value in
            do {
                try body(String(cString: key), value)
                return true
            } catch {
                thrown = error
                return false
            }
        }
        if let thrown {
            try { throw thrown }()
        }
    }

    /// Calls `body` once per entry, as a tuple.
    public func forEach(_ body: (KeyValuePair) throws -> Void) rethrows {
        try forEach { key, value in try body((key: key, value: value)) }
    }

    /// Transforms each entry into a value.
    public func map<ReturnType>(
        _ transform: (KeyValuePair) throws -> ReturnType
    ) rethrows -> [ReturnType] {
        var results: [ReturnType] = []
        results.reserveCapacity(count)
        try forEach { pair in results.append(try transform(pair)) }
        return results
    }

    /// The keys, in the same order as `values`.
    public var keys: [String] { map { $0.key } }

    /// The values, in the same order as `keys`.
    public var values: [xpc_object_t] { map { $0.value } }

    /// Removes `key` and returns the value it held, if any.
    @discardableResult
    public mutating func removeValue(forKey key: String) -> xpc_object_t? {
        let existing = xpc_dictionary_get_value(underlying, key)
        xpc_dictionary_set_value(underlying, key, nil)
        return existing
    }

    /// Shallow-copies every entry into `destination`.
    ///
    /// Values are shared, not duplicated; only the top-level entries are copied.
    public func copy(into destination: XPCCompat.Dictionary) {
        forEach { key, value in
            xpc_dictionary_set_value(destination.underlying, key, value)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// An index and its associated raw value.
    public typealias IndexValuePair = (index: Int, value: xpc_object_t)

    /// Calls `body` once per element, in index order.
    ///
    /// If `body` throws, iteration stops immediately and the error is rethrown.
    public func forEach(
        _ body: (_ index: Int, _ value: xpc_object_t) throws -> Void
    ) rethrows {
        var thrown: Error?
        xpc_array_apply(underlying) { index, value in
            do {
                try body(index, value)
                return true
            } catch {
                thrown = error
                return false
            }
        }
        if let thrown {
            try { throw thrown }()
        }
    }

    /// Calls `body` once per element, as a tuple.
    public func forEach(_ body: (IndexValuePair) throws -> Void) rethrows {
        try forEach { index, value in try body((index: index, value: value)) }
    }

    /// Transforms each element into a value.
    public func map<ReturnType>(
        _ transform: (IndexValuePair) throws -> ReturnType
    ) rethrows -> [ReturnType] {
        var results: [ReturnType] = []
        results.reserveCapacity(count)
        try forEach { pair in results.append(try transform(pair)) }
        return results
    }

    /// Appends every element of the receiver to `destination`.
    public func copy(into destination: XPCCompat.Array) {
        forEach { _, value in
            xpc_array_append_value(destination.underlying, value)
        }
    }
}
