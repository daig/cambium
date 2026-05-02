/// Runtime-local key for dynamically interned token text.
///
/// A token key is a compact handle (one `UInt32`) into a ``CambiumCore/TokenResolver``'s
/// interned-text table. Green tokens whose text varies between source
/// occurrences (identifiers, number literals) hold a `TokenKey` instead of
/// the text itself, so identical tokens like the two `count` identifiers in
/// `count + count` deduplicate to one allocation.
///
/// **Lifetime and durability.** A `TokenKey` is meaningful only with the
/// resolver — interner, snapshot, or overlay — that produced the tree
/// containing it. The raw value is not a durable, cross-process, or
/// serialized identity. Snapshot serialization
/// (`GreenSnapshotDecoder`/`SharedSyntaxTree.serializeGreenSnapshot()`)
/// canonicalizes token text into snapshot-local tables, which means a
/// decoded tree's keys are unrelated to the producer tree's keys even when
/// the underlying text is identical.
///
/// **Cross-tree reuse.** ``CambiumCore/TokenKeyNamespace`` is the runtime identity that
/// two trees must share before their token keys can be mixed. Builders
/// inspect the namespace via ``CambiumCore/TokenResolver/tokenKeyNamespace`` to
/// decide whether `GreenTreeBuilder.reuseSubtree(_:)` can splice a green
/// subtree directly or has to remap its dynamic keys into a fresh interner
/// (the slow `SubtreeReuseOutcome.remapped` path).
public struct TokenKey: RawRepresentable, Sendable, Hashable, Comparable {
    /// The raw `UInt32` index into the producing resolver's interned-text
    /// table. Treat this value as opaque outside the resolver that minted it.
    public let rawValue: UInt32

    /// Wrap an existing `UInt32` as a `TokenKey`. Only meaningful when paired
    /// with the resolver that produced the value.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Wrap an existing `UInt32` as a `TokenKey`. Equivalent to
    /// ``init(rawValue:)``.
    public init(_ rawValue: UInt32) {
        self.init(rawValue: rawValue)
    }

    public static func < (lhs: TokenKey, rhs: TokenKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Compact handle for a "large" dynamic token text stored out-of-line by a
/// resolver.
///
/// Cambium distinguishes two dynamic-text storage classes — the small
/// hash-interned pool indexed by ``CambiumCore/TokenKey`` and an explicit large-text
/// pool indexed by `LargeTokenTextID`. The split lets parsers steer
/// inherently-unique payloads (long string literals, raw text blocks) away
/// from the dedup pool when interning would only waste hash work. Builders
/// expose the choice via
/// `GreenTreeBuilder.largeToken(_:text:)` and
/// `GreenNodeCache.storeLargeText(_:)`.
///
/// Lifetime and durability rules match ``CambiumCore/TokenKey``: the value is opaque
/// outside the resolver that minted it.
public struct LargeTokenTextID: RawRepresentable, Sendable, Hashable, Comparable {
    /// The raw `UInt32` index into the producing resolver's large-text
    /// table. Treat this value as opaque outside the resolver that minted it.
    public let rawValue: UInt32

    /// Wrap an existing `UInt32` as a `LargeTokenTextID`.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Wrap an existing `UInt32` as a `LargeTokenTextID`. Equivalent to
    /// ``init(rawValue:)``.
    public init(_ rawValue: UInt32) {
        self.init(rawValue: rawValue)
    }

    public static func < (lhs: LargeTokenTextID, rhs: LargeTokenTextID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Errors thrown when token text fails validation at an API boundary.
public enum TokenTextError: Error, Sendable, Equatable {
    /// The byte sequence presented to an interning entry point did not
    /// decode as UTF-8. Cambium's text storage is UTF-8; ill-formed input
    /// is rejected at the boundary rather than allowed to propagate into
    /// trees.
    case invalidUTF8
}

/// Identity of a token-key namespace.
///
/// A `TokenKeyNamespace` is a reference type whose **identity** (object
/// pointer) — not its contents — defines the namespace. Two ``CambiumCore/TokenKey``
/// values are comparable only inside the same namespace; mixing keys
/// minted by different namespaces silently produces wrong text.
///
/// You normally do not construct namespaces directly. They are created by
/// interners (`LocalTokenInterner`, `SharedTokenInterner`,
/// `GreenNodeCache`), and exposed by resolvers through
/// ``CambiumCore/TokenResolver/tokenKeyNamespace`` so builders can decide whether
/// to fast-path subtree reuse (`SubtreeReuseOutcome.direct`) or rebuild
/// with remapped keys (`SubtreeReuseOutcome.remapped`).
///
/// The `@unchecked Sendable` conformance is safe: instances carry no state,
/// and identity comparisons are inherently thread-safe.
public final class TokenKeyNamespace: @unchecked Sendable {
    /// Mint a new namespace. Distinct calls produce distinct namespaces by
    /// reference identity.
    public init() {}
}

/// How a ``CambiumCore/GreenToken`` knows what text to render.
///
/// Cambium has four token text-storage classes. The split keeps small,
/// recurring tokens cheap (no per-token text payload for static-text kinds)
/// while still supporting unbounded literals and error-recovery placeholders.
///
/// - `staticText`: render whatever ``CambiumCore/SyntaxLanguage/staticText(for:)``
///   returns for the token's kind (operators, keywords, punctuation).
/// - `missing`: render nothing. A "missing" token represents a
///   parser-recovered placeholder — for example, an expected operator that
///   wasn't actually in the source. Token length is always zero.
/// - `interned`: render the text indexed by the wrapped ``CambiumCore/TokenKey`` in the
///   token's resolver. Used for short, often-recurring dynamic text such
///   as identifiers.
/// - `ownedLargeText`: render the text indexed by the wrapped
///   ``CambiumCore/LargeTokenTextID``. Used for inherently unique payloads (long
///   string literals, raw text blocks) where interning would not pay off.
public enum TokenTextStorage: Sendable, Hashable {
    /// Renders the kind's static text from ``CambiumCore/SyntaxLanguage/staticText(for:)``.
    /// Token length must equal the static text's UTF-8 byte length.
    case staticText

    /// A token of a kind that *would* have static text but is absent in the
    /// source (an error-recovery placeholder). Renders as empty regardless
    /// of the kind's static text. Token length must be zero.
    case missing

    /// Render the text bound to `key` in the token's resolver. The text
    /// length must equal the resolver's bytes for `key`; mismatch is caught
    /// at serialization time.
    case interned(TokenKey)

    /// Render the text bound to `id` in the token's resolver's large-text
    /// table. Same length contract as ``interned(_:)``.
    case ownedLargeText(LargeTokenTextID)
}

/// A read-only view into the token text bound to a green tree.
///
/// `TokenResolver` is the bridge between green tokens (which carry only
/// keys/IDs) and the bytes they render to. Every green tree carries a
/// resolver that resolves every dynamic token key referenced by the tree:
/// builders bundle one in `GreenBuildResult.tokenText`, snapshot
/// decoders construct one inside `GreenTreeSnapshot.tokenText`, and
/// editing operations may produce overlay resolvers that combine a base
/// resolver with replacement-only entries.
///
/// You normally do not implement this protocol. The two implementations
/// you'll touch are:
///
/// - ``CambiumCore/TokenTextSnapshot`` — the immutable, post-build snapshot stored on a
///   ``CambiumCore/SyntaxTree`` or ``CambiumCore/SharedSyntaxTree``.
/// - `SharedTokenInterner` — a thread-safe resolver/interner for custom
///   pipelines that want runtime-shared token text outside
///   `GreenTreeBuilder`'s owned local interner.
///
/// **Namespace identity.** ``CambiumCore/TokenResolver/tokenKeyNamespace`` exposes the runtime
/// identity that builders use to decide whether two trees can share token
/// keys. Resolvers that compose multiple namespaces (overlay resolvers
/// produced by `replacing(_:with:cache:)` for incompatible cache lineages)
/// return `nil` so the builder fall-back path remaps keys conservatively.
public protocol TokenResolver: Sendable {
    /// Namespace for token keys this resolver can resolve, if it has a
    /// single coherent namespace.
    ///
    /// Resolvers that compose multiple namespaces, such as overlays,
    /// should return `nil` so builders remap reused subtrees
    /// conservatively. The default implementation returns `nil`.
    var tokenKeyNamespace: TokenKeyNamespace? { get }

    /// Return the text bound to `key`. Traps when `key` is not present in
    /// this resolver's table.
    func resolve(_ key: TokenKey) -> String

    /// Return the text bound to large-text `id`. The default implementation
    /// traps; override in resolvers that hold large-text entries.
    func resolveLargeText(_ id: LargeTokenTextID) -> String

    /// Call `body` with a UTF-8 byte buffer for the text bound to `key`.
    /// Implementations must arrange for the buffer to remain valid for the
    /// duration of the closure.
    func withUTF8<R>(
        _ key: TokenKey,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R

    /// Call `body` with a UTF-8 byte buffer for the text bound to large-text
    /// `id`. The default implementation calls ``resolveLargeText(_:)`` and
    /// passes its UTF-8 bytes; override for direct buffer access.
    func withLargeTextUTF8<R>(
        _ id: LargeTokenTextID,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R
}

public extension TokenResolver {
    var tokenKeyNamespace: TokenKeyNamespace? {
        nil
    }

    func resolveLargeText(_ id: LargeTokenTextID) -> String {
        preconditionFailure("Resolver does not contain large token text \(id.rawValue)")
    }

    func withLargeTextUTF8<R>(
        _ id: LargeTokenTextID,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        let text = resolveLargeText(id)
        return try text.utf8.withContiguousStorageIfAvailable(body)
            ?? Array(text.utf8).withUnsafeBufferPointer(body)
    }
}

/// A write-capable token-text store: mints `TokenKey`s for new text and
/// stores large-text payloads, paired with a method that yields the
/// `TokenResolver` to associate with finished trees.
///
/// `TokenInterner` is deliberately a sibling of ``TokenResolver`` (not a
/// refinement). `TokenResolver` is `Sendable`; if interning inherited that
/// requirement, single-threaded interner backends would have to adopt
/// `@unchecked Sendable` and silently expose mutable state where a
/// thread-safe resolver is expected. Keeping the protocols disjoint means
/// a single-owner interner like `LocalTokenInterner` need not conform to
/// `TokenResolver` at all — its ``makeResolver()`` returns a frozen
/// snapshot, and that snapshot is the resolver. Backends that genuinely
/// are thread-safe (such as `SharedTokenInterner`) conform to both
/// protocols separately.
///
/// **Lifetime.** `AnyObject`-constrained: interners are reference types.
/// Their namespace identity is the instance identity. Holding the same
/// `TokenInterner` instance from multiple builders means those builders
/// share a token namespace and can fast-path subtree reuse via
/// `SubtreeReuseOutcome.direct`.
public protocol TokenInterner: AnyObject {
    /// The interner's namespace identity. Stable for the lifetime of the
    /// interner instance. Two `TokenKey`s minted by the same interner
    /// share this namespace; keys minted by different interners do not.
    var namespace: TokenKeyNamespace { get }

    /// Intern a UTF-8 byte sequence and return its `TokenKey`. Validates
    /// `bytes` as UTF-8 on first insertion; throws ``TokenTextError/invalidUTF8``
    /// for ill-formed input. Repeated calls with the same bytes return
    /// the same key.
    func intern(_ bytes: UnsafeBufferPointer<UInt8>) throws -> TokenKey

    /// Store `text` in the large-text table without interning, returning
    /// its `LargeTokenTextID`. Use for inherently-unique payloads (long
    /// string literals, raw text blocks) where interning would only waste
    /// hash work.
    func storeLargeText(_ text: String) -> LargeTokenTextID

    /// The resolver to associate with a tree built using this interner.
    /// `LocalTokenInterner` returns a frozen `TokenTextSnapshot`.
    /// `SharedTokenInterner` returns `self` (live; `SharedTokenInterner`
    /// also conforms to ``TokenResolver`` separately). Database-backed
    /// adapters choose deliberately. Called by the builder's `finish()`
    /// at the moment a tree is sealed; the result is stored on the
    /// `GreenBuildResult` and reused, never recomputed.
    func makeResolver() -> any TokenResolver
}

public extension TokenInterner {
    /// Intern `text` and return its `TokenKey`. Default implementation
    /// over the bytes form; conformers may override for a faster
    /// String-typed fast path.
    func intern(_ text: String) -> TokenKey {
        var copy = text
        return copy.withUTF8 { bytes in
            // String guarantees valid UTF-8, so this never throws.
            try! intern(bytes)
        }
    }
}

/// Immutable token-text table for a finished green tree.
///
/// A snapshot resolves token keys that already exist in the tree it was
/// created with. It does not intern new text and does not observe future
/// mutations to a builder cache that shares the same namespace.
///
/// Snapshots are produced by `GreenBuildResult.tokenText` and
/// `GreenTreeSnapshot.tokenText` after a build finishes, and by
/// `GreenSnapshotDecoder` when a serialized green snapshot is loaded.
/// They are the resolver of choice for read-only consumption: analysis,
/// tree printing, wire-format transport.
///
/// For long-lived editor sessions where multiple builders share the same
/// interner, prefer `SharedTokenInterner`.
public struct TokenTextSnapshot: TokenResolver, Sendable {
    private let interned: [String]
    private let large: [String]

    /// The namespace identity of this snapshot. Two snapshots with the
    /// same namespace come from the same token-key lineage, but this
    /// snapshot only resolves keys that existed when it was captured. Use
    /// a fresh snapshot from the cache/interner before rendering trees
    /// that may reference newer keys.
    public let namespace: TokenKeyNamespace

    /// The namespace identity, for ``CambiumCore/TokenResolver`` conformance.
    public var tokenKeyNamespace: TokenKeyNamespace? {
        namespace
    }

    /// Construct an immutable snapshot.
    ///
    /// - Parameters:
    ///   - interned: Texts indexed by ``CambiumCore/TokenKey``. Each ``CambiumCore/TokenKey`` value
    ///     used by tokens in the tree must be a valid index into this array.
    ///   - large: Texts indexed by ``CambiumCore/LargeTokenTextID``. Same indexing
    ///     contract as `interned`.
    ///   - namespace: The namespace identity. Construct a fresh one for
    ///     standalone snapshots; pass the source interner's namespace when
    ///     the snapshot continues an existing key family.
    public init(
        interned: [String] = [],
        large: [String] = [],
        namespace: TokenKeyNamespace = TokenKeyNamespace()
    ) {
        self.interned = interned
        self.large = large
        self.namespace = namespace
    }

    public func resolve(_ key: TokenKey) -> String {
        let index = Int(key.rawValue)
        precondition(interned.indices.contains(index), "Unknown token key \(key.rawValue)")
        return interned[index]
    }

    public func resolveLargeText(_ id: LargeTokenTextID) -> String {
        let index = Int(id.rawValue)
        precondition(large.indices.contains(index), "Unknown large token text id \(id.rawValue)")
        return large[index]
    }

    public func withUTF8<R>(
        _ key: TokenKey,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        let text = resolve(key)
        return try text.utf8.withContiguousStorageIfAvailable(body)
            ?? Array(text.utf8).withUnsafeBufferPointer(body)
    }

    public func withLargeTextUTF8<R>(
        _ id: LargeTokenTextID,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        let text = resolveLargeText(id)
        return try text.utf8.withContiguousStorageIfAvailable(body)
            ?? Array(text.utf8).withUnsafeBufferPointer(body)
    }
}

/// Errors thrown when constructing green storage from invalid inputs.
public enum GreenStorageError: Error, Sendable, Equatable {
    /// A ``CambiumCore/GreenNode`` would have summed its children's text lengths past
    /// `UInt32.max`. The total source size for any subtree must fit in
    /// 4 bytes; see ``CambiumCore/TextSize``.
    case textLengthOverflow

    /// A static-text token's declared length disagreed with its kind's
    /// static text. Reported by serialization validation.
    case staticTextLengthMismatch(expected: TextSize, actual: TextSize)
}

/// Errors thrown by ``CambiumCore/GreenToken``'s static factory methods when the kind
/// and text-storage class don't agree.
public enum GreenTokenError: Error, Sendable, Equatable {
    /// ``GreenToken/staticToken(kind:)`` was called with a kind whose
    /// ``CambiumCore/SyntaxLanguage/staticText(for:)`` is `nil`. Use
    /// ``GreenToken/missingToken(kind:)`` for an empty placeholder, or
    /// ``GreenToken/internedToken(kind:textLength:key:)`` /
    /// ``GreenToken/largeToken(kind:textLength:id:)`` for dynamic text.
    case staticTextUnavailable(RawSyntaxKind)

    /// ``GreenToken/internedToken(kind:textLength:key:)`` or
    /// ``GreenToken/largeToken(kind:textLength:id:)`` was called with a
    /// kind that has non-`nil` ``CambiumCore/SyntaxLanguage/staticText(for:)``. Use
    /// ``GreenToken/staticToken(kind:)`` for static kinds.
    case staticKindRequiresDynamicToken(RawSyntaxKind)
}

internal enum GreenHash {
    static let offset: UInt64 = 0xcbf29ce484222325
    static let prime: UInt64 = 0x100000001b3

    static func mix(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        (hash ^ value).multipliedReportingOverflow(by: prime).partialValue
    }

    static func token(rawKind: RawSyntaxKind, textLength: TextSize, text: TokenTextStorage) -> UInt64 {
        var hash = offset
        hash = mix(hash, 0x746f6b656e)
        hash = mix(hash, UInt64(rawKind.rawValue))
        hash = mix(hash, UInt64(textLength.rawValue))
        switch text {
        case .staticText:
            hash = mix(hash, 0)
        case .interned(let key):
            hash = mix(hash, 1)
            hash = mix(hash, UInt64(key.rawValue))
        case .ownedLargeText(let id):
            hash = mix(hash, 2)
            hash = mix(hash, UInt64(id.rawValue))
        case .missing:
            hash = mix(hash, 3)
        }
        return hash
    }

    static func node(rawKind: RawSyntaxKind, textLength: TextSize, children: [UInt64]) -> UInt64 {
        var hash = offset
        hash = mix(hash, 0x6e6f6465)
        hash = mix(hash, UInt64(rawKind.rawValue))
        hash = mix(hash, UInt64(textLength.rawValue))
        hash = mix(hash, UInt64(children.count))
        for child in children {
            hash = mix(hash, child)
        }
        return hash
    }
}

final class GreenTokenStorage<Lang: SyntaxLanguage> {
    let rawKind: RawSyntaxKind
    let textLength: TextSize
    let text: TokenTextStorage
    let structuralHash: UInt64

    init(rawKind: RawSyntaxKind, textLength: TextSize, text: TokenTextStorage) {
        precondition(text != .missing || textLength == .zero, "Missing tokens must have zero text length")
        self.rawKind = rawKind
        self.textLength = textLength
        self.text = text
        self.structuralHash = GreenHash.token(rawKind: rawKind, textLength: textLength, text: text)
    }
}

/// A leaf in the immutable green layer: a single token of source text.
///
/// `GreenToken` stores a token's kind, its UTF-8 byte length, a
/// ``CambiumCore/TokenTextStorage`` discriminator pointing to its text, and a
/// pre-computed structural hash used for cache-equality checks. It is
/// position-independent — the same green token may appear at multiple
/// source positions in the same tree (deduplicated via `GreenNodeCache`).
///
/// **Construction.** Public callers use the four kind-aware factory methods,
/// which validate that the requested text-storage class is legal for the
/// kind:
///
/// - ``staticToken(kind:)`` — for kinds with grammar-determined text
///   (operators, keywords, punctuation).
/// - ``missingToken(kind:)`` — for parser-recovered placeholders that
///   render to nothing.
/// - ``internedToken(kind:textLength:key:)`` — for short, recurring dynamic
///   text (identifiers, number literals).
/// - ``largeToken(kind:textLength:id:)`` — for unique large payloads (long
///   string literals, raw text blocks).
///
/// Most code goes through `GreenTreeBuilder` (`token(_:text:)`,
/// `staticToken(_:)`, `missingToken(_:)`, `largeToken(_:text:)`) instead of
/// constructing tokens directly. The builder routes through
/// `GreenNodeCache` for deduplication.
///
/// **Equality and hashing.** Tokens compare by green storage shape: kind,
/// text length, text-storage discriminator, and structural hash. Dynamic
/// token equality compares token keys/large-text IDs, not resolver text.
/// This is why cross-namespace reuse remaps dynamic keys before placing a
/// subtree into a new cache lineage.
///
/// `GreenToken` is `@unchecked Sendable` because its storage is a final
/// reference type with immutable contents.
public struct GreenToken<Lang: SyntaxLanguage>: @unchecked Sendable, Hashable {
    internal let storage: GreenTokenStorage<Lang>

    /// Unchecked construction. `package`-visible so trusted call sites in
    /// other modules of this package (cache `makeToken`, replacement
    /// remappers, encoder canonicalization, snapshot decoder) can build
    /// tokens from already-validated inputs without paying re-validation
    /// overhead. Public callers go through the per-variant factories
    /// (`staticToken`, `missingToken`, `internedToken`, `largeToken`).
    package init(kind: RawSyntaxKind, textLength: TextSize, text: TokenTextStorage = .staticText) {
        self.storage = GreenTokenStorage(rawKind: kind, textLength: textLength, text: text)
    }

    package init(kind: Lang.Kind, textLength: TextSize, text: TokenTextStorage = .staticText) {
        self.init(kind: Lang.rawKind(for: kind), textLength: textLength, text: text)
    }

    /// The language-agnostic kind of this token.
    public var rawKind: RawSyntaxKind {
        storage.rawKind
    }

    /// The typed kind of this token, projected through the language.
    public var kind: Lang.Kind {
        Lang.kind(for: rawKind)
    }

    /// The UTF-8 byte length of this token's text. Always zero for
    /// ``TokenTextStorage/missing``.
    public var textLength: TextSize {
        storage.textLength
    }

    /// How the token's text is stored. See ``CambiumCore/TokenTextStorage``.
    public var textStorage: TokenTextStorage {
        storage.text
    }

    /// A pre-computed FNV-1a-style hash that mixes kind, length, and text
    /// storage. Used as the cache key by `GreenNodeCache`.
    public var structuralHash: UInt64 {
        storage.structuralHash
    }

    /// Call `body` with this token's UTF-8 bytes, fetched through
    /// `resolver`. The buffer is valid only for the duration of the
    /// closure.
    ///
    /// `body` receives an empty buffer for ``TokenTextStorage/missing``
    /// tokens. For dynamic-text tokens, the buffer comes from
    /// ``CambiumCore/TokenResolver/withUTF8(_:_:)`` or
    /// ``CambiumCore/TokenResolver/withLargeTextUTF8(_:_:)``; the call traps if
    /// `resolver` does not contain the token's key.
    public func withTextUTF8<R>(
        using resolver: any TokenResolver,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) throws -> R {
        switch textStorage {
        case .staticText:
            guard let text = Lang.staticText(for: kind) else {
                precondition(textLength == .zero, "Kind \(rawKind.rawValue) has no static text")
                let bytes = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
                return try body(bytes)
            }
            var result: Result<R, any Error>!
            text.withUTF8Buffer { bytes in
                result = Result {
                    try body(bytes)
                }
            }
            return try result.get()
        case .missing:
            let bytes = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
            return try body(bytes)
        case .interned(let key):
            return try resolver.withUTF8(key, body)
        case .ownedLargeText(let id):
            return try resolver.withLargeTextUTF8(id, body)
        }
    }

    /// Materialize this token's text as a `String`, using `resolver` to
    /// resolve any dynamic key.
    ///
    /// Allocates. For hot-path code, prefer ``withTextUTF8(using:_:)`` to
    /// avoid the copy.
    public func makeString(using resolver: any TokenResolver) -> String {
        switch textStorage {
        case .staticText:
            guard let text = Lang.staticText(for: kind) else {
                return ""
            }
            return text.withUTF8Buffer { bytes in
                String(decoding: bytes, as: UTF8.self)
            }
        case .missing:
            return ""
        case .interned(let key):
            return resolver.resolve(key)
        case .ownedLargeText(let id):
            return resolver.resolveLargeText(id)
        }
    }

    public static func == (lhs: GreenToken<Lang>, rhs: GreenToken<Lang>) -> Bool {
        lhs.storage === rhs.storage
            || (
                lhs.rawKind == rhs.rawKind
                    && lhs.textLength == rhs.textLength
                    && lhs.textStorage == rhs.textStorage
                    && lhs.structuralHash == rhs.structuralHash
            )
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(structuralHash)
        hasher.combine(rawKind)
        hasher.combine(textLength)
        hasher.combine(textStorage)
    }
}

public extension GreenToken {
    /// Construct a static-text token.
    ///
    /// `textLength` is derived from `Lang.staticText(for: kind)`. Throws
    /// ``CambiumCore/GreenTokenError/staticTextUnavailable(_:)`` when the kind has no
    /// static text — use ``missingToken(kind:)`` for an empty placeholder, or
    /// ``internedToken(kind:textLength:key:)`` /
    /// ``largeToken(kind:textLength:id:)`` for dynamic-text kinds.
    static func staticToken(kind: Lang.Kind) throws -> GreenToken<Lang> {
        guard let text = Lang.staticText(for: kind) else {
            throw GreenTokenError.staticTextUnavailable(Lang.rawKind(for: kind))
        }
        var byteCount = 0
        text.withUTF8Buffer { byteCount = $0.count }
        let length: TextSize
        do {
            length = try TextSize(exactly: byteCount)
        } catch {
            throw GreenStorageError.textLengthOverflow
        }
        return GreenToken(kind: kind, textLength: length, text: .staticText)
    }

    /// Construct a missing-text token.
    ///
    /// Renders as empty bytes regardless of `Lang.staticText(for: kind)`;
    /// `textLength` is always zero. Used for error-recovery placeholders
    /// for kinds that would normally have static or dynamic text.
    static func missingToken(kind: Lang.Kind) -> GreenToken<Lang> {
        GreenToken(kind: kind, textLength: .zero, text: .missing)
    }

    /// Construct an interned-text token.
    ///
    /// Throws ``CambiumCore/GreenTokenError/staticKindRequiresDynamicToken(_:)`` when
    /// the kind has non-`nil` `Lang.staticText(for:)` — use
    /// ``staticToken(kind:)`` for that case.
    ///
    /// - Important: The caller is responsible for `textLength` matching the
    /// resolver's bytes for `key`; mismatch is caught at serialization
    /// time, not at construction.
    static func internedToken(
        kind: Lang.Kind,
        textLength: TextSize,
        key: TokenKey
    ) throws -> GreenToken<Lang> {
        if Lang.staticText(for: kind) != nil {
            throw GreenTokenError.staticKindRequiresDynamicToken(Lang.rawKind(for: kind))
        }
        return GreenToken(kind: kind, textLength: textLength, text: .interned(key))
    }

    /// Construct a large-text token.
    ///
    /// Same kind/static-text validation as ``internedToken(kind:textLength:key:)``.
    /// Use this entry point when the text is unique enough that interning
    /// would not pay off (long string literals, raw text blocks).
    static func largeToken(
        kind: Lang.Kind,
        textLength: TextSize,
        id: LargeTokenTextID
    ) throws -> GreenToken<Lang> {
        if Lang.staticText(for: kind) != nil {
            throw GreenTokenError.staticKindRequiresDynamicToken(Lang.rawKind(for: kind))
        }
        return GreenToken(kind: kind, textLength: textLength, text: .ownedLargeText(id))
    }
}

struct GreenNodeHeader {
    var rawKind: RawSyntaxKind
    var textLength: TextSize
    var childCount: Int
    var nodeChildCount: Int
    var structuralHash: UInt64
}

final class GreenNodeStorage<Lang: SyntaxLanguage>: ManagedBuffer<GreenNodeHeader, GreenElement<Lang>> {
    deinit {
        _ = withUnsafeMutablePointerToElements { elements in
            elements.deinitialize(count: header.childCount)
        }
    }
}

/// An interior node in the immutable green layer.
///
/// `GreenNode` is the position-independent representation of a syntactic
/// production. It carries a kind, a flat array of children (other nodes and
/// tokens), the total UTF-8 byte length of all descendant text, and a
/// pre-computed structural hash. Like ``CambiumCore/GreenToken``, green nodes are
/// **shared** across positions and across tree versions: the same green
/// node may appear at many source positions when `GreenNodeCache`
/// dedupes equal candidates.
///
/// ## Construction
///
/// Most code never builds nodes directly — use `GreenTreeBuilder`, which
/// routes through `GreenNodeCache` for dedup and validates open/close
/// pairing. Direct construction is reserved for replacement and
/// out-of-band tree assembly.
///
/// `init(kind:children:)` (raw or typed kind) computes text length,
/// counts node children, and builds the structural hash. It throws
/// ``CambiumCore/GreenStorageError/textLengthOverflow`` if the children's combined
/// text length would exceed `UInt32.max`.
///
/// ## Children
///
/// Children appear in source order. ``childCount`` returns the total number
/// of children (nodes plus tokens); ``nodeChildCount`` returns just the
/// node count, which is the metric the lazy red layer cares about. Use
/// ``child(at:)`` for indexed access and ``childrenArray()`` to
/// materialize the full child list (allocates).
///
/// ## Identity
///
/// ``identity`` returns a ``CambiumCore/GreenNodeIdentity`` keyed on storage object
/// identity. Two nodes with equal `identity` share the same in-memory
/// storage; two nodes that are structurally equal but allocated separately
/// have distinct `identity`. Identity is the right comparison for
/// detecting structural sharing across tree versions; equality (`==`) is
/// the right comparison for cache lookup.
///
/// ## Sendability
///
/// Green nodes are `@unchecked Sendable` because their storage is a final
/// reference type with immutable contents. They can be safely shared
/// across actor boundaries.
public struct GreenNode<Lang: SyntaxLanguage>: @unchecked Sendable, Hashable {
    internal let storage: GreenNodeStorage<Lang>

    /// Construct a green node from a raw kind and a child list.
    ///
    /// Computes total text length, counts node children, and builds the
    /// structural hash. Throws ``CambiumCore/GreenStorageError/textLengthOverflow`` if
    /// the children's combined text length would exceed `UInt32.max`.
    ///
    /// Most call sites should use `GreenTreeBuilder` instead, which adds
    /// dedup via `GreenNodeCache`.
    public init(kind: RawSyntaxKind, children: [GreenElement<Lang>] = []) throws {
        var length = TextSize.zero
        var nodeChildCount = 0
        var childHashes: [UInt64] = []
        childHashes.reserveCapacity(children.count)

        for child in children {
            if case .node = child {
                nodeChildCount += 1
            }
            do {
                length = try length.adding(child.textLength)
            } catch {
                throw GreenStorageError.textLengthOverflow
            }
            childHashes.append(child.structuralHash)
        }

        let hash = GreenHash.node(rawKind: kind, textLength: length, children: childHashes)
        self.storage = GreenNode.makeStorage(
            rawKind: kind,
            textLength: length,
            nodeChildCount: nodeChildCount,
            structuralHash: hash,
            children: children
        )
    }

    /// Construct a green node from a typed `Lang.Kind` and a child list.
    public init(kind: Lang.Kind, children: [GreenElement<Lang>] = []) throws {
        try self.init(kind: Lang.rawKind(for: kind), children: children)
    }

    /// Compatibility initializer for tests and placeholder clients. It
    /// creates an empty node header; production construction should pass
    /// children. Traps if `childCount > 0`.
    public init(kind: RawSyntaxKind, textLength: TextSize, childCount: Int) {
        precondition(childCount == 0, "Explicit childCount construction cannot populate children")
        self.storage = GreenNode.makeStorage(
            rawKind: kind,
            textLength: textLength,
            nodeChildCount: 0,
            structuralHash: GreenHash.node(rawKind: kind, textLength: textLength, children: []),
            children: []
        )
    }

    private static func makeStorage(
        rawKind: RawSyntaxKind,
        textLength: TextSize,
        nodeChildCount: Int,
        structuralHash: UInt64,
        children: [GreenElement<Lang>]
    ) -> GreenNodeStorage<Lang> {
        let header = GreenNodeHeader(
            rawKind: rawKind,
            textLength: textLength,
            childCount: children.count,
            nodeChildCount: nodeChildCount,
            structuralHash: structuralHash
        )
        let storage = GreenNodeStorage<Lang>.create(minimumCapacity: children.count) { _ in
            header
        } as! GreenNodeStorage<Lang>
        storage.withUnsafeMutablePointerToElements { elements in
            for index in children.indices {
                (elements + index).initialize(to: children[index])
            }
        }
        return storage
    }

    /// The language-agnostic kind of this node.
    public var rawKind: RawSyntaxKind {
        storage.header.rawKind
    }

    /// The typed kind of this node, projected through the language.
    public var kind: Lang.Kind {
        Lang.kind(for: rawKind)
    }

    /// The total UTF-8 byte length covered by this node's descendants
    /// (children, grandchildren, …). Pre-computed at construction.
    public var textLength: TextSize {
        storage.header.textLength
    }

    /// The total number of children — both nodes and tokens.
    public var childCount: Int {
        storage.header.childCount
    }

    /// The number of children that are nodes (not tokens). Used by the red
    /// arena to size its lazy slot array.
    public var nodeChildCount: Int {
        storage.header.nodeChildCount
    }

    /// A pre-computed FNV-1a-style hash mixing kind, length, child count,
    /// and recursive child hashes. Used as the cache key by
    /// `GreenNodeCache`.
    public var structuralHash: UInt64 {
        storage.header.structuralHash
    }

    /// The `index`-th child (node or token) in source order. Traps on
    /// out-of-range indices.
    public func child(at index: Int) -> GreenElement<Lang> {
        precondition(index >= 0 && index < childCount, "Green child index out of bounds")
        return storage.withUnsafeMutablePointerToElements { elements in
            (elements + index).pointee
        }
    }

    /// Allocate and return all children as a Swift `Array`. Convenience for
    /// non-hot-path code; traversal hot paths should use ``child(at:)`` to
    /// avoid the allocation.
    public func childrenArray() -> [GreenElement<Lang>] {
        var result: [GreenElement<Lang>] = []
        result.reserveCapacity(childCount)
        for index in 0..<childCount {
            result.append(child(at: index))
        }
        return result
    }

    /// The byte offset at which the `childIndex`-th child begins, relative
    /// to this node. `childIndex == childCount` is allowed and returns the
    /// node's total length. Linear scan over preceding children.
    public func childStartOffset(at childIndex: Int) -> TextSize {
        precondition(childIndex >= 0 && childIndex <= childCount, "Green child index out of bounds")
        var offset = TextSize.zero
        if childIndex == 0 {
            return offset
        }
        for index in 0..<childIndex {
            offset = offset + child(at: index).textLength
        }
        return offset
    }

    /// Walk this subtree depth-first and write every token's UTF-8 bytes
    /// into `sink`. Useful for building text without allocating
    /// intermediate strings.
    public func writeText<Sink: UTF8Sink>(
        to sink: inout Sink,
        using resolver: any TokenResolver
    ) throws {
        for index in 0..<childCount {
            try child(at: index).writeText(to: &sink, using: resolver)
        }
    }

    /// Materialize this subtree's source text as a `String`, using
    /// `resolver` to resolve dynamic token keys.
    ///
    /// Allocates. For streaming output, use ``writeText(to:using:)`` with a
    /// custom ``CambiumCore/UTF8Sink``.
    public func makeString(using resolver: any TokenResolver) -> String {
        var sink = StringUTF8Sink()
        try? writeText(to: &sink, using: resolver)
        return sink.result
    }

    public static func == (lhs: GreenNode<Lang>, rhs: GreenNode<Lang>) -> Bool {
        if lhs.storage === rhs.storage {
            return true
        }
        guard lhs.rawKind == rhs.rawKind,
              lhs.textLength == rhs.textLength,
              lhs.childCount == rhs.childCount,
              lhs.structuralHash == rhs.structuralHash
        else {
            return false
        }

        for index in 0..<lhs.childCount {
            if lhs.child(at: index) != rhs.child(at: index) {
                return false
            }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(structuralHash)
        hasher.combine(rawKind)
        hasher.combine(textLength)
        hasher.combine(childCount)
    }
}

/// Either a green ``CambiumCore/GreenNode`` or a green ``CambiumCore/GreenToken`` — the homogeneous
/// child type of a green tree.
///
/// The green layer uses a single child type so storage stays compact and
/// generic visitors don't need separate node-vs-token paths. Use the
/// `case`-based switch when the distinction matters; the convenience
/// properties on this enum (``rawKind``, ``textLength``, ``structuralHash``)
/// answer the questions both variants have in common.
public enum GreenElement<Lang: SyntaxLanguage>: @unchecked Sendable, Hashable {
    /// A node (interior, child-bearing) green element.
    case node(GreenNode<Lang>)

    /// A token (leaf, text-bearing) green element.
    case token(GreenToken<Lang>)

    /// The language-agnostic kind of this element.
    public var rawKind: RawSyntaxKind {
        switch self {
        case .node(let node):
            node.rawKind
        case .token(let token):
            token.rawKind
        }
    }

    /// The typed kind of this element, projected through the language.
    public var kind: Lang.Kind {
        Lang.kind(for: rawKind)
    }

    /// The UTF-8 byte length of this element (for tokens, the token's text;
    /// for nodes, the sum over their descendants).
    public var textLength: TextSize {
        switch self {
        case .node(let node):
            node.textLength
        case .token(let token):
            token.textLength
        }
    }

    /// The pre-computed structural hash of this element. Cache key for
    /// `GreenNodeCache`.
    public var structuralHash: UInt64 {
        switch self {
        case .node(let node):
            node.structuralHash
        case .token(let token):
            token.structuralHash
        }
    }

    /// Walk this element depth-first and write every token's UTF-8 bytes
    /// into `sink`.
    public func writeText<Sink: UTF8Sink>(
        to sink: inout Sink,
        using resolver: any TokenResolver
    ) throws {
        switch self {
        case .node(let node):
            try node.writeText(to: &sink, using: resolver)
        case .token(let token):
            try token.withTextUTF8(using: resolver) { bytes in
                try sink.write(bytes)
            }
        }
    }
}

/// A green subtree paired with the resolver that gives meaning to its
/// dynamic token keys.
///
/// Use `ResolvedGreenNode` to pass a green subtree across an API boundary
/// where the receiver does not already know which resolver to use — for
/// example, when supplying a replacement subtree to
/// `SharedSyntaxTree.replacing(_:with:cache:)`. Bundling the resolver
/// closes the gap that would otherwise force a fallback overlay path.
public struct ResolvedGreenNode<Lang: SyntaxLanguage>: Sendable {
    /// The green subtree.
    public let root: GreenNode<Lang>

    /// The resolver that resolves every dynamic token key referenced by
    /// `root`.
    public let resolver: any TokenResolver

    /// Pair a green subtree with its resolver.
    public init(root: GreenNode<Lang>, resolver: any TokenResolver) {
        self.root = root
        self.resolver = resolver
    }
}
