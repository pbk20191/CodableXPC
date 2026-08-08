import Foundation
import Distributed

/// Accumulates one outbound invocation.
///
/// The Swift runtime drives this: it records the generic substitutions, then each
/// argument in declaration order, then the error and return types, then calls
/// `doneRecording`. Nothing is encoded here -- the values are held until
/// `makeInvocationBody` / `makeRequest` assemble them, because the actor key is not
/// known until the session shares it.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct InvocationEncoder: DistributedTargetInvocationEncoder {

    public typealias SerializationRequirement = any Codable

    public private(set) var generics: [String] = []
    public private(set) var arguments: [any Codable] = []
    public private(set) var errorType: String?
    public private(set) var returnType: String?

    public init() {}

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        guard let mangled = TypeName.mangled(for: type) else {
            throw SetupError("no mangled name for generic substitution \(type)")
        }
        generics.append(mangled)
    }

    public mutating func recordArgument<Value: Codable>(
        _ argument: RemoteCallArgument<Value>
    ) throws {
        // The label and the parameter name are dropped on purpose: the receiver knows
        // both statically from the callee signature.
        arguments.append(argument.value)
    }

    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {
        // Not fatal if unnameable. `errorType` being present is what tells the receiver
        // the target can throw, so a name we cannot mangle degrades to tier 3 rather
        // than failing the call -- but the field must still be set.
        errorType = TypeName.mangled(for: type) ?? "\(type)"
    }

    public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {
        returnType = TypeName.mangled(for: type)
    }

    public mutating func doneRecording() throws {}

    /// Assemble the invocation. Separate from recording because the actor key comes
    /// from the session, which only exists at send time.
    ///
    /// **Adapted for R2, not rewritten.** R3 rewrites this type to store `SwiftType`s
    /// directly, to record a `protocolStub`, and to stop degrading an unmangleable
    /// error type into a display string. Until then the stored `String`s are wrapped
    /// here, and `protocolStub` is always nil -- so the *shape* below is the shipping
    /// wire format, while what fills it is still R3's problem.
    public func makeInvocationBody() -> InvocationBody {
        InvocationBody(
            protocolStub: nil,
            genericSubsitutions: generics.map(SwiftType.init(mangledTypeName:)),
            arguments: arguments,
            errorType: errorType.map(SwiftType.init(mangledTypeName:)),
            returnType: returnType.map(SwiftType.init(mangledTypeName:)))
    }

    public func makeRequest(
        id: ID64, actor: SharedActorKey, target: String, basePriority: TaskPriority?
    ) -> RemoteInvocationRequest {
        RemoteInvocationRequest(
            id: id, basePriority: basePriority, targetedSharedActor: actor,
            remoteCallIdentifier: target, contents: makeInvocationBody())
    }
}
