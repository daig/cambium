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

public struct SyntaxAnchor<Lang: SyntaxLanguage>: Sendable, Hashable {
    public let originalTreeID: TreeID
    public let path: [UInt32]
    public let range: TextRange
    public let rawKind: RawSyntaxKind
    public let greenHash: UInt64

    public init(
        originalTreeID: TreeID,
        path: [UInt32],
        range: TextRange,
        rawKind: RawSyntaxKind,
        greenHash: UInt64
    ) {
        self.originalTreeID = originalTreeID
        self.path = path
        self.range = range
        self.rawKind = rawKind
        self.greenHash = greenHash
    }
}

struct RedNodeRecord<Lang: SyntaxLanguage> {
    let green: GreenNode<Lang>
    let parent: RedNodeID?
    let indexInParent: UInt32
    let offset: TextSize
    let childSlotChunk: Int
    let childSlotStart: Int
    let childSlotCount: Int
}

final class AtomicSlotChunk: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Atomic<UInt64>>
    let capacity: Int
    var used: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.used = 0
        self.storage = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: capacity)
        for index in 0..<capacity {
            (storage + index).initialize(to: Atomic(0))
        }
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    func load(at index: Int) -> UInt64 {
        precondition(index >= 0 && index < capacity, "Red child slot index out of bounds")
        return (storage + index).pointee.load(ordering: .acquiring)
    }

    func store(_ value: UInt64, at index: Int) {
        precondition(index >= 0 && index < capacity, "Red child slot index out of bounds")
        (storage + index).pointee.store(value, ordering: .releasing)
    }
}

private let redArenaMinimumSlotChunkCapacity = 1024

final class RedArena<Lang: SyntaxLanguage>: @unchecked Sendable {
    struct State {
        var records: [RedNodeRecord<Lang>]
        var slotChunks: [AtomicSlotChunk]
    }

    private let state: Mutex<State>

    init(root: GreenNode<Lang>) {
        let rootChunk = AtomicSlotChunk(capacity: max(redArenaMinimumSlotChunkCapacity, root.childCount))
        rootChunk.used = root.childCount
        let rootRecord = RedNodeRecord(
            green: root,
            parent: nil,
            indexInParent: 0,
            offset: .zero,
            childSlotChunk: 0,
            childSlotStart: 0,
            childSlotCount: root.childCount
        )
        self.state = Mutex(State(
            records: [rootRecord],
            slotChunks: [rootChunk]
        ))
    }

    func record(for id: RedNodeID) -> RedNodeRecord<Lang> {
        state.withLock { state in
            let index = Int(id.rawValue)
            precondition(state.records.indices.contains(index), "Unknown red node id \(id.rawValue)")
            return state.records[index]
        }
    }

    func realizeChildNode(parent parentID: RedNodeID, childIndex: Int) -> RedNodeID? {
        let parent = record(for: parentID)
        precondition(childIndex >= 0 && childIndex < parent.green.childCount, "Child index out of bounds")

        guard case .node = parent.green.child(at: childIndex) else {
            return nil
        }

        let slotIndex = parent.childSlotStart + childIndex
        let slot = state.withLock { state in
            state.slotChunks[parent.childSlotChunk].load(at: slotIndex)
        }
        if slot != 0 {
            return RedNodeID(rawValue: slot - 1)
        }

        return state.withLock { state -> RedNodeID? in
            let parentIndex = Int(parentID.rawValue)
            precondition(state.records.indices.contains(parentIndex), "Unknown red node id \(parentID.rawValue)")
            let parent = state.records[parentIndex]
            precondition(childIndex >= 0 && childIndex < parent.green.childCount, "Child index out of bounds")

            guard case .node(let childGreen) = parent.green.child(at: childIndex) else {
                return Optional<RedNodeID>.none
            }

            let slotIndex = parent.childSlotStart + childIndex
            let slotChunk = state.slotChunks[parent.childSlotChunk]
            let slot = slotChunk.load(at: slotIndex)
            if slot != 0 {
                return RedNodeID(rawValue: slot - 1)
            }

            let childSlotLocation = allocateSlots(count: childGreen.childCount, state: &state)
            let id = RedNodeID(rawValue: UInt64(state.records.count))
            let childRecord = RedNodeRecord(
                green: childGreen,
                parent: parentID,
                indexInParent: UInt32(childIndex),
                offset: parent.offset + parent.green.childStartOffset(at: childIndex),
                childSlotChunk: childSlotLocation.chunkIndex,
                childSlotStart: childSlotLocation.start,
                childSlotCount: childGreen.childCount
            )
            state.records.append(childRecord)
            slotChunk.store(id.rawValue + 1, at: slotIndex)
            return id
        }
    }

    private func allocateSlots(
        count: Int,
        state: inout State
    ) -> (chunkIndex: Int, start: Int) {
        guard count > 0 else {
            return (0, 0)
        }

        if let last = state.slotChunks.indices.last {
            let chunk = state.slotChunks[last]
            if chunk.capacity - chunk.used >= count {
                let start = chunk.used
                chunk.used += count
                return (last, start)
            }
        }

        let chunk = AtomicSlotChunk(capacity: max(redArenaMinimumSlotChunkCapacity, count))
        let index = state.slotChunks.count
        chunk.used = count
        state.slotChunks.append(chunk)
        return (index, 0)
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

    public init(root: GreenNode<Lang>, resolver: any TokenResolver = TokenTextResolver()) {
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
        let cursor = SyntaxNodeCursor(storage: storage, id: RedNodeID(rawValue: 0))
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
        let cursor = SyntaxNodeCursor(storage: storage, id: RedNodeID(rawValue: 0))
        return try body(cursor)
    }

    public func rootHandle() -> SyntaxNodeHandle<Lang> {
        SyntaxNodeHandle(storage: storage, id: RedNodeID(rawValue: 0))
    }

    public func resolve<R>(
        _ anchor: SyntaxAnchor<Lang>,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        if let exact = try withRoot({ root in
            try root.withDescendant(atPath: anchor.path) { candidate in
                candidate.rawKind == anchor.rawKind
                    && candidate.greenHash == anchor.greenHash
                    ? try body(candidate)
                    : nil
            }
        }) {
            return exact
        }

        return try withRoot { root in
            try root.firstNode(range: anchor.range, rawKind: anchor.rawKind, greenHash: anchor.greenHash, body)
                ?? root.firstNode(range: anchor.range, rawKind: anchor.rawKind, greenHash: nil, body)
                ?? root.nearbyNode(range: anchor.range, rawKind: anchor.rawKind, greenHash: anchor.greenHash, body)
        }
    }
}

public struct SyntaxNodeHandle<Lang: SyntaxLanguage>: Sendable, Hashable {
    internal let storage: SyntaxTreeStorage<Lang>
    internal let id: RedNodeID

    public var identity: SyntaxNodeIdentity {
        SyntaxNodeIdentity(treeID: storage.treeID, nodeID: id)
    }

    public var rawKind: RawSyntaxKind {
        storage.arena.record(for: id).green.rawKind
    }

    public var textRange: TextRange {
        let record = storage.arena.record(for: id)
        return TextRange(start: record.offset, length: record.green.textLength)
    }

    public func withCursor<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R {
        let cursor = SyntaxNodeCursor(storage: storage, id: id)
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
    internal let parent: RedNodeID
    internal let childIndex: UInt32
    internal let offset: TextSize

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
        let parentRecord = storage.arena.record(for: parent)
        guard case .token(let token) = parentRecord.green.child(at: Int(childIndex)) else {
            preconditionFailure("Token handle points at a node child")
        }
        let cursor = SyntaxTokenCursor(
            storage: storage,
            parent: parent,
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

public struct SyntaxNodeCursor<Lang: SyntaxLanguage>: ~Copyable {
    private let storageRef: Unmanaged<SyntaxTreeStorage<Lang>>
    internal var id: RedNodeID

    internal init(storage: SyntaxTreeStorage<Lang>, id: RedNodeID) {
        self.storageRef = Unmanaged.passUnretained(storage)
        self.id = id
    }

    internal var storage: SyntaxTreeStorage<Lang> {
        storageRef.takeUnretainedValue()
    }

    internal var record: RedNodeRecord<Lang> {
        storage.arena.record(for: id)
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
        guard let parent = record.parent else {
            return false
        }
        id = parent
        return true
    }

    public mutating func moveToFirstChild() -> Bool {
        let green = record.green
        for index in 0..<green.childCount {
            if let childID = storage.arena.realizeChildNode(parent: id, childIndex: index) {
                id = childID
                return true
            }
        }
        return false
    }

    public mutating func moveToLastChild() -> Bool {
        let green = record.green
        guard green.childCount > 0 else {
            return false
        }
        for index in stride(from: green.childCount - 1, through: 0, by: -1) {
            if let childID = storage.arena.realizeChildNode(parent: id, childIndex: index) {
                id = childID
                return true
            }
        }
        return false
    }

    public mutating func moveToNextSibling() -> Bool {
        let current = record
        guard let parentID = current.parent else {
            return false
        }
        let parent = storage.arena.record(for: parentID)
        let start = Int(current.indexInParent) + 1
        guard start < parent.green.childCount else {
            return false
        }
        for index in start..<parent.green.childCount {
            if let sibling = storage.arena.realizeChildNode(parent: parentID, childIndex: index) {
                id = sibling
                return true
            }
        }
        return false
    }

    public mutating func moveToPreviousSibling() -> Bool {
        let current = record
        guard let parentID = current.parent, current.indexInParent > 0 else {
            return false
        }
        for index in stride(from: Int(current.indexInParent) - 1, through: 0, by: -1) {
            if let sibling = storage.arena.realizeChildNode(parent: parentID, childIndex: index) {
                id = sibling
                return true
            }
        }
        return false
    }

    public borrowing func withParent<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        guard let parent = record.parent else {
            return nil
        }
        let cursor = SyntaxNodeCursor(storage: storage, id: parent)
        return try body(cursor)
    }

    public borrowing func withChildNode<R>(
        at nodeIndex: Int,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        precondition(nodeIndex >= 0, "Node child index must not be negative")
        let green = record.green
        var seen = 0
        for childIndex in 0..<green.childCount {
            guard case .node = green.child(at: childIndex) else {
                continue
            }
            if seen == nodeIndex {
                guard let childID = storage.arena.realizeChildNode(parent: id, childIndex: childIndex) else {
                    return nil
                }
                let cursor = SyntaxNodeCursor(storage: storage, id: childID)
                return try body(cursor)
            }
            seen += 1
        }
        return nil
    }

    public borrowing func withChildOrToken<R>(
        at childIndex: Int,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        let record = record
        guard childIndex >= 0 && childIndex < record.green.childCount else {
            return nil
        }

        switch record.green.child(at: childIndex) {
        case .node:
            guard let childID = storage.arena.realizeChildNode(parent: id, childIndex: childIndex) else {
                return nil
            }
            let node = SyntaxNodeCursor(storage: storage, id: childID)
            let element = SyntaxElementCursor<Lang>.node(node)
            return try body(element)
        case .token(let token):
            let token = SyntaxTokenCursor(
                storage: storage,
                parent: id,
                childIndex: UInt32(childIndex),
                offset: record.offset + record.green.childStartOffset(at: childIndex),
                green: token
            )
            let element = SyntaxElementCursor<Lang>.token(token)
            return try body(element)
        }
    }

    public borrowing func forEachChild(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> Void
    ) rethrows {
        let green = record.green
        for childIndex in 0..<green.childCount {
            guard case .node = green.child(at: childIndex),
                  let childID = storage.arena.realizeChildNode(parent: id, childIndex: childIndex)
            else {
                continue
            }
            let cursor = SyntaxNodeCursor(storage: storage, id: childID)
            try body(cursor)
        }
    }

    public borrowing func forEachChildOrToken(
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> Void
    ) rethrows {
        let count = childOrTokenCount
        for index in 0..<count {
            _ = try withChildOrToken(at: index) { element in
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

    public borrowing func tokens(
        in range: TextRange? = nil,
        _ body: (borrowing SyntaxTokenCursor<Lang>) throws -> Void
    ) rethrows {
        if let range, !textRange.intersects(range), !textRange.isEmpty {
            return
        }

        let record = record
        for index in 0..<record.green.childCount {
            let childStart = record.offset + record.green.childStartOffset(at: index)
            let child = record.green.child(at: index)
            let childRange = TextRange(start: childStart, length: child.textLength)
            if let range, !childRange.intersects(range), !childRange.isEmpty {
                continue
            }

            switch child {
            case .node:
                guard let childID = storage.arena.realizeChildNode(parent: id, childIndex: index) else {
                    continue
                }
                let cursor = SyntaxNodeCursor(storage: storage, id: childID)
                try cursor.tokens(in: range, body)
            case .token(let token):
                let cursor = SyntaxTokenCursor(
                    storage: storage,
                    parent: id,
                    childIndex: UInt32(index),
                    offset: childStart,
                    green: token
                )
                try body(cursor)
            }
        }
    }

    public borrowing func withToken<R>(
        at offset: TextSize,
        _ body: (borrowing SyntaxTokenCursor<Lang>) throws -> R
    ) rethrows -> R? {
        guard textRange.containsAllowingEnd(offset) else {
            return nil
        }

        let record = record
        for index in 0..<record.green.childCount {
            let childStart = record.offset + record.green.childStartOffset(at: index)
            let child = record.green.child(at: index)
            let childRange = TextRange(start: childStart, length: child.textLength)
            let contains = childRange.contains(offset)
                || (childRange.isEmpty && childRange.start == offset)
            guard contains else {
                continue
            }

            switch child {
            case .node:
                guard let childID = storage.arena.realizeChildNode(parent: id, childIndex: index) else {
                    continue
                }
                let cursor = SyntaxNodeCursor(storage: storage, id: childID)
                return try cursor.withToken(at: offset, body)
            case .token(let token):
                let cursor = SyntaxTokenCursor(
                    storage: storage,
                    parent: id,
                    childIndex: UInt32(index),
                    offset: childStart,
                    green: token
                )
                return try body(cursor)
            }
        }
        return nil
    }

    public borrowing func withCoveringElement<R>(
        _ range: TextRange,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R? {
        guard textRange.contains(range) else {
            return nil
        }

        let record = record
        for index in 0..<record.green.childCount {
            let childStart = record.offset + record.green.childStartOffset(at: index)
            let child = record.green.child(at: index)
            let childRange = TextRange(start: childStart, length: child.textLength)
            guard childRange.contains(range) else {
                continue
            }

            switch child {
            case .node:
                guard let childID = storage.arena.realizeChildNode(parent: id, childIndex: index) else {
                    continue
                }
                let cursor = SyntaxNodeCursor(storage: storage, id: childID)
                return try cursor.withCoveringElement(range, body)
            case .token(let token):
                let cursor = SyntaxTokenCursor(
                    storage: storage,
                    parent: id,
                    childIndex: UInt32(index),
                    offset: childStart,
                    green: token
                )
                let element = SyntaxElementCursor<Lang>.token(cursor)
                return try body(element)
            }
        }

        let node = SyntaxNodeCursor(storage: storage, id: id)
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
        SyntaxNodeHandle(storage: storage, id: id)
    }

    public borrowing func makeAnchor() -> SyntaxAnchor<Lang> {
        SyntaxAnchor(
            originalTreeID: storage.treeID,
            path: childIndexPath(),
            range: textRange,
            rawKind: rawKind,
            greenHash: greenHash
        )
    }

    public borrowing func childIndexPath() -> [UInt32] {
        var path: [UInt32] = []
        var current = record
        while let parent = current.parent {
            path.append(current.indexInParent)
            current = storage.arena.record(for: parent)
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

        var cursor = SyntaxNodeCursor(storage: storage, id: id)
        for rawIndex in path {
            guard let childID = storage.arena.realizeChildNode(
                parent: cursor.id,
                childIndex: Int(rawIndex)
            ) else {
                return nil
            }
            cursor.id = childID
        }
        return try body(cursor)
    }

    internal borrowing func firstNode<R>(
        range: TextRange,
        rawKind: RawSyntaxKind,
        greenHash: UInt64?,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        if textRange == range && self.rawKind == rawKind && (greenHash == nil || self.greenHash == greenHash) {
            return try body(self)
        }
        var result: R?
        try forEachChild { child in
            if result == nil {
                result = try child.firstNode(range: range, rawKind: rawKind, greenHash: greenHash, body)
            }
        }
        return result
    }

    internal borrowing func nearbyNode<R>(
        range: TextRange,
        rawKind: RawSyntaxKind,
        greenHash: UInt64,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        if rawKind == self.rawKind && greenHash == self.greenHash {
            let delta = textRange.start.rawValue > range.start.rawValue
                ? textRange.start.rawValue - range.start.rawValue
                : range.start.rawValue - textRange.start.rawValue
            if delta <= 64 {
                return try body(self)
            }
        }
        var result: R?
        try forEachChild { child in
            if result == nil {
                result = try child.nearbyNode(range: range, rawKind: rawKind, greenHash: greenHash, body)
            }
        }
        return result
    }
}

public struct SyntaxTokenCursor<Lang: SyntaxLanguage>: ~Copyable {
    private let storageRef: Unmanaged<SyntaxTreeStorage<Lang>>
    internal let parent: RedNodeID
    internal let childIndex: UInt32
    internal let offset: TextSize
    internal let green: GreenToken<Lang>

    internal init(
        storage: SyntaxTreeStorage<Lang>,
        parent: RedNodeID,
        childIndex: UInt32,
        offset: TextSize,
        green: GreenToken<Lang>
    ) {
        self.storageRef = Unmanaged.passUnretained(storage)
        self.parent = parent
        self.childIndex = childIndex
        self.offset = offset
        self.green = green
    }

    internal var storage: SyntaxTreeStorage<Lang> {
        storageRef.takeUnretainedValue()
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
        let cursor = SyntaxNodeCursor(storage: storage, id: parent)
        return try body(cursor)
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
            parent: parent,
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
