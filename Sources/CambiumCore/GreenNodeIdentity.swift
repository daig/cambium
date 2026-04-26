/// Identity of a live `GreenNode` storage instance. Use to detect structural
/// sharing across versions of a tree — two `GreenNode` values whose
/// `identity` compares equal share the same in-memory storage and are
/// therefore the same node.
///
/// Lifetime: valid only while *some* `GreenNode`, tree, or witness retains
/// the underlying storage. The wrapped `ObjectIdentifier` can be reused by
/// the runtime once the storage is deallocated, so this is **not** a
/// durable, persistable, or cross-process ID. Compare two identities only
/// when both source values are reachable.
public struct GreenNodeIdentity: Sendable, Hashable {
    private let raw: ObjectIdentifier

    internal init(_ raw: ObjectIdentifier) {
        self.raw = raw
    }
}

public extension GreenNode {
    var identity: GreenNodeIdentity {
        GreenNodeIdentity(ObjectIdentifier(storage))
    }
}

/// A path from a green tree's root to a descendant node, expressed as the
/// sequence of green child-slot indices (one index per descent step).
///
/// This is intent-only documentation: the compiler treats it as `[UInt32]`,
/// so it does not enforce path-vs-array distinctions. It exists to make API
/// signatures readable and to leave room for a wrapper type later.
public typealias SyntaxNodePath = [UInt32]
