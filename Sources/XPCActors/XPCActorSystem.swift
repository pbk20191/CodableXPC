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
    /// exist over there because `preserveSelfIPC` is the other axis and there is no
    /// in-process path in this module to preserve.
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
        let thunk: InboundThunk = { instance, system, target, invocation, handler in
            guard let target1 = instance as? Act else {
                throw SetupError("""
                    the actor registered for \(local) is a \(type(of: instance)), not a \
                    \(Act.self); the invocation thunk and the instance have come apart
                    """)
            }
            var decoder = InvocationDecoder(invocation)
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
    _ invocation: InboundInvocation,
    _ handler: ResultHandler
) async throws -> Void

// ===========================================================================================
// MARK: - The other two associated types
// ===========================================================================================

/// The inbound half of an invocation: the Swift runtime drives this to pull the arguments
/// back out of a `RemoteInvocationRequest` before calling the target.
///
/// Apple's is `XPCSystem.InvocationDecoder`, a `{ mode: encoded | direct }` wrapper around
/// `EncodedInvocationDecoder` and `DirectInvocationDecoder`. There is no in-process path
/// here, so there is no wrapper and no mode: this *is* the encoded decoder.
///
/// It holds an ``InboundInvocation``, which has already done the hard part -- the header
/// fields are decoded eagerly and the arguments container is retained unconsumed, because
/// an argument's type is not known until `executeDistributedTarget` asks for it by static
/// type. **That container is the decoder's entire state**, which is why no index is
/// tracked here and none is tracked in Apple's either.
///
/// **The session travels with the container, not beside it.** An argument holding an
/// `ActorID` needs `CodingUserInfoKey.xpcActorSession` to decode, and it has it: the
/// container was vended by the decoder that read the request, so it carries that decoder's
/// `userInfo`. There is deliberately no second `userInfo` on this type -- one would be a
/// copy that could disagree with the one actually in force.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public struct InvocationDecoder: DistributedTargetInvocationDecoder {

    public typealias SerializationRequirement = any Codable

    /// Apple's `{ mode: encoded | direct }`. The **encoded** mode reads an
    /// ``InboundInvocation`` off the wire; the **direct** mode -- the same-process path that
    /// ``ServiceRegistry`` takes -- carries the caller's own recorded values and never
    /// decodes a byte. Same header fields, same positional argument consumption, two sources.
    enum Mode {
        case encoded(InboundInvocation)
        case direct(Direct)
    }

    /// The direct mode's state: the caller's ``InvocationEncoder`` values, consumed
    /// positionally by a cursor exactly as the encoded container's own cursor is.
    struct Direct {
        var arguments: [any Codable]
        var cursor = 0
        var protocolStub: SwiftType?
        var genericSubsitutions: [SwiftType]
        var returnType: SwiftType?
        var errorType: SwiftType?
    }

    private var mode: Mode

    public init(_ invocation: InboundInvocation) { mode = .encoded(invocation) }

    /// Build the direct decoder straight from the caller's recorded invocation -- the values
    /// are already in hand (see ``InvocationEncoder``'s "nothing is encoded here").
    init(direct encoder: InvocationEncoder) {
        mode = .direct(Direct(
            arguments: encoder.arguments,
            protocolStub: encoder.protocolStub,
            genericSubsitutions: encoder.genericSubsitutions,
            returnType: encoder.returnType,
            errorType: encoder.errorType))
    }

    /// **`protocolStub` is a generic substitution**, and it is merged in *ahead of*
    /// `genericSubsitutions`. Two wire keys, one `[Any.Type]`, stub first -- Apple's
    /// `EncodedInvocationDecoder.decodeGenericSubstitutions` appends in exactly that order
    /// and the order is observable by the runtime.
    ///
    /// **Anything that is not a `Distributed._DistributedActorStub` is rejected.** That is
    /// the receive-side counterpart of ``InvocationEncoder/recordGenericSubstitution(_:)``
    /// refusing to record one: `genericSubsitutions` cannot carry a real substitution on
    /// this wire in either direction. Apple's message, verbatim.
    ///
    /// A name that does not resolve is rejected here too, and by the same guard -- an
    /// unresolvable name is certainly not a stub. That is not in tension with
    /// ``SwiftType``'s "resolution failure is a later failure": this *is* the later
    /// failure, raised by the code that tried to use the type rather than by the decode.
    ///
    /// The direct mode carries the same two fields (stub, substitutions) and resolves them
    /// the same way -- these are types this process already holds, so nothing crosses.
    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        var wire: [SwiftType] = []
        switch mode {
        case .encoded(let invocation):
            if let stub = invocation.protocolStub { wire.append(stub) }
            wire.append(contentsOf: invocation.genericSubsitutions)
        case .direct(let direct):
            if let stub = direct.protocolStub { wire.append(stub) }
            wire.append(contentsOf: direct.genericSubsitutions)
        }
        return try wire.map { named in
            guard let type = named.type, Self.isDistributedActorStub(type) else {
                // Apple's literal, 38 bytes at the throw site in `0x2ad500220`. The name
                // is appended because theirs leaves the caller with nothing to look at.
                throw DistributedActorCodingError(
                    message: "Failed to decode generic substitution. \(named.mangledTypeName)")
            }
            return type
        }
    }

    /// Pull the next argument. Positional: a cursor is the whole state, on either source.
    ///
    /// An absent `arguments` key is Apple's `nil` container and Apple's message, not a
    /// decode failure a request away -- see ``InboundInvocation/argumentsContainer``. The
    /// direct mode never decodes: it hands back the caller's own value, cast to the type the
    /// runtime asks for, and a mismatch is a bug in this process rather than bad wire data.
    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        switch mode {
        case .encoded(var invocation):
            guard invocation.argumentsContainer != nil else {
                throw DistributedActorCodingError(message: "Found no arguments from decoder.")
            }
            // Written back, always: `decode` advances the container's cursor, and a copy
            // that is not stored is a decoder that returns argument 0 forever.
            defer { mode = .encoded(invocation) }
            return try invocation.argumentsContainer!.decode(Argument.self)
        case .direct(var direct):
            guard direct.cursor < direct.arguments.count else {
                throw DistributedActorCodingError(message: "Found no arguments from decoder.")
            }
            let value = direct.arguments[direct.cursor]
            direct.cursor += 1
            mode = .direct(direct)
            guard let typed = value as? Argument else {
                throw DistributedActorCodingError(
                    message: "direct argument is \(type(of: value)), not \(Argument.self)")
            }
            return typed
        }
    }

    /// The resolved `errorType`, or `nil`.
    ///
    /// `nil` for a name that does not resolve, which is not the same message as "the target
    /// cannot throw" -- but it is the only one this requirement can carry, and the field
    /// whose *presence* actually signals throwing is read by ``Session`` directly, off the
    /// invocation, before the decoder is handed to the runtime.
    public mutating func decodeErrorType() throws -> Any.Type? {
        switch mode {
        case .encoded(let invocation): invocation.errorType?.type
        case .direct(let direct): direct.errorType?.type
        }
    }

    public mutating func decodeReturnType() throws -> Any.Type? {
        switch mode {
        case .encoded(let invocation): invocation.returnType?.type
        case .direct(let direct): direct.returnType?.type
        }
    }

    /// The same conformance test the encoder makes, and for the same reason: a name test
    /// would pass for anything a user called `$Something`. Runtime-gated because
    /// `_DistributedActorStub` is macOS 15+, above this type's floor; below it no
    /// conformer can exist and `false` is correct.
    private static func isDistributedActorStub(_ type: Any.Type) -> Bool {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) else { return false }
        return type is any _DistributedActorStub.Type
    }
}

/// Where the outcome of an executed target goes: a value, nothing, or an error, each of
/// which becomes a `RemoteInvocationResponse` body.
///
/// **A class, where the rest of this module reaches for structs.** Apple's `ResultHandler`
/// and `EncodedResultHandler` are both classes, and it is not a style choice: the runtime
/// takes the handler by value into `executeDistributedTarget`, writes the reply from
/// inside, and the caller reads it back afterwards. That needs reference identity.
///
/// `@unchecked Sendable` with a lock over the one mutable field: the write happens on
/// whatever executor the target ran on and the read happens on the execution task, so the
/// two are ordered by the `await` -- but "ordered in the only way we call it" is not a
/// property the type can state, and a lock costs one uncontended acquire.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public final class ResultHandler: DistributedTargetInvocationResultHandler,
                                  @unchecked Sendable {

    public typealias SerializationRequirement = any Codable

    /// Apple's `EncodedResultHandler.canThrow`, and its only resolved consumer is
    /// ``onThrow(error:)``.
    ///
    /// **How it is computed is an inference, and it is marked as one in the
    /// reconstruction** (`Invocation.swift`, UNRESOLVED 4): no direct caller of the
    /// handler's initializer survives in Apple's image, so nothing reads out what feeds
    /// the byte. `errorType != nil` is the reading the reconstruction calls obvious --
    /// `recordErrorType` is not called at all for a non-throwing target, so the field's
    /// presence is exactly the signal -- and it is what ``Session`` passes.
    let canThrow: Bool

    /// Carried forward from the request's own decode, so that a *returned* actor reference
    /// can encode itself. Apple's `RemoteInvocationReplyEncoder` stores the same
    /// dictionary for the same reason.
    private let userInfo: [CodingUserInfoKey: Any]

    private let _reply = Mutex<Packet.Payload?>(nil)

    /// The reply to send, or `nil` if the target produced no outcome. Apple's
    /// `EncodedResultHandler.reply`.
    public var reply: Packet.Payload? { _reply.withLock { $0 } }

    init(canThrow: Bool, userInfo: [CodingUserInfoKey: Any]) {
        self.canThrow = canThrow
        self.userInfo = userInfo
    }

    /// `[0, <value>]`. `Failure` is bound to `Never` in Apple's `Result`; ours does not
    /// need the parameter at all because the response enum carries the tag itself.
    public func onReturn<Success: Codable>(value: Success) async throws {
        try write(RemoteInvocationResponse(result: value))
    }

    /// `[0, {}]` -- tag zero over an ``Ack``, because `Void` is not `Codable` and something
    /// has to occupy the generic parameter.
    public func onReturnVoid() async throws {
        try write(RemoteInvocationResponse<Ack>.void)
    }

    /// `[1, {"executionFailed": {"_0": "<description>"}}]`.
    ///
    /// **No concrete error crosses.** `RemoteInvocationFailure` carries a `String` and
    /// nothing else -- Apple's `", but XPCSystem does not support propagating errors."` --
    /// so the description is the whole of what a peer can be told.
    ///
    /// **`canThrow == false` throws here; Apple `fatalError`s.** Their message is
    /// `"API violation: Swift threw \(error) in a distributed func that doesn't throw."`
    /// and it kills the callee. Ours says the same thing and does not, because the signal
    /// is `errorType`'s presence in a request a *peer* wrote: a peer that omits the key
    /// while naming a throwing target would otherwise be able to crash this process on
    /// demand. This is the same trade `ActorID.encode(to:)` already makes against the same
    /// binary, and the reason is written there at length.
    public func onThrow<Err: Error>(error: Err) async throws {
        guard canThrow else {
            throw RemoteInvocationCancellationError.executionFailed("""
                API violation: Swift threw \(error) in a distributed func that doesn't \
                throw. The invocation carried no errorType, so this target was announced \
                as non-throwing.
                """)
        }
        try write(RemoteInvocationResponse<NoSuccess>.failure(.executionFailed("\(error)")))
    }

    private func write(_ response: some Encodable) throws {
        let payload = try Packet.Payload(encoding: response, userInfo: userInfo)
        _reply.withLock { $0 = payload }
    }
}

// ===========================================================================================
// MARK: - The direct result handler
// ===========================================================================================

/// Apple's `DirectResultHandler`: the same-process counterpart of ``ResultHandler``. Where
/// that one encodes the target's outcome into a `RemoteInvocationResponse` body,
/// this one **captures the raw value** -- Apple's `DirectResultHandler.capturedResult` --
/// so the caller reads its own return type back without a byte crossing.
///
/// A class for the same reason ``ResultHandler`` is: the runtime takes the handler into
/// `executeDistributedTarget` and writes the outcome from inside.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class DirectResultHandler: DistributedTargetInvocationResultHandler, @unchecked Sendable {

    public typealias SerializationRequirement = any Codable

    /// The captured outcome. `value` boxes the concrete `Success` the target returned; the
    /// direct send casts it back to the caller's static return type.
    enum Outcome {
        case value(any Codable)
        case void
        case failure(any Error)
    }

    private let outcome = Mutex<Outcome?>(nil)
    var capturedResult: Outcome? { outcome.withLock { $0 } }

    func onReturn<Success: Codable>(value: Success) async throws {
        outcome.withLock { $0 = .value(value) }
    }

    func onReturnVoid() async throws {
        outcome.withLock { $0 = .void }
    }

    func onThrow<Err: Error>(error: Err) async throws {
        outcome.withLock { $0 = .failure(error) }
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
