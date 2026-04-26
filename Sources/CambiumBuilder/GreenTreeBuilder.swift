import CambiumCore
import Synchronization

final class MutexBox<Value>: @unchecked Sendable {
    let mutex: Mutex<Value>

    init(_ value: sending Value) {
        self.mutex = Mutex(value)
    }
}

public enum GreenCachePolicy: Sendable, Hashable {
    case disabled
    case documentLocal
    case parseSession(maxBytes: Int)
    case shared(maxBytes: Int)

    var maxEntries: Int {
        switch self {
        case .disabled:
            0
        case .documentLocal:
            16_384
        case .parseSession(let maxBytes), .shared(let maxBytes):
            max(128, maxBytes / 128)
        }
    }
}

final class LocalTokenInternerStorage: @unchecked Sendable {
    let tokenKeyNamespace = TokenKeyNamespace()
    var keysByText: [[UInt8]: TokenKey] = [:]
    var textByKey: [String] = []
    var largeText: [String] = []
}

public struct LocalTokenInterner: ~Copyable {
    private let storage: LocalTokenInternerStorage

    public init() {
        self.storage = LocalTokenInternerStorage()
    }

    init(storage: LocalTokenInternerStorage) {
        self.storage = storage
    }

    public mutating func intern(_ text: String) -> TokenKey {
        var copy = text
        return copy.withUTF8 { bytes in
            intern(bytes)
        }
    }

    public mutating func intern(_ bytes: UnsafeBufferPointer<UInt8>) -> TokenKey {
        let keyBytes = Array(bytes)
        if let key = storage.keysByText[keyBytes] {
            return key
        }
        let key = TokenKey(UInt32(storage.textByKey.count))
        storage.keysByText[keyBytes] = key
        storage.textByKey.append(String(decoding: bytes, as: UTF8.self))
        return key
    }

    public mutating func storeLargeText(_ text: String) -> LargeTokenTextID {
        let id = LargeTokenTextID(UInt32(storage.largeText.count))
        storage.largeText.append(text)
        return id
    }

    public borrowing func snapshot() -> TokenTextSnapshot {
        TokenTextSnapshot(
            interned: storage.textByKey,
            large: storage.largeText,
            namespace: storage.tokenKeyNamespace
        )
    }
}

enum SharedTokenInternerKeyLayout {
    static let shardBits = 8
    static let localBits = 24
    static let maxShardCount = 1 << shardBits
    static let maxLocalEntriesPerShard = 1 << localBits
    static let localIndexMask: UInt32 = 0x00ff_ffff

    static func shardIndex(forHash hash: Int, shardCount: Int) -> Int {
        precondition(shardCount > 0, "SharedTokenInterner requires at least one shard")
        return Int(UInt(bitPattern: hash) % UInt(shardCount))
    }

    static func makeKey(shardIndex: Int, localIndex: Int) -> TokenKey? {
        guard shardIndex >= 0,
              shardIndex < maxShardCount,
              localIndex >= 0,
              localIndex < maxLocalEntriesPerShard
        else {
            return nil
        }
        return TokenKey((UInt32(shardIndex) << UInt32(localBits)) | UInt32(localIndex))
    }

    static func decode(_ key: TokenKey) -> (shardIndex: Int, localIndex: Int) {
        (
            shardIndex: Int(key.rawValue >> UInt32(localBits)),
            localIndex: Int(key.rawValue & localIndexMask)
        )
    }
}

/// Thread-safe token interner with sharded storage.
///
/// `TokenKey` values produced by this interner are runtime-local to this
/// resolver. The current encoding uses the high 8 bits for the shard index and
/// the low 24 bits for the per-shard local index, so at most 256 shards and
/// 16,777,216 distinct token texts per shard are representable.
public final class SharedTokenInterner: TokenResolver, @unchecked Sendable {
    struct Shard {
        var keysByText: [[UInt8]: TokenKey] = [:]
        var textByKey: [String] = []
    }

    private let shards: [MutexBox<Shard>]
    public let tokenKeyNamespace: TokenKeyNamespace? = TokenKeyNamespace()

    public init(shardCount: Int = 8) {
        precondition(shardCount > 0, "SharedTokenInterner requires at least one shard")
        precondition(
            shardCount <= SharedTokenInternerKeyLayout.maxShardCount,
            "SharedTokenInterner supports at most \(SharedTokenInternerKeyLayout.maxShardCount) shards"
        )
        self.shards = (0..<shardCount).map { _ in
            MutexBox(Shard())
        }
    }

    public func intern(_ text: String) -> TokenKey {
        var copy = text
        return copy.withUTF8 { bytes in
            intern(bytes)
        }
    }

    public func intern(_ bytes: UnsafeBufferPointer<UInt8>) -> TokenKey {
        let keyBytes = Array(bytes)
        let shardIndex = SharedTokenInternerKeyLayout.shardIndex(
            forHash: keyBytes.hashValue,
            shardCount: shards.count
        )
        return shards[shardIndex].mutex.withLock { shard in
            if let key = shard.keysByText[keyBytes] {
                return key
            }
            guard let key = SharedTokenInternerKeyLayout.makeKey(
                shardIndex: shardIndex,
                localIndex: shard.textByKey.count
            ) else {
                preconditionFailure(
                    "SharedTokenInterner shard \(shardIndex) exhausted its \(SharedTokenInternerKeyLayout.maxLocalEntriesPerShard)-entry key space"
                )
            }
            shard.keysByText[keyBytes] = key
            shard.textByKey.append(String(decoding: bytes, as: UTF8.self))
            return key
        }
    }

    public func resolve(_ key: TokenKey) -> String {
        let (shardIndex, localIndex) = SharedTokenInternerKeyLayout.decode(key)
        precondition(shards.indices.contains(shardIndex), "Unknown shared token key \(key.rawValue)")
        return shards[shardIndex].mutex.withLock { shard in
            precondition(shard.textByKey.indices.contains(localIndex), "Unknown shared token key \(key.rawValue)")
            return shard.textByKey[localIndex]
        }
    }

    public func withUTF8<R>(
        _ key: TokenKey,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        let text = resolve(key)
        return try text.utf8.withContiguousStorageIfAvailable(body)
            ?? Array(text.utf8).withUnsafeBufferPointer(body)
    }
}

struct TokenCacheKey: Hashable {
    var rawKind: RawSyntaxKind
    var textLength: TextSize
    var text: TokenTextStorage
}

struct NodeCacheKey: Hashable {
    var rawKind: RawSyntaxKind
    var textLength: TextSize
    var childCount: Int
    var structuralHash: UInt64
}

final class GreenNodeCacheStorage<Lang: SyntaxLanguage>: @unchecked Sendable {
    let policy: GreenCachePolicy
    var tokenCache: [TokenCacheKey: GreenToken<Lang>] = [:]
    var nodeCache: [NodeCacheKey: [GreenNode<Lang>]] = [:]
    let interner: LocalTokenInternerStorage
    var hits: Int = 0
    var misses: Int = 0
    var evictions: Int = 0

    init(policy: GreenCachePolicy, interner: LocalTokenInternerStorage = LocalTokenInternerStorage()) {
        self.policy = policy
        self.interner = interner
    }

    var isEnabled: Bool {
        policy.maxEntries > 0
    }

    func trimIfNeeded() {
        guard isEnabled else {
            tokenCache.removeAll(keepingCapacity: false)
            nodeCache.removeAll(keepingCapacity: false)
            return
        }

        let maxEntries = policy.maxEntries
        while tokenCache.count + nodeCache.count > maxEntries {
            if let key = tokenCache.keys.first {
                tokenCache.removeValue(forKey: key)
                evictions += 1
            } else if let key = nodeCache.keys.first {
                nodeCache.removeValue(forKey: key)
                evictions += 1
            } else {
                break
            }
        }
    }
}

public struct GreenNodeCache<Lang: SyntaxLanguage>: ~Copyable {
    fileprivate let storage: GreenNodeCacheStorage<Lang>

    public init(policy: GreenCachePolicy = .documentLocal) {
        self.storage = GreenNodeCacheStorage(policy: policy)
    }

    init(storage: GreenNodeCacheStorage<Lang>) {
        self.storage = storage
    }

    public var policy: GreenCachePolicy {
        storage.policy
    }

    public var hitCount: Int {
        storage.hits
    }

    public var missCount: Int {
        storage.misses
    }

    public var evictionCount: Int {
        storage.evictions
    }

    public mutating func intern(_ text: String) -> TokenKey {
        var interner = LocalTokenInterner(storage: storage.interner)
        return interner.intern(text)
    }

    public mutating func intern(_ bytes: UnsafeBufferPointer<UInt8>) -> TokenKey {
        var interner = LocalTokenInterner(storage: storage.interner)
        return interner.intern(bytes)
    }

    public mutating func storeLargeText(_ text: String) -> LargeTokenTextID {
        var interner = LocalTokenInterner(storage: storage.interner)
        return interner.storeLargeText(text)
    }

    public mutating func makeToken(
        kind: RawSyntaxKind,
        textLength: TextSize,
        text: TokenTextStorage = .staticText
    ) -> GreenToken<Lang> {
        let key = TokenCacheKey(rawKind: kind, textLength: textLength, text: text)
        if storage.isEnabled, let cached = storage.tokenCache[key] {
            storage.hits += 1
            return cached
        }

        storage.misses += 1
        let token = GreenToken<Lang>(kind: kind, textLength: textLength, text: text)
        if storage.isEnabled {
            storage.tokenCache[key] = token
            storage.trimIfNeeded()
        }
        return token
    }

    public mutating func makeNode(
        kind: RawSyntaxKind,
        children: [GreenElement<Lang>]
    ) throws -> GreenNode<Lang> {
        let candidate = try GreenNode<Lang>(kind: kind, children: children)
        let key = NodeCacheKey(
            rawKind: candidate.rawKind,
            textLength: candidate.textLength,
            childCount: candidate.childCount,
            structuralHash: candidate.structuralHash
        )

        if storage.isEnabled, let bucket = storage.nodeCache[key] {
            for existing in bucket where existing == candidate {
                storage.hits += 1
                return existing
            }
        }

        storage.misses += 1
        if storage.isEnabled {
            storage.nodeCache[key, default: []].append(candidate)
            storage.trimIfNeeded()
        }
        return candidate
    }

    consuming func takeStorage() -> GreenNodeCacheStorage<Lang> {
        storage
    }
}

public final class SharedGreenNodeCache<Lang: SyntaxLanguage>: @unchecked Sendable {
    private let shards: [MutexBox<GreenNodeCacheStorage<Lang>>]

    public init(policy: GreenCachePolicy = .shared(maxBytes: 16 * 1024 * 1024), shardCount: Int = 8) {
        precondition(shardCount > 0, "SharedGreenNodeCache requires at least one shard")
        self.shards = (0..<shardCount).map { _ in
            MutexBox(GreenNodeCacheStorage(policy: policy))
        }
    }

    public func withShard<R>(
        for rawKind: RawSyntaxKind,
        _ body: (inout GreenNodeCache<Lang>) throws -> R
    ) rethrows -> R {
        let index = Int(rawKind.rawValue % UInt32(shards.count))
        return try shards[index].mutex.withLock { storage in
            var cache = GreenNodeCache<Lang>(storage: storage)
            return try body(&cache)
        }
    }
}

public struct BuilderCheckpoint: Sendable, Hashable {
    fileprivate let parentCount: Int
    fileprivate let childCount: Int

    public init(parentCount: Int, childCount: Int) {
        self.parentCount = parentCount
        self.childCount = childCount
    }
}

public enum GreenTreeBuilderError: Error, Sendable, Equatable {
    case unbalancedStartNodes(Int)
    case finishWithoutNode
    case noRoot
    case multipleRoots(Int)
    case invalidCheckpoint
    case childIndexIsToken
    case staticTextUnavailable(RawSyntaxKind)
    case staticTextLengthOverflow
    /// Raised when `token(_:text:)` or `largeToken(_:text:)` is called with a
    /// kind whose `Lang.staticText(for:)` is non-nil. Static-text kinds belong
    /// on the `staticToken(_:)` path; the dynamic-text paths are reserved for
    /// kinds that don't have grammar-determined text.
    case staticKindRequiresStaticToken(RawSyntaxKind)
}

struct OpenNode {
    var kind: RawSyntaxKind
    var firstChildIndex: Int
}

/// Cacheless snapshot of a finished green tree.
///
/// This is the copyable `root + token text` view of a tree. It is sufficient
/// for rendering, serialization, and creating a `SyntaxTree`, but it does not
/// carry the reusable builder cache needed for identity-preserving incremental
/// reuse.
public struct GreenTreeSnapshot<Lang: SyntaxLanguage>: Sendable {
    public let root: GreenNode<Lang>
    public let tokenText: TokenTextSnapshot

    public init(root: GreenNode<Lang>, tokenText: TokenTextSnapshot) {
        self.root = root
        self.tokenText = tokenText
    }

    public func makeSyntaxTree() -> SyntaxTree<Lang> {
        SyntaxTree(root: root, resolver: tokenText)
    }
}

/// Result of finishing a builder.
///
/// The result includes the reusable cache so parse-session and incremental
/// workflows naturally carry green storage and token-key namespace forward to
/// the next builder.
public struct GreenBuildResult<Lang: SyntaxLanguage>: ~Copyable {
    public let root: GreenNode<Lang>
    public let tokenText: TokenTextSnapshot
    private var cache: GreenNodeCache<Lang>

    public init(
        root: GreenNode<Lang>,
        tokenText: TokenTextSnapshot,
        cache: consuming GreenNodeCache<Lang>
    ) {
        self.root = root
        self.tokenText = tokenText
        self.cache = cache
    }

    public var snapshot: GreenTreeSnapshot<Lang> {
        GreenTreeSnapshot(root: root, tokenText: tokenText)
    }

    /// Consume this result and return the cache for the next builder.
    ///
    /// Read `root`, `tokenText`, `snapshot`, or `makeSyntaxTree()` before calling
    /// this method.
    public consuming func intoCache() -> GreenNodeCache<Lang> {
        cache
    }
}

/// How `GreenTreeBuilder.reuseSubtree(_:)` accepted a subtree.
///
/// Use this to observe whether reuse preserved green storage identity from
/// the source tree (`.direct`) or had to rebuild the subtree because the
/// source resolver's token-key namespace did not match the builder's
/// (`.remapped`). A high `.remapped` rate in incremental parsing usually
/// signals that the integrator failed to carry the cache forward through
/// `result.intoCache()`.
public enum SubtreeReuseOutcome: Sendable, Hashable {
    /// The source resolver shared this builder's token-key namespace, so the
    /// green node was appended directly. Storage identity is preserved.
    case direct

    /// The source resolver did not share this builder's token-key namespace,
    /// so the subtree's dynamic token keys were remapped into this builder's
    /// interner and the subtree was rebuilt. Storage identity is not
    /// preserved across the splice.
    case remapped
}

final class OverlayTokenResolver: TokenResolver, @unchecked Sendable {
    private let base: any TokenResolver
    private let interned: [TokenKey: String]
    private let large: [LargeTokenTextID: String]
    let tokenKeyNamespace: TokenKeyNamespace? = nil

    init(
        base: any TokenResolver,
        interned: [TokenKey: String],
        large: [LargeTokenTextID: String]
    ) {
        self.base = base
        self.interned = interned
        self.large = large
    }

    func resolve(_ key: TokenKey) -> String {
        interned[key] ?? base.resolve(key)
    }

    func resolveLargeText(_ id: LargeTokenTextID) -> String {
        large[id] ?? base.resolveLargeText(id)
    }

    func withUTF8<R>(
        _ key: TokenKey,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        if let text = interned[key] {
            return try text.utf8.withContiguousStorageIfAvailable(body)
                ?? Array(text.utf8).withUnsafeBufferPointer(body)
        }
        return try base.withUTF8(key, body)
    }

    func withLargeTextUTF8<R>(
        _ id: LargeTokenTextID,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        if let text = large[id] {
            return try text.utf8.withContiguousStorageIfAvailable(body)
                ?? Array(text.utf8).withUnsafeBufferPointer(body)
        }
        return try base.withLargeTextUTF8(id, body)
    }
}

struct ReplacementTokenRemapper<Lang: SyntaxLanguage> {
    var nextInterned: UInt32 = UInt32.max
    var nextLarge: UInt32 = UInt32.max
    var interned: [TokenKey: String] = [:]
    var large: [LargeTokenTextID: String] = [:]
    var internedMap: [TokenKey: TokenKey] = [:]
    var largeMap: [LargeTokenTextID: LargeTokenTextID] = [:]

    mutating func remap(
        node: GreenNode<Lang>,
        replacementResolver: any TokenResolver,
        cache: inout GreenNodeCache<Lang>
    ) throws -> GreenNode<Lang> {
        var children: [GreenElement<Lang>] = []
        children.reserveCapacity(node.childCount)
        for childIndex in 0..<node.childCount {
            switch node.child(at: childIndex) {
            case .node(let child):
                children.append(.node(try remap(
                    node: child,
                    replacementResolver: replacementResolver,
                    cache: &cache
                )))
            case .token(let token):
                children.append(.token(remap(
                    token: token,
                    replacementResolver: replacementResolver,
                    cache: &cache
                )))
            }
        }
        return try cache.makeNode(kind: node.rawKind, children: children)
    }

    mutating func remap(
        token: GreenToken<Lang>,
        replacementResolver: any TokenResolver,
        cache: inout GreenNodeCache<Lang>
    ) -> GreenToken<Lang> {
        let text: TokenTextStorage
        switch token.textStorage {
        case .staticText:
            text = .staticText
        case .missing:
            text = .missing
        case .interned(let key):
            let mapped = internedMap[key] ?? {
                let newKey = TokenKey(nextInterned)
                nextInterned -= 1
                internedMap[key] = newKey
                interned[newKey] = replacementResolver.resolve(key)
                return newKey
            }()
            text = .interned(mapped)
        case .ownedLargeText(let id):
            let mapped = largeMap[id] ?? {
                let newID = LargeTokenTextID(nextLarge)
                nextLarge -= 1
                largeMap[id] = newID
                large[newID] = replacementResolver.resolveLargeText(id)
                return newID
            }()
            text = .ownedLargeText(mapped)
        }
        return cache.makeToken(kind: token.rawKind, textLength: token.textLength, text: text)
    }
}

struct ReusedSubtreeTokenRemapper<Lang: SyntaxLanguage> {
    var internedMap: [TokenKey: TokenKey] = [:]
    var largeMap: [LargeTokenTextID: LargeTokenTextID] = [:]

    mutating func remap(
        node: GreenNode<Lang>,
        sourceResolver: any TokenResolver,
        cache: inout GreenNodeCache<Lang>
    ) throws -> GreenNode<Lang> {
        var children: [GreenElement<Lang>] = []
        children.reserveCapacity(node.childCount)
        for childIndex in 0..<node.childCount {
            switch node.child(at: childIndex) {
            case .node(let child):
                children.append(.node(try remap(
                    node: child,
                    sourceResolver: sourceResolver,
                    cache: &cache
                )))
            case .token(let token):
                children.append(.token(remap(
                    token: token,
                    sourceResolver: sourceResolver,
                    cache: &cache
                )))
            }
        }
        return try cache.makeNode(kind: node.rawKind, children: children)
    }

    mutating func remap(
        token: GreenToken<Lang>,
        sourceResolver: any TokenResolver,
        cache: inout GreenNodeCache<Lang>
    ) -> GreenToken<Lang> {
        let text: TokenTextStorage
        switch token.textStorage {
        case .staticText:
            text = .staticText
        case .missing:
            text = .missing
        case .interned(let key):
            let mapped = internedMap[key] ?? {
                let newKey = sourceResolver.withUTF8(key) { bytes in
                    cache.intern(bytes)
                }
                internedMap[key] = newKey
                return newKey
            }()
            text = .interned(mapped)
        case .ownedLargeText(let id):
            let mapped = largeMap[id] ?? {
                let newID = cache.storeLargeText(sourceResolver.resolveLargeText(id))
                largeMap[id] = newID
                return newID
            }()
            text = .ownedLargeText(mapped)
        }
        return cache.makeToken(kind: token.rawKind, textLength: token.textLength, text: text)
    }
}

public struct GreenTreeBuilder<Lang: SyntaxLanguage>: ~Copyable {
    private let cacheStorage: GreenNodeCacheStorage<Lang>
    private var parents: [OpenNode]
    private var children: [GreenElement<Lang>]
    private var finished: Bool

    public init(cache: consuming GreenNodeCache<Lang>) {
        self.cacheStorage = cache.takeStorage()
        self.parents = []
        self.children = []
        self.finished = false
    }

    public init(policy: GreenCachePolicy = .documentLocal) {
        let cache = GreenNodeCacheStorage<Lang>(policy: policy)
        self.cacheStorage = cache
        self.parents = []
        self.children = []
        self.finished = false
    }

    public mutating func startNode(_ kind: Lang.Kind) {
        startNode(rawKind: Lang.rawKind(for: kind))
    }

    public mutating func startNode(rawKind: RawSyntaxKind) {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        parents.append(OpenNode(kind: rawKind, firstChildIndex: children.count))
    }

    public mutating func finishNode() throws {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        guard let parent = parents.popLast() else {
            throw GreenTreeBuilderError.finishWithoutNode
        }

        let nodeChildren = Array(children[parent.firstChildIndex...])
        children.removeSubrange(parent.firstChildIndex...)

        var cache = GreenNodeCache<Lang>(storage: cacheStorage)
        let node = try cache.makeNode(kind: parent.kind, children: nodeChildren)
        children.append(.node(node))
    }

    public mutating func token(_ kind: Lang.Kind, text: String) throws {
        var copy = text
        try copy.withUTF8 { bytes in
            try token(kind, bytes: bytes)
        }
    }

    public mutating func token(_ kind: Lang.Kind, bytes: UnsafeBufferPointer<UInt8>) throws {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        if Lang.staticText(for: kind) != nil {
            throw GreenTreeBuilderError.staticKindRequiresStaticToken(Lang.rawKind(for: kind))
        }
        var interner = LocalTokenInterner(storage: cacheStorage.interner)
        let key = interner.intern(bytes)
        let length = try TextSize(exactly: bytes.count)
        var cache = GreenNodeCache<Lang>(storage: cacheStorage)
        children.append(.token(cache.makeToken(
            kind: Lang.rawKind(for: kind),
            textLength: length,
            text: .interned(key)
        )))
    }

    public mutating func largeToken(_ kind: Lang.Kind, text: String) throws {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        if Lang.staticText(for: kind) != nil {
            throw GreenTreeBuilderError.staticKindRequiresStaticToken(Lang.rawKind(for: kind))
        }
        var interner = LocalTokenInterner(storage: cacheStorage.interner)
        let id = interner.storeLargeText(text)
        let length = try TextSize(byteCountOf: text)
        var cache = GreenNodeCache<Lang>(storage: cacheStorage)
        children.append(.token(cache.makeToken(
            kind: Lang.rawKind(for: kind),
            textLength: length,
            text: .ownedLargeText(id)
        )))
    }

    public mutating func staticToken(_ kind: Lang.Kind) throws {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        guard let text = Lang.staticText(for: kind) else {
            throw GreenTreeBuilderError.staticTextUnavailable(Lang.rawKind(for: kind))
        }
        let length: TextSize
        do {
            var byteCount = 0
            text.withUTF8Buffer { bytes in
                byteCount = bytes.count
            }
            length = try TextSize(exactly: byteCount)
        } catch {
            throw GreenTreeBuilderError.staticTextLengthOverflow
        }

        var cache = GreenNodeCache<Lang>(storage: cacheStorage)
        children.append(.token(cache.makeToken(
            kind: Lang.rawKind(for: kind),
            textLength: length,
            text: .staticText
        )))
    }

    public mutating func missingToken(_ kind: Lang.Kind) {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        var cache = GreenNodeCache<Lang>(storage: cacheStorage)
        children.append(.token(cache.makeToken(
            kind: Lang.rawKind(for: kind),
            textLength: .zero,
            text: .missing
        )))
    }

    public mutating func missingNode(_ kind: Lang.Kind) throws {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        var cache = GreenNodeCache<Lang>(storage: cacheStorage)
        children.append(.node(try cache.makeNode(kind: Lang.rawKind(for: kind), children: [])))
    }

    public mutating func checkpoint() -> BuilderCheckpoint {
        BuilderCheckpoint(parentCount: parents.count, childCount: children.count)
    }

    public mutating func startNode(at checkpoint: BuilderCheckpoint, _ kind: Lang.Kind) throws {
        try validate(checkpoint)
        let wrapped = Array(children[checkpoint.childCount...])
        children.removeSubrange(checkpoint.childCount...)
        parents.append(OpenNode(kind: Lang.rawKind(for: kind), firstChildIndex: children.count))
        children.append(contentsOf: wrapped)
    }

    public mutating func revert(to checkpoint: BuilderCheckpoint) throws {
        try validate(checkpoint)
        parents.removeSubrange(checkpoint.parentCount...)
        children.removeSubrange(checkpoint.childCount...)
    }

    // MARK: - Subtree reuse

    /// Append an existing subtree to this builder.
    ///
    /// If `node`'s resolver shares this builder's token-key namespace, the
    /// green node is appended directly and storage identity is preserved
    /// (`.direct`). Otherwise, dynamic token keys are remapped into this
    /// builder's interner and the subtree is rebuilt before appending
    /// (`.remapped`). A `.remapped` outcome usually means the integrator
    /// could not prove that the source tree shared this builder's interner —
    /// commonly because the source was decoded from a snapshot, came from a
    /// different document, or because the cache lineage was severed by
    /// dropping `result.intoCache()` somewhere upstream.
    @discardableResult
    public mutating func reuseSubtree(
        _ node: borrowing SyntaxNodeCursor<Lang>
    ) throws -> SubtreeReuseOutcome {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        let sourceResolver = node.resolver
        if let sourceNamespace = sourceResolver.tokenKeyNamespace,
           sourceNamespace === cacheStorage.interner.tokenKeyNamespace
        {
            node.green { green in
                children.append(.node(green))
            }
            return .direct
        }

        var cache = GreenNodeCache<Lang>(storage: cacheStorage)
        var remapper = ReusedSubtreeTokenRemapper<Lang>()
        let remapped = try node.green { green in
            try remapper.remap(
                node: green,
                sourceResolver: sourceResolver,
                cache: &cache
            )
        }
        children.append(.node(remapped))
        return .remapped
    }

    /// Finish the tree and return the builder's reusable cache.
    ///
    /// The returned cache carries both green-node cache contents and the
    /// token-key namespace needed for identity-preserving `reuseSubtree` in a
    /// later builder.
    public consuming func finish() throws -> GreenBuildResult<Lang> {
        let root = try finishRoot()
        let interner = LocalTokenInterner(storage: cacheStorage.interner)
        return GreenBuildResult(
            root: root,
            tokenText: interner.snapshot(),
            cache: GreenNodeCache(storage: cacheStorage)
        )
    }

    private mutating func finishRoot() throws -> GreenNode<Lang> {
        if !parents.isEmpty {
            throw GreenTreeBuilderError.unbalancedStartNodes(parents.count)
        }
        guard !children.isEmpty else {
            throw GreenTreeBuilderError.noRoot
        }
        guard children.count == 1 else {
            throw GreenTreeBuilderError.multipleRoots(children.count)
        }
        guard case .node(let root) = children[0] else {
            throw GreenTreeBuilderError.noRoot
        }
        finished = true
        return root
    }

    private func validate(_ checkpoint: BuilderCheckpoint) throws {
        guard checkpoint.parentCount <= parents.count,
              checkpoint.childCount <= children.count
        else {
            throw GreenTreeBuilderError.invalidCheckpoint
        }
    }
}

public extension SyntaxNodeCursor {
    borrowing func replacingSelf(
        with replacement: GreenNode<Lang>,
        using cache: inout GreenNodeCache<Lang>
    ) throws -> GreenNode<Lang> {
        let path = childIndexPath()
        return try rebuildReplacing(
            root: rootGreen,
            path: ArraySlice(path),
            replacement: replacement,
            cache: &cache
        )
    }
}

private func rebuildReplacing<Lang: SyntaxLanguage>(
    root: GreenNode<Lang>,
    path: ArraySlice<UInt32>,
    replacement: GreenNode<Lang>,
    cache: inout GreenNodeCache<Lang>
) throws -> GreenNode<Lang> {
    guard let first = path.first else {
        return replacement
    }

    var children = root.childrenArray()
    let index = Int(first)
    guard children.indices.contains(index) else {
        throw GreenTreeBuilderError.invalidCheckpoint
    }
    guard case .node(let child) = children[index] else {
        throw GreenTreeBuilderError.childIndexIsToken
    }
    let rebuilt = try rebuildReplacing(
        root: child,
        path: path.dropFirst(),
        replacement: replacement,
        cache: &cache
    )
    children[index] = .node(rebuilt)
    return try cache.makeNode(kind: root.rawKind, children: children)
}

public extension SharedSyntaxTree {
    /// Replace the subtree at `handle` with `replacement`, producing a new
    /// `SyntaxTree` and a `ReplacementWitness` that describes the structural
    /// change. The witness carries enough information for an external
    /// identity tracker to translate any v0 reference into v1.
    ///
    /// `handle` must be from this tree; passing a handle from a different
    /// tree traps. (Cross-tree replacement is not a meaningful operation —
    /// translate the handle through your own tracker first.)
    func replacing(
        _ handle: SyntaxNodeHandle<Lang>,
        with replacement: GreenNode<Lang>,
        cache: inout GreenNodeCache<Lang>
    ) throws -> ReplacementResult<Lang> {
        precondition(
            handle.identity.treeID == treeID,
            "SyntaxNodeHandle is from a different tree than the SharedSyntaxTree it is being applied to"
        )
        let oldRoot = rootGreen
        let (replacedPath, oldSubtree): (SyntaxNodePath, GreenNode<Lang>) = handle.withCursor { cursor in
            let path = cursor.childIndexPath()
            let oldSub = cursor.green { $0 }
            return (path, oldSub)
        }
        let newRoot: GreenNode<Lang>
        if oldSubtree.identity == replacement.identity {
            newRoot = oldRoot
        } else {
            newRoot = try rebuildReplacing(
                root: oldRoot,
                path: ArraySlice(replacedPath),
                replacement: replacement,
                cache: &cache
            )
        }
        let witness = ReplacementWitness(
            oldRoot: oldRoot,
            newRoot: newRoot,
            replacedPath: replacedPath,
            oldSubtree: oldSubtree,
            newSubtree: replacement
        )
        return ReplacementResult(
            tree: SyntaxTree(root: newRoot, resolver: resolver),
            witness: witness
        )
    }

    /// Same as `replacing(_:with:cache:)` for `GreenNode`, but accepts a
    /// cacheless snapshot produced by an independent `GreenTreeBuilder`.
    /// Token interner keys in the replacement are remapped through `cache`
    /// so the returned tree's resolver can resolve them; the witness's
    /// `newSubtree` is the remapped subtree (which is what actually lives
    /// in the new tree).
    func replacing(
        _ handle: SyntaxNodeHandle<Lang>,
        with replacement: GreenTreeSnapshot<Lang>,
        cache: inout GreenNodeCache<Lang>
    ) throws -> ReplacementResult<Lang> {
        precondition(
            handle.identity.treeID == treeID,
            "SyntaxNodeHandle is from a different tree than the SharedSyntaxTree it is being applied to"
        )
        var remapper = ReplacementTokenRemapper<Lang>()
        let remappedReplacement = try remapper.remap(
            node: replacement.root,
            replacementResolver: replacement.tokenText,
            cache: &cache
        )

        let oldRoot = rootGreen
        let (replacedPath, oldSubtree): (SyntaxNodePath, GreenNode<Lang>) = handle.withCursor { cursor in
            let path = cursor.childIndexPath()
            let oldSub = cursor.green { $0 }
            return (path, oldSub)
        }
        if oldSubtree.identity == remappedReplacement.identity {
            let witness = ReplacementWitness(
                oldRoot: oldRoot,
                newRoot: oldRoot,
                replacedPath: replacedPath,
                oldSubtree: oldSubtree,
                newSubtree: remappedReplacement
            )
            return ReplacementResult(
                tree: SyntaxTree(root: oldRoot, resolver: resolver),
                witness: witness
            )
        }

        let newRoot = try rebuildReplacing(
            root: oldRoot,
            path: ArraySlice(replacedPath),
            replacement: remappedReplacement,
            cache: &cache
        )
        // If the replacement contributed no dynamic-token text, the overlay
        // would be a pure pass-through to `resolver`. Skip it so the result
        // tree's resolver retains the base's `tokenKeyNamespace`, which lets
        // a subsequent `reuseSubtree` from this tree fast-path-match.
        let resultResolver: any TokenResolver
        if remapper.interned.isEmpty && remapper.large.isEmpty {
            resultResolver = resolver
        } else {
            resultResolver = OverlayTokenResolver(
                base: resolver,
                interned: remapper.interned,
                large: remapper.large
            )
        }
        let witness = ReplacementWitness(
            oldRoot: oldRoot,
            newRoot: newRoot,
            replacedPath: replacedPath,
            oldSubtree: oldSubtree,
            newSubtree: remappedReplacement
        )
        return ReplacementResult(
            tree: SyntaxTree(root: newRoot, resolver: resultResolver),
            witness: witness
        )
    }

    /// Same as `replacing(_:with:cache:)` for `GreenTreeSnapshot`, but borrows
    /// the snapshot view from a cache-preserving build result.
    func replacing(
        _ handle: SyntaxNodeHandle<Lang>,
        with replacement: borrowing GreenBuildResult<Lang>,
        cache: inout GreenNodeCache<Lang>
    ) throws -> ReplacementResult<Lang> {
        try replacing(handle, with: replacement.snapshot, cache: &cache)
    }
}
