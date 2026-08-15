import Foundation
import Synchronization
#if canImport(Darwin)
import XPC
#endif

// ===========================================================================================
// MARK: - TransportReceiver
// ===========================================================================================

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCActorSystem {

    /// The serving side: one of these turns arriving transports into sessions and runs a
    /// handler against each.
    ///
    /// [sym] resilient class; only `__allocating_init` has a method descriptor.
    /// [measured] field offsets 0x10 (fuse), 0x18 (actorSystem), 0x20 (peerHandler, 16 bytes),
    ///            0x30 (cancellationHandler, 16 bytes), 0x40 (peerHandlingTasks); size 0x48.
    ///
    /// The handler's type is the design: it is given a `LocalInterface` **`__owned`** and must
    /// return an `ActivationToken`, and the only ways to obtain a token are to activate or to
    /// explicitly decline (``Session/LocalInterface/cancelWithoutActivating(because:)``). A
    /// handler that exports actors and then forgets to start answering does not compile.
    public final class TransportReceiver: Sendable {

        /// [fieldmd] `{XPCDistributed.Fuse}` -- one-shot. [disasm] `cancel()` does
        /// `caslb 0 -> 1` and returns immediately if it was already tripped. Apple's `Fuse`
        /// is `{ value: Atomic<Bool> }`; this **is** that atomic, and the `caslb` is its
        /// `compareExchange(expected: false, desired: true)`. No `NSLock` stand-in now that
        /// the floor is macOS 26 and `Synchronization` is available.
        private let fuse = Atomic<Bool>(false)

        private let actorSystem: XPCActorSystem

        /// [fieldmd] mangled `yt6result_{ActivationToken}5tokent {LocalInterface}nYaYbc`:
        /// `n` = consuming, `Ya` = async, `Yb` = `@Sendable`, returning the labelled tuple
        /// `(result: (), token: ActivationToken)`.
        private let peerHandler: @Sendable (consuming Session.LocalInterface) async
            -> (result: (), token: Session.LocalInterface.ActivationToken)

        /// [fieldmd] `yyYbcSg`, flags 0x2 -- a `var`, and optional. Held under its own
        /// mutex; only the caller that wins the fuse trip in ``cancel()`` ever
        /// reads-and-clears it.
        private let cancellationHandler = Mutex<(@Sendable () -> Void)?>(nil)

        /// [fieldmd] `{TransportReceiver.(PeerTaskTable)}`, private in Apple's too.
        ///
        /// **How this stands against Apple's, reviewed.** Apple's `PeerTaskTable` is a
        /// `Mutex<[ID64: Slot]>` whose `Slot` is a three-state machine over an
        /// **`UnsafeCurrentTask`** (`initial → task(_) → doneOrCancelled`) — a *control*
        /// handle (cancel + escalate, no retain, no await), so the handler's result is
        /// discarded and the three states bracket the unsafe handle's validity. See the
        /// reconstruction's `Slot`.
        ///
        /// We deliberately hold a **`Task`** instead. It retains and, unlike an
        /// `UnsafeCurrentTask`, it can be **awaited** — which is exactly what
        /// ``unwindPeers()`` needs (`await task.value`). That sidesteps the one thing the
        /// reconstruction could not resolve about Apple's version: *what `unwindPeers`
        /// awaits*, since an `UnsafeCurrentTask` has no result to await. Our shape is
        /// heavier (a retained `Task` per peer) but its shutdown join is plain and provable,
        /// where Apple's is an open question. The `initial`/`doneOrCancelled` bracket has no
        /// analogue here because we never hold an unsafe handle; a key present-or-absent is
        /// the whole state we need.
        ///
        /// **Why a table at all, and not a `(Discarding)TaskGroup`** — decided, with the
        /// evidence in the design notes. Three properties keep the table: `unwindPeers` is
        /// *re-enterable* (it drains the current peers without shutting the receiver down,
        /// and a group's `cancelAll`/host-cancel poisons it permanently — measured); both
        /// serving paths (`accept`, `runXPCServiceMain` via `xpc_main`) are *synchronous*
        /// callbacks, so a group would need an async host scope plus a sync→async bridge;
        /// and any per-id need (dedup, state) forces a side `[ID64: State]` table *alongside*
        /// the group, reintroducing the very thing the group was meant to replace. A group
        /// wins only for a single async entry point with terminal-only shutdown and no
        /// per-id need — which this is not. So the table owns the tasks directly.
        private let peerHandlingTasks = Mutex<[ID64: Task<Session.LocalInterface.ActivationToken, Never>]>([:])

        /// [sym] 0x2ad4e99f0.
        public init(
            actorSystem: XPCActorSystem,
            peerHandler: @escaping @Sendable (consuming Session.LocalInterface) async
                -> (result: (), token: Session.LocalInterface.ActivationToken)
        ) {
            self.actorSystem = actorSystem
            self.peerHandler = peerHandler
        }

        /// [sym] 0x2ad4e94d8. [disasm] the mutex-guarded count of `.live` slots.
        public var peerTaskCount: Int { peerHandlingTasks.withLock { $0.count } }

        /// Turn an arriving transport into a session and start its handler.
        ///
        /// [sym] 0x2ad4e8e40, `throws(SetupError)`. [disasm] builds the session, names a task
        /// from `session.debugDescription`, starts the handler, registers the task under the
        /// session's `ID64`, and calls `session.readyToReceive(task)`.
        ///
        /// **The session starts with its local interface shut**, which is what makes the
        /// handler's export-then-activate ordering safe. Apple starts the handler with
        /// `Task.immediate`, which runs synchronously to the first suspension and so gets the
        /// exports in before this function returns; a plain `Task` does not, and does not need
        /// to -- a request that beats the handler parks in
        /// ``Session/waitForLocalInterfaceActivation()`` instead of resolving against an empty
        /// table. The gate is load-bearing here, not decorative.
        public func attachTransport(_ transport: Transport) throws(SetupError) {
            let session = actorSystem.makeSession(over: transport, localInterfaceActivated: false)

            // Refuse a peer arriving after cancel. Re-checked once more at registration
            // below, since the immediate handler is spawned outside any lock.
            guard !fuse.load(ordering: .acquiring) else {
                session.cancel(because: "The receiver was cancelled before this peer attached.")
                throw SetupError("TransportReceiver is cancelled; refusing the peer.")
            }

            // **Apple's `Task.immediate`, the real one.** It runs the handler synchronously to
            // its first suspension right here, so the exports land and the local interface
            // activates before `attachTransport` returns -- the ordering the shut-interface
            // gate depends on. Spawned **outside any lock**: the immediate prologue is user
            // code (exports, activation) and must never run under a lock it -- or a
            // synchronously-completing handler -- could re-enter.
            let task = Task.immediate { [peerHandler] in
                await peerHandler(session.local).token
            }

            // Apple's `readyToReceive(_:)`: the handler's task becomes the activation event's
            // owner, so an inbound execution parked on the gate escalates the task about to
            // open it (escalate without join, exactly what `Task.escalatePriority(to:)` does
            // and an `await` would not). `escalatePriority` is macOS 26, which is this
            // module's floor now, so the owner is always installed.
            session.setActivationOwner { priority in
                task.escalatePriority(to: priority)
            }

            // Register, re-checking the fuse: a `cancel()` that landed while the handler was
            // starting must not leave this task unreachable from `unwindPeers`. If it did,
            // cancel the just-spawned task and refuse the peer.
            let registered = peerHandlingTasks.withLock { table -> Bool in
                guard !fuse.load(ordering: .acquiring) else { return false }
                table[session.id] = task
                return true
            }
            guard registered else {
                task.cancel()
                session.cancel(because: "The receiver was cancelled while this peer attached.")
                throw SetupError("TransportReceiver is cancelled; refusing the peer.")
            }
            // **Nothing is activated here, and Apple does not activate either** -- the five
            // calls their `attachTransport` makes are session, task name, task start,
            // register, `readyToReceive`. An accepted peer's `XPCSession` is already live
            // when `IncomingSessionRequest.accept` returns, which is why
            // `XPCRawTransport.accepting` builds its transport `isAlreadyActive: true`; there
            // is nothing left to start.
        }

        /// [sym] 0x2ad4e90f4. [disasm] stores the closure, releasing whatever was there. The
        /// parameter is not optional.
        public func setCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
            cancellationHandler.withLock { $0 = handler }
        }

        /// Stop accepting, and tell whoever is listening to stop too.
        ///
        /// [sym] 0x2ad4e9138. [disasm] trips the fuse and returns if it was already tripped;
        /// then **traps** (`brk #1`) if `cancellationHandler` is nil, calls it, and clears it.
        ///
        /// The trap is Apple's and it is reproduced rather than softened. `cancel()` exists to
        /// tear down the thing that feeds this receiver -- the listener -- and a receiver with
        /// no handler has no way to do that, so a "successful" cancel would leave the listener
        /// running and accepting peers into a receiver that refuses them. Failing quietly there
        /// is worse than failing here.
        public func cancel() {
            // Trip the fuse -- `caslb 0 -> 1`. Only the caller that wins the exchange
            // proceeds; a second `cancel()` finds it already tripped and returns.
            let (tripped, _) = fuse.compareExchange(
                expected: false, desired: true, ordering: .sequentiallyConsistent)
            guard tripped else { return }
            let handler = cancellationHandler.withLock { stored -> (@Sendable () -> Void) in
                guard let handler = stored else {
                    preconditionFailure(
                        "TransportReceiver.cancel() with no cancellation handler set. Call "
                        + "setCancellationHandler(_:) before cancelling -- otherwise there is "
                        + "nothing to stop the listener that feeds this receiver.")
                }
                stored = nil
                return handler
            }
            handler()
        }

        /// Cancel every peer handler and wait for all of them to finish.
        ///
        /// [sym] 0x2ad4e952c, `async`. [disasm] collects the live tasks under the mutex, then
        /// for each calls `Task.cancel()` and awaits `Task.result` -- so it genuinely waits,
        /// rather than signalling and returning.
        ///
        /// Collected under the lock and awaited outside it: awaiting while holding a mutex a
        /// finishing handler needs in order to deregister is a deadlock, and the handlers do
        /// deregister.
        public func unwindPeers() async {
            // Collect under the lock and await outside it -- `Mutex.withLock` is
            // non-`async` and so *enforces* that at compile time: a finishing handler that
            // needs the lock to deregister would deadlock if we awaited while holding it.
            let tasks = peerHandlingTasks.withLock { table -> [Task<Session.LocalInterface.ActivationToken, Never>] in
                let live = Array(table.values)
                table.removeAll()
                return live
            }
            for task in tasks {
                task.cancel()
                _ = await task.value
            }
        }

        deinit {
            peerHandlingTasks.withLock { $0.values.forEach { $0.cancel() } }
        }
    }
}

#if canImport(Darwin)

// ===========================================================================================
// MARK: - Serving over libxpc
// ===========================================================================================

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCActorSystem.TransportReceiver {

    /// Accept one inbound peer connection and start its handler.
    ///
    /// Wire this to ``XPCConnectionListener``'s accept closure, or to
    /// ``runXPCServiceMain(accepting:)`` in a bundled service. A receiver that has already been
    /// cancelled hangs up on the peer rather than half-serving it.
    public func accept(_ raw: XPCConnectionTransport, debugName: String = "peer") {
        let transport = Transport(debugName: debugName, role: .responder, rawTransport: raw)
        do {
            try attachTransport(transport)
            // **Activated here, not in `attachTransport`.** libxpc hands a listener a
            // *suspended* peer connection, so unlike the overlay -- where
            // `IncomingSessionRequest.accept` returned a live session and Apple's
            // `attachTransport` therefore had nothing to start -- somebody has to resume it.
            // It happens after `attachTransport` so the session, its handlers and its peer task
            // are all in place before the first message can arrive.
            try raw.activate()
        } catch {
            raw.cancel(reason: "\(error)")
        }
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCActorSystem {

    /// Everything a service process needs to stay up: the listener, the receiver, and the way
    /// to stop.
    ///
    /// Apple's equivalent is `ServiceRegistry.register(service:receiver:actorSystem:targetQueue:)`,
    /// which also enters the receiver into the process-wide registry that makes the
    /// same-process optimization possible. That registry is not modelled here -- see the note
    /// on ``Service/connect(from:with:)`` -- so this is the listener half only, and it is named
    /// for what it does rather than borrowing a name for something it is not.
    public final class ServiceListener: @unchecked Sendable {

        public let receiver: TransportReceiver
        private let listener: XPCConnectionListener
        private let stopped = ActivationEvent(posted: false)

        fileprivate init(receiver: TransportReceiver, listener: XPCConnectionListener) {
            self.receiver = receiver
            self.listener = listener
        }

        /// Park until something cancels this listener. A service process's `main` ends here.
        ///
        /// Parks on its own event rather than on ``TransportReceiver/unwindPeers()``: unwinding
        /// returns as soon as the *current* peers are done, which for a service with no peers
        /// yet is immediately. A service that returned from `main` the moment it finished
        /// starting up would be a service that never serves.
        public func waitUntilCancelled() async {
            await stopped.wait()
        }

        /// Stop listening and unwind every peer.
        public func cancel() async {
            receiver.cancel()
            await receiver.unwindPeers()
            stopped.post()
        }
    }

    /// Listen as `service` and run `peerHandler` for every peer that connects.
    ///
    /// **Mach services only.** `.xpcService` is rejected rather than quietly mishandled: a
    /// bundled XPC service is not given a listener it can create, it is given one by launchd
    /// through `xpc_main`, which never returns. Pretending otherwise would produce a listener
    /// on a name nothing routes to, and a service that starts cleanly and is never reached.
    /// ``runXPCServiceMain(accepting:)`` is that path; `Demo/Sources/DemoService` uses it.
    public func listen(
        as service: Service,
        targetQueue: DispatchQueue? = nil,
        peerHandler: @escaping @Sendable (consuming Session.LocalInterface) async
            -> (result: (), token: Session.LocalInterface.ActivationToken)
    ) throws(SetupError) -> ServiceListener {
        guard service.debugName.hasPrefix("mach:") else {
            throw SetupError(
                "\(service.debugName) cannot be listened on: a bundled XPC service receives its "
                + "listener from launchd through xpc_main. Call runXPCServiceMain(accepting:) "
                + "from a synchronous main instead.")
        }
        let receiver = TransportReceiver(actorSystem: self, peerHandler: peerHandler)
        let listener = XPCConnectionListener.machService(
            service.name, targetQueue: targetQueue
        ) { [receiver] raw in
            receiver.accept(raw, debugName: service.debugName)
        }
        receiver.setCancellationHandler { [listener] in listener.cancel() }
        return ServiceListener(receiver: receiver, listener: listener)
    }
}

#endif
