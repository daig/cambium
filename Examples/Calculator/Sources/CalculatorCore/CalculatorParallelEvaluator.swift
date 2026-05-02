// CalculatorParallelEvaluator.swift
//
// Async fork/join evaluator: walks the typed AST and evaluates the LHS
// and RHS of every `BinaryExpr` concurrently via `async let`, sharing
// one `ExternalAnalysisCache` and one `SyntaxMetadataStore` across
// every task. End-to-end demonstration of Cambium's concurrency
// surface:
//
// - `SharedSyntaxTree` is `Sendable`; child tasks receive the same
//   tree and traverse it concurrently. The red layer realizes lazily
//   under lock-free atomic slots, so two child tasks descending into
//   different siblings of the same parent never observe inconsistent
//   state.
// - `ExprSyntax`, `SyntaxNodeHandle`, and the typed AST node structs
//   are `Sendable, Hashable`, so handing a sub-expression to a child
//   task is just an argument pass.
// - `ExternalAnalysisCache` and `SyntaxMetadataStore` serialize
//   concurrent reads and writes internally (mutex-protected), so the
//   same caches the sequential evaluator uses also work as the
//   parallel evaluator's per-task value memo and per-node sidecar.
// - The new `calculatorParallelTaskOrderKey` records each node's
//   completion order across all tasks via a shared atomic counter,
//   disjoint from the sequential evaluator's per-instance order key.
//
// Cambium APIs showcased here:
// - `SharedSyntaxTree.withRoot` (entry point) and the `Sendable` typed
//   AST overlay (`ExprSyntax`, `BinaryExprSyntax`, …).
// - `ExternalAnalysisCache` cross-task value memoization.
// - `SyntaxMetadataStore` cross-task sidecar writes via a new
//   `SyntaxDataKey<Int>`.
// - Structured concurrency (`async let`) layered onto a tree walk.

import Cambium
import Synchronization

// MARK: - Public entry point

/// Evaluate `tree` using a structured-concurrent fork/join strategy.
///
/// Each `BinaryExpr` evaluates its left and right operands concurrently
/// via `async let`. Every node read goes through `cache` if provided,
/// every node write records the completion order into `metadata` under
/// ``calculatorParallelTaskOrderKey``. Result-equivalent to
/// ``evaluateCalculatorTree(_:)`` — only the per-node completion order
/// in `metadata` reflects actual task scheduling.
public func evaluateCalculatorTreeInParallel(
    _ tree: SharedSyntaxTree<CalculatorLanguage>,
    cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>? = nil,
    metadata: SyntaxMetadataStore<CalculatorLanguage>? = nil
) async throws -> (value: CalculatorValue, report: ParallelEvaluationReport) {
    let entry: ExprSyntax = try tree.withRoot { rootCursor in
        guard let root = RootSyntax(rootCursor.makeHandle()) else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                CalculatorLanguage.name(for: rootCursor.kind),
                rootCursor.textRange
            )
        }
        if let invalidRange = root.firstInvalidChildRange() {
            throw CalculatorEvaluationError.invalidSyntax(
                "parse error node at \(format(invalidRange))"
            )
        }
        let expressions = root.expressions
        guard expressions.count == 1 else {
            let message = expressions.isEmpty
                ? "expected expression"
                : "multiple root expressions"
            throw CalculatorEvaluationError.invalidSyntax("\(message) at \(format(root.range))")
        }
        return expressions[0]
    }

    let stats = ParallelEvalStatsBox()
    let start = ContinuousClock.now
    let value = try await evaluateInParallel(
        entry,
        cache: cache,
        metadata: metadata,
        stats: stats
    )
    return (value, stats.snapshot(elapsedNanos: nanoseconds(since: start)))
}

// MARK: - Public report

/// Aggregate statistics from one parallel evaluation pass.
public struct ParallelEvaluationReport: Sendable, Equatable {
    /// Number of nodes whose value was computed (not served from
    /// cache) during this pass.
    public var nodeEvaluations: Int

    /// Number of nodes whose value was served from `cache`.
    public var cacheHits: Int

    /// Number of `BinaryExpr` fork sites encountered. One fork point
    /// corresponds to one `async let` LHS / `async let` RHS pair.
    public var forkPoints: Int

    /// Peak observed concurrent in-flight evaluator tasks. Includes
    /// suspended parents waiting on child tasks.
    public var maxObservedConcurrency: Int

    /// Wall-clock duration of the evaluation, in nanoseconds.
    public var elapsedNanos: UInt64

    public init(
        nodeEvaluations: Int = 0,
        cacheHits: Int = 0,
        forkPoints: Int = 0,
        maxObservedConcurrency: Int = 0,
        elapsedNanos: UInt64 = 0
    ) {
        self.nodeEvaluations = nodeEvaluations
        self.cacheHits = cacheHits
        self.forkPoints = forkPoints
        self.maxObservedConcurrency = maxObservedConcurrency
        self.elapsedNanos = elapsedNanos
    }
}

// MARK: - Sidecar key

/// Typed sidecar key for the per-node completion order recorded by the
/// parallel evaluator. Disjoint from ``calculatorEvaluationOrderKey``
/// so a tree evaluated both sequentially and in parallel can surface
/// both orderings via `cachedValues()`.
internal let calculatorParallelTaskOrderKey = SyntaxDataKey<Int>(
    "com.cambium.examples.calculator.peval.completion-order"
)

// MARK: - Recursive helper

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

    if let cached = cache?.value(for: key) {
        stats.recordCacheHit()
        record(cached, on: handle, metadata: metadata, stats: stats)
        return cached
    }

    let value: CalculatorValue
    switch expression {
    case .integer(let expression):
        value = try evaluateIntegerLiteral(expression)
    case .real(let expression):
        value = try evaluateRealLiteral(expression)
    case .unary(let expression):
        value = try await evaluateUnaryInParallel(
            expression,
            cache: cache,
            metadata: metadata,
            stats: stats
        )
    case .binary(let expression):
        value = try await evaluateBinaryInParallel(
            expression,
            cache: cache,
            metadata: metadata,
            stats: stats
        )
    case .group(let expression):
        value = try await evaluateGroupInParallel(
            expression,
            cache: cache,
            metadata: metadata,
            stats: stats
        )
    case .roundCall(let expression):
        value = try await evaluateRoundCallInParallel(
            expression,
            cache: cache,
            metadata: metadata,
            stats: stats
        )
    }

    stats.recordEvaluation()
    cache?.set(value, for: key)
    record(value, on: handle, metadata: metadata, stats: stats)
    return value
}

private func record(
    _ value: CalculatorValue,
    on handle: SyntaxNodeHandle<CalculatorLanguage>,
    metadata: SyntaxMetadataStore<CalculatorLanguage>?,
    stats: ParallelEvalStatsBox
) {
    guard let metadata else { return }
    let order = stats.nextCompletionOrder()
    metadata.set(order, for: calculatorParallelTaskOrderKey, on: handle)
    metadata.set(value.kind, for: calculatorEvaluationKindKey, on: handle)
}

// MARK: - Per-kind dispatch

private func evaluateIntegerLiteral(_ expression: IntegerExprSyntax) throws -> CalculatorValue {
    guard let token = expression.literal else {
        throw CalculatorEvaluationError.unsupportedSyntax(
            "missing integer literal", expression.range
        )
    }
    let parsed: Int64? = try token.withTextUTF8 { bytes in
        parseInt64(asciiDigits: bytes)
    }
    guard let value = parsed else {
        throw CalculatorEvaluationError.integerLiteralOutOfRange(token.text, token.range)
    }
    return .integer(value)
}

private func evaluateRealLiteral(_ expression: RealExprSyntax) throws -> CalculatorValue {
    guard let token = expression.literal else {
        throw CalculatorEvaluationError.unsupportedSyntax(
            "missing real literal", expression.range
        )
    }
    let text = try token.withTextUTF8 { bytes in
        String(decoding: bytes, as: UTF8.self)
    }
    guard let value = Double(text), value.isFinite else {
        throw CalculatorEvaluationError.realLiteralOutOfRange(text, token.range)
    }
    return .real(value)
}

private func evaluateUnaryInParallel(
    _ expression: UnaryExprSyntax,
    cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>?,
    metadata: SyntaxMetadataStore<CalculatorLanguage>?,
    stats: ParallelEvalStatsBox
) async throws -> CalculatorValue {
    guard let operand = expression.operand else {
        throw CalculatorEvaluationError.unsupportedSyntax(
            "unary expression is missing an operand", expression.range
        )
    }
    switch try await evaluateInParallel(
        operand,
        cache: cache,
        metadata: metadata,
        stats: stats
    ) {
    case .integer(let value):
        let result = Int64(0).subtractingReportingOverflow(value)
        guard !result.overflow else {
            throw CalculatorEvaluationError.overflow(expression.range)
        }
        return .integer(result.partialValue)
    case .real(let value):
        let result = -value
        guard result.isFinite else {
            throw CalculatorEvaluationError.nonFiniteResult(expression.range)
        }
        return .real(result)
    }
}

private func evaluateBinaryInParallel(
    _ expression: BinaryExprSyntax,
    cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>?,
    metadata: SyntaxMetadataStore<CalculatorLanguage>?,
    stats: ParallelEvalStatsBox
) async throws -> CalculatorValue {
    guard let lhs = expression.lhs else {
        throw CalculatorEvaluationError.unsupportedSyntax(
            "binary expression is missing a left operand", expression.range
        )
    }
    guard let operatorToken = expression.operatorToken else {
        throw CalculatorEvaluationError.unsupportedSyntax(
            "binary expression is missing an operator", expression.range
        )
    }
    guard let rhs = expression.rhs else {
        throw CalculatorEvaluationError.unsupportedSyntax(
            "binary expression is missing a right operand", expression.range
        )
    }

    stats.recordFork()
    async let leftValueAsync = evaluateInParallel(
        lhs,
        cache: cache,
        metadata: metadata,
        stats: stats
    )
    async let rightValueAsync = evaluateInParallel(
        rhs,
        cache: cache,
        metadata: metadata,
        stats: stats
    )
    let leftValue = try await leftValueAsync
    let rightValue = try await rightValueAsync

    switch (leftValue, rightValue) {
    case (.integer(let left), .integer(let right)):
        return try evaluateIntegerBinary(
            left,
            right,
            operatorKind: operatorToken.operatorKind,
            operatorRange: operatorToken.range
        )
    default:
        return try evaluateRealBinary(
            leftValue.realValue,
            rightValue.realValue,
            operatorKind: operatorToken.operatorKind,
            operatorRange: operatorToken.range
        )
    }
}

private func evaluateGroupInParallel(
    _ expression: GroupExprSyntax,
    cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>?,
    metadata: SyntaxMetadataStore<CalculatorLanguage>?,
    stats: ParallelEvalStatsBox
) async throws -> CalculatorValue {
    guard let nestedExpression = expression.expression else {
        throw CalculatorEvaluationError.unsupportedSyntax(
            "group expression is missing an expression", expression.range
        )
    }
    return try await evaluateInParallel(
        nestedExpression,
        cache: cache,
        metadata: metadata,
        stats: stats
    )
}

private func evaluateRoundCallInParallel(
    _ expression: RoundCallExprSyntax,
    cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>?,
    metadata: SyntaxMetadataStore<CalculatorLanguage>?,
    stats: ParallelEvalStatsBox
) async throws -> CalculatorValue {
    guard let argument = expression.argument else {
        throw CalculatorEvaluationError.unsupportedSyntax(
            "round call is missing an argument", expression.range
        )
    }
    switch try await evaluateInParallel(
        argument,
        cache: cache,
        metadata: metadata,
        stats: stats
    ) {
    case .integer(let value):
        return .integer(value)
    case .real(let value):
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        guard rounded.isFinite, let integer = Int64(exactly: rounded) else {
            throw CalculatorEvaluationError.roundedValueOutOfRange(rounded, expression.range)
        }
        return .integer(integer)
    }
}

// MARK: - Stats box

/// Mutex-protected box for parallel-evaluator stats. Mirrors the
/// thread-safe sidecar pattern used by `IncrementalParseSession` for
/// counter aggregation across concurrent workers.
internal final class ParallelEvalStatsBox: @unchecked Sendable {
    private struct State {
        var stats = ParallelEvaluationReport()
        var inFlight = 0
        var nextOrder = 0
    }

    private let storage = Mutex(State())

    func enter() {
        storage.withLock { state in
            state.inFlight += 1
            if state.inFlight > state.stats.maxObservedConcurrency {
                state.stats.maxObservedConcurrency = state.inFlight
            }
        }
    }

    func exit() {
        storage.withLock { state in
            state.inFlight -= 1
        }
    }

    func recordCacheHit() {
        storage.withLock { state in
            state.stats.cacheHits += 1
        }
    }

    func recordEvaluation() {
        storage.withLock { state in
            state.stats.nodeEvaluations += 1
        }
    }

    func recordFork() {
        storage.withLock { state in
            state.stats.forkPoints += 1
        }
    }

    func nextCompletionOrder() -> Int {
        storage.withLock { state in
            state.nextOrder += 1
            return state.nextOrder
        }
    }

    func snapshot(elapsedNanos: UInt64) -> ParallelEvaluationReport {
        storage.withLock { state in
            var report = state.stats
            report.elapsedNanos = elapsedNanos
            return report
        }
    }
}

// MARK: - Time

private func nanoseconds(since start: ContinuousClock.Instant) -> UInt64 {
    let elapsed = ContinuousClock.now - start
    let seconds = UInt64(max(elapsed.components.seconds, 0))
    let attoseconds = UInt64(max(elapsed.components.attoseconds, 0))
    return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
}
