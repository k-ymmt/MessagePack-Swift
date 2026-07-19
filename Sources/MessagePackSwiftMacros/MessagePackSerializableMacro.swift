import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Diagnostics

enum MessagePackMacroDiagnostic: String, DiagnosticMessage {
    case notAStruct
    case missingTypeAnnotation
    case unsupportedPattern
    case invalidKeyArgument

    var message: String {
        switch self {
        case .notAStruct:
            return """
                '@MessagePackSerializable' can only be applied to a struct. Enums with a raw \
                value can conform to 'MessagePackSerializable' directly; a default \
                implementation is provided for 'RawRepresentable' types.
                """
        case .missingTypeAnnotation:
            return """
                '@MessagePackSerializable' requires an explicit type annotation on this stored \
                property so it can be decoded. Add a type annotation, or exclude the property \
                with '@MessagePackIgnored'.
                """
        case .unsupportedPattern:
            return "'@MessagePackSerializable' does not support tuple-pattern stored properties."
        case .invalidKeyArgument:
            return "'@MessagePackKey' requires a single static string literal argument."
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "MessagePackSwiftMacros", id: rawValue)
    }

    var severity: DiagnosticSeverity { .error }
}

// MARK: - Marker macros

/// `@MessagePackIgnored` — a marker read by ``MessagePackSerializableMacro``;
/// expands to nothing itself.
public struct MessagePackIgnoredMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// `@MessagePackKey("name")` — a marker read by
/// ``MessagePackSerializableMacro``; expands to nothing itself.
public struct MessagePackKeyMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

// MARK: - @MessagePackSerializable

/// Generates a `MessagePackSerializable` conformance for a struct: a
/// `serialize(into:)` method that writes the struct as a MessagePack map of
/// field name to field value, and an `init(messagePack:)` that reads it back,
/// accepting fields in any order and skipping unknown keys.
public struct MessagePackSerializableMacro: ExtensionMacro {
    /// One stored property participating in serialization.
    private struct Field {
        /// The property name without backticks, used as the default map key.
        var name: String
        /// The map key on the wire (`@MessagePackKey` override or `name`).
        var key: String
        /// The declared type, as written.
        var type: TypeSyntax?
        /// A type expression usable as `<Type>(messagePack: &reader)`.
        /// Optional sugar is normalized to `Optional<...>`.
        var constructor: String?
        /// Whether the declared type is optional (missing fields decode as nil).
        var isOptional: Bool
        /// The initializer expression, used for missing fields when present.
        var defaultValue: String?
        /// False for `let` properties with an initializer, which cannot be
        /// assigned in an initializer; they are encoded but not decoded.
        var isDecodable: Bool
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(
                Diagnostic(node: Syntax(node), message: MessagePackMacroDiagnostic.notAStruct))
            return []
        }
        guard let fields = collectFields(of: structDecl, in: context) else {
            return []
        }

        let access = accessModifier(of: structDecl)
        let conformanceClause = protocols.isEmpty ? "" : ": MessagePackSwift.MessagePackSerializable"
        let whereClause = genericWhereClause(of: structDecl, fields: fields)

        let extensionSource = """
            extension \(type.trimmed)\(conformanceClause)\(whereClause) {
            \(serializeMethod(fields: fields, access: access))

            \(initializer(fields: fields, access: access))
            }
            """
        return [try ExtensionDeclSyntax("\(raw: extensionSource)")]
    }

    // MARK: Code generation

    private static func serializeMethod(fields: [Field], access: String) -> String {
        var lines: [String] = []
        lines.append("\(access)func serialize(into writer: inout MessagePackSwift.MessagePackWriter) {")
        lines.append("    writer.writeMapHeader(count: \(fields.count))")
        for field in fields {
            lines.append("    writer.writeKey(\(literal(field.key)))")
            lines.append("    self.`\(field.name)`.serialize(into: &writer)")
        }
        lines.append("}")
        return lines.map { "    \($0)" }.joined(separator: "\n")
    }

    private static func initializer(fields: [Field], access: String) -> String {
        let decodable = fields.filter(\.isDecodable)
        var lines: [String] = []
        lines.append(
            "\(access)init(messagePack reader: inout MessagePackSwift.MessagePackReader) throws(MessagePackSwift.MessagePackError) {"
        )
        if decodable.isEmpty {
            lines.append("    let _msgpackEntryCount = try reader.readMapHeader()")
            lines.append("    for _ in 0 ..< _msgpackEntryCount {")
            lines.append("        try reader.skipValue()")
            lines.append("        try reader.skipValue()")
            lines.append("    }")
        } else {
            for field in decodable {
                lines.append("    var _msgpack_\(field.name): Optional<\(field.type!.trimmed)> = nil")
            }
            lines.append("    let _msgpackEntryCount = try reader.readMapHeader()")
            lines.append("    for _ in 0 ..< _msgpackEntryCount {")
            lines.append("        switch try reader.readString() {")
            for field in decodable {
                lines.append("        case \(literal(field.key)):")
                lines.append(
                    "            _msgpack_\(field.name) = .some(try \(field.constructor!)(messagePack: &reader))"
                )
            }
            lines.append("        default:")
            lines.append("            try reader.skipValue()")
            lines.append("        }")
            lines.append("    }")
            for field in decodable {
                if let defaultValue = field.defaultValue {
                    lines.append(
                        "    self.`\(field.name)` = _msgpack_\(field.name) ?? (\(defaultValue))")
                } else if field.isOptional {
                    lines.append("    self.`\(field.name)` = _msgpack_\(field.name) ?? nil")
                } else {
                    lines.append("    if let value = _msgpack_\(field.name) {")
                    lines.append("        self.`\(field.name)` = value")
                    lines.append("    } else {")
                    lines.append(
                        "        throw MessagePackSwift.MessagePackError.missingField(\(literal(field.key)))"
                    )
                    lines.append("    }")
                }
            }
        }
        lines.append("}")
        return lines.map { "    \($0)" }.joined(separator: "\n")
    }

    /// Renders a Swift string literal for `string`, escaping as needed.
    private static func literal(_ string: String) -> String {
        String(reflecting: string)
    }

    private static func accessModifier(of structDecl: StructDeclSyntax) -> String {
        for modifier in structDecl.modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open):
                return "public "
            case .keyword(.package):
                return "package "
            default:
                continue
            }
        }
        return ""
    }

    /// Constrains each generic parameter that appears in a serialized field's
    /// type to `MessagePackSerializable`.
    private static func genericWhereClause(of structDecl: StructDeclSyntax, fields: [Field]) -> String {
        guard let parameters = structDecl.genericParameterClause?.parameters else { return "" }
        var constrained: [String] = []
        for parameter in parameters {
            let name = parameter.name.text
            let isUsed = fields.contains { field in
                guard let type = field.type else { return false }
                return type.tokens(viewMode: .sourceAccurate).contains {
                    $0.tokenKind == .identifier(name)
                }
            }
            if isUsed {
                constrained.append("\(name): MessagePackSwift.MessagePackSerializable")
            }
        }
        guard !constrained.isEmpty else { return "" }
        return " where " + constrained.joined(separator: ", ")
    }

    // MARK: Field collection

    /// Returns the stored properties to serialize, or nil after diagnosing an
    /// unsupported declaration.
    private static func collectFields(
        of structDecl: StructDeclSyntax, in context: some MacroExpansionContext
    ) -> [Field]? {
        var fields: [Field] = []
        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isExcluded = varDecl.modifiers.contains { modifier in
                switch modifier.name.tokenKind {
                case .keyword(.static), .keyword(.class), .keyword(.lazy):
                    return true
                default:
                    return false
                }
            }
            if isExcluded { continue }

            var ignored = false
            var customKey: String?
            for element in varDecl.attributes {
                guard let attribute = element.as(AttributeSyntax.self) else { continue }
                switch attribute.attributeName.trimmedDescription {
                case "MessagePackIgnored", "MessagePackSwift.MessagePackIgnored":
                    ignored = true
                case "MessagePackKey", "MessagePackSwift.MessagePackKey":
                    guard case .argumentList(let arguments) = attribute.arguments,
                        arguments.count == 1,
                        let literalExpr = arguments.first?.expression.as(StringLiteralExprSyntax.self),
                        literalExpr.segments.count == 1,
                        case .stringSegment(let segment)? = literalExpr.segments.first
                    else {
                        context.diagnose(
                            Diagnostic(
                                node: Syntax(attribute),
                                message: MessagePackMacroDiagnostic.invalidKeyArgument))
                        return nil
                    }
                    customKey = segment.content.text
                default:
                    break
                }
            }
            if ignored { continue }

            let isLet = varDecl.bindingSpecifier.tokenKind == .keyword(.let)

            // A type annotation covers preceding annotation-less,
            // initializer-less bindings (`var a, b: Int`), so walk backwards.
            var carriedType: TypeSyntax?
            var collected: [Field] = []
            for binding in varDecl.bindings.reversed() {
                let declaredType: TypeSyntax?
                if let annotation = binding.typeAnnotation {
                    declaredType = annotation.type
                    carriedType = annotation.type
                } else if binding.initializer != nil {
                    declaredType = nil  // inferred from the initializer
                } else {
                    declaredType = carriedType
                }

                if let accessorBlock = binding.accessorBlock {
                    switch accessorBlock.accessors {
                    case .getter:
                        continue  // computed
                    case .accessors(let list):
                        let isStored = list.allSatisfy { accessor in
                            switch accessor.accessorSpecifier.tokenKind {
                            case .keyword(.willSet), .keyword(.didSet):
                                return true
                            default:
                                return false
                            }
                        }
                        if !isStored { continue }  // computed
                    }
                }

                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    context.diagnose(
                        Diagnostic(
                            node: Syntax(binding),
                            message: MessagePackMacroDiagnostic.unsupportedPattern))
                    return nil
                }
                let name = String(pattern.identifier.text.filter { $0 != "`" })
                let defaultValue = binding.initializer?.value.trimmedDescription
                let isDecodable = !(isLet && defaultValue != nil)

                if isDecodable && declaredType == nil {
                    context.diagnose(
                        Diagnostic(
                            node: Syntax(binding),
                            message: MessagePackMacroDiagnostic.missingTypeAnnotation))
                    return nil
                }

                let wrapped = declaredType.flatMap(optionalWrappedType)
                let constructor: String?
                if let wrapped {
                    constructor = "Optional<\(wrapped.trimmed)>"
                } else {
                    constructor = declaredType.map { "\($0.trimmed)" }
                }
                collected.append(
                    Field(
                        name: name,
                        key: customKey ?? name,
                        type: declaredType,
                        constructor: constructor,
                        isOptional: wrapped != nil,
                        defaultValue: defaultValue,
                        isDecodable: isDecodable
                    ))
            }
            fields.append(contentsOf: collected.reversed())
        }
        return fields
    }

    /// The wrapped type if `type` is spelled as an optional
    /// (`T?`, `T!`, or `Optional<T>`), else nil.
    private static func optionalWrappedType(_ type: TypeSyntax) -> TypeSyntax? {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return optional.wrappedType
        }
        if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return unwrapped.wrappedType
        }
        if let identifier = type.as(IdentifierTypeSyntax.self),
            identifier.name.text == "Optional",
            let arguments = identifier.genericArgumentClause?.arguments,
            arguments.count == 1,
            let first = arguments.first,
            case .type(let wrapped) = first.argument
        {
            return wrapped
        }
        return nil
    }
}
