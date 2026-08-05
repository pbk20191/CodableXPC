import XPC

// Storage declarations only. Every other member lives in a file-scope extension,
// per the shadowing rule in Namespace.swift.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat {

    /// A typed wrapper over an `XPC_TYPE_DICTIONARY` object.
    ///
    /// This is a struct with reference semantics: copying it retains the same underlying
    /// object, so mutating a copy is visible through the original. Use `copy(into:)` for
    /// an independent duplicate.
    public struct Dictionary {
        @usableFromInline
        internal let underlying: xpc_object_t

        /// Wraps an existing dictionary object.
        /// - Precondition: `value` is an `XPC_TYPE_DICTIONARY`.
        public init(_ value: xpc_object_t) {
            precondition(
                xpc_get_type(value) == XPC_TYPE_DICTIONARY,
                "XPCCompat.Dictionary requires an XPC_TYPE_DICTIONARY object"
            )
            self.underlying = value
        }

        /// Creates an empty dictionary.
        public init() {
            self.underlying = xpc_dictionary_create(nil, nil, 0)
        }
    }

    /// A typed wrapper over an `XPC_TYPE_ARRAY` object.
    ///
    /// Reference semantics, as `Dictionary`.
    public struct Array {
        @usableFromInline
        internal let underlying: xpc_object_t

        /// Wraps an existing array object.
        /// - Precondition: `value` is an `XPC_TYPE_ARRAY`.
        public init(_ value: xpc_object_t) {
            precondition(
                xpc_get_type(value) == XPC_TYPE_ARRAY,
                "XPCCompat.Array requires an XPC_TYPE_ARRAY object"
            )
            self.underlying = value
        }

        /// Creates an empty array.
        public init() {
            self.underlying = xpc_array_create(nil, 0)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary {

    /// Calls `closure` with the underlying `xpc_object_t`.
    @inlinable
    public func withUnsafeUnderlyingDictionary<ReturnType>(
        _ closure: (xpc_object_t) throws -> ReturnType
    ) rethrows -> ReturnType {
        try closure(underlying)
    }

    /// The number of key-value pairs.
    public var count: Int { xpc_dictionary_get_count(underlying) }

    /// Whether the dictionary has no entries.
    public var isEmpty: Bool { count == 0 }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array {

    /// Calls `closure` with the underlying `xpc_object_t`.
    @inlinable
    public func withUnsafeUnderlyingArray<ReturnType>(
        _ closure: (xpc_object_t) throws -> ReturnType
    ) rethrows -> ReturnType {
        try closure(underlying)
    }

    /// The number of elements.
    public var count: Int { xpc_array_get_count(underlying) }

    /// Whether the array has no elements.
    public var isEmpty: Bool { count == 0 }
}
