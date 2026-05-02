// CalculatorValue.swift
//
// Value, diagnostic, and error types produced by the Calculator's parser
// and evaluator. None of these types showcase Cambium APIs directly —
// they are the language's domain model. The Cambium types they hold
// (`TextRange`, `DiagnosticSeverity`, `Diagnostic`) appear in their
// public surface so consumers can talk about source positions and
// parser-emitted diagnostics in the language's own vocabulary.

import Cambium

/// The result of evaluating a calculator expression.
public enum CalculatorValue: Sendable, Equatable, CustomStringConvertible {
    case integer(Int64)
    case real(Double)

    public var description: String {
        switch self {
        case .integer(let value):
            "\(value)"
        case .real(let value):
            "\(value)"
        }
    }
}

/// Discriminator for ``CalculatorValue``. Used by the analysis sidecar
/// (`SyntaxMetadataStore`) to record which value kind an expression
/// node evaluated to without materializing the full value.
public enum CalculatorValueKind: String, Sendable, Equatable, CustomStringConvertible {
    case integer
    case real

    public var description: String {
        rawValue
    }
}

/// Counters surfaced by ``CalculatorSession`` after each `evaluate()`
/// call. `evalNodes` is the total expression-node visits the evaluator
/// made; `evalHits` is the subset that returned a memoized value from
/// the `ExternalAnalysisCache`.
public struct CalculatorEvaluationStats: Sendable, Equatable {
    public var evalNodes: UInt64
    public var evalHits: UInt64

    public init(evalNodes: UInt64 = 0, evalHits: UInt64 = 0) {
        self.evalNodes = evalNodes
        self.evalHits = evalHits
    }
}

/// A single entry surfaced by `CalculatorSession.cachedValues()`. Pairs
/// the byte range of an expression node with its memoized evaluation
/// result and the order it was first computed in. `parallelOrder`
/// reflects the most recent ``CalculatorSession/evaluateInParallel()``
/// pass, if any.
public struct CalculatorCachedValue: Sendable, Equatable {
    public let range: TextRange
    public let value: CalculatorValue
    public let evaluationOrder: Int?
    public let parallelOrder: Int?
    public let valueKind: CalculatorValueKind?

    public init(
        range: TextRange,
        value: CalculatorValue,
        evaluationOrder: Int?,
        parallelOrder: Int? = nil,
        valueKind: CalculatorValueKind?
    ) {
        self.range = range
        self.value = value
        self.evaluationOrder = evaluationOrder
        self.parallelOrder = parallelOrder
        self.valueKind = valueKind
    }
}

/// Errors produced by the evaluator. All cases carry the byte range of
/// the offending construct (or the expression that produced an out-of-range
/// result) so the REPL can echo the source position alongside the message.
public enum CalculatorEvaluationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSyntax(String)
    case integerLiteralOutOfRange(String, TextRange)
    case realLiteralOutOfRange(String, TextRange)
    case divisionByZero(TextRange)
    case overflow(TextRange)
    case nonFiniteResult(TextRange)
    case roundedValueOutOfRange(Double, TextRange)
    case unsupportedSyntax(String, TextRange)

    public var description: String {
        switch self {
        case .invalidSyntax(let message):
            message
        case .integerLiteralOutOfRange(let text, let range):
            "integer literal '\(text)' is outside Int64 range at \(format(range))"
        case .realLiteralOutOfRange(let text, let range):
            "real literal '\(text)' is outside Double range at \(format(range))"
        case .divisionByZero(let range):
            "division by zero at \(format(range))"
        case .overflow(let range):
            "arithmetic overflow at \(format(range))"
        case .nonFiniteResult(let range):
            "non-finite real result at \(format(range))"
        case .roundedValueOutOfRange(let value, let range):
            "rounded value '\(value)' is outside Int64 range at \(format(range))"
        case .unsupportedSyntax(let kind, let range):
            "unsupported syntax \(kind) at \(format(range))"
        }
    }
}

/// A parser-emitted diagnostic. Wraps Cambium's `Diagnostic<Lang>` with a
/// language-specific facade so consumers don't have to spell out the
/// generic parameter on every signature.
public struct CalculatorDiagnostic: Sendable, Hashable {
    public let range: TextRange
    public let message: String
    public let severity: DiagnosticSeverity

    public init(
        range: TextRange,
        message: String,
        severity: DiagnosticSeverity = .error
    ) {
        self.range = range
        self.message = message
        self.severity = severity
    }

    init(_ diagnostic: Diagnostic<CalculatorLanguage>) {
        self.range = diagnostic.range
        self.message = diagnostic.message
        self.severity = diagnostic.severity
    }
}

internal extension CalculatorValue {
    var kind: CalculatorValueKind {
        switch self {
        case .integer:
            .integer
        case .real:
            .real
        }
    }

    var realValue: Double {
        switch self {
        case .integer(let value):
            Double(value)
        case .real(let value):
            value
        }
    }
}
