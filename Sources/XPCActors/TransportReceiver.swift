import Foundation
#if canImport(Darwin)
import XPC
#endif

// ===========================================================================================
// MARK: - TransportReceiver
// ===========================================================================================

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
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
    public final class TransportReceiver: @unchecked Sendable {

        private let lock = NSLock()

        /// [fieldmd] `{XPCDistributed.Fuse}` -- one-shot. [disasm] `cancel()` does
        /// `caslb 0 -> 1` and returns immediately if it was already tripped.
        private var isCancelled = false

        private let actorSystem: XPCActorSystem

        /// [fieldmd] mangled `yt6result_{ActivationToken}5tokent {LocalInterface}nYaYbc`:
        /// `n` = consuming, `Ya` = async, `Yb` = `@Sendable`, returning the labelled tuple
        /// `(result: (), token: ActivationToken)`.
        private let peerHandler: @Sendable (consuming Session.LocalInterface) async
            -> (result: (), token: Session.LocalInterface.ActivationToken)

        /// [fieldmd] `yyYbcSg`, flags 0x2 -- a `var`, and optional.
        private var cancellationHandler: (@Sendable () -> Void)?

        /// [fieldmd] `{TransportReceiver.(PeerTaskTable)}`, private in Apple's too.
        private var peerHandlingTasks: [ID64: Task<Session.LocalInterface.ActivationToken, Never>] = [:]

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
        public var peerTaskCount: Int { lock.withLock { peerHandlingTasks.count } }

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

            let alreadyCancelled: Bool = lock.withLock {
                guard !isCancelled else { return true }
                let task = Task<Session.LocalInterface.ActivationToken, Never> { [peerHandler] in
                    await peerHandler(session.local).token
                }
                peerHandlingTasks[session.id] = task
                // Apple's `readyToReceive(_:)`: the handler's task becomes the activation
                // event's owner, so an inbound execution parked on the gate lifts the priority
                // of the task that is going to open it, rather than waiting behind it at its
                // own. `OwnedAwaitableEvent.wait()` escalates `owningTask` and never awaits it
                // -- escalate without join, which is exactly what `escalatePriority(to:)` does
                // and an `await` would not.
                //
                // **Only from macOS 26**, which is where `Task.escalatePriority(to:)` was
                // introduced; this file's floor is macOS 14. Below it there is no way to raise
                // a task's priority without joining it, so the owner is left unset rather than
                // installed as a closure that silently ignores its argument -- an absent owner
                // reads as absent, a no-op owner reads as working. The cost on older systems is
                // a priority inversion while the gate is shut, which is latency, not
                // correctness.
                if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, *) {
                    session.setActivationOwner { priority in
                        task.escalatePriority(to: priority)
                    }
                }
                return false
            }
            if alreadyCancelled {
                session.cancel(because: "The receiver was cancelled before this peer attached.")
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
            lock.withLock { cancellationHandler = handler }
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
            let handler: (@Sendable () -> Void)? = lock.withLock {
                guard !isCancelled else { return nil }
                isCancelled = true
                guard let handler = cancellationHandler else {
                    preconditionFailure(
                        "TransportReceiver.cancel() with no cancellation handler set. Call "
                        + "setCancellationHandler(_:) before cancelling -- otherwise there is "
                        + "nothing to stop the listener that feeds this receiver.")
                }
                cancellationHandler = nil
                return handler
            }
            handler?()
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
            let tasks: [Task<Session.LocalInterface.ActivationToken, Never>] = lock.withLock {
                let live = Array(peerHandlingTasks.values)
                peerHandlingTasks.removeAll()
                return live
            }
            for task in tasks {
                task.cancel()
                _ = await task.value
            }
        }

        deinit {
            lock.withLock { peerHandlingTasks.values.forEach { $0.cancel() } }
        }
    }
}

#if canImport(Darwin)

// ===========================================================================================
// MARK: - Serving over libxpc
// ===========================================================================================

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
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

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
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
