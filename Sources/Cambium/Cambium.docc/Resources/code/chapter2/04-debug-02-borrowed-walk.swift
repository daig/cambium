// CalculatorDebugDump.swift

import Cambium

/// Render the full CST of `tree` with one indented line per node /
/// token. Demonstrates `withRoot` / `forEachChildOrToken`: the entry
/// point hands you a *borrowed* cursor on the root, and recursive
/// traversal happens through more borrows — no `Array` allocation, no
/// per-node retain/release.
public func calculatorDebugTree(
    _ tree: SharedSyntaxTree<CalculatorLanguage>
) -> String {
    tree.withRoot { root in
        var lines: [String] = []

        func visit(
            _ node: borrowing SyntaxNodeCursor<CalculatorLanguage>,
            depth: Int
        ) {
            lines.append(
                "\(indent(depth))\(CalculatorLanguage.name(for: node.kind)) \(format(node.textRange))"
            )
            // `forEachChildOrToken` interleaves nodes and tokens in
            // source order so trivia ends up between significant
            // children — the exact shape readers expect from a CST
            // dump.
            node.forEachChildOrToken { element in
                switch element {
                case .node(let child):
                    visit(child, depth: depth + 1)
                case .token(let token):
                    lines.append(
                        "\(indent(depth + 1))\(CalculatorLanguage.name(for: token.kind)) \(format(token.textRange)) \"\(token.makeString())\""
                    )
                }
            }
        }

        visit(root, depth: 0)
        return lines.joined(separator: "\n")
    }
}

private func indent(_ depth: Int) -> String {
    String(repeating: "  ", count: depth)
}

private func format(_ range: TextRange) -> String {
    "\(range.start.rawValue)..<\(range.end.rawValue)"
}
