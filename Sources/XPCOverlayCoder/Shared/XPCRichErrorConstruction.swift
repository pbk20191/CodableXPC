import Foundation
import XPC

/// Making an `XPCRichError` when you are the one reporting the failure.
///
/// ## There is no `xpc_rich_error_create`
///
/// Checked five ways and it is absent from all of them: `dlsym` at runtime on
/// macOS 27 and in an iOS 26.5 simulator, the full symbol table of an iOS 18.6
/// `libxpc` including local symbols, every `.tbd` in the SDK, and every SDK
/// header. libxpc exports exactly three rich-error symbols — the type
/// descriptor, `xpc_rich_error_can_retry` and `xpc_rich_error_copy_description`
/// — and carries the usual internal type callbacks (`_copy`, `_dispose`,
/// `_serialize`…) but no creator under any name.
///
/// ## Which turns out not to matter
///
/// `XPCRichError` does not hold an `xpc_rich_error_t`. The overlay's own
/// `XPCRichError.init(_:)` takes one only to copy two values out of it —
/// `xpc_rich_error_copy_description` into a `String` and
/// `xpc_rich_error_can_retry` into a `Bool` — and keeps nothing else. A real
/// instance reflects as exactly that pair, in 24 bytes: the `Bool` at offset 0,
/// padded, then the `String`.
///
/// So one can be built without libxpc at all. What that gives you is an error to
/// *throw*, indistinguishable from the framework's own to anything that catches
/// it. It is not something to hand back to XPC, which never takes one.
///
/// ## The guard
///
/// This depends on a layout nothing documents. Rather than trust it, every call
/// builds the value and reads it back through Apple's own accessor: if a field
/// were added or moved, the readback stops matching and this returns `nil`
/// instead of handing over a corrupt value.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension XPCRichError {

    /// A rich error carrying `description`, or `nil` if the layout this relies on
    /// no longer holds.
    public static func make(_ description: String, canRetry: Bool = false) -> XPCRichError? {
        guard MemoryLayout<Layout>.size == MemoryLayout<XPCRichError>.size,
              MemoryLayout<Layout>.stride == MemoryLayout<XPCRichError>.stride
        else { return nil }

        let forged = unsafeBitCast(Layout(canRetry: canRetry, description: description),
                                   to: XPCRichError.self)

        // Read back through the real accessors before handing it over.
        guard forged.canRetry == canRetry,
              String(describing: forged) == description
        else { return nil }
        return forged
    }

    /// Whether ``make(_:canRetry:)`` can work on this OS. `false` means Apple
    /// changed the type and every call returns `nil`.
    public static var isConstructible: Bool { make("layout probe", canRetry: true) != nil }

    /// The stored properties of `XPCRichError`, in declaration order — which is
    /// also memory order here, and why the type is 24 bytes rather than the 17 a
    /// `String` and a `Bool` would otherwise need.
    private struct Layout {
        var canRetry: Bool
        var description: String
    }
}
