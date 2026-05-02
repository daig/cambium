// CalculatorEvaluator.swift

import Cambium

// ... entry point, evaluator skeleton, and literal evaluators from prior steps ...

internal extension CalculatorEvaluator {
    mutating func evaluateUnary(
        _ expression: UnaryExprSyntax
    ) throws -> CalculatorValue {
        guard let operand = expression.operand else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                "unary expression is missing an operand", expression.range
            )
        }
        switch try evaluate(operand) {
        case .integer(let value):
            // Negation of `Int64.min` overflows; we surface that as a
            // structured error rather than crashing.
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

    mutating func evaluateGroup(
        _ expression: GroupExprSyntax
    ) throws -> CalculatorValue {
        guard let nested = expression.expression else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                "group expression is missing an expression", expression.range
            )
        }
        return try evaluate(nested)
    }

    mutating func evaluateRoundCall(
        _ expression: RoundCallExprSyntax
    ) throws -> CalculatorValue {
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

    mutating func evaluateBinary(
        _ expression: BinaryExprSyntax
    ) throws -> CalculatorValue {
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

// `evaluateIntegerBinary` and `evaluateRealBinary` switch over
// `CalculatorBinaryOperator`, applying the corresponding stdlib
// reporting-overflow operation for integers, or the natural real
// operator with finiteness checks. Implementation omitted for brevity.
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
