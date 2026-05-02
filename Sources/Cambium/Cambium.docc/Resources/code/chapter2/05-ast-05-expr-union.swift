import Cambium
import CambiumSyntaxMacros

public protocol CalculatorSyntaxNode: TypedSyntaxNode, Sendable, Hashable
    where Lang == CalculatorLanguage
{
    static var kind: CalculatorKind { get }
    var syntax: SyntaxNodeHandle<CalculatorLanguage> { get }
    init(unchecked syntax: SyntaxNodeHandle<CalculatorLanguage>)
}

public extension CalculatorSyntaxNode {
    static var rawKind: RawSyntaxKind {
        CalculatorLanguage.rawKind(for: kind)
    }

    init?(_ syntax: SyntaxNodeHandle<CalculatorLanguage>) {
        guard syntax.rawKind == Self.rawKind else { return nil }
        self.init(unchecked: syntax)
    }

    var range: TextRange {
        syntax.textRange
    }
}

public struct CalculatorTokenSyntax: Sendable, Hashable {
    public let syntax: SyntaxTokenHandle<CalculatorLanguage>

    public init(_ syntax: SyntaxTokenHandle<CalculatorLanguage>) {
        self.syntax = syntax
    }

    public var kind: CalculatorKind {
        syntax.withCursor { $0.kind }
    }

    public var range: TextRange {
        syntax.withCursor { $0.textRange }
    }

    public var text: String {
        syntax.withCursor { $0.makeString() }
    }

    public func withTextUTF8<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) throws -> R {
        try syntax.withCursor { token in
            try token.withTextUTF8(body)
        }
    }
}

/// The four binary operators in the Calculator grammar.
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
    /// The digit token that holds the literal's text.
    public var literal: CalculatorTokenSyntax? {
        firstToken(kind: .number)
    }

    /// The leading `-` when the literal carries a sign. `nil` for
    /// non-negative literals.
    public var minusSign: CalculatorTokenSyntax? {
        firstToken(kind: .minus)
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .realExpr)
public struct RealExprSyntax: CalculatorSyntaxNode {
    /// The digit-and-dot token that holds the literal's text.
    public var literal: CalculatorTokenSyntax? {
        firstToken(kind: .realNumber)
    }

    /// The leading `-` when the literal carries a sign. `nil` for
    /// non-negative literals.
    public var minusSign: CalculatorTokenSyntax? {
        firstToken(kind: .minus)
    }
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
    public var expressions: [ExprSyntax] {
        expressionChildren()
    }
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

    /// First direct token child whose kind matches `kind`. The
    /// borrowed-cursor scope ensures iteration is allocation-free.
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
