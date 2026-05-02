import CambiumCore
import Synchronization

final class MutexBox<Value>: @unchecked Sendable {
    let mutex: Mutex<Value>

    init(_ value: sending Value) {
        self.mutex = Mutex(value)
    }
}

private enum BuilderIDGenerator {
    static let next = Atomic<UInt64>(1)

    static func make() -> UInt64 {
        let result = next.wrappingAdd(1, ordering: .relaxed)
        return result.oldValue
    }
}

/// Caching policy for ``CambiumBuilder/GreenNodeCache``.
///
/// All policies cache tokens unconditionally when caching is enabled.
/// Green nodes are subject to a fixed size threshold: nodes with more than
/// three total children (matching cstree's default) bypass the cache and
/// are returned without lookup or insertion. Wide nodes rarely recur
/// structurally, and caching them tends to evict useful small entries
/// while rarely paying off as a cache hit.
///
/// Eviction is deterministic FIFO across the union of token and node
/// entries, triggered when the combined entry count would exceed
/// `maxEntries`.
///
/// Pick a policy based on the lifetime of the cache:
///
/// - One-off build, small-to-medium document: ``documentLocal``.
/// - Long-lived editor session that reparses via incremental parsing:
///   ``parseSession(maxEntries:)`` and carry the cache across builders
///   with ``CambiumBuilder/GreenBuildResult/intoCache()``.
/// - Multiple concurrent builders sharing a vocabulary:
///   ``shared(maxEntries:)`` paired with ``CambiumBuilder/SharedGreenNodeCache``.
public enum GreenCachePolicy: Sendable, Hashable {
    /// No caching. Every `makeToken` and `makeNode` call returns a fresh
    /// allocation; ``GreenNodeCache/bypassCount`` increments per call.
    case disabled

    /// Per-document cache fixed at 16,384 entries. Suitable for one-shot
    /// builds and small-to-medium documents.
    case documentLocal

    /// Parse-session cache with an explicit entry limit. Use this when
    /// carrying the cache forward across reparses via
    /// ``CambiumBuilder/GreenBuildResult/intoCache()``. `maxEntries` must be positive;
    /// pass ``disabled`` to opt out of caching.
    case parseSession(maxEntries: Int)

    /// Shared cache budget for cross-builder use (e.g. via
    /// ``CambiumBuilder/SharedGreenNodeCache``). `maxEntries` must be positive.
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

/// A single-owner token interner for in-process use.
///
/// `LocalTokenInterner` deduplicates short token text and stores
/// large-text payloads for a single builder context. It conforms to
/// ``CambiumCore/TokenInterner`` but **deliberately does not conform to
/// ``CambiumCore/TokenResolver``** — the only path to a resolver is via
/// ``makeResolver()``, which produces a frozen ``CambiumCore/TokenTextSnapshot``.
/// Keeping the interner off the resolver surface means a single-owner
/// mutable store cannot accidentally be passed where a thread-safe
/// resolver is expected.
///
/// `LocalTokenInterner` is **not** `Sendable`. Single-owner discipline is a
/// documented contract: do not share an instance between threads. For
/// concurrent interning across multiple builders, use
/// ``CambiumBuilder/SharedTokenInterner``.
public final class LocalTokenInterner: TokenInterner {
    private let storage: LocalTokenInternerStorage

    /// The interner's namespace identity. Stable for the lifetime of
    /// this instance.
    public var namespace: TokenKeyNamespace {
        storage.tokenKeyNamespace
    }

    /// Construct a fresh interner with its own ``CambiumCore/TokenKeyNamespace``.
    public init() {
        self.storage = LocalTokenInternerStorage()
    }

    init(storage: LocalTokenInternerStorage) {
        self.storage = storage
    }

    /// Intern `text` and return its ``CambiumCore/TokenKey``. Repeated calls
    /// with the same text return the same key.
    public func intern(_ text: String) -> TokenKey {
        var copy = text
        return copy.withUTF8 { bytes in
            internValidated(text, bytes: bytes)
        }
    }

    /// Intern a UTF-8 byte sequence and return its ``CambiumCore/TokenKey``.
    /// Validates `bytes` as UTF-8 on first insertion; throws
    /// ``CambiumCore/TokenTextError/invalidUTF8`` for ill-formed input.
    public func intern(_ bytes: UnsafeBufferPointer<UInt8>) throws -> TokenKey {
        let keyBytes = Array(bytes)
        if let key = storage.keysByText[keyBytes] {
            return key
        }
        guard let text = String(validating: keyBytes, as: UTF8.self) else {
            throw TokenTextError.invalidUTF8
        }
        return internValidated(text, keyBytes: keyBytes)
    }

    private func internValidated(_ text: String, bytes: UnsafeBufferPointer<UInt8>) -> TokenKey {
        internValidated(text, keyBytes: Array(bytes))
    }

    private func internValidated(_ text: String, keyBytes: [UInt8]) -> TokenKey {
        if let key = storage.keysByText[keyBytes] {
            return key
        }
        let key = TokenKey(UInt32(storage.textByKey.count))
        storage.keysByText[keyBytes] = key
        storage.textByKey.append(text)
        return key
    }

    /// Store `text` in the large-text table without interning, and return
    /// its ``CambiumCore/LargeTokenTextID``. Use for unique payloads where
    /// hash-interning would only waste hash work.
    public func storeLargeText(_ text: String) -> LargeTokenTextID {
        let id = LargeTokenTextID(UInt32(storage.largeText.count))
        storage.largeText.append(text)
        return id
    }

    /// Return an immutable snapshot of the interner's current contents
    /// to associate with a finished tree. Each call constructs a fresh
    /// ``CambiumCore/TokenTextSnapshot`` (an O(n) copy of the interned-strings
    /// arrays) — the builder calls this exactly once at `finish()` time
    /// and stores the result on the build result.
    public func makeResolver() -> any TokenResolver {
        snapshot()
    }

    /// Take an immutable snapshot of the interner's current contents,
    /// suitable as a tree's resolver. Equivalent to ``makeResolver()``
    /// returning a concrete `TokenTextSnapshot` (not erased to
    /// `any TokenResolver`); kept on the class for callers that want
    /// the concrete type.
    public func snapshot() -> TokenTextSnapshot {
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
/// `SharedTokenInterner` is a thread-safe interner/resolver for custom
/// pipelines that concurrently intern from the same vocabulary (multiple
/// parses of related files, background indexers running alongside
/// foreground edits). ``CambiumBuilder/GreenTreeBuilder`` owns a local interner through
/// ``CambiumBuilder/GreenNodeCache``; use this type when you are constructing green
/// tokens yourself or otherwise need a shared `TokenResolver` outside
/// the builder's local-cache lifecycle.
///
/// **Token-key layout.** `TokenKey` values produced by this interner are
/// runtime-local. The current encoding uses the high 8 bits for the shard
/// index and the low 24 bits for the per-shard local index, so at most
/// 256 shards and 16,777,216 distinct token texts per shard are
/// representable. Exhausting a shard traps; pick a shard count appropriate
/// for the expected token vocabulary size.
public final class SharedTokenInterner: TokenResolver, TokenInterner, @unchecked Sendable {
    struct Shard {
        var keysByText: [[UInt8]: TokenKey] = [:]
        var textByKey: [String] = []
    }

    private let shards: [MutexBox<Shard>]

    /// Single-mutex large-text storage. Large-text writes are rare (one
    /// per long string literal); contention with small-token interning is
    /// segregated by mutex (small-token interning hits a per-shard
    /// `MutexBox<Shard>`, large-text writes hit this independent box), so
    /// neither path blocks the other.
    private let largeTexts: MutexBox<[String]> = MutexBox([])

    /// The interner's namespace identity. Stable for the lifetime of
    /// this instance. Trees that resolve through this interner share
    /// this namespace, so subtree reuse via
    /// ``CambiumBuilder/GreenTreeBuilder/reuseSubtree(_:)`` can fast-path
    /// (``CambiumBuilder/SubtreeReuseOutcome/direct``).
    public let namespace: TokenKeyNamespace = TokenKeyNamespace()

    /// `TokenResolver`-side optional bridging to ``namespace``. Always
    /// non-nil for a `SharedTokenInterner`.
    public var tokenKeyNamespace: TokenKeyNamespace? { namespace }

    /// Construct a thread-safe interner with `shardCount` shards.
    /// Default of 8 is appropriate for moderate concurrency; raise to
    /// reduce contention on multi-core systems with many concurrent
    /// builders.
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

    /// Intern `text` and return its `TokenKey`. Repeated calls with the
    /// same text return the same key. Thread-safe.
    public func intern(_ text: String) -> TokenKey {
        var copy = text
        return copy.withUTF8 { bytes in
            internValidated(text, bytes: bytes)
        }
    }

    /// Intern a UTF-8 byte sequence and return its `TokenKey`. Validates
    /// `bytes` as UTF-8 on first insertion; throws `TokenTextError.invalidUTF8`
    /// for ill-formed input. Thread-safe.
    ///
    /// Splits the lookup and the insert into two shard-mutex acquisitions so
    /// UTF-8 validation does not run under the lock. Validation is O(n) over
    /// `bytes`; holding the shard mutex through it would serialize every
    /// other thread that hashes to the same shard for the duration of a long
    /// token's validation. The two-acquisition shape keeps both critical
    /// sections short (a single dictionary read on the fast path, a
    /// re-checked insert on the slow path) at the cost of one extra
    /// acquisition per miss. The slow path's re-check closes the TOCTOU
    /// window between the two acquisitions: if another thread inserted the
    /// same `keyBytes` while we were validating, we return its key.
    public func intern(_ bytes: UnsafeBufferPointer<UInt8>) throws -> TokenKey {
        let keyBytes = Array(bytes)
        let shardIndex = SharedTokenInternerKeyLayout.shardIndex(
            forHash: keyBytes.hashValue,
            shardCount: shards.count
        )
        if let key = shards[shardIndex].mutex.withLock({ shard in
            shard.keysByText[keyBytes]
        }) {
            return key
        }
        guard let text = String(validating: keyBytes, as: UTF8.self) else {
            throw TokenTextError.invalidUTF8
        }
        return internValidated(text, keyBytes: keyBytes, shardIndex: shardIndex)
    }

    private func internValidated(_ text: String, bytes: UnsafeBufferPointer<UInt8>) -> TokenKey {
        let keyBytes = Array(bytes)
        let shardIndex = SharedTokenInternerKeyLayout.shardIndex(
            forHash: keyBytes.hashValue,
            shardCount: shards.count
        )
        return internValidated(text, keyBytes: keyBytes, shardIndex: shardIndex)
    }

    private func internValidated(_ text: String, keyBytes: [UInt8], shardIndex: Int) -> TokenKey {
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
            shard.textByKey.append(text)
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

    /// Append `text` to the large-text table and return its
    /// ``CambiumCore/LargeTokenTextID``. Thread-safe. Traps if the table
    /// would exceed `UInt32.max` entries.
    public func storeLargeText(_ text: String) -> LargeTokenTextID {
        largeTexts.mutex.withLock { storage in
            guard let raw = UInt32(exactly: storage.count) else {
                preconditionFailure(
                    "SharedTokenInterner exhausted its \(UInt32.max)-entry large-text key space"
                )
            }
            storage.append(text)
            return LargeTokenTextID(raw)
        }
    }

    public func resolveLargeText(_ id: LargeTokenTextID) -> String {
        let index = Int(id.rawValue)
        return largeTexts.mutex.withLock { storage in
            precondition(
                storage.indices.contains(index),
                "Unknown shared large token text id \(id.rawValue)"
            )
            return storage[index]
        }
    }

    public func withLargeTextUTF8<R>(
        _ id: LargeTokenTextID,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        let text = resolveLargeText(id)
        return try text.utf8.withContiguousStorageIfAvailable(body)
            ?? Array(text.utf8).withUnsafeBufferPointer(body)
    }

    /// Return `self` as the resolver for a finished tree. Reading the
    /// resolver always sees the live shared interner, including any new
    /// keys minted after the tree was sealed; the existing keys remain
    /// valid because `SharedTokenInterner` does not evict.
    public func makeResolver() -> any TokenResolver {
        self
    }

    /// Total number of distinct interned token texts across every shard.
    /// Inspecting this in long-lived editor sessions is the cheapest way
    /// to observe vocabulary growth and check for shard exhaustion before
    /// it traps. Acquires every shard mutex sequentially; intended for
    /// telemetry, not the inner loop.
    public var count: Int {
        shards.reduce(0) { running, shard in
            running + shard.mutex.withLock { $0.textByKey.count }
        }
    }

    /// Number of large-text payloads stored. `SharedTokenInterner` does
    /// not deduplicate large text, so each `storeLargeText(_:)` call
    /// increments this by one.
    public var largeTextCount: Int {
        largeTexts.mutex.withLock { $0.count }
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
    var hits: Int = 0
    var misses: Int = 0
    var bypasses: Int = 0
    var evictions: Int = 0

    init(policy: GreenCachePolicy) {
        switch policy {
        case .disabled, .documentLocal:
            break
        case .parseSession(let maxEntries), .shared(let maxEntries):
            precondition(maxEntries > 0, "Green cache entry limit must be positive")
        }
        self.policy = policy
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
/// Pure structural-dedup pool for recurring green nodes during build.
/// The cache does not own a token interner — it is bound to one via
/// ``CambiumBuilder/GreenTreeContext``, and forwarded across builders
/// inside that context via
/// ``CambiumBuilder/GreenBuildResult/intoContext()`` to preserve
/// structural sharing and token-key namespace identity for incremental
/// reparse. See ``CambiumBuilder/GreenCachePolicy`` for caching rules
/// and thresholds.
///
/// The cache is `~Copyable` so its ownership is unambiguous: there is
/// always exactly one owner of a given cache, and that owner can hand it
/// off explicitly to another builder via `consume`.
///
/// **Counters.** ``hitCount``, ``missCount``, ``bypassCount``, and
/// ``evictionCount`` summarize the cache's effectiveness. Inspect them
/// in tests or telemetry to verify your incremental pipeline is
/// preserving structural sharing as intended.
public struct GreenNodeCache<Lang: SyntaxLanguage>: ~Copyable {
    fileprivate let storage: GreenNodeCacheStorage<Lang>

    /// Construct a fresh cache. The default policy is ``CambiumBuilder/GreenCachePolicy/documentLocal``.
    public init(policy: GreenCachePolicy = .documentLocal) {
        self.storage = GreenNodeCacheStorage(policy: policy)
    }

    init(storage: GreenNodeCacheStorage<Lang>) {
        self.storage = storage
    }

    /// The caching policy in effect.
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

/// Bundle of `(interner, cache)`, namespace-bound by construction.
///
/// `GreenNodeCache` keys node storage by raw ``CambiumCore/TokenKey`` values.
/// Mixing a cache populated under one interner's namespace with another
/// interner silently returns wrong storage *and* defeats green-node
/// identity (`ObjectIdentifier`) as the "same subtree" signal.
/// `GreenTreeContext` makes the namespace pairing structural: the only
/// public paths to construct a context bind a fresh cache to a chosen
/// interner from birth, and the only path to reuse an existing cache is
/// `GreenBuildResult.intoContext()`, which preserves whatever pairing
/// the prior context established.
///
/// Use a context to drive a ``CambiumBuilder/GreenTreeBuilder``:
///
/// ```swift
/// let context = GreenTreeContext<MyLang>(policy: .documentLocal)
/// var builder = GreenTreeBuilder(context: consume context)
/// // ... drive the builder ...
/// let result = try builder.finish()
/// // For a follow-up parse with structural reuse:
/// var next = GreenTreeBuilder(context: consume result.intoContext())
/// ```
public struct GreenTreeContext<Lang: SyntaxLanguage>: ~Copyable {
    /// The interner this context's keys belong to.
    public let interner: any TokenInterner

    /// The structural-dedup cache. Bound to ``interner``'s namespace by
    /// construction; never mix with a cache from a different context.
    ///
    /// Internal access only: external mutation could populate the cache
    /// with token-text storage referencing keys not minted by this
    /// context's ``interner``, silently weakening the namespace
    /// invariant the type is meant to enforce. The builder consumes
    /// the context (and with it, this cache) through
    /// ``CambiumBuilder/GreenTreeBuilder/init(context:)``.
    internal var cache: GreenNodeCache<Lang>

    /// Adopt an external interner; mint a fresh cache subject to `policy`.
    public init(interner: any TokenInterner, policy: GreenCachePolicy = .documentLocal) {
        self.interner = interner
        self.cache = GreenNodeCache(policy: policy)
    }

    /// Convenience for one-shot builds: mints a fresh ``LocalTokenInterner``
    /// and a fresh cache, paired from birth.
    public init(policy: GreenCachePolicy = .documentLocal) {
        self.init(interner: LocalTokenInterner(), policy: policy)
    }

    /// **Internal only.** Rebind a previously-paired (interner, cache)
    /// into a context. The single legal caller is
    /// ``CambiumBuilder/GreenBuildResult/intoContext()``, which knows the
    /// pairing came from a prior context and is therefore namespace-safe.
    /// No public path exposes this initializer; arbitrary user pairings
    /// would reintroduce the silent green-identity corruption hazard
    /// that motivates the context wrapper in the first place.
    internal init(interner: any TokenInterner, cache: consuming GreenNodeCache<Lang>) {
        self.interner = interner
        self.cache = cache
    }

    /// The active green-node cache policy.
    public var cachePolicy: GreenCachePolicy { cache.policy }

    /// Number of green-cache lookups that returned an existing entry.
    /// See ``CambiumBuilder/GreenNodeCache/hitCount``.
    public var cacheHitCount: Int { cache.hitCount }

    /// Number of green-cache lookups that inserted a new entry.
    /// See ``CambiumBuilder/GreenNodeCache/missCount``.
    public var cacheMissCount: Int { cache.missCount }

    /// Number of green-cache calls that skipped the cache entirely
    /// (disabled policy or a wide-node bypass).
    /// See ``CambiumBuilder/GreenNodeCache/bypassCount``.
    public var cacheBypassCount: Int { cache.bypassCount }

    /// Number of green-cache entries removed by FIFO eviction.
    /// See ``CambiumBuilder/GreenNodeCache/evictionCount``.
    public var cacheEvictionCount: Int { cache.evictionCount }
}

/// A thread-safe, sharded ``CambiumBuilder/GreenNodeCache`` for cross-builder use.
///
/// `SharedGreenNodeCache` keeps a fixed number of cache shards behind
/// mutexes, sharded by raw kind. Pass it to multiple concurrent builders
/// when they should share dedup; each builder borrows its kind's shard
/// inside ``withShard(for:_:)``.
///
/// For most workflows a single ``CambiumBuilder/GreenNodeCache`` carried forward across
/// reparses is enough — reach for this type only when concurrent builders
/// genuinely need to share storage.
public final class SharedGreenNodeCache<Lang: SyntaxLanguage>: @unchecked Sendable {
    private let shards: [MutexBox<GreenNodeCacheStorage<Lang>>]

    /// Construct a shared cache with `shardCount` shards, each subject to
    /// `policy`.
    public init(policy: GreenCachePolicy = .shared(maxEntries: 16_384), shardCount: Int = 8) {
        precondition(shardCount > 0, "SharedGreenNodeCache requires at least one shard")
        self.shards = (0..<shardCount).map { _ in
            MutexBox(GreenNodeCacheStorage(policy: policy))
        }
    }

    /// Borrow the shard for `rawKind` under its mutex and run `body` with
    /// a mutable ``CambiumBuilder/GreenNodeCache`` view. The cache is borrowed for the
    /// duration of the closure; do not let it escape.
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

/// A snapshot of a ``CambiumBuilder/GreenTreeBuilder``'s state, captured by
/// ``GreenTreeBuilder/checkpoint()`` so the builder can later "rewind" or
/// retroactively wrap the children appended since the checkpoint.
///
/// Checkpoints make it possible to write a recursive-descent parser that
/// commits to wrapping children inside a node only **after** seeing later
/// tokens — for example, deciding to wrap a parsed integer inside an
/// `Expr` node only once the parser sees a `+` follow-up. See
/// ``GreenTreeBuilder/startNode(at:_:)`` and
/// ``GreenTreeBuilder/revert(to:)``.
///
/// A checkpoint is bound to the builder that minted it. Using it against
/// any other builder throws ``CambiumBuilder/GreenTreeBuilderError/invalidCheckpoint``.
public struct BuilderCheckpoint: Sendable, Hashable {
    fileprivate let builderID: UInt64
    fileprivate let parentID: UInt64?
    fileprivate let parentCount: Int
    fileprivate let childCount: Int

    fileprivate init(
        builderID: UInt64,
        parentID: UInt64?,
        parentCount: Int,
        childCount: Int
    ) {
        self.builderID = builderID
        self.parentID = parentID
        self.parentCount = parentCount
        self.childCount = childCount
    }
}

/// Errors thrown by ``CambiumBuilder/GreenTreeBuilder``.
public enum GreenTreeBuilderError: Error, Sendable, Equatable {
    /// ``CambiumBuilder/GreenTreeBuilder/finish()`` was called with `Int` open `startNode`
    /// frames still on the stack. Indicates a missing
    /// ``GreenTreeBuilder/finishNode()``.
    case unbalancedStartNodes(Int)

    /// ``GreenTreeBuilder/finishNode()`` was called with no open frame.
    case finishWithoutNode

    /// ``CambiumBuilder/GreenTreeBuilder/finish()`` was called with no children appended;
    /// every tree must have a root node.
    case noRoot

    /// ``CambiumBuilder/GreenTreeBuilder/finish()`` was called with multiple top-level
    /// children. Wrap them in a single root node before finishing.
    case multipleRoots(Int)

    /// A checkpoint was used against the wrong builder, or after the
    /// builder's state moved past the checkpoint in a way that makes the
    /// rewind incoherent (e.g., reverting to a checkpoint whose parent
    /// frame has already been finished).
    case invalidCheckpoint

    /// A path-based replacement helper traversed a child slot expected to
    /// hold a node but found a token instead.
    case childIndexIsToken

    /// ``CambiumBuilder/GreenTreeBuilder/staticToken(_:)`` was called with a kind whose
    /// `SyntaxLanguage.staticText(for:)` is `nil`.
    case staticTextUnavailable(RawSyntaxKind)

    /// A static-text token's bytes would not fit in a `TextSize`. Should
    /// not arise in practice — static text is bounded.
    case staticTextLengthOverflow

    /// Raised when ``CambiumBuilder/GreenTreeBuilder/token(_:text:)`` or
    /// ``CambiumBuilder/GreenTreeBuilder/largeToken(_:text:)`` is called with a kind
    /// whose `SyntaxLanguage.staticText(for:)` is non-`nil`. Static-text
    /// kinds belong on the ``CambiumBuilder/GreenTreeBuilder/staticToken(_:)`` path;
    /// the dynamic-text paths are reserved for kinds that don't have
    /// grammar-determined text.
    case staticKindRequiresStaticToken(RawSyntaxKind)
}

struct OpenNode {
    var id: UInt64
    var kind: RawSyntaxKind
    var firstChildIndex: Int
}

/// Cacheless snapshot of a finished green tree.
///
/// `GreenTreeSnapshot` is the copyable `(root, resolver)` view of a tree.
/// It is sufficient for rendering, serialization
/// (`SharedSyntaxTree.serializeGreenSnapshot()` and friends), and
/// creating a `SyntaxTree` via ``makeSyntaxTree()``. It does not carry
/// the reusable builder cache needed for identity-preserving incremental
/// reuse — for that, hold onto a ``CambiumBuilder/GreenBuildResult`` and
/// pass it through ``CambiumBuilder/GreenBuildResult/intoContext()``.
///
/// **Frozenness depends on the resolver's type.** A `TokenTextSnapshot`
/// (the resolver returned by ``LocalTokenInterner/makeResolver()``) is
/// frozen by construction. A live `SharedTokenInterner` (the resolver it
/// returns from `makeResolver()`) may continue to accept new interns,
/// though existing keys remain valid because shared interners do not
/// evict. If you need a guaranteed-frozen snapshot — e.g., for
/// serialization or hand-off across process boundaries —
/// `GreenSnapshotEncoder`/`GreenSnapshotDecoder` always produces a
/// fresh `TokenTextSnapshot` on decode.
public struct GreenTreeSnapshot<Lang: SyntaxLanguage>: Sendable {
    /// The green root.
    public let root: GreenNode<Lang>

    /// The resolver that resolves every dynamic key in `root`.
    public let resolver: any TokenResolver

    /// Pair a green root with the resolver it depends on.
    public init(root: GreenNode<Lang>, resolver: any TokenResolver) {
        self.root = root
        self.resolver = resolver
    }

    /// Construct a fresh `SyntaxTree` from this snapshot.
    public func makeSyntaxTree() -> SyntaxTree<Lang> {
        SyntaxTree(root: root, resolver: resolver)
    }
}

/// Result of finishing a builder.
///
/// `GreenBuildResult` is the move-only return type of
/// ``CambiumBuilder/GreenTreeBuilder/finish()``. It bundles the freshly
/// built green root, the resolver associated with the tree (sealed once
/// at finish time via ``CambiumCore/TokenInterner/makeResolver()``), and
/// the builder's context (interner + cache) for forwarding to a follow-up
/// builder via ``intoContext()`` — the key to identity-preserving
/// incremental parsing.
///
/// ```swift
/// let firstResult = try builder.finish()
/// let firstTree = firstResult.snapshot.makeSyntaxTree()
/// let context = firstResult.intoContext()
///
/// // Later, for a reparse:
/// var nextBuilder = GreenTreeBuilder<Calc>(context: consume context)
/// // ...drive nextBuilder; reuseSubtree calls hit the fast path
/// ```
public struct GreenBuildResult<Lang: SyntaxLanguage>: ~Copyable {
    /// The green root of the finished tree.
    public let root: GreenNode<Lang>

    /// Resolver associated with this tree. Sealed once at `finish()`
    /// time via ``CambiumCore/TokenInterner/makeResolver()``; this is a
    /// stored property, not computed, so successive accesses do not
    /// re-snapshot (which for ``LocalTokenInterner`` would copy the
    /// interned-strings array on every read).
    public let resolver: any TokenResolver

    private let interner: any TokenInterner
    private var cache: GreenNodeCache<Lang>

    /// Construct a result from explicit parts. Most code obtains a result
    /// by calling ``CambiumBuilder/GreenTreeBuilder/finish()``.
    internal init(
        root: GreenNode<Lang>,
        resolver: any TokenResolver,
        interner: any TokenInterner,
        cache: consuming GreenNodeCache<Lang>
    ) {
        self.root = root
        self.resolver = resolver
        self.interner = interner
        self.cache = cache
    }

    /// A copyable, cacheless view of `(root, resolver)`. Reuses the
    /// already-sealed resolver — does not invoke `makeResolver()` again.
    public var snapshot: GreenTreeSnapshot<Lang> {
        GreenTreeSnapshot(root: root, resolver: resolver)
    }

    /// Consume this result and return the context for the next builder.
    /// Carries (interner, cache) as a unit — namespace pairing preserved.
    ///
    /// Read ``root``, ``resolver``, ``snapshot``,
    /// `snapshot.makeSyntaxTree()`, or any of the cache-statistics
    /// accessors below before calling this method — the result is
    /// consumed.
    public consuming func intoContext() -> GreenTreeContext<Lang> {
        GreenTreeContext(interner: interner, cache: cache)
    }

    /// Number of green-cache lookups during this build that returned an
    /// existing entry. See ``CambiumBuilder/GreenNodeCache/hitCount``.
    public var cacheHitCount: Int { cache.hitCount }

    /// Number of green-cache lookups during this build that inserted a
    /// new entry. See ``CambiumBuilder/GreenNodeCache/missCount``.
    public var cacheMissCount: Int { cache.missCount }

    /// Number of green-cache calls during this build that skipped the
    /// cache entirely (disabled policy or wide-node bypass).
    /// See ``CambiumBuilder/GreenNodeCache/bypassCount``.
    public var cacheBypassCount: Int { cache.bypassCount }

    /// Number of green-cache entries removed by FIFO eviction during this
    /// build. See ``CambiumBuilder/GreenNodeCache/evictionCount``.
    public var cacheEvictionCount: Int { cache.evictionCount }
}

/// How `GreenTreeBuilder.reuseSubtree(_:)` accepted a subtree.
///
/// Use this to observe whether reuse preserved green storage identity from
/// the source tree (`.direct`) or had to rebuild the subtree because the
/// source resolver's token-key namespace did not match the builder's
/// (`.remapped`). A high `.remapped` rate in incremental parsing usually
/// signals that the integrator failed to carry the context forward
/// through `result.intoContext()`.
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
    // Overlay keys are resolver-local synthetic keys, not entries in the
    // base/cache interner. Advertising the base namespace would let
    // `reuseSubtree` direct-reuse green nodes whose keys a later cache
    // snapshot cannot resolve.
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
        cache: inout GreenNodeCache<Lang>,
        interner: any TokenInterner
    ) throws -> GreenNode<Lang> {
        var children: [GreenElement<Lang>] = []
        children.reserveCapacity(node.childCount)
        for childIndex in 0..<node.childCount {
            switch node.child(at: childIndex) {
            case .node(let child):
                children.append(.node(try remap(
                    node: child,
                    replacementResolver: replacementResolver,
                    cache: &cache,
                    interner: interner
                )))
            case .token(let token):
                children.append(.token(try remap(
                    token: token,
                    replacementResolver: replacementResolver,
                    cache: &cache,
                    interner: interner
                )))
            }
        }
        return try cache.makeNode(kind: node.rawKind, children: children)
    }

    mutating func remap(
        token: GreenToken<Lang>,
        replacementResolver: any TokenResolver,
        cache: inout GreenNodeCache<Lang>,
        interner: any TokenInterner
    ) throws -> GreenToken<Lang> {
        let text: TokenTextStorage
        switch token.textStorage {
        case .staticText:
            text = .staticText
        case .missing:
            text = .missing
        case .interned(let key):
            let mapped: TokenKey
            if let existing = internedMap[key] {
                mapped = existing
            } else {
                let newKey = try replacementResolver.withUTF8(key) { bytes in
                    try interner.intern(bytes)
                }
                internedMap[key] = newKey
                mapped = newKey
            }
            text = .interned(mapped)
        case .ownedLargeText(let id):
            let mapped = largeMap[id] ?? {
                let newID = interner.storeLargeText(replacementResolver.resolveLargeText(id))
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
        cache: inout GreenNodeCache<Lang>,
        interner: any TokenInterner
    ) throws -> GreenNode<Lang> {
        var children: [GreenElement<Lang>] = []
        children.reserveCapacity(node.childCount)
        for childIndex in 0..<node.childCount {
            switch node.child(at: childIndex) {
            case .node(let child):
                children.append(.node(try remap(
                    node: child,
                    sourceResolver: sourceResolver,
                    cache: &cache,
                    interner: interner
                )))
            case .token(let token):
                children.append(.token(try remap(
                    token: token,
                    sourceResolver: sourceResolver,
                    cache: &cache,
                    interner: interner
                )))
            }
        }
        return try cache.makeNode(kind: node.rawKind, children: children)
    }

    mutating func remap(
        token: GreenToken<Lang>,
        sourceResolver: any TokenResolver,
        cache: inout GreenNodeCache<Lang>,
        interner: any TokenInterner
    ) throws -> GreenToken<Lang> {
        let text: TokenTextStorage
        switch token.textStorage {
        case .staticText:
            text = .staticText
        case .missing:
            text = .missing
        case .interned(let key):
            let mapped: TokenKey
            if let existing = internedMap[key] {
                mapped = existing
            } else {
                let newKey = try sourceResolver.withUTF8(key) { bytes in
                    try interner.intern(bytes)
                }
                internedMap[key] = newKey
                mapped = newKey
            }
            text = .interned(mapped)
        case .ownedLargeText(let id):
            let mapped = largeMap[id] ?? {
                let newID = interner.storeLargeText(sourceResolver.resolveLargeText(id))
                largeMap[id] = newID
                return newID
            }()
            text = .ownedLargeText(mapped)
        }
        return cache.makeToken(kind: token.rawKind, textLength: token.textLength, text: text)
    }
}

/// The event-style builder used by parsers to construct a green tree.
///
/// `GreenTreeBuilder` follows cstree's event-stream shape: parsers tell
/// the builder when to start a node, when to emit a token, and when to
/// finish the open node. Behind the scenes the builder dedupes nodes and
/// tokens through a ``CambiumBuilder/GreenNodeCache`` and accumulates children for the
/// open frame.
///
/// ## Lifecycle
///
/// 1. Construct with ``init(policy:)`` (one-shot build) or
///    ``init(cache:)`` (carry forward a cache from a prior parse to
///    preserve structural sharing).
/// 2. Drive the builder with ``startNode(_:)``, ``token(_:text:)``,
///    ``staticToken(_:)``, ``finishNode()``, and friends.
/// 3. Call ``finish()`` to consume the builder and return a
///    ``CambiumBuilder/GreenBuildResult`` containing the green root, the token-text
///    snapshot, and the cache (for the next reparse).
///
/// ## Token kinds
///
/// The builder enforces the static-vs-dynamic split. A kind whose
/// `SyntaxLanguage.staticText(for:)` returns non-`nil` must use
/// ``staticToken(_:)`` (or ``missingToken(_:)`` for an empty
/// placeholder); a kind whose static text is `nil` must use
/// ``token(_:text:)`` or ``largeToken(_:text:)``. Mixing them throws
/// the corresponding ``CambiumBuilder/GreenTreeBuilderError``.
///
/// ## Checkpoints and retroactive wrapping
///
/// Parsers that don't yet know whether to wrap children in a node when
/// they encounter the start of a construct can call ``checkpoint()`` to
/// remember the current builder state, parse forward, and then wrap the
/// new children retroactively with ``startNode(at:_:)``. Use
/// ``revert(to:)`` to discard work after speculative parsing.
///
/// ## Subtree reuse for incremental parsing
///
/// ``reuseSubtree(_:)`` accepts a borrowed cursor from a prior tree and
/// splices its green storage into the new tree. When the source tree's
/// resolver shares this builder's namespace the splice is direct
/// (``CambiumBuilder/SubtreeReuseOutcome/direct``); otherwise the subtree is
/// re-interned and rebuilt (``CambiumBuilder/SubtreeReuseOutcome/remapped``). Carry
/// the cache across parses with ``CambiumBuilder/GreenBuildResult/intoCache()`` to keep
/// the namespace stable.
///
/// ## Topics
///
/// ### Constructing
/// - ``init(context:)``
/// - ``init(policy:)``
/// - ``init(interner:policy:)``
///
/// ### Building structure
/// - ``startNode(_:)``
/// - ``startNode(rawKind:)``
/// - ``finishNode()``
/// - ``missingNode(_:)``
///
/// ### Emitting tokens
/// - ``token(_:text:)``
/// - ``token(_:bytes:)``
/// - ``staticToken(_:)``
/// - ``missingToken(_:)``
/// - ``largeToken(_:text:)``
///
/// ### Checkpoints
/// - ``checkpoint()``
/// - ``startNode(at:_:)``
/// - ``revert(to:)``
///
/// ### Subtree reuse
/// - ``reuseSubtree(_:)``
///
/// ### Finishing
/// - ``finish()``
public struct GreenTreeBuilder<Lang: SyntaxLanguage>: ~Copyable {
    private let builderID: UInt64
    private let interner: any TokenInterner
    private let cacheStorage: GreenNodeCacheStorage<Lang>
    private var parents: [OpenNode]
    private var children: [GreenElement<Lang>]
    private var nextParentID: UInt64
    private var finished: Bool

    /// Construct a builder driven by `context`. Consumes the context as a
    /// unit, preserving the namespace pairing between its interner and
    /// cache.
    public init(context: consuming GreenTreeContext<Lang>) {
        self.builderID = BuilderIDGenerator.make()
        self.interner = context.interner
        self.cacheStorage = context.cache.takeStorage()
        self.parents = []
        self.children = []
        self.nextParentID = 1
        self.finished = false
    }

    /// Convenience: construct a builder with a fresh ``LocalTokenInterner``
    /// and a fresh cache governed by `policy`. Default policy is
    /// ``CambiumBuilder/GreenCachePolicy/documentLocal``.
    public init(policy: GreenCachePolicy = .documentLocal) {
        self.init(context: GreenTreeContext(policy: policy))
    }

    /// Convenience: construct a builder bound to an existing `interner`
    /// (typically a ``CambiumBuilder/SharedTokenInterner`` shared across
    /// concurrent workers). The cache is fresh and subject to `policy`.
    public init(interner: any TokenInterner, policy: GreenCachePolicy = .documentLocal) {
        self.init(context: GreenTreeContext(interner: interner, policy: policy))
    }

    /// Open a node of `kind` and start collecting its children.
    public mutating func startNode(_ kind: Lang.Kind) {
        startNode(rawKind: Lang.rawKind(for: kind))
    }

    /// Open a node of `rawKind`. Equivalent to ``startNode(_:)`` but
    /// avoids the typed-kind round-trip, useful for language-agnostic
    /// builders.
    public mutating func startNode(rawKind: RawSyntaxKind) {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        parents.append(OpenNode(
            id: makeParentID(),
            kind: rawKind,
            firstChildIndex: children.count
        ))
    }

    /// Close the most recently opened node, gathering its accumulated
    /// children and inserting it as a child of the next-outer node (or as
    /// the root if it was the top-level frame).
    ///
    /// Throws ``CambiumBuilder/GreenTreeBuilderError/finishWithoutNode`` if no frame is
    /// currently open.
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

    /// Append a dynamic-text token of `kind` with the given source `text`.
    /// Throws ``CambiumBuilder/GreenTreeBuilderError/staticKindRequiresStaticToken(_:)``
    /// if the kind has static text.
    public mutating func token(_ kind: Lang.Kind, text: String) throws {
        var copy = text
        try copy.withUTF8 { bytes in
            try token(kind, bytes: bytes)
        }
    }

    /// Append a dynamic-text token from raw UTF-8 bytes. Validates the
    /// bytes as UTF-8 on first interning; throws
    /// `TokenTextError.invalidUTF8` for ill-formed input.
    public mutating func token(_ kind: Lang.Kind, bytes: UnsafeBufferPointer<UInt8>) throws {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        if Lang.staticText(for: kind) != nil {
            throw GreenTreeBuilderError.staticKindRequiresStaticToken(Lang.rawKind(for: kind))
        }
        let key = try interner.intern(bytes)
        let length = try TextSize(exactly: bytes.count)
        var cache = GreenNodeCache<Lang>(storage: cacheStorage)
        children.append(.token(cache.makeToken(
            kind: Lang.rawKind(for: kind),
            textLength: length,
            text: .interned(key)
        )))
    }

    /// Append a large-text token of `kind` with the given source `text`.
    /// Routes through the large-text storage path instead of the interned
    /// pool. Use for inherently unique payloads (long string literals,
    /// raw text blocks) where interning would not pay off. Throws
    /// ``CambiumBuilder/GreenTreeBuilderError/staticKindRequiresStaticToken(_:)`` if the
    /// kind has static text.
    public mutating func largeToken(_ kind: Lang.Kind, text: String) throws {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        if Lang.staticText(for: kind) != nil {
            throw GreenTreeBuilderError.staticKindRequiresStaticToken(Lang.rawKind(for: kind))
        }
        let id = interner.storeLargeText(text)
        let length = try TextSize(byteCountOf: text)
        var cache = GreenNodeCache<Lang>(storage: cacheStorage)
        children.append(.token(cache.makeToken(
            kind: Lang.rawKind(for: kind),
            textLength: length,
            text: .ownedLargeText(id)
        )))
    }

    /// Append a static-text token of `kind`. The text comes from
    /// `SyntaxLanguage.staticText(for:)`; throws
    /// ``CambiumBuilder/GreenTreeBuilderError/staticTextUnavailable(_:)`` for kinds with
    /// no static text.
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

    /// Append a "missing" token of `kind`. Renders as an empty span
    /// regardless of the kind's static or dynamic text. Use to record
    /// parser-recovered placeholders (an expected operator that was not
    /// in the source).
    public mutating func missingToken(_ kind: Lang.Kind) {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        var cache = GreenNodeCache<Lang>(storage: cacheStorage)
        children.append(.token(cache.makeToken(
            kind: Lang.rawKind(for: kind),
            textLength: .zero,
            text: .missing
        )))
    }

    /// Append an empty "missing" node of `kind`. The node has no children
    /// and zero text length. Use to record parser-recovered placeholders
    /// where a structural element was expected but not present.
    public mutating func missingNode(_ kind: Lang.Kind) throws {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        var cache = GreenNodeCache<Lang>(storage: cacheStorage)
        children.append(.node(try cache.makeNode(kind: Lang.rawKind(for: kind), children: [])))
    }

    /// Capture a snapshot of the builder's current state for later use
    /// with ``startNode(at:_:)`` or ``revert(to:)``. See
    /// ``CambiumBuilder/BuilderCheckpoint`` for the use case.
    public mutating func checkpoint() -> BuilderCheckpoint {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        return BuilderCheckpoint(
            builderID: builderID,
            parentID: parents.last?.id,
            parentCount: parents.count,
            childCount: children.count
        )
    }

    /// Retroactively wrap every child appended since `checkpoint` inside
    /// a new node of `kind`. After this call, the builder's open frame
    /// is the new node and any children appended between the checkpoint
    /// and now have become children of the new node.
    ///
    /// Throws ``CambiumBuilder/GreenTreeBuilderError/invalidCheckpoint`` if the
    /// checkpoint is from a different builder or is incoherent with the
    /// current state.
    public mutating func startNode(at checkpoint: BuilderCheckpoint, _ kind: Lang.Kind) throws {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        try validateStartNodeCheckpoint(checkpoint)
        let wrapped = Array(children[checkpoint.childCount...])
        children.removeSubrange(checkpoint.childCount...)
        parents.append(OpenNode(
            id: makeParentID(),
            kind: Lang.rawKind(for: kind),
            firstChildIndex: children.count
        ))
        children.append(contentsOf: wrapped)
    }

    /// Discard every change made since `checkpoint` was captured. Useful
    /// for backtracking after speculative parsing. Throws
    /// ``CambiumBuilder/GreenTreeBuilderError/invalidCheckpoint`` if the checkpoint is
    /// not from this builder or is incoherent.
    public mutating func revert(to checkpoint: BuilderCheckpoint) throws {
        precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
        try validateRevertCheckpoint(checkpoint)
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
           sourceNamespace === interner.namespace
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
                cache: &cache,
                interner: interner
            )
        }
        children.append(.node(remapped))
        return .remapped
    }

    /// Finish the tree and return a ``CambiumBuilder/GreenBuildResult`` carrying the
    /// green root, an immutable token-text snapshot, and the builder's
    /// reusable cache.
    ///
    /// The returned cache carries both green-node cache contents and the
    /// token-key namespace needed for identity-preserving
    /// ``reuseSubtree(_:)`` in a later builder. Throws if the open-frame
    /// stack is not empty
    /// (``CambiumBuilder/GreenTreeBuilderError/unbalancedStartNodes(_:)``), no children
    /// were appended (``CambiumBuilder/GreenTreeBuilderError/noRoot``), or multiple
    /// top-level children were appended
    /// (``CambiumBuilder/GreenTreeBuilderError/multipleRoots(_:)``).
    public consuming func finish() throws -> GreenBuildResult<Lang> {
        let root = try finishRoot()
        // Seal the resolver once. For LocalTokenInterner this is the one
        // O(n) snapshot copy of the interned-strings array; for shared
        // backends it's just `self`. Stored on the result so that
        // `result.resolver` and `result.snapshot.resolver` reuse it.
        let resolver = interner.makeResolver()
        return GreenBuildResult(
            root: root,
            resolver: resolver,
            interner: interner,
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

    private mutating func makeParentID() -> UInt64 {
        precondition(nextParentID < UInt64.max, "Builder parent id space exhausted")
        let id = nextParentID
        nextParentID += 1
        return id
    }

    private func validateStartNodeCheckpoint(_ checkpoint: BuilderCheckpoint) throws {
        guard checkpoint.builderID == builderID,
              checkpoint.parentCount == parents.count,
              checkpoint.parentID == parents.last?.id,
              checkpoint.childCount <= children.count
        else {
            throw GreenTreeBuilderError.invalidCheckpoint
        }

        if let currentParent = parents.last, checkpoint.childCount < currentParent.firstChildIndex {
            throw GreenTreeBuilderError.invalidCheckpoint
        }
    }

    private func validateRevertCheckpoint(_ checkpoint: BuilderCheckpoint) throws {
        guard checkpoint.builderID == builderID,
              checkpoint.parentCount <= parents.count,
              checkpoint.childCount <= children.count,
              checkpointParentExists(checkpoint)
        else {
            throw GreenTreeBuilderError.invalidCheckpoint
        }
    }

    private func checkpointParentExists(_ checkpoint: BuilderCheckpoint) -> Bool {
        guard checkpoint.parentCount > 0 else {
            return checkpoint.parentID == nil
        }
        let parentIndex = checkpoint.parentCount - 1
        guard parents.indices.contains(parentIndex) else {
            return false
        }
        return parents[parentIndex].id == checkpoint.parentID
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
    /// For full correctness when sharing storage across builders or when
    /// the replacement was built independently of this tree, pass a
    /// `context` whose interner is the one used to build this tree
    /// (typically obtained via `result.intoContext()`). When the
    /// context's interner shares this tree's namespace, the result tree's
    /// resolver is the fresh resolver returned by
    /// ``CambiumCore/TokenInterner/makeResolver()`` covering every key
    /// referenced by the new tree.
    ///
    /// If the target tree shares the context's interner but the
    /// replacement does not, the replacement's dynamic token keys are
    /// remapped into the context's interner and the result tree carries
    /// a fresh resolver from that interner.
    ///
    /// In every other case — including the subtle one where the
    /// replacement and target share a namespace but the context does
    /// not — replacement falls back to an overlay resolver. The overlay
    /// preserves structural sharing and correctness (every key in the
    /// new tree resolves correctly), but intentionally exposes no
    /// `tokenKeyNamespace`; future `reuseSubtree` calls with a context
    /// must remap dynamic token keys instead of direct-reusing the
    /// overlay-backed green storage.
    func replacing(
        _ handle: SyntaxNodeHandle<Lang>,
        with replacement: ResolvedGreenNode<Lang>,
        context: inout GreenTreeContext<Lang>
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
           sourceNamespace === targetNamespace,
           targetNamespace === context.interner.namespace
        {
            // All three (source, target, context-interner) share one
            // namespace: the replacement's keys are valid in the cache
            // and the result tree can carry a fresh resolver from the
            // context's interner. This is the happy path.
            let newRoot = try rebuildReplacingCached(
                root: oldRoot,
                path: ArraySlice(replacedPath),
                replacement: replacement.root,
                cache: &context.cache
            )
            // Fresh resolver from the context's interner. Required for
            // correctness when the interner has grown beyond this tree's
            // resolver snapshot (e.g., another builder using the same
            // interner minted keys after this tree finished). The new
            // resolver shares the context interner's namespace, so
            // namespace-identity continuity is preserved.
            let resultResolver = context.interner.makeResolver()
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
        // Note: when sourceNamespace === targetNamespace but the
        // context's interner is in a different namespace, we deliberately
        // fall through. The previous version of this branch reused the
        // target tree's old `resolver` after a direct rebuild, which
        // could leave the new tree referencing keys minted in the
        // shared namespace after the target's resolver was sealed —
        // rendering would precondition-fail. The fall-through routes
        // such cases to tier 3 (cache-remap into the context interner)
        // or tier 5 (overlay fallback), both of which produce a tree
        // with a resolver guaranteed to cover every key it references.

        if let targetNamespace = resolver.tokenKeyNamespace,
           targetNamespace === context.interner.namespace
        {
            var remapper = CacheReplacementTokenRemapper<Lang>()
            let remappedReplacement = try remapper.remap(
                node: replacement.root,
                replacementResolver: replacement.resolver,
                cache: &context.cache,
                interner: context.interner
            )
            let newRoot: GreenNode<Lang>
            if oldSubtree.identity == remappedReplacement.identity {
                newRoot = oldRoot
            } else {
                newRoot = try rebuildReplacingCached(
                    root: oldRoot,
                    path: ArraySlice(replacedPath),
                    replacement: remappedReplacement,
                    cache: &context.cache
                )
            }
            // Fresh resolver from the context's interner. Re-interning may
            // have returned existing keys minted before this tree's
            // resolver snapshot was taken (e.g., from another builder
            // sharing the interner), so reusing `resolver` could leave
            // the new tree referencing keys outside its snapshot. Captured
            // *after* the rebuild so any keys minted during remapping are
            // present in the resolver.
            let resultResolver = context.interner.makeResolver()
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
        // The resulting resolver exposes no namespace because no matching
        // cache/interner can resolve those synthetic overlay keys.
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

    /// Same as `replacing(_:with:context:)` for `ResolvedGreenNode`, but
    /// accepts a cacheless snapshot produced by an independent
    /// `GreenTreeBuilder`.
    func replacing(
        _ handle: SyntaxNodeHandle<Lang>,
        with replacement: GreenTreeSnapshot<Lang>,
        context: inout GreenTreeContext<Lang>
    ) throws -> ReplacementResult<Lang> {
        try replacing(
            handle,
            with: ResolvedGreenNode(root: replacement.root, resolver: replacement.resolver),
            context: &context
        )
    }

    /// Same as `replacing(_:with:context:)` for `GreenTreeSnapshot`, but
    /// borrows the snapshot view from a context-preserving build result.
    func replacing(
        _ handle: SyntaxNodeHandle<Lang>,
        with replacement: borrowing GreenBuildResult<Lang>,
        context: inout GreenTreeContext<Lang>
    ) throws -> ReplacementResult<Lang> {
        try replacing(
            handle,
            with: ResolvedGreenNode(root: replacement.root, resolver: replacement.resolver),
            context: &context
        )
    }
}
