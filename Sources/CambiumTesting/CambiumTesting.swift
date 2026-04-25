import CambiumCore

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
