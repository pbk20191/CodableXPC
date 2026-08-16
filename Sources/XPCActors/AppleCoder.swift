#if canImport(Darwin)
import XPC

// ===========================================================================================
// MARK: - Apple's overlay coder, bound directly
// ===========================================================================================
//
// `XPCDictionary.encode(_:forKey:withUserInfo:)` and `.decode(as:forKey:withUserInfo:)` are the
// `userInfo`-carrying coder Apple's own `Payload.init(encoding:userInfo:)` calls. They are
// exported from `libswiftXPC.dylib` on macOS 26+ (both `T` in the export trie) but absent from
// the public `.swiftinterface`, so there is no declaration to call. Both are generic instance
// methods over *public* types (`XPCDictionary`, `String`, `[CodingUserInfoKey:Any]`,
// `Encodable`/`Decodable`), which is what makes them bindable: declaring the method with its
// true Swift signature lets the compiler emit the exact calling convention -- self, generic
// metadata and witness, `throws` -- rather than us asserting one and being wrong.
//
// Bound with `@_silgen_name` because a generic method cannot be reached through `dlsym` without
// hand-passing metadata and witness tables. That makes these a load-time dependency: on an OS
// that dropped the symbols, dyld would refuse to launch. That is acceptable *here* only because
// this package's floor is macOS 26, where both symbols are present -- and it is what lets
// `XPCActors` carry its own wire coding with no dependency on the `XPCOverlayCoder`
// reconstruction.

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCDictionary {

    /// Apple's `XPCDictionary.encode<A: Encodable>(_:forKey:withUserInfo:)`.
    @_silgen_name("$s3XPC13XPCDictionaryV6encode_6forKey12withUserInfoyx_SSSDys06CodingghE0VypGtKSERzlF")
    func appleEncode<A: Encodable>(
        _ value: A, forKey key: String, withUserInfo userInfo: [CodingUserInfoKey: Any]) throws

    /// Apple's `XPCDictionary.decode<A: Decodable>(as:forKey:withUserInfo:)`.
    @_silgen_name("$s3XPC13XPCDictionaryV6decode2as6forKey12withUserInfoxxm_SSSDys06CodinghiF0VypGtKSeRzlF")
    func appleDecode<A: Decodable>(
        as type: A.Type, forKey key: String, withUserInfo userInfo: [CodingUserInfoKey: Any]
    ) throws -> A
}
#endif
