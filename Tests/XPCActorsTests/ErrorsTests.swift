import XCTest
@testable import XPCActors

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class ErrorsTests: XCTestCase {

    func testRawTransportErrorCarriesMessage() {
        let error = RawTransportError.rawTransportCancelled(message: "peer went away")
        XCTAssertEqual(error, .rawTransportCancelled(message: "peer went away"))
        XCTAssertNotEqual(error, .rawTransportCancelled(message: "something else"))
    }

    func testTransportErrorDistinguishesCancellationSources() {
        // These are different failures and must never compare equal: one means the
        // pipe died, the other means our own caller walked away.
        XCTAssertNotEqual(
            TransportError.transportCancelled(message: "closed"),
            TransportError.taskCancelled
        )
    }

    func testSetupErrorDescriptionIncludesMessage() {
        let error = SetupError("version 9 unsupported")
        XCTAssertTrue(error.description.contains("version 9 unsupported"))
    }
}
