// CalculatorParallelEvaluator.swift

import Cambium
import Synchronization

/// Aggregate statistics from one parallel evaluation pass.
public struct ParallelEvaluationReport: Sendable, Equatable {
    public var nodeEvaluations: Int = 0
    public var cacheHits: Int = 0
    public var forkPoints: Int = 0
    public var maxObservedConcurrency: Int = 0
    public var elapsedNanos: UInt64 = 0
}

/// Evaluate `tree` using a structured-concurrent fork/join strategy.
public func evaluateCalculatorTreeInParallel(
    _ tree: SharedSyntaxTree<CalculatorLanguage>,
    cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>? = nil,
    metadata: SyntaxMetadataStore<CalculatorLanguage>? = nil
) async throws -> (value: CalculatorValue, report: ParallelEvaluationReport) {
    // Project the root through the typed AST exactly as the
    // sequential evaluator does. `SharedSyntaxTree.withRoot` is safe
    // to call from any task.
    let entry: ExprSyntax = try tree.withRoot { rootCursor in
        guard let root = RootSyntax(rootCursor.makeHandle()),
              let only = root.expressions.first,
              root.expressions.count == 1
        else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                "expected single root expression",
                rootCursor.textRange
            )
        }
        return only
    }

    let stats = ParallelEvalStatsBox()
    let value = try await evaluateInParallel(
        entry, cache: cache, metadata: metadata, stats: stats
    )
    return (value, stats.snapshot())
}
