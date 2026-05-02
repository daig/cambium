// CalculatorSession.swift

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

        // Translate the prior cache through the parse witness BEFORE
        // we evict old-tree entries — entries whose paths landed
        // inside reused subtrees move to their new identities.
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

    /// Translate evaluation-cache entries from `previousTree` to
    /// `newTree` across an incremental reparse, using the
    /// ``CambiumIncremental/ParseWitness`` produced in Tutorial 8.
    ///
    /// For each reused subtree:
    ///
    ///   1. Walk every descendant of the OLD subtree by path.
    ///   2. Look up its cache entry by old `SyntaxNodeIdentity`.
    ///   3. If found, compute the corresponding NEW path (rewrite
    ///      the old prefix to the new prefix) and re-set the entry
    ///      under the new identity.
    ///
    /// After translation, evict any leftover entries whose `TreeID`
    /// no longer matches the current tree.
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
                    // `withDescendant(atPath:_:)` walks an absolute
                    // path from the root.
                    _ = oldRoot.withDescendant(atPath: reuse.oldPath) { oldReuseRoot in
                        oldReuseRoot.forEachDescendant(includingSelf: true) { oldNode in
                            let oldHandle = oldNode.makeHandle()
                            let oldKey = calculatorEvaluationCacheKey(
                                for: oldHandle.identity
                            )
                            guard let value = snapshot[oldKey] else { return }

                            // Translate path: drop the old subtree
                            // prefix, then prepend the new subtree
                            // prefix.
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

        // Bulk-evict entries from old tree versions. Any cached
        // value whose `TreeID` doesn't match `newTree.treeID` is now
        // unreachable — `removeValues(notMatching:)` is the
        // canonical garbage-collection step.
        evaluationCache.removeValues(notMatching: newTree.treeID)
    }
}
