import Distributed
import XPCActors

/// The contract both processes share.
///
/// This module is the only thing the host and the service have in common: the service links
/// it to *implement* `Greeter`, the host links it to *name* one. Neither can see the other's
/// concrete types, which is the actual constraint a two-process demo has to respect and the
/// one an in-process test cannot impose on itself.
///
/// `@Resolvable` synthesises `$Greeter`, a `_DistributedActorStub`. That stub is what makes
/// the naming work across the boundary: `LocalInterface.export(_:asDefaultActorFor:)` and
/// `RemoteInterface.import(defaultActorFor:)` both key on its mangled type name, so the
/// service and the host mint the same `SharedActorKey` without ever agreeing on a string.
@Resolvable
@available(macOS 15, *)
public protocol Greeter: DistributedActor where ActorSystem == XPCActorSystem {

    distributed func greet(name: String) -> String

    /// Returns the pid that actually ran the call. The point of the whole exercise: the host
    /// prints this next to its own and they differ.
    distributed func servingProcessID() -> Int32

    /// A throwing target, so the failure arm crosses a process boundary too.
    distributed func refuse(_ why: String) throws -> String
}

public struct Refused: Error, Codable, Sendable, CustomStringConvertible {
    public let why: String
    public init(why: String) { self.why = why }
    public var description: String { "refused: \(why)" }
}

/// Named once, used by both sides.
public enum DemoService {
    /// Must match the `CFBundleIdentifier` of the `.xpc` bundle the build script assembles.
    public static let bundleIdentifier = "com.example.XPCActorsDemo.GreeterService"
}
