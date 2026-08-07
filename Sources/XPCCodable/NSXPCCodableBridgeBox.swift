import Foundation
import XPC
import CodableXPC

/// Carries a `Codable` value across an `NSXPCConnection` or an `NSKeyedArchiver`.
///
/// NSXPC can only move `NSSecureCoding` objects, so a Swift `Codable` value has to
/// ride inside one. This is that box: encode on the way in, decode on the way out.
///
/// ## Why it is not generic
///
/// A generic Swift class cannot appear in an `@objc` protocol, and it cannot carry
/// `@objc(StableName)` either — the compiler rejects that with *"generic subclasses
/// of '@objc' classes cannot have an explicit '@objc' because they are not directly
/// visible from Objective-C"*. A generic box would also embed its module name and
/// its payload type into every archive it appears in (`_TtGC6MyMod21NSXPCCodableBridgeBoxVS_6Person_`),
/// so renaming either one silently breaks every stored archive and every peer built
/// from a different module.
///
/// One non-generic class with a pinned `@objc` name avoids all of that. The payload
/// type lives in the Swift generic parameter of ``init(_:)`` and ``decode(_:)``,
/// where it costs nothing at runtime.
///
/// ## Why JSON and not a property list
///
/// `PropertyListEncoder` cannot encode a top-level fragment: `String`, `Int`, and
/// `Optional` all fail with *"the data couldn't be written because it isn't in the
/// correct format"*. Anything that boxes arbitrary parameters — a generated XPC
/// shim, for instance — hits that on the first `String` argument. `JSONEncoder`
/// round-trips all of them.
///
/// ## Using it with NSXPC
///
/// Pass the box as a *direct* parameter of an `@objc` method and no
/// `setClasses(_:for:argumentIndex:ofReply:)` registration is needed — NSXPC allows
/// classes named in the signature automatically. Nesting a box inside an array or
/// dictionary does require registration.
///
///     @objc protocol Greeter {
///         func greet(_ person: NSXPCCodableBridgeBox, reply: @escaping (NSXPCCodableBridgeBox?, Error?) -> Void)
///     }
///
/// - Note: Do not try to swap the decoded object for another type from
///   `awakeAfter(using:)`. It works under `NSKeyedUnarchiver`, but `NSXPCDecoder`
///   crashes with `EXC_BAD_ACCESS` inside `swift_retain`.
/// The Objective-C name is prefixed and deliberately does not match the Swift one.
///
/// `NS` is Apple's reserved prefix; registering a third-party class under it squats
/// on their namespace and would collide outright if Apple ever shipped a class by
/// this name. `CXPC` is this package's prefix.
///
/// The name is pinned rather than left to Swift's mangling because it is written
/// into every archive the box appears in, and both peers of a connection have to
/// agree on it. Changing it after anything ships makes old archives unreadable.
@objc(CXPCCodableBridgeBox)
public final class NSXPCCodableBridgeBox: NSObject, NSSecureCoding {

    /// What the box is holding, which depends on where it came from and where it
    /// is going.
    ///
    /// Encoding is deferred rather than done at construction because the right
    /// representation depends on the coder, and the coder is not known until
    /// `encode(with:)` runs. An `NSXPCCoder` takes an `xpc_object_t` directly, so
    /// there is no reason to serialise; an `NSKeyedArchiver` needs bytes, and an
    /// `xpc_object_t` cannot be turned into bytes by any public API.
    private enum Storage {
        /// Outgoing, not yet encoded. Holds the value and a closure that can encode
        /// it either way once the coder reveals itself.
        case pending(encodeToXPC: () throws -> xpc_object_t, encodeToData: () throws -> Data)
        /// Arrived over NSXPC.
        case xpc(xpc_object_t)
        /// Arrived from an archive, or was built from bytes directly.
        case data(Data)
    }

    private let storage: Storage

    public class var supportsSecureCoding: Bool { true }

    /// Wrap bytes that are already an encoded payload.
    public init(payload: Data) {
        storage = .data(payload)
    }

    /// The JSON encoder used when the caller does not supply one.
    ///
    /// `.sortedKeys` is not cosmetic. Without it, `JSONEncoder` emits object keys in
    /// Swift `Dictionary` iteration order, which is seeded per process — the same
    /// value encodes to `{"name":…,"age":…}` in one run and `{"age":…,"name":…}` in
    /// the next. Sorting makes a payload reproducible, which is what lets you diff
    /// two captures, cache on the bytes, or compare a golden fixture.
    private static func defaultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    /// Encode `value` into a new box, choosing the representation later.
    public init<Value: Encodable>(_ value: Value) throws {
        storage = .pending(
            encodeToXPC: { try XPCEncoder().encode(value) },
            encodeToData: { try NSXPCCodableBridgeBox.defaultEncoder().encode(value) })
    }

    /// Encode `value` with a caller-supplied JSON encoder, for date and key
    /// strategies. Forces the bytes path: a custom `JSONEncoder` has no meaning for
    /// the native representation.
    public convenience init<Value: Encodable>(_ value: Value, encoder: JSONEncoder) throws {
        self.init(payload: try encoder.encode(value))
    }

    /// The encoded bytes, for a box that has them or can produce them.
    ///
    /// A box that arrived over NSXPC holds an `xpc_object_t`, which no public API
    /// can serialise, so this is `nil` for that case. Use ``decode(_:)`` instead —
    /// it works whatever the box is holding.
    public var payload: Data? {
        switch storage {
        case .data(let data): return data
        case .pending(_, let encodeToData): return try? encodeToData()
        case .xpc: return nil
        }
    }

    /// Decode the payload back into `Value`.
    public func decode<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        switch storage {
        case .xpc(let object):
            return try XPCDecoder().decode(type, from: object)
        case .data(let data):
            return try JSONDecoder().decode(type, from: data)
        case .pending(_, let encodeToData):
            // Round-tripping a box that never left the process. Rare, but it should
            // not be an error.
            return try JSONDecoder().decode(type, from: try encodeToData())
        }
    }

    /// Decode with a caller-supplied JSON decoder, matching whatever encoded it.
    public func decode<Value: Decodable>(_ type: Value.Type = Value.self, decoder: JSONDecoder) throws -> Value {
        guard let payload else {
            throw NSXPCCodableBridgeBoxError.nativePayloadNeedsNoJSONDecoder
        }
        return try decoder.decode(type, from: payload)
    }

    // MARK: NSSecureCoding

    private enum Key {
        static let payload = "payload"
    }

    /// Selectors on `NSXPCCoder`, which is not public API. Guarded by
    /// `responds(to:)` at every use, so a future OS that removes them falls back to
    /// the bytes path rather than crashing.
    private enum SPI {
        static let encode = NSSelectorFromString("encodeXPCObject:forKey:")
        static let decode = NSSelectorFromString("decodeXPCObjectForKey:")
    }

    @objc private protocol XPCCoderSPI {
        @objc(encodeXPCObject:forKey:) func encodeXPCObject(_ object: xpc_object_t, forKey key: String)
        @objc(decodeXPCObjectForKey:) func decodeXPCObject(forKey key: String) -> xpc_object_t?
    }

    // Bitcast rather than cast: NSXPCCoder does not advertise conformance to
    // anything, so `as?` fails. The bitcast only ever forms an objc_msgSend, and it
    // is reached only after `responds(to:)` has confirmed the selector exists.
    private static func spi(_ coder: NSCoder) -> XPCCoderSPI {
        unsafeBitCast(coder, to: XPCCoderSPI.self)
    }

    public func encode(with coder: NSCoder) {
        // The native path skips JSON entirely: an NSXPC message is an xpc dictionary
        // already, so handing it one costs no serialisation.
        if coder.responds(to: SPI.encode), let object = try? nativeObject() {
            NSXPCCodableBridgeBox.spi(coder).encodeXPCObject(object, forKey: Key.payload)
            return
        }
        // Keyed, not `encode(_:)`. The unkeyed pair works — an NSKeyedArchiver
        // generates positional keys — but it leaves the payload unnamed in the
        // archive, which makes the format impossible to evolve.
        guard let payload else {
            coder.failWithError(NSXPCCodableBridgeBoxError.nativePayloadCannotBeArchived)
            return
        }
        coder.encode(payload, forKey: Key.payload)
    }

    public required init?(coder: NSCoder) {
        if coder.responds(to: SPI.decode),
           let object = NSXPCCodableBridgeBox.spi(coder).decodeXPCObject(forKey: Key.payload) {
            storage = .xpc(object)
            return
        }
        guard let data = coder.decodeObject(of: NSData.self, forKey: Key.payload) as Data? else {
            return nil
        }
        storage = .data(data)
    }

    private func nativeObject() throws -> xpc_object_t {
        switch storage {
        case .xpc(let object): return object
        case .pending(let encodeToXPC, _): return try encodeToXPC()
        case .data(let data): return try XPCEncoder().encode(data)
        }
    }

    // MARK: Equality — deliberately inherited

    // There is no `isEqual:` override here, and that is a decision rather than an
    // omission. Comparing payload bytes looks like value equality but is not: the
    // same value encodes differently under a different `JSONEncoder`, a different
    // key strategy, or — before `.sortedKeys` above — a different process. An
    // equality that is right most of the time is worse than identity, which is at
    // least predictable. Compare the decoded values instead.

    public override var description: String {
        switch storage {
        case .data(let data): return "NSXPCCodableBridgeBox(\(data.count) bytes)"
        case .xpc: return "NSXPCCodableBridgeBox(native xpc)"
        case .pending: return "NSXPCCodableBridgeBox(pending)"
        }
    }
}

/// Failures specific to how a box is carrying its payload.
public enum NSXPCCodableBridgeBoxError: Error, Equatable {
    /// The box arrived over NSXPC and holds an `xpc_object_t`. No public API turns
    /// one into bytes, so it cannot be written to an archive or read with a
    /// `JSONDecoder`. Use ``NSXPCCodableBridgeBox/decode(_:)``.
    case nativePayloadCannotBeArchived
    case nativePayloadNeedsNoJSONDecoder
}

@propertyWrapper
public struct XPCCodableMarker<T:Codable>: Codable {
    
    public var wrappedValue: T
    
    public init(wrappedValue: T) {
        self.wrappedValue = wrappedValue
    }
    
    public init(from decoder: any Decoder) throws {
        self.wrappedValue = try decoder.singleValueContainer().decode(T.self)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
    
}

extension KeyedEncodingContainer {
    
    public mutating func encode<T>(_ value: XPCCodableMarker<T>, forKey key: K) throws {
        try self.encode(value.wrappedValue, forKey: key)
    }
    
}

extension XPCCodableMarker: Hashable where T:Hashable {}
extension XPCCodableMarker: Equatable where T:Equatable {}
extension XPCCodableMarker: Sendable where T: Sendable {}
extension XPCCodableMarker: BitwiseCopyable where T: BitwiseCopyable {}

/// Marks a parameter or return value that should cross as an NSXPC **proxy**
/// rather than as data.
///
/// `@XPCService` turns the position into
/// `NSXPCInterface.setInterface(_:for:argumentIndex:ofReply:)`, which is what
/// tells NSXPC to vend the object instead of trying to encode it.
///
///     @XPCService
///     public protocol Auditor {
///         func attach(_ ledger: XPCProxyMarker<AuditLedgerXPCShim>)
///     }
///
/// ## What `Service` may be
///
/// `AnyObject` is the constraint, and it admits exactly what NSXPC can vend: an
/// `@objc` protocol, or a class. Measured — an `@objc` protocol's existential
/// passes because those self-conform and are class-bound, while a plain Swift
/// protocol does not, `AnyObject`-refined or otherwise.
///
/// So a Swift-native `@XPCService` protocol cannot be named here. Name its
/// generated shim instead, which is `@objc` and does qualify. The object arrives
/// as that shim, and one line turns it back into the Swift protocol, with the
/// ``lifetime`` supplying the failure channel:
///
///     func attach(_ ledger: XPCProxyMarker<AuditLedgerXPCShim>) {
///         let peer = AuditLedgerXPCClient(proxy: ledger.wrappedValue,
///                                         lifetime: ledger.lifetime)
///     }
///
/// That line is the price of a constraint that actually holds. The alternative
/// was for the macro to assume every named protocol was `@XPCService` and emit
/// `<Name>XPCShim` on faith, which no type could check and which shut out every
/// `@objc` protocol anyone already had.
public struct XPCProxyMarker<Service: AnyObject> {
    public var wrappedValue: Service

    /// The failure channel the proxy itself does not have.
    ///
    /// A proxy is not a connection: no error handler, and when the connection it
    /// arrived over dies, calls on it neither reply nor fail. The adapter that
    /// received it knows that connection and records invalidation here. On a
    /// marker you construct yourself — sending, rather than receiving — it is
    /// ``XPCProxyLifetime/unbounded``, which never fails.
    public var lifetime: XPCProxyLifetime

    public init(wrappedValue: Service, lifetime: XPCProxyLifetime = .unbounded) {
        self.wrappedValue = wrappedValue
        self.lifetime = lifetime
    }
}
