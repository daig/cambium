import Cambium

let tree = try parseCalculator("(42)")

tree.withRoot { root in
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
