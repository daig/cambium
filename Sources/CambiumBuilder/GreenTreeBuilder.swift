import CambiumCore
import Synchronization

final class MutexBox<Value>: @unchecked Sendable {
    let mutex: Mutex<Value>

    init(_ value: sending Value) {
        self.mutex = Mutex(value)
    }
}

/// Caching policy for `GreenNodeCache`.
///
/// All policies cache tokens unconditionally when caching is enabled. Green
/// nodes are subject to a fixed size threshold: nodes with more than three
/// total children (matching cstree's default) bypass the cache and are
/// returned without lookup or insertion. Wide nodes rarely recur
/// structurally, and caching them tends to evict useful small entries while
/// rarely paying off as a cache hit.
///
/// Eviction is deterministic FIFO across the union of token and node entries,
/// triggered when the combined entry count would exceed `maxEntries`.
public enum GreenCachePolicy: Sendable, Hashable {
    /// No caching. Every `makeToken` and `makeNode` call returns a fresh
    /// allocation; `bypassCount` increments per call.
    case disabled

    /// Per-document cache fixed at 16,384 entries. Suitable for one-shot
    /// builds and small-to-medium documents.
    case documentLocal

    /// Parse-session cache with an explicit entry limit. Use this when
    /// carrying the cache forward across reparses via `result.intoCache()`.
    /// `maxEntries` must be positive; pass `.disabled` to opt out of caching.
    case parseSession(maxEntries: Int)

    /// Shared cache budget for cross-builder use (e.g. via
    /// `SharedGreenNodeCache`). `maxEntries` must be positive.
    case shared(maxEntries: Int)

    var maxEntries: Int {
        switch self {
        case .disabled:
            0
        case .documentLocal:
            16_384
        case .parseSession(let maxEntries), .shared(let maxEntries):
            maxEntries
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

private enum GreenCacheEntryKey: Hashable {
    case token(TokenCacheKey)
    case node(NodeCacheKey)
}

final class GreenNodeCacheStorage<Lang: SyntaxLanguage>: @unchecked Sendable {
    private static var nodeCacheChildThreshold: Int {
        3
    }

    let policy: GreenCachePolicy
    var tokenCache: [TokenCacheKey: GreenToken<Lang>] = [:]
    var nodeCache: [NodeCacheKey: [GreenNode<Lang>]] = [:]
    private var evictionQueue: [GreenCacheEntryKey] = []
    private var evictionHead: Int = 0
    let interner: LocalTokenInternerStorage
    var hits: Int = 0
    var misses: Int = 0
    var bypasses: Int = 0
    var evictions: Int = 0

    init(policy: GreenCachePolicy, interner: LocalTokenInternerStorage = LocalTokenInternerStorage()) {
        switch policy {
        case .disabled, .documentLocal:
            break
        case .parseSession(let maxEntries), .shared(let maxEntries):
            precondition(maxEntries > 0, "Green cache entry limit must be positive")
        }
        self.policy = policy
        self.interner = interner
    }

    var isEnabled: Bool {
        policy.maxEntries > 0
    }

    func isNodeCacheEligible(childCount: Int) -> Bool {
        childCount <= Self.nodeCacheChildThreshold
    }

    func recordTokenInsertion(for key: TokenCacheKey) {
        if tokenCache[key] == nil {
            evictionQueue.append(.token(key))
        }
    }

    func recordNodeInsertion(for key: NodeCacheKey) {
        if nodeCache[key] == nil {
            evictionQueue.append(.node(key))
        }
    }

    func trimIfNeeded() {
        guard isEnabled else {
            tokenCache.removeAll(keepingCapacity: false)
            nodeCache.removeAll(keepingCapacity: false)
            evictionQueue.removeAll(keepingCapacity: false)
            evictionHead = 0
            return
        }

        let maxEntries = policy.maxEntries
        while tokenCache.count + nodeCache.count > maxEntries {
            guard evictionHead < evictionQueue.count else {
                break
            }

            let key = evictionQueue[evictionHead]
            evictionHead += 1

            switch key {
            case .token(let key):
                guard tokenCache.removeValue(forKey: key) != nil else {
                    continue
                }
                evictions += 1
            case .node(let key):
                guard nodeCache.removeValue(forKey: key) != nil else {
                    continue
                }
                evictions += 1
            }
        }

        compactEvictionQueueIfNeeded()
    }

    private func compactEvictionQueueIfNeeded() {
        guard evictionHead > 1_024, evictionHead * 2 > evictionQueue.count else {
            return
        }
        evictionQueue.removeFirst(evictionHead)
        evictionHead = 0
    }
}

/// Move-only green-node cache.
///
/// Owns the token interner and dedupes recurring green nodes during build.
/// Carry an instance forward across builders via `result.intoCache()` to
/// preserve structural sharing and token-key namespace identity for
/// incremental reparse. See `GreenCachePolicy` for caching rules and
/// thresholds.
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

    /// Cache lookups that returned an existing entry.
    public var hitCount: Int {
        storage.hits
    }

    /// Cache lookups that didn't find an entry and inserted a new one.
    public var missCount: Int {
        storage.misses
    }

    /// Calls that skipped lookup and insertion entirely. Increments when the
    /// policy is `.disabled` or when a node exceeds the cache's size
    /// threshold (see `GreenCachePolicy`).
    public var bypassCount: Int {
        storage.bypasses
    }

    /// Entries removed by FIFO eviction to keep the cache within
    /// `maxEntries`. A bucket of hash-colliding node candidates evicts as one
    /// entry.
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

    /// Return a (possibly cached) green token for `(kind, textLength, text)`.
    ///
    /// When caching is enabled, identical token shapes deduplicate to the
    /// same `GreenToken` storage. When the policy is `.disabled`, every call
    /// returns a fresh token and `bypassCount` increments.
    public mutating func makeToken(
        kind: RawSyntaxKind,
        textLength: TextSize,
        text: TokenTextStorage = .staticText
    ) -> GreenToken<Lang> {
        let key = TokenCacheKey(rawKind: kind, textLength: textLength, text: text)
        guard storage.isEnabled else {
            storage.bypasses += 1
            return GreenToken<Lang>(kind: kind, textLength: textLength, text: text)
        }

        if let cached = storage.tokenCache[key] {
            storage.hits += 1
            return cached
        }

        storage.misses += 1
        let token = GreenToken<Lang>(kind: kind, textLength: textLength, text: text)
        storage.recordTokenInsertion(for: key)
        storage.tokenCache[key] = token
        storage.trimIfNeeded()
        return token
    }

    /// Return a (possibly cached) green node for `(kind, children)`.
    ///
    /// Always allocates a candidate node first (its structural hash is the
    /// cache key). If the candidate has more than three total children, or
    /// the policy is `.disabled`, the candidate is returned directly and
    /// `bypassCount` increments — wide nodes recur too rarely to justify
    /// caching them. Otherwise, the cache is consulted: an equal entry is
    /// returned in place of the candidate (`hitCount`), or the candidate is
    /// inserted (`missCount`).
    public mutating func makeNode(
        kind: RawSyntaxKind,
        children: [GreenElement<Lang>]
    ) throws -> GreenNode<Lang> {
        let candidate = try GreenNode<Lang>(kind: kind, children: children)
        guard storage.isEnabled, storage.isNodeCacheEligible(childCount: candidate.childCount) else {
            storage.bypasses += 1
            return candidate
        }

        let key = NodeCacheKey(
            rawKind: candidate.rawKind,
            textLength: candidate.textLength,
            childCount: candidate.childCount,
            structuralHash: candidate.structuralHash
        )

        if let bucket = storage.nodeCache[key] {
            for existing in bucket where existing == candidate {
                storage.hits += 1
                return existing
            }
        }

        storage.misses += 1
        storage.recordNodeInsertion(for: key)
        storage.nodeCache[key, default: []].append(candidate)
        storage.trimIfNeeded()
        return candidate
    }

    consuming func takeStorage() -> GreenNodeCacheStorage<Lang> {
        storage
    }
}

public final class SharedGreenNodeCache<Lang: SyntaxLanguage>: @unchecked Sendable {
    private let shards: [MutexBox<GreenNodeCacheStorage<Lang>>]

    public init(policy: GreenCachePolicy = .shared(maxEntries: 16_384), shardCount: Int = 8) {
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

struct CacheReplacementTokenRemapper<Lang: SyntaxLanguage> {
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
                let newKey = replacementResolver.withUTF8(key) { bytes in
                    cache.intern(bytes)
                }
                internedMap[key] = newKey
                return newKey
            }()
            text = .interned(mapped)
        case .ownedLargeText(let id):
            let mapped = largeMap[id] ?? {
                let newID = cache.storeLargeText(replacementResolver.resolveLargeText(id))
                largeMap[id] = newID
                return newID
            }()
            text = .ownedLargeText(mapped)
        }
        return cache.makeToken(kind: token.rawKind, textLength: token.textLength, text: text)
    }
}

private struct DynamicTokenMaxima {
    var interned: UInt32?
    var large: UInt32?

    mutating func record(_ storage: TokenTextStorage) {
        switch storage {
        case .staticText, .missing:
            break
        case .interned(let key):
            interned = max(interned ?? key.rawValue, key.rawValue)
        case .ownedLargeText(let id):
            large = max(large ?? id.rawValue, id.rawValue)
        }
    }
}

private func dynamicTokenMaxima<Lang: SyntaxLanguage>(in node: GreenNode<Lang>) -> DynamicTokenMaxima {
    var maxima = DynamicTokenMaxima()
    recordDynamicTokenMaxima(in: node, into: &maxima)
    return maxima
}

private func recordDynamicTokenMaxima<Lang: SyntaxLanguage>(
    in node: GreenNode<Lang>,
    into maxima: inout DynamicTokenMaxima
) {
    for childIndex in 0..<node.childCount {
        switch node.child(at: childIndex) {
        case .node(let child):
            recordDynamicTokenMaxima(in: child, into: &maxima)
        case .token(let token):
            maxima.record(token.textStorage)
        }
    }
}

private func nextOverlayRawValue(after maxValue: UInt32?) -> UInt32 {
    guard let maxValue else {
        return 0
    }
    precondition(maxValue < UInt32.max, "Overlay token key space exhausted")
    return maxValue + 1
}

struct OverlayReplacementTokenRemapper<Lang: SyntaxLanguage> {
    var nextInterned: UInt32
    var nextLarge: UInt32
    var interned: [TokenKey: String] = [:]
    var large: [LargeTokenTextID: String] = [:]
    var internedMap: [TokenKey: TokenKey] = [:]
    var largeMap: [LargeTokenTextID: LargeTokenTextID] = [:]
    private var internedExhausted = false
    private var largeExhausted = false

    init(nextInterned: UInt32, nextLarge: UInt32) {
        self.nextInterned = nextInterned
        self.nextLarge = nextLarge
    }

    mutating func remap(
        node: GreenNode<Lang>,
        replacementResolver: any TokenResolver
    ) throws -> GreenNode<Lang> {
        var children: [GreenElement<Lang>] = []
        children.reserveCapacity(node.childCount)
        for childIndex in 0..<node.childCount {
            switch node.child(at: childIndex) {
            case .node(let child):
                children.append(.node(try remap(
                    node: child,
                    replacementResolver: replacementResolver
                )))
            case .token(let token):
                children.append(.token(remap(
                    token: token,
                    replacementResolver: replacementResolver
                )))
            }
        }
        return try GreenNode<Lang>(kind: node.rawKind, children: children)
    }

    mutating func remap(
        token: GreenToken<Lang>,
        replacementResolver: any TokenResolver
    ) -> GreenToken<Lang> {
        let text: TokenTextStorage
        switch token.textStorage {
        case .staticText:
            text = .staticText
        case .missing:
            text = .missing
        case .interned(let key):
            let mapped = internedMap[key] ?? {
                let newKey = nextOverlayTokenKey()
                internedMap[key] = newKey
                interned[newKey] = replacementResolver.resolve(key)
                return newKey
            }()
            text = .interned(mapped)
        case .ownedLargeText(let id):
            let mapped = largeMap[id] ?? {
                let newID = nextOverlayLargeTextID()
                largeMap[id] = newID
                large[newID] = replacementResolver.resolveLargeText(id)
                return newID
            }()
            text = .ownedLargeText(mapped)
        }
        return GreenToken<Lang>(kind: token.rawKind, textLength: token.textLength, text: text)
    }

    private mutating func nextOverlayTokenKey() -> TokenKey {
        precondition(!internedExhausted, "Overlay token key space exhausted")
        let key = TokenKey(nextInterned)
        if nextInterned == UInt32.max {
            internedExhausted = true
        } else {
            nextInterned += 1
        }
        return key
    }

    private mutating func nextOverlayLargeTextID() -> LargeTokenTextID {
        precondition(!largeExhausted, "Overlay large token text key space exhausted")
        let id = LargeTokenTextID(nextLarge)
        if nextLarge == UInt32.max {
            largeExhausted = true
        } else {
            nextLarge += 1
        }
        return id
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

private func rebuildReplacingCached<Lang: SyntaxLanguage>(
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
    let rebuilt = try rebuildReplacingCached(
        root: child,
        path: path.dropFirst(),
        replacement: replacement,
        cache: &cache
    )
    children[index] = .node(rebuilt)
    return try cache.makeNode(kind: root.rawKind, children: children)
}

private func rebuildReplacingDirect<Lang: SyntaxLanguage>(
    root: GreenNode<Lang>,
    path: ArraySlice<UInt32>,
    replacement: GreenNode<Lang>
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
    let rebuilt = try rebuildReplacingDirect(
        root: child,
        path: path.dropFirst(),
        replacement: replacement
    )
    children[index] = .node(rebuilt)
    return try GreenNode<Lang>(kind: root.rawKind, children: children)
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
    ///
    /// For full correctness when sharing a cache across builders or when
    /// the replacement was built independently of this tree, pass a `cache`
    /// whose interner is the one used to build this tree (typically
    /// obtained via `result.intoCache()`). When the cache shares this
    /// tree's namespace, the result tree's resolver is a fresh snapshot of
    /// the cache covering every key referenced by the new tree.
    ///
    /// In the rare case where the replacement is in the same namespace as
    /// this tree but the cache passed in is in a different namespace, this
    /// tree's resolver is reused as-is. If the replacement was taken from
    /// a fresher snapshot of the same shared interner, rendering may
    /// precondition-fail on keys that postdate this tree's snapshot. Pass
    /// a namespace-matching cache to avoid this.
    func replacing(
        _ handle: SyntaxNodeHandle<Lang>,
        with replacement: ResolvedGreenNode<Lang>,
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

        if oldSubtree.identity == replacement.root.identity {
            let witness = ReplacementWitness(
                oldRoot: oldRoot,
                newRoot: oldRoot,
                replacedPath: replacedPath,
                oldSubtree: oldSubtree,
                newSubtree: oldSubtree
            )
            return ReplacementResult(
                tree: SyntaxTree(root: oldRoot, resolver: resolver),
                witness: witness
            )
        }

        if let sourceNamespace = replacement.resolver.tokenKeyNamespace,
           let targetNamespace = resolver.tokenKeyNamespace,
           sourceNamespace === targetNamespace
        {
            let newRoot: GreenNode<Lang>
            let resultResolver: any TokenResolver
            if targetNamespace === cache.storage.interner.tokenKeyNamespace {
                newRoot = try rebuildReplacingCached(
                    root: oldRoot,
                    path: ArraySlice(replacedPath),
                    replacement: replacement.root,
                    cache: &cache
                )
                // Fresh snapshot of the cache's interner. Required for
                // correctness when the cache has grown beyond this tree's
                // resolver snapshot (e.g., another builder using the same
                // cache minted keys after this tree finished). The new
                // snapshot shares the cache's `tokenKeyNamespace`, so
                // namespace-identity continuity is preserved.
                let interner = LocalTokenInterner(storage: cache.storage.interner)
                resultResolver = interner.snapshot()
            } else {
                newRoot = try rebuildReplacingDirect(
                    root: oldRoot,
                    path: ArraySlice(replacedPath),
                    replacement: replacement.root
                )
                resultResolver = resolver
            }
            let witness = ReplacementWitness(
                oldRoot: oldRoot,
                newRoot: newRoot,
                replacedPath: replacedPath,
                oldSubtree: oldSubtree,
                newSubtree: replacement.root
            )
            return ReplacementResult(
                tree: SyntaxTree(root: newRoot, resolver: resultResolver),
                witness: witness
            )
        }

        if let targetNamespace = resolver.tokenKeyNamespace,
           targetNamespace === cache.storage.interner.tokenKeyNamespace
        {
            var remapper = CacheReplacementTokenRemapper<Lang>()
            let remappedReplacement = try remapper.remap(
                node: replacement.root,
                replacementResolver: replacement.resolver,
                cache: &cache
            )
            let newRoot: GreenNode<Lang>
            if oldSubtree.identity == remappedReplacement.identity {
                newRoot = oldRoot
            } else {
                newRoot = try rebuildReplacingCached(
                    root: oldRoot,
                    path: ArraySlice(replacedPath),
                    replacement: remappedReplacement,
                    cache: &cache
                )
            }
            // Fresh snapshot of the cache's interner. Re-interning may have
            // returned existing keys minted before this tree's resolver
            // snapshot was taken (e.g., from another builder sharing the
            // cache), so reusing `resolver` could leave the new tree
            // referencing keys outside its snapshot.
            let interner = LocalTokenInterner(storage: cache.storage.interner)
            let resultResolver = interner.snapshot()
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

        // Fallback for incompatible namespaces. The replacement subtree and
        // rebuilt ancestors intentionally bypass `GreenNodeCache`: the overlay
        // keys are resolver-local and caching them would make unrelated
        // replacements with equal raw synthetic keys share green identity.
        let candidateRoot = try rebuildReplacingDirect(
            root: oldRoot,
            path: ArraySlice(replacedPath),
            replacement: replacement.root
        )
        let maxima = dynamicTokenMaxima(in: candidateRoot)
        var remapper = OverlayReplacementTokenRemapper<Lang>(
            nextInterned: nextOverlayRawValue(after: maxima.interned),
            nextLarge: nextOverlayRawValue(after: maxima.large)
        )
        let remappedReplacement = try remapper.remap(
            node: replacement.root,
            replacementResolver: replacement.resolver
        )
        let newRoot = try rebuildReplacingDirect(
            root: oldRoot,
            path: ArraySlice(replacedPath),
            replacement: remappedReplacement
        )
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

    /// Same as `replacing(_:with:cache:)` for `ResolvedGreenNode`, but accepts
    /// a cacheless snapshot produced by an independent `GreenTreeBuilder`.
    func replacing(
        _ handle: SyntaxNodeHandle<Lang>,
        with replacement: GreenTreeSnapshot<Lang>,
        cache: inout GreenNodeCache<Lang>
    ) throws -> ReplacementResult<Lang> {
        try replacing(
            handle,
            with: ResolvedGreenNode(root: replacement.root, resolver: replacement.tokenText),
            cache: &cache
        )
    }

    /// Same as `replacing(_:with:cache:)` for `GreenTreeSnapshot`, but borrows
    /// the snapshot view from a cache-preserving build result.
    func replacing(
        _ handle: SyntaxNodeHandle<Lang>,
        with replacement: borrowing GreenBuildResult<Lang>,
        cache: inout GreenNodeCache<Lang>
    ) throws -> ReplacementResult<Lang> {
        try replacing(
            handle,
            with: ResolvedGreenNode(root: replacement.root, resolver: replacement.tokenText),
            cache: &cache
        )
    }
}
