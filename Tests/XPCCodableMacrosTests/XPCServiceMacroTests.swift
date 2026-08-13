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

    /// A protocol that inherits requirements is refused, with a message about *inheritance*.
    ///
    /// Before this, the macro simply ignored the inheritance clause and generated a client that
    /// did not conform. The error that reached the author was "type 'DerivedXPCClient' does not
    /// conform to protocol 'Base'", reported *inside macro expansion* -- pointing at code they
    /// never wrote, and not mentioning the thing they actually did wrong.
    func testRejectsInheritedRequirements() {
        assertMacroExpansion(
            """
            @XPCService
            protocol Derived: Base {
                func f() async throws -> Int
            }
            """,
            expandedSource: """
            protocol Derived: Base {
                func f() async throws -> Int
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                        @XPCService cannot see requirements a protocol inherits. The macro is \
                        syntactic -- it is handed this protocol's own text and nothing else, so \
                        an inherited protocol's methods are invisible to it and would silently \
                        not be carried across the connection. Copy the requirements you need \
                        into this protocol. Only 'AnyObject' and 'Sendable' may be inherited, \
                        because neither adds a requirement to carry.
                        """,
                    line: 2, column: 17)
            ],
            macros: macros)
    }

    /// A `static func` is a `FunctionDeclSyntax`, so it sailed past the members guard; its
    /// modifier lives on the declaration, not in the signature the client copies, so the
    /// generated client declared an *instance* method and failed to conform -- an error inside
    /// the expansion. Now it is the same diagnostic every other non-method requirement gets.
    func testRejectsAStaticMethod() {
        assertMacroExpansion(
            """
            @XPCService
            protocol S {
                static func ping()
            }
            """,
            expandedSource: """
            protocol S {
                static func ping()
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

    /// The reply slot's own optionality is the failure channel, so `-> String?` became
    /// `String??` in the shim -- unrepresentable in Objective-C, reported from inside the
    /// expansion. Refused with a message that says what to do instead.
    func testRejectsAnOptionalReturn() {
        assertMacroExpansion(
            """
            @XPCService
            protocol S {
                func f() async throws -> String?
            }
            """,
            expandedSource: """
            protocol S {
                func f() async throws -> String?
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                        @XPCService cannot return an optional. The reply block's slot is already \
                        optional -- nil there means "the peer failed to reply", and it is how a \
                        thrown error crosses -- so an optional return would make a legitimate nil \
                        indistinguishable from a missing reply. Return a non-optional, or wrap the \
                        optional in a Codable type and mark it XPCCodableMarker.
                        """,
                    line: 3, column: 30)
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
