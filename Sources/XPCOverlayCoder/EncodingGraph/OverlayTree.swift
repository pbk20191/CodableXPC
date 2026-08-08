import Foundation

/// A value with container references resolved.
public indirect enum OverlayValue: Sendable {
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
    /// An index into `_CodableOutOfLine`.
    case outOfLineData(UInt32)
    case container(OverlayNode)
}

/// A container with its children resolved.
public struct OverlayNode: Sendable {
    public let kind: OverlayContainerKind

    /// Keyed entries in wire order. `nil` is `superEncoder()`. Order is preserved
    /// because the format preserves it and a round trip should too.
    public let entries: [(key: String?, value: OverlayValue)]

    /// Unkeyed elements, or the single value.
    public let elements: [OverlayValue]

    /// Built once so key lookup is not linear. A later duplicate key wins, matching
    /// how a dictionary built by insertion would behave.
    let byKey: [String: OverlayValue]

    init(kind: OverlayContainerKind,
         entries: [(key: String?, value: OverlayValue)],
         elements: [OverlayValue]) {
        self.kind = kind
        self.entries = entries
        self.elements = elements
        var lookup: [String: OverlayValue] = [:]
        for entry in entries {
            if let key = entry.key { lookup[key] = entry.value }
        }
        byKey = lookup
    }

    /// The `superEncoder()` slot, stored under the keyless entry.
    var superValue: OverlayValue? {
        entries.first { $0.key == nil }?.value
    }

    /// Apple special-cases a container shaped `[unkeyed, outOfLineData]` back into
    /// `Data` without going through `Decodable.init(from:)` at all. Recognising the
    /// shape is what makes a `Data` field decode, since `Data.init(from:)` would
    /// otherwise expect a run of `UInt8` elements.
    var foundationDataIndex: UInt32? {
        guard kind == .unkeyed, elements.count == 1,
              case .outOfLineData(let index) = elements[0] else { return nil }
        return index
    }
}

extension OverlayValue {
    /// Resolve a parsed stream into a tree.
    static func resolve(_ container: OverlayRawContainer,
                        in containers: [UInt32: OverlayRawContainer]) throws -> OverlayNode {
        var resolving: Set<UInt32> = []
        return try node(container, containers, &resolving)
    }

    private static func node(_ raw: OverlayRawContainer,
                             _ all: [UInt32: OverlayRawContainer],
                             _ resolving: inout Set<UInt32>) throws -> OverlayNode {
        var entries: [(key: String?, value: OverlayValue)] = []
        var elements: [OverlayValue] = []

        if raw.kind == .keyed {
            // Keyed bodies alternate key, value. An odd count means a key with no
            // value, which Apple's decoder also rejects.
            guard raw.items.count % 2 == 0 else {
                throw OverlayCoderError.truncated(needed: raw.items.count + 1,
                                                  available: raw.items.count)
            }
            var index = 0
            while index < raw.items.count {
                guard case .key(let name) = raw.items[index] else {
                    throw OverlayCoderError.unknownTag(OverlayTag.key.rawValue)
                }
                entries.append((name, try value(raw.items[index + 1], all, &resolving)))
                index += 2
            }
        } else {
            for item in raw.items {
                elements.append(try value(item, all, &resolving))
            }
        }
        return OverlayNode(kind: raw.kind, entries: entries, elements: elements)
    }

    private static func value(_ raw: OverlayRawValue,
                              _ all: [UInt32: OverlayRawContainer],
                              _ resolving: inout Set<UInt32>) throws -> OverlayValue {
        switch raw {
        case .null: return .null
        case .bool(let v): return .bool(v)
        case .string(let v): return .string(v)
        case .float(let v): return .float(v)
        case .double(let v): return .double(v)
        case .int(let v): return .int(v)
        case .int8(let v): return .int8(v)
        case .int16(let v): return .int16(v)
        case .int32(let v): return .int32(v)
        case .int64(let v): return .int64(v)
        case .uint(let v): return .uint(v)
        case .uint8(let v): return .uint8(v)
        case .uint16(let v): return .uint16(v)
        case .uint32(let v): return .uint32(v)
        case .uint64(let v): return .uint64(v)
        case .outOfLineData(let index): return .outOfLineData(index)
        case .key, .containerKind:
            throw OverlayCoderError.unknownTag(OverlayTag.key.rawValue)
        case .containerReference(let id):
            guard let child = all[id] else {
                throw OverlayCoderError.danglingContainerReference(id)
            }
            // The format cannot express a cycle -- each id is referenced once, which
            // the reader enforces -- but resolving is recursive, so guard anyway
            // rather than trusting a hostile stream.
            guard resolving.insert(id).inserted else {
                throw OverlayCoderError.duplicateContainerReference(id)
            }
            defer { resolving.remove(id) }
            return .container(try node(child, all, &resolving))
        }
    }
}
