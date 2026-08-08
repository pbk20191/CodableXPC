import Foundation
import Distributed

/// Accumulates one outbound invocation.
///
/// The Swift runtime drives this: it records the generic substitutions, then each
/// argument in declaration order, then the error and return types, then calls
/// `doneRecording`. Nothing is encoded here -- the values are held until
/// `makeRequestBody` assembles them, because the actor key is not known until the
/// session shares it.
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

    /// Assemble the body. Separate from recording because the actor key comes from the
    /// session, which only exists at send time.
    public func makeRequestBody(
        actor: SharedActorKey, target: String, basePriority: UInt64?
    ) -> RequestBody {
        RequestBody(
            actor: actor, target: target, generics: generics, args: arguments,
            errorType: errorType, returnType: returnType, basePriority: basePriority)
    }
}
