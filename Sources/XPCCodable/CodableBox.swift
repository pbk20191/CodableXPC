import Foundation

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
/// its payload type into every archive it appears in (`_TtGC6MyMod10CodableBox…`),
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
///         func greet(_ person: CodableBox, reply: @escaping (CodableBox?, Error?) -> Void)
///     }
///
/// - Note: Do not try to swap the decoded object for another type from
///   `awakeAfter(using:)`. It works under `NSKeyedUnarchiver`, but `NSXPCDecoder`
///   crashes with `EXC_BAD_ACCESS` inside `swift_retain`.
@objc(CodableBox)
public final class CodableBox: NSObject, NSSecureCoding {

    /// The encoded payload. JSON, per the note above.
    public let payload: Data

    public class var supportsSecureCoding: Bool { true }

    public init(payload: Data) {
        self.payload = payload
    }

    /// The encoder used when the caller does not supply one.
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

    /// Encode `value` into a new box.
    public convenience init<Value: Encodable>(_ value: Value) throws {
        self.init(payload: try CodableBox.defaultEncoder().encode(value))
    }

    /// Encode `value` with a caller-supplied encoder, for date and key strategies.
    public convenience init<Value: Encodable>(_ value: Value, encoder: JSONEncoder) throws {
        self.init(payload: try encoder.encode(value))
    }

    /// Decode the payload back into `Value`.
    public func decode<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        try JSONDecoder().decode(type, from: payload)
    }

    /// Decode with a caller-supplied decoder, matching whatever encoded it.
    public func decode<Value: Decodable>(_ type: Value.Type = Value.self, decoder: JSONDecoder) throws -> Value {
        try decoder.decode(type, from: payload)
    }

    // MARK: NSSecureCoding

    // Keyed, not `encode(_:)` / `decodeData()`. The unkeyed pair does work — an
    // NSKeyedArchiver generates positional keys for it — but it gives the payload
    // no name in the archive, which makes the format impossible to evolve and
    // unreadable in a plist dump.
    private enum Key {
        static let payload = "payload"
    }

    public func encode(with coder: NSCoder) {
        coder.encode(payload, forKey: Key.payload)
    }

    public required init?(coder: NSCoder) {
        guard let data = coder.decodeObject(of: NSData.self, forKey: Key.payload) as Data? else {
            return nil
        }
        self.payload = data
    }

    // MARK: Equality — deliberately inherited

    // There is no `isEqual:` override here, and that is a decision rather than an
    // omission. Comparing payload bytes looks like value equality but is not: the
    // same value encodes differently under a different `JSONEncoder`, a different
    // key strategy, or — before `.sortedKeys` above — a different process. An
    // equality that is right most of the time is worse than identity, which is at
    // least predictable. Compare the decoded values instead.

    public override var description: String {
        "CodableBox(\(payload.count) bytes)"
    }
}
