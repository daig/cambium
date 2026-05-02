// CalculatorDebugDump.swift
//
// Pretty-printers for trees and the typed AST overlay. The CST printer
// (`calculatorDebugTree`) walks elements with `forEachChildOrToken` so
// trivia tokens appear inline with structural children — exactly the
// shape readers expect from a cstree dump. The typed-AST printer walks
// `ExprSyntax` recursively so consumers can see the same data through
// the typed overlay's lens.
//
// Cambium APIs showcased here:
// - `SharedSyntaxTree.withRoot(_:)` and `SyntaxNodeCursor.forEachChildOrToken(_:)`
//   for the CST walk.
// - `SyntaxNodeHandle.makeHandle()` (via `ExprSyntax.init`) for the
//   typed-AST recursion.

import Cambium

/// Render the full CST of `tree`, including token leaves, with indented
/// `kind range "text"` lines.
public func calculatorDebugTree(_ tree: SharedSyntaxTree<CalculatorLanguage>) -> String {
    tree.withRoot { root in
        var lines: [String] = []

        func visit(_ node: borrowing SyntaxNodeCursor<CalculatorLanguage>, depth: Int) {
            lines.append("\(indent(depth))\(CalculatorLanguage.name(for: node.kind)) \(format(node.textRange))")
            node.forEachChildOrToken { element in
                switch element {
                case .node(let child):
                    visit(child, depth: depth + 1)
                case .token(let token):
                    lines.append(
                        "\(indent(depth + 1))\(CalculatorLanguage.name(for: token.kind)) \(format(token.textRange)) \"\(escaped(token.makeString()))\""
                    )
                }
            }
        }

        visit(root, depth: 0)
        return lines.joined(separator: "\n")
    }
}

/// Render the typed AST overlay for a parse result, falling back to a
/// diagnostic dump when the parser emitted any.
public func calculatorDebugTypedAST(_ result: CalculatorParseResult) -> String {
    guard result.diagnostics.isEmpty else {
        return result.diagnostics.map(formatDiagnostic).joined(separator: "\n")
    }
    return calculatorDebugTypedAST(result.tree)
}

/// Render the typed AST overlay for a tree. Skips trivia and tokens —
/// only the typed expression node names are surfaced.
public func calculatorDebugTypedAST(_ tree: SharedSyntaxTree<CalculatorLanguage>) -> String {
    tree.withRoot { root in
        guard let root = RootSyntax(root.makeHandle()) else {
            return "unsupported syntax \(CalculatorLanguage.name(for: root.kind)) at \(format(root.textRange))"
        }

        var lines: [String] = []
        lines.append("RootSyntax \(format(root.range))")

        for expression in root.expressions {
            appendTypedOverlayDebug(expression, depth: 1, lines: &lines)
        }
        return lines.joined(separator: "\n")
    }
}

private func appendTypedOverlayDebug(
    _ expression: ExprSyntax,
    depth: Int,
    lines: inout [String]
) {
    lines.append("\(indent(depth))\(expression.debugLabel) \(format(expression.range))")
    for child in expression.children {
        appendTypedOverlayDebug(child, depth: depth + 1, lines: &lines)
    }
}

private extension ExprSyntax {
    var debugLabel: String {
        switch self {
        case .integer:
            "IntegerExprSyntax"
        case .real:
            "RealExprSyntax"
        case .unary:
            "UnaryExprSyntax"
        case .binary:
            "BinaryExprSyntax"
        case .group:
            "GroupExprSyntax"
        case .roundCall:
            "RoundCallExprSyntax"
        }
    }

    var children: [ExprSyntax] {
        switch self {
        case .integer, .real:
            []
        case .unary(let expression):
            expression.operand.map { [$0] } ?? []
        case .binary(let expression):
            [expression.lhs, expression.rhs].compactMap { $0 }
        case .group(let expression):
            expression.expression.map { [$0] } ?? []
        case .roundCall(let expression):
            expression.argument.map { [$0] } ?? []
        }
    }
}

private func indent(_ depth: Int) -> String {
    String(repeating: "  ", count: depth)
}

private func escaped(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\n":
            result += "\\n"
        case "\r":
            result += "\\r"
        case "\t":
            result += "\\t"
        case "\"":
            result += "\\\""
        case "\\":
            result += "\\\\"
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}
