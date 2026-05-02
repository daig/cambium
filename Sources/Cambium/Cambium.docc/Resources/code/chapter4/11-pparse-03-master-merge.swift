// MasterMerge.swift
//
// Demonstrates merging worker trees into a top-level builder.
// The master is bound to the *same* `SharedTokenInterner`, so
// every `reuseSubtree(_:)` takes the `.direct` path.

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
            // Splice the worker's root node directly into the
            // master. Outcome is `.direct` because both contexts
            // share the same interner namespace — Cambium does no
            // remapping work at all.
            let outcome = try master.reuseSubtree(rootCursor)
            assert(outcome == .direct)
        }
    }
    try master.finishNode()

    let build = try master.finish()
    return build.snapshot.makeSyntaxTree()
}
