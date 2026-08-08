#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCOverlayCoder

/// `XPCRichError` is not a wrapper around an `xpc_rich_error_t`, so one can be
/// made without libxpc — which has no creator for it under any name.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class XPCRichErrorConstructionTests: XCTestCase {

    func testTheLayoutStillHolds() {
        XCTAssertTrue(XPCRichError.isConstructible,
                      "XPCRichError's layout moved; make(_:canRetry:) now returns nil")
    }

    func testItCarriesWhatItWasGiven() throws {
        let error = try XCTUnwrap(XPCRichError.make("the drawer is open", canRetry: true))
        XCTAssertTrue(error.canRetry)
        XCTAssertEqual(String(describing: error), "the drawer is open")

        let final = try XCTUnwrap(XPCRichError.make("no route to peer"))
        XCTAssertFalse(final.canRetry)
    }

    func testItThrowsAndCatchesAsTheRealType() throws {
        func failing() throws { throw XPCRichError.make("peer went away", canRetry: false)! }

        do {
            try failing()
            XCTFail("expected a throw")
        } catch let caught as XPCRichError {
            XCTAssertEqual(String(describing: caught), "peer went away")
        }
    }

    /// The framework's own instances have the same shape, which is the whole
    /// basis for making one. Asserted against a real failure rather than assumed.
    func testAFrameworkErrorHasTheSameTwoFields() throws {
        do {
            let session = try XPCSession(xpcService: "com.example.absent.\(getpid())")
            try session.send(message: XPCDictionary(xpc_dictionary_create(nil, nil, 0)))
            throw XCTSkip("the bogus service unexpectedly connected")
        } catch let real as XPCRichError {
            let fields = Mirror(reflecting: real).children.compactMap(\.label)
            XCTAssertEqual(fields, ["_canRetry", "_description"])
            XCTAssertEqual(Mirror(reflecting: try XCTUnwrap(XPCRichError.make("x")))
                .children.compactMap(\.label), fields)
        }
    }
}
#endif
