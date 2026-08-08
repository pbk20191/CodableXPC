import Foundation

/// Mangled type names, cached in both directions.
///
/// `_typeByName` performs a runtime lookup on every call, so the reverse direction
/// is cached; the forward direction is cached with it so the two stay one component.
/// Apple added the same cache to `XPCSystem` between the two builds we can observe.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum TypeName {

    private static let lock = NSLock()
    private static var byName: [String: Any.Type] = [:]
    private static var byType: [ObjectIdentifier: String] = [:]
    /// Names that did not resolve. Cached too: a peer sending an unknown type
    /// repeatedly must not cost a runtime lookup every time.
    private static var unresolvable: Set<String> = []

    public static func mangled(for type: Any.Type) -> String? {
        let key = ObjectIdentifier(type)
        if let hit = lock.withLock({ byType[key] }) { return hit }
        guard let name = _mangledTypeName(type) else { return nil }
        lock.withLock {
            byType[key] = name
            byName[name] = type
        }
        return name
    }

    public static func type(for name: String) -> Any.Type? {
        let cached: Any.Type?? = lock.withLock {
            if unresolvable.contains(name) { return .some(nil) }
            if let hit = byName[name] { return .some(hit) }
            return nil
        }
        if let cached { return cached }

        guard let resolved = _typeByName(name) else {
            lock.withLock { _ = unresolvable.insert(name) }
            return nil
        }
        lock.withLock {
            byName[name] = resolved
            byType[ObjectIdentifier(resolved)] = name
        }
        return resolved
    }
}
