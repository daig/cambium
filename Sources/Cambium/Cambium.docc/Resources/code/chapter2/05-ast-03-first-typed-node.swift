// CalculatorTypedAST.swift

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

/// Typed wrapper for a single token. Surfaces the token's kind, range,
/// and text without forcing callers to open a `withCursor` scope at
/// every read site.
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

/// `IntegerExprSyntax` wraps every node whose kind is `.integerExpr`.
///
/// The ``CambiumSyntaxMacros/CambiumSyntaxNode(_:for:)`` macro
/// generates the boilerplate: the `kind` constant, the stored `syntax`
/// handle, and the unchecked initializer the protocol requires. Only
/// the typed accessors are hand-written.
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

internal extension CalculatorSyntaxNode {
    /// First direct token child whose kind matches `kind`. The
    /// borrowed-cursor scope ensures iteration is allocation-free.
    func firstToken(kind: CalculatorKind) -> CalculatorTokenSyntax? {
        syntax.withCursor { node in
            var result: CalculatorTokenSyntax?
            node.forEachChildOrToken { element in
                switch element {
                case .token(let token) where result == nil && token.kind == kind:
                    result = CalculatorTokenSyntax(token.makeHandle())
                default:
                    break
                }
            }
            return result
        }
    }
}
