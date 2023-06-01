import XCTest
import XPC
@testable import CodableXPC

final class CodableXPCTests: XCTestCase {
    
    
    
    func testDictionary() throws {
        let encoded = try XPCEncoder().encode(["":"A"])
        let rawDictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(rawDictionary, "", "A")
        if !xpc_equal(rawDictionary, encoded) {
            XCTFail("\(encoded) and \(rawDictionary) is not equal")
        }
        let decode = try XPCDecoder().decode([String:String].self, from: rawDictionary)
        XCTAssertEqual(decode, ["":"A"])
    }
    
    func testArray() throws {
        let encoded = try XPCEncoder().encode(["", "A", "B"])
        let rawArray = xpc_array_create(nil, 0)
        xpc_array_append_value(rawArray, xpc_string_create(""))
        xpc_array_append_value(rawArray, xpc_string_create("A"))
        xpc_array_append_value(rawArray, xpc_string_create("B"))
        if !xpc_equal(rawArray, encoded) {
            XCTFail("\(encoded) and \(rawArray) is not equal")
        }
        let array = try XPCDecoder().decode([String].self, from: rawArray)
        XCTAssertEqual(array, ["", "A", "B"])
    }
    
    
}
