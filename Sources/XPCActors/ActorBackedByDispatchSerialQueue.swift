import Dispatch

// ===========================================================================================
// MARK: - ActorBackedByDispatchSerialQueue
// ===========================================================================================

/// Apple's `XPCDistributed.ActorBackedByDispatchSerialQueue` -- a class-bound (`Actor`) protocol
/// that pins a conforming actor's isolation to a specific `DispatchSerialQueue`. That is what
/// lets the actor be entered **synchronously** (``syncToActor(_:file:line:)``), returning a value,
/// as well as asynchronously (``asyncToActor(_:file:line:)``). A plain `actor` cannot offer a
/// synchronous, value-returning entry point; this protocol is how Apple gets one, and it is the
/// only load-bearing reason the protocol exists (the serialization guarantee alone is what any
/// `actor` already provides).
///
/// [sym] `class-protocol $s14XPCDistributed32ActorBackedByDispatchSerialQueueP`, one requirement
/// `queue: OS_dispatch_queue_serial`, with default implementations of `unownedExecutor`,
/// `syncToActor<A>(_:file:line:)`, and `asyncToActor(_:file:line:)`. Apple's conformers are
/// `BackpressureManager<A>`, `RequestManager<A, B>`, and `RequestManager<A, B>.Request`.
///
/// [refl] decompiled bodies: `unownedExecutor.getter` == `queue.asUnownedSerialExecutor()`;
/// `syncToActor` == `queue.sync { self.assumeIsolated { body($0) } }`; `asyncToActor` builds a
/// `DispatchWorkItem` at `DispatchQoS.unspecified` with empty `DispatchWorkItemFlags` and
/// `queue.async`s it around `self.assumeIsolated { body($0) }`.
///
/// Apple's protocol is `internal` to XPCDistributed; it is `public` here only so the package's
/// public ``RequestTable`` (Apple's `RequestManager`) can adopt it -- a source-visibility choice
/// with no runtime bearing.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public protocol ActorBackedByDispatchSerialQueue: Actor {

    /// Apple's `queue: OS_dispatch_queue_serial` -- the serial queue that *is* this actor's
    /// executor. `nonisolated` because ``unownedExecutor`` reads it before isolation exists.
    nonisolated var queue: DispatchSerialQueue { get }
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public extension ActorBackedByDispatchSerialQueue {

    /// [sym] `unownedExecutor.getter` -> `queue.asUnownedSerialExecutor()`. Overriding the actor's
    /// default executor with the serial queue is the whole point: it makes "running on the queue"
    /// and "isolated to this actor" the same condition, which is exactly what
    /// ``syncToActor(_:file:line:)`` and `assumeIsolated` rely on.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        unsafeDowncast(queue, to: _DispatchSerialExecutorQueue.self).asUnownedSerialExecutor()
      //  queue.asUnownedSerialExecutor()
    }

    /// Enter the actor **synchronously**, run `body` with isolated access, and return its result
    /// -- the capability a plain `actor` lacks. [sym] byte-for-byte Apple's body:
    /// `queue.sync { self.assumeIsolated { body($0) } }`, with no added guard.
    ///
    /// **Must be called from off the queue.** `queue.sync` onto the actor's own queue would
    /// deadlock; Apple relies on that non-reentrancy without a guard, and so does this -- the
    /// caller invokes it from the transport's own context, never from within the actor.
    nonisolated func syncToActor<T: Sendable>(
        _ body: (isolated Self) throws -> T,
        file: StaticString = #fileID, line: UInt = #line
    ) rethrows -> T {
        try queue.sync {
            try self.assumeIsolated({ try body($0) }, file: file, line: line)
        }
    }

    /// Enter the actor **asynchronously**, fire-and-forget. [sym] `queue.async { self
    /// .assumeIsolated { body($0) } }`. Apple dispatches at `DispatchQoS.unspecified` with no
    /// `DispatchWorkItemFlags` -- `queue.async`'s own defaults -- so nothing extra is passed.
    nonisolated func asyncToActor(
        _ body: @escaping @Sendable (isolated Self) -> Void,
        file: StaticString = #fileID, line: UInt = #line
    ) {
        queue.async {
            self.assumeIsolated({ body($0) }, file: file, line: line)
        }
    }
}
