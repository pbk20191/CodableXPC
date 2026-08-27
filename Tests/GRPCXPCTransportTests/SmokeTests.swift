import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class SmokeTests: XCTestCase {
    func testTypesConform() {
        // Compile-time: the conformances exist with Bytes == GRPCSwiftData.
        func requireClient<T: ClientTransport>(_ t: T.Type) where T.Bytes == GRPCSwiftData {}
        func requireServer<T: ServerTransport>(_ t: T.Type) where T.Bytes == GRPCSwiftData {}
        requireClient(XPCClientTransport.self)
        requireServer(XPCServerTransport.self)
    }
}
