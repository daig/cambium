import CambiumCore

/// A description of one subtree that was reused (i.e. carried over by
/// reference) from a previous tree into a new one during an incremental
/// parse. The same `green` storage is reachable from both `oldPath` (in the
/// old tree) and `newPath` (in the new tree), so consumers can translate
/// any v0 reference whose path falls inside this subtree to v1 by
/// rewriting the `oldPath` prefix to `newPath`.
public struct Reuse<Lang: SyntaxLanguage>: Sendable {
    public let green: GreenNode<Lang>
    public let oldPath: SyntaxNodePath
    public let newPath: SyntaxNodePath

    public init(
        green: GreenNode<Lang>,
        oldPath: SyntaxNodePath,
        newPath: SyntaxNodePath
    ) {
        self.green = green
        self.oldPath = oldPath
        self.newPath = newPath
    }
}

/// A pure structural description of an incremental reparse.
///
/// `reusedSubtrees` records subtrees the parser carried over by reference
/// (see `Reuse`). Anything in the new tree that isn't covered by a `Reuse`
/// entry is freshly parsed; references whose v0 paths point into freshly
/// parsed regions should be considered deleted from an identity-tracking
/// perspective.
///
/// Construction is the integrator's responsibility — the parser/builder
/// records accepted reuses on `IncrementalParseSession` via
/// `recordAcceptedReuse(...)`, and the integrator drains the log via
/// `consumeAcceptedReuses()` to populate `reusedSubtrees` after the parse
/// completes.
public struct ParseWitness<Lang: SyntaxLanguage>: Sendable {
    public let oldRoot: GreenNode<Lang>?
    public let newRoot: GreenNode<Lang>
    public let reusedSubtrees: [Reuse<Lang>]
    public let invalidatedRegions: [TextRange]

    public init(
        oldRoot: GreenNode<Lang>?,
        newRoot: GreenNode<Lang>,
        reusedSubtrees: [Reuse<Lang>],
        invalidatedRegions: [TextRange] = []
    ) {
        self.oldRoot = oldRoot
        self.newRoot = newRoot
        self.reusedSubtrees = reusedSubtrees
        self.invalidatedRegions = invalidatedRegions
    }
}
