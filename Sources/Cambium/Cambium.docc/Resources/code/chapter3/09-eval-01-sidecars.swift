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
