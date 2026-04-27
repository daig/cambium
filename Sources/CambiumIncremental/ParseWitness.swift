import CambiumCore

/// A description of one subtree that was reused (i.e. carried over by
/// reference) from a previous tree into a new one during an incremental
/// parse.
///
/// The same `green` storage is reachable from both `oldPath` (in the old
/// tree) and `newPath` (in the new tree). Consumers can translate any v0
/// reference whose path falls inside this subtree to v1 by rewriting the
/// `oldPath` prefix to `newPath`.
///
/// Reuses are produced by the parser/builder during an incremental parse
/// and recorded on the session via
/// ``CambiumIncremental/IncrementalParseSession/recordAcceptedReuse(oldPath:newPath:green:)``.
/// They are then collected into a ``CambiumIncremental/ParseWitness`` for the integrator to
/// translate identities through.
public struct Reuse<Lang: SyntaxLanguage>: Sendable {
    /// The shared green storage that lives at both `oldPath` and
    /// `newPath`.
    public let green: GreenNode<Lang>

    /// The path to this subtree in the previous tree.
    public let oldPath: SyntaxNodePath

    /// The path to this subtree in the new tree.
    public let newPath: SyntaxNodePath

    /// Construct a reuse record. Most code obtains reuses from
    /// ``CambiumIncremental/IncrementalParseSession/consumeAcceptedReuses()`` rather than
    /// constructing them directly.
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
/// ``reusedSubtrees`` records subtrees the parser carried over by
/// reference (see ``CambiumIncremental/Reuse``). Anything in the new tree that isn't
/// covered by a `Reuse` entry is freshly parsed; references whose v0
/// paths point into freshly parsed regions should be considered deleted
/// from an identity-tracking perspective.
///
/// **Construction.** The parser/builder records accepted reuses on
/// ``CambiumIncremental/IncrementalParseSession`` via
/// ``CambiumIncremental/IncrementalParseSession/recordAcceptedReuse(oldPath:newPath:green:)``,
/// and the integrator drains the log via
/// ``CambiumIncremental/IncrementalParseSession/consumeAcceptedReuses()`` to populate
/// ``reusedSubtrees`` after the parse completes.
///
/// `ParseWitness` is the cousin of `ReplacementWitness`: replacements
/// describe one targeted edit; parse witnesses describe a full reparse,
/// potentially preserving many disjoint subtrees.
public struct ParseWitness<Lang: SyntaxLanguage>: Sendable {
    /// The previous tree's root, or `nil` for a cold-start parse.
    public let oldRoot: GreenNode<Lang>?

    /// The new tree's root.
    public let newRoot: GreenNode<Lang>

    /// Subtrees the parser carried over from the previous tree by
    /// reference. See ``CambiumIncremental/Reuse``.
    public let reusedSubtrees: [Reuse<Lang>]

    /// Byte ranges in the new tree that are known to have been
    /// freshly parsed (typically the union of the user's edit ranges,
    /// plus any whitespace adjustments). Optional; integrators may
    /// ignore this field.
    public let invalidatedRegions: [TextRange]

    /// Construct a witness from explicit parts.
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
