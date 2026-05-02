// CalculatorEvaluator.swift
//
// Walks the typed AST and produces a `CalculatorValue`. The recursive
// dispatch on `ExprSyntax` is the typical shape for evaluators built on
// top of typed AST overlays.
//
// Cambium APIs showcased here:
// - `SyntaxNodeHandle` / `withCursor` (via the typed AST nodes)
// - `withTextUTF8` (literal parsing reads bytes directly without
//   allocating a `String` per token)
// - `ExternalAnalysisCache<Lang, Value>` keyed on `SyntaxNodeIdentity`
//   (memoize evaluation results across reparses; entries from old
//   `TreeID`s are evicted by the session)
// - `SyntaxMetadataStore<Lang>` keyed by `SyntaxDataKey<Value>` (record
//   per-node sidecar data — here, the order each node was first
//   evaluated in and which value kind it produced)

import Cambium

// MARK: - Public entry point

/// Evaluate a tree, throwing `CalculatorEvaluationError` if the tree
/// contains parse-error nodes or evaluates to an out-of-range value.
///
/// This is the no-cache variant — every call walks the whole tree fresh.
/// `CalculatorSession.evaluate()` uses the same evaluator with a cache
/// and metadata store attached so successive evaluations memoize.
public func evaluateCalculatorTree(
    _ tree: SharedSyntaxTree<CalculatorLanguage>
) throws -> CalculatorValue {
    var evaluator = CalculatorEvaluator()
    return try evaluator.evaluateTree(tree)
}

// MARK: - Analysis-cache keys
//
// These constants name the per-node analysis sidecar slots the
// evaluator writes into. They are `internal` (not `private`) so the
// session's witness-translation helpers can rebuild cache entries for
// reused subtrees by addressing the same slots in the new tree.

internal let calculatorEvaluationNamespace = "com.cambium.examples.calculator.eval"

internal let calculatorEvaluationOrderKey = SyntaxDataKey<Int>(
    "com.cambium.examples.calculator.eval.order"
)

internal let calculatorEvaluationKindKey = SyntaxDataKey<CalculatorValueKind>(
    "com.cambium.examples.calculator.eval.value-kind"
)

internal func calculatorEvaluationCacheKey(
    for identity: SyntaxNodeIdentity
) -> AnalysisCacheKey<CalculatorLanguage> {
    AnalysisCacheKey(identity: identity, namespace: calculatorEvaluationNamespace)
}

// MARK: - Evaluator

/// Recursive AST evaluator. `internal` rather than `private` so
/// `CalculatorSession.evaluate()` can construct one with cache +
/// metadata attached, and so the fold engine's predicate
/// (`foldValue(for:)` in `CalculatorFold.swift`) can call `evaluate(_:)`
/// on a cacheless instance.
internal struct CalculatorEvaluator {
    private let cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>?
    private let metadata: SyntaxMetadataStore<CalculatorLanguage>?
    private var evaluationOrder = 0
    private(set) var stats = CalculatorEvaluationStats()

    init(
        cache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>? = nil,
        metadata: SyntaxMetadataStore<CalculatorLanguage>? = nil
    ) {
        self.cache = cache
        self.metadata = metadata
    }

    mutating func evaluateTree(
        _ tree: SharedSyntaxTree<CalculatorLanguage>
    ) throws -> CalculatorValue {
        try tree.withRoot { root in
            guard let root = RootSyntax(root.makeHandle()) else {
                throw CalculatorEvaluationError.unsupportedSyntax(
                    CalculatorLanguage.name(for: root.kind),
                    root.textRange
                )
            }
            return try evaluateRoot(root)
        }
    }

    private mutating func evaluateRoot(_ root: RootSyntax) throws -> CalculatorValue {
        if let invalidRange = root.firstInvalidChildRange() {
            throw CalculatorEvaluationError.invalidSyntax("parse error node at \(format(invalidRange))")
        }

        let expressions = root.expressions
        guard expressions.count == 1 else {
            let message = expressions.isEmpty ? "expected expression" : "multiple root expressions"
            throw CalculatorEvaluationError.invalidSyntax("\(message) at \(format(root.range))")
        }
        return try evaluate(expressions[0])
    }

    /// Evaluate a single expression. The cache lookup happens here so
    /// every recursive call benefits from prior memoization within the
    /// same session.
    mutating func evaluate(_ expression: ExprSyntax) throws -> CalculatorValue {
        stats.evalNodes += 1
        let handle = expression.syntax
        let key = calculatorEvaluationCacheKey(for: handle.identity)

        if let cached = cache?.value(for: key) {
            stats.evalHits += 1
            recordMetadata(cached, on: handle)
            return cached
        }

        let value: CalculatorValue
        switch expression {
        case .integer(let expression):
            value = try evaluateInteger(expression)
        case .real(let expression):
            value = try evaluateReal(expression)
        case .unary(let expression):
            value = try evaluateUnary(expression)
        case .binary(let expression):
            value = try evaluateBinary(expression)
        case .group(let expression):
            value = try evaluateGroup(expression)
        case .roundCall(let expression):
            value = try evaluateRoundCall(expression)
        }

        cache?.set(value, for: key)
        recordMetadata(value, on: handle)
        return value
    }

    private mutating func recordMetadata(
        _ value: CalculatorValue,
        on handle: SyntaxNodeHandle<CalculatorLanguage>
    ) {
        guard let metadata else {
            return
        }
        evaluationOrder += 1
        metadata.set(evaluationOrder, for: calculatorEvaluationOrderKey, on: handle)
        metadata.set(value.kind, for: calculatorEvaluationKindKey, on: handle)
    }

    // MARK: - Per-kind dispatch

    /// Parse an integer literal directly from the token's UTF-8 bytes.
    /// Demonstrates `withTextUTF8` as the "no `String` allocation"
    /// alternative to `token.makeString()` — appropriate for hot-path
    /// evaluators that read literals frequently.
    private func evaluateInteger(_ expression: IntegerExprSyntax) throws -> CalculatorValue {
        guard let token = expression.literal else {
            throw CalculatorEvaluationError.unsupportedSyntax("missing integer literal", expression.range)
        }
        let parsed: Int64? = try token.withTextUTF8 { bytes in
            parseInt64(asciiDigits: bytes)
        }
        guard let value = parsed else {
            // Materialize the text only on the error path, since out-of-range
            // is rare and we want it in the diagnostic.
            throw CalculatorEvaluationError.integerLiteralOutOfRange(token.text, token.range)
        }
        return .integer(value)
    }

    /// Real literals fall back to `Double(_:)` because the stdlib has no
    /// from-bytes parser. We still avoid `token.makeString()` by going
    /// through `withTextUTF8` and decoding the slice we receive — the
    /// allocation is bounded to one literal's bytes, not the document.
    private func evaluateReal(_ expression: RealExprSyntax) throws -> CalculatorValue {
        guard let token = expression.literal else {
            throw CalculatorEvaluationError.unsupportedSyntax("missing real literal", expression.range)
        }
        let text = try token.withTextUTF8 { bytes in
            String(decoding: bytes, as: UTF8.self)
        }
        guard let value = Double(text), value.isFinite else {
            throw CalculatorEvaluationError.realLiteralOutOfRange(text, token.range)
        }
        return .real(value)
    }

    private mutating func evaluateUnary(_ expression: UnaryExprSyntax) throws -> CalculatorValue {
        guard let operand = expression.operand else {
            throw CalculatorEvaluationError.unsupportedSyntax("unary expression is missing an operand", expression.range)
        }

        switch try evaluate(operand) {
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

    private mutating func evaluateBinary(_ expression: BinaryExprSyntax) throws -> CalculatorValue {
        guard let lhs = expression.lhs else {
            throw CalculatorEvaluationError.unsupportedSyntax("binary expression is missing a left operand", expression.range)
        }
        guard let operatorToken = expression.operatorToken else {
            throw CalculatorEvaluationError.unsupportedSyntax("binary expression is missing an operator", expression.range)
        }
        guard let rhs = expression.rhs else {
            throw CalculatorEvaluationError.unsupportedSyntax("binary expression is missing a right operand", expression.range)
        }

        let leftValue = try evaluate(lhs)
        let rightValue = try evaluate(rhs)

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

    private mutating func evaluateGroup(_ expression: GroupExprSyntax) throws -> CalculatorValue {
        guard let nestedExpression = expression.expression else {
            throw CalculatorEvaluationError.unsupportedSyntax("group expression is missing an expression", expression.range)
        }
        return try evaluate(nestedExpression)
    }

    private mutating func evaluateRoundCall(_ expression: RoundCallExprSyntax) throws -> CalculatorValue {
        guard let argument = expression.argument else {
            throw CalculatorEvaluationError.unsupportedSyntax("round call is missing an argument", expression.range)
        }

        switch try evaluate(argument) {
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
}

// MARK: - Arithmetic helpers

internal func evaluateIntegerBinary(
    _ lhs: Int64,
    _ rhs: Int64,
    operatorKind: CalculatorBinaryOperator,
    operatorRange: TextRange
) throws -> CalculatorValue {
    let result: (partialValue: Int64, overflow: Bool)
    switch operatorKind {
    case .add:
        result = lhs.addingReportingOverflow(rhs)
    case .subtract:
        result = lhs.subtractingReportingOverflow(rhs)
    case .multiply:
        result = lhs.multipliedReportingOverflow(by: rhs)
    case .divide:
        guard rhs != 0 else {
            throw CalculatorEvaluationError.divisionByZero(operatorRange)
        }
        result = lhs.dividedReportingOverflow(by: rhs)
    }

    guard !result.overflow else {
        throw CalculatorEvaluationError.overflow(operatorRange)
    }
    return .integer(result.partialValue)
}

internal func evaluateRealBinary(
    _ lhs: Double,
    _ rhs: Double,
    operatorKind: CalculatorBinaryOperator,
    operatorRange: TextRange
) throws -> CalculatorValue {
    let result: Double
    switch operatorKind {
    case .add:
        result = lhs + rhs
    case .subtract:
        result = lhs - rhs
    case .multiply:
        result = lhs * rhs
    case .divide:
        guard rhs != 0 else {
            throw CalculatorEvaluationError.divisionByZero(operatorRange)
        }
        result = lhs / rhs
    }

    guard result.isFinite else {
        throw CalculatorEvaluationError.nonFiniteResult(operatorRange)
    }
    return .real(result)
}

/// Parse `bytes` as a base-10 ASCII unsigned integer. Returns `nil` on
/// any non-digit byte or on overflow. The lexer already rejected any
/// leading sign or non-digit; this is a hot-path digit accumulator.
internal func parseInt64(asciiDigits bytes: UnsafeBufferPointer<UInt8>) -> Int64? {
    guard !bytes.isEmpty else {
        return nil
    }
    var result: Int64 = 0
    for byte in bytes {
        guard byte >= 0x30, byte <= 0x39 else {
            return nil
        }
        let (afterMul, mulOverflow) = result.multipliedReportingOverflow(by: 10)
        guard !mulOverflow else {
            return nil
        }
        let (afterAdd, addOverflow) = afterMul.addingReportingOverflow(Int64(byte - 0x30))
        guard !addOverflow else {
            return nil
        }
        result = afterAdd
    }
    return result
}
