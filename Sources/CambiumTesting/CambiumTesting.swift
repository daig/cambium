import CambiumCore

/// Trap if `element`'s `GreenElement.textLength` is not exactly
/// `expected`. Test-support helper.
public func assertTextLength<Lang: SyntaxLanguage>(
    _ element: GreenElement<Lang>,
    equals expected: TextSize,
    file: StaticString = #file,
    line: UInt = #line
) {
    precondition(
        element.textLength == expected,
        "Expected text length \(expected.rawValue), got \(element.textLength.rawValue)",
        file: file,
        line: line
    )
}

/// Trap if rendering `tree`'s root text does not produce `expected`.
/// Test-support helper for confirming a parse round-trips losslessly.
public func assertRoundTrip<Lang: SyntaxLanguage>(
    _ tree: SharedSyntaxTree<Lang>,
    equals expected: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    let actual = tree.withRoot { root in
        root.makeString()
    }
    precondition(
        actual == expected,
        "Expected roundtrip text \(expected), got \(actual)",
        file: file,
        line: line
    )
}

/// Render `tree` as a multi-line indented string showing each node's kind
/// name and text range. Useful for tests, REPL exploration, and
/// debugging.
///
/// Tokens are not included in the output; for a token-aware view, walk
/// the tree directly with `SyntaxNodeCursor.walkPreorderWithTokens(_:)`.
public func debugTree<Lang: SyntaxLanguage>(_ tree: SharedSyntaxTree<Lang>) -> String {
    tree.withRoot { root in
        var lines: [String] = []
        func visit(_ node: borrowing SyntaxNodeCursor<Lang>, depth: Int) {
            lines.append("\(String(repeating: "  ", count: depth))\(Lang.name(for: node.kind)) \(node.textRange)")
            node.forEachChild { child in
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return lines.joined(separator: "\n")
    }
}
