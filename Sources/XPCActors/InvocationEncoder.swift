import Foundation
import Distributed

/// Accumulates one outbound invocation.
///
/// The Swift runtime drives this: it records the generic substitutions, then each
/// argument in declaration order, then the error and return types, then calls
/// `doneRecording`. Nothing is encoded here -- the values are held until
/// `makeInvocationBody` / `makeRequest` assemble them, because the actor key is not
/// known until the session shares it.
///
/// The five stored properties below are exactly Apple's, and exactly the five wire keys
/// of `XPCSystem.InvocationCodingKeys`. They hold `SwiftType`, not `String`: a mangled
/// name only means anything wrapped, and keeping the wrapper here rather than at the
/// boundary is what stops a display string from being spelled the same way as a mangled
/// one. See `docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md`.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct InvocationEncoder: DistributedTargetInvocationEncoder {

    public typealias SerializationRequirement = any Codable

    /// The `_DistributedActorStub` this call goes through, when it targets a distributed
    /// *protocol* rather than a concrete actor type. At most one; see
    /// `recordGenericSubstitution`, which is where it is captured.
    public private(set) var protocolStub: SwiftType?
    /// Always `[]`, and deliberately still a stored property.
    ///
    /// Apple's own `encode(to:)` traps -- `"Bug in XPCDistributed: Found generic
    /// substitutions during encoding."` then `BRK` -- rather than serialise a non-empty
    /// one, so a non-empty array is unrepresentable on this wire. `recordGenericSubstitution`
    /// below therefore refuses to fill it. The field stays because the key stays: it is
    /// not optional, it is always written, and an absent key is a different message from
    /// an empty array.
    public let genericSubsitutions: [SwiftType] = []
    public private(set) var arguments: [any Codable] = []
    /// Present exactly when the target can throw -- its presence is the signal.
    public private(set) var errorType: SwiftType?
    public private(set) var returnType: SwiftType?

    public init() {}

    /// Where `protocolStub` comes from.
    ///
    /// `DistributedTargetInvocationEncoder` has no `recordProtocolStub` and Apple did not
    /// add one -- their `InvocationEncoder`'s only protocol witnesses are the four
    /// `record*` methods plus `doneRecording`. Both of the relevant error strings resolve
    /// to this one function in the shipping binary (`0x2ad4ff6e4`):
    ///
    ///     "Encoding second _DistributedActorStub "
    ///     "Failed to record generic substitution of type "
    ///
    /// It branches on the recorded type, wraps it with `SwiftType.init<A>(A.Type)`, and
    /// throws `DistributedActorCodingError` in both failing cases -- thrown, not trapped.
    ///
    /// **Deliberate deviation from Apple, in timing and failure mode but not in bytes.**
    /// Apple accepts a non-stub substitution here and dies much later, inside
    /// `encode(to:)`, on a `BRK` with no indication of which call produced it. We refuse
    /// it at the call site that caused it, with the type in the message. The wire outcome
    /// is identical either way -- a non-empty `genericSubsitutions` cannot be sent by
    /// either implementation -- and this is a local programmer error, never
    /// peer-controlled input, so failing early costs nothing and names the culprit.
    ///
    /// Two declarations trigger it, and the second is the surprising one: a generic
    /// distributed *func*, and a generic distributed **actor**. A `distributed actor
    /// Foo<T>` records its own generic arguments on every call, including calls to
    /// entirely non-generic funcs -- so declaring the actor generic is enough to make
    /// every remote call on it unrepresentable. The message names both causes because
    /// someone who never wrote a generic func would not otherwise connect the two.
    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        guard Self.isDistributedActorStub(type) else {
            throw DistributedActorCodingError(message: """
                Failed to record generic substitution of type \(type): XPCDistributed's \
                invocation format cannot carry generic substitutions -- genericSubsitutions \
                is always empty on the wire, and Apple's own encoder traps rather than \
                serialise a non-empty one. Only a _DistributedActorStub may be recorded \
                here. The cause is either a generic distributed func, or a generic \
                distributed actor -- a `distributed actor Foo<T>` records its generic \
                arguments on every call, even to non-generic funcs.
                """)
        }
        if let existing = protocolStub {
            throw DistributedActorCodingError(message: """
                Encoding second _DistributedActorStub \(type): an invocation carries at \
                most one, and \(existing.mangledTypeName) was already recorded.
                """)
        }
        // Failable on purpose, and not degraded: a stub with no mangled name is a name no
        // peer can resolve, and unlike `errorType` there is nothing here whose mere
        // presence carries meaning.
        guard let stub = SwiftType(type) else {
            throw DistributedActorCodingError(message: """
                Failed to record generic substitution of type \(type): it has no mangled \
                name, so no peer could resolve it.
                """)
        }
        protocolStub = stub
    }

    /// `_DistributedActorStub` is `Distributed`'s own marker for a `@Resolvable`-generated
    /// protocol stub. Detected by conformance rather than by name -- a name test would
    /// pass for anything a user chose to call `$Something`, and fail for a stub Apple
    /// renames.
    ///
    /// The protocol is macOS 15+, which is above this type's own floor, so the check is
    /// runtime-gated. Below that floor no conformer can exist, and `false` is correct.
    private static func isDistributedActorStub(_ type: Any.Type) -> Bool {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) else { return false }
        return type is any _DistributedActorStub.Type
    }

    public mutating func recordArgument<Value: Codable>(
        _ argument: RemoteCallArgument<Value>
    ) throws {
        // The label and the parameter name are dropped on purpose: the receiver knows
        // both statically from the callee signature.
        arguments.append(argument.value)
    }

    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {
        // The one degradation this encoder permits, and it is spelled out here rather
        // than hidden inside `SwiftType`'s initializer so that every other caller of that
        // initializer keeps failing loudly.
        //
        // `"\(type)"` is a *display* string. It is not a mangled name, no peer can feed
        // it to `_typeByName`, and it is guaranteed not to resolve on the far side. It is
        // still the right answer here, and only here: `errorType`'s **presence** is what
        // tells the receiver this target can throw, so dropping the key would change the
        // meaning of the call -- a worse outcome than a name the receiver cannot use.
        errorType = SwiftType(type) ?? SwiftType(mangledTypeName: "\(type)")
    }

    public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {
        // No such excuse here. An absent `returnType` and an unresolvable one are not
        // different messages, so degrading would only move the failure to the peer.
        guard let named = SwiftType(type) else {
            throw DistributedActorCodingError(message: """
                Failed to record return type \(type): it has no mangled name, so no peer \
                could resolve it.
                """)
        }
        returnType = named
    }

    public mutating func doneRecording() throws {}

    /// Assemble the invocation. Separate from recording because the actor key comes
    /// from the session, which only exists at send time.
    public func makeInvocationBody() -> InvocationBody {
        InvocationBody(
            protocolStub: protocolStub,
            genericSubsitutions: genericSubsitutions,
            arguments: arguments,
            errorType: errorType,
            returnType: returnType)
    }

    /// Apple's initializer is
    /// `init(id:targetedSharedActor:remoteCallTarget:invocation:)` -- `invocation` is the
    /// encoder itself, and there is **no `basePriority` parameter**. `basePriority` has a
    /// getter and no setter, so the request derives it, from `Task.basePriority`: the
    /// name and the `TaskPriority?` type match Swift's own exactly, and it is what the
    /// `invocationEscalated` / `responseEscalated` notifications exist to raise
    /// afterwards. That the initializer reads it is an inference, marked as one in the
    /// spec; the getter-only property and the name match are not.
    ///
    /// Off a task there is no base priority, `Task.basePriority` is nil, and the key is
    /// simply not written.
    public func makeRequest(
        id: ID64, targetedSharedActor: SharedActorKey, remoteCallTarget: RemoteCallTarget
    ) -> RemoteInvocationRequest {
        RemoteInvocationRequest(
            id: id,
            basePriority: Task.basePriority,
            targetedSharedActor: targetedSharedActor,
            remoteCallIdentifier: remoteCallTarget.identifier,
            contents: makeInvocationBody())
    }
}
