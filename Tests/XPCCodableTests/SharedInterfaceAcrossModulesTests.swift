#if canImport(Darwin)
import XCTest
import Foundation
// Deliberately NOT @testable, and deliberately a different module: an interface
// shared by a client and a service is declared once and consumed from elsewhere,
// so `public` on the generated surface is the thing under test.
import XPCCodableSharedInterfaceFixture
import XPCCodable

private final class BillingService: Billing, @unchecked Sendable {
    var acknowledged: [Invoice] = []
    func settle(_ invoice: XPCCodableMarker<Invoice>, memo: String)
        async throws -> XPCCodableMarker<Invoice> {
        XPCCodableMarker(wrappedValue: Invoice(id: invoice.wrappedValue.id + ":" + memo,
                                               cents: invoice.wrappedValue.cents))
    }
    func acknowledge(_ invoice: XPCCodableMarker<Invoice>) {
        acknowledged.append(invoice.wrappedValue)
    }
}

/// Every generated declaration, named from another module.
///
/// Most of this file asserts by compiling. `internal` is reachable from the
/// declaring module and from `@testable`, so a same-module test passes whether or
/// not the macro propagated `public` — it only fails in the process on the other
/// end of the connection, which no test would have caught.
final class SharedInterfaceAcrossModulesTests: XCTestCase {

    func testTheGeneratedFacadeIsReachable() {
        let interface: NSXPCInterface = BillingXPC.interface

        // The shim's Objective-C name carries the module it was declared in. That
        // is worth pinning, because it makes sharing the interface *module*
        // mandatory rather than merely tidy: two sides that each declare their own
        // copy of the protocol get two different runtime names, and NSXPC matches
        // on the name. The macro emits no explicit @objc(...) to override this --
        // an unqualified name would be a process-wide identifier handed out by a
        // library, which is a collision waiting to happen.
        XCTAssertEqual(NSStringFromProtocol(interface.protocol),
                       "XPCCodableSharedInterfaceFixture.BillingXPCShim")
    }

    func testTheGeneratedAdapterIsReachable() {
        let exported: NSObject = BillingXPC.exported(BillingService())
        XCTAssertTrue(exported is BillingXPCAdapter)
        // The adapter must satisfy the shim protocol, which is what NSXPCConnection
        // checks against the interface above.
        XCTAssertTrue(exported.conforms(to: BillingXPC.interface.protocol))
    }

    func testTheGeneratedClientIsConstructibleAndTyped() {
        let connection = NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)
        // Both the type and its initialiser have to be public to write this line.
        let client = BillingXPCClient(connection: connection)
        let asProtocol: any Billing = client
        XCTAssertNotNil(asProtocol)
        // …as does the facade's convenience form.
        let viaFacade: any Billing = BillingXPC.remote(connection)
        XCTAssertNotNil(viaFacade)
        connection.invalidate()
    }

    func testTheProtocolItselfIsImplementableFromAnotherModule() async throws {
        let service = BillingService()
        let settled = try await service.settle(
            XPCCodableMarker(wrappedValue: Invoice(id: "A-1", cents: 250)), memo: "paid")
        XCTAssertEqual(settled.wrappedValue, Invoice(id: "A-1:paid", cents: 250))

        // The bare-value overload the extension adds, used across the module line.
        let bare = try await service.settle(Invoice(id: "A-2", cents: 10), memo: "cash")
        XCTAssertEqual(bare, Invoice(id: "A-2:cash", cents: 10))

        service.acknowledge(Invoice(id: "A-3", cents: 0))
        XCTAssertEqual(service.acknowledged, [Invoice(id: "A-3", cents: 0)])
    }
}
#endif
