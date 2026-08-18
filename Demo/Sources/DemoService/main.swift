import Foundation
import Distributed
import XPCActors
import DemoProtocol

/// The service half. launchd starts this on demand when the host dials the bundle
/// identifier; nothing registers it and nothing has to clean it up.
///
/// **No `@main`, and no `async` main.** A bundled XPC service does not create its own listener
/// -- launchd hands it one through `xpc_main`, which takes over this thread and never returns.
/// `XPCActorSystem.listen(as:)` refuses a `.xpcService` for exactly that reason rather than
/// building a listener on a name nothing routes to.

@available(macOS 15, *)
distributed actor GreeterImpl: Greeter {

    typealias ActorSystem = XPCActorSystem

    distributed func greet(name: String) -> String {
        "hello \(name), from pid \(getpid())"
    }

    distributed func servingProcessID() -> Int32 { getpid() }

    distributed func refuse(_ why: String) throws -> String {
        throw Refused(why: why)
    }
}

guard #available(macOS 15, *) else {
    FileHandle.standardError.write(Data("GreeterService: needs macOS 15\n".utf8))
    exit(1)
}

let system = XPCActorSystem("GreeterService")

// Built once, before any peer can arrive. One of these handlers runs per connected peer, and
// the ordering inside it is the contract: export first, then activate. A request that arrives
// in between parks on the activation gate rather than resolving against an empty table.
let receiver = XPCActorSystem.TransportReceiver(actorSystem: system) { local in
    let greeter = GreeterImpl(actorSystem: system)
    local.export(greeter, asDefaultActorFor: $Greeter.self)
    // No `withExtendedLifetime` around the await: the system's `ActorRegistry` holds actors
    // weakly, but `export` resolves through it and stores the strong reference in the session's
    // shared-actor table, which lives as long as the session. From here on the session owns it.
    return await local.activateThenWaitForCancellation()
}

// Never returns. Peers arrive on libxpc's own queue; `accept` starts each one's handler as a
// Task and resumes the suspended connection.
runXPCServiceMain { raw in
    receiver.accept(raw, debugName: "greeter")
}
