import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class SmokeTests: XCTestCase {
    func testTypesConform() {
        // Compile-time: the conformances exist with Bytes == [UInt8].
        func requireClient<T: ClientTransport>(_ t: T.Type) where T.Bytes == [UInt8] {}
        func requireServer<T: ServerTransport>(_ t: T.Type) where T.Bytes == [UInt8] {}
        requireClient(XPCClientTransport.self)
        requireServer(XPCServerTransport.self)
    }
}
