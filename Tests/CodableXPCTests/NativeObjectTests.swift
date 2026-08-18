#if canImport(Darwin)
import XCTest
import XPC
@testable import CodableXPC

private struct Handoff: Codable, Equatable {
    let label: String
    let object: XPCNativeObject
    let extras: [XPCNativeObject]
}

/// Any `xpc_object_t` can travel in a `Codable` graph, because this coder builds
/// a native object tree and an xpc object is already in its final form. Nothing
/// is serialised and nothing is indexed into a side table.
final class NativeObjectTests: XCTestCase {

    /// The connection is a listener; libxpc traps on release unless it was
    /// cancelled first, which is its contract rather than anything to do here.
    private func makeConnection() -> xpc_connection_t {
        let connection = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        addTeardownBlock { xpc_connection_cancel(connection) }
        return connection
    }

    /// `xpc_shmem_create` needs page-aligned memory. `malloc` does not give it,
    /// and passing it traps in `_xpc_api_misuse` rather than returning nil.
    private func makeShmem() throws -> xpc_object_t {
        let page = mmap(nil, 4096, PROT_READ | PROT_WRITE, MAP_ANON | MAP_SHARED, -1, 0)
        let region = try XCTUnwrap(page == MAP_FAILED ? nil : page)
        addTeardownBlock { munmap(region, 4096) }
        return try XCTUnwrap(xpc_shmem_create(region, 4096))
    }

    func testEveryNativeKindSurvivesUnchanged() throws {
        let connection = makeConnection()
        let nested = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(nested, "n", 42)

        let kinds: [(String, xpc_object_t)] = [
            ("connection", connection),
            ("endpoint", xpc_endpoint_create(connection)),
            ("fd", try XCTUnwrap(xpc_fd_create(STDIN_FILENO))),
            ("shmem", try makeShmem()),
            ("dictionary", nested),
        ]

        for (name, object) in kinds {
            let value = Handoff(label: name, object: XPCNativeObject(object),
                                extras: [XPCNativeObject(nested)])
            let graph = try XPCEncoder().encode(value)

            // It sits in the tree as itself, not as some encoded stand-in.
            let slot = try XCTUnwrap(xpc_dictionary_get_value(graph, "object"), name)
            XCTAssertEqual(xpc_get_type(slot), xpc_get_type(object), name)

            let back = try XPCDecoder().decode(Handoff.self, from: graph)
            XCTAssertTrue(xpc_equal(back.object.object, object), "\(name) did not survive")
            XCTAssertEqual(back.label, name)
            XCTAssertEqual(back.extras.count, 1)
        }
    }

    func testItWorksInEveryContainerKind() throws {
        let object = xpc_string_create("payload")

        // single value
        let single = try XPCEncoder().encode(XPCNativeObject(object))
        XCTAssertEqual(xpc_get_type(single), XPC_TYPE_STRING)
        XCTAssertEqual(try XPCDecoder().decode(XPCNativeObject.self, from: single),
                       XPCNativeObject(object))

        // unkeyed
        let array = try XPCEncoder().encode([XPCNativeObject(object), XPCNativeObject(object)])
        XCTAssertEqual(xpc_get_type(array), XPC_TYPE_ARRAY)
        XCTAssertEqual(try XPCDecoder().decode([XPCNativeObject].self, from: array).count, 2)

        // keyed
        let keyed = try XPCEncoder().encode(["k": XPCNativeObject(object)])
        XCTAssertEqual(xpc_get_type(try XCTUnwrap(xpc_dictionary_get_value(keyed, "k"))),
                       XPC_TYPE_STRING)
        XCTAssertEqual(try XPCDecoder().decode([String: XPCNativeObject].self, from: keyed)["k"],
                       XPCNativeObject(object))
    }

    /// The wrapper is the author's declaration that a live resource is crossing.
    /// Any coder that cannot honour that has to say so, not improvise: a JSON
    /// document with an endpoint quietly reduced to `{}` is worse than an error.
    func testAnyOtherCoderRefusesIt() {
        let value = XPCNativeObject(xpc_string_create("x"))
        XCTAssertThrowsError(try JSONEncoder().encode(value)) { error in
            guard case EncodingError.invalidValue = error else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
        XCTAssertThrowsError(try JSONDecoder().decode(XPCNativeObject.self, from: Data("{}".utf8)))
    }

    func testEqualityIsXPCEquality() {
        let a = xpc_dictionary_create(nil, nil, 0); xpc_dictionary_set_int64(a, "n", 1)
        let b = xpc_dictionary_create(nil, nil, 0); xpc_dictionary_set_int64(b, "n", 1)
        // Structural for containers…
        XCTAssertEqual(XPCNativeObject(a), XPCNativeObject(b))
        xpc_dictionary_set_int64(b, "n", 2)
        XCTAssertNotEqual(XPCNativeObject(a), XPCNativeObject(b))
        // …and identity for the live ones.
        let connection = makeConnection()
        XCTAssertEqual(XPCNativeObject(connection), XPCNativeObject(connection))
    }
}
#endif
