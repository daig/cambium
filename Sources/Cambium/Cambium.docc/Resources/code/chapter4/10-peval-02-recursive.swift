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

private func evaluateInParallel(
    _ expression: ExprSyntax,
    cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>?,
    metadata: SyntaxMetadataStore<CalculatorLanguage>?,
    stats: ParallelEvalStatsBox
) async throws -> CalculatorValue {
    stats.enter()
    defer { stats.exit() }

    let handle = expression.syntax
    let key = calculatorEvaluationCacheKey(for: handle.identity)

    // Both stores serialize their own reads and writes via internal
    // mutexes, so cross-task lookups are safe without extra
    // synchronization.
    if let cached = cache?.value(for: key) {
        stats.recordCacheHit()
        return cached
    }

    let value: CalculatorValue
    switch expression {
    case .integer(let expression):
        value = try evaluateIntegerLiteral(expression)
    case .real(let expression):
        value = try evaluateRealLiteral(expression)
    case .binary(let expression):
        // The fork point. `async let` spawns a child task per
        // operand; we await both before combining. The compiler
        // enforces that any reference captured by an `async let`
        // body is `Sendable`, which is exactly why the typed AST
        // overlays were declared `Sendable`.
        guard let lhs = expression.lhs,
              let rhs = expression.rhs,
              let op = expression.operatorToken
        else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                "binary expression missing a child", expression.range
            )
        }
        stats.recordFork()
        async let leftValueAsync = evaluateInParallel(
            lhs, cache: cache, metadata: metadata, stats: stats
        )
        async let rightValueAsync = evaluateInParallel(
            rhs, cache: cache, metadata: metadata, stats: stats
        )
        let leftValue = try await leftValueAsync
        let rightValue = try await rightValueAsync
        value = try combine(leftValue, rightValue, op: op.operatorKind)

    case .unary, .group, .roundCall:
        // Sequential recursion is fine for single-operand kinds —
        // splitting into one async task adds overhead without
        // parallelism.
        value = try await sequentialRecurse(
            expression, cache: cache, metadata: metadata, stats: stats
        )
    }

    stats.recordEvaluation()
    cache?.set(value, for: key)
    return value
}

// Single-operand kinds, the literal evaluators (which use
// `withTextUTF8` from Tutorial 6), and the binary-operator combiner
// share the shape of their sequential counterparts. Stubs shown for
// brevity.
private func sequentialRecurse(
    _ expression: ExprSyntax,
    cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>?,
    metadata: SyntaxMetadataStore<CalculatorLanguage>?,
    stats: ParallelEvalStatsBox
) async throws -> CalculatorValue { fatalError() }

private func combine(
    _ lhs: CalculatorValue,
    _ rhs: CalculatorValue,
    op: CalculatorBinaryOperator
) throws -> CalculatorValue { fatalError() }

private func evaluateIntegerLiteral(_ expression: IntegerExprSyntax) throws -> CalculatorValue { fatalError() }
private func evaluateRealLiteral(_ expression: RealExprSyntax) throws -> CalculatorValue { fatalError() }
