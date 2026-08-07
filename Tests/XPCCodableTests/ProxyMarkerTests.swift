#if canImport(Darwin)
import XCTest
import Foundation
import XPCCodableSharedInterfaceFixture
import XPCCodable

private final class LedgerImpl: AuditLedger, @unchecked Sendable {
    var notes: [String] = []
    func note(_ text: String) { notes.append(text) }
    func total() async throws -> Int { notes.count }
}

private final class AuditorImpl: Auditor, @unchecked Sendable {
    var attached: (any AuditLedger)?
    func attach(_ ledger: XPCProxyMarker<AuditLedger>) { attached = ledger.wrappedValue }
    func reconcile(_ ledger: XPCProxyMarker<AuditLedger>, label: String) async throws -> Int {
        ledger.wrappedValue.note(label)
        return try await ledger.wrappedValue.total()
    }
    func current() async throws -> XPCProxyMarker<AuditLedger> {
        XPCProxyMarker(wrappedValue: attached ?? LedgerImpl())
    }
}

/// `XPCProxyMarker` positions become `setInterface` registrations rather than
/// encoded arguments.
///
/// The interface is the thing worth asserting on: `setClasses` and `setInterface`
/// are what NSXPC consults before it will move an argument at all, and a missing
/// registration shows up at runtime as a rejected message rather than as anything
/// a compiler would catch.
final class ProxyMarkerTests: XCTestCase {

    private func selector(_ name: String) -> Selector { NSSelectorFromString(name) }

    func testAProxyParameterGetsAnInterfaceNotAClassList() {
        let interface = AuditorXPC.interface
        let nested = interface.forSelector(selector("attach:"), argumentIndex: 0, ofReply: false)

        XCTAssertNotNil(nested, "attach's argument 0 should carry AuditLedger's interface")
        XCTAssertEqual(nested.map { NSStringFromProtocol($0.protocol) },
                       "XPCCodableSharedInterfaceFixture.AuditLedgerXPCShim")
    }

    func testItIsRegisteredAlongsideOrdinaryArguments() {
        let interface = AuditorXPC.interface
        let nested = interface.forSelector(
            selector("reconcile:label:reply:"), argumentIndex: 0, ofReply: false)
        XCTAssertEqual(nested.map { NSStringFromProtocol($0.protocol) },
                       "XPCCodableSharedInterfaceFixture.AuditLedgerXPCShim")
        // The String beside it is an ordinary argument and gets no interface.
        XCTAssertNil(interface.forSelector(
            selector("reconcile:label:reply:"), argumentIndex: 1, ofReply: false))
    }

    func testAProxyReturnIsRegisteredOnTheReply() {
        let nested = AuditorXPC.interface.forSelector(
            selector("currentWithReply:"), argumentIndex: 0, ofReply: true)
        XCTAssertEqual(nested.map { NSStringFromProtocol($0.protocol) },
                       "XPCCodableSharedInterfaceFixture.AuditLedgerXPCShim")
    }

    func testTheShimTakesThePeersObjcFaceNotTheSwiftProtocol() {
        // What the adapter must satisfy is Auditor's shim; what it hands the
        // implementation is a AuditLedger rebuilt from the peer's shim.
        let exported: NSObject = AuditorXPC.exported(AuditorImpl())
        XCTAssertTrue(exported.conforms(to: AuditorXPC.interface.protocol))
        XCTAssertTrue(exported.responds(to: selector("attach:")))
    }

    /// Both halves in-process: the adapter wraps an incoming shim back into the
    /// Swift protocol, which is the step that lets an implementation stay unaware
    /// that its `AuditLedger` is someone else's object.
    func testAnImplementationCallsBackThroughTheWrappedProxy() async throws {
        let ledger = LedgerImpl()
        let auditor = AuditorImpl()

        // Stand in for what NSXPC delivers: the peer's @objc face.
        let asShim: any AuditLedgerXPCShim = AuditLedgerXPCAdapter(ledger)
        let rebuilt = AuditLedgerXPCClient(proxy: asShim)

        rebuilt.note("opening")
        auditor.attach(XPCProxyMarker(wrappedValue: rebuilt))
        XCTAssertNotNil(auditor.attached)

        let total = try await auditor.reconcile(
            XPCProxyMarker(wrappedValue: rebuilt), label: "audited")
        XCTAssertEqual(total, 2)
        XCTAssertEqual(ledger.notes, ["opening", "audited"])
    }

    /// The convenience overload takes the bare protocol, so a caller never spells
    /// the marker outside the interface declaration.
    func testTheBareOverloadTakesTheProtocolItself() async throws {
        let auditor = AuditorImpl()
        let ledger = LedgerImpl()
        auditor.attach(ledger)                       // no XPCProxyMarker at the call site
        let total = try await auditor.reconcile(ledger, label: "bare")
        XCTAssertEqual(total, 1)
    }
}
#endif
