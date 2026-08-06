import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros
import XPCCodableMacrosCore

/// The plugin host, and a type that exists only so the compiler can find the macro.
///
/// `#externalMacro(module:type:)` must name the *plugin* module, which SwiftPM fixes
/// to the `.macro` target's name, while the plugin resolves a macro by its fully
/// qualified type name. Those two only agree if the type is declared here. The
/// expansion itself lives in `XPCCodableMacrosCore`, a plain library, because
/// `@testable import` of a `.macro` executable does not link under the swiftbuild
/// build system — so the tests link the library and this file forwards to it.
public struct XPCServiceMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try XPCCodableMacrosCore.XPCServiceMacro.expansion(
            of: node, providingPeersOf: declaration, in: context)
    }
}

@main
struct XPCCodableMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        XPCServiceMacro.self,
    ]
}
