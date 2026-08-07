import SwiftSyntax
import SwiftSyntaxBuilder
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

// MARK: - Model

/// How a protocol requirement maps onto an `@objc` shim method.
private enum Shape {
    /// `async throws -> R`: reply carries a boxed value or an error.
    case twoWayValue(returnType: TypeSyntax)
    /// `async throws`: reply carries an error or nothing.
    case twoWayVoid
    /// no effects, no return: fire and forget, no reply block.
    case oneWay
}

private struct Parameter {
    /// The label as written, `nil` where the source used `_`.
    let label: String?
    /// The name the parameter is known by inside a body.
    let internalName: String
    /// As written in the protocol: `XPCCodableMarker<Person>`, or `Int`.
    let declaredType: TypeSyntax
    /// The payload inside the marker, or `nil` when the parameter passes through.
    let boxedType: TypeSyntax?

    var isBoxed: Bool { boxedType != nil }

    /// What the shim declares: a box when marked, the type verbatim otherwise.
    var shimType: String { isBoxed ? "CodableBox" : declaredType.trimmedDescription }

    /// What the convenience overload declares: unwrapped when marked.
    var bareType: String { (boxedType ?? declaredType).trimmedDescription }

    func labelled(_ value: String) -> String {
        label.map { "\($0): \(value)" } ?? value
    }
}

private struct Method {
    let decl: FunctionDeclSyntax
    let shape: Shape
    let parameters: [Parameter]
    /// True when the return type was written as `XPCCodableMarker<T>`.
    let returnsMarker: Bool

    var name: String { decl.name.text }
    var hasBoxedParameter: Bool { parameters.contains(where: \.isBoxed) }

    /// Approximates the Objective-C selector, for collision detection.
    var selectorKey: String {
        let tail = parameters.enumerated().map { index, parameter in
            index == 0 ? "" : (parameter.label ?? "_")
        }.joined(separator: ":")
        return "\(name):\(tail)"
    }

    /// `_ a0: CodableBox, id a1: Int, …` keeping the original labels so the
    /// generated selector reads naturally.
    var shimParameters: [String] {
        parameters.enumerated().map { index, parameter in
            "\(parameter.label ?? "_") a\(index): \(parameter.shimType)"
        }
    }

    /// What the adapter passes into the implementation. A boxed parameter is decoded
    /// and re-wrapped, because the implementation's signature still says
    /// `XPCCodableMarker<Person>`.
    var adapterArguments: [String] {
        parameters.enumerated().map { index, parameter in
            guard let boxed = parameter.boxedType else {
                return parameter.labelled("a\(index)")
            }
            return parameter.labelled(
                "XPCCodableMarker(wrappedValue: try a\(index).decode(\(boxed.trimmedDescription).self))")
        }
    }

    /// What the client passes into the shim.
    var clientArguments: [String] {
        parameters.map { parameter in
            parameter.labelled(
                parameter.isBoxed
                    ? "try CodableBox(\(parameter.internalName).wrappedValue)"
                    : parameter.internalName)
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
        let access = accessModifier(of: proto)

        return [
            DeclSyntax(stringLiteral: shim(name: name, access: access, methods: methods)),
            DeclSyntax(stringLiteral: client(name: name, access: access, methods: methods)),
            DeclSyntax(stringLiteral: adapter(name: name, access: access, methods: methods)),
            DeclSyntax(stringLiteral: facade(name: name, access: access)),
        ]
    }

    // MARK: parsing

    /// Mirror the protocol's visibility so the generated surface is reachable
    /// exactly where the protocol is.
    fileprivate static func accessModifier(of proto: ProtocolDeclSyntax) -> String {
        proto.modifiers.first {
            ["public", "package", "internal", "fileprivate", "private"].contains($0.name.text)
        }.map { "\($0.name.text) " } ?? ""
    }

    /// The `T` in `XPCCodableMarker<T>`, or `nil` if this is not a marker.
    fileprivate static func markerPayload(_ type: TypeSyntax) -> TypeSyntax? {
        guard let identifier = type.as(IdentifierTypeSyntax.self),
              identifier.name.text == "XPCCodableMarker",
              let arguments = identifier.genericArgumentClause?.arguments,
              arguments.count == 1,
              let only = arguments.first
        else { return nil }
        return only.argument.as(TypeSyntax.self)
    }

    fileprivate static func parse(
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
            let returnsMarker = returnType.flatMap(markerPayload) != nil

            let shape: Shape
            switch (returnsValue, isAsync, isThrowing) {
            case (true, true, true):
                // Same rule as parameters: marked means Codable-boxed, unmarked
                // crosses as itself so an NSSecureCoding class can be returned
                // natively. Note the reply block needs an optional, so an unmarked
                // value type like Int is not representable -- the generated @objc
                // protocol reports that, which is the honest signal.
                shape = .twoWayValue(returnType: markerPayload(returnType!) ?? returnType!)
            case (false, true, true):
                shape = .twoWayVoid
            case (false, false, false):
                shape = .oneWay
            default:
                context.diagnose(Diagnostic(node: fn, message: XPCServiceDiagnostic.unsupportedShape))
                return nil
            }

            var parameters: [Parameter] = []
            for syntax in fn.signature.parameterClause.parameters {
                // Unmarked types pass through as themselves. That is deliberate: a
                // custom NSSecureCoding class is exactly what NSXPC exists to carry,
                // and forcing it through Codable would be wrong. If a type is not
                // representable in Objective-C the generated @objc protocol says so.
                let declared = syntax.type
                let boxed = markerPayload(declared)
                parameters.append(Parameter(
                    label: syntax.firstName.text == "_" ? nil : syntax.firstName.text,
                    internalName: (syntax.secondName ?? syntax.firstName).text,
                    declaredType: declared,
                    boxedType: boxed))
            }

            methods.append(Method(decl: fn, shape: shape,
                                  parameters: parameters, returnsMarker: returnsMarker))
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
            let parameters = method.shimParameters
            switch method.shape {
            case .twoWayValue(let returnType):
                let replyType = method.returnsMarker ? "CodableBox?" : "\(returnType.trimmedDescription)?"
                return "    func \(method.name)(\((parameters + ["reply: @escaping (\(replyType), (any Error)?) -> Void"]).joined(separator: ", ")))"
            case .twoWayVoid:
                return "    func \(method.name)(\((parameters + ["reply: @escaping ((any Error)?) -> Void"]).joined(separator: ", ")))"
            case .oneWay:
                return "    func \(method.name)(\(parameters.joined(separator: ", ")))"
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
            let arguments = method.clientArguments

            switch method.shape {
            case .twoWayValue(let returnType):
                // `arguments` is empty for a no-argument method, so the reply closure
                // has to join as a list element rather than follow a comma.
                let call = method.name + "(" + (arguments + ["reply: { box, error in"]).joined(separator: ", ")
                let payload = returnType.trimmedDescription
                let rewrapped = method.returnsMarker
                    ? "XPCCodableMarker(wrappedValue: try box.decode(\(payload).self))"
                    : "box"
                return """
                    \(access)func \(method.name)\(signature) {
                        try await withCheckedThrowingContinuation { continuation in
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
                                    do { continuation.resume(returning: \(rewrapped)) }
                                    catch { continuation.resume(throwing: error) }
                                })
                            } catch {
                                if once.claim() { continuation.resume(throwing: error) }
                            }
                        }
                    }
                """
            case .twoWayVoid:
                let call = method.name + "(" + (arguments + ["reply: { error in"]).joined(separator: ", ")
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
                        try? proxy.\(method.name)(\(arguments.joined(separator: ", ")))
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
            let parameters = method.shimParameters
            let arguments = method.adapterArguments.joined(separator: ", ")
            let unwrapReturn = method.returnsMarker ? ".wrappedValue" : ""

            switch method.shape {
            case .twoWayValue(let returnType):
                let replyType = method.returnsMarker ? "CodableBox?" : "\(returnType.trimmedDescription)?"
                let produced = method.returnsMarker
                    ? "try CodableBox(result\(unwrapReturn))"
                    : "result"
                return """
                    \(access)func \(method.name)(\((parameters + ["reply: @escaping (\(replyType), (any Error)?) -> Void"]).joined(separator: ", "))) {
                        let implementation = self.implementation
                        Task {
                            do {
                                let result = try await implementation.\(method.name)(\(arguments))
                                reply(\(produced), nil)
                            } catch { reply(nil, error) }
                        }
                    }
                """
            case .twoWayVoid:
                return """
                    \(access)func \(method.name)(\((parameters + ["reply: @escaping ((any Error)?) -> Void"]).joined(separator: ", "))) {
                        let implementation = self.implementation
                        Task {
                            do { try await implementation.\(method.name)(\(arguments)); reply(nil) }
                            catch { reply(error) }
                        }
                    }
                """
            case .oneWay:
                return """
                    \(access)func \(method.name)(\(parameters.joined(separator: ", "))) {
                        // One-way: there is no reply block, so a decode failure has nowhere
                        // to go. Dropping it matches NSXPC's own behaviour for such calls.
                        try? implementation.\(method.name)(\(arguments))
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

// MARK: - Convenience overloads

extension XPCServiceMacro: ExtensionMacro {

    /// Adds an overload of every marked method taking and returning bare values, so
    /// a caller writes `greet(person)` rather than
    /// `greet(XPCCodableMarker(wrappedValue: person))`.
    ///
    /// This has to be an extension role. A peer macro cannot emit one — the compiler
    /// rejects that with "macro expansion cannot introduce extension" — and without
    /// these overloads, marking a parameter would make every call site worse rather
    /// than better.
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Both roles parse the same protocol. Diagnostics are suppressed here so a
        // rejected requirement is reported once, by the peer role, rather than twice.
        guard let proto = declaration.as(ProtocolDeclSyntax.self),
              let methods = parse(proto, in: SilentContext(wrapping: context))
        else { return [] }

        let access = accessModifier(of: proto)

        let overloads = methods.filter(\.hasBoxedParameter).map { method -> String in
            let declared = method.parameters.map {
                "\($0.label ?? "_") \($0.internalName): \($0.bareType)"
            }.joined(separator: ", ")

            let forwarded = method.parameters.map { parameter in
                parameter.labelled(
                    parameter.isBoxed
                        ? "XPCCodableMarker(wrappedValue: \(parameter.internalName))"
                        : parameter.internalName)
            }.joined(separator: ", ")

            switch method.shape {
            case .twoWayValue(let returnType):
                return """
                    \(access)func \(method.name)(\(declared)) async throws -> \(returnType.trimmedDescription) {
                        try await \(method.name)(\(forwarded))\(method.returnsMarker ? ".wrappedValue" : "")
                    }
                """
            case .twoWayVoid:
                return """
                    \(access)func \(method.name)(\(declared)) async throws {
                        try await \(method.name)(\(forwarded))
                    }
                """
            case .oneWay:
                return """
                    \(access)func \(method.name)(\(declared)) {
                        \(method.name)(\(forwarded))
                    }
                """
            }
        }
        guard !overloads.isEmpty else { return [] }

        let text: DeclSyntax = """
            extension \(raw: type.trimmedDescription) {
            \(raw: overloads.joined(separator: "\n\n"))
            }
            """
        return text.as(ExtensionDeclSyntax.self).map { [$0] } ?? []
    }
}

/// Discards diagnostics. Used so the extension role can re-parse without repeating
/// what the peer role already reported.
private final class SilentContext<Wrapped: MacroExpansionContext>: MacroExpansionContext {
    let wrapped: Wrapped
    init(wrapping wrapped: Wrapped) { self.wrapped = wrapped }

    func makeUniqueName(_ name: String) -> TokenSyntax { wrapped.makeUniqueName(name) }
    func diagnose(_ diagnostic: Diagnostic) {}
    func location(
        of node: some SyntaxProtocol,
        at position: PositionInSyntaxNode,
        filePathMode: SourceLocationFilePathMode
    ) -> AbstractSourceLocation? {
        wrapped.location(of: node, at: position, filePathMode: filePathMode)
    }
    var lexicalContext: [Syntax] { wrapped.lexicalContext }
}
