#if canImport(Darwin)
import Foundation
import Synchronization
import XPC

// ===========================================================================================
// MARK: - A listener on libxpc itself
// ===========================================================================================

/// Accepts peers, on the C API rather than `XPCListener`.
///
/// `XPCListener` is macOS 14 because it wraps `xpc_listener_create`, which is macOS 14. The
/// older mechanism it replaced -- a *connection* created with
/// `XPC_CONNECTION_MACH_SERVICE_LISTENER`, or an anonymous one created with a nil name -- is
/// `__MAC_10_7`, and delivers new peers as `XPC_TYPE_CONNECTION` objects to the same untyped
/// event handler everything else arrives on.
///
/// **Three ways to listen, and they are not interchangeable.**
///
/// - ``anonymous(targetQueue:accepting:)`` has no name at all. It vends an
///   ``XPCConnectionListener/endpoint`` that must be handed to the other side by some channel
///   that already exists -- which in practice means in-process, or over another XPC
///   connection. This is what the tests use.
/// - ``machService(_:targetQueue:accepting:)`` claims a name launchd already holds for this
///   process, from a `MachServices` key in a launchd plist.
/// - An **XPC service bundle** cannot use either below macOS 14, and that is a real hole
///   rather than an oversight: launchd hands a bundled service its listener through
///   `xpc_main`, which never returns and owns the main thread. ``runXPCServiceMain(accepting:)``
///   is that path, and it is a separate function because a call that never returns should not
///   look like one that does.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public final class XPCConnectionListener: @unchecked Sendable {

    private let listener: xpc_connection_t
    /// One-shot fuse, `caslb 0 -> 1`; an `Atomic<Bool>` now that the floor is macOS 26.
    private let isCancelled = Atomic<Bool>(false)

    /// Retained for the same reason as the transport's: the event handler is held by the
    /// connection, so a handler that captured `self` strongly would make the pair immortal.
    private let box = Box()

    private init(listener: xpc_connection_t,
                 accepting accept: @escaping @Sendable (XPCConnectionTransport) -> Void) {
        self.listener = listener
        box.accept = accept
        // Captured explicitly: the closure must hold the *box*, never `self`. Holding `self`
        // would close the cycle listener -> handler -> transport -> listener that the box
        // exists to keep open.
        let box = self.box
        xpc_connection_set_event_handler(listener) { event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION else {
                // A listener's channel also carries its own death. Nothing else can arrive:
                // messages go to peer connections, never to the listener.
                return
            }
            // A plain annotated binding, not a cast: the Swift overlay lowers both
            // `xpc_object_t` and `xpc_connection_t` to the same existential (`any
            // OS_xpc_object`), so an `unsafeBitCast` between them is a no-op the compiler now
            // flags as unnecessary. The real check that this object *is* a connection is
            // `xpc_get_type(event) == XPC_TYPE_CONNECTION`, made on the line above; the type
            // system has no `xpc_connection_t` case to narrow to, so the binding stands in for
            // the narrowing the runtime already did.
            let peer: xpc_connection_t = event
            box.accept?(XPCConnectionTransport(connection: peer))
        }
        xpc_connection_activate(listener)
    }

    /// A listener with no name, reachable only through ``endpoint``.
    public static func anonymous(
        targetQueue: DispatchQueue? = nil,
        accepting accept: @escaping @Sendable (XPCConnectionTransport) -> Void
    ) -> XPCConnectionListener {
        XPCConnectionListener(listener: xpc_connection_create(nil, targetQueue),
                              accepting: accept)
    }

    /// A listener on a launchd-registered Mach service name.
    public static func machService(
        _ name: String,
        targetQueue: DispatchQueue? = nil,
        accepting accept: @escaping @Sendable (XPCConnectionTransport) -> Void
    ) -> XPCConnectionListener {
        XPCConnectionListener(
            listener: xpc_connection_create_mach_service(
                name, targetQueue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)),
            accepting: accept)
    }

    /// The address of this listener, for a peer that can be handed one.
    ///
    /// `xpc_endpoint_create` is `__MAC_10_7`; `XPCEndpoint`, which merely wraps it, is macOS
    /// 15. That gap was the second of the two reasons this module could not go below 14.
    public var endpoint: xpc_endpoint_t { xpc_endpoint_create(listener) }

    /// Stop accepting. Peers already accepted are untouched -- they have their own connections
    /// and their own lifetimes.
    public func cancel() {
        let (tripped, _) = isCancelled.compareExchange(
            expected: false, desired: true, ordering: .sequentiallyConsistent)
        guard tripped else { return }
        xpc_connection_cancel(listener)
        box.accept = nil
    }

    final class Box: @unchecked Sendable {
        private let _accept = Mutex<(@Sendable (XPCConnectionTransport) -> Void)?>(nil)
        var accept: (@Sendable (XPCConnectionTransport) -> Void)? {
            get { _accept.withLock { $0 } }
            set { _accept.withLock { $0 = newValue } }
        }
    }
}

// ===========================================================================================
// MARK: - The bundled-service entry point
// ===========================================================================================

/// Hand the main thread to launchd and accept peers forever. **Never returns.**
///
/// This is how an XPC service bundle listens below macOS 14. `xpc_main` takes over the calling
/// thread, so there is no way to wrap it in something that returns a listener object, and no
/// way to reach it from an `async` `main` -- which is why the service executable in `Demo/`
/// has a synchronous `main` that ends here.
///
/// The peer handler runs on libxpc's own queue. Anything asynchronous it wants to do -- and a
/// distributed-actor peer handler is entirely asynchronous -- has to be started as a `Task`,
/// which is what ``XPCActorSystem/TransportReceiver/attachTransport(_:)`` already does.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public func runXPCServiceMain(
    accepting accept: @escaping @Sendable (XPCConnectionTransport) -> Void
) -> Never {
    // A global, because `xpc_main`'s handler is a C function pointer context that outlives
    // every scope here by construction -- the function it belongs to never returns.
    xpcServiceMainAccept = accept
    xpc_main { peer in
        xpcServiceMainAccept?(XPCConnectionTransport(connection: peer))
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
nonisolated(unsafe) private var xpcServiceMainAccept:
    (@Sendable (XPCConnectionTransport) -> Void)?
#endif
