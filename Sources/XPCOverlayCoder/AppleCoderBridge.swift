import Foundation
import XPC

/// Hands a raw message dictionary to Apple's own overlay coder, in-process.
///
/// ## Why this is possible at all
///
/// `XPCReceivedMessage.init(dictionary:)` is exported from `libswiftXPC.dylib` —
/// it is in the `.tbd` the linker reads — but it is absent from the public
/// `.swiftinterface`, so there is no declaration to call. Both its parameter and
/// its result are public types, though, which is what makes the gap bridgeable:
/// declaring a Swift function with the same Swift signature lets the compiler
/// emit the calling convention, instead of us asserting one and being wrong.
///
/// ## Why the *encoder* is not here
///
/// The symmetric entry point is `XPCReceivedMessage.encodeMessage(_:userInfo:isSync:)`,
/// which builds the whole envelope in one call. It cannot be reached this way: it
/// is an internal static helper and is exported under no name at all, so there is
/// nothing for the linker to bind. ``OverlayEnvelope/message(_:isSync:)``
/// reimplements it instead — five keys, verified against the disassembly.
///
/// ## What it is for
///
/// Checking this module's output against the real decoder without standing up an
/// `XPCListener` and an `XPCSession`. That round trip works, but it is a live
/// connection in a test, and it can only carry a message the framework agrees to
/// send. This path takes any dictionary at all, including deliberately malformed
/// ones.
@available(macOS 14, macCatalyst 17, *)
public enum AppleCoderBridge {

    /// Whether the private symbol resolved. `false` means the OS moved and every
    /// call below will return `nil`.
    public static var isAvailable: Bool { receivedMessageInit != nil }

    /// Decode a message dictionary with Apple's coder rather than this module's.
    ///
    /// - Returns: `nil` when the symbol is unavailable, which is distinct from a
    ///   decode failure — that throws.
    public static func decode<T: Decodable>(_ type: T.Type = T.self,
                                            from message: xpc_object_t) throws -> T? {
        guard let make = receivedMessageInit else { return nil }
        return try make(XPCDictionary(message)).decode(as: type)
    }

    /// Resolved through `dlsym` rather than declared with `@_silgen_name`.
    ///
    /// `@_silgen_name` links fine and runs fine — that is how this was first
    /// proven — but it turns the symbol into a load-time dependency. On an OS that
    /// dropped it, dyld would kill the process at launch, before any code of ours
    /// could report anything. A missing symbol should cost a consumer this one
    /// feature, not their whole binary.
    ///
    /// The parameter is `__owned`, and that word is the whole difference between
    /// this working and crashing.
    ///
    /// An initialiser stores its argument, so it takes it at +1 and releases it.
    /// Written without `__owned` the call site passes `@guaranteed`, the callee
    /// releases a reference the caller still holds, and the process dies later in
    /// `swift_unknownObjectRelease` on an object that is already gone — far from
    /// the call, with a one-frame stack, and only for some value shapes. A single
    /// `String` field survived it; a single `Int` did not.
    ///
    /// `@convention(thin)` is the convention of a Swift function that captures
    /// nothing. A struct initialiser also takes a `@thin` metatype in the self
    /// position, but an empty thin metatype occupies no register, so the lowered
    /// signature is exactly the one written here.
    private typealias MakeReceivedMessage =
        @convention(thin) (__owned XPCDictionary) -> XPCReceivedMessage

    private static let receivedMessageInit: MakeReceivedMessage? = {
        // "$s3XPC18XPCReceivedMessageV10dictionaryAcA13XPCDictionaryV_tcfC"
        // = XPC.XPCReceivedMessage.init(dictionary: XPC.XPCDictionary) -> …
        let mangled = "$s3XPC18XPCReceivedMessageV10dictionaryAcA13XPCDictionaryV_tcfC"
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), mangled) else {
            return nil
        }
        return unsafeBitCast(symbol, to: MakeReceivedMessage.self)
    }()
}
