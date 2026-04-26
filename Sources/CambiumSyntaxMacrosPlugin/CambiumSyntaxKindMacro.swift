import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct CambiumSyntaxKindMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            diagnose(
                context,
                node: node,
                id: "non-enum-target",
                message: "@CambiumSyntaxKind can only be attached to an enum"
            )
            return []
        }

        guard enumDecl.hasRawType(named: "UInt32") || enumDecl.hasRawType(named: "Swift.UInt32") else {
            diagnose(
                context,
                node: enumDecl.name,
                id: "invalid-raw-type",
                message: "@CambiumSyntaxKind requires an enum with raw type UInt32"
            )
            return []
        }

        let collection = collectCases(from: enumDecl, context: context)
        guard !collection.hasErrors else {
            return []
        }

        let access = enumDecl.generatedExtensionAccess
        let cases = collection.cases
        return [
            try ExtensionDeclSyntax("\(raw: access)extension \(type.trimmed): CambiumCore.SyntaxKind") {
                DeclSyntax(
                    """
                    static func rawKind(for kind: Self) -> CambiumCore.RawSyntaxKind {
                        CambiumCore.RawSyntaxKind(kind.rawValue)
                    }
                    """
                )
                DeclSyntax(
                    """
                    static func kind(for raw: CambiumCore.RawSyntaxKind) -> Self {
                        guard let kind = Self(rawValue: raw.rawValue) else {
                            preconditionFailure("Unknown raw syntax kind \\(raw.rawValue) for \(raw: type.cambiumTrimmedDescription)")
                        }
                        return kind
                    }
                    """
                )
                DeclSyntax(stringLiteral: staticTextFunction(cases: cases))
                DeclSyntax(stringLiteral: nameFunction(cases: cases))
            },
        ]
    }

    private static func collectCases(
        from enumDecl: EnumDeclSyntax,
        context: some MacroExpansionContext
    ) -> (cases: [SyntaxKindCase], hasErrors: Bool) {
        var result: [SyntaxKindCase] = []
        var rawValues: [UInt32: String] = [:]
        var hasErrors = false

        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else {
                continue
            }

            let staticText = staticTextLiteral(in: caseDecl.attributes)
            if staticText == .invalid {
                hasErrors = true
            }

            for element in caseDecl.elements {
                if element.parameterClause != nil {
                    diagnose(
                        context,
                        node: element.name,
                        id: "associated-values",
                        message: "@CambiumSyntaxKind cases cannot have associated values"
                    )
                    hasErrors = true
                }

                guard let rawValue = element.rawValue?.value else {
                    diagnose(
                        context,
                        node: element.name,
                        id: "missing-raw-value",
                        message: "@CambiumSyntaxKind cases must have explicit raw values"
                    )
                    hasErrors = true
                    continue
                }

                guard let parsedRawValue = parseUInt32Literal(rawValue) else {
                    diagnose(
                        context,
                        node: rawValue,
                        id: "non-literal-raw-value",
                        message: "@CambiumSyntaxKind raw values must be UInt32 integer literals"
                    )
                    hasErrors = true
                    continue
                }

                let name = element.name.text
                if let existingName = rawValues[parsedRawValue] {
                    diagnose(
                        context,
                        node: rawValue,
                        id: "duplicate-raw-value",
                        message: "duplicate raw value \(parsedRawValue) already used by case \(existingName)"
                    )
                    hasErrors = true
                    continue
                }

                rawValues[parsedRawValue] = name
                result.append(SyntaxKindCase(
                    reference: element.name.cambiumTrimmedDescription,
                    name: name,
                    staticText: staticText.literal
                ))
            }
        }

        return (result, hasErrors)
    }

    private static func staticTextFunction(cases: [SyntaxKindCase]) -> String {
        let staticCases = cases.compactMap { syntaxCase -> String? in
            guard let staticText = syntaxCase.staticText else {
                return nil
            }
            return """
                case .\(syntaxCase.reference):
                    \(staticText)
            """
        }

        guard !staticCases.isEmpty else {
            return """
            static func staticText(for kind: Self) -> StaticString? {
                nil
            }
            """
        }

        return """
        static func staticText(for kind: Self) -> StaticString? {
            switch kind {
        \(staticCases.joined(separator: "\n"))
            default:
                nil
            }
        }
        """
    }

    private static func nameFunction(cases: [SyntaxKindCase]) -> String {
        let caseBranches = cases
            .map { syntaxCase in
                """
                    case .\(syntaxCase.reference):
                        "\(syntaxCase.name)"
                """
            }
            .joined(separator: "\n")

        return """
        static func name(for kind: Self) -> String {
            switch kind {
        \(caseBranches)
            }
        }
        """
    }
}

public struct StaticTextMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if declaration.as(EnumCaseDeclSyntax.self) == nil {
            diagnose(
                context,
                node: node,
                id: "static-text-non-case",
                message: "@StaticText can only be attached to enum cases"
            )
        } else if staticTextLiteral(from: node) == nil {
            diagnose(
                context,
                node: node,
                id: "invalid-static-text",
                message: "@StaticText requires a single string literal argument"
            )
        }

        return []
    }
}

private struct SyntaxKindCase {
    var reference: String
    var name: String
    var staticText: String?
}

private enum StaticTextParseResult: Equatable {
    case absent
    case invalid
    case valid(String)

    var literal: String? {
        guard case .valid(let literal) = self else {
            return nil
        }
        return literal
    }
}

private struct CambiumSyntaxMacroDiagnostic: DiagnosticMessage {
    var id: String
    var message: String
    var severity: DiagnosticSeverity { .error }

    var diagnosticID: MessageID {
        MessageID(domain: "CambiumSyntaxMacros", id: id)
    }
}

private func diagnose(
    _ context: some MacroExpansionContext,
    node: some SyntaxProtocol,
    id: String,
    message: String
) {
    context.diagnose(Diagnostic(
        node: Syntax(node),
        message: CambiumSyntaxMacroDiagnostic(id: id, message: message)
    ))
}

private func staticTextLiteral(in attributes: AttributeListSyntax) -> StaticTextParseResult {
    var found = false
    var literal: String?

    for attributeElement in attributes {
        guard let attribute = attributeElement.as(AttributeSyntax.self),
              attribute.isStaticTextAttribute
        else {
            continue
        }

        found = true
        guard let parsed = staticTextLiteral(from: attribute) else {
            return .invalid
        }
        literal = parsed
    }

    if let literal {
        return .valid(literal)
    }
    return found ? .invalid : .absent
}

private func staticTextLiteral(from attribute: AttributeSyntax) -> String? {
    guard case .argumentList(let arguments) = attribute.arguments,
          arguments.count == 1,
          let argument = arguments.first,
          argument.label == nil,
          argument.trailingComma == nil,
          let literal = argument.expression.as(StringLiteralExprSyntax.self),
          literal.segments.allSatisfy({ $0.as(StringSegmentSyntax.self) != nil })
    else {
        return nil
    }

    return literal.cambiumTrimmedDescription
}

private func parseUInt32Literal(_ expression: ExprSyntax) -> UInt32? {
    var text = expression.cambiumTrimmedDescription
    text.removeAll(where: { $0 == "_" })

    let radix: Int
    let digits: Substring
    if text.hasPrefix("0x") || text.hasPrefix("0X") {
        radix = 16
        digits = text.dropFirst(2)
    } else if text.hasPrefix("0b") || text.hasPrefix("0B") {
        radix = 2
        digits = text.dropFirst(2)
    } else if text.hasPrefix("0o") || text.hasPrefix("0O") {
        radix = 8
        digits = text.dropFirst(2)
    } else {
        radix = 10
        digits = Substring(text)
    }

    guard !digits.isEmpty else {
        return nil
    }
    return UInt32(digits, radix: radix)
}

private extension AttributeSyntax {
    var isStaticTextAttribute: Bool {
        let name = attributeName.cambiumTrimmedDescription
        return name.split(separator: ".").last == "StaticText"
    }
}

private extension EnumDeclSyntax {
    func hasRawType(named rawTypeName: String) -> Bool {
        inheritanceClause?.inheritedTypes.contains { inheritedType in
            inheritedType.type.cambiumTrimmedDescription == rawTypeName
        } ?? false
    }

    var generatedExtensionAccess: String {
        for modifier in modifiers {
            switch modifier.name.text {
            case "public", "package":
                return "\(modifier.name.text) "
            default:
                continue
            }
        }
        return ""
    }
}

private extension SyntaxProtocol {
    var cambiumTrimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
