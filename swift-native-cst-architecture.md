# Swift-native CST Architecture

**A borrowing-first, performance-sensitive concrete syntax tree library inspired by Rust `cstree`**

**Document date:** 2026-04-25  
**Intended audience:** engineering lead and implementers  
**Primary use case:** incremental and bidirectional parsing for a SwiftUI-based editor  
**Design stance:** performance-first, borrowing-first, explicit copying/sharing

---

## 1. Executive summary

We want a Swift-native CST library that preserves the practical guarantees of Rust `cstree` while using modern Swift language features rather than imitating Rust mechanically.

The library should be built around:

1. **Immutable green trees**: compact, position-independent, structurally shared, lossless syntax representation.
2. **Lazy persistent red trees**: position-aware parent/child navigation, realized on demand and retained for the life of the tree.
3. **Borrowed, noncopyable traversal cursors as the primary API**: normal traversal should avoid implicit ARC traffic and accidental handle copying.
4. **Explicit copyable handles only when the caller asks for them**: useful for long-lived diagnostics, SwiftUI snapshots, cross-task sharing, and caches, but not the default traversal model.
5. **Noncopyable builders/caches**: parser construction state should be unique and impossible to accidentally duplicate.
6. **Synchronous traversal**: syntax navigation must not be `async`; actors belong at document/session boundaries, not inside nodes.
7. **Thread-safe immutable snapshots**: green storage is immutable, red realization is synchronized, and shared tree handles are `Sendable`.

The most important architectural change from the initial design is this:

> The core public API should not make `SyntaxNode` a freely copyable ergonomic handle. The primary node/token API should be a borrowed, move-only cursor API. Copyable node handles are an explicit opt-in.

This makes performance-visible ownership part of the user experience. Engineers writing syntax queries, highlighters, parsers, indexers, and formatters should naturally use the fast API. Convenience APIs may exist, but they should live in a separate layer or be named so their cost is clear.

---

## 2. Reference model and feature assumptions

This design is based on these external facts and constraints:

### Rust `cstree` reference behavior

Rust `cstree` uses a homogeneous CST model tagged by raw syntax kind. It separates the tree into an immutable position-independent green layer and a position-aware red layer. Green nodes/tokens are deduplicated. Red nodes are created lazily but persist once realized. Red nodes are `Send`/`Sync` by atomically reference-counting the syntax tree as a whole rather than individual nodes. Token strings are interned. Tree replacement creates new trees rather than mutating old ones in place.

Sources:

- `cstree` crate docs: https://docs.rs/cstree/latest/cstree/
- `cstree::syntax` docs: https://docs.rs/cstree/latest/cstree/syntax/index.html
- `cstree::green` docs: https://docs.rs/cstree/latest/cstree/green/index.html
- `cstree` repository: https://github.com/domenicquirl/cstree

### Swift ownership and synchronization features

The proposed architecture assumes modern Swift ownership control is available or acceptable as a toolchain requirement:

- `borrowing` and `consuming` parameter modifiers, implemented in Swift 5.9 via SE-0377.
- noncopyable structs/enums using `~Copyable`, implemented in Swift 5.9 via SE-0390.
- noncopyable generics, implemented in Swift 6.0 but historically gated behind an experimental feature flag in the proposal text; the exact shipping/toolchain status must be verified for the implementation target.
- noncopyable standard library primitives, implemented in Swift 6.0 via SE-0437.
- standard-library `Mutex`, implemented in Swift 6.0 via SE-0433.
- Swift Atomics or standard synchronization atomics for low-level child-slot publication.

Sources:

- SE-0377, borrowing/consuming parameter ownership modifiers: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0377-parameter-ownership-modifiers.md
- SE-0390, noncopyable structs and enums: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md
- SE-0427, noncopyable generics: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md
- SE-0437, noncopyable standard library primitives: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0437-noncopyable-stdlib-primitives.md
- SE-0433, synchronous mutual exclusion lock: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0433-mutex.md
- Swift Atomics package: https://github.com/apple/swift-atomics
- Swift Atomics blog: https://www.swift.org/blog/swift-atomics/

---

## 3. Goals

### 3.1 Semantic goals

The library must provide:

- lossless CST representation;
- homogeneous raw syntax kinds;
- support for trivia, missing syntax, and error syntax;
- immutable persistent green trees;
- position-aware red trees;
- lazy red-node realization;
- stable handles within a tree version;
- structural sharing between related trees;
- safe concurrent traversal of a shared tree snapshot;
- explicit replacement/edit APIs that create new trees;
- parser-neutral infrastructure for incremental parsing.

### 3.2 Performance goals

The library must make the performance-sensitive path the default:

- no accidental owned node copies during normal traversal;
- no per-node ARC increments in hot child iteration;
- no `Array` allocation for ordinary child traversal;
- no `String` allocation for token text unless requested;
- no actor hop during syntax navigation;
- no `async` syntax APIs;
- no per-red-node class allocation;
- no `ManagedAtomic` allocation per child slot;
- no retaining parent/child red nodes individually;
- predictable memory layout and benchmarkable storage.

### 3.3 API goals

The API should make ownership visible:

- borrowed cursors are the primary node/token representation;
- copyable handles have names that make their cost clear;
- long-lived references require explicit conversion;
- builder/session/cache state is move-only;
- APIs that allocate collections should be named as allocation-producing convenience APIs.

### 3.4 SwiftUI/editor goals

The core library should not depend on SwiftUI, Combine, AppKit, or UIKit. It should, however, support SwiftUI editors by making immutable parsed snapshots cheap and safe to publish.

The expected SwiftUI integration boundary is a copyable snapshot wrapper containing an explicitly shared syntax tree handle, not freely copyable syntax nodes in the core traversal API.

---

## 4. Non-goals

The library should not:

- own a language parser;
- provide grammar-specific typed AST nodes in the core module;
- mutate syntax trees in place;
- make red-node navigation actor-isolated;
- optimize for maximal source-code ergonomics over performance;
- provide `node.children -> [SyntaxNode]` as a core hot-path API;
- hide sharing/copying costs behind innocent-looking value copies;
- store every token as a Swift `String`;
- expose unsafe pointers in public stable APIs;
- promise cross-version node identity.

---

## 5. Core terminology

### Green tree

The green tree is immutable, position-independent syntax storage. Green nodes know their kind, child structure, text length, and structural hash. Green tokens know their kind, text length, and text identity. Green elements are nodes or tokens.

Green storage is the persistence and sharing layer.

### Red tree

The red tree overlays source position, parent links, child indices, and navigation state on top of the green tree. Red nodes are realized lazily and persist once created.

Red storage is the traversal and identity layer.

### Borrowed cursor

A borrowed cursor is a noncopyable, non-owning view of a red node or token within a borrow scope. It does not retain the tree. It is the primary traversal representation.

### Explicit handle

A handle is a copyable, owned reference to a node/token/tree. It strongly retains the underlying tree storage. Handles are useful for storage, cross-task work, SwiftUI snapshots, diagnostics, and caches. They are intentionally not the default traversal representation.

### Witness

A witness is a pure structural description of an edit or incremental reparse, returned alongside the new tree. Cross-tree identity tracking is *not* a core concern; consumers translate v0 references to v1 by inspecting the witness, and compose their own identity tables outside the library. See `WITNESS.md` for the full design and `ReplacementWitness` / `ParseWitness` for the concrete types.

---

## 6. Layered architecture

The library should have four conceptual layers:

```text
Parser events / builder operations
        ↓
Green storage
  immutable, lossless, position-independent, structurally shared
        ↓
Red storage
  lazy, persistent, position-aware, stable within one tree
        ↓
Views
  borrowed cursors first; explicit copyable handles second; typed AST overlay optional
```

Recommended package/module split:

```text
CSTCore
  TextSize, TextRange, RawSyntaxKind, SyntaxLanguage
  GreenNode, GreenToken, SyntaxTree storage
  red arena, borrowed cursors, explicit handles
  traversal primitives, text streaming

CSTBuilder
  GreenTreeBuilder
  GreenNodeCache
  token interner/resolver
  parser event/checkpoint utilities

CSTIncremental
  ReuseOracle
  ParseWitness
  edit/range mapping
  incremental parse session infrastructure

CSTAnalysis
  diagnostics
  typed node metadata keys
  analysis cache helpers

CSTASTSupport
  optional typed wrappers
  macro/codegen support for language-specific AST overlays

CSTTesting
  roundtrip assertions
  sharing assertions
  concurrent traversal stress tests
  debug tree rendering
```

`CSTCore` should have no UI dependencies and no parser dependencies.

---

## 7. Ownership-first public API model

This section is the most important part of the architecture.

The library should be designed so that the default usage pattern is fast, explicit, and ownership-aware. Copyable convenience should exist only where it is clearly named and intentionally chosen.

### 7.1 Primary public types

The primary public tree type should be noncopyable:

```swift
public struct SyntaxTree<Lang: SyntaxLanguage>: ~Copyable, Sendable {
    // Owns one immutable syntax snapshot.
    // Cannot be implicitly copied.
}
```

The primary traversal types should be noncopyable borrowed cursors:

```swift
public struct SyntaxNodeCursor<Lang: SyntaxLanguage>: ~Copyable {
    // Borrowed view of a red node.
    // Does not retain tree storage.
}

public struct SyntaxTokenCursor<Lang: SyntaxLanguage>: ~Copyable {
    // Borrowed view of a token.
    // Does not retain tree storage.
}

public enum SyntaxElementCursor<Lang: SyntaxLanguage>: ~Copyable {
    case node(SyntaxNodeCursor<Lang>)
    case token(SyntaxTokenCursor<Lang>)
}
```

The explicit copyable types should be named as handles or shared snapshots:

```swift
public struct SharedSyntaxTree<Lang: SyntaxLanguage>: Sendable {
    // Copyable by design.
    // Strongly retains SyntaxTreeStorage.
}

public struct SyntaxNodeHandle<Lang: SyntaxLanguage>: Sendable, Hashable {
    // Copyable by design.
    // Strongly retains SharedSyntaxTree storage.
}

public struct SyntaxTokenHandle<Lang: SyntaxLanguage>: Sendable, Hashable {
    // Copyable by design.
    // Strongly retains SharedSyntaxTree storage.
}
```

Naming matters. `SyntaxNodeCursor` communicates traversal. `SyntaxNodeHandle` communicates storage/ownership. Avoid calling the copyable handle simply `SyntaxNode` in the core API, because that invites accidental copying and hides ARC costs.

### 7.2 Borrow scopes

Tree traversal should normally begin with a borrow scope:

```swift
extension SyntaxTree {
    public borrowing func withRoot<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R
}

extension SharedSyntaxTree {
    public func withRoot<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R
}
```

Example hot-path use:

```swift
tree.withRoot { root in
    root.visitPreorder { node in
        if node.rawKind == MyLangKinds.identifier.rawValue {
            // inspect node without retaining the tree per step
        }
    }
}
```

### 7.3 Explicit sharing and copying

Copyable sharing should be opt-in:

```swift
extension SyntaxTree {
    public borrowing func share() -> SharedSyntaxTree<Lang>
    public consuming func intoShared() -> SharedSyntaxTree<Lang>
}

extension SyntaxNodeCursor {
    public borrowing func makeHandle() -> SyntaxNodeHandle<Lang>
}
```

Use cases for `SharedSyntaxTree`:

- publish a parsed snapshot to SwiftUI;
- send a tree snapshot to another task;
- keep a tree alive while storing diagnostics;
- store long-lived language-server snapshots.

Use cases for `SyntaxNodeHandle`:

- diagnostic primary node;
- temporary cross-task reference within the same tree version;
- explicit external cache key;
- debug tooling.

In normal syntax traversal, do not use handles.

### 7.4 Primary traversal should not allocate collections

Avoid this as a primary API:

```swift
// Not core hot-path API.
let children: [SyntaxNodeHandle] = node.childrenArray()
```

Prefer:

```swift
node.forEachChild { child in
    // child is a borrowing SyntaxNodeCursor
}
```

or:

```swift
node.forEachChildOrToken { element in
    switch element {
    case .node(let child):
        // borrowed child cursor
    case .token(let token):
        // borrowed token cursor
    }
}
```

For algorithms that need an explicit stack, provide a noncopyable cursor stack type:

```swift
public struct SyntaxCursorStack<Lang: SyntaxLanguage>: ~Copyable {
    public mutating func pushCurrent(_ cursor: borrowing SyntaxNodeCursor<Lang>)
    public mutating func popInto(_ cursor: inout SyntaxNodeCursor<Lang>) -> Bool
}
```

The stack should store compact red IDs and offsets, not owned node handles.

### 7.5 Mutating cursor navigation

A cursor should support navigation by mutation:

```swift
extension SyntaxNodeCursor {
    public borrowing var rawKind: RawSyntaxKind { get }
    public borrowing var kind: Lang.Kind { get }
    public borrowing var textRange: TextRange { get }
    public borrowing var textLength: TextSize { get }

    public mutating func moveToParent() -> Bool
    public mutating func moveToFirstChild() -> Bool
    public mutating func moveToLastChild() -> Bool
    public mutating func moveToNextSibling() -> Bool
    public mutating func moveToPreviousSibling() -> Bool
}
```

This is useful for tight loops that want to reuse a single cursor value.

When a caller needs to inspect a child without moving the parent cursor, use scoped duplication instead of implicit copying:

```swift
extension SyntaxNodeCursor {
    public borrowing func withChildNode<R>(
        at index: Int,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R?
}
```

### 7.6 Convenience APIs belong in a separate layer

A convenience module may provide ergonomic copyable wrappers:

```swift
extension SyntaxNodeHandle {
    public var children: [SyntaxNodeHandle] { get }
    public var descendants: AnySequence<SyntaxNodeHandle> { get }
}
```

This should not be the core API and should be documented as allocation/retain-producing.

Recommended module name: `CSTConvenience` or `CSTOwnedTraversal`.

---

## 8. Language abstraction

The core tree is language-generic.

```swift
public struct RawSyntaxKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32
}

public protocol SyntaxLanguage: Sendable {
    associatedtype Kind: RawRepresentable & Hashable & Sendable
        where Kind.RawValue == UInt32

    static func rawKind(for kind: Kind) -> RawSyntaxKind
    static func kind(for raw: RawSyntaxKind) -> Kind

    static func staticText(for kind: Kind) -> StaticString?
    static func isTrivia(_ kind: Kind) -> Bool
    static func isNode(_ kind: Kind) -> Bool
    static func isToken(_ kind: Kind) -> Bool

    static var errorKind: Kind { get }
    static var missingKind: Kind { get }
}
```

The core should not know about grammar-specific typed nodes such as `FunctionDeclSyntax`. Typed AST wrappers should be built on top of red cursors and handles.

### 8.1 Trivia

Represent trivia as ordinary tokens by default:

```text
WHITESPACE
LINE_COMMENT
BLOCK_COMMENT
IDENTIFIER
PLUS
CALL_EXPR
ERROR
```

This preserves losslessness and keeps the core parser-neutral. Typed overlays can provide trivia-skipping child accessors.

### 8.2 Missing and error syntax

Support zero-length missing tokens/nodes and explicit error nodes. IDE parsing must represent incomplete source without failing.

Recommended invariants:

- missing syntax has zero text length;
- error syntax has ordinary children/tokens and nonzero text length if it covers text;
- missing syntax participates in tree shape but not text rendering;
- error nodes participate in text rendering and range queries.

Missing tokens are represented at storage level by the `.missing` variant of
`TokenTextStorage` (see §10.1), which is distinct from `.staticText`. This
distinction matters when a missing token's kind has static text (e.g. an
expected `+` that the source omitted) — the token must render empty, not
render the static text. Implementations should enforce the zero-length
invariant at construction time so that a `.missing` token cannot be
constructed with a nonzero length.

---

## 9. Text model

Use UTF-8 byte offsets in core APIs.

```swift
public struct TextSize: RawRepresentable, Comparable, Hashable, Sendable {
    public let rawValue: UInt32
}

public struct TextRange: Hashable, Sendable {
    public let start: TextSize
    public let end: TextSize
}
```

Rationale:

- parsers usually operate on UTF-8;
- byte offsets are cheap and stable;
- Swift `String.Index` is too expensive for core syntax storage;
- LSP/editor workflows usually need byte/UTF offsets at boundaries;
- conversion can happen at UI/document boundaries.

Default to `UInt32` for compact storage. Provide a feature flag or alternate type for very large files if needed:

```swift
public typealias TextSizeStorage = UInt32
// Optional future: UInt64-backed TextSize64
```

All builder and replacement operations must check overflow.

---

## 10. Token text, interning, and resolving

### 10.1 Token text model

Token text should be one of:

```swift
public enum TokenTextStorage: Sendable, Hashable {
    case staticText
    case missing
    case interned(TokenKey)
    case ownedLargeText(LargeTokenTextID) // optional, policy-controlled
}
```

Each variant has a distinct rendering and length contract:

- **`.staticText`** — the token renders the kind's static text from
  `Lang.staticText(for: kind)`. Token length must equal that text's UTF-8
  byte length.
- **`.missing`** — the token is an absent placeholder for error recovery
  (the parser expected this kind but the source did not contain it). The
  token always renders as empty regardless of whether the kind has static
  text. Token length must be zero. This is a separate variant from
  `.staticText` so that a missing-token of a static-text kind (e.g. an
  expected `+` that the source omitted) does *not* render the static text;
  conflating the two produces trees whose aggregate `textLength` does not
  match their rendered text.
- **`.interned(TokenKey)`** — dynamic token text stored in an interner;
  the resolver maps the key back to bytes/`String`.
- **`.ownedLargeText(LargeTokenTextID)`** — an optional, policy-controlled
  escape hatch for tokens whose text is too large to intern profitably.

Static tokens are provided by the language:

```swift
Lang.staticText(for: kind)
```

Dynamic token text is interned by default:

```swift
public struct TokenKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32
}
```

`TokenKey.rawValue` is resolver/interner-local. It is meaningful only with the
resolver that produced the tree or build result, and must not be treated as a
durable serialized identity.

The structural hash mixes a different per-variant tag value for each case
above so that, for example, `(.plus, length 0, .staticText)` (which would
be invalid — `.plus` has nonzero static text) and `(.plus, length 0, .missing)`
(the legal absent placeholder) are not collapsed by the green node cache.

### 10.2 Resolver/interner split

Use a split similar to `cstree`: builders need an interner; finished trees need only a resolver.

```swift
public protocol TokenResolver: Sendable {
    func resolve(_ key: TokenKey) -> String

    func withUTF8<R>(
        _ key: TokenKey,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R
}

public protocol TokenInterner: TokenResolver {
    mutating func intern(_ bytes: UnsafeBufferPointer<UInt8>) -> TokenKey
}
```

Prefer interning from UTF-8 bytes, not from `String`, in parser hot paths.

### 10.3 Interner implementations

Provide:

```swift
public struct LocalTokenInterner: ~Copyable {
    // Fast, single-threaded, builder-owned.
}

public final class SharedTokenInterner: TokenResolver, @unchecked Sendable {
    // Sharded Mutex-protected storage.
}
```

The default parser path should use `LocalTokenInterner`. Shared interning is optional and should be sharded if used heavily.
The current shared interner uses an 8-bit shard / 24-bit local-index runtime key
layout and traps before shard-local exhaustion rather than aliasing keys.

Avoid global unbounded interners.

---

## 11. Green tree storage

### 11.1 Public green API

Green nodes/tokens are immutable syntax storage. Because green nodes are persistent and often need to be reused across trees, green references may be copyable as long as the implementation keeps copy cost predictable and avoids using green references in red traversal hot loops.

```swift
public struct GreenNode<Lang: SyntaxLanguage>: Sendable, Hashable {
    fileprivate let storage: GreenNodeStorage<Lang>
}

public struct GreenToken<Lang: SyntaxLanguage>: Sendable, Hashable {
    fileprivate let storage: GreenTokenStorage<Lang>
}

public enum GreenElement<Lang: SyntaxLanguage>: Sendable, Hashable {
    case node(GreenNode<Lang>)
    case token(GreenToken<Lang>)
}
```

If benchmarks show unacceptable ARC overhead in green reuse, move to a `GreenStore` + `GreenID` model. That model stores green nodes/tokens in arena/pool storage and makes green references compact IDs plus an explicit store owner.

### 11.2 Green node storage

Production storage should be compact and immutable:

```swift
final class GreenNodeStorage<Lang: SyntaxLanguage>: @unchecked Sendable {
    let rawKind: RawSyntaxKind
    let textLength: TextSize
    let childCount: UInt32
    let structuralHash: UInt64
    // Tail-allocated GreenElementStorage[childCount]
}
```

Do not represent production green nodes as:

```swift
let children: [GreenElement<Lang>]
```

unless benchmarks prove the overhead is acceptable. A Swift `Array` per node creates allocation and header overhead that can dominate large CSTs.

Preferred storage options:

1. `ManagedBuffer`-style single allocation per green node;
2. custom slab/arena allocation with immutable records;
3. compact child buffers indexed by node header.

### 11.3 Green token storage

```swift
final class GreenTokenStorage<Lang: SyntaxLanguage>: @unchecked Sendable {
    let rawKind: RawSyntaxKind
    let textLength: TextSize
    let text: TokenTextStorage
    let structuralHash: UInt64
}
```

Token text should not allocate a `String` unless the user asks for one. Text rendering should stream UTF-8 whenever possible.

### 11.4 Green structural hashing

Each green node/token should have a structural hash computed during construction.

For nodes:

```text
hash = hash(rawKind, textLength, childCount, child hashes)
```

For tokens:

```text
hash = hash(rawKind, textLength, token text identity/content)
```

Never deduplicate solely by hash. Deduplication must compare:

1. raw kind;
2. text length;
3. child count or token text key;
4. structural hash;
5. full structural equality when needed.

Hash collision tests are mandatory.

---

## 12. Green builder and node cache

### 12.1 Builder is noncopyable

The builder should be move-only:

```swift
public struct GreenTreeBuilder<Lang: SyntaxLanguage>: ~Copyable {
    public init(cache: consuming GreenNodeCache<Lang>)

    public mutating func startNode(_ kind: Lang.Kind)
    public mutating func finishNode()

    public mutating func token(_ kind: Lang.Kind, bytes: UnsafeBufferPointer<UInt8>)
    public mutating func staticToken(_ kind: Lang.Kind)
    public mutating func missingToken(_ kind: Lang.Kind)

    public mutating func checkpoint() -> BuilderCheckpoint
    public mutating func startNode(at checkpoint: BuilderCheckpoint, _ kind: Lang.Kind)
    public mutating func revert(to checkpoint: BuilderCheckpoint)

    public mutating func reuseSubtree(_ node: borrowing SyntaxNodeCursor<Lang>)

    public consuming func finish() -> GreenBuildResult<Lang>
}
```

Noncopyability prevents accidental duplication of parser state, interner state, cache state, and internal child stacks.

### 12.2 Builder internals

A simple internal model:

```swift
parents: [(kind: RawSyntaxKind, firstChildIndex: Int)]
children: [PendingGreenElement]
```

On `finishNode`:

1. take children since `firstChildIndex`;
2. compute total text length;
3. compute structural hash from child hashes;
4. query the node cache;
5. append the deduplicated node as one pending element.

### 12.3 Node cache

The node cache should also be noncopyable:

```swift
public struct GreenNodeCache<Lang: SyntaxLanguage>: ~Copyable {
    var tokenCache: TokenCache
    var nodeCache: NodeCache
    var interner: LocalTokenInterner
}
```

Cache policy:

```swift
public enum GreenCachePolicy: Sendable {
    case disabled
    case documentLocal
    case parseSession(maxBytes: Int)
    case shared(maxBytes: Int)
}
```

Cache aggressively:

- static tokens;
- repeated dynamic tokens;
- small green nodes;
- medium nodes below a configurable threshold.

Avoid caching huge nodes by default.

### 12.4 Shared cache

A shared cache is useful for incremental parse sessions, but should be explicit:

```swift
public final class SharedGreenNodeCache<Lang: SyntaxLanguage>: @unchecked Sendable {
    private let shards: [Mutex<Shard>]
}
```

Do not use one global lock for all syntax nodes/tokens.

---

## 13. Red tree storage

### 13.1 Tree storage

`SyntaxTree` and `SharedSyntaxTree` both point to internal storage:

```swift
final class SyntaxTreeStorage<Lang: SyntaxLanguage>: @unchecked Sendable {
    let treeID: TreeID
    let rootGreen: GreenNode<Lang>
    let resolver: any TokenResolver
    let arena: RedArena<Lang>
}
```

`SyntaxTreeStorage` is retained by:

- one move-only `SyntaxTree` owner;
- any explicit `SharedSyntaxTree` copies;
- any explicit node/token handles.

Borrowed cursors do not retain it.

### 13.2 Red arena

Red records should be arena-owned, not individual classes:

```swift
struct RedNodeID: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt64
}

struct RedNodeRecord<Lang: SyntaxLanguage> {
    let green: GreenNode<Lang>
    let parent: RedNodeID?
    let indexInParent: UInt32
    let offset: TextSize
    let childSlotStart: UInt32
    let childSlotCount: UInt32
    let metadata: NodeMetadata?
}
```

Use chunked/slab allocation so `RedNodeID`s remain stable. Do not use a single `Array` in a way that exposes pointers invalidated by reallocation.

### 13.3 Child slots

Each red node needs slots for child red-node realization. Token children do not need red records.

Slot representation:

```swift
// 0 means unrealized.
// nonzero packs RedNodeID.rawValue + 1 or another sentinel-safe encoding.
UnsafeAtomic<UInt64>
```

Do not allocate one `ManagedAtomic` object per child slot. If using Swift Atomics, `UnsafeAtomic` over tail-allocated/slab storage is the right shape for this hot data. `ManagedAtomic` is convenient but allocates one class instance per atomic value.

### 13.4 Lazy child realization

Fast path:

1. load child slot with acquire ordering;
2. if nonzero, return a cursor for the existing red node;
3. if zero, go to slow path.

Slow path:

1. acquire a per-tree or per-arena realization lock, or a striped lock keyed by parent red ID;
2. recheck the child slot;
3. allocate a red record in the arena;
4. initialize child slots for that child;
5. publish the child red ID with release ordering;
6. return the cursor.

Preferred lock granularity:

- start with arena-level or striped locks for correctness;
- benchmark per-parent locks only if contention appears in real workloads;
- keep atomics isolated in a tiny internal module.

### 13.5 Parent links

Store parent as `RedNodeID?`, not as a strong reference.

The tree arena owns red records. This avoids retain cycles, ARC traffic, and per-node reference counting.

### 13.6 Node identity

Within a tree:

```text
node identity = (treeID, redNodeID)
token identity = (treeID, parentRedNodeID, childIndexInParent)
```

Across trees, node identity is not preserved by the library. Cross-tree identity tracking is externalized — consumers translate v0 references to v1 by inspecting witnesses returned from `replacing(...)` and incremental reparses (see `WITNESS.md`).

---

## 14. Borrowed cursor API

The cursor API is the primary API.

### 14.1 Node cursor

```swift
public struct SyntaxNodeCursor<Lang: SyntaxLanguage>: ~Copyable {
    // Implementation sketch:
    // unowned/unsafe pointer to SyntaxTreeStorage
    // RedNodeID
}
```

Core accessors:

```swift
extension SyntaxNodeCursor {
    public borrowing var rawKind: RawSyntaxKind { get }
    public borrowing var kind: Lang.Kind { get }
    public borrowing var textRange: TextRange { get }
    public borrowing var textLength: TextSize { get }
    public borrowing var childCount: Int { get }
    public borrowing var childOrTokenCount: Int { get }

    public borrowing func green<R>(
        _ body: (borrowing GreenNode<Lang>) throws -> R
    ) rethrows -> R
}
```

Navigation:

```swift
extension SyntaxNodeCursor {
    public mutating func moveToParent() -> Bool
    public mutating func moveToFirstChild() -> Bool
    public mutating func moveToLastChild() -> Bool
    public mutating func moveToNextSibling() -> Bool
    public mutating func moveToPreviousSibling() -> Bool

    public borrowing func withParent<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R?

    public borrowing func withChildNode<R>(
        at index: Int,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R?

    public borrowing func withChildOrToken<R>(
        at index: Int,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R?
}
```

Traversal:

```swift
extension SyntaxNodeCursor {
    public borrowing func forEachChild(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> Void
    ) rethrows

    public borrowing func forEachChildOrToken(
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> Void
    ) rethrows

    public borrowing func visitPreorder(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> TraversalControl
    ) rethrows

    public borrowing func tokens(
        in range: TextRange?,
        _ body: (borrowing SyntaxTokenCursor<Lang>) throws -> Void
    ) rethrows
}
```

Point/range lookup:

```swift
extension SyntaxNodeCursor {
    public borrowing func withToken<R>(
        at offset: TextSize,
        _ body: (borrowing SyntaxTokenCursor<Lang>) throws -> R
    ) rethrows -> R?

    public borrowing func withCoveringElement<R>(
        _ range: TextRange,
        _ body: (borrowing SyntaxElementCursor<Lang>) throws -> R
    ) rethrows -> R?
}
```

Explicit ownership conversions:

```swift
extension SyntaxNodeCursor {
    public borrowing func makeHandle() -> SyntaxNodeHandle<Lang>
}
```

### 14.2 Token cursor

```swift
public struct SyntaxTokenCursor<Lang: SyntaxLanguage>: ~Copyable {
    // tree pointer, parent red ID, child index, offset, green token ref/id
}
```

API:

```swift
extension SyntaxTokenCursor {
    public borrowing var rawKind: RawSyntaxKind { get }
    public borrowing var kind: Lang.Kind { get }
    public borrowing var textRange: TextRange { get }
    public borrowing var textLength: TextSize { get }

    public borrowing func withParent<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R

    public borrowing func withTextUTF8<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R

    public borrowing func makeString() -> String
    public borrowing func makeHandle() -> SyntaxTokenHandle<Lang>
}
```

`makeString()` is explicit and allocating when the token is dynamic.

### 14.3 Element cursor

```swift
public enum SyntaxElementCursor<Lang: SyntaxLanguage>: ~Copyable {
    case node(SyntaxNodeCursor<Lang>)
    case token(SyntaxTokenCursor<Lang>)
}
```

If noncopyable enum ergonomics are problematic in the target Swift version, replace this with closure dispatch:

```swift
public borrowing func withChildOrToken<R>(
    at index: Int,
    node: (borrowing SyntaxNodeCursor<Lang>) throws -> R,
    token: (borrowing SyntaxTokenCursor<Lang>) throws -> R
) rethrows -> R?
```

---

## 15. Explicit handle API

Handles are for intentional sharing and storage.

### 15.1 Shared tree

```swift
public struct SharedSyntaxTree<Lang: SyntaxLanguage>: Sendable {
    fileprivate let storage: SyntaxTreeStorage<Lang>

    public func withRoot<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R

    public func rootHandle() -> SyntaxNodeHandle<Lang>
}
```

`SharedSyntaxTree` is copyable. Copying it increments/decrements one tree-storage reference, not per-node references.

### 15.2 Node/token handles

```swift
public struct SyntaxNodeHandle<Lang: SyntaxLanguage>: Sendable, Hashable {
    fileprivate let tree: SharedSyntaxTree<Lang>
    fileprivate let id: RedNodeID

    public func withCursor<R>(
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R
}

public struct SyntaxTokenHandle<Lang: SyntaxLanguage>: Sendable, Hashable {
    fileprivate let tree: SharedSyntaxTree<Lang>
    fileprivate let parent: RedNodeID
    fileprivate let childIndex: UInt32
    fileprivate let offset: TextSize

    public func withCursor<R>(
        _ body: (borrowing SyntaxTokenCursor<Lang>) throws -> R
    ) rethrows -> R
}
```

### 15.3 Handle discipline

Rules:

- never return handles from primary traversal unless explicitly requested;
- never build arrays of handles in core traversal APIs;
- provide handle collections only in a convenience module;
- document that handles retain tree storage;
- handles are tree-scoped; for cross-version translation, drive an external identity tracker with witnesses (see `WITNESS.md`).

---

## 16. Syntax text rendering

Use streaming text APIs rather than materializing full strings.

```swift
public struct SyntaxText<Lang: SyntaxLanguage>: ~Copyable {
    public borrowing var utf8Count: Int { get }

    public borrowing func writeUTF8(
        to sink: inout some UTF8Sink
    ) throws

    public consuming func makeString() -> String
}
```

Node text:

```swift
extension SyntaxNodeCursor {
    public borrowing func withText<R>(
        _ body: (borrowing SyntaxText<Lang>) throws -> R
    ) rethrows -> R
}
```

The primary API streams text. `makeString()` is explicit.

---

## 17. Replacement and structured editing

Trees are immutable. Replacement creates a new green root and then a new syntax tree.

### 17.1 Green replacement

```swift
extension SyntaxNodeCursor {
    public borrowing func replacingSelf(
        with replacement: borrowing GreenNode<Lang>,
        using cache: inout GreenNodeCache<Lang>
    ) -> GreenNode<Lang>
}
```

This recreates only the ancestor path from the replaced node to the root and shares unchanged green subtrees.

### 17.2 Tree replacement

```swift
extension SyntaxTree {
    public consuming func replacing(
        _ node: borrowing SyntaxNodeCursor<Lang>,
        with replacement: borrowing GreenNode<Lang>,
        cache: consuming GreenNodeCache<Lang>
    ) -> SyntaxTree<Lang>
}
```

Exact Swift signatures may need adjustment depending on ownership feature availability. The important behavior is:

- old tree remains valid if explicitly shared/handled;
- new tree has a new red arena;
- green structure is shared where unchanged;
- replacement is proportional to tree depth plus replacement size;
- kind compatibility is checked unless the caller uses an unsafe API.

### 17.3 Text edits

Structured editing should integrate with normal editor undo/redo:

```swift
public struct SyntaxEdit<Lang: SyntaxLanguage>: Sendable {
    public let range: TextRange
    public let replacement: SharedSyntaxText<Lang>
}
```

A structured replacement can produce a text edit:

```swift
node.withText { oldText in ... }
replacement.withText { newText in ... }
```

---

## 18. Cross-tree identity via witnesses

Node handles are stable only within one tree version. They are not cross-version identity.

Cross-tree identity tracking is *externalized*: edit-producing operations (`replacing(handle:...)` and incremental reparses) return a **witness** alongside the new tree. The witness is a pure structural description of what changed; consumers translate v0 references to v1 by inspecting it. Cambium does not impose a tracker, deletion policy, or fingerprint heuristic.

The two witness types:

```swift
public struct ReplacementWitness<Lang: SyntaxLanguage>: Sendable {
    public let oldRoot: GreenNode<Lang>
    public let newRoot: GreenNode<Lang>
    public let replacedPath: SyntaxNodePath
    public let oldSubtree: GreenNode<Lang>
    public let newSubtree: GreenNode<Lang>
    public func classify(path: SyntaxNodePath) -> ReplacementOutcome<Lang>
}

public struct ParseWitness<Lang: SyntaxLanguage>: Sendable {
    public let oldRoot: GreenNode<Lang>?
    public let newRoot: GreenNode<Lang>
    public let reusedSubtrees: [Reuse<Lang>]
    public let invalidatedRegions: [TextRange]
}
```

Witnesses use `GreenNodeIdentity` (`node.identity`) as the cross-tree "same node" relation: because the cache deduplicates green storage, structurally preserved subtrees keep the same `GreenNode` instance across versions. This makes "preserved" a deterministic identity-equality check rather than a fingerprint-match heuristic.

Use witnesses for: diagnostics, selections, code actions, folding ranges, semantic caches, syntax-highlight invalidation, symbol-index references — all of which previously required fingerprint-based anchors, now drive an external identity tracker by feeding it witnesses on each edit.

See `WITNESS.md` for the full design rationale, classification rules, and the integrator pattern for `ParseWitness` (parser-driven `IncrementalParseSession.recordAcceptedReuse` / `consumeAcceptedReuses`).

---

## 19. Incremental parsing infrastructure

The CST library should support incremental parsing without owning grammar logic.

### 19.1 Parse session

```swift
public final class IncrementalParseSession<Lang: SyntaxLanguage>: Sendable {
    // Owns shared cache/interner policy.
    // Does not own document UI state.
}
```

A parse session may contain:

- shared token interner/resolver;
- shared green node cache;
- cache memory budgets;
- instrumentation counters;
- optional language-specific reuse policy.

### 19.2 Parser-facing API

```swift
public struct ParseInput<Lang: SyntaxLanguage>: Sendable {
    public let text: TextSnapshot
    public let edits: [TextEdit]
    public let previousTree: SharedSyntaxTree<Lang>?
}
```

The parser receives a reuse oracle:

```swift
public struct ReuseOracle<Lang: SyntaxLanguage>: ~Copyable {
    public borrowing func withReusableNode<R>(
        startingAt offset: TextSize,
        kind: Lang.Kind,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R?
}
```

Builder reuse:

```swift
extension GreenTreeBuilder {
    public mutating func reuseSubtree(_ node: borrowing SyntaxNodeCursor<Lang>)
}
```

The parser decides invalidation boundaries and recovery. The CST library provides range lookup, green reuse, structural hashing, and cache reuse.

### 19.3 Bidirectional editor operations

Text to tree:

```swift
root.withToken(at: offset) { token in ... }
root.withCoveringElement(range) { element in ... }
root.tokens(in: visibleRange) { token in ... }
```

Tree to text:

```swift
node.withText { text in
    try text.writeUTF8(to: &sink)
}
```

Tree to edit:

```swift
let edit = SyntaxEdit(range: node.textRange, replacement: replacementText)
```

---

## 20. SwiftUI integration model

The core does not depend on SwiftUI.

Recommended app model:

```swift
@MainActor
final class DocumentModel: ObservableObject {
    @Published private(set) var snapshot: ParsedSnapshot<MyLang>

    func applyUserEdit(_ edit: TextEdit) {
        // 1. update text snapshot immediately
        // 2. start parse task
        // 3. publish immutable ParsedSnapshot when parse completes
    }
}
```

Snapshot:

```swift
public struct ParsedSnapshot<Lang: SyntaxLanguage>: Sendable {
    public let version: UInt64
    public let text: TextSnapshot
    public let tree: SharedSyntaxTree<Lang>
    public let diagnostics: [Diagnostic<Lang>]
}
```

`ParsedSnapshot` is copyable because SwiftUI and observation frameworks expect copyable values. The explicit conversion happens at the boundary:

```swift
let shared = parsedTree.intoShared()
let snapshot = ParsedSnapshot(version: version, text: text, tree: shared, diagnostics: diagnostics)
```

Inside syntax consumers:

```swift
snapshot.tree.withRoot { root in
    root.tokens(in: visibleRange) { token in
        // syntax highlighting without owned node copies
    }
}
```

The UI should store handles or ranges, not node cursors. Cursors are borrow-scoped and should not escape. To follow a reference across tree versions, drive an external identity tracker with witnesses returned from edits.

---

## 21. Concurrency model

### 21.1 Public concurrency guarantees

The library should guarantee:

- `SyntaxTree<Lang>` is move-only and `Sendable` when consumed/transferred.
- `SharedSyntaxTree<Lang>` is copyable and `Sendable`.
- `SyntaxNodeHandle` and `SyntaxTokenHandle` are copyable and `Sendable`.
- Borrowed cursors are not intended for cross-task storage or escape.
- Concurrent traversal of one shared tree is safe.
- Lazy red-node realization is safe under concurrent access.
- Green storage is immutable after publication.

### 21.2 Actors

Do not use actors for node navigation.

Actors are appropriate for:

- document model mutation;
- parse job coordination;
- project-wide indexing state;
- cache eviction policy if it is not on a hot path.

Actors are not appropriate for:

- `node.kind`;
- `node.textRange`;
- `node.forEachChild`;
- `token.text`;
- `root.token(at:)`.

### 21.3 Locks and atomics

Use locks for coarse/rare mutable state:

- shared interner shards;
- shared green cache shards;
- metadata sidecars;
- red arena slow-path allocation if needed.

Use atomics only for low-level publication:

- realized red child slot IDs;
- maybe tree ID counters;
- maybe lazy one-time caches.

Atomic code must be isolated to small audited files. Every atomic protocol must have comments describing memory ordering.

Recommended child slot ordering:

- load with `.acquire`;
- store/publish with `.release`;
- compare-exchange with `.acquiringAndReleasing` or equivalent where necessary.

Exact ordering should be reviewed by someone comfortable with Swift/C++ memory models.

### 21.4 `@unchecked Sendable` policy

Allow `@unchecked Sendable` only for internal storage types satisfying one of:

1. deeply immutable after initialization;
2. mutable state protected by `Mutex`;
3. mutable state accessed only through documented atomics.

Every `@unchecked Sendable` type must have a short invariant comment.

Example:

```swift
// SAFETY: All stored fields are immutable after initialization except `arena`,
// whose mutation is internally synchronized. Published red records are never
// mutated after publication except for atomic child-slot realization.
final class SyntaxTreeStorage<Lang: SyntaxLanguage>: @unchecked Sendable { ... }
```

---

## 22. Node metadata and analysis caches

`cstree` allows user-defined node data. Swift should support metadata, but it should not become the primary semantic cache mechanism.

### 22.1 Typed sidecar keys

```swift
public struct SyntaxDataKey<Value: Sendable>: Sendable {
    public init(_ name: StaticString)
}
```

Cursor API:

```swift
extension SyntaxNodeCursor {
    public borrowing func data<Value: Sendable>(
        for key: SyntaxDataKey<Value>
    ) -> Value?

    public borrowing func getOrComputeData<Value: Sendable>(
        for key: SyntaxDataKey<Value>,
        _ compute: () -> Value
    ) -> Value
}
```

### 22.2 Internal storage

```swift
final class NodeMetadata: @unchecked Sendable {
    private let storage: Mutex<[MetadataKeyID: AnySendableBox]>
}
```

This has runtime lookup and locking overhead. It is useful for memoized local syntax facts, but large semantic systems should use external caches keyed by `SyntaxNodeIdentity`, `TreeID`, or explicit node handles, with cross-tree migration driven by witnesses.

---

## 23. Typed AST overlay

Typed AST wrappers should be lightweight and should not own or duplicate tree structure.

Borrowed typed view:

```swift
public struct FunctionDeclCursor<Lang: SyntaxLanguage>: ~Copyable {
    private var syntax: SyntaxNodeCursor<Lang>
}
```

Handle typed view:

```swift
public struct FunctionDeclHandle<Lang: SyntaxLanguage>: Sendable, Hashable {
    private let syntax: SyntaxNodeHandle<Lang>
}
```

Protocol sketch:

```swift
public protocol TypedSyntaxKind {
    associatedtype Lang: SyntaxLanguage
    static var rawKind: RawSyntaxKind { get }
}
```

Construction should validate kind:

```swift
extension FunctionDeclCursor {
    public init?(_ node: consuming SyntaxNodeCursor<Lang>) {
        guard node.rawKind == Self.rawKind else { return nil }
        self.syntax = node
    }
}
```

Because consuming a cursor may be awkward for conditional wrappers, the implementation may prefer scoped APIs:

```swift
node.withTyped(FunctionDeclCursor.self) { function in
    // borrowed typed function cursor
}
```

Typed accessors should be generated or macro-generated, but the core library should not require code generation.

---

## 24. Serialization and persistence

Serialize green trees and token tables, not red trees.

Serialize:

- raw syntax kinds;
- green node/token structure;
- text lengths;
- canonical token text tables;
- static-text markers;
- optional structural hashes;
- format version and language ID.

Do not serialize:

- red arena;
- red child slots;
- node metadata;
- analysis caches;
- parse-session caches;
- borrowed cursors;
- node handles.
- runtime `TokenKey.rawValue` assignments.

On load:

1. reconstruct green storage;
2. reconstruct resolver tables with snapshot-local token keys;
3. create a new `SyntaxTreeStorage` with a fresh red arena;
4. realize root red node only.

---

## 25. Memory layout and performance requirements

### 25.1 Allocation targets

Hard targets:

- one allocation per uncached green node, preferably tail-allocated;
- no allocation for cached green nodes/tokens;
- no class allocation per red node;
- no class allocation per red child slot;
- no allocation for `kind`, `textLength`, `textRange`, or `rawKind`;
- no allocation for ordinary child traversal;
- no `String` allocation unless `makeString()` is called.

### 25.2 ARC targets

Hard targets:

- borrowed cursor traversal should not retain/release tree storage per node;
- iterators/visitors should borrow once per traversal scope;
- copyable handles should retain the tree once and make the cost explicit;
- red records should not be independently reference counted.

### 25.3 Offset lookup

`token(at:)` should descend using child text lengths.

For wide nodes, consider lazily built offset tables:

```swift
struct ChildOffsetTable {
    let childStarts: UnsafeBufferPointer<TextSize>
}
```

Build such tables only when child count exceeds a threshold or repeated point lookups justify them.

### 25.4 Cache memory policy

Every cache should have a budget:

- maximum bytes;
- maximum entries;
- optional per-kind thresholds;
- eviction strategy;
- instrumentation counters.

Caches must never be globally unbounded.

### 25.5 Benchmark targets

Create benchmark suites for:

- parse/build throughput;
- full-tree traversal;
- visible-range token iteration;
- `token(at:)` repeated lookup;
- incremental reparse with small edit;
- green sharing ratio;
- memory footprint per source byte;
- ARC retain/release counts where measurable;
- concurrent traversal under contention;
- red realization cold vs warm traversal.

---

## 26. API examples

### 26.1 Parse and traverse

```swift
var cache = GreenNodeCache<MyLang>(policy: .parseSession(maxBytes: 64 * 1024 * 1024))
var builder = GreenTreeBuilder<MyLang>(cache: consume cache)

parser.parse(into: &builder)

let result = builder.finish()
var tree = result.intoSyntaxTree()

tree.withRoot { root in
    root.visitPreorder { node in
        if node.kind == .identifier {
            // No node handle allocation, no array allocation.
        }
        return .continue
    }
}
```

### 26.2 Publish to SwiftUI

```swift
let sharedTree = tree.intoShared()
let snapshot = ParsedSnapshot(
    version: version,
    text: textSnapshot,
    tree: sharedTree,
    diagnostics: diagnostics
)

await MainActor.run {
    model.snapshot = snapshot
}
```

### 26.3 Highlight visible range

```swift
snapshot.tree.withRoot { root in
    root.tokens(in: visibleRange) { token in
        token.withTextUTF8 { bytes in
            highlighter.emit(kind: token.kind, range: token.textRange, bytes: bytes)
        }
    }
}
```

### 26.4 Store a diagnostic reference

```swift
snapshot.tree.withRoot { root in
    root.withCoveringElement(errorRange) { element in
        switch element {
        case .node(let node):
            diagnostics.append(Diagnostic(range: node.textRange, message: message))
        case .token(let token):
            diagnostics.append(Diagnostic(range: token.textRange, message: message))
        }
    }
}
```

### 26.5 Intentionally keep a node handle

```swift
let handle: SyntaxNodeHandle<MyLang> = snapshot.tree.withRoot { root in
    root.withChildNode(at: 0) { child in
        child.makeHandle() // explicit retain of tree storage
    }!
}

handle.withCursor { node in
    debugPrint(node.rawKind)
}
```

---

## 27. Implementation phases

### Phase 1: Core value model and text primitives

Deliver:

- `RawSyntaxKind`;
- `TextSize` / `TextRange`;
- `SyntaxLanguage`;
- token text model;
- local interner/resolver;
- basic green node/token types.

Exit criteria:

- roundtrip token text tests;
- UTF-8 offset tests;
- overflow tests.

### Phase 2: Green builder and cache

Deliver:

- noncopyable `GreenTreeBuilder`;
- checkpoints;
- static/dynamic/missing tokens;
- green structural hashing;
- node/token cache;
- roundtrip text rendering.

Exit criteria:

- builder balance tests;
- cache deduplication tests;
- hash collision tests;
- memory budget tests.

### Phase 3: Borrowed red tree

Deliver:

- `SyntaxTree` move-only owner;
- `SharedSyntaxTree` explicit handle;
- red arena;
- lazy persistent red realization;
- borrowed node/token cursors;
- traversal APIs;
- explicit node/token handles.

Exit criteria:

- no array allocation in primary traversal;
- old-handle persistence tests;
- cold/warm traversal benchmarks;
- Thread Sanitizer concurrent traversal tests.

### Phase 4: Replacement and witnesses

Deliver:

- green replacement;
- tree replacement;
- `ReplacementWitness` returned from `replacing(handle:...)`;
- text edit integration.

Exit criteria:

- ancestor-path-only replacement tests;
- old tree remains valid;
- witness `classify(path:)` returns the right outcome for preservation, ancestor, replacedRoot, and deletion paths.

### Phase 5: Incremental support

Deliver:

- parse session;
- reuse oracle;
- range mapping;
- parser-facing reuse APIs;
- cache reuse across parse versions.

Exit criteria:

- small-edit incremental benchmark;
- green sharing ratio metrics;
- visible-range highlighter benchmark.

### Phase 6: Typed overlay and convenience module

Deliver:

- typed cursor/handle wrapper pattern;
- optional macro/codegen helpers;
- copyable convenience traversal module;
- debug renderers.

Exit criteria:

- typed overlay does not duplicate storage;
- convenience APIs documented as allocation/retain-producing;
- debug tools do not pollute core API.

---

## 28. Testing strategy

Required test categories:

1. **Roundtrip tests**: tree text equals input byte-for-byte.
2. **Builder balance tests**: malformed start/finish sequences fail clearly.
3. **Checkpoint tests**: nested checkpoints, rollback, retroactive wrapping.
4. **Green sharing tests**: identical subtrees share storage when cache is reused.
5. **Hash collision tests**: forced collisions do not cause incorrect deduplication.
6. **Replacement tests**: only ancestor path changes; old tree remains valid.
7. **Borrowing API tests**: cursors do not escape; handles require explicit creation.
8. **Concurrent traversal tests**: many tasks traverse one shared tree and force red realization races.
9. **Thread Sanitizer suite**: child slot publication, shared caches, interners, metadata.
10. **Unicode tests**: UTF-8 offsets, invalid/malformed parser input if applicable, grapheme-boundary conversion helpers.
11. **Huge-file tests**: wide nodes, deep nodes, large tokens, cache pressure.
12. **ARC/performance tests**: compare borrowed traversal vs handle traversal.
13. **SwiftUI snapshot tests**: publish shared snapshots, traverse on main/background tasks.

---

## 29. Engineering rules and anti-patterns

### 29.1 Do this

- Use borrowed cursors for traversal.
- Use `with...` APIs to create scoped borrows.
- Use `makeHandle()` only when a node/token must outlive the borrow scope.
- Drive an external identity tracker with witnesses for cross-version reference translation.
- Use `SyntaxText.writeUTF8` for text rendering.
- Keep builder/cache/interner state noncopyable.
- Keep red records arena-owned.
- Keep atomics isolated and documented.
- Benchmark before adding ergonomic APIs to core.

### 29.2 Do not do this

- Do not expose copyable `SyntaxNode` as the default traversal type.
- Do not return `[SyntaxNodeHandle]` from core child traversal.
- Do not make syntax navigation `async`.
- Do not put actors inside red or green nodes.
- Do not store token text as `String` by default.
- Do not use `ManagedAtomic` per child slot.
- Do not store parent/child red links as strong references.
- Do not rely on structural hash without equality checks.
- Do not mutate trees in place.
- Do not use node handles as cross-version identity.

---

## 30. Known tradeoffs vs Rust `cstree`

Even with a borrowing-first Swift architecture, Swift will not provide all of Rust’s static guarantees.

Expected limitations:

- Swift lifetimes are less expressive than Rust lifetimes.
- Some internal storage will require `@unchecked Sendable`.
- Low-level synchronization relies on audited atomics/locks.
- Noncopyable generic support may impose toolchain constraints.
- Borrowed cursors may be less ergonomic than Rust references.
- Some fast APIs will require closure scopes or mutating cursor navigation.
- The convenience layer will be slower than the core borrowed layer.

Expected compensating strengths:

- Swift-native API works naturally with SwiftUI boundaries when sharing is explicit.
- Noncopyable public types prevent accidental copies in core workflows.
- Borrowed cursor traversal can avoid most per-node ARC overhead.
- Explicit handles make ownership visible to users.
- The architecture remains parser-neutral and language-generic.

---

## 31. Open implementation questions

These should be resolved early by prototyping and benchmarking:

1. **Exact toolchain requirement**: decide minimum Swift/Xcode version and whether experimental noncopyable generics are acceptable.
2. **Cursor representation**: choose between unowned references, unsafe pointers, or compact storage IDs inside borrow scopes.
3. **Green storage strategy**: class-per-green-node with tail allocation vs `GreenStore` ID arena.
4. **Red child-slot strategy**: striped lock + `UnsafeAtomic` slots vs compare-exchange-only allocation path.
5. **Offset table threshold**: when to build child offset tables for wide nodes.
6. **Interner policy**: all dynamic tokens interned vs large-token escape hatch.
7. **Shared cache policy**: per-document, per-session, or global bounded cache.
8. **Typed overlay generation**: Swift macros, build plugin, or manual wrappers.
9. **Convenience API module boundary**: how strongly to separate copyable traversal from core.
10. **Metadata strategy**: node-local sidecar cache vs external analysis tables.

---

## 32. Recommended final shape

The recommended architecture is:

```text
Move-only SyntaxTree
    owns SyntaxTreeStorage
    ↓ explicit share/consume
Copyable SharedSyntaxTree
    retains SyntaxTreeStorage
    ↓ scoped borrow
Noncopyable SyntaxNodeCursor / SyntaxTokenCursor
    primary traversal path
    no implicit storage retain
    ↓ explicit makeHandle
Copyable SyntaxNodeHandle / SyntaxTokenHandle
    long-lived same-tree references
    ↓ edit / incremental reparse
ReplacementWitness / ParseWitness
    pure structural change descriptions
    consumed by external identity trackers
```

Green tree construction is likewise ownership-aware:

```text
Move-only GreenNodeCache
    ↓ consumed by
Move-only GreenTreeBuilder
    ↓ consuming finish
GreenBuildResult
    ↓ consuming intoSyntaxTree
Move-only SyntaxTree
```

This makes the performant usage path the natural usage path. Users can still opt into copyable handles and convenience traversal, but they must do so explicitly.

---

## 33. Summary for implementers

Build a Swift CST library that is not merely “Rust `cstree` but in Swift.” Preserve the proven red/green semantics, but adapt the API around Swift ownership:

- **Borrowed cursors are the core user-facing node/token API.**
- **Copyable handles are explicit.**
- **Builders and caches are noncopyable.**
- **Trees are immutable snapshots.**
- **Red nodes are lazy, persistent, arena-owned, and thread-safe.**
- **Green nodes are immutable, shared, and cache-deduplicated.**
- **Text is UTF-8-offset-based and streamed by default.**
- **SwiftUI sees shared snapshots, not mutable trees or escaping cursors.**

The implementation should be benchmark-driven from the beginning. The core API should make accidental slow paths difficult to write, even if that means the API is less ergonomic than a conventional Swift collection-style interface.
