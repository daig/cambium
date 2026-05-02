// CalculatorSession.swift

import Cambium

extension CalculatorSession {
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
