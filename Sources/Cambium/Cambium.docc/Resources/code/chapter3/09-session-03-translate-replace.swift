import Cambium

public final class CalculatorSession {
    private var context: GreenTreeContext<CalculatorLanguage>?
    private var lastTree: SharedSyntaxTree<CalculatorLanguage>?
    private var lastDiagnostics: [Diagnostic<CalculatorLanguage>] = []
    private var incremental = IncrementalParseSession<CalculatorLanguage>()

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

        let witness = makeParseWitness(previousTree: previousTree, newTree: tree)
        if let previousTree {
            translateEvaluationCache(
                from: previousTree,
                to: tree,
                witness: witness
            )
        }

        context = consume nextContext
        lastTree = tree
        lastDiagnostics = output.diagnostics
        return tree
    }

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

    func translateEvaluationCache(
        from previousTree: SharedSyntaxTree<CalculatorLanguage>,
        to newTree: SharedSyntaxTree<CalculatorLanguage>,
        witness: ParseWitness<CalculatorLanguage>
    ) {
        guard !witness.reusedSubtrees.isEmpty else { return }
        let snapshot = evaluationCache.snapshot()
        guard !snapshot.isEmpty else { return }

        previousTree.withRoot { oldRoot in
            newTree.withRoot { newRoot in
                for reuse in witness.reusedSubtrees {
                    _ = oldRoot.withDescendant(atPath: reuse.oldPath) { oldReuseRoot in
                        oldReuseRoot.forEachDescendant(includingSelf: true) { oldNode in
                            let oldHandle = oldNode.makeHandle()
                            let oldKey = calculatorEvaluationCacheKey(
                                for: oldHandle.identity
                            )
                            guard let value = snapshot[oldKey] else { return }

                            let fullOldPath = oldNode.childIndexPath()
                            let relativePath = SyntaxNodePath(
                                fullOldPath.dropFirst(reuse.oldPath.count)
                            )
                            let newPath = reuse.newPath + relativePath
                            _ = newRoot.withDescendant(atPath: newPath) { newNode in
                                let newKey = calculatorEvaluationCacheKey(
                                    for: newNode.identity
                                )
                                evaluationCache.set(value, for: newKey)
                            }
                        }
                    }
                }
            }
        }

        evaluationCache.removeValues(notMatching: newTree.treeID)
    }

    func translateEvaluationCache(
        from previousTree: SharedSyntaxTree<CalculatorLanguage>,
        to newTree: SharedSyntaxTree<CalculatorLanguage>,
        witness: ReplacementWitness<CalculatorLanguage>,
        replacementValue: CalculatorValue
    ) {
        let snapshot = evaluationCache.snapshot()
        previousTree.withRoot { oldRoot in
            newTree.withRoot { newRoot in
                if !snapshot.isEmpty {
                    oldRoot.forEachDescendant(includingSelf: true) { oldNode in
                        let oldHandle = oldNode.makeHandle()
                        guard ExprSyntax(oldHandle) != nil else { return }

                        let oldKey = calculatorEvaluationCacheKey(for: oldHandle.identity)
                        guard let value = snapshot[oldKey] else { return }

                        let path = oldNode.childIndexPath()
                        guard case .unchanged = witness.classify(path: path) else {
                            return
                        }
                        _ = newRoot.withDescendant(atPath: path) { newNode in
                            let newKey = calculatorEvaluationCacheKey(
                                for: newNode.makeHandle().identity
                            )
                            evaluationCache.set(value, for: newKey)
                        }
                    }
                }

                _ = newRoot.withDescendant(atPath: witness.replacedPath) { node in
                    let key = calculatorEvaluationCacheKey(
                        for: node.makeHandle().identity
                    )
                    evaluationCache.set(replacementValue, for: key)
                }
            }
        }
        evaluationCache.removeValues(notMatching: newTree.treeID)
    }
}
