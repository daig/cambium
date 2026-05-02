import CambiumCore
import Synchronization

/// Severity classes for ``Diagnostic``. Ordered from least to most
/// severe.
public enum DiagnosticSeverity: Sendable, Hashable {
    /// Informational. Carries no badness implication.
    case note

    /// Possibly-incorrect code that is not invalid.
    case warning

    /// Outright invalid code.
    case error
}

/// A range-anchored diagnostic message.
///
/// `Diagnostic` is a minimal carrier — Cambium does not impose a
/// diagnostic format. Wrap it in your own type if you need richer fields
/// (fix-its, related locations, codes), or use it directly when a
/// `(range, message, severity)` triple is enough.
public struct Diagnostic<Lang: SyntaxLanguage>: Sendable, Hashable {
    /// The byte range in the source document the diagnostic refers to.
    public var range: TextRange

    /// The human-readable message.
    public var message: String

    /// The severity class.
    public var severity: DiagnosticSeverity

    /// Construct a diagnostic. Severity defaults to ``DiagnosticSeverity/error``.
    public init(
        range: TextRange,
        message: String,
        severity: DiagnosticSeverity = .error
    ) {
        self.range = range
        self.message = message
        self.severity = severity
    }
}

/// A typed key for storing per-node sidecar data in a
/// ``CambiumAnalysis/SyntaxMetadataStore``.
///
/// The phantom `Value` type binds every read and write to a specific
/// payload type, so a single store can carry many distinct kinds of
/// per-node metadata without runtime type confusion.
///
/// ```swift
/// let inferredType = SyntaxDataKey<Type>("type-inference.inferred-type")
/// store.set(intType, for: inferredType, on: handle)
/// let kind: Type? = store.value(for: inferredType, on: handle)
/// ```
public struct SyntaxDataKey<Value: Sendable>: Sendable, Hashable {
    /// The string name of the key. Choose a globally unique string
    /// (typically dot-separated, namespaced) — Cambium uses string
    /// equality on this name as the key identity, so two `SyntaxDataKey`
    /// values with the same name address the same slot regardless of
    /// `Value`. Mismatched `Value` types at read time return `nil`.
    public let name: StaticString

    /// Construct a key from a string name.
    public init(_ name: StaticString) {
        self.name = name
    }

    fileprivate var id: String {
        String(describing: name)
    }

    public static func == (lhs: SyntaxDataKey<Value>, rhs: SyntaxDataKey<Value>) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private final class AnySendableBox: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }
}

/// A thread-safe store mapping `(node, typed key)` pairs to arbitrary
/// `Sendable` values.
///
/// `SyntaxMetadataStore` is the building block for tools that want to
/// attach per-node sidecar data: type inference results, name resolution
/// outcomes, fold state, custom diagnostics. Use ``CambiumAnalysis/SyntaxDataKey`` to
/// keep value types straight.
///
/// Entries are keyed on `SyntaxNodeIdentity`; if the underlying tree is
/// edited and a node disappears, its entries become unreachable but
/// remain in storage. For automatic invalidation on tree-version
/// changes, prefer ``CambiumAnalysis/ExternalAnalysisCache`` together with
/// ``ExternalAnalysisCache/removeValues(notMatching:)``.
public final class SyntaxMetadataStore<Lang: SyntaxLanguage>: @unchecked Sendable {
    private let storage = Mutex<[SyntaxNodeIdentity: [String: AnySendableBox]]>([:])

    /// Construct an empty store.
    public init() {}

    /// Read the value bound to `key` on `handle`'s node, or `nil` when no
    /// value has been set or the stored type doesn't match `Value`.
    public func value<Value: Sendable>(
        for key: SyntaxDataKey<Value>,
        on handle: SyntaxNodeHandle<Lang>
    ) -> Value? {
        storage.withLock { values in
            values[handle.identity]?[key.id]?.value as? Value
        }
    }

    /// Bind `value` to `key` on `handle`'s node, replacing any existing
    /// entry.
    public func set<Value: Sendable>(
        _ value: Value,
        for key: SyntaxDataKey<Value>,
        on handle: SyntaxNodeHandle<Lang>
    ) {
        storage.withLock { values in
            values[handle.identity, default: [:]][key.id] = AnySendableBox(value)
        }
    }

    /// Read the value bound to `key` on `handle`'s node; if absent,
    /// invoke `compute()` to produce a value, store it, and return it.
    /// Useful for memoizing per-node analyses.
    public func getOrCompute<Value: Sendable>(
        for key: SyntaxDataKey<Value>,
        on handle: SyntaxNodeHandle<Lang>,
        _ compute: () -> Value
    ) -> Value {
        if let cached: Value = value(for: key, on: handle) {
            return cached
        }
        let computed = compute()
        set(computed, for: key, on: handle)
        return computed
    }
}

/// A composite key for an analysis cache entry: a node identity plus a
/// string namespace.
///
/// The namespace lets one cache hold the results of multiple unrelated
/// analyses without collision. Pair with ``CambiumAnalysis/ExternalAnalysisCache``.
public struct AnalysisCacheKey<Lang: SyntaxLanguage>: Sendable, Hashable {
    /// The node identity.
    public let identity: SyntaxNodeIdentity

    /// The analysis namespace. Conventionally a reverse-DNS-style
    /// identifier ("com.example.type-inference").
    public let namespace: String

    /// Construct a key from its parts.
    public init(identity: SyntaxNodeIdentity, namespace: String) {
        self.identity = identity
        self.namespace = namespace
    }
}

/// A thread-safe cache of analysis results, keyed by
/// ``CambiumAnalysis/AnalysisCacheKey`` and holding `Value`-typed payloads.
///
/// Unlike ``CambiumAnalysis/SyntaxMetadataStore``, `ExternalAnalysisCache` is single-typed
/// (every entry is the same `Value`) and supports tree-aware bulk
/// eviction via ``removeValues(notMatching:)``. Use one cache per
/// analysis kind, and call `removeValues(notMatching:)` on the post-edit
/// `TreeID` to drop entries from older tree versions.
public final class ExternalAnalysisCache<Lang: SyntaxLanguage, Value: Sendable>: @unchecked Sendable {
    private let storage = Mutex<[AnalysisCacheKey<Lang>: Value]>([:])

    /// Construct an empty cache.
    public init() {}

    /// The number of cached entries currently stored.
    public var count: Int {
        storage.withLock { $0.count }
    }

    /// Whether the cache currently stores no entries.
    public var isEmpty: Bool {
        storage.withLock { $0.isEmpty }
    }

    /// Read the value for `key`, or `nil` when no entry exists.
    public func value(for key: AnalysisCacheKey<Lang>) -> Value? {
        storage.withLock { $0[key] }
    }

    /// Bind `value` to `key`, replacing any existing entry.
    public func set(_ value: Value, for key: AnalysisCacheKey<Lang>) {
        storage.withLock { $0[key] = value }
    }

    /// Return a point-in-time copy of the cache contents.
    ///
    /// This is primarily useful for diagnostics, debugging views, and
    /// higher-level identity translation driven by edit or parse witnesses.
    public func snapshot() -> [AnalysisCacheKey<Lang>: Value] {
        storage.withLock { $0 }
    }

    /// Drop every cached entry.
    public func removeAll(keepingCapacity keepCapacity: Bool = false) {
        storage.withLock { $0.removeAll(keepingCapacity: keepCapacity) }
    }

    /// Drop every entry whose identity does **not** belong to `treeID`.
    /// Use after publishing a new tree version to evict stale entries.
    public func removeValues(notMatching treeID: TreeID) {
        storage.withLock { values in
            values = values.filter { $0.key.identity.treeID == treeID }
        }
    }
}
