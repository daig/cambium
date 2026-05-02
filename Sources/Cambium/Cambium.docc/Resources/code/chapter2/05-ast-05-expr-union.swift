// CalculatorTypedAST.swift

import Cambium
import CambiumSyntaxMacros

// ... protocol, token wrapper, and per-kind structs from prior steps ...

/// Tagged union over the six expression kinds. The natural "what kind
/// of expression is this?" entry point — pattern matching on this
/// enum is what the evaluator and constant-folder dispatch on.
public enum ExprSyntax: Sendable, Hashable {
    case integer(IntegerExprSyntax)
    case real(RealExprSyntax)
    case unary(UnaryExprSyntax)
    case binary(BinaryExprSyntax)
    case group(GroupExprSyntax)
    case roundCall(RoundCallExprSyntax)

    public init?(_ syntax: SyntaxNodeHandle<CalculatorLanguage>) {
        switch CalculatorLanguage.kind(for: syntax.rawKind) {
        case .integerExpr: self = .integer(IntegerExprSyntax(unchecked: syntax))
        case .realExpr: self = .real(RealExprSyntax(unchecked: syntax))
        case .unaryExpr: self = .unary(UnaryExprSyntax(unchecked: syntax))
        case .binaryExpr: self = .binary(BinaryExprSyntax(unchecked: syntax))
        case .groupExpr: self = .group(GroupExprSyntax(unchecked: syntax))
        case .roundCallExpr: self = .roundCall(RoundCallExprSyntax(unchecked: syntax))
        default: return nil
        }
    }

    public var syntax: SyntaxNodeHandle<CalculatorLanguage> {
        switch self {
        case .integer(let expression): expression.syntax
        case .real(let expression): expression.syntax
        case .unary(let expression): expression.syntax
        case .binary(let expression): expression.syntax
        case .group(let expression): expression.syntax
        case .roundCall(let expression): expression.syntax
        }
    }

    public var range: TextRange { syntax.textRange }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .root)
public struct RootSyntax: CalculatorSyntaxNode {
    /// Every expression-shape direct child of the root, in source
    /// order. The Calculator grammar puts exactly one expression here
    /// for clean input, but the parser also emits zero or more under
    /// recovery — keep the accessor plural-shaped so consumers can
    /// gracefully report on whatever shape arrived.
    public var expressions: [ExprSyntax] {
        expressionChildren()
    }
}
