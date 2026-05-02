import Cambium

func describeFoldStep(_ step: FoldStep) {
    print("folded \(step.oldText) -> \(step.newText)")
    print("  replaced path = \(step.replacedPath)")

    let cases: [SyntaxNodePath] = [
        [],                   // root
        step.replacedPath,    // the replaced node itself
    ]
    for path in cases {
        switch step.witness.classify(path: path) {
        case .unchanged:
            print("  classify(\(path)) = .unchanged")
        case .ancestor:
            print("  classify(\(path)) = .ancestor")
        case .replacedRoot(let newSubtree):
            print(
                "  classify(\(path)) = .replacedRoot",
                "(\(CalculatorLanguage.name(for: newSubtree.kind)))"
            )
        case .deleted:
            print("  classify(\(path)) = .deleted")
        }
    }
}
