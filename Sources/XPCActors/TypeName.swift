import Foundation

/// Mangled type names, cached in both directions.
///
/// `_typeByName` performs a runtime lookup on every call, so the reverse direction
/// is cached; the forward direction is cached with it so the two stay one component.
/// Apple added the same cache to `XPCSystem` between the two builds we can observe.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public enum TypeName {

    private static let lock = NSLock()
    // `nonisolated(unsafe)` is the honest annotation, not a silencer: every access below is
    // inside `lock.withLock`, so the synchronization the compiler cannot see is real. The
    // values are metatypes (`Any.Type`), which are not `Sendable`, so strict concurrency flags
    // the bare `static var` -- and it is right to, for anyone who reaches them *without* the
    // lock. The lock is the contract; this marks that the contract is kept by hand.
    nonisolated(unsafe) private static var byName: [String: Any.Type] = [:]
    nonisolated(unsafe) private static var byType: [ObjectIdentifier: String] = [:]
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
        if let hit = lock.withLock({ byType[key] }) { return hit }
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
        lock.withLock { byType[key] = name }
        return name
    }

    public static func type(for name: String) -> Any.Type? {
        if let hit = lock.withLock({ byName[name] }) { return hit }

        // No negative memo -- see `unresolvableCacheCount`. A name that fails here is
        // asked again next time, which is what lets a type become resolvable after its
        // framework loads, and what stops a peer from growing this type without bound.
        guard let resolved = _typeByName(name) else { return nil }
        lock.withLock {
            byName[name] = resolved
            byType[ObjectIdentifier(resolved)] = name
        }
        return resolved
    }
}
