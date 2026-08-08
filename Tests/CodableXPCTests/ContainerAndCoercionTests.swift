#if canImport(Darwin)
import XCTest
import XPC
@testable import CodableXPC

/// Hand-written containers, and what the decoder will and will not coerce.
final class ContainerAndCoercionTests: XCTestCase {

    // MARK: nested containers

    private struct Manual: Codable, Equatable {
        var inner: [String: Int]
        var list: [Int]
        enum K: String, CodingKey { case inner, list }
        enum Inner: String, CodingKey { case a, b }

        init(inner: [String: Int], list: [Int]) { self.inner = inner; self.list = list }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            var n = c.nestedContainer(keyedBy: Inner.self, forKey: .inner)
            try n.encode(inner["a"] ?? 0, forKey: .a)
            try n.encode(inner["b"] ?? 0, forKey: .b)
            var u = c.nestedUnkeyedContainer(forKey: .list)
            for v in list { try u.encode(v) }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            let n = try c.nestedContainer(keyedBy: Inner.self, forKey: .inner)
            inner = ["a": try n.decode(Int.self, forKey: .a),
                     "b": try n.decode(Int.self, forKey: .b)]
            var u = try c.nestedUnkeyedContainer(forKey: .list)
            var out: [Int] = []
            while !u.isAtEnd { out.append(try u.decode(Int.self)) }
            list = out
        }
    }

    /// Found two defects, from one copy-paste. Both nested factories on the
    /// *keyed* container passed the parent ref to the child instead of the child
    /// they had just created. The unkeyed one trapped on a precondition; the
    /// keyed one passed it — a dictionary is a dictionary — and wrote the nested
    /// values into the parent.
    func testNestedContainersWriteIntoTheirOwnNode() throws {
        let value = Manual(inner: ["a": 1, "b": 2], list: [3, 4, 5])
        let object = try XPCEncoder().encode(value)

        let inner = try XCTUnwrap(xpc_dictionary_get_value(object, "inner"))
        XCTAssertEqual(xpc_get_type(inner), XPC_TYPE_DICTIONARY)
        XCTAssertEqual(xpc_dictionary_get_int64(inner, "a"), 1)
        // The parent must not have grown the child's keys.
        XCTAssertNil(xpc_dictionary_get_value(object, "a"))

        let list = try XCTUnwrap(xpc_dictionary_get_value(object, "list"))
        XCTAssertEqual(xpc_get_type(list), XPC_TYPE_ARRAY)
        XCTAssertEqual(xpc_array_get_count(list), 3)

        XCTAssertEqual(try XPCDecoder().decode(Manual.self, from: object), value)
    }

    private class Base: Codable, Equatable {
        var id: Int
        init(id: Int) { self.id = id }
        static func == (l: Base, r: Base) -> Bool { l.id == r.id }
    }
    private final class Derived: Base {
        var name: String
        enum K: String, CodingKey { case name }
        init(id: Int, name: String) { self.name = name; super.init(id: id) }
        required init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            name = try c.decode(String.self, forKey: .name)
            try super.init(from: c.superDecoder())
        }
        override func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: K.self)
            try c.encode(name, forKey: .name)
            try super.encode(to: c.superEncoder())
        }
    }

    func testSuperEncoderRoundTrips() throws {
        let object = try XPCEncoder().encode(Derived(id: 7, name: "d"))
        let back = try XPCDecoder().decode(Derived.self, from: object)
        XCTAssertEqual(back.id, 7)
        XCTAssertEqual(back.name, "d")
    }

    // MARK: coercion

    /// The policy is strict, and worth stating because it is a choice: a value is
    /// read as the type it was written as, and narrowing is allowed only when it
    /// is exact.
    func testWhatIsAndIsNotCoerced() throws {
        XCTAssertEqual(try XPCDecoder().decode(Int32.self, from: xpc_int64_create(5)), 5)
        XCTAssertEqual(try XPCDecoder().decode(Double.self, from: xpc_int64_create(5)), 5.0)

        for (label, object, attempt) in [
            ("int that overflows the target", xpc_int64_create(70_000),
             { try XPCDecoder().decode(Int8.self, from: xpc_int64_create(70_000)) as Any }),
            ("negative into unsigned", xpc_int64_create(-1),
             { try XPCDecoder().decode(UInt.self, from: xpc_int64_create(-1)) as Any }),
            ("uint that overflows Int64", xpc_uint64_create(.max),
             { try XPCDecoder().decode(Int64.self, from: xpc_uint64_create(.max)) as Any }),
            ("fractional double as Int", xpc_double_create(1.5),
             { try XPCDecoder().decode(Int.self, from: xpc_double_create(1.5)) as Any }),
            ("bool as Int", xpc_bool_create(true),
             { try XPCDecoder().decode(Int.self, from: xpc_bool_create(true)) as Any }),
            ("string as Int", xpc_string_create("5"),
             { try XPCDecoder().decode(Int.self, from: xpc_string_create("5")) as Any }),
        ] as [(String, xpc_object_t, () throws -> Any)] {
            _ = object
            XCTAssertThrowsError(try attempt(), label)
        }
    }

    /// Found a defect. The double branch converted without checking, so a value
    /// too large for `Float` arrived as `infinity` — silently, in a decoder that
    /// refuses to turn 1.5 into an `Int`. Rounding is still fine; 0.1 is not
    /// representable as a `Float` either, and that is not what this catches.
    func testADoubleThatOverflowsFloatIsRefusedInEveryContainer() {
        XCTAssertThrowsError(try XPCDecoder().decode(Float.self, from: xpc_double_create(1e300)))

        let array = xpc_array_create(nil, 0)
        xpc_array_append_value(array, xpc_double_create(1e300))
        XCTAssertThrowsError(try XPCDecoder().decode([Float].self, from: array))

        struct Holder: Codable { let f: Float }
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(dictionary, "f", 1e300)
        XCTAssertThrowsError(try XPCDecoder().decode(Holder.self, from: dictionary))

        XCTAssertEqual(try XPCDecoder().decode(Float.self, from: xpc_double_create(0.1)), 0.1)
    }
}
#endif
