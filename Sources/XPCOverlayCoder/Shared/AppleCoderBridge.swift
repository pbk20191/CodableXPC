import Foundation
import XPC

/// Hands a raw message dictionary to Apple's own overlay coder, in-process.
///
/// ## Why this is possible at all
///
/// `XPCReceivedMessage.init(dictionary:)` is exported from `libswiftXPC.dylib` on
/// macOS 26+ / iOS 26+ — it is in the `.tbd` the linker reads — but it is absent
/// from the public `.swiftinterface`, so there is no declaration to call. Both
/// its parameter and its result are public types, though, which is what makes
/// the gap bridgeable: declaring a Swift function with the same Swift signature
/// lets the compiler emit the calling convention, instead of us asserting one
/// and being wrong.
///
/// ## On the older builds it is there but not exported
///
/// iOS 18 has the same initialiser under the same mangled name as a **local**
/// symbol, so `dlsym` returns nil and ``isAvailable`` reports `false`. That is
/// linkage, not absence — the code is there and runs — but no shippable code can
/// reach it. `dlsym` sees only exports and `@_silgen_name` needs the `.tbd`,
/// which leaves the address, and the address cannot be discovered in process:
/// on a device `libswiftXPC` lives in the dyld shared cache with no on-disk file
/// and no local symbol table mapped. It was callable here only because the
/// *simulator* ships a real dylib that `nm` can read offline, and the offset
/// that came from belongs to that one build.
///
/// None of which costs anything, because the older builds need no bridge: they
/// export the byte-level `XPCEncoder`/`XPCDecoder` outright, which is a
/// name-resolvable route and what the iOS 18 harness uses.
///
/// iOS 17 is unverified either way. Only a decompile is to hand, and that same
/// tool reports no such initialiser for iOS 18, where the binary demonstrably
/// has one — so its silence is not evidence.
///
/// ## Why the *encoder* is not here
///
/// The symmetric entry point is `XPCReceivedMessage.encodeMessage`, which builds
/// the whole envelope in one call. It cannot be reached this way, on any build:
/// it is an internal static helper exported under no name at all — absent from
/// the linker's `.tbd` and from the runtime export trie alike — so there is
/// nothing to bind. ``OverlayEnvelope/message(_:isSync:)`` reimplements it
/// instead, five keys, checked against the disassembly and then against real
/// output.
///
/// It also changed shape, which is worth recording because it is the clearest
/// statement of what each generation considered public:
///
///     // iOS 17 and iOS 18 — identical, register for register
///     encodeMessage<A>(_:isSync:)
///       (a1@X0 value, a2@W1 isSync, a3@X2 metadata, a4@X3 witness, a5@X8 sret)
///
///     // iOS 26+ — a parameter inserted, shifting everything along
///     encodeMessage<A>(_:userInfo:isSync:)
///       (X0 value, a1@X1 userInfo, a2@W2 isSync, a3@X3 metadata, a5@X8 sret)
///
/// The older pair take no `userInfo` because a caller had no way to supply one:
/// their message layer exports no `send(_:userInfo:)`, no `reply(_:userInfo:)`
/// and no `decode(as:userInfo:)` — zero of the three, against all three on the
/// newer builds. `userInfo` was reachable there only through the byte-level
/// `XPCEncoder`/`XPCDecoder`, which those builds export and the newer ones
/// deleted. The two generations trade which layer is public, and this bridge
/// exists because of which half is left.
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

    /// Looked up in `libswiftXPC` by name rather than through `RTLD_DEFAULT`, so
    /// the image the symbol comes from is written down rather than searched for.
    ///
    /// It has to be `libswiftXPC`: the name is mangled into module `XPC`, and
    /// `libswiftCore` does not export it. That mistake compiles, builds, and
    /// leaves `isAvailable` permanently `false` — the whole bridge disabled with
    /// no diagnostic, and every test that depends on it reporting a skip.
    ///
    /// The handle is not closed on success, because the function pointer lives in
    /// that image. Closing it is harmless in practice — this module's own
    /// `import XPC` holds the image open regardless, which is also why the
    /// `dlopen` cannot fail here — but using a pointer into an image you have
    /// released is not something to rely on being harmless.
    private static let receivedMessageInit: MakeReceivedMessage? = {
        // "$s3XPC18XPCReceivedMessageV10dictionaryAcA13XPCDictionaryV_tcfC"
        // = XPC.	.init(dictionary: XPC.XPCDictionary) -> …
        let mangled = "$s3XPC18XPCReceivedMessageV10dictionaryAcA13XPCDictionaryV_tcfC"
        guard let image = dlopen("/usr/lib/swift/libswiftXPC.dylib", RTLD_NOW | RTLD_LOCAL)
        else { return nil }
        guard let symbol = dlsym(image, mangled) else {
            dlclose(image)
            return nil
        }
        return unsafeBitCast(symbol, to: MakeReceivedMessage.self)
    }()
}
