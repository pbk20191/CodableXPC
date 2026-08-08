import Foundation

/// A value as it appears in the stream, before container references are resolved.
public enum OverlayRawValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case string(String)
    case float(Float)
    case double(Double)
    case int(Int)
    case int8(Int8)
    case int16(Int16)
    case int32(Int32)
    case int64(Int64)
    case uint(UInt)
    case uint8(UInt8)
    case uint16(UInt16)
    case uint32(UInt32)
    case uint64(UInt64)
    /// A keyed container's key. `nil` is `superEncoder()`.
    case key(String?)
    /// An index into `_CodableOutOfLine`.
    case outOfLineData(UInt32)
    case containerKind(OverlayContainerKind)
    /// A container whose body appears later in the stream.
    case containerReference(UInt32)
}

/// A parsed container: its kind and its items, references unresolved.
public struct OverlayRawContainer: Equatable, Sendable {
    public let kind: OverlayContainerKind
    /// The body, excluding the leading kind marker. A keyed container alternates
    /// `key, value, key, value…`.
    public let items: [OverlayRawValue]
}

/// Reads Apple's `_CodableBody` byte stream.
///
/// The stream is flat. A container declares its children by id where they appear,
/// and each child's body follows later, introduced by
/// ``OverlayTag/containerStart``, in the order the ids were assigned. That order is
/// breadth-first, because Apple's encoder assigns ids during a breadth-first
/// traversal — so this reader opens bodies by a simple ascending counter rather
/// than by tracking a stack.
public struct OverlayStreamReader {

    private let bytes: [UInt8]
    private var offset = 0

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    /// Parse the whole stream.
    ///
    /// - Returns: the root container, and every referenced container by id.
    public static func parse(_ data: Data) throws -> (root: OverlayRawContainer,
                                                      containers: [UInt32: OverlayRawContainer]) {
        var reader = OverlayStreamReader(data)
        return try reader.run()
    }

    private mutating func run() throws -> (root: OverlayRawContainer,
                                           containers: [UInt32: OverlayRawContainer]) {
        var current: [OverlayRawValue] = []
        var currentID: UInt32?
        var declared: Set<UInt32> = []
        var finished: [UInt32: [OverlayRawValue]] = [:]
        var rootItems: [OverlayRawValue]?
        // Bodies open in the order ids were handed out, which is why no stack is
        // needed: the encoder assigned them breadth-first and writes them in the
        // same order.
        var nextToOpen: UInt32 = 0

        func closeCurrent() {
            if let currentID { finished[currentID] = current } else { rootItems = current }
        }

        while offset < bytes.count {
            let raw = try readByte()
            guard let tag = OverlayTag(rawValue: raw) else {
                // Apple's decoder folds unknown bytes into its nil branch. Rejecting
                // them instead is a deliberate divergence: reading corruption as a
                // valid nil is worse than failing.
                throw OverlayCoderError.unknownTag(raw)
            }

            switch tag {
            case .containerStart:
                closeCurrent()
                guard declared.remove(nextToOpen) != nil else {
                    throw OverlayCoderError.unopenedContainerBody
                }
                currentID = nextToOpen
                nextToOpen += 1
                current = []

            case .containerReference:
                let id = try readUInt32()
                guard declared.insert(id).inserted else {
                    throw OverlayCoderError.duplicateContainerReference(id)
                }
                current.append(.containerReference(id))

            default:
                current.append(try readValue(tag))
            }
        }
        closeCurrent()

        if let dangling = declared.first {
            throw OverlayCoderError.danglingContainerReference(dangling)
        }
        guard let rootItems else { throw OverlayCoderError.truncated(needed: 1, available: 0) }

        return (try Self.container(from: rootItems),
                try finished.mapValues { try Self.container(from: $0) })
    }

    /// Split the leading kind marker off a body.
    private static func container(from items: [OverlayRawValue]) throws -> OverlayRawContainer {
        guard case .containerKind(let kind)? = items.first else {
            throw OverlayCoderError.unknownContainerKind(0)
        }
        return OverlayRawContainer(kind: kind, items: Array(items.dropFirst()))
    }

    private mutating func readValue(_ tag: OverlayTag) throws -> OverlayRawValue {
        switch tag {
        case .null: return .null
        case .boolTrue: return .bool(true)
        case .boolFalse: return .bool(false)
        case .string: return .string(try readString())
        case .float: return .float(Float(bitPattern: try readUInt32()))
        case .double: return .double(Double(bitPattern: try readUInt64()))
        case .int: return .int(Int(bitPattern: UInt(try readUInt64())))
        case .int8: return .int8(Int8(bitPattern: try readByte()))
        case .int16: return .int16(Int16(bitPattern: try readUInt16()))
        case .int32: return .int32(Int32(bitPattern: try readUInt32()))
        case .int64: return .int64(Int64(bitPattern: try readUInt64()))
        case .uint: return .uint(UInt(try readUInt64()))
        case .uint8: return .uint8(try readByte())
        case .uint16: return .uint16(try readUInt16())
        case .uint32: return .uint32(try readUInt32())
        case .uint64: return .uint64(try readUInt64())
        case .keyNil: return .key(nil)
        case .key: return .key(try readString())
        case .outOfLineData: return .outOfLineData(try readUInt32())
        case .containerMetadata:
            let raw = try readByte()
            guard let kind = OverlayContainerKind(rawValue: raw) else {
                throw OverlayCoderError.unknownContainerKind(raw)
            }
            return .containerKind(kind)
        case .containerReference, .containerStart:
            preconditionFailure("handled by the caller")
        }
    }

    // MARK: primitives

    private mutating func require(_ count: Int) throws {
        guard bytes.count - offset >= count else {
            throw OverlayCoderError.truncated(needed: count, available: bytes.count - offset)
        }
    }

    private mutating func readByte() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func readUInt16() throws -> UInt16 { try readFixedWidth() }
    private mutating func readUInt32() throws -> UInt32 { try readFixedWidth() }
    private mutating func readUInt64() throws -> UInt64 { try readFixedWidth() }

    /// Little-endian, byte at a time — the stream has no alignment guarantee.
    private mutating func readFixedWidth<T: FixedWidthInteger & UnsignedInteger>() throws -> T {
        let width = MemoryLayout<T>.size
        try require(width)
        var value: T = 0
        for index in 0..<width {
            value |= T(bytes[offset + index]) << (8 * index)
        }
        offset += width
        return value
    }

    /// `UInt64` byte count, the UTF-8 bytes, then a NUL that is not counted.
    private mutating func readString() throws -> String {
        let count = Int(try readUInt64())
        try require(count + 1)
        let text = String(decoding: bytes[offset..<(offset + count)], as: UTF8.self)
        guard bytes[offset + count] == 0 else { throw OverlayCoderError.stringNotTerminated }
        offset += count + 1
        return text
    }
}
