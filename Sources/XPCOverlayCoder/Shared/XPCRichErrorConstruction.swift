import Foundation
import XPC

/// Making an `XPCRichError` when you are the one reporting the failure.
///
/// ## `xpc_rich_error_create` exists, but not where anything can reach it
///
///     xpc_rich_error_create(const char *description, char canRetry)
///       -> _xpc_try_strdup, then xpc_rich_error_create_no_copy
///       -> _xpc_base_create(OS_xpc_rich_error, 24)
///
/// It is a **local** symbol — lowercase `t` in the symbol table, at a fixed
/// offset — so it is in neither the export trie nor the SDK's `.tbd`. `dlsym`
/// cannot see it and `@_silgen_name` cannot link it. Only three rich-error
/// symbols are exported: the type descriptor, `xpc_rich_error_can_retry` and
/// `xpc_rich_error_copy_description`.
///
/// Its address can still be had — sliding from an exported neighbour by the
/// delta the symbol table records does work, and the call returns a genuine
/// `xpc_rich_error_t` — but that delta is a property of one build of one
/// binary, and nothing checks it before jumping.
///
/// ## Which is why this does not use it
///
/// `XPCRichError` does not hold an `xpc_rich_error_t`. The overlay's own
/// `XPCRichError.init(_:)` takes one only to copy two values out of it —
/// `xpc_rich_error_copy_description` into a `String` and
/// `xpc_rich_error_can_retry` into a `Bool` — and keeps nothing else. A real
/// instance reflects as exactly that pair, in 24 bytes: the `Bool` at offset 0,
/// padded, then the `String`.
///
/// So one can be built without libxpc at all — no address arithmetic, nothing
/// that moves between builds. What that gives you is an error to *throw*,
/// indistinguishable from the framework's own to anything that catches it. It is
/// not something to hand back to XPC, which never takes one.
///
/// If you need a real `xpc_rich_error_t` for a C API rather than a Swift error
/// to raise, this is the wrong tool and the offset route above is the only one.
///
/// ## The other error type has no creator at all
///
/// `xpc_error` — the classic `XPC_TYPE_ERROR` a connection handler receives — is
/// not created by anyone, exported or otherwise. Searching the whole symbol
/// table for a name containing both "error" and "create" returns exactly one
/// entry, the local `_xpc_rich_error_create` above. What libxpc exports instead
/// are the four singletons themselves, as data:
/// `XPC_ERROR_CONNECTION_INTERRUPTED`, `XPC_ERROR_CONNECTION_INVALID`,
/// `XPC_ERROR_TERMINATION_IMMINENT` and the peer-code-signing one, plus
/// `XPC_ERROR_KEY_DESCRIPTION` and the type descriptor. They are values to
/// recognise and pass along, never a family to add to.
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
