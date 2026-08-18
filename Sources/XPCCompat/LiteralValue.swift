import XPC

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat {

    /// A value usable inside an `XPCCompat.Dictionary` literal.
    ///
    ///     let message: XPCCompat.Dictionary = ["name": "hello", "count": 3]
    public struct LiteralValue {
        @usableFromInline
        internal let object: xpc_object_t

        /// Wraps an already-built XPC object.
        public init(_ object: xpc_object_t) {
            self.object = object
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.LiteralValue {

    /// Wraps a string.
    public init(_ value: String) { self.init(xpc_string_create(value)) }

    /// Wraps a signed integer.
    public init<T: SignedInteger>(_ value: T) { self.init(xpc_int64_create(Int64(value))) }

    /// Wraps an unsigned integer.
    public init<T: UnsignedInteger>(_ value: T) { self.init(xpc_uint64_create(UInt64(value))) }

    /// Wraps a floating-point value.
    public init<T: BinaryFloatingPoint>(_ value: T) { self.init(xpc_double_create(Double(value))) }

    /// Wraps a boolean.
    public init(_ value: Bool) { self.init(xpc_bool_create(value)) }

    /// Wraps a nested dictionary.
    public init(_ value: XPCCompat.Dictionary) { self.init(value.underlying) }

    /// Wraps a nested array.
    public init(_ value: XPCCompat.Array) { self.init(value.underlying) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.LiteralValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.LiteralValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self.init(value) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.LiteralValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self.init(value) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.LiteralValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self.init(value) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary: ExpressibleByDictionaryLiteral {
    public typealias Key = String
    public typealias Value = XPCCompat.LiteralValue

    public init(dictionaryLiteral elements: (String, XPCCompat.LiteralValue)...) {
        self.init()
        for (key, element) in elements {
            xpc_dictionary_set_value(underlying, key, element.object)
        }
    }
}
