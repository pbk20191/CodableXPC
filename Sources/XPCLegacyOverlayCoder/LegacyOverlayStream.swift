import Foundation

/// A decoded value. There is no single-value case: that container is transparent
/// on the wire and writes only what it contains.
public indirect enum LegacyOverlayValue: Equatable, Sendable {
    case null
    case optionalNone
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
    /// Entries in wire order. Apple emitted them in `Dictionary` hash order, so the
    /// order a real legacy message arrives in is not stable across processes; this
    /// module preserves whatever order it reads and writes what it is given.
    case keyed([Entry])
    case unkeyed([LegacyOverlayValue])

    public struct Entry: Equatable, Sendable {
        public let key: String
        public let value: LegacyOverlayValue
        public init(key: String, value: LegacyOverlayValue) {
            self.key = key
            self.value = value
        }
    }
}

/// Reads the legacy byte stream.
///
/// Recursive descent, because the format is self-delimiting: every container
/// declares its element count and its body length up front, and every keyed value
/// declares its own length. That is the whole difference from the newer format,
/// which defers container bodies and refers to them by index instead.
public struct LegacyOverlayStreamReader {

    private let bytes: [UInt8]
    private var offset: Int
    private let limit: Int

    public init(_ data: Data) {
        bytes = [UInt8](data)
        offset = 0
        limit = bytes.count
    }

    private init(bytes: [UInt8], offset: Int, limit: Int) {
        self.bytes = bytes
        self.offset = offset
        self.limit = limit
    }

    /// Parse a whole message body. Trailing bytes are an error, not ignored.
    public static func parse(_ data: Data) throws -> LegacyOverlayValue {
        var reader = LegacyOverlayStreamReader(data)
        let value = try reader.readValue()
        guard reader.offset == reader.limit else {
            throw LegacyOverlayCoderError.trailingBytes(reader.limit - reader.offset)
        }
        return value
    }

    mutating func readValue() throws -> LegacyOverlayValue {
        let raw = try readByte()
        guard let tag = LegacyOverlayTag(rawValue: raw) else {
            throw LegacyOverlayCoderError.unknownTag(raw)
        }
        switch tag {
        case .null: return .null
        case .optionalNone:
            // Always followed by a single 0x01. Apple writes the marker and then a
            // byte; nothing reads the byte, but it is part of the encoding.
            _ = try readByte()
            return .optionalNone
        case .bool: return .bool(try readByte() & 1 == 1)
        case .string: return .string(try readString())
        case .float: return .float(Float(bitPattern: try readFixedWidth()))
        case .double: return .double(Double(bitPattern: try readFixedWidth()))
        case .int: return .int(Int(bitPattern: UInt(try readFixedWidth() as UInt64)))
        case .int8: return .int8(Int8(bitPattern: try readByte()))
        case .int16: return .int16(Int16(bitPattern: try readFixedWidth()))
        case .int32: return .int32(Int32(bitPattern: try readFixedWidth()))
        case .int64: return .int64(Int64(bitPattern: try readFixedWidth() as UInt64))
        case .uint: return .uint(UInt(try readFixedWidth() as UInt64))
        case .uint8: return .uint8(try readByte())
        case .uint16: return .uint16(try readFixedWidth())
        case .uint32: return .uint32(try readFixedWidth())
        case .uint64: return .uint64(try readFixedWidth())
        case .unkeyedContainer: return .unkeyed(try readUnkeyedBody())
        case .keyedContainer: return .keyed(try readKeyedBody())
        case .singleValueContainer, .encoder:
            // Declared by Apple's encoder but never emitted; seeing one means the
            // stream is not what it claims to be.
            throw LegacyOverlayCoderError.unknownTag(raw)
        }
    }

    private mutating func readUnkeyedBody() throws -> [LegacyOverlayValue] {
        let count = Int(try readFixedWidth() as UInt64)
        let bodyLength = Int(try readFixedWidth() as UInt64)
        var body = try scoped(bodyLength)
        var values: [LegacyOverlayValue] = []
        values.reserveCapacity(Swift.min(count, 1024))
        for _ in 0..<count {
            values.append(try body.readValue())
        }
        guard body.offset == body.limit else {
            throw LegacyOverlayCoderError.trailingBytes(body.limit - body.offset)
        }
        offset += bodyLength
        return values
    }

    private mutating func readKeyedBody() throws -> [LegacyOverlayValue.Entry] {
        let count = Int(try readFixedWidth() as UInt64)
        let bodyLength = Int(try readFixedWidth() as UInt64)
        var body = try scoped(bodyLength)
        var entries: [LegacyOverlayValue.Entry] = []
        entries.reserveCapacity(Swift.min(count, 1024))
        for _ in 0..<count {
            let keyTag = try body.readByte()
            guard keyTag == LegacyOverlayTag.string.rawValue else {
                throw LegacyOverlayCoderError.unexpectedTag(expected: .string, found: keyTag)
            }
            let key = try body.readString()
            // Unlike unkeyed elements, each keyed value carries its own length.
            let valueLength = Int(try body.readFixedWidth() as UInt64)
            var slot = try body.scoped(valueLength)
            let value = try slot.readValue()
            guard slot.offset == slot.limit else {
                throw LegacyOverlayCoderError.trailingBytes(slot.limit - slot.offset)
            }
            body.offset += valueLength
            entries.append(.init(key: key, value: value))
        }
        guard body.offset == body.limit else {
            throw LegacyOverlayCoderError.trailingBytes(body.limit - body.offset)
        }
        offset += bodyLength
        return entries
    }

    /// A reader over the next `length` bytes, so a declared length cannot be used
    /// to read past its own region.
    private func scoped(_ length: Int) throws -> LegacyOverlayStreamReader {
        guard length >= 0, limit - offset >= length else {
            throw LegacyOverlayCoderError.declaredLengthOverruns(
                declared: length, available: limit - offset)
        }
        return LegacyOverlayStreamReader(bytes: bytes, offset: offset, limit: offset + length)
    }

    // MARK: primitives

    private mutating func require(_ count: Int) throws {
        guard limit - offset >= count else {
            throw LegacyOverlayCoderError.truncated(needed: count, available: limit - offset)
        }
    }

    private mutating func readByte() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

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

    /// `[u64 length][utf8][NUL]` where the length **includes** the NUL — one more
    /// than the UTF-8 byte count, unlike the newer format.
    private mutating func readString() throws -> String {
        let declared = Int(try readFixedWidth() as UInt64)
        guard declared >= 1 else {
            throw LegacyOverlayCoderError.stringNotTerminated
        }
        let utf8Count = declared - 1
        try require(declared)
        let text = String(decoding: bytes[offset..<(offset + utf8Count)], as: UTF8.self)
        guard bytes[offset + utf8Count] == 0 else {
            throw LegacyOverlayCoderError.stringNotTerminated
        }
        offset += declared
        return text
    }
}

/// Writes the legacy byte stream.
public enum LegacyOverlayStreamWriter {

    public static func serialize(_ value: LegacyOverlayValue) -> Data {
        var bytes: [UInt8] = []
        write(value, into: &bytes)
        return Data(bytes)
    }

    static func write(_ value: LegacyOverlayValue, into bytes: inout [UInt8]) {
        switch value {
        case .null: bytes.append(LegacyOverlayTag.null.rawValue)
        case .optionalNone:
            bytes.append(LegacyOverlayTag.optionalNone.rawValue)
            bytes.append(1)
        case .bool(let v):
            bytes.append(LegacyOverlayTag.bool.rawValue); bytes.append(v ? 1 : 0)
        case .string(let v):
            bytes.append(LegacyOverlayTag.string.rawValue); writeString(v, into: &bytes)
        case .float(let v):
            bytes.append(LegacyOverlayTag.float.rawValue); writeFixed(v.bitPattern, into: &bytes)
        case .double(let v):
            bytes.append(LegacyOverlayTag.double.rawValue); writeFixed(v.bitPattern, into: &bytes)
        case .int(let v):
            bytes.append(LegacyOverlayTag.int.rawValue)
            writeFixed(UInt64(bitPattern: Int64(v)), into: &bytes)
        case .int8(let v):
            bytes.append(LegacyOverlayTag.int8.rawValue); bytes.append(UInt8(bitPattern: v))
        case .int16(let v):
            bytes.append(LegacyOverlayTag.int16.rawValue)
            writeFixed(UInt16(bitPattern: v), into: &bytes)
        case .int32(let v):
            bytes.append(LegacyOverlayTag.int32.rawValue)
            writeFixed(UInt32(bitPattern: v), into: &bytes)
        case .int64(let v):
            bytes.append(LegacyOverlayTag.int64.rawValue)
            writeFixed(UInt64(bitPattern: v), into: &bytes)
        case .uint(let v):
            bytes.append(LegacyOverlayTag.uint.rawValue); writeFixed(UInt64(v), into: &bytes)
        case .uint8(let v):
            bytes.append(LegacyOverlayTag.uint8.rawValue); bytes.append(v)
        case .uint16(let v):
            bytes.append(LegacyOverlayTag.uint16.rawValue); writeFixed(v, into: &bytes)
        case .uint32(let v):
            bytes.append(LegacyOverlayTag.uint32.rawValue); writeFixed(v, into: &bytes)
        case .uint64(let v):
            bytes.append(LegacyOverlayTag.uint64.rawValue); writeFixed(v, into: &bytes)

        case .unkeyed(let elements):
            bytes.append(LegacyOverlayTag.unkeyedContainer.rawValue)
            writeFixed(UInt64(elements.count), into: &bytes)
            var body: [UInt8] = []
            for element in elements { write(element, into: &body) }
            writeFixed(UInt64(body.count), into: &bytes)
            bytes.append(contentsOf: body)

        case .keyed(let entries):
            bytes.append(LegacyOverlayTag.keyedContainer.rawValue)
            writeFixed(UInt64(entries.count), into: &bytes)
            var body: [UInt8] = []
            for entry in entries {
                body.append(LegacyOverlayTag.string.rawValue)
                writeString(entry.key, into: &body)
                var slot: [UInt8] = []
                write(entry.value, into: &slot)
                writeFixed(UInt64(slot.count), into: &body)
                body.append(contentsOf: slot)
            }
            writeFixed(UInt64(body.count), into: &bytes)
            bytes.append(contentsOf: body)
        }
    }

    /// Length counts the NUL, matching what the reader expects.
    private static func writeString(_ string: String, into bytes: inout [UInt8]) {
        let utf8 = Array(string.utf8)
        writeFixed(UInt64(utf8.count + 1), into: &bytes)
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }

    private static func writeFixed<T: FixedWidthInteger & UnsignedInteger>(
        _ value: T, into bytes: inout [UInt8]) {
        for index in 0..<MemoryLayout<T>.size {
            bytes.append(UInt8(truncatingIfNeeded: value >> (8 * index)))
        }
    }
}
