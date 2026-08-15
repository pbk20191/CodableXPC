import Foundation
import XPC

/// The three envelope keys, and the whole of the envelope.
///
/// Both header names are Swift small strings built from `movz`/`movk` immediates in
/// Apple's `Packet.(Header).write(to:)` (`0x2ad4e134c`), which is why neither appears in
/// any string table and why they went unnoticed for so long. They were decoded from the
/// immediates at their two call sites.
///
/// Not exhaustive on the receiving side: ``Packet/init(rawValue:)`` validates these
/// three and ignores any other key it finds. Apple's decoder is lenient in exactly the
/// same way -- it checks the three it wants and looks at nothing else -- so the leniency
/// is now interop rather than a hedge against our own future versions. There are no
/// versions.
///
/// ## There is no version key, and that is a real loss
///
/// A `version` entry used to sit alongside these, and it is gone because
/// `XPCDistributed` has none: a peer receiving one would be reading a key it has no case
/// for. It existed to catch exactly the failure this whole exercise is a reconstruction
/// of -- two builds of a protocol drifting apart with nothing in the format able to
/// notice. Apple's own `SharedActorKey` coding changed shape between two observable
/// builds and no receiver could have told. Interop buys peer compatibility and pays for
/// it with that detector; nothing replaces it, and the only remaining guard is the
/// golden fixtures in this package's tests.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public enum EnvelopeKey {
    public static let headerCategory = "headerCategory"
    public static let headerID = "headerID"
    public static let payload = "payload"
}

/// `Transport.Packet.Header`, modelled as Apple models it.
///
/// The presence rules that our previous `{ version, kind, seq }` header *checked* in a
/// failable initializer are unrepresentable here instead: a notification has no id
/// because the case has no payload, and a request cannot be built without one.
///
/// The associated value is an ``ID64`` because that is what Apple's enum carries. It is
/// a bare `UInt64` wherever it is coded, and the header is not coded at all -- it is
/// written as native xpc entries -- so the choice is about modelling, not bytes.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public enum PacketHeader: Hashable, Sendable {
    case request(ID64)
    case response(ID64)
    case notification

    /// The `headerCategory` value. **Not the enum tag.**
    ///
    /// Apple's `Packet.Header` is a multi-payload enum whose tags are `request` 0,
    /// `response` 1, `notification` 2 -- resolved from four independent call sites, not
    /// from declaration order -- and `write(to:)` renumbers them on the way out. Writing
    /// the tag instead would send a request that every peer reads as a notification.
    public enum Category: UInt64, Sendable {
        case notification = 0
        case request = 1
        case response = 2
    }

    public var category: Category {
        switch self {
        case .request: return .request
        case .response: return .response
        case .notification: return .notification
        }
    }

    /// The correlation id, or `nil` for a notification -- which is the case that has
    /// none, not a case whose id happens to be absent.
    public var id: ID64? {
        switch self {
        case .request(let id), .response(let id): return id
        case .notification: return nil
        }
    }
}

/// One wire message: three native entries of a single xpc dictionary, or two for a
/// notification.
///
/// The header is not `Codable`, does not go through the overlay byte stream, and is not
/// nested under anything. `Packet.rawValue` in the shipping framework copies
/// `payload.dictionary` into the result and tail-calls `Header.write(to:)` on that copy,
/// which is why the payload's own single `"payload"` entry *is* the envelope's third
/// entry rather than sitting beneath one.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public struct Packet: @unchecked Sendable {
    public let header: PacketHeader
    public let payload: Payload

    public init(header: PacketHeader, payload: Payload) {
        self.header = header
        self.payload = payload
    }

    /// Parse and validate. Returns `nil` for anything that does not satisfy the
    /// envelope contract; the caller drops such messages.
    ///
    /// Every rule here is a rejection rather than a default, matching
    /// `Header.init(from:)`: a missing `headerCategory` rejects; `0` is a notification
    /// and `headerID` is never read; `1` and `2` require `headerID`; anything `>= 3`
    /// rejects; and all three kinds require `payload`.
    public init?(rawValue: xpc_object_t) {
        guard xpc_get_type(rawValue) == XPC_TYPE_DICTIONARY,
              let rawCategory = Packet.uint64(rawValue, EnvelopeKey.headerCategory),
              let category = PacketHeader.Category(rawValue: rawCategory)
        else { return nil }

        switch category {
        case .notification:
            // `headerID` is deliberately not read, present or not. A decoder that
            // rejected a surplus id would drop traffic a real peer accepts.
            header = .notification
        case .request, .response:
            guard let id = Packet.uint64(rawValue, EnvelopeKey.headerID) else { return nil }
            header = category == .request
                ? .request(ID64(rawValue: id))
                : .response(ID64(rawValue: id))
        }

        // Presence only, no type check: the body is an overlay envelope rather than a
        // structure this layer understands, and Apple asks only `contains(key:)`.
        guard let body = xpc_dictionary_get_value(rawValue, EnvelopeKey.payload)
        else { return nil }
        payload = Payload(body: body)
    }

    public var rawValue: xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        // The payload contributes its one entry, under the same key it stores it by.
        //
        // A trap, not a silent short message. `decode` already throws `.payloadHasNoBody`
        // for this, and emitting a message every receiver drops -- with no error on this
        // side and nothing on the wire to explain it -- is the worse of the two failures.
        // Unreachable through the public API: only `init(unchecked:)` can build a body-less
        // payload, and that is test-only.
        guard let body = payload.body else {
            preconditionFailure("a packet cannot be sent with a payload that has no body")
        }
        xpc_dictionary_set_value(dictionary, EnvelopeKey.payload, body)
        xpc_dictionary_set_uint64(dictionary, EnvelopeKey.headerCategory,
                                  header.category.rawValue)
        if let id = header.id {
            // Absent, never null: assigning nil through Apple's `XPCDictionary`
            // subscript leaves the key out, so a notification is a two-entry message.
            xpc_dictionary_set_uint64(dictionary, EnvelopeKey.headerID, id.rawValue)
        }
        return dictionary
    }

    /// Read a uint64, distinguishing "absent" from "zero".
    ///
    /// `xpc_dictionary_get_uint64` returns 0 for a missing key and for a key of the
    /// wrong type, so it cannot be used here: a message with no `headerCategory` would
    /// parse as a notification, which is the one kind that needs no other field.
    static func uint64(_ dictionary: xpc_object_t, _ key: String) -> UInt64? {
        guard let value = xpc_dictionary_get_value(dictionary, key),
              xpc_get_type(value) == XPC_TYPE_UINT64
        else { return nil }
        return xpc_uint64_get_value(value)
    }
}
