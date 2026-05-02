// CalculatorValue.swift — domain types the evaluator returns

import Cambium

public enum CalculatorValue: Sendable, Equatable, CustomStringConvertible {
    case integer(Int64)
    case real(Double)

    public var description: String {
        switch self {
        case .integer(let value): "\(value)"
        case .real(let value): "\(value)"
        }
    }
}

internal extension CalculatorValue {
    var realValue: Double {
        switch self {
        case .integer(let value): Double(value)
        case .real(let value): value
        }
    }
}

public enum CalculatorEvaluationError: Error, Equatable, Sendable {
    case integerLiteralOutOfRange(String, TextRange)
    case realLiteralOutOfRange(String, TextRange)
    case divisionByZero(TextRange)
    case overflow(TextRange)
    case nonFiniteResult(TextRange)
    case roundedValueOutOfRange(Double, TextRange)
    case unsupportedSyntax(String, TextRange)
}
