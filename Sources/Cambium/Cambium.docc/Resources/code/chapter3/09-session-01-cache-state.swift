// CalculatorSession.swift

import Cambium

public final class CalculatorSession {
    private var context: GreenTreeContext<CalculatorLanguage>?
    private var lastTree: SharedSyntaxTree<CalculatorLanguage>?
    private var lastDiagnostics: [Diagnostic<CalculatorLanguage>] = []
    private var incremental = IncrementalParseSession<CalculatorLanguage>()

    // Long-lived analysis state. The cache must outlive every reparse
    // so memoized values can survive across edits; the metadata store
    // is replaced on each pass because evaluation order is per-pass-
    // relative.
    private let evaluationCache = ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>()
    private var evaluationMetadata = SyntaxMetadataStore<CalculatorLanguage>()

    public init() {}

    public var counters: IncrementalParseCounters {
        incremental.counters
    }

    public func parse(
        _ input: String,
        edits: [TextEdit] = []
    ) throws -> SharedSyntaxTree<CalculatorLanguage> {
        let previousTree = lastTree

        let builder: GreenTreeBuilder<CalculatorLanguage>
        if let existing = context.take() {
            builder = GreenTreeBuilder(context: consume existing)
        } else {
            builder = GreenTreeBuilder(policy: .parseSession(maxEntries: 16_384))
        }

        var parser = CalculatorParser(
            input: input,
            builder: consume builder,
            previousTree: previousTree,
            edits: edits,
            incremental: incremental
        )
        try parser.parse()
        let output = try parser.finishBuild()

        let tree = output.build.snapshot.makeSyntaxTree().intoShared()
        let nextContext = output.build.intoContext()

        context = consume nextContext
        lastTree = tree
        lastDiagnostics = output.diagnostics
        return tree
    }

    /// Evaluate the current tree, memoizing results in the long-lived
    /// `ExternalAnalysisCache` and recording per-node metadata in a
    /// fresh `SyntaxMetadataStore`.
    public func evaluate() throws -> CalculatorValue {
        guard let tree = lastTree else {
            throw CalculatorEvaluationError.invalidSyntax("no current document")
        }
        evaluationMetadata = SyntaxMetadataStore<CalculatorLanguage>()
        var evaluator = CalculatorEvaluator(
            cache: evaluationCache,
            metadata: evaluationMetadata
        )
        return try evaluator.evaluateTree(tree)
    }

    func makeParseWitness(
        previousTree: SharedSyntaxTree<CalculatorLanguage>?,
        newTree: SharedSyntaxTree<CalculatorLanguage>
    ) -> ParseWitness<CalculatorLanguage> {
        return ParseWitness(
            oldRoot: previousTree?.rootGreen,
            newRoot: newTree.rootGreen,
            reusedSubtrees: incremental.consumeAcceptedReuses()
        )
    }
}
