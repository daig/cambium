import Cambium

let tree = try parseCalculator("(42)")

tree.withRoot { root in
    // `makeString()` materializes the subtree's bytes by walking the
    // green tree on demand — round-trip first to confirm losslessness.
    print("source:", root.makeString())
    print("kind:  ", CalculatorLanguage.name(for: root.kind))
    print("range: ", root.textRange.start.rawValue, "..<", root.textRange.end.rawValue)

    root.forEachChildOrToken { element in
        switch element {
        case .node(let node):
            print(
                "node:",
                CalculatorLanguage.name(for: node.kind),
                node.textRange.start.rawValue,
                "..<",
                node.textRange.end.rawValue
            )
        case .token(let token):
            print(
                "token:",
                CalculatorLanguage.name(for: token.kind),
                "\"\(token.makeString())\""
            )
        }
    }
}
