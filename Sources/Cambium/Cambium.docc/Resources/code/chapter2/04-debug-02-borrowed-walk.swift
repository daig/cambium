import Cambium

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
