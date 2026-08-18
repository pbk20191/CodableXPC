import Foundation
import Synchronization

/// Mangled type names, cached in both directions.
///
/// `_typeByName` performs a runtime lookup on every call, so the reverse direction
/// is cached; the forward direction is cached with it so the two stay one component.
/// Apple added the same cache to `XPCSystem` between the two builds we can observe.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public enum TypeName {

    /// Both directions under one `Synchronization.Mutex`. The values are metatypes
    /// (`Any.Type`), which are not `Sendable`; the `Mutex` is the contract that makes
    /// concurrent access safe without a `nonisolated(unsafe)` hand-wave, now that the floor
    /// is macOS 26. `type(for:)` writes both maps at once, which is why they share one lock.
    private struct Caches {
        var byName: [String: Any.Type] = [:]
        var byType: [ObjectIdentifier: String] = [:]
    }
    private static let caches = Mutex<Caches>(Caches())
    /// **There is no negative cache, deliberately.**
    ///
    /// There used to be: a `Set<String>` of names that failed, so a repeated unknown
    /// name would not cost a runtime lookup each time. Under this protocol's actual
    /// threat model that reasoning is inverted, because **the peer chooses the names**.
    /// `SwiftType.type` reads `type(for:)` with a string that arrived on the wire — an
    /// invocation's `errorType`, `returnType`, `protocolStub`, and every generic
    /// substitution — so distinct garbage grew the set without bound, forever, while
    /// the cache only ever helped a peer that repeated *one* name.
    ///
    /// It was also wrong independently of any peer: a name that failed before its
    /// framework was `dlopen`ed stayed nil for the life of the process, so a lazily
    /// loaded type could never become resolvable.
    ///
    /// The cost of removing it is a failed `_typeByName` per unresolvable lookup, which
    /// is a failed lookup — cheaper than the unbounded growth it was buying, and paid
    /// only by traffic that was already malformed.
    ///
    /// The **positive** cache stays: it is bounded by the number of types actually in
    /// the process, which no peer controls.
    ///
    /// Test-only, so a test can assert the absence rather than trust this comment.
    static var unresolvableCacheCount: Int { 0 }

    public static func mangled(for type: Any.Type) -> String? {
        let key = ObjectIdentifier(type)
        if let hit = caches.withLock({ $0.byType[key] }) { return hit }
        guard let name = _mangledTypeName(type) else { return nil }
        // Only the forward direction is learned here. Writing `byName[name] = type`
        // would assert an inverse that was never checked, and the assertion is not
        // always true: a function-local type mangles to a name embedding a process
        // address that `_typeByName` cannot resolve, and an ObjC class built at runtime
        // over a Swift superclass mangles to the *superclass's* name. Caching either
        // would make `type(for:)` answer from our own guess -- reporting success for a
        // name no peer can resolve, or worse, returning the wrong type for a name that
        // legitimately belongs to the superclass. `type(for:)` populates `byName` from
        // a real `_typeByName`, which is the only source entitled to.
        caches.withLock { $0.byType[key] = name }
        return name
    }

    public static func type(for name: String) -> Any.Type? {
        if let hit = caches.withLock({ $0.byName[name] }) { return hit }

        // No negative memo -- see `unresolvableCacheCount`. A name that fails here is
        // asked again next time, which is what lets a type become resolvable after its
        // framework loads, and what stops a peer from growing this type without bound.
        guard let resolved = _typeByName(name) else { return nil }
        caches.withLock {
            $0.byName[name] = resolved
            $0.byType[ObjectIdentifier(resolved)] = name
        }
        return resolved
    }
}
