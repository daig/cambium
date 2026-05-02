import Cambium

func mergeWorkerTrees(
    _ trees: [SharedSyntaxTree<CalculatorLanguage>],
    using interner: SharedTokenInterner
) throws -> SyntaxTree<CalculatorLanguage> {
    let context = GreenTreeContext<CalculatorLanguage>(
        interner: interner,
        policy: .documentLocal
    )
    var master = GreenTreeBuilder<CalculatorLanguage>(context: consume context)

    master.startNode(.root)
    for tree in trees {
        try tree.withRoot { rootCursor in
            let outcome = try master.reuseSubtree(rootCursor)
            assert(outcome == .direct)
        }
    }
    try master.finishNode()

    let build = try master.finish()
    return build.snapshot.makeSyntaxTree()
}
