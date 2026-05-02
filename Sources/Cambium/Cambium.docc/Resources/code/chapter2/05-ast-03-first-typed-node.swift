// CalculatorTypedAST.swift

import Cambium
import CambiumSyntaxMacros

// ... `CalculatorSyntaxNode` and `CalculatorTokenSyntax` from prior steps ...

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
