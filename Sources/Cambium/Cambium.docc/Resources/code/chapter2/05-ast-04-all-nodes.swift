// CalculatorTypedAST.swift

import Cambium
import CambiumSyntaxMacros

// ... `CalculatorSyntaxNode` and `CalculatorTokenSyntax` from prior steps ...

public enum CalculatorBinaryOperator: Sendable, Hashable {
    case add, subtract, multiply, divide

    init?(_ kind: CalculatorKind) {
        switch kind {
        case .plus: self = .add
        case .minus: self = .subtract
        case .star: self = .multiply
        case .slash: self = .divide
        default: return nil
        }
    }
}

public struct CalculatorBinaryOperatorTokenSyntax: Sendable, Hashable {
    public let token: CalculatorTokenSyntax
    public let operatorKind: CalculatorBinaryOperator

    public init?(_ token: CalculatorTokenSyntax) {
        guard let operatorKind = CalculatorBinaryOperator(token.kind) else {
            return nil
        }
        self.token = token
        self.operatorKind = operatorKind
    }

    public var range: TextRange { token.range }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .integerExpr)
public struct IntegerExprSyntax: CalculatorSyntaxNode {
    public var literal: CalculatorTokenSyntax? { firstToken(kind: .number) }
    public var minusSign: CalculatorTokenSyntax? { firstToken(kind: .minus) }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .realExpr)
public struct RealExprSyntax: CalculatorSyntaxNode {
    public var literal: CalculatorTokenSyntax? { firstToken(kind: .realNumber) }
    public var minusSign: CalculatorTokenSyntax? { firstToken(kind: .minus) }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .unaryExpr)
public struct UnaryExprSyntax: CalculatorSyntaxNode {
    /// The operand expression. Resolved by walking the direct children
    /// in source order; the parser only emits one expression child.
    public var operand: ExprSyntax? { expression(at: 0) }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .binaryExpr)
public struct BinaryExprSyntax: CalculatorSyntaxNode {
    public var lhs: ExprSyntax? { expression(at: 0) }
    public var rhs: ExprSyntax? { expression(at: 1) }
    public var operatorToken: CalculatorBinaryOperatorTokenSyntax? {
        binaryOperatorToken()
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .groupExpr)
public struct GroupExprSyntax: CalculatorSyntaxNode {
    public var expression: ExprSyntax? { expression(at: 0) }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .roundCallExpr)
public struct RoundCallExprSyntax: CalculatorSyntaxNode {
    public var argument: ExprSyntax? { expression(at: 0) }
}

internal extension CalculatorSyntaxNode {
    /// Every direct expression-shape child in source order.
    func expressionChildren() -> [ExprSyntax] {
        syntax.withCursor { node in
            var expressions: [ExprSyntax] = []
            node.forEachChild { child in
                if let expression = ExprSyntax(child.makeHandle()) {
                    expressions.append(expression)
                }
            }
            return expressions
        }
    }

    /// Index into the expression children. `0` is the leftmost.
    func expression(at index: Int) -> ExprSyntax? {
        let expressions = expressionChildren()
        guard index >= 0, index < expressions.count else { return nil }
        return expressions[index]
    }

    /// First binary-operator token among direct children, paired with
    /// its decoded operator.
    func binaryOperatorToken() -> CalculatorBinaryOperatorTokenSyntax? {
        guard let token = firstToken(where: { CalculatorBinaryOperator($0) != nil }) else {
            return nil
        }
        return CalculatorBinaryOperatorTokenSyntax(token)
    }

    func firstToken(kind: CalculatorKind) -> CalculatorTokenSyntax? {
        firstToken(where: { $0 == kind })
    }

    private func firstToken(
        where matches: (CalculatorKind) -> Bool
    ) -> CalculatorTokenSyntax? {
        syntax.withCursor { node in
            var result: CalculatorTokenSyntax?
            node.forEachChildOrToken { element in
                switch element {
                case .token(let token) where result == nil && matches(token.kind):
                    result = CalculatorTokenSyntax(token.makeHandle())
                default:
                    break
                }
            }
            return result
        }
    }
}
