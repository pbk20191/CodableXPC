import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - Diagnostics

enum XPCServiceDiagnostic: String, DiagnosticMessage {
    case notAProtocol
    case unsupportedShape
    case duplicateSelector
    case associatedTypes
    case unsupportedRequirement

    var severity: DiagnosticSeverity { .error }
    var diagnosticID: MessageID { MessageID(domain: "XPCCodableMacros", id: rawValue) }

    var message: String {
        switch self {
        case .notAProtocol:
            return "@XPCService can only be applied to a protocol"
        case .unsupportedShape:
            return """
                @XPCService requires 'async throws' on any method that returns a value or \
                reports failure, and no effects at all on a one-way method. A method that \
                returns a value without throwing cannot report a dropped connection.
                """
        case .duplicateSelector:
            return """
                @XPCService cannot overload on parameter type: two methods here produce the \
                same Objective-C selector. Rename one of them.
                """
        case .associatedTypes:
            return "@XPCService does not support protocols with associated types"
        case .unsupportedRequirement:
            return """
                @XPCService supports method requirements only. NSXPC has no way to express \
                a property, initializer, subscript, or static member across a connection.
                """
        }
    }
}

// MARK: - Method model

/// How a protocol requirement maps onto an `@objc` shim method.
private enum Shape {
    /// `async throws -> R`: reply carries a boxed value or an error.
    case twoWayValue(returnType: TypeSyntax)
    /// `async throws`: reply carries an error or nothing.
    case twoWayVoid
    /// no effects, no return: fire and forget, no reply block.
    case oneWay
}

private struct Method {
    let decl: FunctionDeclSyntax
    let shape: Shape
    /// Argument labels as written, `nil` where the source used `_`.
    let labels: [String?]
    /// The name each parameter is known by inside a body.
    let internalNames: [String]
    let types: [TypeSyntax]

    var name: String { decl.name.text }

    /// Approximates the Objective-C selector, for collision detection.
    var selectorKey: String {
        let tail = labels.enumerated().map { index, label in
            index == 0 ? "" : (label ?? "_")
        }.joined(separator: ":")
        return "\(name):\(tail)"
    }

    /// `_ a0: CodableBox, to a1: CodableBox, …` preserving the original labels so
    /// the generated selector reads naturally.
    var boxedParameters: [String] {
        labels.enumerated().map { index, label in
            "\(label ?? "_") a\(index): CodableBox"
        }
    }

    /// `try a0.decode(Person.self)`, labelled for the call into the implementation.
    var decodedArguments: [String] {
        zip(labels, types).enumerated().map { index, pair in
            let (label, type) = pair
            let value = "try a\(index).decode(\(type.trimmedDescription).self)"
            return label.map { "\($0): \(value)" } ?? value
        }
    }

    /// `try CodableBox(person)`, positional, for the call into the shim.
    var boxedArguments: [String] {
        zip(labels, internalNames).map { label, name in
            let value = "try CodableBox(\(name))"
            return label.map { "\($0): \(value)" } ?? value
        }
    }
}

// MARK: - The macro

public struct XPCServiceMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let proto = declaration.as(ProtocolDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: node, message: XPCServiceDiagnostic.notAProtocol))
            return []
        }
        if proto.primaryAssociatedTypeClause != nil
            || proto.memberBlock.members.contains(where: { $0.decl.is(AssociatedTypeDeclSyntax.self) }) {
            context.diagnose(Diagnostic(node: node, message: XPCServiceDiagnostic.associatedTypes))
            return []
        }

        // nil means a requirement was rejected and a diagnostic already emitted;
        // an empty array means the protocol simply has no methods, which is legal
        // and yields an empty shim.
        guard let methods = parse(proto, in: context) else { return [] }

        var seen = Set<String>()
        for method in methods where !seen.insert(method.selectorKey).inserted {
            context.diagnose(Diagnostic(node: method.decl, message: XPCServiceDiagnostic.duplicateSelector))
            return []
        }

        let name = proto.name.text
        // Mirror the protocol's visibility so the generated surface is reachable
        // exactly where the protocol is.
        let access = proto.modifiers.first {
            ["public", "package", "internal", "fileprivate", "private"].contains($0.name.text)
        }.map { "\($0.name.text) " } ?? ""

        return [
            DeclSyntax(stringLiteral: shim(name: name, access: access, methods: methods)),
            DeclSyntax(stringLiteral: client(name: name, access: access, methods: methods)),
            DeclSyntax(stringLiteral: adapter(name: name, access: access, methods: methods)),
            DeclSyntax(stringLiteral: facade(name: name, access: access)),
        ]
    }

    // MARK: parsing

    private static func parse(
        _ proto: ProtocolDeclSyntax,
        in context: some MacroExpansionContext
    ) -> [Method]? {
        var methods: [Method] = []
        for member in proto.memberBlock.members {
            guard let fn = member.decl.as(FunctionDeclSyntax.self) else {
                // Anything that is not a method cannot cross an NSXPC connection.
                // Skipping it silently would leave the caller with a "cannot find
                // GreeterXPC in scope" error pointing nowhere near the cause.
                context.diagnose(Diagnostic(node: member.decl,
                                            message: XPCServiceDiagnostic.unsupportedRequirement))
                return nil
            }

            let effects = fn.signature.effectSpecifiers
            let isAsync = effects?.asyncSpecifier != nil
            let isThrowing = effects?.throwsClause != nil
            let returnType = fn.signature.returnClause?.type
            let returnsValue = returnType.map { !isVoid($0) } ?? false

            let shape: Shape
            switch (returnsValue, isAsync, isThrowing) {
            case (true, true, true):
                shape = .twoWayValue(returnType: returnType!)
            case (false, true, true):
                shape = .twoWayVoid
            case (false, false, false):
                shape = .oneWay
            default:
                context.diagnose(Diagnostic(node: fn, message: XPCServiceDiagnostic.unsupportedShape))
                return nil
            }

            let params = fn.signature.parameterClause.parameters
            methods.append(Method(
                decl: fn,
                shape: shape,
                labels: params.map { $0.firstName.text == "_" ? nil : $0.firstName.text },
                internalNames: params.map { ($0.secondName ?? $0.firstName).text },
                types: params.map { $0.type }
            ))
        }
        return methods
    }

    private static func isVoid(_ type: TypeSyntax) -> Bool {
        let text = type.trimmedDescription
        return text == "Void" || text == "()"
    }

    // MARK: generation

    private static func shim(name: String, access: String, methods: [Method]) -> String {
        let requirements = methods.map { method -> String in
            let boxed = method.boxedParameters
            switch method.shape {
            case .twoWayValue:
                return "    func \(method.name)(\((boxed + ["reply: @escaping (CodableBox?, (any Error)?) -> Void"]).joined(separator: ", ")))"
            case .twoWayVoid:
                return "    func \(method.name)(\((boxed + ["reply: @escaping ((any Error)?) -> Void"]).joined(separator: ", ")))"
            case .oneWay:
                return "    func \(method.name)(\(boxed.joined(separator: ", ")))"
            }
        }.joined(separator: "\n")

        return """
        /// The Objective-C face of `\(name)`, which is all NSXPC can see. Generated by
        /// `@XPCService`; you name it when configuring a connection, never implement it.
        @objc \(access)protocol \(name)XPCShim {
        \(requirements)
        }
        """
    }

    private static func client(name: String, access: String, methods: [Method]) -> String {
        let implementations = methods.map { method -> String in
            let signature = method.decl.signature.trimmedDescription
            let boxed = method.boxedArguments

            switch method.shape {
            case .twoWayValue(let returnType):
                // `boxed` is empty for a no-argument method, so the reply closure has to
                // be joined as a list element rather than appended after a comma.
                let call = method.name + "(" + (boxed + ["reply: { box, error in"]).joined(separator: ", ")
                return """
                    \(access)func \(method.name)\(signature) {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<\(returnType.trimmedDescription), any Error>) in
                            let once = XPCOneShot()
                            guard let proxy = proxy(resumingOnFailure: { error in
                                if once.claim() { continuation.resume(throwing: error) }
                            }) else {
                                if once.claim() { continuation.resume(throwing: XPCServiceError.proxyUnavailable) }
                                return
                            }
                            do {
                                try proxy.\(call)
                                    guard once.claim() else { return }
                                    if let error { continuation.resume(throwing: error); return }
                                    guard let box else {
                                        continuation.resume(throwing: XPCServiceError.missingReply)
                                        return
                                    }
                                    do { continuation.resume(returning: try box.decode(\(returnType.trimmedDescription).self)) }
                                    catch { continuation.resume(throwing: error) }
                                })
                            } catch {
                                if once.claim() { continuation.resume(throwing: error) }
                            }
                        }
                    }
                """
            case .twoWayVoid:
                let call = method.name + "(" + (boxed + ["reply: { error in"]).joined(separator: ", ")
                return """
                    \(access)func \(method.name)\(signature) {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                            let once = XPCOneShot()
                            guard let proxy = proxy(resumingOnFailure: { error in
                                if once.claim() { continuation.resume(throwing: error) }
                            }) else {
                                if once.claim() { continuation.resume(throwing: XPCServiceError.proxyUnavailable) }
                                return
                            }
                            do {
                                try proxy.\(call)
                                    guard once.claim() else { return }
                                    if let error { continuation.resume(throwing: error) }
                                    else { continuation.resume() }
                                })
                            } catch {
                                if once.claim() { continuation.resume(throwing: error) }
                            }
                        }
                    }
                """
            case .oneWay:
                // No reply block, so nothing can report a failure. Encoding errors and
                // a missing proxy are dropped, matching how NSXPC treats a one-way call.
                return """
                    \(access)func \(method.name)\(signature) {
                        guard let proxy = proxy(resumingOnFailure: { _ in }) else { return }
                        try? proxy.\(method.name)(\(boxed.joined(separator: ", ")))
                    }
                """
            }
        }.joined(separator: "\n\n")

        return """
        /// Client half generated by `@XPCService`. Obtain one from `\(name)XPC.remote(_:)`.
        \(access)struct \(name)XPCClient: \(name) {
            private let connection: NSXPCConnection

            \(access)init(connection: NSXPCConnection) {
                self.connection = connection
            }

            private func proxy(
                resumingOnFailure onFailure: @escaping @Sendable (any Error) -> Void
            ) -> (any \(name)XPCShim)? {
                connection.remoteObjectProxyWithErrorHandler(onFailure) as? any \(name)XPCShim
            }

        \(implementations)
        }
        """
    }

    private static func adapter(name: String, access: String, methods: [Method]) -> String {
        let implementations = methods.map { method -> String in
            let boxed = method.boxedParameters
            let decoded = method.decodedArguments.joined(separator: ", ")

            switch method.shape {
            case .twoWayValue:
                return """
                    \(access)func \(method.name)(\((boxed + ["reply: @escaping (CodableBox?, (any Error)?) -> Void"]).joined(separator: ", "))) {
                        let implementation = self.implementation
                        Task {
                            do { reply(try CodableBox(try await implementation.\(method.name)(\(decoded))), nil) }
                            catch { reply(nil, error) }
                        }
                    }
                """
            case .twoWayVoid:
                return """
                    \(access)func \(method.name)(\((boxed + ["reply: @escaping ((any Error)?) -> Void"]).joined(separator: ", "))) {
                        let implementation = self.implementation
                        Task {
                            do { try await implementation.\(method.name)(\(decoded)); reply(nil) }
                            catch { reply(error) }
                        }
                    }
                """
            case .oneWay:
                return """
                    \(access)func \(method.name)(\(boxed.joined(separator: ", "))) {
                        // One-way: there is no reply block, so a decode failure has nowhere
                        // to go. Dropping it matches NSXPC's own behaviour for such calls.
                        try? implementation.\(method.name)(\(decoded))
                    }
                """
            }
        }.joined(separator: "\n\n")

        return """
        /// Server half generated by `@XPCService`. Obtain one from `\(name)XPC.exported(_:)`.
        ///
        /// `@unchecked Sendable` because NSXPC delivers calls on arbitrary queues: the
        /// implementation must already tolerate that, which is a property of the service
        /// rather than of this wrapper.
        \(access)final class \(name)XPCAdapter: NSObject, \(name)XPCShim, @unchecked Sendable {
            private let implementation: any \(name)

            \(access)init(_ implementation: any \(name)) {
                self.implementation = implementation
            }

        \(implementations)
        }
        """
    }

    private static func facade(name: String, access: String) -> String {
        """
        /// Entry points generated by `@XPCService`.
        \(access)enum \(name)XPC {
            /// Assign to both `exportedInterface` and `remoteObjectInterface`.
            \(access)static var interface: NSXPCInterface {
                NSXPCInterface(with: \(name)XPCShim.self)
            }

            /// Wrap `connection` so it can be called through `\(name)`.
            \(access)static func remote(_ connection: NSXPCConnection) -> any \(name) {
                \(name)XPCClient(connection: connection)
            }

            /// Wrap an implementation for `NSXPCConnection.exportedObject`.
            \(access)static func exported(_ implementation: any \(name)) -> NSObject {
                \(name)XPCAdapter(implementation)
            }
        }
        """
    }
}
