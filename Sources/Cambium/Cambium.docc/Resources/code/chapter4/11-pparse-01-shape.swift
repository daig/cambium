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
