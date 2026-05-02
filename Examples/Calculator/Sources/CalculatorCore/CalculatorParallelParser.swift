// CalculatorParallelParser.swift
//
// Parallel parsing: N expressions parsed concurrently via `async let`,
// every worker bound to one shared `SharedTokenInterner` so dynamic
// token text (number literal digits, whitespace) deduplicates across
// workers and downstream `reuseSubtree(_:)` from any worker tree into a
// master builder hits the `.direct` fast path.
//
// This is the canonical demonstration of the externalized-interner
// model: each worker owns its own `GreenTreeContext` (its own
// `GreenNodeCache`) but shares a single `TokenInterner`, so:
//
// - Token-text vocabulary is unified across workers from birth.
// - Two workers parsing "1 + 2" and "1 + 3" mint the same `TokenKey`
//   for the digit "1".
// - Splicing any worker tree into a master builder (also bound to the
//   shared interner) is a structural no-op: namespace identity matches,
//   so `reuseSubtree` takes `.direct`.
//
// Cambium APIs showcased here:
// - `SharedTokenInterner` as the externalized vocabulary.
// - `GreenTreeContext(interner:policy:)` per-worker.
// - `GreenTreeBuilder(context: consume context)` per-worker.
// - `GreenTreeBuilder(interner:)` for the master.
// - `reuseSubtree(_:)` cross-context with `.direct` outcome.

import Cambium

// MARK: - Public report

/// Result of one `parseCalculatorExpressionsInParallel(_:)` run.
public struct ParallelParseReport: Sendable {
    /// One parsed tree per input expression, in input order.
    public let trees: [SharedSyntaxTree<CalculatorLanguage>]

    /// The interner that backed every worker's parse. Holding this
    /// instance is what lets a downstream master builder splice each
    /// `trees[i]` via `reuseSubtree(_:)` on the `.direct` fast path.
    public let interner: SharedTokenInterner

    /// Number of distinct interner keys minted across all workers.
    /// Lower is better — a low number relative to total token count
    /// signals that vocabulary deduplicated across workers, which is
    /// the entire point of sharing the interner.
    public let internerKeySpaceUsed: Int

    /// Sum of dynamic-text tokens across every parsed tree. Compare
    /// against `internerKeySpaceUsed` to see the dedup ratio.
    public let totalDynamicTokens: Int
}

/// Parse `expressions` concurrently. Every worker uses the supplied
/// `interner` (or a fresh one if none is given), so token vocabulary
/// is unified across the worker pool. Returns the parsed trees plus a
/// report enabling cross-worker subtree splicing via `reuseSubtree`.
///
/// Each worker constructs a `GreenTreeContext(interner: shared, ...)`
/// — distinct green-node caches per worker (cross-cache structural
/// dedup is `SharedGreenNodeCache`'s domain, not exercised here) but a
/// shared token namespace. After this returns, calling
/// `masterBuilder.reuseSubtree(workerTree.root)` on a master built
/// against the same `interner` will take the `.direct` fast path for
/// every worker tree — no remapping cost.
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

        var ordered = Array<SharedSyntaxTree<CalculatorLanguage>?>(
            repeating: nil,
            count: expressions.count
        )
        for try await (index, tree) in group {
            ordered[index] = tree
        }
        return ordered.compactMap { $0 }
    }

    let totalDynamicTokens = trees.reduce(0) { running, tree in
        running + countDynamicTokens(in: tree)
    }
    let internerKeySpaceUsed = countInternerKeyOccupancy(
        across: trees,
        interner: interner
    )

    return ParallelParseReport(
        trees: trees,
        interner: interner,
        internerKeySpaceUsed: internerKeySpaceUsed,
        totalDynamicTokens: totalDynamicTokens
    )
}

// MARK: - Reporting helpers

private func countDynamicTokens(
    in tree: SharedSyntaxTree<CalculatorLanguage>
) -> Int {
    var count = 0
    walkGreenTokens(in: tree.rootGreen) { token in
        switch token.textStorage {
        case .interned, .ownedLargeText:
            count += 1
        case .staticText, .missing:
            break
        }
    }
    return count
}

private func countInternerKeyOccupancy(
    across trees: [SharedSyntaxTree<CalculatorLanguage>],
    interner _: SharedTokenInterner
) -> Int {
    var seen: Set<UInt32> = []
    for tree in trees {
        walkGreenTokens(in: tree.rootGreen) { token in
            if case .interned(let key) = token.textStorage {
                seen.insert(key.rawValue)
            }
        }
    }
    return seen.count
}

private func walkGreenTokens(
    in node: GreenNode<CalculatorLanguage>,
    visit: (GreenToken<CalculatorLanguage>) -> Void
) {
    for childIndex in 0..<node.childCount {
        switch node.child(at: childIndex) {
        case .node(let child):
            walkGreenTokens(in: child, visit: visit)
        case .token(let token):
            visit(token)
        }
    }
}
