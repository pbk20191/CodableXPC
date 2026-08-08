import Foundation
#if canImport(XPC)
import XPC
import ObjectiveC

/// Builds the `xpc_data` for a `Data`, taking the cheaper of two copies.
///
/// `xpc_data_create` copies the bytes itself. Handing libxpc a `dispatch_data_t`
/// instead lets it take ownership of a buffer that was copied by dispatch, which
/// is cheaper at size — measured on this machine, per call:
///
///     64 KiB   0.018 ms -> 0.004 ms
///      1 MiB   0.092 ms -> 0.014 ms
///     64 MiB   5.123 ms -> 2.370 ms
///
/// It is not zero-copy, and it cannot be. A Swift `Data` is never backed by
/// dispatch data — it bridges to `__NSSwiftData`, while an `NSData` built in
/// Objective-C at size *is* an `OS_dispatch_data` — so there is nothing to hand
/// over for free. This trades libxpc's copy for dispatch's, which is vm-based
/// once the payload is large enough to matter.
///
/// For a genuinely zero-copy payload the caller has to own the buffer's
/// lifetime, which means holding a `DispatchData` and passing the object
/// through ``XPCNativeObject``.
///
/// ## Why the threshold is not ours
///
/// `NSData` answers `_canReplaceWithDispatchDataForXPCCoder`, a selector that
/// exists for exactly this substitution — Apple's own XPC coder asks it. It says
/// no below about 64 KiB, where the substitution would cost more than it saves,
/// so there is no constant to pick or to keep up to date.
///
/// ## Private, so guarded
///
/// Both selectors are SPI. Everything is resolved once and checked; if either
/// goes away, ``isAvailable`` turns false and every call takes the plain path.
/// The result is the same either way — the tests assert the two paths produce
/// identical bytes — so losing this costs speed and nothing else.
enum DispatchDataBridge {

    private static let canReplace = NSSelectorFromString("_canReplaceWithDispatchDataForXPCCoder")
    private static let createDispatchData = NSSelectorFromString("_createDispatchData")

    /// `objc_msgSend` typed twice, because the two selectors differ in return
    /// and one of them is `BOOL`, which `perform(_:)` cannot express.
    private typealias AskBool = @convention(c) (AnyObject, Selector) -> Bool
    private typealias MakeObject = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?

    private static let entryPoints: (ask: AskBool, make: MakeObject)? = {
        guard let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend"),
              NSData().responds(to: canReplace),
              NSData().responds(to: createDispatchData)
        else { return nil }
        return (unsafeBitCast(send, to: AskBool.self), unsafeBitCast(send, to: MakeObject.self))
    }()

    /// Whether the substitution can be attempted at all on this OS.
    static var isAvailable: Bool { entryPoints != nil }

    /// The `xpc_data` for `data`, by whichever route is cheaper.
    static func xpcData(for data: Data) -> xpc_object_t {
        if let substituted = substituting(data) { return substituted }
        return data.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
    }

    /// Internal rather than private so a test can observe which path ran, instead
    /// of inferring it from a timing or from a BOOL selector called through
    /// `perform(_:)`, which reinterprets the boolean as a pointer.
    static func substituting(_ data: Data) -> xpc_object_t? {
        guard let entry = entryPoints else { return nil }
        let bridged = data as NSData
        guard entry.ask(bridged, canReplace) else { return nil }

        // `_createDispatchData` hands back +1. Taking it as a plain `AnyObject`
        // lets ARC treat it as +0 and over-release, which segfaults well away
        // from here -- `Unmanaged` is what makes the ownership explicit, since
        // "create" is not one of the prefixes ARC infers a retain family from.
        guard let owned = entry.make(bridged, createDispatchData) else { return nil }
        let dispatchData = owned.takeRetainedValue()
        return xpc_data_create_with_dispatch_data(
            unsafeBitCast(dispatchData, to: __DispatchData.self))
    }
}
#endif
