import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct CambiumSyntaxNodeMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.as(StructDeclSyntax.self) != nil else {
            diagnose(
                context,
                node: node,
                id: "syntax-node-non-struct",
                message: "@CambiumSyntaxNode can only be attached to a struct"
            )
            return []
        }

        guard let arguments = parseSyntaxNodeArguments(node, context: context) else {
            return []
        }

        let access = declaration.generatedMemberAccess
        return [
            DeclSyntax(
                """
                \(raw: access)static let kind: \(raw: arguments.kindType) = \(arguments.kind)
                """
            ),
            DeclSyntax(
                """
                \(raw: access)let syntax: CambiumCore.SyntaxNodeHandle<Lang>
                """
            ),
            DeclSyntax(
                """
                \(raw: access)init(unchecked syntax: CambiumCore.SyntaxNodeHandle<Lang>) {
                    self.syntax = syntax
                }
                """
            ),
        ]
    }
}

private struct SyntaxNodeArguments {
    var kindType: String
    var kind: ExprSyntax
}

private func parseSyntaxNodeArguments(
    _ attribute: AttributeSyntax,
    context: some MacroExpansionContext
) -> SyntaxNodeArguments? {
    guard case .argumentList(let arguments) = attribute.arguments,
          arguments.count == 2,
          let kindTypeArgument = arguments.first,
          kindTypeArgument.label == nil,
          let kindArgument = arguments.dropFirst().first,
          kindArgument.label?.text == "for"
    else {
        diagnose(
            context,
            node: attribute,
            id: "syntax-node-invalid-arguments",
            message: "@CambiumSyntaxNode requires arguments '<Kind>.self, for: <kind>'"
        )
        return nil
    }

    let selfSuffix = ".self"
    let kindTypeExpression = kindTypeArgument.expression.cambiumTrimmedDescription
    guard kindTypeExpression.hasSuffix(selfSuffix) else {
        diagnose(
            context,
            node: kindTypeArgument.expression,
            id: "syntax-node-invalid-kind-type",
            message: "@CambiumSyntaxNode first argument must be a kind type, like CalculatorKind.self"
        )
        return nil
    }

    let end = kindTypeExpression.index(kindTypeExpression.endIndex, offsetBy: -selfSuffix.count)
    let kindType = String(kindTypeExpression[..<end])
    guard !kindType.isEmpty else {
        diagnose(
            context,
            node: kindTypeArgument.expression,
            id: "syntax-node-invalid-kind-type",
            message: "@CambiumSyntaxNode first argument must be a kind type, like CalculatorKind.self"
        )
        return nil
    }

    return SyntaxNodeArguments(kindType: kindType, kind: kindArgument.expression)
}

private struct CambiumSyntaxNodeMacroDiagnostic: DiagnosticMessage {
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
        message: CambiumSyntaxNodeMacroDiagnostic(id: id, message: message)
    ))
}

private extension DeclGroupSyntax {
    var generatedMemberAccess: String {
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
