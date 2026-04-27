/// Runtime-local key for dynamically interned token text.
///
/// A token key is meaningful only with the `TokenResolver` or interner that
/// produced the tree containing it. The raw value is not a durable,
/// cross-process, or serialized identity; green snapshot serialization
/// canonicalizes token text into snapshot-local tables instead of preserving
/// runtime keys.
public struct TokenKey: RawRepresentable, Sendable, Hashable, Comparable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt32) {
        self.init(rawValue: rawValue)
    }

    public static func < (lhs: TokenKey, rhs: TokenKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct LargeTokenTextID: RawRepresentable, Sendable, Hashable, Comparable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt32) {
        self.init(rawValue: rawValue)
    }

    public static func < (lhs: LargeTokenTextID, rhs: LargeTokenTextID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum TokenTextError: Error, Sendable, Equatable {
    case invalidUTF8
}

/// Identity of a token-key namespace.
///
/// `TokenKey` and `LargeTokenTextID` values are only meaningful inside the
/// namespace produced by one interner/resolver family. Builders can use this
/// identity to decide whether a green subtree may be reused directly or must
/// have its dynamic token keys remapped.
public final class TokenKeyNamespace: @unchecked Sendable {
    public init() {}
}

public enum TokenTextStorage: Sendable, Hashable {
    /// Renders the kind's static text from `Lang.staticText(for:)`.
    /// Token length must equal the static text's UTF-8 byte length.
    case staticText
    /// A token of a kind that *would* have static text but is absent in the
    /// source (an error-recovery placeholder). Renders as empty regardless
    /// of the kind's static text. Token length must be zero.
    case missing
    case interned(TokenKey)
    case ownedLargeText(LargeTokenTextID)
}

public protocol TokenResolver: Sendable {
    /// Namespace for token keys this resolver can resolve, if it has a single
    /// coherent namespace.
    ///
    /// Resolvers that compose multiple namespaces, such as overlays, should
    /// return `nil` so builders remap reused subtrees conservatively.
    var tokenKeyNamespace: TokenKeyNamespace? { get }

    func resolve(_ key: TokenKey) -> String
    func resolveLargeText(_ id: LargeTokenTextID) -> String

    func withUTF8<R>(
        _ key: TokenKey,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R

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

/// Immutable token-text table for a finished green tree.
///
/// A snapshot resolves token keys that already exist in the tree it was
/// created with. It does not intern new text and does not observe future
/// mutations to a builder cache that shares the same namespace.
public struct TokenTextSnapshot: TokenResolver, Sendable {
    private let interned: [String]
    private let large: [String]
    public let namespace: TokenKeyNamespace

    public var tokenKeyNamespace: TokenKeyNamespace? {
        namespace
    }

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

public enum GreenStorageError: Error, Sendable, Equatable {
    case textLengthOverflow
    case staticTextLengthMismatch(expected: TextSize, actual: TextSize)
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

public struct GreenToken<Lang: SyntaxLanguage>: @unchecked Sendable, Hashable {
    internal let storage: GreenTokenStorage<Lang>

    public init(kind: RawSyntaxKind, textLength: TextSize, text: TokenTextStorage = .staticText) {
        self.storage = GreenTokenStorage(rawKind: kind, textLength: textLength, text: text)
    }

    public init(kind: Lang.Kind, textLength: TextSize, text: TokenTextStorage = .staticText) {
        self.init(kind: Lang.rawKind(for: kind), textLength: textLength, text: text)
    }

    public var rawKind: RawSyntaxKind {
        storage.rawKind
    }

    public var kind: Lang.Kind {
        Lang.kind(for: rawKind)
    }

    public var textLength: TextSize {
        storage.textLength
    }

    public var textStorage: TokenTextStorage {
        storage.text
    }

    public var structuralHash: UInt64 {
        storage.structuralHash
    }

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

public struct GreenNode<Lang: SyntaxLanguage>: @unchecked Sendable, Hashable {
    internal let storage: GreenNodeStorage<Lang>

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

    public init(kind: Lang.Kind, children: [GreenElement<Lang>] = []) throws {
        try self.init(kind: Lang.rawKind(for: kind), children: children)
    }

    /// Compatibility initializer for tests and placeholder clients. It creates
    /// an empty node header; production construction should pass children.
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

    public var rawKind: RawSyntaxKind {
        storage.header.rawKind
    }

    public var kind: Lang.Kind {
        Lang.kind(for: rawKind)
    }

    public var textLength: TextSize {
        storage.header.textLength
    }

    public var childCount: Int {
        storage.header.childCount
    }

    public var nodeChildCount: Int {
        storage.header.nodeChildCount
    }

    public var structuralHash: UInt64 {
        storage.header.structuralHash
    }

    public func child(at index: Int) -> GreenElement<Lang> {
        precondition(index >= 0 && index < childCount, "Green child index out of bounds")
        return storage.withUnsafeMutablePointerToElements { elements in
            (elements + index).pointee
        }
    }

    public func childrenArray() -> [GreenElement<Lang>] {
        var result: [GreenElement<Lang>] = []
        result.reserveCapacity(childCount)
        for index in 0..<childCount {
            result.append(child(at: index))
        }
        return result
    }

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

    public func writeText<Sink: UTF8Sink>(
        to sink: inout Sink,
        using resolver: any TokenResolver
    ) throws {
        for index in 0..<childCount {
            try child(at: index).writeText(to: &sink, using: resolver)
        }
    }

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

public enum GreenElement<Lang: SyntaxLanguage>: @unchecked Sendable, Hashable {
    case node(GreenNode<Lang>)
    case token(GreenToken<Lang>)

    public var rawKind: RawSyntaxKind {
        switch self {
        case .node(let node):
            node.rawKind
        case .token(let token):
            token.rawKind
        }
    }

    public var kind: Lang.Kind {
        Lang.kind(for: rawKind)
    }

    public var textLength: TextSize {
        switch self {
        case .node(let node):
            node.textLength
        case .token(let token):
            token.textLength
        }
    }

    public var structuralHash: UInt64 {
        switch self {
        case .node(let node):
            node.structuralHash
        case .token(let token):
            token.structuralHash
        }
    }

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

/// A green subtree paired with the resolver that gives meaning to its dynamic
/// token keys.
public struct ResolvedGreenNode<Lang: SyntaxLanguage>: Sendable {
    public let root: GreenNode<Lang>
    public let resolver: any TokenResolver

    public init(root: GreenNode<Lang>, resolver: any TokenResolver) {
        self.root = root
        self.resolver = resolver
    }
}
