/// The one string both processes have to agree on.
///
/// It is the `.xpc` bundle's `CFBundleIdentifier`, which is simultaneously the name
/// `XPCServerTransport.service(named:)` listens on and the name
/// `XPCClientTransport.connecting(toXPCService:)` dials. `run.sh` writes the same literal into the
/// service's `Info.plist`; if the three ever disagree, launchd simply does not find a service and
/// the dial fails.
///
/// It lives beside the generated stubs because the bundle identifier is part of this demo's
/// contract in exactly the way the service descriptor is -- and `.proto` has nowhere to put it.
public enum DemoService {
    public static let bundleIdentifier = "com.example.GRPCXPCDemo.CalculatorService"
}
