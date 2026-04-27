/// Identity of a live ``CambiumCore/GreenNode`` storage instance.
///
/// Use to detect structural sharing across versions of a tree — two
/// ``CambiumCore/GreenNode`` values whose `identity` compares equal share the same
/// in-memory storage and are therefore the same node, structurally and
/// physically.
///
/// This is the most precise possible "is this still the same green node"
/// signal. ``CambiumCore/ReplacementWitness/classify(path:)`` uses it to short-circuit
/// no-op replacements (`oldSubtree.identity == newSubtree.identity`).
///
/// **Lifetime.** Valid only while *some* ``CambiumCore/GreenNode``, tree, or witness
/// retains the underlying storage. The wrapped `ObjectIdentifier` can be
/// reused by the runtime once the storage is deallocated, so this is
/// **not** a durable, persistable, or cross-process ID. Compare two
/// identities only when both source values are reachable.
public struct GreenNodeIdentity: Sendable, Hashable {
    private let raw: ObjectIdentifier

    internal init(_ raw: ObjectIdentifier) {
        self.raw = raw
    }
}

public extension GreenNode {
    /// The identity of this green node's underlying storage. See
    /// ``CambiumCore/GreenNodeIdentity`` for the equality contract and lifetime rules.
    var identity: GreenNodeIdentity {
        GreenNodeIdentity(ObjectIdentifier(storage))
    }
}

/// A path from a green tree's root to a descendant node, expressed as the
/// sequence of green child-slot indices (one index per descent step).
///
/// Each index is a position in the parent's full child list (counting both
/// nodes and tokens), not the node-only count exposed by
/// ``CambiumCore/SyntaxNodeCursor/childCount``. This matches the indexing used by
/// ``CambiumCore/SyntaxNodeCursor/childIndexPath()`` and
/// ``CambiumCore/SyntaxNodeCursor/withDescendant(atPath:_:)``.
///
/// This is intent-only documentation: the compiler treats it as
/// `[UInt32]`, so it does not enforce path-vs-array distinctions. It
/// exists to make API signatures readable and to leave room for a wrapper
/// type later.
public typealias SyntaxNodePath = [UInt32]
