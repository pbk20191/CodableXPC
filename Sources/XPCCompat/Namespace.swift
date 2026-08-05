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
/// - Important: Declare only stored properties and initializers inside this enum's body.
///   Every other member belongs in a file-scope `extension XPCCompat.X`. Inside the enum
///   body, an unqualified `Array` resolves to `XPCCompat.Array` rather than `Swift.Array`,
///   and `Array()` compiles cleanly while producing the wrong type.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public enum XPCCompat {}
