#if NSXPCPrivateAPI
import Foundation

// ===========================================================================================
// MARK: - NSXPCConnection's private surface
// ===========================================================================================
//
// Behind the `NSXPCPrivateAPI` trait, which is off by default. The trait's declaration in
// `Package.swift` carries the argument for why; this file carries the measurements and the
// bindings.
//
// Nothing in the shipping code path uses any of this yet. It is bound here so that the
// coder-level boxing experiment can be run and tested without the default build -- and
// therefore without any consumer who has not asked -- containing a single reference to a
// private symbol.

// ===========================================================================================
// MARK: The delegate hook
// ===========================================================================================

/// `NSXPCConnection`'s undeclared delegate protocol.
///
/// **What was measured.** With an in-process `NSXPCListener`, a `Recorder` installed on both
/// ends via `setDelegate:`, and an `@objc` shim method taking `id`:
///
/// ```
/// HOOK[client] NSTaggedPointerString encoder=NSXPCEncoder
/// service received: NSTaggedPointerString = REPLACED     <- the substitution crossed
/// HOOK[server] NSTaggedPointerString encoder=NSXPCEncoder <- fires for the reply too
/// ```
///
/// So: the hook is consulted by `NSXPCEncoder` on the *sending* side for each `id` argument,
/// the object it returns is what the peer decodes, and replies go through it as well. Both
/// directions are interceptable, which is the whole reason this is interesting -- boxing could
/// move out of the generated shim signature and into the coder.
///
/// **The return value is not optional in practice, whatever the signature says.** Returning
/// nil raises `NSInvalidArgumentException` from `-[NSXPCEncoder _replaceObject:]`:
/// *"The replacement object must not be nil."* The stack goes
/// `_encodeUnkeyedObject:` → `replacementObjectForCoder:` → `_replaceObject:`. So an
/// implementation must return `object` unchanged for everything it does not want to touch;
/// reading nil as "no replacement" crashes on the first argument you leave alone.
///
/// It is declared optional here because the runtime treats it as optional -- a delegate that
/// does not implement it is fine, and that is the only sense in which nil is allowed.
@objc(NSXPCConnectionDelegate)
protocol NSXPCConnectionPrivateDelegate {

    /// Substitute `object` on its way into the encoder. **Must not return nil** -- see the
    /// type's documentation. Return `object` to leave it alone.
    @objc(replacementObjectForXPCConnection:encoder:object:)
    optional func replacementObject(
        for connection: NSXPCConnection, encoder: NSXPCCoder, object: Any
    ) -> Any?

    /// Present in the header this was read from, and **unavailable on purpose**: an
    /// `NSInvocation`-based hook cannot be implemented from Swift, which has no way to build
    /// or inspect one. Kept as a declaration so the protocol matches what the runtime expects
    /// rather than a subset of it.
    @available(*, unavailable)
    @objc(connection:handleInvocation:isReply:)
    optional func connection(
        _ connection: NSXPCConnection, handleInvocation: NSInvocation, isReply: Bool
    )
}

extension NSXPCConnection {

    /// `setDelegate:` / `delegate`, both present on `NSXPCConnection` in the Objective-C
    /// runtime (checked with `class_getInstanceMethod`).
    ///
    /// `weak`, matching every other Cocoa delegate: the connection must not keep the object
    /// that owns it alive. `@NSManaged` rather than `perform(_:with:)` so the accessor is
    /// typed and the compiler emits the right `objc_msgSend`.
    ///
    /// **The Swift name has to be `delegate`.** A `@NSManaged` property derives its selectors
    /// from its name, so calling this `privateDelegate` -- which reads better and was tried --
    /// sends `setPrivateDelegate:` and dies with *"unrecognized selector"*. There is no
    /// public `delegate` on `NSXPCConnection` for it to collide with; that is the whole point
    /// of binding it. `NSXPCPrivateDelegateTests` catches the mistake, which is why the
    /// cheap-looking round-trip test is there.
    @NSManaged weak var delegate: NSXPCConnectionPrivateDelegate?

    /// A proxy that reports failure after `timeout` rather than waiting for the connection to
    /// die.
    ///
    /// The public API has no per-call timeout at all, which is why this is worth binding: a
    /// two-way call over a peer that has stopped answering but whose connection is still up
    /// never completes. Unused so far -- see the note at the top of this file.
    @objc(remoteObjectProxyWithTimeout:errorHandler:)
    @NSManaged func remoteObjectProxy(
        with timeout: TimeInterval,
        errorHandler: @convention(block) @escaping (Error) -> Void
    ) -> NSObjectProtocol

    /// A proxy carrying `userInfo`, which the peer can read off its own connection.
    @objc(remoteObjectProxyWithUserInfo:errorHandler:)
    @NSManaged func remoteObjectProxy(
        with userInfo: NSObjectProtocol?,
        errorHandler: @convention(block) @escaping (Error) -> Void
    ) -> NSObjectProtocol
}

// `_handoffCurrentReplyToQueue:block:` is deliberately **not** bound. It was named in the
// exploratory code this file grew out of, and `class_getInstanceMethod(NSXPCConnection.self,
// NSSelectorFromString("_handoffCurrentReplyToQueue:block:"))` returns nil on macOS 27 --
// there is no such method to bind, so a binding would be a null branch waiting to happen.
#endif
