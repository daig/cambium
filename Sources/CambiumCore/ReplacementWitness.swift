/// A pure structural description of a single-subtree replacement applied via
/// `SharedSyntaxTree.replacing(handle:with:cache:)`.
///
/// Witnesses are version-spanning primitives: they describe what changed, in
/// vocabulary that's stable across tree versions (green nodes, paths, ranges).
/// They contain no resolution logic and impose no policy. Cross-tree identity
/// trackers consume witnesses to translate v0 references into v1.
///
/// Same-tree token resolution concerns (the `OverlayTokenResolver` returned
/// by `replacing` when remapping interner keys) are not part of the witness;
/// they travel via the returned `SyntaxTree`.
public struct ReplacementWitness<Lang: SyntaxLanguage>: Sendable {
    public let oldRoot: GreenNode<Lang>
    public let newRoot: GreenNode<Lang>
    public let replacedPath: SyntaxNodePath
    public let oldSubtree: GreenNode<Lang>
    public let newSubtree: GreenNode<Lang>

    public init(
        oldRoot: GreenNode<Lang>,
        newRoot: GreenNode<Lang>,
        replacedPath: SyntaxNodePath,
        oldSubtree: GreenNode<Lang>,
        newSubtree: GreenNode<Lang>
    ) {
        self.oldRoot = oldRoot
        self.newRoot = newRoot
        self.replacedPath = replacedPath
        self.oldSubtree = oldSubtree
        self.newSubtree = newSubtree
    }
}

/// Classification of a v0 path against a `ReplacementWitness`.
///
/// Pattern-match to extract `newSubtree` from `.replacedRoot`. Not
/// `Equatable`: equality semantics around green identity are subtle, and
/// callers should compare specific fields via `.identity` rather than
/// rely on synthesized equality.
public enum ReplacementOutcome<Lang: SyntaxLanguage>: Sendable {
    /// The path's node is preserved unchanged in the new tree. Either the
    /// path is disjoint from `replacedPath`, or the replacement was a no-op
    /// (the new subtree shared storage with the old).
    case unchanged

    /// The path is a strict prefix of `replacedPath`. The ancestor still
    /// exists in the new tree; only one of its descendants changed.
    case ancestor

    /// The path equals `replacedPath`. The node at this position has been
    /// replaced; `newSubtree` is the replacement.
    case replacedRoot(newSubtree: GreenNode<Lang>)

    /// The path is a strict descendant of `replacedPath`. The node it
    /// referred to has been deleted; whatever lives at this path now is a
    /// node from the replacement subtree, by definition a different node.
    case deleted
}

public extension ReplacementWitness {
    /// Classify a v0 path against this witness. Use the returned outcome to
    /// decide how to translate any v0 reference whose path is `path`.
    ///
    /// If the replacement was a no-op (`oldSubtree` and `newSubtree` share
    /// the same green storage), every path classifies as `.unchanged` —
    /// including paths at and under `replacedPath`. This short-circuit
    /// preserves the guarantee that identity-equal subtrees mean "no
    /// logical change."
    func classify(path: SyntaxNodePath) -> ReplacementOutcome<Lang> {
        if oldSubtree.identity == newSubtree.identity {
            return .unchanged
        }

        let pathCount = path.count
        let replacedCount = replacedPath.count
        let prefixLen = min(pathCount, replacedCount)

        for i in 0..<prefixLen {
            if path[i] != replacedPath[i] {
                return .unchanged
            }
        }

        if pathCount == replacedCount {
            return .replacedRoot(newSubtree: newSubtree)
        } else if pathCount < replacedCount {
            return .ancestor
        } else {
            return .deleted
        }
    }
}

/// Result of `SharedSyntaxTree.replacing(handle:with:cache:)`. Bundles the
/// new (noncopyable) tree with the witness describing the change.
///
/// The struct is `~Copyable` because `SyntaxTree<Lang>` is. Extract the
/// tree with `consume result.tree` (or `result.intoTree()`), and read
/// `result.witness` directly (the witness is Copyable).
public struct ReplacementResult<Lang: SyntaxLanguage>: ~Copyable, Sendable {
    public var tree: SyntaxTree<Lang>
    public let witness: ReplacementWitness<Lang>

    public init(tree: consuming SyntaxTree<Lang>, witness: ReplacementWitness<Lang>) {
        self.tree = tree
        self.witness = witness
    }

    /// Consume this result and return its `SyntaxTree`. The witness can be
    /// read before this call.
    public consuming func intoTree() -> SyntaxTree<Lang> {
        tree
    }
}
