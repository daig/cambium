import Synchronization

public struct TreeID: RawRepresentable, Sendable, Hashable, Comparable {
    public let rawValue: UInt64

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

public struct RedNodeID: RawRepresentable, Sendable, Hashable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: RedNodeID, rhs: RedNodeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct SyntaxNodeIdentity: Sendable, Hashable {
    public let treeID: TreeID
    public let nodeID: RedNodeID

    public init(treeID: TreeID, nodeID: RedNodeID) {
        self.treeID = treeID
        self.nodeID = nodeID
    }
}

public struct SyntaxTokenIdentity: Sendable, Hashable {
    public let treeID: TreeID
    public let parentID: RedNodeID
    public let childIndexInParent: UInt32

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

public final class SyntaxTreeStorage<Lang: SyntaxLanguage>: @unchecked Sendable {
    public let treeID: TreeID
    public let rootGreen: GreenNode<Lang>
    public let resolver: any TokenResolver
    let arena: RedArena<Lang>

    public init(rootGreen: GreenNode<Lang>, resolver: any TokenResolver) {
        self.treeID = TreeIDGenerator.make()
        self.rootGreen = rootGreen
        self.resolver = resolver
        self.arena = RedArena(root: rootGreen)
    }
}

public struct SyntaxTree<Lang: SyntaxLanguage>: ~Copyable, Sendable {
    internal let storage: SyntaxTreeStorage<Lang>

    public init(root: GreenNode<Lang>, resolver: any TokenResolver = TokenTextSnapshot()) {
        self.storage = SyntaxTreeStorage(rootGreen: root, resolver: resolver)
    }

    public var treeID: TreeID {
        storage.treeID
    }

    public var rootGreen: GreenNode<Lang> {
        storage.rootGreen
    }

    public var resolver: any TokenResolver {
        storage.resolver
    }

    public borrowing func withRoot<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R {
        let cursor = SyntaxNodeCursor(storage: storage, record: storage.arena.rootRecord)
        return try body(cursor)
    }

    public borrowing func share() -> SharedSyntaxTree<Lang> {
        SharedSyntaxTree(storage: storage)
    }

    public consuming func intoShared() -> SharedSyntaxTree<Lang> {
        SharedSyntaxTree(storage: storage)
    }
}

public struct SharedSyntaxTree<Lang: SyntaxLanguage>: Sendable {
    internal let storage: SyntaxTreeStorage<Lang>

    public init(storage: SyntaxTreeStorage<Lang>) {
        self.storage = storage
    }

    public var treeID: TreeID {
        storage.treeID
    }

    public var rootGreen: GreenNode<Lang> {
        storage.rootGreen
    }

    public var resolver: any TokenResolver {
        storage.resolver
    }

    public func withRoot<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R {
        let cursor = SyntaxNodeCursor(storage: storage, record: storage.arena.rootRecord)
        return try body(cursor)
    }

    public func rootHandle() -> SyntaxNodeHandle<Lang> {
        SyntaxNodeHandle(storage: storage, record: storage.arena.rootRecord)
    }

}

public struct SyntaxNodeHandle<Lang: SyntaxLanguage>: Sendable, Hashable {
    internal let storage: SyntaxTreeStorage<Lang>
    internal let record: RedNodeRecord<Lang>

    internal var id: RedNodeID {
        record.id
    }

    public var identity: SyntaxNodeIdentity {
        SyntaxNodeIdentity(treeID: storage.treeID, nodeID: id)
    }

    public var rawKind: RawSyntaxKind {
        record.green.rawKind
    }

    public var textRange: TextRange {
        return TextRange(start: record.offset, length: record.green.textLength)
    }

    public func withCursor<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R {
        let cursor = SyntaxNodeCursor(storage: storage, record: record)
        return try body(cursor)
    }

    public static func == (lhs: SyntaxNodeHandle<Lang>, rhs: SyntaxNodeHandle<Lang>) -> Bool {
        lhs.storage.treeID == rhs.storage.treeID && lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage.treeID)
        hasher.combine(id)
    }
}

public struct SyntaxTokenHandle<Lang: SyntaxLanguage>: Sendable, Hashable {
    internal let storage: SyntaxTreeStorage<Lang>
    internal let parentRecord: RedNodeRecord<Lang>
    internal let childIndex: UInt32
    internal let offset: TextSize

    internal var parent: RedNodeID {
        parentRecord.id
    }

    public var identity: SyntaxTokenIdentity {
        SyntaxTokenIdentity(
            treeID: storage.treeID,
            parentID: parent,
            childIndexInParent: childIndex
        )
    }

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

public enum TraversalControl: Sendable, Hashable {
    case `continue`
    case skipChildren
    case stop
}

public enum TraversalDirection: Sendable, Hashable {
    case forward
    case backward
}

public enum SyntaxNodeWalkEvent<Lang: SyntaxLanguage>: ~Copyable {
    case enter(SyntaxNodeCursor<Lang>)
    case leave(SyntaxNodeCursor<Lang>)
}

public enum SyntaxElementWalkEvent<Lang: SyntaxLanguage>: ~Copyable {
    case enter(SyntaxElementCursor<Lang>)
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

    public var identity: SyntaxNodeIdentity {
        SyntaxNodeIdentity(treeID: storage.treeID, nodeID: id)
    }

    public var rawKind: RawSyntaxKind {
        record.green.rawKind
    }

    public var kind: Lang.Kind {
        Lang.kind(for: rawKind)
    }

    public var textRange: TextRange {
        let record = record
        return TextRange(start: record.offset, length: record.green.textLength)
    }

    public var textLength: TextSize {
        record.green.textLength
    }

    public var childCount: Int {
        record.green.nodeChildCount
    }

    public var childOrTokenCount: Int {
        record.green.childCount
    }

    public var greenHash: UInt64 {
        record.green.structuralHash
    }

    public var rootGreen: GreenNode<Lang> {
        storage.rootGreen
    }

    public var resolver: any TokenResolver {
        storage.resolver
    }

    public borrowing func green<R>(
        _ body: (borrowing GreenNode<Lang>) throws -> R
    ) rethrows -> R {
        try body(record.green)
    }

    public mutating func moveToParent() -> Bool {
        guard let parent = record.parentRecord else {
            return false
        }
        move(to: parent)
        return true
    }

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

    public borrowing func withParent<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        guard let parent = record.parentRecord else {
            return nil
        }
        let cursor = SyntaxNodeCursor(storage: storage, record: parent)
        return try body(cursor)
    }

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

    public borrowing func withChildOrToken<R>(
        at childIndex: Int,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        try withRawChildOrToken(at: childIndex, body)
    }

    public borrowing func withFirstChildOrToken<R>(
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        guard childOrTokenCount > 0 else {
            return nil
        }
        return try withRawChildOrToken(parentRecord: record, at: 0, childStartOffset: .zero, body)
    }

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

    public borrowing func visitPreorder(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> TraversalControl
    ) rethrows -> TraversalControl {
        switch try body(self) {
        case .continue:
            var shouldStop = false
            try forEachChild { child in
                if try child.visitPreorder(body) == .stop {
                    shouldStop = true
                }
            }
            return shouldStop ? .stop : .continue
        case .skipChildren:
            return .continue
        case .stop:
            return .stop
        }
    }

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

    public borrowing func tokens(
        in range: TextRange? = nil,
        _ body: (borrowing SyntaxTokenCursor<Lang>) throws -> Void
    ) rethrows {
        if let range, !textRange.intersects(range), !textRange.isEmpty {
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
            if let range, !childRange.intersects(range), !childRange.isEmpty {
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

    public borrowing func withText<R>(
        _ body: (borrowing SyntaxText<Lang>) throws -> R
    ) rethrows -> R {
        let text = SyntaxText(root: record.green, resolver: storage.resolver)
        return try body(text)
    }

    public borrowing func makeString() -> String {
        record.green.makeString(using: storage.resolver)
    }

    public borrowing func makeHandle() -> SyntaxNodeHandle<Lang> {
        SyntaxNodeHandle(storage: storage, record: record)
    }

    public borrowing func childIndexPath() -> [UInt32] {
        var path: [UInt32] = []
        var current = record
        while let parent = current.parentRecord {
            path.append(current.indexInParent)
            current = parent
        }
        return path.reversed()
    }

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

    public var identity: SyntaxTokenIdentity {
        SyntaxTokenIdentity(
            treeID: storage.treeID,
            parentID: parent,
            childIndexInParent: childIndex
        )
    }

    public var rawKind: RawSyntaxKind {
        green.rawKind
    }

    public var kind: Lang.Kind {
        green.kind
    }

    public var textRange: TextRange {
        TextRange(start: offset, length: green.textLength)
    }

    public var textLength: TextSize {
        green.textLength
    }

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

    public borrowing func withNextSiblingOrToken<R>(
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let nextStart = (offset - parentRecord.offset) + green.textLength
        return try withSiblingOrToken(at: Int(childIndex) + 1, childStartOffset: nextStart, body)
    }

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

    public borrowing func withTextUTF8<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) throws -> R {
        try green.withTextUTF8(using: storage.resolver, body)
    }

    public borrowing func makeString() -> String {
        green.makeString(using: storage.resolver)
    }

    public borrowing func makeHandle() -> SyntaxTokenHandle<Lang> {
        SyntaxTokenHandle(
            storage: storage,
            parentRecord: parentRecord,
            childIndex: childIndex,
            offset: offset
        )
    }
}

public enum SyntaxElementCursor<Lang: SyntaxLanguage>: ~Copyable {
    case node(SyntaxNodeCursor<Lang>)
    case token(SyntaxTokenCursor<Lang>)

    public var rawKind: RawSyntaxKind {
        switch self {
        case .node(let node):
            node.rawKind
        case .token(let token):
            token.rawKind
        }
    }

    public var textRange: TextRange {
        switch self {
        case .node(let node):
            node.textRange
        case .token(let token):
            token.textRange
        }
    }
}
