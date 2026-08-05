import XPC

/// Namespace for backported equivalents of Apple's `XPC` Swift overlay types.
///
/// These types mirror `XPCDictionary`, `XPCArray`, `XPCSession` and friends but are
/// available from macOS 10.15. This module deliberately does not re-export `XPC`, so
/// `import XPC` and `import XPCCompat` can appear in the same file.
///
/// For drop-in source compatibility, declare your own aliases:
///
///     typealias XPCDictionary = XPCCompat.Dictionary
///
/// - Important: Never write an unqualified `Array` or `Dictionary` anywhere lexically
///   inside `enum XPCCompat` or any `extension XPCCompat`. In those scopes the bare name
///   resolves to `XPCCompat.Array` / `XPCCompat.Dictionary` rather than to `Swift.Array` /
///   `Swift.Dictionary`, and `Array()` *compiles cleanly while producing the wrong type* —
///   only `Array(repeating:count:)` errors out. Always spell them out: `Swift.Array` /
///   `Swift.Dictionary` for the standard library types, `XPCCompat.Array` /
///   `XPCCompat.Dictionary` for these. `Tests/XPCCompatTests/ShadowingLintTests.swift`
///   enforces this across the whole module.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public enum XPCCompat {}
