// CalculatorParallelParser.swift

import Cambium

public struct ParallelParseReport: Sendable {
    /// One parsed tree per input expression, in input order.
    public let trees: [SharedSyntaxTree<CalculatorLanguage>]

    /// The interner that backed every worker. Holding this is what
    /// lets a downstream master builder splice each `trees[i]` via
    /// ``CambiumBuilder/GreenTreeBuilder/reuseSubtree(_:)`` on the
    /// ``CambiumBuilder/SubtreeReuseOutcome/direct`` fast path.
    public let interner: SharedTokenInterner

    /// Number of distinct interner keys used across all workers.
    /// Lower-than-`totalDynamicTokens` indicates dedup actually
    /// happened.
    public let internerKeySpaceUsed: Int
    public let totalDynamicTokens: Int
}

public func parseCalculatorExpressionsInParallel(
    _ expressions: [String],
    interner: SharedTokenInterner = SharedTokenInterner()
) async throws -> ParallelParseReport {
    let trees = try await withThrowingTaskGroup(
        of: (Int, SharedSyntaxTree<CalculatorLanguage>).self,
        returning: [SharedSyntaxTree<CalculatorLanguage>].self
    ) { group in
        for (index, source) in expressions.enumerated() {
            group.addTask {
                // Each worker gets its own `GreenTreeContext`, so
                // its `GreenNodeCache` is local — but the interner
                // is shared, so dynamic-token vocabulary is unified
                // from the moment of birth.
                let context = GreenTreeContext<CalculatorLanguage>(
                    interner: interner,
                    policy: .documentLocal
                )
                let builder = GreenTreeBuilder<CalculatorLanguage>(
                    context: consume context
                )
                var parser = CalculatorParser(
                    input: source,
                    builder: consume builder,
                    previousTree: nil,
                    edits: [],
                    incremental: nil
                )
                try parser.parse()
                let result = try parser.finish()
                return (index, result.tree)
            }
        }

        // Reassemble in input order. Task-group results arrive in
        // completion order, so we re-index by the original
        // position.
        var ordered = Array<SharedSyntaxTree<CalculatorLanguage>?>(
            repeating: nil, count: expressions.count
        )
        for try await (index, tree) in group {
            ordered[index] = tree
        }
        return ordered.compactMap { $0 }
    }

    return ParallelParseReport(
        trees: trees,
        interner: interner,
        internerKeySpaceUsed: countInternerKeyOccupancy(across: trees),
        totalDynamicTokens: trees.reduce(0) { $0 + countDynamicTokens(in: $1) }
    )
}

// Reporting helpers — walk each tree's green nodes via
// `node.child(at:)`, examine `token.textStorage`, and tally
// `.interned` vs `.staticText`. Implementations omitted for brevity.
private func countDynamicTokens(in tree: SharedSyntaxTree<CalculatorLanguage>) -> Int { 0 }
private func countInternerKeyOccupancy(across trees: [SharedSyntaxTree<CalculatorLanguage>]) -> Int { 0 }
