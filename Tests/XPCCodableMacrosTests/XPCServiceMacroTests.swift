import XCTest
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XPCCodableMacrosCore

private let macros: [String: any Macro.Type] = ["XPCService": XPCServiceMacro.self]

/// These cover what the macro *refuses*. The generated code itself is checked
/// behaviourally in `XPCCodableTests`, over a real `NSXPCConnection` — an
/// exact-text expansion test would break on every whitespace change while proving
/// less.
final class XPCServiceMacroDiagnosticTests: XCTestCase {

    func testRejectsNonProtocol() {
        assertMacroExpansion(
            """
            @XPCService
            struct NotAProtocol {}
            """,
            expandedSource: """
            struct NotAProtocol {}
            """,
            diagnostics: [
                DiagnosticSpec(message: "@XPCService can only be applied to a protocol", line: 1, column: 1)
            ],
            macros: macros)
    }

    func testRejectsAValueReturnWithoutThrows() {
        // The important one. Such a method cannot report a dropped connection, so
        // allowing it would mean either trapping or lying.
        assertMacroExpansion(
            """
            @XPCService
            protocol S {
                func f() async -> Int
            }
            """,
            expandedSource: """
            protocol S {
                func f() async -> Int
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                        @XPCService cannot express this method. A method that returns a value \
                        has to be able to throw: a dropped connection is not something it could \
                        otherwise report, and inventing a return value for it would be worse. \
                        Add 'throws' -- with 'async' the caller suspends, without it the caller \
                        blocks. A method that returns nothing may also be 'async throws', \
                        'throws', or have no effects at all and be one-way.
                        """,
                    line: 3, column: 5)
            ],
            macros: macros)
    }

    func testRejectsASynchronousValueReturnWithoutThrows() {
        // The sibling of the case above, and the reason the rule is about the
        // failure channel rather than about `async`: `throws -> Int` is supported
        // (see SynchronousShapeTests), this is not.
        assertMacroExpansion(
            """
            @XPCService
            protocol S {
                func f() -> Int
            }
            """,
            expandedSource: """
            protocol S {
                func f() -> Int
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                        @XPCService cannot express this method. A method that returns a value \
                        has to be able to throw: a dropped connection is not something it could \
                        otherwise report, and inventing a return value for it would be worse. \
                        Add 'throws' -- with 'async' the caller suspends, without it the caller \
                        blocks. A method that returns nothing may also be 'async throws', \
                        'throws', or have no effects at all and be one-way.
                        """,
                    line: 3, column: 5)
            ],
            macros: macros)
    }

    func testRejectsAssociatedTypes() {
        assertMacroExpansion(
            """
            @XPCService
            protocol S {
                associatedtype T
            }
            """,
            expandedSource: """
            protocol S {
                associatedtype T
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@XPCService does not support protocols with associated types",
                               line: 1, column: 1)
            ],
            macros: macros)
    }

    func testRejectsAPropertyRequirement() {
        // NSXPC cannot carry a property. Before this diagnostic the macro generated
        // nothing at all, and the caller got "cannot find SXPC in scope" pointing
        // nowhere near the cause.
        assertMacroExpansion(
            """
            @XPCService
            protocol S {
                var name: String { get }
            }
            """,
            expandedSource: """
            protocol S {
                var name: String { get }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                        @XPCService supports method requirements only. NSXPC has no way to express \
                        a property, initializer, subscript, or static member across a connection.
                        """,
                    line: 3, column: 5)
            ],
            macros: macros)
    }

    func testRejectsSelectorCollision() {
        // Two Swift overloads, one Objective-C selector `f:`.
        assertMacroExpansion(
            """
            @XPCService
            protocol S {
                func f(_ a: Int)
                func f(_ b: String)
            }
            """,
            expandedSource: """
            protocol S {
                func f(_ a: Int)
                func f(_ b: String)
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                        @XPCService cannot overload on parameter type: two methods here produce the \
                        same Objective-C selector. Rename one of them.
                        """,
                    line: 4, column: 5)
            ],
            macros: macros)
    }
}
