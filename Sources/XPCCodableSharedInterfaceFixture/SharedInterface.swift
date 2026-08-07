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
