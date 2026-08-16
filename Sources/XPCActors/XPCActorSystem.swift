// Sources/XPCActors/XPCActorSystem.swift
import Distributed
import Foundation
import Synchronization

/// The `DistributedActorSystem`. Apple calls theirs `XPCSystem`; the name is ours, the
/// behaviour is not.
///
/// **All eight requirements are real.** Both directions are built: `assignID`,
/// `actorReady`, `resignID`, `resolve`, `makeInvocationEncoder`, `remoteCall` and
/// `remoteCallVoid` send, and `invokeHandlerOnReturn` -- with ``InvocationDecoder`` and
/// ``ResultHandler`` -- receives. ``Session/handleReceivedRequest(_:replyUsing:)`` is
/// what drives the receiving half.
///
/// `final`, where Apple's is not: `XPCSystem` has a vtable covering only its four
/// initialisers, which is what a non-`final` class produces, and subclassing it is not a
/// documented extension point. Nothing here needs to be overridable, and `final` is what
/// lets this be `Sendable` rather than `@unchecked Sendable`.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public final class XPCActorSystem: Sendable {

    /// Diagnostics only. Apple's `XPCSystem.debugName`, never transmitted.
    public let debugName: String

    /// From the process-global counter -- the same one that mints instance ids below and
    /// session ids in ``Session``. Apple's `XPCSystem.id`, and the witness for their
    /// `Internal.Identifiable`.
    ///
    /// It is also the answer to "does this session belong to me": see ``resolve(id:as:)``.
    public let id: ID64

    /// The table of actors living in this process. **Weak entries**, like Apple's
    /// `actorTable: Mutex<[RawActorID.Local: WeakActorRef]>` -- an actor's lifetime
    /// belongs to whoever created it. The strong table is the wire-facing one on
    /// ``Session``.
    ///
    /// **`ActorRegistry<InboundThunk>`, and the widening the previous slice predicted.**
    /// That slice wrote "if the inbound execution path later needs a per-actor thunk it
    /// can widen this, and the reconstruction says Apple's does not". It needs one, and
    /// the reason Apple does not is a difference in what the two languages can express
    /// rather than a difference in design: `executeDistributedTarget` is generic over
    /// `Act: DistributedActor where Act.ID == ActorID`, `DistributedActor` has no primary
    /// associated type, and so `any DistributedActor` cannot be opened into that
    /// constraint. The thunk is captured in ``actorReady(_:)``, where the concrete `Act`
    /// is still in scope, and it is the only way to get from a stored `AnyObject` back to
    /// a call. See ``InboundThunk``.
    ///
    /// `internal`, not `private`: `Session` needs it in order to turn a local id into an
    /// instance, and Apple's `XPCSystem.resolve(id:)` is likewise non-private for exactly
    /// that caller.
    let registry = ActorRegistry<InboundThunk>()

    /// What every peer of every session of this system must prove, or `nil` for "anyone".
    ///
    /// Apple's `XPCSystem.peerRequirement : XPC.XPCPeerRequirement?` at field offset `0x28`,
    /// a `let` (field record flags `0x0`). Their four initialisers split two and two: the
    /// two that take no requirement store the optional's empty case — `nil` — which is why
    /// an unconfigured system admits everyone and why nothing broke while this gate was
    /// missing.
    ///
    /// **Non-optional on an actor, optional here**: the reconstruction is explicit that
    /// `RestrictedAccessDistributedActor.peerRequirement` is `XPCPeerRequirement` and this
    /// one is `XPCPeerRequirement?`. The two gates are separate and both apply; see
    /// ``Session/handleReceivedRequest(_:replyUsing:)``.
    public let peerRequirement: PeerRequirement?

    /// Apple has four initialisers rather than one with defaults — the image contains no
    /// `default argument N of XPCSystem.init…` symbol, and the absence is meaningful
    /// because `Session.init`'s *does* exist. One with a default is enough here; the four
    /// exist over there because `preserveSelfIPC` is the other axis -- and that axis is now
    /// real here too (``Service/InitializationOptions/preserveSelfIPC`` forces XPC past the
    /// same-process path), it just rides an option rather than a fourth initialiser.
    public init(_ debugName: String, peerRequirement: PeerRequirement? = nil) {
        self.debugName = debugName
        self.id = ID64.next()
        self.peerRequirement = peerRequirement
    }
}

// ===========================================================================================
// MARK: - The conformance
// ===========================================================================================

/// Apple's `XPCSystem` witnesses all eight `DistributedActorSystem` requirements, and so
/// does this.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCActorSystem: DistributedActorSystem {

    public typealias ActorID = XPCActors.ActorID
    public typealias InvocationEncoder = XPCActors.InvocationEncoder
    public typealias InvocationDecoder = XPCActors.InvocationDecoder
    public typealias ResultHandler = XPCActors.ResultHandler

    /// Apple's is `any Decodable & Encodable`, read out of the witness slot for
    /// `DistributedActorSystem`'s `SerializationRequirement` associated type rather than
    /// inferred. `any Codable` is the Swift spelling of exactly that constraint -- note
    /// that every *method* mangling in Apple's image spells it as the two separate
    /// requirements, which is the same type written the long way.
    public typealias SerializationRequirement = any Codable

    // MARK: Identity

    /// Mint an id for an actor about to be created here.
    ///
    /// The type argument is untouched, exactly as in Apple's (`0x2ad51e17c` never reads
    /// it). Both halves of the id come from the **process-global** `ID64` generator --
    /// the same one that mints `self.id` and every session id -- so an `instanceID` can
    /// never collide with a system id in this process.
    ///
    /// That is load-bearing rather than incidental: `Session`'s dedupe of a re-shared
    /// actor is safe only because a `RawActorID.Local` is never recycled, and *that*
    /// rests on this counter being monotonic and shared. Minting from a per-system
    /// counter would break it silently.
    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, Act.ID == ActorID {
        ActorID(raw: .local(.init(systemID: id, instanceID: ID64.next())))
    }

    /// Register a local actor. The registry stores it **weakly**, as Apple's does.
    ///
    /// **Traps on a `.remote` id, deliberately, and this is not inconsistent with
    /// `ActorID.encode(to:)` throwing.** The distinction is who can reach the failure.
    /// `encode` is reached with a value shape a *peer* influenced, so it must report
    /// rather than kill the process. Nothing a peer sends can reach `actorReady`: the id
    /// comes from `assignID` a few instructions earlier, in our own code, and only ever
    /// as `.local`. A `.remote` here means this system is being handed a proxy as though
    /// it were a local actor -- a programmer error in code we own, with no correct
    /// recovery, and the same `brk #1` Apple emits.
    public func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ID == ActorID {
        guard case .local(let local) = actor.id.raw else {
            preconditionFailure("actorReady was handed a remote id: \(actor.id.raw)")
        }
        // The one place `Act` is concrete. Nothing is captured but the type: the instance
        // is passed back in, so the closure does not pin the actor and the registry's weak
        // hold keeps meaning what it says.
        let thunk: InboundThunk = { instance, system, target, decoder, handler in
            guard let target1 = instance as? Act else {
                throw SetupError("""
                    the actor registered for \(local) is a \(type(of: instance)), not a \
                    \(Act.self); the invocation thunk and the instance have come apart
                    """)
            }
            var decoder = decoder
            try await system.executeDistributedTarget(
                on: target1, target: target, invocationDecoder: &decoder, handler: handler)
        }
        registry.register(actor, id: local, thunk: thunk)
    }

    /// Drop a local actor. Traps on a `.remote` id for the reason above.
    ///
    /// Note what this does *not* do: it does not withdraw the actor from any session that
    /// has exported it. Apple's does not either, and the shared-actor table is what keeps
    /// such an actor answerable -- see ``Session/resolveSharedActor(at:)``.
    public func resignID(_ id: ActorID) {
        guard case .local(let local) = id.raw else {
            preconditionFailure("resignID was handed a remote id: \(id.raw)")
        }
        registry.resign(local)
    }

    /// The three-way branch, and the three outcomes are not interchangeable.
    ///
    /// - `.local` -> the instance, or **a throw** if the table does not have it. Not
    ///   `nil`: `nil` is the runtime's instruction to synthesise a *proxy*, and a proxy
    ///   for a local id has no session to speak over. Apple's private
    ///   `resolve(id:as:) throws(SetupError) -> Act` is non-optional for the same reason,
    ///   and its message is the one reproduced below.
    /// - `.remote` **through a session of ours** -> `nil`, i.e. "make a proxy".
    /// - `.remote` through anyone else's session -> a throw, with Apple's wording. This
    ///   is the check that stops an id minted against one system from resolving in
    ///   another, and it is total: it does not depend on the session being one of our own
    ///   `Session` objects, only on what the session says its system is.
    ///
    /// Typed throws, as Apple's is.
    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws(SetupError) -> Act?
    where Act: DistributedActor, Act.ID == ActorID {
        switch id.raw {
        case .local(let local):
            guard let instance = registry.lookup(local)?.instance as? Act else {
                // Apple: "Could not resolve actor ID " + String(describing: id) + " as "
                //        + _typeName(A, qualified: false)   [0x2ad51dee8]
                throw SetupError("Could not resolve actor ID \(local) as \(actorType)")
            }
            return instance
        case .remote(let remote):
            guard remote.session.systemID == self.id else {
                throw SetupError("Remote actor does not belong to the actor system.")
            }
            return nil
        }
    }

    /// A fresh encoder. Apple's is 40 bytes of zeroing with no calls.
    public func makeInvocationEncoder() -> InvocationEncoder { InvocationEncoder() }

    // MARK: The call requirements

    /// Send a call to an actor living in a peer, and wait for its result.
    ///
    /// Both this and ``remoteCallVoid(on:target:invocation:throwing:)`` are thin: Apple's
    /// two public entry points tail into one private funnel,
    /// `XPCSystem.(remoteCall)<Act, Res>(actor:target:invocation:result:)`, which reads
    /// the actor's session out of its id, throws if there is none, and otherwise
    /// dispatches `OutboundSessionProtocol.sendInvocation`. ``send(_:to:target:)`` below
    /// is that funnel.
    ///
    /// **Typed throws, and the asymmetry with `remoteCallVoid` below is Apple's.** Their
    /// `remoteCall` mangles as `throws(RemoteInvocationCancellationError)` while
    /// `remoteCallVoid` mangles as plain `throws`; the reconstruction lists *why* as
    /// unresolved but the manglings themselves are unambiguous. Reproduced rather than
    /// tidied, because a mirror that "fixes" an asymmetry it does not understand is
    /// guessing. Note the funnel is typed either way -- the private one is
    /// `throws(RemoteInvocationCancellationError)` in the mangling too -- so
    /// `remoteCallVoid` widens on the way out and never actually throws anything else.
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws(RemoteInvocationCancellationError) -> Res
    where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: Codable {
        try await Self.send(&invocation, to: actor.id, target: target)
    }

    /// The void shape. **The result type is bound to ``Ack``**, which is Apple's: a void
    /// success on the wire is `[0, {}]` because `Void` is not `Codable` and something has
    /// to occupy the generic parameter. Nothing is returned from it -- the value exists
    /// only so the response has a type to decode as.
    ///
    /// Plain `throws`, which is Apple's spelling here and not a transcription slip.
    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        let _: Ack = try await Self.send(&invocation, to: actor.id, target: target)
    }

    /// Apple's private funnel, and the one place a local actor is refused.
    ///
    /// **The refusal comes before any session is involved**, so nothing is sent. Apple
    /// spells the lookup as `(extension in XPCDistributed) DistributedActor.session`,
    /// an `OutboundSessionProtocol?` that is `nil` for a `.local` id, and throws
    /// `.executionFailed` when it is. The message is their 29-byte literal, verbatim.
    ///
    /// The second guard is ours and has no counterpart in Apple's, where
    /// `Remote.session` is *typed* as the outbound protocol so no cast is needed. Our
    /// `RawActorID.Remote.session` is `any SessionCoding` -- the narrower protocol the
    /// identity layer can state without importing `Distributed` -- so a conformer that
    /// can code ids but cannot send is representable. It is named here rather than
    /// trapped: it is reached by handing the system a proxy built against a foreign
    /// session, which is a caller's mistake, not the runtime's.
    private static func send<Res: Codable>(
        _ invocation: inout InvocationEncoder,
        to id: ActorID,
        target: RemoteCallTarget
    ) async throws(RemoteInvocationCancellationError) -> Res {
        guard case .remote(let remote) = id.raw else {
            throw RemoteInvocationCancellationError.executionFailed(
                "Remote call on a local actor.")
        }
        guard let session = remote.session as? any OutboundSession else {
            throw RemoteInvocationCancellationError.executionFailed("""
                the session naming \(remote.key) can code actor ids but cannot send \
                invocations, so there is nowhere to send \(target.identifier).
                """)
        }
        return try await session.sendInvocation(to: id, target: target, invocation: &invocation)
    }

    /// The eighth requirement, and the one most easily missed: the runtime calls it to
    /// hand a returning target's result to the `ResultHandler` when the result type is
    /// only known dynamically.
    ///
    /// Apple's loads the `Decodable` and `Encodable` protocol descriptors, casts the
    /// metatype through `dynamic_cast_existential_2_unconditional` with **no branch on
    /// the result**, then does `resultBuffer.load(as:)` and calls
    /// `ResultHandler.onReturn(value:)`. Reproduced, cast included.
    ///
    /// **This is a trap, and it is chosen rather than inherited.** The criterion is the
    /// one ``actorReady(_:)`` already uses: a trap is right where nothing a peer sends can
    /// reach the failure, and a throw is right where the value shape is peer-influenced.
    /// A peer does choose the `remoteCallIdentifier`, so it chooses *which* target runs --
    /// but every distributed func in this process was compiled against
    /// `SerializationRequirement == any Codable`, so whichever one it names has a
    /// `Codable` return type, and a generic one can only be substituted through a
    /// `_DistributedActorStub` (``InvocationDecoder/decodeGenericSubstitutions()`` rejects
    /// everything else) whose requirement is `Codable` too. So a non-`Codable` metatype
    /// here means the Swift runtime handed us a return type its own type checker forbids:
    /// a programmer error in code we own with no correct recovery, not a bad message.
    /// Unlike Apple's bare `brk #1`, it says which type.
    public func invokeHandlerOnReturn(
        handler: ResultHandler,
        resultBuffer: UnsafeRawPointer,
        metatype: Any.Type
    ) async throws {
        guard let codable = metatype as? any Codable.Type else {
            preconditionFailure("""
                invokeHandlerOnReturn was handed \(metatype), which is not Codable; a \
                distributed func's return type must satisfy the system's \
                SerializationRequirement
                """)
        }
        // Implicit existential opening: `doInvoke` is generic and `codable` is the sole
        // use of the existential metatype, so Swift binds `T` to the dynamic type.
        func doInvoke<T: Codable>(_ type: T.Type) async throws {
            try await handler.onReturn(value: resultBuffer.load(as: T.self))
        }
        try await doInvoke(codable)
    }
}

// ===========================================================================================
// MARK: - The inbound thunk
// ===========================================================================================

/// How a stored `AnyObject` becomes a call on the actor it is.
///
/// `DistributedActorSystem.executeDistributedTarget` is generic over
/// `Act: DistributedActor where Act.ID == ActorID`, and `DistributedActor` has no primary
/// associated type -- so `any DistributedActor` cannot be opened into that constraint and
/// there is no way to reach the method from an erased reference. The thunk is manufactured
/// in ``XPCActorSystem/actorReady(_:)``, where `Act` is still concrete, and stored beside
/// the actor.
///
/// It takes the instance as a parameter rather than capturing it, so it holds nothing: the
/// system's registry is weak on purpose and a capturing thunk would quietly make it strong.
///
/// The `InboundInvocation` is passed rather than an `InvocationDecoder` because the
/// decoder is `inout` at the call site, and an `inout` parameter in a stored closure type
/// buys nothing here -- the decoder is built inside and consumed there.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
typealias InboundThunk = (
    _ instance: AnyObject,
    _ system: XPCActorSystem,
    _ target: RemoteCallTarget,
    _ decoder: InvocationDecoder,
    _ handler: ResultHandler
) async throws -> Void

// ===========================================================================================
// MARK: - The other two associated types
// ===========================================================================================

/// The same conformance test the encoder makes, and for the same reason: a name test would
/// pass for anything a user called `$Something`. Runtime-gated because `_DistributedActorStub`
/// is macOS 15+, above this module's floor; below it no conformer can exist and `false` is
/// correct. Shared by both inner decoders.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private func isDistributedActorStub(_ type: Any.Type) -> Bool {
    guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) else { return false }
    return type is any _DistributedActorStub.Type
}

/// Resolve the wire's generic substitutions, shared by both inner decoders.
///
/// **`protocolStub` is a generic substitution**, merged in *ahead of* `substitutions`. Two
/// wire keys, one `[Any.Type]`, stub first -- Apple's
/// `EncodedInvocationDecoder.decodeGenericSubstitutions` appends in exactly that order and the
/// order is observable by the runtime.
///
/// **Anything that is not a `Distributed._DistributedActorStub` is rejected.** That is the
/// receive-side counterpart of ``InvocationEncoder/recordGenericSubstitution(_:)`` refusing to
/// record one: `genericSubsitutions` cannot carry a real substitution on this wire in either
/// direction. Apple's message, verbatim. A name that does not resolve is rejected here too, by
/// the same guard -- an unresolvable name is certainly not a stub, and this *is* the later
/// failure ``SwiftType`` defers to, raised by the code that tried to use the type.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private func resolveGenericSubstitutions(
    protocolStub: SwiftType?, _ substitutions: [SwiftType]) throws -> [Any.Type] {
    var wire: [SwiftType] = []
    if let protocolStub { wire.append(protocolStub) }
    wire.append(contentsOf: substitutions)
    return try wire.map { named in
        guard let type = named.type, isDistributedActorStub(type) else {
            // Apple's literal, 38 bytes at the throw site in `0x2ad500220`. The name is
            // appended because theirs leaves the caller with nothing to look at.
            throw DistributedActorCodingError(
                message: "Failed to decode generic substitution. \(named.mangledTypeName)")
        }
        return type
    }
}

/// Apple's `XPCSystem.EncodedInvocationDecoder`: the encoded half. Holds an
/// ``InboundInvocation``, which has already done the hard part -- the header fields are decoded
/// eagerly and the arguments container is retained unconsumed, because an argument's type is
/// not known until `executeDistributedTarget` asks for it by static type. **That container is
/// the decoder's entire state**, which is why no index is tracked here and none is in Apple's.
///
/// **The session travels with the container, not beside it.** An argument holding an `ActorID`
/// needs `CodingUserInfoKey.xpcActorSession` to decode, and it has it: the container was vended
/// by the decoder that read the request, so it carries that decoder's `userInfo`. There is
/// deliberately no second `userInfo` on this type -- one would be a copy that could disagree
/// with the one actually in force.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
struct EncodedInvocationDecoder: DistributedTargetInvocationDecoder {

    public typealias SerializationRequirement = any Codable

    var invocation: InboundInvocation

    init(_ invocation: InboundInvocation) { self.invocation = invocation }

    mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        try resolveGenericSubstitutions(
            protocolStub: invocation.protocolStub, invocation.genericSubsitutions)
    }

    /// An absent `arguments` key is Apple's `nil` container and Apple's message, not a decode
    /// failure a request away -- see ``InboundInvocation/argumentsContainer``. `decode`
    /// advances the container's cursor in place; `self` is `mutating` so the advance is kept
    /// (a copy that is not stored is a decoder that returns argument 0 forever).
    mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard invocation.argumentsContainer != nil else {
            throw DistributedActorCodingError(message: "Found no arguments from decoder.")
        }
        return try invocation.argumentsContainer!.decode(Argument.self)
    }

    /// The resolved `errorType`, or `nil` for a name that does not resolve -- which is not the
    /// same as "the target cannot throw". The field whose *presence* signals throwing is read
    /// by ``Session`` directly, off the invocation, before the decoder is handed to the runtime.
    mutating func decodeErrorType() throws -> Any.Type? { invocation.errorType?.type }

    mutating func decodeReturnType() throws -> Any.Type? { invocation.returnType?.type }
}

/// Apple's `XPCSystem.DirectInvocationDecoder`: the same-process half that ``ServiceRegistry``
/// takes. It carries the caller's own recorded ``InvocationEncoder`` values, consumed
/// positionally by a cursor exactly as the encoded container's own cursor is, and decodes
/// nothing -- these are types and values this process already holds, so nothing crosses.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
struct DirectInvocationDecoder: DistributedTargetInvocationDecoder {

    public typealias SerializationRequirement = any Codable

    var arguments: [any Codable]
    var cursor = 0
    var protocolStub: SwiftType?
    var genericSubsitutions: [SwiftType]
    var returnType: SwiftType?
    var errorType: SwiftType?

    mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        try resolveGenericSubstitutions(protocolStub: protocolStub, genericSubsitutions)
    }

    /// Hands back the caller's own value, cast to the type the runtime asks for; a mismatch is
    /// a bug in this process rather than bad wire data. Exhaustion reports exactly as the
    /// encoded container's does.
    mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard cursor < arguments.count else {
            throw DistributedActorCodingError(message: "Found no arguments from decoder.")
        }
        let value = arguments[cursor]
        cursor += 1
        guard let typed = value as? Argument else {
            throw DistributedActorCodingError(
                message: "direct argument is \(type(of: value)), not \(Argument.self)")
        }
        return typed
    }

    mutating func decodeErrorType() throws -> Any.Type? { errorType?.type }

    mutating func decodeReturnType() throws -> Any.Type? { returnType?.type }
}

/// The inbound half of an invocation: the Swift runtime drives this to pull the arguments back
/// out of a `RemoteInvocationRequest` before calling the target.
///
/// Apple's `XPCSystem.InvocationDecoder` is a `{ mode: encoded | direct }` **wrapper** over
/// ``EncodedInvocationDecoder`` and ``DirectInvocationDecoder``, each a
/// `DistributedTargetInvocationDecoder` in its own right; this is that wrapper. The runtime
/// drives the wrapper (it is the system's `InvocationDecoder` associated type), and every call
/// forwards to whichever inner decoder the mode holds -- same header fields, same positional
/// argument consumption, two sources.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public struct InvocationDecoder: DistributedTargetInvocationDecoder {

    public typealias SerializationRequirement = any Codable

    enum Mode {
        case encoded(EncodedInvocationDecoder)
        case direct(DirectInvocationDecoder)
    }
    private var mode: Mode

    public init(_ invocation: InboundInvocation) {
        mode = .encoded(EncodedInvocationDecoder(invocation))
    }

    /// Build the direct decoder straight from the caller's recorded invocation -- the values
    /// are already in hand (see ``InvocationEncoder``'s "nothing is encoded here"). Apple's
    /// `InvocationEncoder.makeDirectInvocationDecoder(senderSession:receiverSession:)` resolves
    /// the types eagerly against the sessions; this reconstruction carries the encoder's
    /// ``SwiftType`` values and resolves them on demand, the same as the encoded path.
    init(direct encoder: InvocationEncoder) {
        mode = .direct(DirectInvocationDecoder(
            arguments: encoder.arguments,
            protocolStub: encoder.protocolStub,
            genericSubsitutions: encoder.genericSubsitutions,
            returnType: encoder.returnType,
            errorType: encoder.errorType))
    }

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        switch mode {
        case .encoded(var d): defer { mode = .encoded(d) }; return try d.decodeGenericSubstitutions()
        case .direct(var d): defer { mode = .direct(d) }; return try d.decodeGenericSubstitutions()
        }
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        switch mode {
        case .encoded(var d): defer { mode = .encoded(d) }; return try d.decodeNextArgument()
        case .direct(var d): defer { mode = .direct(d) }; return try d.decodeNextArgument()
        }
    }

    public mutating func decodeErrorType() throws -> Any.Type? {
        switch mode {
        case .encoded(var d): defer { mode = .encoded(d) }; return try d.decodeErrorType()
        case .direct(var d): defer { mode = .direct(d) }; return try d.decodeErrorType()
        }
    }

    public mutating func decodeReturnType() throws -> Any.Type? {
        switch mode {
        case .encoded(var d): defer { mode = .encoded(d) }; return try d.decodeReturnType()
        case .direct(var d): defer { mode = .direct(d) }; return try d.decodeReturnType()
        }
    }
}

/// Apple's `EncodedResultHandler.ReplyHandler`: the strategy that turns a target's `Result`
/// into a reply ``Packet/Payload``. Apple's sole conformer is
/// ``RemoteInvocationReplyEncoder`` (a nested type of `Session` in the binary), which carries
/// the request's `userInfo` so that a *returned* actor reference can encode itself.
///
/// `encodeReply` is non-throwing, matching the binary's signature
/// (`encodeReply<A: Codable, B: Error>(with: Result<A, B>) -> Payload`): a result that will
/// not encode becomes a *propagation-failure* reply rather than propagating out.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
protocol ReplyHandler {
    func encodeReply<Success: Codable, Failure: Error>(
        with result: Result<Success, Failure>) -> Packet.Payload
}

/// Apple's `Session.RemoteInvocationReplyEncoder`: the ``ReplyHandler`` that carries the
/// request's `userInfo`, so an actor reference returned from the target can encode itself
/// against the session that received the call.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
struct RemoteInvocationReplyEncoder: ReplyHandler, @unchecked Sendable {

    /// Carried forward from the request's own decode. Apple's `RemoteInvocationReplyEncoder`
    /// stores the same dictionary for the same reason.
    let userInfo: [CodingUserInfoKey: Any]

    /// `.success` → `[0, <value>]` (a void return arrives as `.success(Ack())`, which is
    /// `RemoteInvocationResponse<Ack>.void` -- the identical bytes); `.failure` →
    /// `[1, {"executionFailed": {"_0": "<description>"}}]`.
    ///
    /// **No concrete error crosses.** `RemoteInvocationFailure` carries a `String` and
    /// nothing else -- Apple's `", but XPCSystem does not support propagating errors."` -- so
    /// the description is the whole of what a peer can be told.
    func encodeReply<Success: Codable, Failure: Error>(
        with result: Result<Success, Failure>) -> Packet.Payload {
        do {
            switch result {
            case .success(let value):
                return try Packet.Payload(
                    encoding: RemoteInvocationResponse(result: value), userInfo: userInfo)
            case .failure(let error):
                return try Packet.Payload(
                    encoding: RemoteInvocationResponse<NoSuccess>.failure(
                        .executionFailed("\(error)")),
                    userInfo: userInfo)
            }
        } catch {
            // A result that will not encode is a propagation failure, not an execution one.
            // The fallback body is a single `String`, which cannot itself fail to encode.
            return (try? Packet.Payload(
                encoding: RemoteInvocationResponse<NoSuccess>.failure(
                    .resultPropagationFailed("\(error)")),
                userInfo: userInfo))!
        }
    }
}

/// Apple's `EncodedResultHandler`: the cross-process result handler. Each outcome is encoded
/// through its ``ReplyHandler`` into ``reply``, which ``Session`` reads back and sends.
///
/// **A class, where the rest of this module reaches for structs.** The runtime takes the
/// handler into `executeDistributedTarget`, writes the reply from inside, and the caller
/// reads it back afterwards -- that needs reference identity. `@unchecked Sendable` with a
/// lock over the one mutable field: the write happens on whatever executor the target ran on
/// and the read happens on the execution task, ordered by the `await` -- but "ordered in the
/// only way we call it" is not a property the type can state, and a lock costs one uncontended
/// acquire.
///
/// **`canThrow == false` throws in `onThrow`; Apple `fatalError`s.** Their message is
/// `"API violation: Swift threw \(error) in a distributed func that doesn't throw."` and it
/// kills the callee. Ours says the same thing and does not, because the signal is
/// `errorType`'s presence in a request a *peer* wrote: a peer that omits the key while naming
/// a throwing target would otherwise be able to crash this process on demand. This is the
/// same trade `ActorID.encode(to:)` already makes against the same binary.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class EncodedResultHandler: DistributedTargetInvocationResultHandler, @unchecked Sendable {

    typealias SerializationRequirement = any Codable

    let replyHandler: any ReplyHandler
    let canThrow: Bool

    private let _reply = Mutex<Packet.Payload?>(nil)

    /// The reply to send, or `nil` if the target produced no outcome. Apple's
    /// `EncodedResultHandler.reply`.
    var reply: Packet.Payload? { _reply.withLock { $0 } }

    init(_ replyHandler: any ReplyHandler, canThrow: Bool) {
        self.replyHandler = replyHandler
        self.canThrow = canThrow
    }

    func onReturn<Success: Codable>(value: Success) async throws {
        let payload = replyHandler.encodeReply(with: Result<Success, Never>.success(value))
        _reply.withLock { $0 = payload }
    }

    /// A void return is `.success(Ack())`, tag zero over an ``Ack`` -- `Void` is not `Codable`
    /// and something has to occupy the generic parameter.
    func onReturnVoid() async throws {
        let payload = replyHandler.encodeReply(with: Result<Ack, Never>.success(Ack()))
        _reply.withLock { $0 = payload }
    }

    func onThrow<Err: Error>(error: Err) async throws {
        guard canThrow else {
            throw RemoteInvocationCancellationError.executionFailed("""
                API violation: Swift threw \(error) in a distributed func that doesn't \
                throw. The invocation carried no errorType, so this target was announced \
                as non-throwing.
                """)
        }
        let payload = replyHandler.encodeReply(with: Result<NoSuccess, Err>.failure(error))
        _reply.withLock { $0 = payload }
    }
}

/// Apple's `DirectResultHandler`: the same-process result handler. It captures the raw
/// outcome instead of encoding it, so the caller reads its own return type back without a
/// byte crossing. `capturedResult` is Apple's field, a `Result<any Codable, any Error>?`
/// (a void return is `.success(Ack())`).
///
/// **No `canThrow`.** Apple's `DirectResultHandler.init()` takes none: a same-process capture
/// has no *peer*-written request to guard against, so a throw is captured unconditionally and
/// the direct caller (``Session/directSend(key:target:invocation:peer:)``) rethrows it.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class DirectResultHandler: DistributedTargetInvocationResultHandler, @unchecked Sendable {

    typealias SerializationRequirement = any Codable

    private let _captured = Mutex<Result<any Codable, any Error>?>(nil)

    /// The captured outcome, or `nil` if the target produced none. Apple's
    /// `DirectResultHandler.capturedResult`.
    var capturedResult: Result<any Codable, any Error>? { _captured.withLock { $0 } }

    init() {}

    func onReturn<Success: Codable>(value: Success) async throws {
        _captured.withLock { $0 = .success(value) }
    }

    func onReturnVoid() async throws {
        _captured.withLock { $0 = .success(Ack()) }
    }

    func onThrow<Err: Error>(error: Err) async throws {
        _captured.withLock { $0 = .failure(error) }
    }
}

/// Where the outcome of an executed target goes. Apple's `ResultHandler` is the
/// `DistributedActorSystem`'s `ResultHandler` associated type: a **wrapper** over
/// `{ EncodedResultHandler | DirectResultHandler }` -- confirmed by the live `XPCDistributed`
/// image, which carries both inner classes (each conforming to
/// `DistributedTargetInvocationResultHandler` in its own right) and the two wrapper
/// initializers `init(_: EncodedResultHandler.ReplyHandler, canThrow: Bool)` and
/// `init(direct: DirectResultHandler)`. The runtime calls `on*` on the wrapper; the wrapper
/// forwards to whichever inner handler it holds, and ``Session`` reads the outcome back off
/// that inner handler (``reply`` for encoded, ``capturedResult`` for direct).
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public final class ResultHandler: DistributedTargetInvocationResultHandler,
                                  @unchecked Sendable {

    public typealias SerializationRequirement = any Codable

    enum Mode {
        case encoded(EncodedResultHandler)
        case direct(DirectResultHandler)
    }
    let mode: Mode

    /// Apple's `ResultHandler.init(_: EncodedResultHandler.ReplyHandler, canThrow: Bool)`.
    init(_ replyHandler: any ReplyHandler, canThrow: Bool) {
        self.mode = .encoded(EncodedResultHandler(replyHandler, canThrow: canThrow))
    }

    /// The encoded handler built from a request's `userInfo`, the form ``Session`` and the
    /// tests reach for. Wraps a ``RemoteInvocationReplyEncoder`` -- Apple's `ReplyHandler`.
    convenience init(canThrow: Bool, userInfo: [CodingUserInfoKey: Any]) {
        self.init(RemoteInvocationReplyEncoder(userInfo: userInfo), canThrow: canThrow)
    }

    /// Apple's `ResultHandler.init(direct: DirectResultHandler)`.
    init(direct: DirectResultHandler) { self.mode = .direct(direct) }

    /// The direct (same-process) handler, ungated. Convenience over `init(direct:)`.
    static func direct() -> ResultHandler { ResultHandler(direct: DirectResultHandler()) }

    /// The reply to send (encoded mode), or `nil`. Apple's `EncodedResultHandler.reply`,
    /// surfaced through the wrapper.
    public var reply: Packet.Payload? {
        if case .encoded(let handler) = mode { return handler.reply }
        return nil
    }

    /// The captured outcome (direct mode), or `nil`. Apple's
    /// `DirectResultHandler.capturedResult`, surfaced through the wrapper.
    var capturedResult: Result<any Codable, any Error>? {
        if case .direct(let handler) = mode { return handler.capturedResult }
        return nil
    }

    public func onReturn<Success: Codable>(value: Success) async throws {
        switch mode {
        case .encoded(let handler): try await handler.onReturn(value: value)
        case .direct(let handler): try await handler.onReturn(value: value)
        }
    }

    public func onReturnVoid() async throws {
        switch mode {
        case .encoded(let handler): try await handler.onReturnVoid()
        case .direct(let handler): try await handler.onReturnVoid()
        }
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        switch mode {
        case .encoded(let handler): try await handler.onThrow(error: error)
        case .direct(let handler): try await handler.onThrow(error: error)
        }
    }
}

// ===========================================================================================
// MARK: - RemoteInvocationCancellationError
// ===========================================================================================

/// Why a remote invocation did not produce a result.
///
/// Apple's `XPCSystem.RemoteInvocationCancellationError`, and the error type
/// `remoteCall`'s typed throws names. Two stored properties, a `Reason` and an optional
/// message, with the four reasons carrying fixed default texts that the message is
/// appended to -- `defaultText + ". " + (message ?? "")`. All of that is read out of the
/// binary rather than invented, including the pairing that makes `.executionFailed` say
/// the invocation was *not* executed.
///
/// Only `.executionFailed` is constructed in this slice, by the stubs. The other three
/// belong to the transport and cancellation paths.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public struct RemoteInvocationCancellationError: Error, Equatable, Sendable,
                                                 CustomStringConvertible {

    /// Tag order is Apple's, read three ways over: field-record order, the value witness
    /// table, and the four static factories writing the tag literally.
    public enum Reason: Hashable, Sendable {
        case underlyingSessionCancelled   // tag 0
        case callingTaskCancelled         // tag 1
        case executionFailed              // tag 2
        case resultPropagationFailed      // tag 3

        /// Read out of the image at the pointers `message.getter`'s `csel` chain selects,
        /// with the lengths it selects.
        var defaultText: String {
            switch self {
            case .underlyingSessionCancelled: return "Underlying session was cancelled"
            case .callingTaskCancelled: return "The task calling the distributed invocation was cancelled"
            case .executionFailed: return "The distributed invocation was not executed"
            case .resultPropagationFailed:
                return "Failed to obtain the result of the distributed invocation after it was executed"
            }
        }
    }

    public let reason: Reason
    private let detail: String?

    public init(reason: Reason, message: String?) {
        self.reason = reason
        self.detail = message
    }

    /// `.callingTaskCancelled` takes no message and stores nil; the other three take one.
    /// That asymmetry is Apple's -- their factory writes `stp xzr, xzr`.
    public static func underlyingSessionCancelled(_ message: String) -> Self {
        .init(reason: .underlyingSessionCancelled, message: message)
    }
    public static func callingTaskCancelled() -> Self {
        .init(reason: .callingTaskCancelled, message: nil)
    }
    public static func executionFailed(_ message: String) -> Self {
        .init(reason: .executionFailed, message: message)
    }
    public static func resultPropagationFailed(_ message: String) -> Self {
        .init(reason: .resultPropagationFailed, message: message)
    }

    /// `defaultText + ". " + (detail ?? "")`, which is what Apple's `message.getter`
    /// builds -- trailing separator and all, when there is no detail.
    public var message: String { "\(reason.defaultText). \(detail ?? "")" }

    public var description: String { message }
}
