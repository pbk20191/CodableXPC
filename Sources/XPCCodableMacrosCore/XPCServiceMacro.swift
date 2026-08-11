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
    case objcNameNotALiteral
    case proxyMarkerArgument
    case inheritedProtocol

    var severity: DiagnosticSeverity { .error }
    var diagnosticID: MessageID { MessageID(domain: "XPCCodableMacros", id: rawValue) }

    var message: String {
        switch self {
        case .notAProtocol:
            return "@XPCService can only be applied to a protocol"
        case .unsupportedShape:
            return """
                @XPCService cannot express this method. A method that returns a value \
                has to be able to throw: a dropped connection is not something it could \
                otherwise report, and inventing a return value for it would be worse. \
                Add 'throws' -- with 'async' the caller suspends, without it the caller \
                blocks. A method that returns nothing may also be 'async throws', \
                'throws', or have no effects at all and be one-way.
                """
        case .duplicateSelector:
            return """
                @XPCService cannot overload on parameter type: two methods here produce the \
                same Objective-C selector. Rename one of them.
                """
        case .associatedTypes:
            return "@XPCService does not support protocols with associated types"
        case .proxyMarkerArgument:
            return """
                XPCProxyMarker's argument has to be the plain name of a protocol marked \
                @XPCService, as in XPCProxyMarker<Ledger>. It cannot be optional, a \
                collection, a tuple, or a generic type: the macro turns the name into \
                <Name>XPCShim, and nothing else has one.
                """
        case .objcNameNotALiteral:
            return """
                @XPCService(objcName:) needs a plain string literal. The name is baked \
                into the generated @objc attribute at compile time, so it cannot be \
                computed.
                """
        case .inheritedProtocol:
            return """
                @XPCService cannot see requirements a protocol inherits. The macro is \
                syntactic -- it is handed this protocol's own text and nothing else, so an \
                inherited protocol's methods are invisible to it and would silently not be \
                carried across the connection. Copy the requirements you need into this \
                protocol. Only 'AnyObject' and 'Sendable' may be inherited, because neither \
                adds a requirement to carry.
                """
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
    /// `throws`: same wire shape as ``twoWayVoid``, but the caller blocks.
    case syncVoid
    /// `throws -> R`: same wire shape as ``twoWayValue``, but the caller blocks.
    case syncValue(returnType: TypeSyntax)
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
    /// The service named by `XPCProxyMarker<Service>`, or `nil`. This one crosses
    /// as a live proxy, so it is neither encoded nor passed through.
    let proxyService: String?

    var isBoxed: Bool { boxedType != nil }
    var isProxy: Bool { proxyService != nil }

    /// What the shim declares: the peer's `@objc` face for a proxy, a box when
    /// marked for encoding, the type verbatim otherwise.
    var shimType: String {
        if let service = proxyService { return "any \(service)" }
        return isBoxed ? "NSXPCCodableBridgeBox" : declaredType.trimmedDescription
    }

    /// What the convenience overload declares: unwrapped when marked.
    var bareType: String {
        if let service = proxyService { return "any \(service)" }
        return (boxedType ?? declaredType).trimmedDescription
    }

    func labelled(_ value: String) -> String {
        label.map { "\($0): \(value)" } ?? value
    }
}

/// Swift's numeric and `Bool` types bridge to `NSNumber`, but only the class is
/// representable in an `@objc` block: a reply carrying `Int?` will not compile,
/// while `NSNumber?` will. Carrying them boxed is the same bridge Objective-C
/// would have used, and the accessor puts the value back exactly.
///
/// Parameters need none of this -- a non-optional `Int` is representable. It is
/// the optionality a reply block forces that these types cannot express.
private let numberAccessors: [String: String] = [
    "Int": "intValue", "Int8": "int8Value", "Int16": "int16Value",
    "Int32": "int32Value", "Int64": "int64Value",
    "UInt": "uintValue", "UInt8": "uint8Value", "UInt16": "uint16Value",
    "UInt32": "uint32Value", "UInt64": "uint64Value",
    "Double": "doubleValue", "Float": "floatValue", "Bool": "boolValue",
]

private struct Method {
    let decl: FunctionDeclSyntax
    let shape: Shape
    let parameters: [Parameter]
    /// True when the return type was written as `XPCCodableMarker<T>`.
    let returnsMarker: Bool
    /// The service named by a returned `XPCProxyMarker<Service>`, or `nil`.
    let returnsProxyService: String?

    /// The `NSNumber` accessor for a bridged return, or `nil`.
    func numberAccessor(_ returnType: TypeSyntax) -> String? {
        guard !returnsMarker, returnsProxyService == nil else { return nil }
        return numberAccessors[returnType.trimmedDescription]
    }

    /// What the shim's reply block carries. Four cases, and they are exclusive:
    /// a proxy to the peer's object, a box of encoded bytes, an `NSNumber` for a
    /// type that cannot be optional in Objective-C, or the value itself.
    func replyType(_ returnType: TypeSyntax) -> String {
        if let service = returnsProxyService { return "(any \(service))?" }
        if returnsMarker { return "NSXPCCodableBridgeBox?" }
        if numberAccessor(returnType) != nil { return "NSNumber?" }
        return "\(returnType.trimmedDescription)?"
    }

    var name: String { decl.name.text }
    var hasBoxedParameter: Bool { parameters.contains(where: \.isBoxed) }
    var hasProxyParameter: Bool { parameters.contains(where: \.isProxy) }

    /// Every shape but ``Shape/oneWay`` carries a reply block. A sync method has the
    /// same wire shape as its async counterpart -- the difference is entirely in the
    /// client, which blocks on the reply instead of suspending.
    var expectsReply: Bool {
        if case .oneWay = shape { return false }
        return true
    }
    var isSynchronous: Bool {
        switch shape {
        case .syncVoid, .syncValue: return true
        case .twoWayValue, .twoWayVoid, .oneWay: return false
        }
    }
    /// The declared return type for the two value-returning shapes.
    var valueReturnType: TypeSyntax? {
        switch shape {
        case .twoWayValue(let type), .syncValue(let type): return type
        case .twoWayVoid, .oneWay, .syncVoid: return nil
        }
    }
    /// Whether the caller-facing overload has to unwrap what the marked method returns.
    var returnIsWrapped: Bool { returnsMarker || returnsProxyService != nil }

    /// `submit(_:count:note:reply:)` — the argument-label form `#selector` needs.
    ///
    /// Built rather than spelled as a string because Swift's selector mangling is
    /// not mechanical: `ping(reply:)` becomes `pingWithReply:`, not `ping:reply:`.
    /// Letting the compiler resolve it removes a whole class of silent mistakes.
    var selectorLabels: String {
        var pieces = parameters.map { "\($0.label ?? "_"):" }
        if expectsReply { pieces.append("reply:") }
        return "\(name)(\(pieces.joined()))"
    }

    /// Approximates the Objective-C selector, for collision detection.
    var selectorKey: String {
        let tail = parameters.enumerated().map { index, parameter in
            index == 0 ? "" : (parameter.label ?? "_")
        }.joined(separator: ":")
        return "\(name):\(tail)"
    }

    /// `_ a0: NSXPCCodableBridgeBox, id a1: Int, …` keeping the original labels so the
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
            // A proxy arrives as the peer's shim; wrap it so the implementation still
            // sees the Swift protocol it declared.
            if let service = parameter.proxyService {
                _ = service
                return parameter.labelled(
                    "XPCProxyMarker(wrappedValue: a\(index), lifetime: lifetime)")
            }
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
            // Vend the caller's own object. NSXPC turns it into a proxy on the far
            // side; the adapter is only the @objc face it needs to do that.
            if parameter.isProxy {
                // Vend the caller's own object. NSXPC turns it into a proxy on the
                // far side; nothing here has to understand what it is.
                return parameter.labelled("\(parameter.internalName).wrappedValue")
            }
            return parameter.labelled(
                parameter.isBoxed
                    ? "try NSXPCCodableBridgeBox(\(parameter.internalName).wrappedValue)"
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

        // Inheritance, and why it is refused rather than followed.
        //
        // The macro is syntactic: it receives this protocol's text and nothing else. It cannot
        // resolve `Base`, so it cannot generate shim methods for `Base`'s requirements -- and a
        // generated client that silently did not carry them is the worst available outcome. What
        // happened before this check was almost as bad: the client failed to conform, and the
        // error landed *inside macro expansion*, pointing at code the author never wrote
        // ("type 'DerivedXPCClient' does not conform to protocol 'Base'").
        //
        // `AnyObject` and `Sendable` are let through because neither adds a requirement to
        // carry. `AnyObject` does change what has to be generated, though -- see `isClassBound`.
        //
        // `NSObjectProtocol` is deliberately **not** on that list: it looks harmless and is not.
        // It requires `isEqual:`, `hash` and the rest, which a plain Swift class does not get
        // for free, so admitting it would trade one confusing generated-code error for another.
        let harmlessInheritance: Set<String> = ["AnyObject", "Sendable"]
        let inherited = proto.inheritanceClause?.inheritedTypes.map {
            $0.type.trimmedDescription
        } ?? []
        for name in inherited where !harmlessInheritance.contains(name) {
            // Pointed at the inheritance clause when there is one, so the caret lands on the
            // author's own text rather than on the attribute.
            context.diagnose(Diagnostic(node: proto.inheritanceClause.map(Syntax.init) ?? Syntax(node),
                                       message: XPCServiceDiagnostic.inheritedProtocol))
            return []
        }
        /// A class-bound protocol cannot be satisfied by a struct, and the generated client was
        /// one -- so `protocol P: AnyObject` failed with "non-class type 'PXPCClient' cannot
        /// conform to class protocol 'P'". It is a natural thing to write on a service protocol,
        /// so the client becomes a `final class` instead of the declaration being refused.
        let isClassBound = inherited.contains("AnyObject")

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

        // nil is "not asked for"; .some(nil) is "asked for but malformed", already
        // diagnosed.
        guard let objcName = objcName(from: node, in: context) else { return [] }

        return [
            DeclSyntax(stringLiteral: shim(name: name, access: access,
                                           objcName: objcName, methods: methods)),
            DeclSyntax(stringLiteral: client(name: name, access: access, methods: methods,
                                            isClassBound: isClassBound)),
            DeclSyntax(stringLiteral: adapter(name: name, access: access, methods: methods)),
            DeclSyntax(stringLiteral: facade(name: name, access: access, methods: methods)),
        ]
    }

    // MARK: parsing

    /// The explicit Objective-C name for the shim, if the author asked for one.
    ///
    /// Without it the shim's runtime name is module-qualified, and NSXPC matches
    /// interfaces by that name -- so both sides have to be built against the same
    /// module. That is the right default for a shared interface and the wrong one
    /// when the two sides cannot share a module at all, which is the case this
    /// parameter exists for.
    ///
    /// It is a name rather than a flag on purpose. Flattening to the unqualified
    /// `FooXPCShim` would still be a process-wide Objective-C identifier issued on
    /// the author's behalf; making them write the name puts the collision where
    /// they can see it.
    ///
    /// - Returns: `.some(nil)` when no name was given, `.some(.some(name))` when
    ///   one was, and `nil` when the argument was malformed and diagnosed.
    fileprivate static func objcName(
        from node: AttributeSyntax, in context: some MacroExpansionContext
    ) -> String?? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
              let argument = arguments.first(where: { $0.label?.text == "objcName" })
        else { return .some(nil) }

        guard let literal = argument.expression.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              case .stringSegment(let segment)? = literal.segments.first
        else {
            context.diagnose(Diagnostic(node: argument.expression,
                                        message: XPCServiceDiagnostic.objcNameNotALiteral))
            return nil
        }
        return .some(segment.content.text)
    }

    /// Mirror the protocol's visibility so the generated surface is reachable
    /// exactly where the protocol is.
    fileprivate static func accessModifier(of proto: ProtocolDeclSyntax) -> String {
        proto.modifiers.first {
            ["public", "package", "internal", "fileprivate", "private"].contains($0.name.text)
        }.map { "\($0.name.text) " } ?? ""
    }

    /// The Objective-C class a leaf type arrives as.
    private static func leafClassName(_ type: TypeSyntax) -> String {
        switch type.trimmedDescription {
        case "String": return "NSString"
        case "Int", "UInt", "Int8", "Int16", "Int32", "Int64",
             "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float", "Bool":
            return "NSNumber"
        case "Data": return "NSData"
        case "Date": return "NSDate"
        case "URL": return "NSURL"
        case "UUID": return "NSUUID"
        default: return type.trimmedDescription
        }
    }

    /// Appends every class NSXPC has to be told about for `type`, and reports
    /// whether a container was involved.
    ///
    /// Only containers need this. A class named directly in an `@objc` signature is
    /// allowed automatically — verified — but the moment it sits inside an array or
    /// dictionary NSXPC refuses it unless the interface whitelists the element type
    /// as well as the container.
    @discardableResult
    private static func collectClasses(_ type: TypeSyntax, into out: inout [String]) -> Bool {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return collectClasses(optional.wrappedType, into: &out)
        }
        if let array = type.as(ArrayTypeSyntax.self) {
            out.append("NSArray")
            collectClasses(array.element, into: &out)
            return true
        }
        if let dictionary = type.as(DictionaryTypeSyntax.self) {
            out.append("NSDictionary")
            collectClasses(dictionary.key, into: &out)
            collectClasses(dictionary.value, into: &out)
            return true
        }
        if let identifier = type.as(IdentifierTypeSyntax.self),
           identifier.name.text == "Set",
           let element = identifier.genericArgumentClause?.arguments.first?.argument.as(TypeSyntax.self) {
            out.append("NSSet")
            collectClasses(element, into: &out)
            return true
        }
        out.append(leafClassName(type))
        return false
    }

    /// The classes to register for `type`, or `nil` when no registration is needed.
    fileprivate static func containerClasses(for type: TypeSyntax) -> [String]? {
        var classes: [String] = []
        guard collectClasses(type, into: &classes) else { return nil }
        var seen = Set<String>()
        return classes.filter { seen.insert($0).inserted }
    }

    /// The `Service` in `XPCProxyMarker<Service>`, or `nil` if this is not one.
    ///
    /// `.some(nil)` means it was a proxy marker whose argument cannot be a service
    /// name; the caller diagnoses and stops.
    fileprivate static func proxyService(_ type: TypeSyntax) -> String?? {
        guard let identifier = type.as(IdentifierTypeSyntax.self),
              identifier.name.text == "XPCProxyMarker",
              let arguments = identifier.genericArgumentClause?.arguments,
              arguments.count == 1,
              let only = arguments.first,
              let inner = only.argument.as(TypeSyntax.self)
        else { return .some(nil) }

        // Both `XPCProxyMarker<Ledger>` and `XPCProxyMarker<any Ledger>` name Ledger.
        let bare = inner.as(SomeOrAnyTypeSyntax.self).map { $0.constraint } ?? inner
        guard let named = bare.as(IdentifierTypeSyntax.self),
              named.genericArgumentClause == nil
        else { return nil }
        return .some(.some(named.name.text))
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

            // From the declared type, before the shape rewrites it to the bare one.
            let returnsProxyService: String?
            if let returnType {
                guard let proxy = proxyService(returnType) else {
                    context.diagnose(Diagnostic(node: returnType,
                                                message: XPCServiceDiagnostic.proxyMarkerArgument))
                    return nil
                }
                returnsProxyService = proxy
            } else {
                returnsProxyService = nil
            }

            let shape: Shape
            switch (returnsValue, isAsync, isThrowing) {
            case (true, true, true):
                // Same rule as parameters: marked means Codable-boxed, unmarked
                // crosses as itself so an NSSecureCoding class can be returned
                // natively. Note the reply block needs an optional, so an unmarked
                // value type like Int is not representable -- the generated @objc
                // protocol reports that, which is the honest signal.
                // The shape carries what the caller sees, not what was written: the
                // payload for a marker, the bare existential for a proxy.
                shape = .twoWayValue(
                    returnType: markerPayload(returnType!)
                        ?? returnsProxyService.map { TypeSyntax(stringLiteral: "any \($0)") }
                        ?? returnType!)
            case (false, true, true):
                shape = .twoWayVoid
            case (false, false, true):
                shape = .syncVoid
            case (true, false, true):
                shape = .syncValue(
                    returnType: markerPayload(returnType!)
                        ?? returnsProxyService.map { TypeSyntax(stringLiteral: "any \($0)") }
                        ?? returnType!)
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
                guard let proxy = proxyService(declared) else {
                    context.diagnose(Diagnostic(node: declared,
                                                message: XPCServiceDiagnostic.proxyMarkerArgument))
                    return nil
                }
                parameters.append(Parameter(
                    label: syntax.firstName.text == "_" ? nil : syntax.firstName.text,
                    internalName: (syntax.secondName ?? syntax.firstName).text,
                    declaredType: declared,
                    boxedType: boxed,
                    proxyService: proxy))
            }

            methods.append(Method(decl: fn, shape: shape,
                                  parameters: parameters, returnsMarker: returnsMarker,
                                  returnsProxyService: returnsProxyService))
        }
        return methods
    }

    private static func isVoid(_ type: TypeSyntax) -> Bool {
        let text = type.trimmedDescription
        return text == "Void" || text == "()"
    }

    // MARK: generation

    private static func shim(name: String, access: String,
                             objcName: String?, methods: [Method]) -> String {
        let requirements = methods.map { method -> String in
            let parameters = method.shimParameters
            switch method.shape {
            case .twoWayValue(let returnType), .syncValue(let returnType):
                let replyType = method.replyType(returnType)
                return "    func \(method.name)(\((parameters + ["reply: @escaping (\(replyType), (any Error)?) -> Void"]).joined(separator: ", ")))"
            case .twoWayVoid, .syncVoid:
                return "    func \(method.name)(\((parameters + ["reply: @escaping ((any Error)?) -> Void"]).joined(separator: ", ")))"
            case .oneWay:
                return "    func \(method.name)(\(parameters.joined(separator: ", ")))"
            }
        }.joined(separator: "\n")

        return """
        /// The Objective-C face of `\(name)`, which is all NSXPC can see. Generated by
        /// `@XPCService`; you name it when configuring a connection, never implement it.
        @objc\(objcName.map { "(\($0))" } ?? "") \(access)protocol \(name)XPCShim {
        \(requirements)
        }
        """
    }

    private static func client(name: String, access: String, methods: [Method],
                               isClassBound: Bool) -> String {
        let implementations = methods.map { method -> String in
            let signature = method.decl.signature.trimmedDescription
            let arguments = method.clientArguments

            switch method.shape {
            case .twoWayValue(let returnType):
                // `arguments` is empty for a no-argument method, so the reply closure
                // has to join as a list element rather than follow a comma.
                let call = method.name + "(" + (arguments + ["reply: { box, error in"]).joined(separator: ", ")
                let payload = returnType.trimmedDescription
                let rewrapped = method.returnsProxyService
                    .map { _ in "XPCProxyMarker(wrappedValue: box, lifetime: sourceLifetime)" }
                    ?? (method.returnsMarker
                        ? "XPCCodableMarker(wrappedValue: try box.decode(\(payload).self))"
                        : (method.numberAccessor(returnType).map { "box.\($0)" } ?? "box"))
                // The Swift type the *declaration* promises, which is what the resumption is
                // generic over -- `returnType` here is the unwrapped payload, so a marker or a
                // proxy-marker return would give the resumption the wrong type and the
                // `succeed(_:)` call would not compile. Same expression as `.syncValue` below.
                let declared = method.returnsMarker
                    ? "XPCCodableMarker<\(payload)>"
                    : (method.returnsProxyService.map { "XPCProxyMarker<\($0)>" } ?? payload)
                return """
                    \(access)func \(method.name)\(signature) {
                        let resumption = XPCCallResumption<\(declared)>()
                        return try await withTaskCancellationHandler {
                            try await withCheckedThrowingContinuation { continuation in
                                resumption.park(continuation)
                                guard let proxy = proxy(resumingOnFailure: { resumption.fail($0) }) else {
                                    resumption.fail(XPCServiceError.proxyUnavailable)
                                    return
                                }
                                do {
                                    try proxy.\(call)
                                        if let error { resumption.fail(error); return }
                                        guard let box else {
                                            resumption.fail(XPCServiceError.missingReply)
                                            return
                                        }
                                        do { resumption.succeed(\(rewrapped)) }
                                        catch { resumption.fail(error) }
                                    })
                                } catch {
                                    resumption.fail(error)
                                }
                            }
                        } onCancel: {
                            resumption.cancel()
                        }
                    }
                """
            case .twoWayVoid:
                let call = method.name + "(" + (arguments + ["reply: { error in"]).joined(separator: ", ")
                return """
                    \(access)func \(method.name)\(signature) {
                        let resumption = XPCCallResumption<Void>()
                        return try await withTaskCancellationHandler {
                            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                                resumption.park(continuation)
                                guard let proxy = proxy(resumingOnFailure: { resumption.fail($0) }) else {
                                    resumption.fail(XPCServiceError.proxyUnavailable)
                                    return
                                }
                                do {
                                    try proxy.\(call)
                                        if let error { resumption.fail(error) }
                                        else { resumption.succeed(()) }
                                    })
                                } catch {
                                    resumption.fail(error)
                                }
                            }
                        } onCancel: {
                            resumption.cancel()
                        }
                    }
                """
            case .syncValue(let returnType):
                let call = method.name + "(" + (arguments + ["reply: { box, error in"]).joined(separator: ", ")
                let payload = returnType.trimmedDescription
                let rewrapped = method.returnsProxyService
                    .map { _ in "XPCProxyMarker(wrappedValue: box, lifetime: sourceLifetime)" }
                    ?? (method.returnsMarker
                        ? "XPCCodableMarker(wrappedValue: try box.decode(\(payload).self))"
                        : (method.numberAccessor(returnType).map { "box.\($0)" } ?? "box"))
                let declared = method.returnsMarker
                    ? "XPCCodableMarker<\(payload)>"
                    : (method.returnsProxyService.map { "XPCProxyMarker<\($0)>" } ?? payload)
                return """
                    \(access)func \(method.name)\(signature) {
                        // The synchronous proxy runs the reply block, or the error
                        // handler, before this call returns -- so the outcome is
                        // already there to be read on the line after.
                        let outcome = XPCSyncOutcome<\(declared)>()
                        guard let proxy = synchronousProxy(reportingFailureTo: {
                            outcome.set(.failure($0))
                        }) else {
                            throw XPCServiceError.proxyUnavailable
                        }
                        try proxy.\(call)
                            if let error { outcome.set(.failure(error)); return }
                            guard let box else {
                                outcome.set(.failure(XPCServiceError.missingReply)); return
                            }
                            do { outcome.set(.success(\(rewrapped))) }
                            catch { outcome.set(.failure(error)) }
                        })
                        outcome.wait()
                        return try outcome.take()
                    }
                """
            case .syncVoid:
                let call = method.name + "(" + (arguments + ["reply: { error in"]).joined(separator: ", ")
                return """
                    \(access)func \(method.name)\(signature) {
                        let outcome = XPCSyncOutcome<Void>()
                        guard let proxy = synchronousProxy(reportingFailureTo: {
                            outcome.set(.failure($0))
                        }) else {
                            throw XPCServiceError.proxyUnavailable
                        }
                        try proxy.\(call)
                            outcome.set(error.map { .failure($0) } ?? .success(()))
                        })
                        outcome.wait()
                        return try outcome.take()
                    }
                """
            case .oneWay:
                // A one-way method has no reply block and cannot throw, so a failure
                // here has nowhere to go but a trap. Returning quietly would let a
                // call that never happened look like one that did.
                let label = "\(name).\(method.name)"
                return """
                    \(access)func \(method.name)\(signature) {
                        precondition(deadPeer == nil,
                            "\(label): one-way call on a dead peer -- \\(deadPeer!)")
                        guard let proxy = proxy(resumingOnFailure: { _ in }) else {
                            preconditionFailure(
                                "\(label): one-way call with no proxy -- the connection's "
                                + "remoteObjectInterface is unset or names another service")
                        }
                        \(method.hasBoxedParameter ? """
                        do {
                                    // The `try` belongs to the boxing in the arguments, not
                                    // to the shim call, which cannot throw.
                                    proxy.\(method.name)(\(arguments.joined(separator: ", ")))
                                } catch {
                                    preconditionFailure("\(label): one-way argument could not be encoded -- \\(error)")
                                }
                        """ : "proxy.\(method.name)(\(arguments.joined(separator: ", ")))")
                    }
                """
            }
        }.joined(separator: "\n\n")

        return """
        /// Client half generated by `@XPCService`. Obtain one from `\(name)XPC.remote(_:)`.
        \(access)\(isClassBound ? "final class" : "struct") \(name)XPCClient: \(name) {
            /// Every call below goes through `proxy(resumingOnFailure:)` and none of
            /// them care where the shim came from, which is what lets a proxy handed
            /// over as an argument be driven by exactly the same code as a connection.
            private enum Source {
                case connection(NSXPCConnection)
                case proxy(any \(name)XPCShim, XPCProxyLifetime)
            }
            private let source: Source

            \(access)init(connection: NSXPCConnection) {
                self.source = .connection(connection)
            }

            /// Wrap a peer's object that arrived as an `XPCProxyMarker` argument.
            ///
            /// The lifetime is the object's only failure channel: a proxy is not a
            /// connection and has no error handler, so without one a call made
            /// after the far side went away never completes at all.
            \(access)init(proxy: any \(name)XPCShim,
                          lifetime: XPCProxyLifetime = .unbounded) {
                self.source = .proxy(proxy, lifetime)
            }

            private func proxy(
                resumingOnFailure onFailure: @escaping @Sendable (any Error) -> Void
            ) -> (any \(name)XPCShim)? {
                switch source {
                case .connection(let connection):
                    return connection.remoteObjectProxyWithErrorHandler(onFailure) as? any \(name)XPCShim
                case .proxy(let shim, let lifetime):
                    // A proxy has no error handler of its own, so the lifetime the
                    // adapter recorded stands in for one. Registering here means an
                    // in-flight call is resolved when the connection dies rather
                    // than waiting for a reply that cannot arrive.
                    lifetime.onFailure(onFailure)
                    return shim
                }
            }

            /// Whether the peer is known to be gone, read synchronously.
            ///
            /// Only a proxy can answer: its lifetime was recorded by the adapter that
            /// received it. A connection reports asynchronously, through the error
            /// handler, and there is no public way to ask it now -- so a connection
            /// that dies mid-call stays silent for a one-way method, which is what
            /// NSXPC does with such messages anyway.
            private var deadPeer: (any Error)? {
                if case .proxy(_, let lifetime) = source { return lifetime.recordedFailure }
                return nil
            }

            /// The failure channel to attach to a proxy that arrives in a *reply*.
            /// Its lifetime is this client's own connection, since that is what the
            /// object came over.
            private var sourceLifetime: XPCProxyLifetime {
                switch source {
                case .connection(let connection): return XPCProxyLifetime(watching: connection)
                case .proxy(_, let lifetime): return lifetime
                }
            }

            /// The blocking counterpart. NSXPC runs the reply block on this thread
            /// before the proxy call returns; a proxy handed over as an argument is
            /// already local, and its adapter replies inline for these shapes, so the
            /// same code reads the outcome either way.
            private func synchronousProxy(
                reportingFailureTo onFailure: @escaping @Sendable (any Error) -> Void
            ) -> (any \(name)XPCShim)? {
                switch source {
                case .connection(let connection):
                    return connection.synchronousRemoteObjectProxyWithErrorHandler(onFailure) as? any \(name)XPCShim
                case .proxy(let shim, let lifetime):
                    lifetime.onFailure(onFailure)
                    return shim
                }
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
            // NSXPCConnection.current() is set only while the call is being
            // handled: it is nil inside a Task, and reading it from an async
            // context is an error under the Swift 6 language mode. Capture first.
            // Folded into the first line of the body so the interpolation keeps the
            // literal's indentation; an empty string leaves that line untouched.
            let captureLifetime = method.hasProxyParameter
                ? "let lifetime = XPCProxyLifetime(watching: NSXPCConnection.current())\n                        "
                : ""

            switch method.shape {
            case .twoWayValue(let returnType):
                let replyType = method.replyType(returnType)
                // Same three cases as the reply type, in the same order.
                let produced = method.returnsProxyService.map { _ in "result.wrappedValue" }
                    ?? (method.returnsMarker
                        ? "try NSXPCCodableBridgeBox(result\(unwrapReturn))"
                        : (method.numberAccessor(returnType) != nil
                            ? "NSNumber(value: result)"
                            : "result"))
                return """
                    \(access)func \(method.name)(\((parameters + ["reply: @escaping (\(replyType), (any Error)?) -> Void"]).joined(separator: ", "))) {
                        \(captureLifetime)let implementation = self.implementation
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
                        \(captureLifetime)let implementation = self.implementation
                        Task {
                            do { try await implementation.\(method.name)(\(arguments)); reply(nil) }
                            catch { reply(error) }
                        }
                    }
                """
            case .syncValue(let returnType):
                let replyType = method.replyType(returnType)
                let produced = method.returnsProxyService.map { _ in "result.wrappedValue" }
                    ?? (method.returnsMarker
                        ? "try NSXPCCodableBridgeBox(result\(unwrapReturn))"
                        : (method.numberAccessor(returnType) != nil
                            ? "NSNumber(value: result)"
                            : "result"))
                return """
                    \(access)func \(method.name)(\((parameters + ["reply: @escaping (\(replyType), (any Error)?) -> Void"]).joined(separator: ", "))) {
                        \(captureLifetime)// No Task: the implementation is synchronous too, and the caller
                        // is blocked on this reply running before the call returns.
                        do {
                            let result = try implementation.\(method.name)(\(arguments))
                            reply(\(produced), nil)
                        } catch { reply(nil, error) }
                    }
                """
            case .syncVoid:
                return """
                    \(access)func \(method.name)(\((parameters + ["reply: @escaping ((any Error)?) -> Void"]).joined(separator: ", "))) {
                        \(captureLifetime)do { try implementation.\(method.name)(\(arguments)); reply(nil) }
                        catch { reply(error) }
                    }
                """
            case .oneWay:
                return """
                    \(access)func \(method.name)(\(parameters.joined(separator: ", "))) {
                        \(captureLifetime)\(method.hasBoxedParameter ? """
                        // One-way: there is no reply block, so a decode failure has
                                // nowhere to go. Dropping it matches NSXPC, and unlike the
                                // client side a trap here would let any sender crash the
                                // service by mangling one argument.
                                do {
                                    implementation.\(method.name)(\(arguments))
                                } catch {}
                        """ : "implementation.\(method.name)(\(arguments))")
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
        \(access)final class \(name)XPCAdapter<T: \(name)>: \(name)XPCShim, @unchecked Sendable {
            private let implementation: T

            \(access)init(_ implementation: T) {
                self.implementation = implementation
            }

        \(implementations)
        }
        """
    }

    private static func facade(name: String, access: String, methods: [Method]) -> String {
        // A class named directly in the signature is allowed automatically; one
        // inside a container is not. Emit the whitelisting NSXPC would otherwise
        // reject the message for, so a passed-through `[Item]` just works.
        var registrations: [String] = []
        for method in methods {
            let selector = "#selector(\(name)XPCShim.\(method.selectorLabels))"
            for (index, parameter) in method.parameters.enumerated() {
                // A proxy is not encoded, so it needs the peer's interface rather than
                // a class whitelist. This is what makes NSXPC vend the object.
                if let service = parameter.proxyService {
                    registrations.append("""
                            interface.setInterface(
                                NSXPCInterface(with: \(service).self),
                                for: \(selector), argumentIndex: \(index), ofReply: false)
                    """)
                    continue
                }
                guard !parameter.isBoxed,
                      let classes = containerClasses(for: parameter.declaredType) else { continue }
                registrations.append("""
                        interface.setClasses(
                            NSSet(array: [\(classes.map { "\($0).self" }.joined(separator: ", "))]) as! Set<AnyHashable>,
                            for: \(selector), argumentIndex: \(index), ofReply: false)
                """)
            }
            if method.valueReturnType != nil, let service = method.returnsProxyService {
                registrations.append("""
                        interface.setInterface(
                            NSXPCInterface(with: \(service).self),
                            for: \(selector), argumentIndex: 0, ofReply: true)
                """)
            }
            if let returnType = method.valueReturnType,
               !method.returnsMarker, method.returnsProxyService == nil,
               let classes = containerClasses(for: returnType) {
                registrations.append("""
                        interface.setClasses(
                            NSSet(array: [\(classes.map { "\($0).self" }.joined(separator: ", "))]) as! Set<AnyHashable>,
                            for: \(selector), argumentIndex: 0, ofReply: true)
                """)
            }
        }
        let body = registrations.isEmpty
            ? "        NSXPCInterface(with: \(name)XPCShim.self)"
            : """
                    let interface = NSXPCInterface(with: \(name)XPCShim.self)
            \(registrations.joined(separator: "\n"))
                    return interface
            """

        return """
        /// Entry points generated by `@XPCService`.
        \(access)enum \(name)XPC {
            /// Assign to both `exportedInterface` and `remoteObjectInterface`.
            ///
            /// Any container-typed parameter that crosses natively is whitelisted here
            /// already — NSXPC rejects a class nested inside an array or dictionary
            /// unless the interface names both.
            \(access)static var interface: NSXPCInterface {
        \(body)
            }

            /// Wrap `connection` so it can be called through `\(name)`.
            \(access)static func remote(_ connection: NSXPCConnection) -> any \(name) {
                \(name)XPCClient(connection: connection)
            }

            /// Wrap an implementation for `NSXPCConnection.exportedObject`.
            ///
            /// Generic over the implementation, so the adapter holds it concretely
            /// rather than boxed. An existential still works at the call site --
            /// Swift opens it into `T` implicitly.
            \(access)static func exported<T: \(name)>(_ implementation: T) -> any \(name)XPCShim {
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

        let overloads = methods.filter { $0.hasBoxedParameter || $0.hasProxyParameter }
            .map { method -> String in
            let declared = method.parameters.map { parameter -> String in
                // `memo memo:` is a duplicate name, not a label plus a name.
                let label = parameter.label ?? "_"
                let prefix = label == parameter.internalName ? "" : "\(label) "
                return "\(prefix)\(parameter.internalName): \(parameter.bareType)"
            }.joined(separator: ", ")

            let forwarded = method.parameters.map { parameter in
                if parameter.isProxy {
                    return parameter.labelled(
                        "XPCProxyMarker(wrappedValue: \(parameter.internalName))")
                }
                return parameter.labelled(
                    parameter.isBoxed
                        ? "XPCCodableMarker(wrappedValue: \(parameter.internalName))"
                        : parameter.internalName)
            }.joined(separator: ", ")

            switch method.shape {
            case .twoWayValue(let returnType):
                return """
                    \(access)func \(method.name)(\(declared)) async throws -> \(returnType.trimmedDescription) {
                        try await \(method.name)(\(forwarded))\(method.returnIsWrapped ? ".wrappedValue" : "")
                    }
                """
            case .twoWayVoid:
                return """
                    \(access)func \(method.name)(\(declared)) async throws {
                        try await \(method.name)(\(forwarded))
                    }
                """
            case .syncValue(let returnType):
                return """
                    \(access)func \(method.name)(\(declared)) throws -> \(returnType.trimmedDescription) {
                        try \(method.name)(\(forwarded))\(method.returnIsWrapped ? ".wrappedValue" : "")
                    }
                """
            case .syncVoid:
                return """
                    \(access)func \(method.name)(\(declared)) throws {
                        try \(method.name)(\(forwarded))
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
