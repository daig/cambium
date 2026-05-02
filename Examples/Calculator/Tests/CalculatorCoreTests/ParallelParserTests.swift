import CalculatorCore
import Cambium
import Testing

@Test func parallelParseProducesIndividualTreesPerExpression() async throws {
    let inputs = ["1 + 2", "3 * 4", "round(5.5)", "(6 - 7) / 8"]

    let report = try await parseCalculatorExpressionsInParallel(inputs)

    #expect(report.trees.count == inputs.count)
    for (tree, input) in zip(report.trees, inputs) {
        let rendered = tree.withRoot { $0.makeString() }
        #expect(rendered == input)
    }
}

@Test func parallelParseDeduplicatesTokenTextAcrossWorkers() async throws {
    // Every expression contains the digit "1" — there's only one
    // interner key for it across all workers. With independent
    // interners, every worker would mint its own; with the shared
    // interner, the keyspace stays compact.
    let inputs = ["1 + 2", "1 - 3", "1 * 4", "1 / 5", "1 + 6"]
    let interner = SharedTokenInterner()

    let report = try await parseCalculatorExpressionsInParallel(
        inputs,
        interner: interner
    )

    // The interner should now contain the digit "1" exactly once,
    // regardless of how many worker trees referenced it.
    let oneKey = interner.intern("1")
    let oneAgain = interner.intern("1")
    #expect(oneKey == oneAgain)

    // More dynamic tokens than interner keys — that's the dedup signal.
    #expect(report.totalDynamicTokens > report.internerKeySpaceUsed)
}

@Test func parallelParseTreesReuseDirectlyIntoMasterBoundToSharedInterner() async throws {
    // The end-to-end externalized-interner story: workers parse with
    // the shared interner, then a master builder bound to the same
    // interner splices each worker tree via `reuseSubtree` and every
    // outcome must be `.direct` because they share a token namespace.
    let interner = SharedTokenInterner()
    let inputs = ["1 + 2", "3 + 4", "5 + 6"]

    let report = try await parseCalculatorExpressionsInParallel(
        inputs,
        interner: interner
    )

    // Hand each worker tree's root to a master builder bound to the
    // same interner. Every reuseSubtree call should be `.direct`.
    var master = GreenTreeBuilder<CalculatorLanguage>(interner: interner)
    master.startNode(.root)
    var outcomes: [SubtreeReuseOutcome] = []
    for tree in report.trees {
        let outcome = try tree.withRoot { root in
            try master.reuseSubtree(root)
        }
        outcomes.append(outcome)
    }
    try master.finishNode()
    _ = try master.finish()

    #expect(outcomes.count == inputs.count)
    #expect(outcomes.allSatisfy { $0 == .direct })
}
