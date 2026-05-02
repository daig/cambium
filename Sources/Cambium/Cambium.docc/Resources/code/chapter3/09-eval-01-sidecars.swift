import Cambium

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
    AnalysisCacheKey(
        identity: identity,
        namespace: calculatorEvaluationNamespace
    )
}
