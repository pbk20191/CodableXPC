// Sources/XPCActors/XPCActorSystem.swift
import Distributed
import Foundation

/// The `DistributedActorSystem`. Apple calls theirs `XPCSystem`; the name is ours, the
/// behaviour is not.
///
/// **This slice is the identity half.** `assignID`, `actorReady`, `resignID`, `resolve`
/// and `makeInvocationEncoder` are built for real. `remoteCall`, `remoteCallVoid` and
/// `invokeHandlerOnReturn` need a `Session` wired to a `Transport`, which does not exist
/// yet; they throw, visibly, and say so. See ``notWiredYet(_:)``.
///
/// `final`, where Apple's is not: `XPCSystem` has a vtable covering only its four
/// initialisers, which is what a non-`final` class produces, and subclassing it is not a
/// documented extension point. Nothing here needs to be overridable, and `final` is what
/// lets this be `Sendable` rather than `@unchecked Sendable`.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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
    /// `ActorRegistry<Void>` because there is no thunk. The generic parameter is a
    /// placeholder from the slice that introduced the registry; Apple's table stores a
    /// `WeakActorRef` and nothing else, so `Void` is not a stand-in for something we have
    /// not written yet -- it is the honest width of the entry. If the inbound execution
    /// path later needs a per-actor thunk it can widen this, and the reconstruction says
    /// Apple's does not.
    ///
    /// `internal`, not `private`: `Session` needs it in order to turn a local id into an
    /// instance, and Apple's `XPCSystem.resolve(id:)` is likewise non-private for exactly
    /// that caller.
    let registry = ActorRegistry<Void>()

    public init(_ debugName: String) {
        self.debugName = debugName
        self.id = ID64.next()
    }
}

// ===========================================================================================
// MARK: - The conformance
// ===========================================================================================

/// Apple's `XPCSystem` witnesses all eight `DistributedActorSystem` requirements, and so
/// does this.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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
        registry.register(actor, id: local, thunk: ())
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

    // MARK: The call requirements -- stubbed, visibly

    /// **Not wired yet.** S3 gives a `Session` a `Transport`; at that point this becomes
    /// Apple's private funnel: read the actor's session out of its `.remote` id, throw
    /// `RemoteInvocationCancellationError(reason: .executionFailed, message: "Remote call
    /// on a local actor.")` if there is none, and otherwise hand the encoder to
    /// `Session.sendInvocation(to:target:invocation:)`, which assembles a
    /// `RemoteInvocationRequest`, awaits the reply through `RequestTable`, and decodes the
    /// `Res` out of the response body.
    ///
    /// It throws rather than returning something plausible on purpose. A stub that
    /// returned a default value would let a caller believe a call had happened.
    ///
    /// **Typed throws, and the asymmetry with `remoteCallVoid` below is Apple's.** Their
    /// `remoteCall` mangles as `throws(RemoteInvocationCancellationError)` while
    /// `remoteCallVoid` mangles as plain `throws`; the reconstruction lists *why* as
    /// unresolved but the manglings themselves are unambiguous. Reproduced rather than
    /// tidied, because a mirror that "fixes" an asymmetry it does not understand is
    /// guessing.
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws(RemoteInvocationCancellationError) -> Res
    where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: Codable {
        throw Self.notWiredYet("remoteCall(on:target:invocation:throwing:returning:)")
    }

    /// **Not wired yet**, as `remoteCall` above. Apple binds the result type to their
    /// `Ack` and otherwise takes the same path.
    ///
    /// Plain `throws`, which is Apple's spelling here and not a transcription slip.
    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        throw Self.notWiredYet("remoteCallVoid(on:target:invocation:throwing:)")
    }

    /// **Not wired yet.** The eighth requirement, and the one most easily missed: the
    /// runtime calls it to hand a returning target's result to the `ResultHandler` when
    /// the result type is only known dynamically.
    ///
    /// Apple's loads the `Decodable` and `Encodable` protocol descriptors, casts the
    /// metatype through `dynamic_cast_existential_2_unconditional` with **no branch on
    /// the result** -- so a non-`Codable` return type traps the callee -- then does
    /// `resultBuffer.load(as:)` and calls `ResultHandler.onReturn(value:)`. It belongs
    /// with the inbound execution path, which is where the `ResultHandler` comes from.
    public func invokeHandlerOnReturn(
        handler: ResultHandler,
        resultBuffer: UnsafeRawPointer,
        metatype: Any.Type
    ) async throws {
        throw Self.notWiredYet("invokeHandlerOnReturn(handler:resultBuffer:metatype:)")
    }

    /// One spelling for every **outbound** stub, so a caller who hits one gets the same
    /// sentence and the same reason wherever it came from.
    ///
    /// Outbound only, deliberately. The inbound stubs -- the decoder and the result
    /// handler -- use ``notWiredYetInbound(_:)`` instead, because a decoder that cannot
    /// decode an argument is not a cancelled remote invocation, and a later slice that
    /// grows a `catch` on `RemoteInvocationCancellationError` must not catch one.
    static func notWiredYet(_ what: String) -> RemoteInvocationCancellationError {
        .executionFailed("""
            \(what) is not wired yet: it needs an outbound Session over a Transport, \
            which this slice does not build. Nothing has been sent to the peer.
            """)
    }

    /// The inbound counterpart. A different error type on purpose -- see
    /// ``notWiredYet(_:)``.
    static func notWiredYetInbound(_ what: String) -> SetupError {
        SetupError("""
            \(what) is not wired yet: it needs the inbound path, which this slice does \
            not build. Nothing has been decoded.
            """)
    }
}

// ===========================================================================================
// MARK: - The other two associated types -- stubbed, visibly
// ===========================================================================================

/// **Not wired yet.** The inbound half of an invocation: the Swift runtime drives this to
/// pull the arguments back out of a `RemoteInvocationRequest` before calling the target.
///
/// It exists because `DistributedActorSystem` names it as an associated type and the
/// conformance cannot be written without one -- not because there is anything to decode
/// yet. Every method throws. Apple's is `XPCSystem.InvocationDecoder` (and a second,
/// `DirectInvocationDecoder`, for the in-process path); the wire shapes it will read are
/// already resolved in `InvocationBodies.swift`.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct InvocationDecoder: DistributedTargetInvocationDecoder {

    public typealias SerializationRequirement = any Codable

    public init() {}

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        throw XPCActorSystem.notWiredYetInbound("InvocationDecoder.decodeGenericSubstitutions()")
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        throw XPCActorSystem.notWiredYetInbound("InvocationDecoder.decodeNextArgument()")
    }

    public mutating func decodeErrorType() throws -> Any.Type? {
        throw XPCActorSystem.notWiredYetInbound("InvocationDecoder.decodeErrorType()")
    }

    public mutating func decodeReturnType() throws -> Any.Type? {
        throw XPCActorSystem.notWiredYetInbound("InvocationDecoder.decodeReturnType()")
    }
}

/// **Not wired yet.** Where the outcome of an executed target goes: a value, nothing, or
/// an error, each of which becomes a `RemoteInvocationResponse` body.
///
/// The bodies it will write are already resolved -- see `InvocationBodies.swift`, and in
/// particular that `onReturnVoid()` sends an `Ack` rather than an empty body. Nothing
/// here fakes that; every method throws.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct ResultHandler: DistributedTargetInvocationResultHandler {

    public typealias SerializationRequirement = any Codable

    public init() {}

    public func onReturn<Success: Codable>(value: Success) async throws {
        throw XPCActorSystem.notWiredYetInbound("ResultHandler.onReturn(value:)")
    }

    public func onReturnVoid() async throws {
        throw XPCActorSystem.notWiredYetInbound("ResultHandler.onReturnVoid()")
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        throw XPCActorSystem.notWiredYetInbound("ResultHandler.onThrow(error:)")
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
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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
