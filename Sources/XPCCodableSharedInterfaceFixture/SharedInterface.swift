#if canImport(Darwin)
import XPCCodable

/// A `@XPCService` protocol in the arrangement it is meant for: declared once in
/// a module both sides depend on, rather than beside either of them.
///
/// This target exists so that arrangement is compiled. The macro mirrors the
/// protocol's visibility onto everything it generates, and an omission there is
/// invisible from inside the declaring module -- `internal` is reachable from the
/// same module and from `@testable`, so a same-module test passes either way. It
/// only fails where it matters, in the process on the other end of the
/// connection. So the consumer of this module is a different one.
public struct Invoice: Codable, Equatable, Sendable {
    public let id: String
    public let cents: Int
    public init(id: String, cents: Int) {
        self.id = id
        self.cents = cents
    }
}

@XPCService
public protocol Billing {
    func settle(_ invoice: XPCCodableMarker<Invoice>, memo: String)
        async throws -> XPCCodableMarker<Invoice>
    func acknowledge(_ invoice: XPCCodableMarker<Invoice>)
}
#endif

#if canImport(Darwin)
/// The escape hatch from the module-qualified default: two sides that cannot
/// share a module need a name they both spell the same way. Choosing it is the
/// author's job -- it is a process-wide Objective-C identifier.
@XPCService(objcName: "TeamFortyTwoCourier")
public protocol Courier {
    func dispatch(_ note: String)
}
#endif

#if canImport(Darwin)
/// A service that is handed *to* another service as a live object.
@XPCService
public protocol AuditLedger {
    func note(_ text: String)
    func total() async throws -> Int
}

/// Takes a `AuditLedger` by proxy and hands one back the same way. Neither crosses as
/// data: `XPCProxyMarker` makes the macro emit `NSXPCInterface.setInterface`, so
/// NSXPC vends the object and the far side calls back into it.
@XPCService
public protocol Auditor {
    func attach(_ ledger: XPCProxyMarker<AuditLedger>)
    func reconcile(_ ledger: XPCProxyMarker<AuditLedger>, label: String) async throws -> Int
    func current() async throws -> XPCProxyMarker<AuditLedger>
}
#endif
