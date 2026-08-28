import Foundation
#if canImport(XPC)
import XPC
import ObjectiveC

private extension NSData {
    @NSManaged func _canReplaceWithDispatchDataForXPCCoder() -> Bool
    /// `Unmanaged` because this returns +1 -- see ``DispatchDataBridge``.
    @NSManaged func _createDispatchData() -> Unmanaged<__DispatchData>
}

/// Builds the `xpc_data` for a `Data`, taking the cheaper of two copies.
///
/// Its own target because two coders need it and neither should depend on the
/// other: `CodableXPC` builds a native object graph, `XPCOverlayCoder`
/// reproduces Apple's wire formats, and they are deliberately independent.
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
/// ## Declared, not looked up
///
/// `@NSManaged` says "something else provides this at runtime", so the compiler
/// emits the `objc_msgSend` with the right types — no `dlsym`, no hand-cast
/// function pointer, and `BOOL` comes back as `Bool`.
///
/// The return type has to be `Unmanaged`. `_createDispatchData` hands back +1,
/// and "create" is not one of the prefixes ARC infers a retain family from —
/// `alloc`, `new`, `copy`, `mutableCopy`, `init` — so declaring it as `-> NSData`
/// leaks every buffer: forty 8 MiB calls grew the footprint by 320.8 MiB,
/// against 8.1 with `takeRetainedValue`.
///
/// Swift has no way to say it otherwise. There is no return-ownership specifier;
/// `consuming` and `borrowing` describe parameters. Objective-C does have one,
/// and it works — a header declaring the selector
/// `NS_RETURNS_RETAINED` imports with the +1 consumed and leaks nothing (0.1 MiB
/// over the same forty calls), leaving a call site with no `Unmanaged` in it. It
/// would cost this package a C target and a public header to carry two private
/// selectors, which is more than one `takeRetainedValue` is worth.
///
/// ## Private, so guarded
///
/// Both selectors are SPI. Everything is resolved once and checked; if either
/// goes away, ``isAvailable`` turns false and every call takes the plain path.
/// The result is the same either way — the tests assert the two paths produce
/// identical bytes — so losing this costs speed and nothing else.
package enum DispatchDataBridge {
    /// Whether the substitution can be attempted at all on this OS.
    ///
    /// `@NSManaged` emits the call without checking anything, so a missing
    /// selector would be an unrecognised-selector crash rather than a fallback.
    /// This is what makes it a fallback.
    public static let isAvailable: Bool = {
        let probe = NSData()
        return probe.responds(to: #selector(NSData._canReplaceWithDispatchDataForXPCCoder)) && probe.responds(to: #selector(NSData._createDispatchData))
    }()

    /// The `xpc_data` for `data`, by whichever route is cheaper.
    public static func xpcData(for data: Data) -> xpc_object_t {
        if let substituted = substituting(data) { return substituted }
        return data.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
    }

    /// Internal rather than private so a test can observe which path ran, instead
    /// of inferring it from a timing.
    public static func substituting(_ data: Data) -> xpc_object_t? {
        guard isAvailable else { return nil }
        let bridged = data as NSData
        guard bridged._canReplaceWithDispatchDataForXPCCoder() else { return nil }

        let dispatchData = bridged._createDispatchData().takeRetainedValue()
        return xpc_data_create_with_dispatch_data(dispatchData)
    }

    /// The `DispatchData` for an `NSData`, without a copy where the object already is one.
    ///
    /// The first question -- "is this already a dispatch data?" -- is asked of the
    /// ObjC runtime rather than of SPI. An `NSData` that libdispatch or libxpc handed
    /// back *is* an `OS_dispatch_data`, so a conditional cast answers it, and measured
    /// here it gives the same answer `_isDispatchData` gives for every shape this
    /// package can produce: `_NSZeroData`, `_NSInlineData`, `__NSSwiftData`,
    /// `NSConcreteMutableData`, and dispatch data both flat and concatenated. A public
    /// runtime cast cannot go missing under an OS update, and a `nil` from it costs a
    /// copy rather than the process -- neither of which is true of a private selector
    /// answered with a force-cast.
    ///
    /// Everything past that is the substitution ``substituting(_:)`` already makes,
    /// behind the same two gates: ``isAvailable``, so a removed selector falls back
    /// instead of crashing, and Apple's own `_canReplaceWithDispatchDataForXPCCoder`
    /// threshold, so a small object is not run through it for nothing. When either
    /// says no, a plain `DispatchData` copy is the answer; it is always correct and
    /// only ever costs speed, which is the same trade the rest of this type makes.
    public static func dispatchData(_ data: NSData) -> DispatchData {
        if let already = data as AnyObject as? DispatchData { return already }

        if isAvailable, data._canReplaceWithDispatchDataForXPCCoder() {
            return data._createDispatchData().takeRetainedValue() as DispatchData
        }

        return withExtendedLifetime(data) {
            DispatchData(bytes: UnsafeRawBufferPointer(start: data.bytes, count: data.length))
        }
    }
}
#endif
