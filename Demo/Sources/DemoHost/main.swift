import Foundation
import Distributed
import XPCActors
import DemoProtocol

/// The host half: dial the service, call it, print what came back.

@available(macOS 15, *)
@main
enum Main {
    static func main() async {
        let system = XPCActorSystem("DemoHost")
        print("host      pid \(getpid())")

        do {
            let remote = try system.makeRemoteInterface(
                to: .xpcService(DemoService.bundleIdentifier))

            // No message has been sent yet -- this mints a key and resolves it. A name the
            // service never exported would produce a perfectly good proxy whose first call
            // fails, which is the protocol's own shape: there is no "does this key exist"
            // request on the wire.
            let greeter: any Greeter = remote.import(defaultActorFor: $Greeter.self)

            let servicePID = try await greeter.servingProcessID()
            print("service   pid \(servicePID)")
            guard servicePID != getpid() else {
                print("FAIL: the call was answered in this process; nothing crossed.")
                exit(1)
            }

            print(try await greeter.greet(name: "world"))

            do {
                _ = try await greeter.refuse("by design")
                print("FAIL: a throwing target returned normally.")
                exit(1)
            } catch {
                print("throw crossed back: \(error)")
            }

            print("OK -- \(2) calls and one throw crossed a real process boundary.")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
