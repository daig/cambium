// CalculatorSession.swift

import Cambium

extension CalculatorSession {
    /// Translate evaluation-cache entries through a single fold step.
    ///
    /// `ReplacementWitness.classify(path:)` distinguishes the four
    /// outcomes from Tutorial 7. For cache survival across an edit:
    ///
    /// - `.unchanged` → carry the cached value to the new tree's
    ///                  node at the same path.
    /// - `.ancestor`  → ancestor identities change (the rebuild
    ///                  walks them), so re-evaluation will produce a
    ///                  fresh value naturally — skip.
    /// - `.replacedRoot` → the new node is the freshly-folded
    ///                     literal; the fold step already knows its
    ///                     value, so set the new key explicitly.
    /// - `.deleted`   → the node is gone from the new tree — drop.
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
                        // Only `.unchanged` paths are safe to carry.
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

                // Seed the new literal with its known value.
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
