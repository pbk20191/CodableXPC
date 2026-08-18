import XCTest
import XPC
@testable import XPCCompat

final class NamespaceTests: XCTestCase {

    // Importing both XPC and XPCCompat in one file must not be ambiguous.
    // If XPCCompat ever re-exports XPC, this file stops compiling.
    func testBothModulesImportableTogether() {
        let appleType: xpc_type_t = XPC_TYPE_DICTIONARY
        XCTAssertTrue(appleType == XPC_TYPE_DICTIONARY)
    }

    func testNamespaceExists() {
        // A caseless enum has no values; proving the metatype exists is enough.
        XCTAssertNotNil(XPCCompat.self)
    }
}
