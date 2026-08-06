import Foundation
import XPC

/// A stable, sorted rendering of an xpc object, for golden-fixture assertions.
///
/// `xpc_copy_description` is not usable for this: its output includes pointer
/// values and its dictionary ordering is unspecified.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
func normalizedDescription(_ object: xpc_object_t, topLevel: Bool = true) -> String {
    switch xpc_get_type(object) {
    case XPC_TYPE_DICTIONARY:
        var pairs: [String] = []
        xpc_dictionary_apply(object) { key, value in
            pairs.append("\(String(cString: key))=\(normalizedDescription(value, topLevel: false))")
            return true
        }
        // The outermost object is always the thing under test, so it needs no type
        // tag; nested values do, to keep a dictionary distinguishable from an array
        // at a glance. Do not invert this: the golden fixtures are written to it.
        let prefix = topLevel ? "" : "dict"
        return prefix + "{" + pairs.sorted().joined(separator: ",") + "}"
    case XPC_TYPE_ARRAY:
        var items: [String] = []
        xpc_array_apply(object) { _, value in
            items.append(normalizedDescription(value, topLevel: false))
            return true
        }
        return "[" + items.joined(separator: ",") + "]"
    case XPC_TYPE_UINT64:
        return "uint64(\(xpc_uint64_get_value(object)))"
    case XPC_TYPE_INT64:
        return "int64(\(xpc_int64_get_value(object)))"
    case XPC_TYPE_STRING:
        return "string(\(String(cString: xpc_string_get_string_ptr(object)!)))"
    case XPC_TYPE_BOOL:
        return "bool(\(xpc_bool_get_value(object)))"
    case XPC_TYPE_DOUBLE:
        return "double(\(xpc_double_get_value(object)))"
    case XPC_TYPE_NULL:
        return "null"
    default:
        return "other"
    }
}
