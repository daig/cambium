// CalculatorSession.swift
//
// Long-lived parsing context. Owns three independent caches and threads
// them through every parse:
//
//   1. `cache` — a `GreenNodeCache<CalculatorLanguage>` forwarded across
//      reparses via `GreenBuildResult.intoCache()`. Preserves green-node
//      structural sharing and keeps the token-key namespace stable so
//      `GreenTreeBuilder.reuseSubtree(_:)` can hit the `.direct` path.
//
//   2. `incremental` — an `IncrementalParseSession<CalculatorLanguage>`
//      that aggregates `IncrementalParseCounters` across parses and
//      records the `Reuse<Lang>` log used to build a `ParseWitness`.
//
//   3. `evaluationCache` + `evaluationMetadata` — `ExternalAnalysisCache`
//      and `SyntaxMetadataStore` keyed on `SyntaxNodeIdentity`. Memoize
//      evaluation results across reparses; entries from old `TreeID`s
//      are evicted, and entries surviving in reused subtrees get
//      translated to the new tree's node identities via the witness.
//
// The witness translation is what the per-node analysis cache needs to
// be useful at all: without it, every reparse would invalidate every
// memoized evaluation. Reading `translateEvaluationCache(...)` is the
// "how do `ParseWitness` and `ReplacementWitness` actually pay off"
// payoff.
//
// Cambium APIs showcased here:
// - `GreenNodeCache` / `GreenCachePolicy.parseSession(maxEntries:)`
// - `GreenBuildResult.intoCache()` (cache forwarding)
// - `IncrementalParseSession`, `IncrementalParseCounters`,
//   `recordAcceptedReuse(oldPath:newPath:green:)`,
//   `consumeAcceptedReuses()`
// - `ParseWitness` and `ReplacementWitness.classify(path:)`
// - `ExternalAnalysisCache.removeValues(notMatching:)`
// - `SyntaxMetadataStore` indexed by `SyntaxDataKey<Value>`
// - `SyntaxNodeCursor.withDescendant(atPath:_:)` for path-based traversal

import Cambium

public final class CalculatorSession {
    private var cache: GreenNodeCache<CalculatorLanguage>?
    private var lastTree: SharedSyntaxTree<CalculatorLanguage>?
    private var lastDiagnostics: [CalculatorDiagnostic] = []
    private var incremental = IncrementalParseSession<CalculatorLanguage>()
    private let evaluationCache = ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>()
    private var evaluationMetadata = SyntaxMetadataStore<CalculatorLanguage>()
    private var lastEvaluationStats = CalculatorEvaluationStats()

    public init() {}

    /// Parse `input`, optionally as the result of applying `edits` to the
    /// previous parse's source. The cache and previous tree are forwarded
    /// automatically; callers do not need to thread them.
    ///
    /// `edits` are interpreted in old-tree coordinates per
    /// `CambiumIncremental`'s contract: non-overlapping, sorted by start.
    /// Pass `[]` for a fresh document.
    public func parse(
        _ input: String,
        edits: [TextEdit] = []
    ) throws -> CalculatorParseResult {
        let previousTree = lastTree
        _ = incremental.consumeAcceptedReuses()
        evaluationMetadata = SyntaxMetadataStore<CalculatorLanguage>()
        lastEvaluationStats = CalculatorEvaluationStats()

        let builder: GreenTreeBuilder<CalculatorLanguage>
        if let existing = cache.take() {
            builder = GreenTreeBuilder(cache: existing)
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

        // Read the snapshot before consuming the build for its cache. Order
        // matters: `intoCache()` is `consuming`, after which `output.build`
        // is gone.
        let tree = output.build.snapshot.makeSyntaxTree().intoShared()
        let diagnostics = output.diagnostics
        let acceptedReuses = output.acceptedReuses
        let nextCache = output.build.intoCache()
        let calculatorDiagnostics = diagnostics.map(CalculatorDiagnostic.init(_:))
        let witness = makeParseWitness(
            previousTree: previousTree,
            newTree: tree,
            acceptedReuses: acceptedReuses
        )
        if let previousTree {
            translateEvaluationCache(from: previousTree, to: tree, witness: witness)
        }
        evaluationCache.removeValues(notMatching: tree.treeID)

        cache = consume nextCache
        lastTree = tree
        lastDiagnostics = calculatorDiagnostics
        return CalculatorParseResult(
            tree: tree,
            diagnostics: calculatorDiagnostics
        )
    }

    /// Adopt an externally-produced tree, such as a decoded serialized
    /// snapshot, as this session's current tree.
    ///
    /// The adopted tree's resolver carries its own token-key namespace, so
    /// any existing cache cannot safely be shared with subsequent parses. The
    /// next `parse(_:edits:)` call will mint a fresh cache; any subtree reuse
    /// from the adopted tree will remap dynamic token keys into that cache.
    public func adopt(_ tree: SharedSyntaxTree<CalculatorLanguage>) {
        cache = nil
        lastTree = tree
        lastDiagnostics = []
        evaluationCache.removeAll()
        evaluationMetadata = SyntaxMetadataStore<CalculatorLanguage>()
        lastEvaluationStats = CalculatorEvaluationStats()
    }

    /// Constant-fold the current document one subtree replacement at a
    /// time. Each step replaces exactly one foldable expression with an
    /// integer or real literal and records the `ReplacementWitness`
    /// returned by `SharedSyntaxTree.replacing(_:with:cache:)`. The
    /// session's evaluation cache is translated through each witness so
    /// untouched subtrees keep their memoized values.
    public func fold() throws -> FoldReport {
        guard var currentTree = lastTree else {
            throw CalculatorEvaluationError.invalidSyntax("no current document")
        }
        guard lastDiagnostics.isEmpty else {
            throw CalculatorEvaluationError.invalidSyntax(
                lastDiagnostics.map(formatDiagnostic).joined(separator: "\n")
            )
        }

        var foldCache: GreenNodeCache<CalculatorLanguage>
        if let existing = cache.take() {
            foldCache = existing
        } else {
            foldCache = GreenNodeCache(policy: .parseSession(maxEntries: 16_384))
        }

        var steps: [FoldStep] = []
        while let candidate = firstFoldCandidate(in: currentTree) {
            let output = try applyFold(
                candidate,
                in: currentTree,
                cache: consume foldCache
            )
            let step = output.step
            foldCache = output.intoCache()
            translateEvaluationCache(
                from: currentTree,
                to: step.newTree,
                witness: step.witness,
                replacementValue: candidate.literal.value
            )
            currentTree = step.newTree
            steps.append(step)
        }

        let finalSource = currentTree.withRoot { root in
            root.makeString()
        }
        cache = consume foldCache
        lastTree = currentTree
        lastDiagnostics = []
        evaluationMetadata = SyntaxMetadataStore<CalculatorLanguage>()
        lastEvaluationStats = CalculatorEvaluationStats()
        return FoldReport(
            steps: steps,
            finalTree: currentTree,
            finalSource: finalSource
        )
    }

    /// Aggregate reuse-oracle counters since the session was created or
    /// last `reset()`. See `IncrementalParseCounters` for semantics.
    public var counters: IncrementalParseCounters {
        incremental.counters
    }

    /// Stats from the most recent `evaluate()` invocation.
    public var evaluationStats: CalculatorEvaluationStats {
        lastEvaluationStats
    }

    /// Evaluate the current document, memoizing per-node values in the
    /// session's `ExternalAnalysisCache` and recording per-node metadata
    /// (evaluation order, value kind) in the `SyntaxMetadataStore`.
    public func evaluate() throws -> CalculatorValue {
        guard let tree = lastTree else {
            throw CalculatorEvaluationError.invalidSyntax("no current document")
        }
        guard lastDiagnostics.isEmpty else {
            throw CalculatorEvaluationError.invalidSyntax(
                lastDiagnostics.map(formatDiagnostic).joined(separator: "\n")
            )
        }

        evaluationMetadata = SyntaxMetadataStore<CalculatorLanguage>()
        var evaluator = CalculatorEvaluator(
            cache: evaluationCache,
            metadata: evaluationMetadata
        )
        let value = try evaluator.evaluateTree(tree)
        lastEvaluationStats = evaluator.stats
        return value
    }

    /// Memoized evaluation values for every cached expression node in
    /// the current tree, in source order. Useful for surfacing what the
    /// session has computed without re-running the evaluator.
    public func cachedValues() -> [CalculatorCachedValue] {
        guard let tree = lastTree else {
            return []
        }
        let snapshot = evaluationCache.snapshot()
        let metadata = evaluationMetadata
        return tree.withRoot { root in
            var values: [CalculatorCachedValue] = []
            _ = root.visitPreorder { node in
                let handle = node.makeHandle()
                guard ExprSyntax(handle) != nil else {
                    return .continue
                }
                let key = calculatorEvaluationCacheKey(for: handle.identity)
                guard let value = snapshot[key] else {
                    return .continue
                }
                values.append(CalculatorCachedValue(
                    range: node.textRange,
                    value: value,
                    evaluationOrder: metadata.value(for: calculatorEvaluationOrderKey, on: handle),
                    valueKind: metadata.value(for: calculatorEvaluationKindKey, on: handle)
                ))
                return .continue
            }
            return values.sorted {
                if $0.range.start == $1.range.start {
                    return $0.range.end < $1.range.end
                }
                return $0.range.start < $1.range.start
            }
        }
    }

    /// Drop every piece of session state — green-node cache, last tree,
    /// evaluation cache and metadata, and the underlying
    /// `IncrementalParseSession` (which carries the offer-side
    /// counters). After `reset()` the session is observationally
    /// indistinguishable from a fresh `CalculatorSession()`.
    public func reset() {
        cache = nil
        lastTree = nil
        lastDiagnostics = []
        evaluationCache.removeAll()
        evaluationMetadata = SyntaxMetadataStore<CalculatorLanguage>()
        lastEvaluationStats = CalculatorEvaluationStats()
        // Replacing the IncrementalParseSession is the only way to zero
        // the offer-side counters: the type does not expose a counter
        // reset.
        incremental = IncrementalParseSession<CalculatorLanguage>()
    }

    // MARK: - Witness construction

    /// Build a `ParseWitness` from the parser's accepted-reuse log,
    /// resolving each old-path entry's new-tree path by green-identity
    /// match. The session emits the result so any downstream identity
    /// tracker has a single witness covering the whole reparse.
    private func makeParseWitness(
        previousTree: SharedSyntaxTree<CalculatorLanguage>?,
        newTree: SharedSyntaxTree<CalculatorLanguage>,
        acceptedReuses: [CalculatorAcceptedReuse]
    ) -> ParseWitness<CalculatorLanguage> {
        for acceptedReuse in acceptedReuses {
            guard let newPath = resolveAcceptedReuse(acceptedReuse, in: newTree) else {
                continue
            }
            incremental.recordAcceptedReuse(
                oldPath: acceptedReuse.oldPath,
                newPath: newPath,
                green: acceptedReuse.green
            )
        }

        return ParseWitness(
            oldRoot: previousTree?.rootGreen,
            newRoot: newTree.rootGreen,
            reusedSubtrees: incremental.consumeAcceptedReuses()
        )
    }

    /// Find the first node in `tree` whose offset matches the parser's
    /// recorded splice-point and whose green storage is identical to the
    /// reused subtree. Green identity is the strongest "same node"
    /// signal — it survives only when `reuseSubtree(_:)` took the
    /// `.direct` path, exactly the case we care about.
    private func resolveAcceptedReuse(
        _ acceptedReuse: CalculatorAcceptedReuse,
        in tree: SharedSyntaxTree<CalculatorLanguage>
    ) -> SyntaxNodePath? {
        tree.withRoot { root in
            var resolvedPath: SyntaxNodePath?
            _ = root.visitPreorder { node in
                guard resolvedPath == nil,
                      node.textRange.start == acceptedReuse.newOffset,
                      node.green({ green in green.identity }) == acceptedReuse.green.identity
                else {
                    return .continue
                }
                resolvedPath = node.childIndexPath()
                return .stop
            }
            return resolvedPath
        }
    }

    // MARK: - Evaluation-cache translation

    /// Translate evaluation-cache entries from `previousTree` to `newTree`
    /// across an incremental reparse. Walks each reused subtree in the
    /// witness; any node whose old path is inside a reused subtree
    /// translates by rewriting the old path's prefix to the new path.
    private func translateEvaluationCache(
        from previousTree: SharedSyntaxTree<CalculatorLanguage>,
        to newTree: SharedSyntaxTree<CalculatorLanguage>,
        witness: ParseWitness<CalculatorLanguage>
    ) {
        guard !witness.reusedSubtrees.isEmpty else {
            return
        }
        let snapshot = evaluationCache.snapshot()
        guard !snapshot.isEmpty else {
            return
        }

        previousTree.withRoot { oldRoot in
            newTree.withRoot { newRoot in
                for reuse in witness.reusedSubtrees {
                    _ = oldRoot.withDescendant(atPath: reuse.oldPath) { oldReuseRoot in
                        oldReuseRoot.forEachDescendant(includingSelf: true) { oldNode in
                            let oldHandle = oldNode.makeHandle()
                            let oldKey = calculatorEvaluationCacheKey(for: oldHandle.identity)
                            guard let value = snapshot[oldKey] else {
                                return
                            }

                            let fullOldPath = oldNode.childIndexPath()
                            let relativePath = SyntaxNodePath(fullOldPath.dropFirst(reuse.oldPath.count))
                            let newPath = reuse.newPath + relativePath
                            _ = newRoot.withDescendant(atPath: newPath) { newNode in
                                let newKey = calculatorEvaluationCacheKey(for: newNode.identity)
                                evaluationCache.set(value, for: newKey)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Translate evaluation-cache entries through a single fold step.
    /// `ReplacementWitness.classify(path:)` distinguishes preserved
    /// nodes (`.unchanged`) from those inside the replaced subtree
    /// (`.deleted` or `.replacedRoot`); only the unchanged ones can
    /// carry their cached values into the new tree. The fold step's
    /// fresh literal node receives the freshly-computed value.
    private func translateEvaluationCache(
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
                        guard ExprSyntax(oldHandle) != nil else {
                            return
                        }
                        let oldKey = calculatorEvaluationCacheKey(for: oldHandle.identity)
                        guard let value = snapshot[oldKey] else {
                            return
                        }

                        let path = oldNode.childIndexPath()
                        guard case .unchanged = witness.classify(path: path) else {
                            return
                        }
                        _ = newRoot.withDescendant(atPath: path) { newNode in
                            let newHandle = newNode.makeHandle()
                            guard ExprSyntax(newHandle) != nil else {
                                return
                            }
                            let newKey = calculatorEvaluationCacheKey(for: newHandle.identity)
                            evaluationCache.set(value, for: newKey)
                        }
                    }
                }

                _ = newRoot.withDescendant(atPath: witness.replacedPath) { replacementNode in
                    let replacementHandle = replacementNode.makeHandle()
                    guard ExprSyntax(replacementHandle) != nil else {
                        return
                    }
                    let replacementKey = calculatorEvaluationCacheKey(for: replacementHandle.identity)
                    evaluationCache.set(replacementValue, for: replacementKey)
                }
            }
        }
        evaluationCache.removeValues(notMatching: newTree.treeID)
    }
}
