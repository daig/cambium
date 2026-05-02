// CalculatorSession.swift

import Cambium

extension CalculatorSession {
    // The session owns the long-lived `ExternalAnalysisCache` and a
    // per-pass `SyntaxMetadataStore`. The cache must outlive every
    // reparse so memoized values can survive across edits; the
    // metadata store is replaced on each pass because evaluation
    // order is per-pass-relative.

    func evaluate() throws -> CalculatorValue {
        guard let tree = lastTree else {
            throw CalculatorEvaluationError.invalidSyntax("no current document")
        }
        evaluationMetadata = SyntaxMetadataStore<CalculatorLanguage>()
        var evaluator = CalculatorEvaluator(
            cache: evaluationCache,
            metadata: evaluationMetadata
        )
        return try evaluator.evaluate(/* root expression of `tree` */)
    }
}

// Storage extension for the additional fields. In the production
// example these live alongside the other session state on the same
// class.
private var _evaluationCache = ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>()
private var _evaluationMetadata = SyntaxMetadataStore<CalculatorLanguage>()

extension CalculatorSession {
    var evaluationCache: ExternalAnalysisCache<CalculatorLanguage, CalculatorValue> {
        _evaluationCache
    }
    var evaluationMetadata: SyntaxMetadataStore<CalculatorLanguage> {
        get { _evaluationMetadata }
        set { _evaluationMetadata = newValue }
    }
}
