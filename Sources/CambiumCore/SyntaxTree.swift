import Synchronization

/// A process-unique identifier for a ``CambiumCore/SyntaxTree`` (or ``CambiumCore/SharedSyntaxTree``).
///
/// Tree IDs are minted atomically when a tree is first constructed and stay
/// constant for the tree's lifetime. They appear inside ``CambiumCore/SyntaxNodeIdentity``
/// and ``CambiumCore/SyntaxTokenIdentity``, where they let consumers detect that two
/// references point at the same tree before comparing node IDs.
///
/// Tree IDs are not stable across processes or runs.
public struct TreeID: RawRepresentable, Sendable, Hashable, Comparable {
    /// The raw `UInt64` identifier.
    public let rawValue: UInt64

    /// Wrap an existing raw identifier. Most code obtains tree IDs from
    /// ``SyntaxTree/treeID`` or ``SharedSyntaxTree/treeID`` rather than
    /// constructing them directly.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: TreeID, rhs: TreeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private enum TreeIDGenerator {
    static let next = Atomic<UInt64>(1)

    static func make() -> TreeID {
        let result = next.wrappingAdd(1, ordering: .relaxed)
        return TreeID(rawValue: result.oldValue)
    }
}

/// A tree-local identifier for a realized red node.
///
/// Red node IDs are assigned in the order red nodes are first realized
/// (lazily, on demand). They are stable for the life of the tree they
/// belong to but not meaningful across trees — pair with ``CambiumCore/TreeID`` to
/// form a globally interpretable identity (see ``CambiumCore/SyntaxNodeIdentity``).
public struct RedNodeID: RawRepresentable, Sendable, Hashable, Comparable {
    /// The raw `UInt64` identifier.
    public let rawValue: UInt64

    /// Wrap an existing raw identifier.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: RedNodeID, rhs: RedNodeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The value-typed identity of a node within a tree.
///
/// `SyntaxNodeIdentity` is the right key when you want a hashable handle to
/// a node that does **not** retain the tree — for example, a key into a
/// `Dictionary<SyntaxNodeIdentity, Diagnostic>`. Two identities compare
/// equal iff they refer to the same node in the same tree.
///
/// To compare a node from one tree to a "corresponding" node in a later
/// tree version, you need a witness chain (see ``CambiumCore/ReplacementWitness`` and
/// `ParseWitness`); identities themselves do not survive structural edits.
public struct SyntaxNodeIdentity: Sendable, Hashable {
    /// The owning tree's identifier.
    public let treeID: TreeID

    /// The tree-local identifier for the node.
    public let nodeID: RedNodeID

    /// Construct an identity from its parts. Most code obtains identities
    /// via ``CambiumCore/SyntaxNodeCursor/identity`` or ``CambiumCore/SyntaxNodeHandle/identity``
    /// rather than building them by hand.
    public init(treeID: TreeID, nodeID: RedNodeID) {
        self.treeID = treeID
        self.nodeID = nodeID
    }
}

/// The value-typed identity of a token within a tree.
///
/// Tokens are not realized as red nodes (they are leaves), so their
/// identity is keyed on their parent's red node ID and their child index
/// within that parent — together with the owning ``CambiumCore/TreeID``.
public struct SyntaxTokenIdentity: Sendable, Hashable {
    /// The owning tree's identifier.
    public let treeID: TreeID

    /// The parent node's tree-local identifier.
    public let parentID: RedNodeID

    /// The token's index inside its parent's child list (counting both
    /// nodes and tokens).
    public let childIndexInParent: UInt32

    /// Construct an identity from its parts. Most code obtains identities
    /// via ``SyntaxTokenCursor/identity`` or ``SyntaxTokenHandle/identity``.
    public init(treeID: TreeID, parentID: RedNodeID, childIndexInParent: UInt32) {
        self.treeID = treeID
        self.parentID = parentID
        self.childIndexInParent = childIndexInParent
    }
}

final class RedNodeRecord<Lang: SyntaxLanguage>: @unchecked Sendable {
    let id: RedNodeID
    let green: GreenNode<Lang>
    let parentRecord: RedNodeRecord<Lang>?
    let indexInParent: UInt32
    let offset: TextSize
    let childSlotChunk: AtomicSlotChunk
    let childSlotStart: Int
    let childSlotCount: Int

    init(
        id: RedNodeID,
        green: GreenNode<Lang>,
        parentRecord: RedNodeRecord<Lang>?,
        indexInParent: UInt32,
        offset: TextSize,
        childSlotChunk: AtomicSlotChunk,
        childSlotStart: Int,
        childSlotCount: Int
    ) {
        self.id = id
        self.green = green
        self.parentRecord = parentRecord
        self.indexInParent = indexInParent
        self.offset = offset
        self.childSlotChunk = childSlotChunk
        self.childSlotStart = childSlotStart
        self.childSlotCount = childSlotCount
    }
}

final class AtomicSlotChunk: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Atomic<UInt>>
    let capacity: Int
    var used: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.used = 0
        self.storage = UnsafeMutablePointer<Atomic<UInt>>.allocate(capacity: capacity)
        for index in 0..<capacity {
            (storage + index).initialize(to: Atomic(0))
        }
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    func loadRecord<Lang: SyntaxLanguage>(
        at index: Int
    ) -> RedNodeRecord<Lang>? {
        precondition(index >= 0 && index < capacity, "Red child slot index out of bounds")
        let bits = (storage + index).pointee.load(ordering: .acquiring)
        guard bits != 0 else {
            return nil
        }
        let pointer = UnsafeRawPointer(bitPattern: bits)!
        return Unmanaged<RedNodeRecord<Lang>>
            .fromOpaque(pointer)
            .takeUnretainedValue()
    }

    func storeRecord<Lang: SyntaxLanguage>(
        _ record: RedNodeRecord<Lang>,
        at index: Int
    ) {
        precondition(index >= 0 && index < capacity, "Red child slot index out of bounds")
        let bits = UInt(bitPattern: Unmanaged.passUnretained(record).toOpaque())
        (storage + index).pointee.store(bits, ordering: .releasing)
    }
}

private let redArenaMinimumSlotChunkCapacity = 1024

final class RedArena<Lang: SyntaxLanguage>: @unchecked Sendable {
    struct State {
        var records: [RedNodeRecord<Lang>]
        var slotChunks: [AtomicSlotChunk]
    }

    let rootRecord: RedNodeRecord<Lang>
    private let state: Mutex<State>

    init(root: GreenNode<Lang>) {
        let rootChunk = AtomicSlotChunk(capacity: max(redArenaMinimumSlotChunkCapacity, root.childCount))
        rootChunk.used = root.childCount
        let rootRecord = RedNodeRecord(
            id: RedNodeID(rawValue: 0),
            green: root,
            parentRecord: nil,
            indexInParent: 0,
            offset: .zero,
            childSlotChunk: rootChunk,
            childSlotStart: 0,
            childSlotCount: root.childCount
        )
        self.rootRecord = rootRecord
        self.state = Mutex(State(
            records: [rootRecord],
            slotChunks: [rootChunk]
        ))
    }

    func realizeChildNode(
        parent: RedNodeRecord<Lang>,
        childIndex: Int,
        childStartOffset: TextSize? = nil
    ) -> RedNodeRecord<Lang>? {
        precondition(childIndex >= 0 && childIndex < parent.green.childCount, "Child index out of bounds")

        guard case .node = parent.green.child(at: childIndex) else {
            return nil
        }

        let slotIndex = parent.childSlotStart + childIndex
        if let child: RedNodeRecord<Lang> = parent.childSlotChunk.loadRecord(at: slotIndex) {
            return child
        }

        return state.withLock { state -> RedNodeRecord<Lang>? in
            let parentIndex = Int(parent.id.rawValue)
            precondition(state.records.indices.contains(parentIndex), "Unknown red node id \(parent.id.rawValue)")
            precondition(state.records[parentIndex] === parent, "Red parent record does not match its id")
            precondition(childIndex >= 0 && childIndex < parent.green.childCount, "Child index out of bounds")

            guard case .node(let childGreen) = parent.green.child(at: childIndex) else {
                return Optional<RedNodeRecord<Lang>>.none
            }

            let slotIndex = parent.childSlotStart + childIndex
            let slotChunk = parent.childSlotChunk
            if let child: RedNodeRecord<Lang> = slotChunk.loadRecord(at: slotIndex) {
                return child
            }

            let childSlotLocation = allocateSlots(count: childGreen.childCount, state: &state)
            let id = RedNodeID(rawValue: UInt64(state.records.count))
            let childRecord = RedNodeRecord(
                id: id,
                green: childGreen,
                parentRecord: parent,
                indexInParent: UInt32(childIndex),
                offset: parent.offset + (childStartOffset ?? parent.green.childStartOffset(at: childIndex)),
                childSlotChunk: childSlotLocation.chunk,
                childSlotStart: childSlotLocation.start,
                childSlotCount: childGreen.childCount
            )
            // The arena retains the record before publishing its pointer to lock-free readers.
            state.records.append(childRecord)
            slotChunk.storeRecord(childRecord, at: slotIndex)
            return childRecord
        }
    }

    private func allocateSlots(
        count: Int,
        state: inout State
    ) -> (chunk: AtomicSlotChunk, start: Int) {
        guard count > 0 else {
            return (state.slotChunks[0], 0)
        }

        if let last = state.slotChunks.indices.last {
            let chunk = state.slotChunks[last]
            if chunk.capacity - chunk.used >= count {
                let start = chunk.used
                chunk.used += count
                return (chunk, start)
            }
        }

        let chunk = AtomicSlotChunk(capacity: max(redArenaMinimumSlotChunkCapacity, count))
        chunk.used = count
        state.slotChunks.append(chunk)
        return (chunk, 0)
    }
}

/// Reference-counted backing storage shared by ``CambiumCore/SyntaxTree`` and
/// ``CambiumCore/SharedSyntaxTree``.
///
/// You normally never name `SyntaxTreeStorage` directly. It exists as a
/// concrete reference type so the value-typed `SyntaxTree`/`SharedSyntaxTree`
/// wrappers can share the same lazy red arena and underlying green root.
///
/// Public to support custom integration patterns (storing pre-built
/// storage, constructing handles from third-party producers); ordinary
/// code should construct trees through ``SyntaxTree/init(root:resolver:)``.
public final class SyntaxTreeStorage<Lang: SyntaxLanguage>: @unchecked Sendable {
    /// Process-unique identifier minted at construction.
    public let treeID: TreeID

    /// The immutable green root.
    public let rootGreen: GreenNode<Lang>

    /// Resolver for the tree's dynamic token text.
    public let resolver: any TokenResolver

    let arena: RedArena<Lang>

    /// Construct fresh storage. Mints a new ``CambiumCore/TreeID``.
    public init(rootGreen: GreenNode<Lang>, resolver: any TokenResolver) {
        self.treeID = TreeIDGenerator.make()
        self.rootGreen = rootGreen
        self.resolver = resolver
        self.arena = RedArena(root: rootGreen)
    }
}

/// A non-copyable owning view of a syntax tree.
///
/// `SyntaxTree` is what `GreenTreeSnapshot.makeSyntaxTree()` returns after
/// a builder has produced a `GreenBuildResult`. It is `~Copyable` to make
/// ownership boundaries explicit: you traverse it by passing a borrowed
/// closure to ``withRoot(_:)`` (which yields a noncopyable
/// ``CambiumCore/SyntaxNodeCursor``), and you "promote" it to a copyable
/// ``CambiumCore/SharedSyntaxTree`` only when you genuinely need long-lived sharing
/// across actor boundaries or storage in a snapshot value.
///
/// ## Why noncopyable?
///
/// The cstree-style red layer is allocated lazily as you traverse, and
/// individual red nodes are not retained — only the tree as a whole is.
/// Making `SyntaxTree` copyable would either entail per-node retain
/// traffic (the price `rowan` pays) or force a confusing semantic
/// (copy of a value vs. copy of a reference). `~Copyable` removes the
/// ambiguity: traversal borrows; sharing requires an explicit conversion.
///
/// ```swift
/// let result = try builder.finish()
/// let tree = result.snapshot.makeSyntaxTree()
///
/// // Borrowed traversal — no allocations beyond lazy red-node realization.
/// let length = tree.withRoot { root in
///     root.textLength
/// }
///
/// // Promote to a copyable shared tree for handing off to async work.
/// let shared = tree.intoShared()
/// ```
///
/// ## Topics
///
/// ### Constructing
/// - ``init(root:resolver:)``
///
/// ### Inspecting
/// - ``treeID``
/// - ``rootGreen``
/// - ``resolver``
///
/// ### Traversing
/// - ``withRoot(_:)``
/// - ``withMutableRoot(_:)``
///
/// ### Sharing
/// - ``share()``
/// - ``intoShared()``
public struct SyntaxTree<Lang: SyntaxLanguage>: ~Copyable, Sendable {
    internal let storage: SyntaxTreeStorage<Lang>

    /// Construct a tree from a green root.
    ///
    /// The default resolver is an empty ``CambiumCore/TokenTextSnapshot``, which is
    /// only sufficient when the tree contains no dynamic tokens. Pass the
    /// builder's `GreenBuildResult.tokenText` (or call
    /// `GreenTreeSnapshot.makeSyntaxTree()` instead) when the tree
    /// contains identifiers, literals, or other dynamic-text tokens.
    public init(root: GreenNode<Lang>, resolver: any TokenResolver = TokenTextSnapshot()) {
        self.storage = SyntaxTreeStorage(rootGreen: root, resolver: resolver)
    }

    /// The process-unique identifier of this tree.
    public var treeID: TreeID {
        storage.treeID
    }

    /// The immutable green root.
    public var rootGreen: GreenNode<Lang> {
        storage.rootGreen
    }

    /// Resolver for the tree's dynamic token text.
    public var resolver: any TokenResolver {
        storage.resolver
    }

    /// Run `body` with a borrowed cursor on the root node.
    ///
    /// This is the primary traversal entry point. The cursor is `~Copyable`
    /// and lives only inside the closure — a deliberate restriction that
    /// keeps traversal allocation-free.
    public borrowing func withRoot<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R {
        let cursor = SyntaxNodeCursor(storage: storage, record: storage.arena.rootRecord)
        return try body(cursor)
    }

    /// Run `body` with an owned mutable cursor on the root node.
    ///
    /// Use this when you want the low-level ``SyntaxNodeCursor/moveToParent()``
    /// / ``SyntaxNodeCursor/moveToFirstChild()`` style APIs. For most
    /// traversal code, prefer ``withRoot(_:)`` and the borrowed `with*` or
    /// visitor helpers.
    public borrowing func withMutableRoot<R>(
        _ body: (inout SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R {
        var cursor = SyntaxNodeCursor(storage: storage, record: storage.arena.rootRecord)
        return try body(&cursor)
    }

    /// Return a copyable ``CambiumCore/SharedSyntaxTree`` referring to this tree's
    /// storage, without consuming `self`. Use when you need to hold a
    /// shared reference while still continuing to use the noncopyable tree.
    public borrowing func share() -> SharedSyntaxTree<Lang> {
        SharedSyntaxTree(storage: storage)
    }

    /// Consume this tree and return a copyable ``CambiumCore/SharedSyntaxTree`` over
    /// the same storage. Use when promoting a fresh build result for
    /// SwiftUI publishing, cross-actor handoff, or long-lived storage.
    public consuming func intoShared() -> SharedSyntaxTree<Lang> {
        SharedSyntaxTree(storage: storage)
    }
}

/// A copyable, `Sendable`, reference-counted view of a syntax tree.
///
/// `SharedSyntaxTree` is what you reach for whenever a tree needs to
/// outlive a single borrow scope: storing it in a SwiftUI `@State`,
/// publishing it through `Combine`, handing it off to a `Task`, building
/// a long-lived index. It strongly retains the underlying
/// ``CambiumCore/SyntaxTreeStorage``, so the green tree, the resolver, and any
/// realized red nodes survive as long as any shared tree value does.
///
/// All traversal still goes through ``withRoot(_:)``, which yields a
/// borrowed ``CambiumCore/SyntaxNodeCursor``. For long-lived references to specific
/// nodes, use ``rootHandle()`` to obtain a ``CambiumCore/SyntaxNodeHandle``.
///
/// ## Topics
///
/// ### Inspecting
/// - ``treeID``
/// - ``rootGreen``
/// - ``resolver``
///
/// ### Traversing
/// - ``withRoot(_:)``
/// - ``withMutableRoot(_:)``
///
/// ### Handles
/// - ``rootHandle()``
///
/// ### Editing
///
/// `SharedSyntaxTree.replacing(_:with:cache:)` (defined in
/// CambiumBuilder) returns a new tree along with a
/// ``CambiumCore/ReplacementWitness`` describing the structural change.
public struct SharedSyntaxTree<Lang: SyntaxLanguage>: Sendable {
    internal let storage: SyntaxTreeStorage<Lang>

    /// Wrap existing tree storage. Most code obtains shared trees via
    /// ``CambiumCore/SyntaxTree/share()`` or ``CambiumCore/SyntaxTree/intoShared()`` instead.
    public init(storage: SyntaxTreeStorage<Lang>) {
        self.storage = storage
    }

    /// The process-unique identifier of this tree.
    public var treeID: TreeID {
        storage.treeID
    }

    /// The immutable green root.
    public var rootGreen: GreenNode<Lang> {
        storage.rootGreen
    }

    /// Resolver for the tree's dynamic token text.
    public var resolver: any TokenResolver {
        storage.resolver
    }

    /// Run `body` with a borrowed cursor on the root node. Same semantics
    /// as ``CambiumCore/SyntaxTree/withRoot(_:)``.
    public func withRoot<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R {
        let cursor = SyntaxNodeCursor(storage: storage, record: storage.arena.rootRecord)
        return try body(cursor)
    }

    /// Run `body` with an owned mutable cursor on the root node.
    ///
    /// Use this when you want the low-level ``SyntaxNodeCursor/moveToParent()``
    /// / ``SyntaxNodeCursor/moveToFirstChild()`` style APIs. For most
    /// traversal code, prefer ``withRoot(_:)`` and the borrowed `with*` or
    /// visitor helpers.
    public func withMutableRoot<R>(
        _ body: (inout SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R {
        var cursor = SyntaxNodeCursor(storage: storage, record: storage.arena.rootRecord)
        return try body(&cursor)
    }

    /// Return a copyable handle to the tree's root node. Useful for
    /// long-lived references that survive across borrow scopes.
    public func rootHandle() -> SyntaxNodeHandle<Lang> {
        SyntaxNodeHandle(storage: storage, record: storage.arena.rootRecord)
    }

}

/// A copyable, hashable, retained reference to a node in a syntax tree.
///
/// `SyntaxNodeHandle` is the long-lived complement to ``CambiumCore/SyntaxNodeCursor``.
/// Use it when a node reference needs to outlive a borrow scope: storing
/// nodes in a `Dictionary` or `Set`, attaching diagnostics to nodes,
/// publishing nodes to SwiftUI, sending nodes across actor boundaries.
///
/// Handles strongly retain the underlying ``CambiumCore/SyntaxTreeStorage``, so the
/// tree (and any realized red nodes) stays alive as long as the handle
/// does.
///
/// All traversal still goes through ``withCursor(_:)``, which yields a
/// borrowed ``CambiumCore/SyntaxNodeCursor`` over the same node. Use
/// ``withMutableCursor(_:)`` only when you specifically need the mutating
/// `moveTo*` cursor operations.
///
/// ## Equality
///
/// Two handles compare equal iff they refer to the same node in the same
/// tree. Handles from different trees never compare equal even if they
/// reference structurally identical green storage.
public struct SyntaxNodeHandle<Lang: SyntaxLanguage>: Sendable, Hashable {
    internal let storage: SyntaxTreeStorage<Lang>
    internal let record: RedNodeRecord<Lang>

    internal var id: RedNodeID {
        record.id
    }

    /// The value-typed identity of this handle. Useful as a hashable key
    /// when you don't need to retain the tree.
    public var identity: SyntaxNodeIdentity {
        SyntaxNodeIdentity(treeID: storage.treeID, nodeID: id)
    }

    /// The language-agnostic kind of the referenced node.
    public var rawKind: RawSyntaxKind {
        record.green.rawKind
    }

    /// The byte range covered by the referenced node.
    public var textRange: TextRange {
        return TextRange(start: record.offset, length: record.green.textLength)
    }

    /// Run `body` with a borrowed cursor on the referenced node.
    public func withCursor<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R {
        let cursor = SyntaxNodeCursor(storage: storage, record: record)
        return try body(cursor)
    }

    /// Run `body` with an owned mutable cursor on this node.
    public func withMutableCursor<R>(
        _ body: (inout SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R {
        var cursor = SyntaxNodeCursor(storage: storage, record: record)
        return try body(&cursor)
    }

    public static func == (lhs: SyntaxNodeHandle<Lang>, rhs: SyntaxNodeHandle<Lang>) -> Bool {
        lhs.storage.treeID == rhs.storage.treeID && lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage.treeID)
        hasher.combine(id)
    }
}

/// A copyable, hashable, retained reference to a token in a syntax tree.
///
/// Same role as ``CambiumCore/SyntaxNodeHandle`` but for tokens. Uses parent + child
/// index as identity (tokens are leaves, not realized as red records).
public struct SyntaxTokenHandle<Lang: SyntaxLanguage>: Sendable, Hashable {
    internal let storage: SyntaxTreeStorage<Lang>
    internal let parentRecord: RedNodeRecord<Lang>
    internal let childIndex: UInt32
    internal let offset: TextSize

    internal var parent: RedNodeID {
        parentRecord.id
    }

    /// The value-typed identity of this handle.
    public var identity: SyntaxTokenIdentity {
        SyntaxTokenIdentity(
            treeID: storage.treeID,
            parentID: parent,
            childIndexInParent: childIndex
        )
    }

    /// Run `body` with a borrowed cursor on the referenced token. Traps if
    /// the parent's child at `childIndex` is no longer a token (only
    /// possible when handles are mismanaged across structurally
    /// incompatible trees).
    public func withCursor<R>(
        _ body: (borrowing SyntaxTokenCursor<Lang>) throws -> R
    ) rethrows -> R {
        guard case .token(let token) = parentRecord.green.child(at: Int(childIndex)) else {
            preconditionFailure("Token handle points at a node child")
        }
        let cursor = SyntaxTokenCursor(
            storage: storage,
            parentRecord: parentRecord,
            childIndex: childIndex,
            offset: offset,
            green: token
        )
        return try body(cursor)
    }

    public static func == (lhs: SyntaxTokenHandle<Lang>, rhs: SyntaxTokenHandle<Lang>) -> Bool {
        lhs.storage.treeID == rhs.storage.treeID
            && lhs.parent == rhs.parent
            && lhs.childIndex == rhs.childIndex
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage.treeID)
        hasher.combine(parent)
        hasher.combine(childIndex)
    }
}

/// Per-step control returned from a visitor closure to direct further
/// traversal.
///
/// Visitor methods such as ``SyntaxNodeCursor/visitPreorder(_:)``,
/// ``SyntaxNodeCursor/walkPreorder(_:)``, and
/// ``CambiumCore/SyntaxNodeCursor/walkPreorderWithTokens(_:)`` accept a closure
/// returning `TraversalControl` after each visited node or event.
public enum TraversalControl: Sendable, Hashable {
    /// Continue normal traversal: descend into children, then move on to
    /// siblings.
    case `continue`

    /// Skip the children of the current node, but continue with siblings.
    /// Useful for pruning whole subtrees that you've classified as
    /// uninteresting.
    case skipChildren

    /// Abandon traversal entirely. The visitor returns up the stack and
    /// the outermost `visitPreorder`/`walkPreorder` returns `.stop`.
    case stop
}

/// Iteration direction for sibling/element walks.
public enum TraversalDirection: Sendable, Hashable {
    /// Iterate in source order.
    case forward

    /// Iterate in reverse source order.
    case backward
}

/// A pre/post-order event fired by ``SyntaxNodeCursor/walkPreorder(_:)``.
///
/// Each node is announced twice: once on entry (before children) and once
/// on exit (after children). Useful when the work you want to do at a
/// node depends on whether you're descending or ascending — emitting
/// indented output, for example.
public enum SyntaxNodeWalkEvent<Lang: SyntaxLanguage>: ~Copyable {
    /// The walker has just entered `cursor`'s node and has not yet visited
    /// its children.
    case enter(SyntaxNodeCursor<Lang>)

    /// The walker has just finished visiting `cursor`'s children and is
    /// about to leave its node.
    case leave(SyntaxNodeCursor<Lang>)
}

/// The element-grained pre/post-order event fired by
/// ``CambiumCore/SyntaxNodeCursor/walkPreorderWithTokens(_:)``.
///
/// Like ``CambiumCore/SyntaxNodeWalkEvent`` but also fires `enter`/`leave` events for
/// tokens (which are leaves, so the two events fire back-to-back).
public enum SyntaxElementWalkEvent<Lang: SyntaxLanguage>: ~Copyable {
    /// The walker has just entered `cursor`'s element. For tokens this
    /// always pairs with an immediate ``leave(_:)``.
    case enter(SyntaxElementCursor<Lang>)

    /// The walker is about to leave `cursor`'s element.
    case leave(SyntaxElementCursor<Lang>)
}

// NOTE: The natural shape for the token-at-offset API would be a `~Copyable`
// enum:
//
//     public enum TokenAtOffset<Lang>: ~Copyable {
//         case none
//         case single(SyntaxTokenCursor<Lang>)
//         case between(left: SyntaxTokenCursor<Lang>, right: SyntaxTokenCursor<Lang>)
//     }
//
// SE-0432 says this should work, and SyntaxNodeWalkEvent already uses the
// single-payload form. But pattern-matching the multi-payload `.between` case
// (`case .between(let left, let right)`) currently triggers a Swift compiler
// error: "copy of noncopyable typed value. This is a compiler bug." It's a
// known family of bugs against `~Copyable` codegen, with no documented fix-in
// version. Tracking links:
//   - https://forums.swift.org/t/copy-of-noncopyable-typed-value-bug/84873
//   - https://forums.swift.org/t/copy-of-non-copyable-typed-value/75842
// As a workaround we expose the three cases via three explicit closures
// (`none`, `single`, `between`) on `withTokenAtOffset(_:none:single:between:)`
// — function parameters with multiple `~Copyable` values work fine, only the
// pattern-binding path breaks. Revisit and switch to the enum form once the
// compiler bug is fixed.

/// Captures everything needed to construct a `SyntaxTokenCursor` for a
/// found token, without paying the cursor construction cost during the
/// recursive walk. Internal helper for `withTokenAtOffset`.
private struct TokenLocation<Lang: SyntaxLanguage> {
    let parentRecord: RedNodeRecord<Lang>
    let childIndex: UInt32
    let offset: TextSize
    let green: GreenToken<Lang>
}

/// A non-owning, non-copyable cursor that points at one node in a syntax
/// tree.
///
/// `SyntaxNodeCursor` is the **primary traversal API**. It does not retain
/// the tree; it borrows it for the duration of a closure passed to
/// ``CambiumCore/SyntaxTree/withRoot(_:)``, ``CambiumCore/SharedSyntaxTree/withRoot(_:)``, or one
/// of the cursor's own `with*` methods. Because cursors are `~Copyable`
/// and non-owning, traversal involves no per-step ARC traffic, no
/// allocation of intermediate `Array`s, and no implicit copying of red
/// node records.
///
/// ## Two flavours of navigation
///
/// Cursors expose traversal as two families: **borrowing `with*`**
/// methods that return a result from a closure (visit a neighbour
/// without losing the original position), and low-level **mutating
/// `moveTo*`** methods that move an owned cursor in place.
///
/// ```swift
/// // In-place: walk to the first child, if any.
/// let firstKind = tree.withMutableRoot { cursor in
///     cursor.moveToFirstChild() ? cursor.kind : nil
/// }
///
/// // With-closure: inspect the first child without moving the original.
/// let firstChildKind = tree.withRoot { root in
///     root.withFirstChild { child in
///         child.kind
///     }
/// }
/// ```
///
/// ## Visitors
///
/// For full-tree walks, prefer the visitor methods over manual
/// recursion:
///
/// - ``forEachChild(_:)``, ``forEachChildOrToken(_:)``: direct children only.
/// - ``forEachDescendant(includingSelf:_:)``, ``forEachDescendantOrToken(includingSelf:_:)``:
///   recursive depth-first walks.
/// - ``visitPreorder(_:)``, ``walkPreorder(_:)``,
///   ``walkPreorderWithTokens(_:)``: depth-first walks with control
///   over descent and stopping (``CambiumCore/TraversalControl``).
/// - ``forEachAncestor(includingSelf:_:)``: walk parent chain.
/// - ``tokens(in:_:)``: visit tokens, optionally filtered to a range.
///
/// ## Same-tree identity
///
/// Within one tree, identity is rock solid:
///
/// - ``identity`` returns a value-typed ``CambiumCore/SyntaxNodeIdentity`` you can
///   key a `Dictionary` on.
/// - ``makeHandle()`` returns a copyable ``CambiumCore/SyntaxNodeHandle`` you can
///   store and re-borrow later.
///
/// Cross-tree identity (translating a node from version `v0` to version
/// `v1` after edits) is **not** done via cursors; it is done by following
/// a witness chain (``CambiumCore/ReplacementWitness``, `ParseWitness`).
///
/// ## Topics
///
/// ### Inspecting
/// - ``identity``
/// - ``rawKind``
/// - ``kind``
/// - ``textRange``
/// - ``textLength``
/// - ``childCount``
/// - ``childOrTokenCount``
/// - ``greenHash``
/// - ``rootGreen``
/// - ``resolver``
///
/// ### Working with the underlying green node
/// - ``green(_:)``
/// - ``resolvedGreenNode()``
///
/// ### Moving the cursor in place
/// - ``moveToParent()``
/// - ``moveToFirstChild()``
/// - ``moveToLastChild()``
/// - ``moveToNextSibling()``
/// - ``moveToPreviousSibling()``
///
/// ### Visiting neighbours via closure
/// - ``withParent(_:)``
/// - ``withChildNode(at:_:)``
/// - ``withFirstChild(_:)``
/// - ``withLastChild(_:)``
/// - ``withChildOrToken(at:_:)``
/// - ``withFirstChildOrToken(_:)``
/// - ``withLastChildOrToken(_:)``
/// - ``withNextSibling(_:)``
/// - ``withPreviousSibling(_:)``
/// - ``withNextSiblingOrToken(_:)``
/// - ``withPreviousSiblingOrToken(_:)``
///
/// ### Iteration
/// - ``forEachChild(_:)``
/// - ``forEachChildOrToken(_:)``
/// - ``forEachSibling(direction:includingSelf:_:)``
/// - ``forEachSiblingOrToken(direction:includingSelf:_:)``
/// - ``forEachAncestor(includingSelf:_:)``
/// - ``forEachDescendant(includingSelf:_:)``
/// - ``forEachDescendantOrToken(includingSelf:_:)``
/// - ``visitPreorder(_:)``
/// - ``walkPreorder(_:)``
/// - ``walkPreorderWithTokens(_:)``
/// - ``tokens(in:_:)``
///
/// ### Position queries
/// - ``withTokenAtOffset(_:none:single:between:)``
/// - ``withCoveringElement(_:_:)``
///
/// ### Text materialization
/// - ``withText(_:)``
/// - ``makeString()``
///
/// ### Crossing borrow scopes
/// - ``makeHandle()``
/// - ``childIndexPath()``
/// - ``withDescendant(atPath:_:)``
public struct SyntaxNodeCursor<Lang: SyntaxLanguage>: ~Copyable {
    private let storageRef: Unmanaged<SyntaxTreeStorage<Lang>>
    private var recordRef: Unmanaged<RedNodeRecord<Lang>>

    internal init(storage: SyntaxTreeStorage<Lang>, record: RedNodeRecord<Lang>) {
        self.storageRef = Unmanaged.passUnretained(storage)
        self.recordRef = Unmanaged.passUnretained(record)
    }

    internal var storage: SyntaxTreeStorage<Lang> {
        storageRef.takeUnretainedValue()
    }

    internal var record: RedNodeRecord<Lang> {
        recordRef.takeUnretainedValue()
    }

    internal var id: RedNodeID {
        record.id
    }

    private mutating func move(to record: RedNodeRecord<Lang>) {
        recordRef = Unmanaged.passUnretained(record)
    }

    /// The value-typed identity of the node under this cursor.
    public var identity: SyntaxNodeIdentity {
        SyntaxNodeIdentity(treeID: storage.treeID, nodeID: id)
    }

    /// The language-agnostic kind of the node.
    public var rawKind: RawSyntaxKind {
        record.green.rawKind
    }

    /// The typed kind of the node.
    public var kind: Lang.Kind {
        Lang.kind(for: rawKind)
    }

    /// The byte range of the node within the source document.
    public var textRange: TextRange {
        let record = record
        return TextRange(start: record.offset, length: record.green.textLength)
    }

    /// The UTF-8 byte length of the node.
    public var textLength: TextSize {
        record.green.textLength
    }

    /// The number of node children (excluding tokens).
    public var childCount: Int {
        record.green.nodeChildCount
    }

    /// The number of children counting both nodes and tokens.
    public var childOrTokenCount: Int {
        record.green.childCount
    }

    /// The structural hash of the underlying green node. Useful as a
    /// content-addressed key for memoized analysis caches.
    public var greenHash: UInt64 {
        record.green.structuralHash
    }

    /// The green root of the tree this cursor walks.
    public var rootGreen: GreenNode<Lang> {
        storage.rootGreen
    }

    /// The resolver for the tree's dynamic token text.
    public var resolver: any TokenResolver {
        storage.resolver
    }

    /// Run `body` with the borrowed green node under this cursor.
    public borrowing func green<R>(
        _ body: (borrowing GreenNode<Lang>) throws -> R
    ) rethrows -> R {
        try body(record.green)
    }

    /// The green node and resolver, packaged for replacement APIs that
    /// need both. See ``CambiumCore/ResolvedGreenNode``.
    public borrowing func resolvedGreenNode() -> ResolvedGreenNode<Lang> {
        ResolvedGreenNode(root: record.green, resolver: storage.resolver)
    }

    /// Move this cursor to its parent, returning `true` on success.
    /// Returns `false` (and leaves the cursor at the root) when the cursor
    /// is already at the tree root.
    public mutating func moveToParent() -> Bool {
        guard let parent = record.parentRecord else {
            return false
        }
        move(to: parent)
        return true
    }

    /// Move this cursor to its first node child, returning `true` on
    /// success. Skips token children. Returns `false` (and leaves the
    /// cursor in place) when there is no node child.
    public mutating func moveToFirstChild() -> Bool {
        let current = record
        let green = current.green
        var childStart = TextSize.zero
        for index in 0..<green.childCount {
            let childGreen = green.child(at: index)
            defer {
                childStart = childStart + childGreen.textLength
            }
            guard case .node = childGreen else {
                continue
            }
            if let child = storage.arena.realizeChildNode(
                parent: current,
                childIndex: index,
                childStartOffset: childStart
            ) {
                move(to: child)
                return true
            }
        }
        return false
    }

    /// Move this cursor to its last node child, returning `true` on
    /// success. Skips token children. Returns `false` (and leaves the
    /// cursor in place) when there is no node child.
    public mutating func moveToLastChild() -> Bool {
        let current = record
        let green = current.green
        guard green.childCount > 0 else {
            return false
        }
        var childEnd = green.textLength
        for index in stride(from: green.childCount - 1, through: 0, by: -1) {
            let childGreen = green.child(at: index)
            let childStart = childEnd - childGreen.textLength
            defer {
                childEnd = childStart
            }
            guard case .node = childGreen else {
                continue
            }
            if let child = storage.arena.realizeChildNode(
                parent: current,
                childIndex: index,
                childStartOffset: childStart
            ) {
                move(to: child)
                return true
            }
        }
        return false
    }

    /// Move this cursor to its next node sibling, returning `true` on
    /// success. Skips token siblings. Returns `false` (and leaves the
    /// cursor in place) when there is no later node sibling.
    public mutating func moveToNextSibling() -> Bool {
        let current = record
        guard let parent = current.parentRecord else {
            return false
        }
        let start = Int(current.indexInParent) + 1
        guard start < parent.green.childCount else {
            return false
        }
        var childStart = (current.offset - parent.offset) + current.green.textLength
        for index in start..<parent.green.childCount {
            let childGreen = parent.green.child(at: index)
            defer {
                childStart = childStart + childGreen.textLength
            }
            guard case .node = childGreen else {
                continue
            }
            if let sibling = storage.arena.realizeChildNode(
                parent: parent,
                childIndex: index,
                childStartOffset: childStart
            ) {
                move(to: sibling)
                return true
            }
        }
        return false
    }

    /// Move this cursor to its previous node sibling, returning `true` on
    /// success. Skips token siblings. Returns `false` (and leaves the
    /// cursor in place) when there is no earlier node sibling.
    public mutating func moveToPreviousSibling() -> Bool {
        let current = record
        guard let parent = current.parentRecord, current.indexInParent > 0 else {
            return false
        }
        var childEnd = current.offset - parent.offset
        for index in stride(from: Int(current.indexInParent) - 1, through: 0, by: -1) {
            let childGreen = parent.green.child(at: index)
            let childStart = childEnd - childGreen.textLength
            defer {
                childEnd = childStart
            }
            guard case .node = childGreen else {
                continue
            }
            if let sibling = storage.arena.realizeChildNode(
                parent: parent,
                childIndex: index,
                childStartOffset: childStart
            ) {
                move(to: sibling)
                return true
            }
        }
        return false
    }

    private borrowing func withRawChildNode<R>(
        at childIndex: Int,
        childStartOffset: TextSize? = nil,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        guard let child = storage.arena.realizeChildNode(
            parent: record,
            childIndex: childIndex,
            childStartOffset: childStartOffset
        ) else {
            return nil
        }
        let cursor = SyntaxNodeCursor(storage: storage, record: child)
        return try body(cursor)
    }

    private borrowing func withRawChildOrToken<R>(
        parentRecord: RedNodeRecord<Lang>,
        at childIndex: Int,
        childStartOffset: TextSize? = nil,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        guard childIndex >= 0 && childIndex < parentRecord.green.childCount else {
            return nil
        }

        switch parentRecord.green.child(at: childIndex) {
        case .node:
            guard let child = storage.arena.realizeChildNode(
                parent: parentRecord,
                childIndex: childIndex,
                childStartOffset: childStartOffset
            ) else {
                return nil
            }
            let node = SyntaxNodeCursor(storage: storage, record: child)
            let element = SyntaxElementCursor<Lang>.node(node)
            return try body(element)
        case .token(let token):
            let token = SyntaxTokenCursor(
                storage: storage,
                parentRecord: parentRecord,
                childIndex: UInt32(childIndex),
                offset: parentRecord.offset + (childStartOffset ?? parentRecord.green.childStartOffset(at: childIndex)),
                green: token
            )
            let element = SyntaxElementCursor<Lang>.token(token)
            return try body(element)
        }
    }

    private borrowing func withRawChildOrToken<R>(
        at childIndex: Int,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let record = record
        return try withRawChildOrToken(parentRecord: record, at: childIndex, body)
    }

    /// Run `body` with a borrowed cursor on this node's parent, if any.
    /// Returns `nil` (and does not call `body`) when the cursor is at the
    /// tree root.
    public borrowing func withParent<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        guard let parent = record.parentRecord else {
            return nil
        }
        let cursor = SyntaxNodeCursor(storage: storage, record: parent)
        return try body(cursor)
    }

    /// Run `body` with a borrowed cursor on the `nodeIndex`-th node child
    /// (counting only nodes, skipping tokens). Returns `nil` when there
    /// is no such child.
    public borrowing func withChildNode<R>(
        at nodeIndex: Int,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        precondition(nodeIndex >= 0, "Node child index must not be negative")
        let green = record.green
        var seen = 0
        var childStart = TextSize.zero
        for childIndex in 0..<green.childCount {
            let childGreen = green.child(at: childIndex)
            defer {
                childStart = childStart + childGreen.textLength
            }
            guard case .node = childGreen else {
                continue
            }
            if seen == nodeIndex {
                return try withRawChildNode(at: childIndex, childStartOffset: childStart, body)
            }
            seen += 1
        }
        return nil
    }

    /// Run `body` with a borrowed cursor on the first node child. Returns
    /// `nil` when there is no node child.
    public borrowing func withFirstChild<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let green = record.green
        var childStart = TextSize.zero
        for childIndex in 0..<green.childCount {
            let childGreen = green.child(at: childIndex)
            defer {
                childStart = childStart + childGreen.textLength
            }
            guard case .node = childGreen else {
                continue
            }
            return try withRawChildNode(at: childIndex, childStartOffset: childStart, body)
        }
        return nil
    }

    /// Run `body` with a borrowed cursor on the last node child. Returns
    /// `nil` when there is no node child.
    public borrowing func withLastChild<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let green = record.green
        guard green.childCount > 0 else {
            return nil
        }
        var childEnd = green.textLength
        for childIndex in stride(from: green.childCount - 1, through: 0, by: -1) {
            let childGreen = green.child(at: childIndex)
            let childStart = childEnd - childGreen.textLength
            defer {
                childEnd = childStart
            }
            guard case .node = childGreen else {
                continue
            }
            return try withRawChildNode(at: childIndex, childStartOffset: childStart, body)
        }
        return nil
    }

    /// Run `body` with a borrowed element cursor on the `childIndex`-th
    /// child (counting both nodes and tokens). Returns `nil` for
    /// out-of-range indices.
    public borrowing func withChildOrToken<R>(
        at childIndex: Int,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        try withRawChildOrToken(at: childIndex, body)
    }

    /// Run `body` with a borrowed element cursor on the first child
    /// (counting nodes and tokens). Returns `nil` when there are no
    /// children.
    public borrowing func withFirstChildOrToken<R>(
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        guard childOrTokenCount > 0 else {
            return nil
        }
        return try withRawChildOrToken(parentRecord: record, at: 0, childStartOffset: .zero, body)
    }

    /// Run `body` with a borrowed element cursor on the last child
    /// (counting nodes and tokens). Returns `nil` when there are no
    /// children.
    public borrowing func withLastChildOrToken<R>(
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let count = childOrTokenCount
        guard count > 0 else {
            return nil
        }
        let record = record
        let childIndex = count - 1
        let child = record.green.child(at: childIndex)
        let childStart = record.green.textLength - child.textLength
        return try withRawChildOrToken(parentRecord: record, at: childIndex, childStartOffset: childStart, body)
    }

    /// Run `body` with a borrowed cursor on the next node sibling. Skips
    /// token siblings. Returns `nil` when there is no later node sibling.
    public borrowing func withNextSibling<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let current = record
        guard let parent = current.parentRecord else {
            return nil
        }
        let start = Int(current.indexInParent) + 1
        guard start < parent.green.childCount else {
            return nil
        }
        var childStart = (current.offset - parent.offset) + current.green.textLength
        for childIndex in start..<parent.green.childCount {
            let childGreen = parent.green.child(at: childIndex)
            defer {
                childStart = childStart + childGreen.textLength
            }
            guard case .node = childGreen,
                  let child = storage.arena.realizeChildNode(
                    parent: parent,
                    childIndex: childIndex,
                    childStartOffset: childStart
                  )
            else {
                continue
            }
            let cursor = SyntaxNodeCursor(storage: storage, record: child)
            return try body(cursor)
        }
        return nil
    }

    /// Run `body` with a borrowed cursor on the previous node sibling.
    /// Skips token siblings. Returns `nil` when there is no earlier node
    /// sibling.
    public borrowing func withPreviousSibling<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let current = record
        guard let parent = current.parentRecord, current.indexInParent > 0 else {
            return nil
        }
        var childEnd = current.offset - parent.offset
        for childIndex in stride(from: Int(current.indexInParent) - 1, through: 0, by: -1) {
            let childGreen = parent.green.child(at: childIndex)
            let childStart = childEnd - childGreen.textLength
            defer {
                childEnd = childStart
            }
            guard case .node = childGreen,
                  let child = storage.arena.realizeChildNode(
                    parent: parent,
                    childIndex: childIndex,
                    childStartOffset: childStart
                  )
            else {
                continue
            }
            let cursor = SyntaxNodeCursor(storage: storage, record: child)
            return try body(cursor)
        }
        return nil
    }

    /// Run `body` with a borrowed element cursor on the immediate next
    /// sibling, whether it is a node or a token. Returns `nil` when this
    /// node has no next sibling at all.
    public borrowing func withNextSiblingOrToken<R>(
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let current = record
        guard let parent = current.parentRecord else {
            return nil
        }
        let childIndex = Int(current.indexInParent) + 1
        let childStart = (current.offset - parent.offset) + current.green.textLength
        return try withRawChildOrToken(parentRecord: parent, at: childIndex, childStartOffset: childStart, body)
    }

    /// Run `body` with a borrowed element cursor on the immediate previous
    /// sibling, whether it is a node or a token. Returns `nil` when this
    /// node has no previous sibling at all.
    public borrowing func withPreviousSiblingOrToken<R>(
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let current = record
        guard let parent = current.parentRecord, current.indexInParent > 0 else {
            return nil
        }
        let childIndex = Int(current.indexInParent) - 1
        let child = parent.green.child(at: childIndex)
        let childStart = (current.offset - parent.offset) - child.textLength
        return try withRawChildOrToken(parentRecord: parent, at: childIndex, childStartOffset: childStart, body)
    }

    /// Visit every node child in source order. Skips token children.
    public borrowing func forEachChild(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> Void
    ) rethrows {
        let record = record
        let green = record.green
        var childStart = TextSize.zero
        for childIndex in 0..<green.childCount {
            let childGreen = green.child(at: childIndex)
            defer {
                childStart = childStart + childGreen.textLength
            }
            guard case .node = childGreen,
                  let child = storage.arena.realizeChildNode(
                    parent: record,
                    childIndex: childIndex,
                    childStartOffset: childStart
                  )
            else {
                continue
            }
            let cursor = SyntaxNodeCursor(storage: storage, record: child)
            try body(cursor)
        }
    }

    /// Visit every node sibling in `direction` order. Skips token
    /// siblings. When `includingSelf` is `true`, this cursor's node is
    /// visited first.
    public borrowing func forEachSibling(
        direction: TraversalDirection = .forward,
        includingSelf: Bool = false,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> Void
    ) rethrows {
        let current = record
        if includingSelf {
            try body(self)
        }

        guard let parent = current.parentRecord else {
            return
        }

        switch direction {
        case .forward:
            let start = Int(current.indexInParent) + 1
            guard start < parent.green.childCount else {
                return
            }
            var childStart = (current.offset - parent.offset) + current.green.textLength
            for childIndex in start..<parent.green.childCount {
                let childGreen = parent.green.child(at: childIndex)
                defer {
                    childStart = childStart + childGreen.textLength
                }
                guard case .node = childGreen,
                      let sibling = storage.arena.realizeChildNode(
                        parent: parent,
                        childIndex: childIndex,
                        childStartOffset: childStart
                      )
                else {
                    continue
                }
                let cursor = SyntaxNodeCursor(storage: storage, record: sibling)
                try body(cursor)
            }
        case .backward:
            guard current.indexInParent > 0 else {
                return
            }
            var childEnd = current.offset - parent.offset
            for childIndex in stride(from: Int(current.indexInParent) - 1, through: 0, by: -1) {
                let childGreen = parent.green.child(at: childIndex)
                let childStart = childEnd - childGreen.textLength
                defer {
                    childEnd = childStart
                }
                guard case .node = childGreen,
                      let sibling = storage.arena.realizeChildNode(
                        parent: parent,
                        childIndex: childIndex,
                        childStartOffset: childStart
                      )
                else {
                    continue
                }
                let cursor = SyntaxNodeCursor(storage: storage, record: sibling)
                try body(cursor)
            }
        }
    }

    /// Visit every sibling — both nodes and tokens — in `direction` order.
    /// When `includingSelf` is `true`, this cursor's node is yielded first
    /// as a ``SyntaxElementCursor/node(_:)`` element.
    public borrowing func forEachSiblingOrToken(
        direction: TraversalDirection = .forward,
        includingSelf: Bool = false,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> Void
    ) rethrows {
        let current = record
        if includingSelf {
            let node = SyntaxNodeCursor(storage: storage, record: current)
            let element = SyntaxElementCursor<Lang>.node(node)
            try body(element)
        }

        guard let parent = current.parentRecord else {
            return
        }

        switch direction {
        case .forward:
            let start = Int(current.indexInParent) + 1
            guard start < parent.green.childCount else {
                return
            }
            var childStart = (current.offset - parent.offset) + current.green.textLength
            for childIndex in start..<parent.green.childCount {
                let childGreen = parent.green.child(at: childIndex)
                defer {
                    childStart = childStart + childGreen.textLength
                }
                _ = try withRawChildOrToken(
                    parentRecord: parent,
                    at: childIndex,
                    childStartOffset: childStart
                ) { element in
                    try body(element)
                }
            }
        case .backward:
            guard current.indexInParent > 0 else {
                return
            }
            var childEnd = current.offset - parent.offset
            for childIndex in stride(from: Int(current.indexInParent) - 1, through: 0, by: -1) {
                let childGreen = parent.green.child(at: childIndex)
                let childStart = childEnd - childGreen.textLength
                defer {
                    childEnd = childStart
                }
                _ = try withRawChildOrToken(
                    parentRecord: parent,
                    at: childIndex,
                    childStartOffset: childStart
                ) { element in
                    try body(element)
                }
            }
        }
    }

    /// Visit every child — both nodes and tokens — in source order.
    public borrowing func forEachChildOrToken(
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> Void
    ) rethrows {
        let count = childOrTokenCount
        let record = record
        var childStart = TextSize.zero
        for index in 0..<count {
            let child = record.green.child(at: index)
            defer {
                childStart = childStart + child.textLength
            }
            _ = try withRawChildOrToken(
                parentRecord: record,
                at: index,
                childStartOffset: childStart
            ) { element in
                try body(element)
            }
        }
    }

    /// Visit every ancestor walking towards the root. When `includingSelf`
    /// is `true`, this cursor's node is visited first.
    public borrowing func forEachAncestor(
        includingSelf: Bool = false,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> Void
    ) rethrows {
        if includingSelf {
            try body(self)
        }

        var current = record
        while let parent = current.parentRecord {
            let cursor = SyntaxNodeCursor(storage: storage, record: parent)
            try body(cursor)
            current = parent
        }
    }

    /// Recursively visit every descendant node in depth-first preorder.
    /// Skips token leaves. When `includingSelf` is `true`, this cursor's
    /// node is visited first. Cannot be stopped early; use
    /// ``visitPreorder(_:)`` if you need that.
    public borrowing func forEachDescendant(
        includingSelf: Bool = false,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> Void
    ) rethrows {
        if includingSelf {
            try body(self)
        }

        let record = record
        var childStart = TextSize.zero
        for childIndex in 0..<record.green.childCount {
            let childGreen = record.green.child(at: childIndex)
            defer {
                childStart = childStart + childGreen.textLength
            }
            guard case .node = childGreen,
                  let childRecord = storage.arena.realizeChildNode(
                    parent: record,
                    childIndex: childIndex,
                    childStartOffset: childStart
                  )
            else {
                continue
            }
            let child = SyntaxNodeCursor(storage: storage, record: childRecord)
            try body(child)
            let descendant = SyntaxNodeCursor(storage: storage, record: childRecord)
            try descendant.forEachDescendant(includingSelf: false, body)
        }
    }

    /// Recursively visit every descendant — both nodes and tokens — in
    /// depth-first preorder. When `includingSelf` is `true`, this cursor's
    /// node is yielded first.
    public borrowing func forEachDescendantOrToken(
        includingSelf: Bool = false,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> Void
    ) rethrows {
        let record = record
        if includingSelf {
            let node = SyntaxNodeCursor(storage: storage, record: record)
            let element = SyntaxElementCursor<Lang>.node(node)
            try body(element)
        }

        var childStart = TextSize.zero
        for childIndex in 0..<record.green.childCount {
            let child = record.green.child(at: childIndex)
            defer {
                childStart = childStart + child.textLength
            }

            switch child {
            case .node:
                guard let childRecord = storage.arena.realizeChildNode(
                    parent: record,
                    childIndex: childIndex,
                    childStartOffset: childStart
                ) else {
                    continue
                }
                let node = SyntaxNodeCursor(storage: storage, record: childRecord)
                let element = SyntaxElementCursor<Lang>.node(node)
                try body(element)
                let descendant = SyntaxNodeCursor(storage: storage, record: childRecord)
                try descendant.forEachDescendantOrToken(includingSelf: false, body)
            case .token(let token):
                let token = SyntaxTokenCursor(
                    storage: storage,
                    parentRecord: record,
                    childIndex: UInt32(childIndex),
                    offset: record.offset + childStart,
                    green: token
                )
                let element = SyntaxElementCursor<Lang>.token(token)
                try body(element)
            }
        }
    }

    /// Depth-first preorder visit over node descendants. The closure
    /// returns a ``CambiumCore/TraversalControl`` to direct further traversal:
    /// `.continue` to descend, `.skipChildren` to skip the current
    /// subtree but continue with siblings, `.stop` to abandon traversal
    /// entirely.
    ///
    /// Returns `.stop` if the visitor stopped, `.continue` otherwise.
    public borrowing func visitPreorder(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> TraversalControl
    ) rethrows -> TraversalControl {
        switch try body(self) {
        case .continue:
            let record = record
            let green = record.green
            var childStart = TextSize.zero
            for childIndex in 0..<green.childCount {
                let childGreen = green.child(at: childIndex)
                defer {
                    childStart = childStart + childGreen.textLength
                }
                guard case .node = childGreen,
                      let childRecord = storage.arena.realizeChildNode(
                        parent: record,
                        childIndex: childIndex,
                        childStartOffset: childStart
                      )
                else {
                    continue
                }
                let child = SyntaxNodeCursor(storage: storage, record: childRecord)
                if try child.visitPreorder(body) == .stop {
                    return .stop
                }
            }
            return .continue
        case .skipChildren:
            return .continue
        case .stop:
            return .stop
        }
    }

    /// Like ``visitPreorder(_:)`` but fires both `enter` and `leave`
    /// events for every node. Useful when you need to do work on the way
    /// up the tree as well as on the way down — building indented output,
    /// for example. See ``CambiumCore/SyntaxNodeWalkEvent``.
    public borrowing func walkPreorder(
        _ body: (borrowing SyntaxNodeWalkEvent<Lang>) throws -> TraversalControl
    ) rethrows -> TraversalControl {
        let record = record
        let enterNode = SyntaxNodeCursor(storage: storage, record: record)
        let enterEvent = SyntaxNodeWalkEvent<Lang>.enter(enterNode)
        let enterControl = try body(enterEvent)
        switch enterControl {
        case .continue:
            var childStart = TextSize.zero
            for childIndex in 0..<record.green.childCount {
                let childGreen = record.green.child(at: childIndex)
                defer {
                    childStart = childStart + childGreen.textLength
                }
                guard case .node = childGreen,
                      let childRecord = storage.arena.realizeChildNode(
                        parent: record,
                        childIndex: childIndex,
                        childStartOffset: childStart
                      )
                else {
                    continue
                }
                let child = SyntaxNodeCursor(storage: storage, record: childRecord)
                if try child.walkPreorder(body) == .stop {
                    return .stop
                }
            }
        case .skipChildren:
            break
        case .stop:
            return .stop
        }

        let leaveNode = SyntaxNodeCursor(storage: storage, record: record)
        let leaveEvent = SyntaxNodeWalkEvent<Lang>.leave(leaveNode)
        switch try body(leaveEvent) {
        case .continue, .skipChildren:
            return .continue
        case .stop:
            return .stop
        }
    }

    private borrowing func walkTokenPreorder(
        at childIndex: Int,
        childStartOffset: TextSize,
        token: GreenToken<Lang>,
        parentRecord: RedNodeRecord<Lang>,
        _ body: (borrowing SyntaxElementWalkEvent<Lang>) throws -> TraversalControl
    ) rethrows -> TraversalControl {
        let childOffset = parentRecord.offset + childStartOffset
        let enterToken = SyntaxTokenCursor(
            storage: storage,
            parentRecord: parentRecord,
            childIndex: UInt32(childIndex),
            offset: childOffset,
            green: token
        )
        let enterElement = SyntaxElementCursor<Lang>.token(enterToken)
        let enterEvent = SyntaxElementWalkEvent<Lang>.enter(enterElement)
        switch try body(enterEvent) {
        case .continue, .skipChildren:
            break
        case .stop:
            return .stop
        }

        let leaveToken = SyntaxTokenCursor(
            storage: storage,
            parentRecord: parentRecord,
            childIndex: UInt32(childIndex),
            offset: childOffset,
            green: token
        )
        let leaveElement = SyntaxElementCursor<Lang>.token(leaveToken)
        let leaveEvent = SyntaxElementWalkEvent<Lang>.leave(leaveElement)
        switch try body(leaveEvent) {
        case .continue, .skipChildren:
            return .continue
        case .stop:
            return .stop
        }
    }

    /// Like ``walkPreorder(_:)`` but also fires `enter`/`leave` events for
    /// tokens. See ``CambiumCore/SyntaxElementWalkEvent``. For tokens, `enter` and
    /// `leave` always fire back-to-back since tokens are leaves.
    public borrowing func walkPreorderWithTokens(
        _ body: (borrowing SyntaxElementWalkEvent<Lang>) throws -> TraversalControl
    ) rethrows -> TraversalControl {
        let record = record
        let enterNode = SyntaxNodeCursor(storage: storage, record: record)
        let enterElement = SyntaxElementCursor<Lang>.node(enterNode)
        let enterEvent = SyntaxElementWalkEvent<Lang>.enter(enterElement)
        let enterControl = try body(enterEvent)
        switch enterControl {
        case .continue:
            var childStart = TextSize.zero
            for childIndex in 0..<record.green.childCount {
                let child = record.green.child(at: childIndex)
                defer {
                    childStart = childStart + child.textLength
                }

                switch child {
                case .node:
                    guard let childRecord = storage.arena.realizeChildNode(
                        parent: record,
                        childIndex: childIndex,
                        childStartOffset: childStart
                    ) else {
                        continue
                    }
                    let child = SyntaxNodeCursor(storage: storage, record: childRecord)
                    if try child.walkPreorderWithTokens(body) == .stop {
                        return .stop
                    }
                case .token(let token):
                    if try walkTokenPreorder(
                        at: childIndex,
                        childStartOffset: childStart,
                        token: token,
                        parentRecord: record,
                        body
                    ) == .stop {
                        return .stop
                    }
                }
            }
        case .skipChildren:
            break
        case .stop:
            return .stop
        }

        let leaveNode = SyntaxNodeCursor(storage: storage, record: record)
        let leaveElement = SyntaxElementCursor<Lang>.node(leaveNode)
        let leaveEvent = SyntaxElementWalkEvent<Lang>.leave(leaveElement)
        switch try body(leaveEvent) {
        case .continue, .skipChildren:
            return .continue
        case .stop:
            return .stop
        }
    }

    /// Visit every token in this subtree, optionally filtered to those
    /// whose range overlaps `range`.
    ///
    /// Tokens are yielded in source order. Empty ranges (zero-length
    /// tokens at the boundary of `range`) are included when their offset
    /// lies inside `range`. The shape `range == nil` visits every token in
    /// the subtree.
    public borrowing func tokens(
        in range: TextRange? = nil,
        _ body: (borrowing SyntaxTokenCursor<Lang>) throws -> Void
    ) rethrows {
        if let range, !range.includesElement(textRange) {
            return
        }

        let record = record
        var childStart = TextSize.zero
        for index in 0..<record.green.childCount {
            let child = record.green.child(at: index)
            let absoluteChildStart = record.offset + childStart
            let childRange = TextRange(start: absoluteChildStart, length: child.textLength)
            defer {
                childStart = childStart + child.textLength
            }
            if let range, !range.includesElement(childRange) {
                continue
            }

            switch child {
            case .node:
                guard let childRecord = storage.arena.realizeChildNode(
                    parent: record,
                    childIndex: index,
                    childStartOffset: childStart
                ) else {
                    continue
                }
                let cursor = SyntaxNodeCursor(storage: storage, record: childRecord)
                try cursor.tokens(in: range, body)
            case .token(let token):
                let cursor = SyntaxTokenCursor(
                    storage: storage,
                    parentRecord: record,
                    childIndex: UInt32(index),
                    offset: absoluteChildStart,
                    green: token
                )
                try body(cursor)
            }
        }
    }

    /// Find the token(s) at `offset` in this subtree.
    ///
    /// Exactly one of `none`, `single`, or `between` is invoked, and its
    /// return value is returned from this method:
    ///
    /// - `none` runs when the offset is outside the subtree's range or the
    ///   subtree has no tokens.
    /// - `single` runs when one token is "at" the offset: the offset is
    ///   strictly inside a token, or sits at the very start of the first
    ///   token (no left neighbor), or at the very end of the last token
    ///   (no right neighbor), or a zero-length token sits at that exact
    ///   offset (taking precedence over any non-zero neighbors).
    /// - `between` runs when the offset lies exactly between two
    ///   non-zero-length tokens, with `left.textRange.end == offset ==
    ///   right.textRange.start`.
    ///
    /// The three-closure shape is a workaround for a Swift compiler bug
    /// affecting pattern-matching of multi-payload `~Copyable` enum cases;
    /// see the `TokenLocation` comment block above for context. When that
    /// bug is fixed this should become a single body taking a
    /// `TokenAtOffset<Lang>: ~Copyable` enum.
    public borrowing func withTokenAtOffset<R>(
        _ offset: TextSize,
        none: () throws -> R,
        single: (borrowing SyntaxTokenCursor<Lang>) throws -> R,
        between: (borrowing SyntaxTokenCursor<Lang>, borrowing SyntaxTokenCursor<Lang>) throws -> R
    ) rethrows -> R {
        guard textRange.containsAllowingEnd(offset) else {
            return try none()
        }

        let right = findTokenLocation(at: offset)
        let left: TokenLocation<Lang>? = offset > .zero
            ? findTokenLocation(at: offset - TextSize(1))
            : nil

        switch (left, right) {
        case (nil, nil):
            return try none()

        case (nil, let r?):
            let cursor = makeTokenCursor(from: r)
            return try single(cursor)

        case (let l?, nil):
            let cursor = makeTokenCursor(from: l)
            return try single(cursor)

        case (let l?, let r?):
            // A zero-length token at offset wins over any boundary classification.
            if r.green.textLength == .zero {
                let cursor = makeTokenCursor(from: r)
                return try single(cursor)
            }
            // Same token: strictly inside one token (left and right both fell
            // into the same token).
            if l.parentRecord === r.parentRecord && l.childIndex == r.childIndex {
                let cursor = makeTokenCursor(from: r)
                return try single(cursor)
            }
            // Different tokens. Boundary case requires left.end == offset == right.start.
            let leftEnd = l.offset + l.green.textLength
            if leftEnd == offset && r.offset == offset {
                let leftCursor = makeTokenCursor(from: l)
                let rightCursor = makeTokenCursor(from: r)
                return try between(leftCursor, rightCursor)
            }
            // Otherwise we're inside `right` (right.start < offset); `left` was
            // an adjacent token at offset-1 that doesn't share a boundary at
            // offset. Defensive — shouldn't arise in well-formed trees.
            let cursor = makeTokenCursor(from: r)
            return try single(cursor)
        }
    }

    /// Depth-first search for a token at `offset`. Returns the first matching
    /// token in iteration order, descending into node children that may
    /// contain a deeper match. Right-leaning at boundaries by virtue of
    /// iteration order; zero-length tokens at the offset always win.
    ///
    /// **Why nodes and tokens use different containment checks** — node
    /// descent uses `containsAllowingEnd` (the offset can equal the
    /// child's `end`), while token matching uses strict `contains` plus
    /// an explicit zero-length-at-offset clause. A non-zero-length token
    /// whose range ends at `offset` does not actually contain `offset`,
    /// so it is not a match. But that token's parent node's range *also*
    /// ends at `offset`, and a zero-length token may sit at the parent's
    /// right boundary as a sibling of the non-zero token. The asymmetry
    /// is what lets us descend into the parent and find that zero-length
    /// descendant; without it, lookup would fall through to the next
    /// top-level sibling and miss the nested zero-length match. If you
    /// simplify both branches to use the same check you will reintroduce
    /// the regression covered by `tokenAtOffsetFindsNestedZeroLengthTokenAtChildEnd`.
    private borrowing func findTokenLocation(at offset: TextSize) -> TokenLocation<Lang>? {
        guard textRange.containsAllowingEnd(offset) else {
            return nil
        }

        let record = record
        var childStart = TextSize.zero
        for index in 0..<record.green.childCount {
            let child = record.green.child(at: index)
            let absoluteChildStart = record.offset + childStart
            let childRange = TextRange(start: absoluteChildStart, length: child.textLength)
            defer {
                childStart = childStart + child.textLength
            }

            switch child {
            case .node:
                guard childRange.containsAllowingEnd(offset) else {
                    continue
                }
                guard let childRecord = storage.arena.realizeChildNode(
                    parent: record,
                    childIndex: index,
                    childStartOffset: childStart
                ) else {
                    continue
                }
                let childCursor = SyntaxNodeCursor(storage: storage, record: childRecord)
                if let found = childCursor.findTokenLocation(at: offset) {
                    return found
                }
            case .token(let token):
                let contains = childRange.contains(offset)
                    || (childRange.isEmpty && childRange.start == offset)
                guard contains else {
                    continue
                }
                return TokenLocation(
                    parentRecord: record,
                    childIndex: UInt32(index),
                    offset: absoluteChildStart,
                    green: token
                )
            }
        }
        return nil
    }

    private borrowing func makeTokenCursor(from location: TokenLocation<Lang>) -> SyntaxTokenCursor<Lang> {
        SyntaxTokenCursor(
            storage: storage,
            parentRecord: location.parentRecord,
            childIndex: location.childIndex,
            offset: location.offset,
            green: location.green
        )
    }

    /// Find the smallest element (node or token) whose range fully covers
    /// `range`, and run `body` with a borrowed element cursor on it.
    ///
    /// Returns `nil` (and does not call `body`) when `range` is not
    /// contained in this subtree. Useful for "what surrounds this
    /// selection?" editor queries.
    public borrowing func withCoveringElement<R>(
        _ range: TextRange,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        guard textRange.contains(range) else {
            return nil
        }

        let record = record
        var childStart = TextSize.zero
        for index in 0..<record.green.childCount {
            let child = record.green.child(at: index)
            let absoluteChildStart = record.offset + childStart
            let childRange = TextRange(start: absoluteChildStart, length: child.textLength)
            defer {
                childStart = childStart + child.textLength
            }
            guard childRange.contains(range) else {
                continue
            }

            switch child {
            case .node:
                guard let childRecord = storage.arena.realizeChildNode(
                    parent: record,
                    childIndex: index,
                    childStartOffset: childStart
                ) else {
                    continue
                }
                let cursor = SyntaxNodeCursor(storage: storage, record: childRecord)
                return try cursor.withCoveringElement(range, body)
            case .token(let token):
                let cursor = SyntaxTokenCursor(
                    storage: storage,
                    parentRecord: record,
                    childIndex: UInt32(index),
                    offset: absoluteChildStart,
                    green: token
                )
                let element = SyntaxElementCursor<Lang>.token(cursor)
                return try body(element)
            }
        }

        let node = SyntaxNodeCursor(storage: storage, record: record)
        let element = SyntaxElementCursor<Lang>.node(node)
        return try body(element)
    }

    /// Run `body` with a borrowed ``CambiumCore/SyntaxText`` view over this node's
    /// source text. The view does not allocate; use it for byte-level
    /// scans, equality checks, slicing.
    public borrowing func withText<R>(
        _ body: (borrowing SyntaxText<Lang>) throws -> R
    ) rethrows -> R {
        let text = SyntaxText(root: record.green, resolver: storage.resolver)
        return try body(text)
    }

    /// Allocate and return this node's source text as a `String`. For
    /// hot-path scans, prefer ``withText(_:)``.
    public borrowing func makeString() -> String {
        record.green.makeString(using: storage.resolver)
    }

    /// Promote this borrowed cursor to a copyable, retained
    /// ``CambiumCore/SyntaxNodeHandle`` you can store across borrow scopes.
    public borrowing func makeHandle() -> SyntaxNodeHandle<Lang> {
        SyntaxNodeHandle(storage: storage, record: record)
    }

    /// The sequence of green child-slot indices from the root to this
    /// node. Each index identifies the slot the path takes within its
    /// parent's full child list (counting both nodes and tokens). Use
    /// with ``withDescendant(atPath:_:)`` to re-locate this node in a
    /// later tree version, after consulting a witness chain to confirm
    /// the path is still valid.
    public borrowing func childIndexPath() -> [UInt32] {
        var path: [UInt32] = []
        var current = record
        while let parent = current.parentRecord {
            path.append(current.indexInParent)
            current = parent
        }
        return path.reversed()
    }

    /// Run `body` with a borrowed cursor on the descendant at `path`
    /// (interpreted relative to this cursor). Returns `nil` if the path
    /// goes through a token slot or otherwise leaves the tree.
    public borrowing func withDescendant<R>(
        atPath path: [UInt32],
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        if path.isEmpty {
            return try body(self)
        }

        var cursor = SyntaxNodeCursor(storage: storage, record: record)
        for rawIndex in path {
            guard let childRecord = storage.arena.realizeChildNode(
                parent: cursor.record,
                childIndex: Int(rawIndex)
            ) else {
                return nil
            }
            cursor.move(to: childRecord)
        }
        return try body(cursor)
    }

}

/// A non-owning, non-copyable cursor that points at one token in a syntax
/// tree.
///
/// The token analogue of ``CambiumCore/SyntaxNodeCursor``. Tokens are leaves and never
/// realized as red nodes; a token cursor instead carries a borrowed
/// reference to its parent's red record plus the token's child index and
/// absolute offset.
///
/// ## Topics
///
/// ### Inspecting
/// - ``identity``
/// - ``rawKind``
/// - ``kind``
/// - ``textRange``
/// - ``textLength``
///
/// ### Navigating
/// - ``withParent(_:)``
/// - ``withNextSiblingOrToken(_:)``
/// - ``withPreviousSiblingOrToken(_:)``
/// - ``forEachAncestor(_:)``
/// - ``forEachSiblingOrToken(direction:includingSelf:_:)``
///
/// ### Reading text
/// - ``withTextUTF8(_:)``
/// - ``makeString()``
///
/// ### Crossing borrow scopes
/// - ``makeHandle()``
public struct SyntaxTokenCursor<Lang: SyntaxLanguage>: ~Copyable {
    private let storageRef: Unmanaged<SyntaxTreeStorage<Lang>>
    private let parentRef: Unmanaged<RedNodeRecord<Lang>>
    internal let childIndex: UInt32
    internal let offset: TextSize
    internal let green: GreenToken<Lang>

    internal init(
        storage: SyntaxTreeStorage<Lang>,
        parentRecord: RedNodeRecord<Lang>,
        childIndex: UInt32,
        offset: TextSize,
        green: GreenToken<Lang>
    ) {
        self.storageRef = Unmanaged.passUnretained(storage)
        self.parentRef = Unmanaged.passUnretained(parentRecord)
        self.childIndex = childIndex
        self.offset = offset
        self.green = green
    }

    internal var storage: SyntaxTreeStorage<Lang> {
        storageRef.takeUnretainedValue()
    }

    internal var parentRecord: RedNodeRecord<Lang> {
        parentRef.takeUnretainedValue()
    }

    internal var parent: RedNodeID {
        parentRecord.id
    }

    /// The value-typed identity of the token under this cursor.
    public var identity: SyntaxTokenIdentity {
        SyntaxTokenIdentity(
            treeID: storage.treeID,
            parentID: parent,
            childIndexInParent: childIndex
        )
    }

    /// The language-agnostic kind of the token.
    public var rawKind: RawSyntaxKind {
        green.rawKind
    }

    /// The typed kind of the token.
    public var kind: Lang.Kind {
        green.kind
    }

    /// The byte range of the token within the source document.
    public var textRange: TextRange {
        TextRange(start: offset, length: green.textLength)
    }

    /// The UTF-8 byte length of the token's text.
    public var textLength: TextSize {
        green.textLength
    }

    /// Run `body` with a borrowed cursor on the token's parent node.
    public borrowing func withParent<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R {
        let cursor = SyntaxNodeCursor(storage: storage, record: parentRecord)
        return try body(cursor)
    }

    private borrowing func withSiblingOrToken<R>(
        at siblingIndex: Int,
        childStartOffset: TextSize? = nil,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let parentRecord = parentRecord
        guard siblingIndex >= 0 && siblingIndex < parentRecord.green.childCount else {
            return nil
        }

        switch parentRecord.green.child(at: siblingIndex) {
        case .node:
            guard let child = storage.arena.realizeChildNode(
                parent: parentRecord,
                childIndex: siblingIndex,
                childStartOffset: childStartOffset
            ) else {
                return nil
            }
            let node = SyntaxNodeCursor(storage: storage, record: child)
            let element = SyntaxElementCursor<Lang>.node(node)
            return try body(element)
        case .token(let token):
            let token = SyntaxTokenCursor(
                storage: storage,
                parentRecord: parentRecord,
                childIndex: UInt32(siblingIndex),
                offset: parentRecord.offset + (childStartOffset ?? parentRecord.green.childStartOffset(at: siblingIndex)),
                green: token
            )
            let element = SyntaxElementCursor<Lang>.token(token)
            return try body(element)
        }
    }

    /// Run `body` with a borrowed element cursor on the immediate next
    /// sibling, whether it is a node or a token. Returns `nil` when the
    /// token has no next sibling.
    public borrowing func withNextSiblingOrToken<R>(
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let nextStart = (offset - parentRecord.offset) + green.textLength
        return try withSiblingOrToken(at: Int(childIndex) + 1, childStartOffset: nextStart, body)
    }

    /// Run `body` with a borrowed element cursor on the immediate previous
    /// sibling, whether it is a node or a token. Returns `nil` when the
    /// token has no previous sibling.
    public borrowing func withPreviousSiblingOrToken<R>(
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let siblingIndex = Int(childIndex) - 1
        guard siblingIndex >= 0 else {
            return nil
        }
        let sibling = parentRecord.green.child(at: siblingIndex)
        let siblingStart = (offset - parentRecord.offset) - sibling.textLength
        return try withSiblingOrToken(at: siblingIndex, childStartOffset: siblingStart, body)
    }

    /// Visit every ancestor walking from the parent up to the root.
    public borrowing func forEachAncestor(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> Void
    ) rethrows {
        var current = parentRecord
        while true {
            let cursor = SyntaxNodeCursor(storage: storage, record: current)
            try body(cursor)

            guard let parent = current.parentRecord else {
                return
            }
            current = parent
        }
    }

    /// Visit every sibling — both nodes and tokens — in `direction` order.
    /// When `includingSelf` is `true`, this token is yielded first as a
    /// ``SyntaxElementCursor/token(_:)`` element.
    public borrowing func forEachSiblingOrToken(
        direction: TraversalDirection = .forward,
        includingSelf: Bool = false,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> Void
    ) rethrows {
        let parentRecord = parentRecord
        if includingSelf {
            let token = SyntaxTokenCursor(
                storage: storage,
                parentRecord: parentRecord,
                childIndex: childIndex,
                offset: offset,
                green: green
            )
            let element = SyntaxElementCursor<Lang>.token(token)
            try body(element)
        }

        switch direction {
        case .forward:
            let start = Int(childIndex) + 1
            guard start < parentRecord.green.childCount else {
                return
            }
            var childStart = (offset - parentRecord.offset) + green.textLength
            for siblingIndex in start..<parentRecord.green.childCount {
                let child = parentRecord.green.child(at: siblingIndex)
                defer {
                    childStart = childStart + child.textLength
                }
                _ = try withSiblingOrToken(at: siblingIndex, childStartOffset: childStart) { element in
                    try body(element)
                }
            }
        case .backward:
            guard childIndex > 0 else {
                return
            }
            var childEnd = offset - parentRecord.offset
            for siblingIndex in stride(from: Int(childIndex) - 1, through: 0, by: -1) {
                let child = parentRecord.green.child(at: siblingIndex)
                let childStart = childEnd - child.textLength
                defer {
                    childEnd = childStart
                }
                _ = try withSiblingOrToken(at: siblingIndex, childStartOffset: childStart) { element in
                    try body(element)
                }
            }
        }
    }

    /// Call `body` with the token's UTF-8 bytes. The buffer is valid only
    /// for the duration of the closure. Empty for missing tokens.
    public borrowing func withTextUTF8<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) throws -> R {
        try green.withTextUTF8(using: storage.resolver, body)
    }

    /// Allocate and return the token's source text as a `String`.
    public borrowing func makeString() -> String {
        green.makeString(using: storage.resolver)
    }

    /// Promote this borrowed cursor to a copyable, retained
    /// ``CambiumCore/SyntaxTokenHandle`` you can store across borrow scopes.
    public borrowing func makeHandle() -> SyntaxTokenHandle<Lang> {
        SyntaxTokenHandle(
            storage: storage,
            parentRecord: parentRecord,
            childIndex: childIndex,
            offset: offset
        )
    }
}

/// Either a ``CambiumCore/SyntaxNodeCursor`` or a ``CambiumCore/SyntaxTokenCursor`` — the
/// homogeneous element type used by `*OrToken` traversals.
///
/// Pattern-match to specialize on node-vs-token; ``rawKind`` and
/// ``textRange`` answer the questions both variants have in common.
public enum SyntaxElementCursor<Lang: SyntaxLanguage>: ~Copyable {
    /// A node-shaped element.
    case node(SyntaxNodeCursor<Lang>)

    /// A token-shaped element.
    case token(SyntaxTokenCursor<Lang>)

    /// The language-agnostic kind of this element.
    public var rawKind: RawSyntaxKind {
        switch self {
        case .node(let node):
            node.rawKind
        case .token(let token):
            token.rawKind
        }
    }

    /// The byte range of this element within the source document.
    public var textRange: TextRange {
        switch self {
        case .node(let node):
            node.textRange
        case .token(let token):
            token.textRange
        }
    }
}

private extension TextRange {
    /// Half-open inclusion test for `tokens(in:)`. Empty candidates are
    /// included only when their offset lies strictly inside `self` —
    /// matching the half-open behavior `intersects` already gives for
    /// non-empty candidates and the zero-length-at-offset clause used by
    /// `findTokenLocation`. Without this, `intersects` undershoots at the
    /// left boundary for empty candidates (`[X, X).intersects([X, X+n))`
    /// is false), and a naive `!isEmpty` bandaid leaks zero-length
    /// candidates everywhere into the result.
    func includesElement(_ candidate: TextRange) -> Bool {
        if candidate.isEmpty {
            return contains(candidate.start)
        } else {
            return intersects(candidate)
        }
    }
}
