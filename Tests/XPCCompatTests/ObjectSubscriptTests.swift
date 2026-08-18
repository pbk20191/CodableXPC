import XCTest
import XPC
@testable import XPCCompat

final class ObjectSubscriptTests: XCTestCase {

    func testNestedDictionaryRoundTrip() {
        var outer = XPCCompat.Dictionary()
        var inner = XPCCompat.Dictionary()
        inner["n"] = Int(1)
        outer["child"] = inner
        XCTAssertEqual(outer["child", as: XPCCompat.Dictionary.self], inner)
    }

    // Nested containers alias rather than copy: mutating the child after
    // insertion is visible through the parent.
    func testNestedContainersAlias() {
        var outer = XPCCompat.Dictionary()
        var inner = XPCCompat.Dictionary()
        outer["child"] = inner
        inner["added"] = Int(1)
        XCTAssertEqual(outer["child", as: XPCCompat.Dictionary.self]?.count, 1)
    }

    func testNestedArrayRoundTrip() {
        var outer = XPCCompat.Dictionary()
        let inner = XPCCompat.Array()
        outer["list"] = inner
        XCTAssertEqual(outer["list", as: XPCCompat.Array.self], inner)
    }

    func testWrongContainerTypeIsNil() {
        var d = XPCCompat.Dictionary()
        d["list"] = XPCCompat.Array()
        XCTAssertNil(d["list", as: XPCCompat.Dictionary.self])
    }

    func testRawObjectRoundTrip() {
        var d = XPCCompat.Dictionary()
        d["raw"] = xpc_string_create("hi")
        let value = d["raw", as: xpc_object_t.self]
        XCTAssertNotNil(value)
        XCTAssertTrue(xpc_get_type(value!) == XPC_TYPE_STRING)
    }

    func testLookupByTypeReturnsValueWhenTypeMatches() {
        var d = XPCCompat.Dictionary()
        d["s"] = "hi"
        XCTAssertNotNil(d["s", as: XPC_TYPE_STRING])
        XCTAssertNil(d["s", as: XPC_TYPE_INT64])
    }

    func testEndpointRoundTrip() {
        let connection = xpc_connection_create(nil, nil)
        // DEVIATION (test-only, see task-9-report.md): the brief's version of this test
        // creates the connection and cancels it without ever activating it. On this SDK
        // (macOS 27 beta) libxpc traps with "API misuse" when an un-activated connection
        // is canceled or deallocated. Setting an event handler and activating before use
        // is the documented, correct XPC connection lifecycle and avoids the trap without
        // touching any XPCCompat production code.
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        let endpoint = XPCCompat.Endpoint(xpc_endpoint_create(connection))
        var d = XPCCompat.Dictionary()
        d["ep"] = endpoint
        XCTAssertEqual(d["ep", as: XPCCompat.Endpoint.self], endpoint)
        xpc_connection_cancel(connection)
    }



    func testAssigningNilRemovesNestedContainer() {
        var d = XPCCompat.Dictionary()
        d["child"] = XPCCompat.Dictionary()
        d["child"] = XPCCompat.Dictionary?.none
        XCTAssertEqual(d.count, 0)
    }



    // Finding 2: XPCCompat.Array needs the same typed read/write subscript surface
    // as XPCCompat.Dictionary for nested Dictionary, Array and Endpoint.

    func testArrayNestedDictionaryRoundTrip() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_bool_create(false))
        var a = XPCCompat.Array(raw)
        var inner = XPCCompat.Dictionary()
        inner["n"] = Int(1)
        a[0] = inner
        XCTAssertEqual(a[0, as: XPCCompat.Dictionary.self], inner)
    }

    func testArrayNestedArrayRoundTrip() {
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_bool_create(false))
        var a = XPCCompat.Array(raw)
        let inner = XPCCompat.Array()
        a[0] = inner
        XCTAssertEqual(a[0, as: XPCCompat.Array.self], inner)
    }

    func testArrayEndpointRoundTrip() {
        let connection = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        let endpoint = XPCCompat.Endpoint(xpc_endpoint_create(connection))
        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_bool_create(false))
        var a = XPCCompat.Array(raw)
        a[0] = endpoint
        XCTAssertEqual(a[0, as: XPCCompat.Endpoint.self], endpoint)
        xpc_connection_cancel(connection)
    }


}
