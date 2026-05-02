// CalculatorFold.swift

import Cambium

// ... `FoldStep` / `firstFoldCandidate` / `applyFold` from prior steps ...

/// Iteratively constant-fold `tree` until no foldable expression
/// remains. Returns a `FoldReport` whose `steps` records every
/// replacement applied in order.
public func foldCalculatorTree(
    _ tree: SharedSyntaxTree<CalculatorLanguage>,
    context: consuming GreenTreeContext<CalculatorLanguage>
) throws -> FoldReport {
    var currentTree = tree
    var steps: [FoldStep] = []
    var foldContext = context

    while let candidate = firstFoldCandidate(in: currentTree) {
        let output = try applyFold(
            candidate,
            in: currentTree,
            context: consume foldContext
        )
        let step = output.step
        // The replacement consumed our context and handed back a new
        // one bound to the same namespace. Reuse it for the next
        // splice so green-node sharing carries across the pass.
        foldContext = output.intoContext()
        currentTree = step.newTree
        steps.append(step)
    }

    return FoldReport(steps: steps, finalTree: currentTree)
}
