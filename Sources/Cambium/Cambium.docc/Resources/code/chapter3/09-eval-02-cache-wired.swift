// CalculatorEvaluator.swift

import Cambium

internal struct CalculatorEvaluator {
    private let cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>?
    private let metadata: SyntaxMetadataStore<CalculatorLanguage>?
    private var evaluationOrder = 0

    init(
        cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>? = nil,
        metadata: SyntaxMetadataStore<CalculatorLanguage>? = nil
    ) {
        self.cache = cache
        self.metadata = metadata
    }

    /// Recursive expression entry. Cache lookup happens here, so
    /// every recursive call benefits from prior memoization within
    /// the same session.
    mutating func evaluate(_ expression: ExprSyntax) throws -> CalculatorValue {
        let handle = expression.syntax
        let key = calculatorEvaluationCacheKey(for: handle.identity)

        if let cached = cache?.value(for: key) {
            recordMetadata(cached, on: handle)
            return cached
        }

        let value: CalculatorValue
        switch expression {
        case .integer(let expression): value = try evaluateInteger(expression)
        case .real(let expression): value = try evaluateReal(expression)
        case .unary(let expression): value = try evaluateUnary(expression)
        case .binary(let expression): value = try evaluateBinary(expression)
        case .group(let expression): value = try evaluateGroup(expression)
        case .roundCall(let expression): value = try evaluateRoundCall(expression)
        }

        cache?.set(value, for: key)
        recordMetadata(value, on: handle)
        return value
    }

    /// Record per-evaluation sidecar data: the order this node was
    /// first visited, and the value kind it produced. The
    /// `SyntaxMetadataStore` serializes its own writes via an
    /// internal mutex, so multi-task evaluators can share a store
    /// without extra synchronization.
    private mutating func recordMetadata(
        _ value: CalculatorValue,
        on handle: SyntaxNodeHandle<CalculatorLanguage>
    ) {
        guard let metadata else { return }
        evaluationOrder += 1
        metadata.set(evaluationOrder, for: calculatorEvaluationOrderKey, on: handle)
        metadata.set(value.kind, for: calculatorEvaluationKindKey, on: handle)
    }

    // ... per-kind helpers from Chapter 2; bodies omitted for brevity ...
    private mutating func evaluateInteger(_ expression: IntegerExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateReal(_ expression: RealExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateUnary(_ expression: UnaryExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateBinary(_ expression: BinaryExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateGroup(_ expression: GroupExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateRoundCall(_ expression: RoundCallExprSyntax) throws -> CalculatorValue { fatalError() }
}
