// CalculatorTypedAST.swift
//
// Typed AST overlays on top of the green/red CST. This file demonstrates
// the **`CambiumASTSupport`** subsystem: pairing each significant node
// kind with a typed Swift struct that surfaces grammar-shaped accessors
// (lhs / rhs / operatorToken / argument / …).
//
// The `@CambiumSyntaxNode` macro generates the storage and the
// `init(unchecked:)` initializer; `CalculatorSyntaxNode` is a tiny
// language-specific protocol the macro plugs into. `ExprSyntax` is a
// hand-written tagged union over the six expression kinds, the natural
// "what kind of expression is this?" entry point for the evaluator and
// fold engine.
//
// Cambium APIs showcased here:
// - `TypedSyntaxNode` (the protocol the macro emits a conformance to)
// - `@CambiumSyntaxNode` (the macro)
// - `SyntaxNodeHandle` / `SyntaxTokenHandle` (the storage each typed node wraps)
// - `withCursor` (used to read kind/range/text from a handle)

import Cambium
import CambiumSyntaxMacros

/// Common protocol for the Calculator's typed AST node wrappers. Each
/// typed node is a value type whose only stored property is a
/// `SyntaxNodeHandle`; the typed accessors (lhs, rhs, operand, …) are
/// computed on demand by walking the underlying tree.
public protocol CalculatorSyntaxNode: TypedSyntaxNode, Sendable, Hashable
    where Lang == CalculatorLanguage
{
    /// The kind every node of this type must have.
    static var kind: CalculatorKind { get }

    /// The wrapped handle.
    var syntax: SyntaxNodeHandle<CalculatorLanguage> { get }

    /// Construct without checking the handle's kind. The
    /// `@CambiumSyntaxNode` macro emits this initializer; client code
    /// should prefer the failable `init(_:)` below.
    init(unchecked syntax: SyntaxNodeHandle<CalculatorLanguage>)
}

public extension CalculatorSyntaxNode {
    static var rawKind: RawSyntaxKind {
        CalculatorLanguage.rawKind(for: kind)
    }

    /// Failable down-cast: returns `nil` when `syntax`'s kind doesn't
    /// match `Self.kind`. This is the canonical entry point for
    /// constructing a typed wrapper from an arbitrary handle.
    init?(_ syntax: SyntaxNodeHandle<CalculatorLanguage>) {
        guard syntax.rawKind == Self.rawKind else {
            return nil
        }
        self.init(unchecked: syntax)
    }

    var range: TextRange {
        syntax.textRange
    }
}

/// Typed wrapper for a single token. Surfaces the token's kind, range,
/// and text without forcing callers to open a `withCursor` scope.
public struct CalculatorTokenSyntax: Sendable, Hashable {
    public let syntax: SyntaxTokenHandle<CalculatorLanguage>

    public init(_ syntax: SyntaxTokenHandle<CalculatorLanguage>) {
        self.syntax = syntax
    }

    public var kind: CalculatorKind {
        syntax.withCursor { token in
            token.kind
        }
    }

    public var range: TextRange {
        syntax.withCursor { token in
            token.textRange
        }
    }

    public var text: String {
        syntax.withCursor { token in
            token.makeString()
        }
    }

    /// Stream the token's UTF-8 bytes through `body` without allocating
    /// a `String`. Mirrors `SyntaxTokenCursor.withTextUTF8(_:)` so
    /// evaluators that parse from bytes (e.g. integer/real literal
    /// parsing) can avoid the `text` allocation.
    public func withTextUTF8<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) throws -> R {
        try syntax.withCursor { token in
            try token.withTextUTF8(body)
        }
    }
}

/// A binary-operator token paired with its decoded operator. Constructed
/// by `BinaryExprSyntax.operatorToken` after a successful kind match.
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

    public var range: TextRange {
        token.range
    }
}

/// The four binary operators in the Calculator grammar.
public enum CalculatorBinaryOperator: Sendable, Hashable, CustomStringConvertible {
    case add
    case subtract
    case multiply
    case divide

    public var description: String {
        switch self {
        case .add:
            "+"
        case .subtract:
            "-"
        case .multiply:
            "*"
        case .divide:
            "/"
        }
    }

    init?(_ kind: CalculatorKind) {
        switch kind {
        case .plus:
            self = .add
        case .minus:
            self = .subtract
        case .star:
            self = .multiply
        case .slash:
            self = .divide
        default:
            return nil
        }
    }
}

/// Tagged union over the six expression kinds. The evaluator and fold
/// engine pattern-match on this to dispatch — exactly the scenario the
/// typed-AST overlay layer is meant to support.
public enum ExprSyntax: Sendable, Hashable {
    case integer(IntegerExprSyntax)
    case real(RealExprSyntax)
    case unary(UnaryExprSyntax)
    case binary(BinaryExprSyntax)
    case group(GroupExprSyntax)
    case roundCall(RoundCallExprSyntax)

    public init?(_ syntax: SyntaxNodeHandle<CalculatorLanguage>) {
        switch CalculatorLanguage.kind(for: syntax.rawKind) {
        case .integerExpr:
            self = .integer(IntegerExprSyntax(unchecked: syntax))
        case .realExpr:
            self = .real(RealExprSyntax(unchecked: syntax))
        case .unaryExpr:
            self = .unary(UnaryExprSyntax(unchecked: syntax))
        case .binaryExpr:
            self = .binary(BinaryExprSyntax(unchecked: syntax))
        case .groupExpr:
            self = .group(GroupExprSyntax(unchecked: syntax))
        case .roundCallExpr:
            self = .roundCall(RoundCallExprSyntax(unchecked: syntax))
        default:
            return nil
        }
    }

    public var range: TextRange {
        switch self {
        case .integer(let expression):
            expression.range
        case .real(let expression):
            expression.range
        case .unary(let expression):
            expression.range
        case .binary(let expression):
            expression.range
        case .group(let expression):
            expression.range
        case .roundCall(let expression):
            expression.range
        }
    }

    public var syntax: SyntaxNodeHandle<CalculatorLanguage> {
        switch self {
        case .integer(let expression):
            expression.syntax
        case .real(let expression):
            expression.syntax
        case .unary(let expression):
            expression.syntax
        case .binary(let expression):
            expression.syntax
        case .group(let expression):
            expression.syntax
        case .roundCall(let expression):
            expression.syntax
        }
    }
}

// MARK: - Concrete typed nodes
//
// One struct per significant node kind. The `@CambiumSyntaxNode` macro
// emits the protocol conformance, the stored `syntax` property, the
// `kind` constant, and the `init(unchecked:)` initializer; only the
// hand-written body of each type matters for grammar shape.

@CambiumSyntaxNode(CalculatorKind.self, for: .root)
public struct RootSyntax: CalculatorSyntaxNode {
    public var expressions: [ExprSyntax] {
        expressionChildren()
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .integerExpr)
public struct IntegerExprSyntax: CalculatorSyntaxNode {
    public var literal: CalculatorTokenSyntax? {
        firstToken(kind: .number)
    }

    /// The leading `-` token when this literal carries a sign. `nil` for
    /// non-negative literals. The Calculator parser combines `-` with the
    /// immediately-following number token into a single `IntegerExpr`,
    /// rather than wrapping a positive literal in `UnaryExpr` — so the
    /// AST faithfully represents that `-3` is one number.
    public var minusSign: CalculatorTokenSyntax? {
        firstToken(kind: .minus)
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .realExpr)
public struct RealExprSyntax: CalculatorSyntaxNode {
    public var literal: CalculatorTokenSyntax? {
        firstToken(kind: .realNumber)
    }

    /// The leading `-` token when this literal carries a sign. `nil` for
    /// non-negative literals. See ``IntegerExprSyntax/minusSign`` for the
    /// rationale.
    public var minusSign: CalculatorTokenSyntax? {
        firstToken(kind: .minus)
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .unaryExpr)
public struct UnaryExprSyntax: CalculatorSyntaxNode {
    public var operand: ExprSyntax? {
        expression(at: 0)
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .binaryExpr)
public struct BinaryExprSyntax: CalculatorSyntaxNode {
    public var lhs: ExprSyntax? {
        expression(at: 0)
    }

    public var operatorToken: CalculatorBinaryOperatorTokenSyntax? {
        binaryOperatorToken()
    }

    public var rhs: ExprSyntax? {
        expression(at: 1)
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .groupExpr)
public struct GroupExprSyntax: CalculatorSyntaxNode {
    public var expression: ExprSyntax? {
        expression(at: 0)
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .roundCallExpr)
public struct RoundCallExprSyntax: CalculatorSyntaxNode {
    public var argument: ExprSyntax? {
        expression(at: 0)
    }
}

// MARK: - Shared traversal helpers

internal extension CalculatorSyntaxNode {
    /// All child nodes whose kind is an expression kind, in source order.
    /// Used by `expressions` (on `RootSyntax`) and indexed via
    /// `expression(at:)` for unary / binary / group / round-call slots.
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

    /// The `index`-th expression child, or `nil` for out-of-range.
    func expression(at index: Int) -> ExprSyntax? {
        let expressions = expressionChildren()
        guard index >= 0, index < expressions.count else {
            return nil
        }
        return expressions[index]
    }

    /// The first direct token child whose kind matches `kind`.
    func firstToken(kind: CalculatorKind) -> CalculatorTokenSyntax? {
        firstToken { $0 == kind }
    }

    /// The first binary-operator token among direct children, decoded
    /// into `CalculatorBinaryOperator`.
    func binaryOperatorToken() -> CalculatorBinaryOperatorTokenSyntax? {
        guard let token = firstToken(where: { CalculatorBinaryOperator($0) != nil }) else {
            return nil
        }
        return CalculatorBinaryOperatorTokenSyntax(token)
    }

    /// The byte range of the first `.missing` or `.error` direct child.
    /// Used by the evaluator to report parse-error positions.
    func firstInvalidChildRange() -> TextRange? {
        syntax.withCursor { node in
            var range: TextRange?
            node.forEachChild { child in
                if range == nil, child.kind == .missing || child.kind == .error {
                    range = child.textRange
                }
            }
            return range
        }
    }

    private func firstToken(where matches: (CalculatorKind) -> Bool) -> CalculatorTokenSyntax? {
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
