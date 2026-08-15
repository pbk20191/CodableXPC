#if canImport(Darwin)
import Foundation
import XPC

// ===========================================================================================
// MARK: - Service
// ===========================================================================================

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCActorSystem {

    /// A launchd-registered service, addressed by name.
    ///
    /// [refl] Two fields, both `let`: `isMach: Bool` at offset 0, `name: String` at 8.
    /// [vwt] size 24, stride 24 -- consistent with that layout.
    /// [dis] `machService(_:)` @ 0x2ad4c8eb8 writes `1` to byte [0]; `xpcService(_:)` writes `0`.
    /// [sym] No `Encodable`/`Decodable` conformance descriptor exists anywhere in the image:
    ///       this is deliberately **not** `Codable`. A name only means something inside one
    ///       launchd domain, so sending one to a peer would be sending an address that may not
    ///       resolve -- `EphemeralService`, which carries a live `XPCEndpoint`, is the one
    ///       service type Apple does make `Codable`.
    public struct Service: Hashable, Sendable {

        /// [inf] `private` is inferred, not resolved: unlike `name` it has no getter symbol and
        ///       no property descriptor, and both factories store the byte inline. Reflection
        ///       metadata carries no access level.
        private let isMach: Bool

        /// [refl] `SS`. [sym] getter @ 0x2ad4c8e88.
        public let name: String

        /// A Mach service -- a name in launchd's namespace, as registered by a launchd plist's
        /// `MachServices`. Reachable by anything in the same domain that is allowed to look it
        /// up.
        ///
        /// [sym] `static Service.machService(Swift.String) -> Service` @ 0x2ad4c8eb8.
        public static func machService(_ name: String) -> Service {
            Service(isMach: true, name: name)
        }

        /// An XPC service -- a `.xpc` bundle inside the calling application's own bundle, at
        /// `Contents/XPCServices`. launchd starts it on demand and only this application can
        /// reach it, so it needs no registration and leaves nothing behind.
        ///
        /// [sym] `static Service.xpcService(Swift.String) -> Service` @ 0x2ad4c8ecc.
        public static func xpcService(_ name: String) -> Service {
            Service(isMach: false, name: name)
        }

        /// [sym] getter @ 0x2ad4c92e4.
        /// [dis] `(isMach ? "mach:" : "xpc:") + name`. Both prefixes are Swift small strings
        ///       assembled from `movz`/`movk` immediates, which is why neither appears in any
        ///       string table.
        public var debugName: String { (isMach ? "mach:" : "xpc:") + name }

        /// [sym] `Service.(makeXPCSession)(peerRequirement:)` @ 0x2ad4c8edc -- private
        ///       discriminator, so `private`.
        /// [dis] Branches on `isMach`, creates the session `.inactive`, then applies the
        ///       requirement when one was given.
        ///
        /// Apple's builds an `XPCSession`, and so does this -- the same branch, the same
        /// ordering, the same `.inactive`. A session created here is inactive until
        /// ``XPCRawTransport/activate()``, which is what gives the requirement somewhere to be
        /// applied before any byte moves.
        private func makeTransport(
            peerRequirement: PeerRequirement?, targetQueue: DispatchQueue?
        ) throws(SetupError) -> XPCRawTransport {
            let transport: XPCRawTransport
            do {
                transport = isMach
                    ? try XPCRawTransport.connectingToMachService(name, targetQueue: targetQueue)
                    : try XPCRawTransport.connectingToXPCService(name, targetQueue: targetQueue)
            } catch {
                throw SetupError("could not dial \(debugName): \(error)")
            }
            guard let peerRequirement else { return transport }
            // Apple's `makeXPCSession` calls `XPCSession.setPeerRequirement(_:)` here -- and
            // over the overlay we can, which is one capability the bare-connection detour had
            // to refuse (`xpc_connection_set_peer_requirement` is `XPC_SWIFT_NOEXPORT`, its
            // argument type not even linkable). Applied on the inactive session, before any
            // byte moves, exactly as theirs.
            transport.setPeerRequirement(peerRequirement)
            return transport
        }

        /// Dial this service and return the session speaking to it.
        ///
        /// [sym] `Service.connect(from:with:)` @ 0x2ad4d7020.
        ///
        /// **Apple's same-process optimization, and this now has it.** The body first consults
        /// `ServiceRegistry.shared.lookUpAndConnect(to:from:options:)`: a service served in
        /// this same process is reached over a `.local` session's direct-invocation path,
        /// which encodes nothing, and only a miss (or `preserveSelfIPC`) falls through to XPC
        /// -- the two branches Apple names in its own log lines, `'Using same-process
        /// optimization for service %s'` and `'preserveSelfIPC set, forcing XPC for service
        /// %s'`. The `.local` session, its `LocalSessionState` peer, and the direct-invocation
        /// path are all here now; see ``Session/Kind`` and ``ServiceRegistry``.
        func connect(
            from actorSystem: XPCActorSystem, with arguments: ServiceConnectArguments
        ) throws(SetupError) -> Session {
            // Apple's body first consults the process-wide registry: a service served in
            // this same process is reached directly unless `preserveSelfIPC` forces XPC.
            if let local = ServiceRegistry.shared.lookUpAndConnect(
                to: self, from: actorSystem, options: arguments.options) {
                return local
            }
            let raw = try makeTransport(peerRequirement: arguments.peerRequirement,
                                        targetQueue: nil)
            let transport = Transport(debugName: debugName, role: .initiator, rawTransport: raw)
            let session = actorSystem.makeSession(
                over: transport,
                // Inverted, and the inversion is the whole meaning of the flag. A
                // **bidirectional** client is going to export actors and must therefore open
                // its own gate *after* it has, so it starts shut. A plain client exports
                // nothing and will never call `activateThenWaitForCancellation`, so starting
                // it shut would be a trap rather than a safeguard: an inbound request would
                // park in `waitForLocalInterfaceActivation()` for a gate nobody is going to
                // open, and the peer would wait forever -- there is no timeout in this
                // protocol. Open, it answers "nothing is shared at that key", which is both
                // true and terminal.
                localInterfaceActivated: !arguments.options.contains(.bidirectional),
                isBidirectional: arguments.options.contains(.bidirectional))
            do {
                try raw.activate()
            } catch {
                throw SetupError("Could not activate \(debugName): \(error)")
            }
            return session
        }

        private init(isMach: Bool, name: String) {
            self.isMach = isMach
            self.name = name
        }
    }

    // =======================================================================================
    // MARK: ServiceConnectArguments
    // =======================================================================================

    /// The argument bundle of `ConnectableService.connect(from:with:)`.
    ///
    /// [fieldmd] [sym] Two stored properties, both `let`.
    /// [disasm] `default argument 1 of ...init(peerRequirement:options:)` @ 0x2ad4bd8ec is
    ///          `mov x0, #0; ret`, so `peerRequirement` defaults to `nil`.
    /// [sym] No `default argument 2` symbol exists, so `options` has **no** default here --
    ///       unlike `Session.init`, where it defaults to `[]`. The absence is the evidence.
    public struct ServiceConnectArguments: Sendable {

        public let peerRequirement: PeerRequirement?
        public let options: InitializationOptions

        public init(peerRequirement: PeerRequirement? = nil, options: InitializationOptions) {
            self.peerRequirement = peerRequirement
            self.options = options
        }
    }

    /// [sym] `XPCSystem.InitializationOptions`, an `OptionSet`.
    ///
    /// Only the one case is modelled, because it is the only one this module can honour.
    /// Apple's set also drives `.inactive` on the session, which here is `Transport.activate()`
    /// -- argued at ``XPCActorSystem/makeSession(over:localInterfaceActivated:)``.
    public struct InitializationOptions: OptionSet, Sendable {

        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// This side will export actors too, so its local interface must be activated
        /// explicitly rather than opened at connect.
        ///
        /// Apple's `Session.(addSharedActor)` asserts on it -- `"API violation: Session must be
        /// bidirectional to share actor references"`.
        public static let bidirectional = InitializationOptions(rawValue: 1 << 0)

        /// Force the XPC path even when the service is served in this same process, rather
        /// than taking ``ServiceRegistry``'s same-process optimization. Apple's
        /// `preserveSelfIPC`; it logs `"preserveSelfIPC set, forcing XPC for service %s"`.
        public static let preserveSelfIPC = InitializationOptions(rawValue: 1 << 1)
    }

    // =======================================================================================
    // MARK: Connecting
    // =======================================================================================

    /// Dial `service` and hand back its peer-facing interface.
    ///
    /// [sym] `makeRemoteInterface(to:)` @ the `Service` overload.
    ///
    /// The session itself is not returned and is not retained by the system -- it is held by
    /// the `RemoteInterface` struct, which is one word. Drop the interface and the connection
    /// closes, which is the lifetime rule the whole module runs on: nothing global keeps a
    /// conversation alive.
    public func makeRemoteInterface(to service: Service) throws(SetupError)
    -> Session.RemoteInterface {
        try makeRemoteInterface(to: service, assumingPeerSatisfies: nil)
    }

    /// Dial `service`, refusing unless the peer satisfies `requirement`.
    ///
    /// The requirement is applied to the `XPCSession` *before* it is activated, so it is
    /// libxpc that refuses rather than us -- which matters, because it means no byte of ours
    /// ever reaches a peer that fails it.
    public func makeRemoteInterface(
        to service: Service, assumingPeerSatisfies requirement: PeerRequirement?
    ) throws(SetupError) -> Session.RemoteInterface {
        let session = try service.connect(
            from: self,
            with: ServiceConnectArguments(peerRequirement: requirement, options: []))
        return session.remote
    }
}
#endif
