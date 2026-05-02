// CalculatorEvaluator.swift

import Cambium

/// Namespace for analysis cache keys belonging to the calculator
/// evaluator. The same key namespace must be used by every consumer
/// that wants to read these entries.
internal let calculatorEvaluationNamespace = "com.cambium.examples.calculator.eval"

/// `SyntaxDataKey<Value>` slots a typed payload into a
/// `SyntaxMetadataStore`. Equality is by string name, so namespace
/// the key strings to keep unrelated passes from colliding.
internal let calculatorEvaluationOrderKey = SyntaxDataKey<Int>(
    "com.cambium.examples.calculator.eval.order"
)
internal let calculatorEvaluationKindKey = SyntaxDataKey<CalculatorValueKind>(
    "com.cambium.examples.calculator.eval.value-kind"
)

/// Build the key the evaluator will use for a node's cached value.
/// Pairing the per-tree `SyntaxNodeIdentity` with a namespace lets a
/// single cache hold values from many passes without collision.
internal func calculatorEvaluationCacheKey(
    for identity: SyntaxNodeIdentity
) -> AnalysisCacheKey<CalculatorLanguage> {
    AnalysisCacheKey(
        identity: identity,
        namespace: calculatorEvaluationNamespace
    )
}

public func evaluateCalculatorTree(
    _ tree: SharedSyntaxTree<CalculatorLanguage>
) throws -> CalculatorValue {
    var evaluator = CalculatorEvaluator()
    return try evaluator.evaluateTree(tree)
}

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
            let expressions = root.expressions
            guard let only = expressions.first, expressions.count == 1 else {
                throw CalculatorEvaluationError.unsupportedSyntax(
                    "expected a single root expression",
                    root.range
                )
            }
            return try evaluate(only)
        }
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

    private mutating func evaluateInteger(_ expression: IntegerExprSyntax) throws -> CalculatorValue {
        guard let token = expression.literal else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                "missing integer literal", expression.range
            )
        }
        let parsed: Int64? = try token.withTextUTF8 { bytes in
            parseInt64(asciiDigits: bytes)
        }
        guard let value = parsed else {
            throw CalculatorEvaluationError.integerLiteralOutOfRange(
                token.text, token.range
            )
        }
        return .integer(expression.minusSign != nil ? -value : value)
    }

    private mutating func evaluateReal(_ expression: RealExprSyntax) throws -> CalculatorValue {
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
        return .real(expression.minusSign != nil ? -value : value)
    }

    private mutating func evaluateUnary(_ expression: UnaryExprSyntax) throws -> CalculatorValue {
        guard let operand = expression.operand else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                "unary expression is missing an operand", expression.range
            )
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

    private mutating func evaluateGroup(_ expression: GroupExprSyntax) throws -> CalculatorValue {
        guard let nested = expression.expression else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                "group expression is missing an expression", expression.range
            )
        }
        return try evaluate(nested)
    }

    private mutating func evaluateRoundCall(_ expression: RoundCallExprSyntax) throws -> CalculatorValue {
        guard let argument = expression.argument else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                "round call is missing an argument", expression.range
            )
        }
        switch try evaluate(argument) {
        case .integer(let value):
            return .integer(value)
        case .real(let value):
            let rounded = value.rounded(.toNearestOrAwayFromZero)
            guard rounded.isFinite, let integer = Int64(exactly: rounded) else {
                throw CalculatorEvaluationError.roundedValueOutOfRange(
                    rounded, expression.range
                )
            }
            return .integer(integer)
        }
    }

    private mutating func evaluateBinary(_ expression: BinaryExprSyntax) throws -> CalculatorValue {
        guard let lhs = expression.lhs,
              let rhs = expression.rhs,
              let operatorToken = expression.operatorToken
        else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                "binary expression is missing a child", expression.range
            )
        }

        let leftValue = try evaluate(lhs)
        let rightValue = try evaluate(rhs)

        switch (leftValue, rightValue) {
        case (.integer(let left), .integer(let right)):
            return try evaluateIntegerBinary(
                left, right,
                operatorKind: operatorToken.operatorKind,
                operatorRange: operatorToken.range
            )
        default:
            return try evaluateRealBinary(
                leftValue.realValue, rightValue.realValue,
                operatorKind: operatorToken.operatorKind,
                operatorRange: operatorToken.range
            )
        }
    }
}

internal func parseInt64(asciiDigits bytes: UnsafeBufferPointer<UInt8>) -> Int64? {
    guard !bytes.isEmpty else { return nil }
    var result: Int64 = 0
    for byte in bytes {
        guard byte >= 0x30, byte <= 0x39 else { return nil }
        let (afterMul, mulOverflow) = result.multipliedReportingOverflow(by: 10)
        guard !mulOverflow else { return nil }
        let (afterAdd, addOverflow) = afterMul.addingReportingOverflow(Int64(byte - 0x30))
        guard !addOverflow else { return nil }
        result = afterAdd
    }
    return result
}

internal func evaluateIntegerBinary(
    _ lhs: Int64, _ rhs: Int64,
    operatorKind: CalculatorBinaryOperator,
    operatorRange: TextRange
) throws -> CalculatorValue { fatalError() }

internal func evaluateRealBinary(
    _ lhs: Double, _ rhs: Double,
    operatorKind: CalculatorBinaryOperator,
    operatorRange: TextRange
) throws -> CalculatorValue { fatalError() }
