# Externalized Interning

Plug an external token-text store into Cambium via the
``CambiumCore/TokenInterner`` protocol.

## Overview

Cambium's green-node cache and token interner are independent components.
A ``CambiumBuilder/GreenTreeContext`` bundles them as a namespace-bound
unit, but only the **interner** is intended to be externalized: it
controls token-text vocabulary, namespace identity, and the resolver
attached to every finished tree. The cache stays internal-but-tunable
via ``CambiumBuilder/GreenCachePolicy``.

The protocol shape:

```swift
public protocol TokenInterner: AnyObject {
    var namespace: TokenKeyNamespace { get }
    func intern(_ bytes: UnsafeBufferPointer<UInt8>) throws -> TokenKey
    func storeLargeText(_ text: String) -> LargeTokenTextID
    func makeResolver() -> any TokenResolver
}
```

`TokenInterner` deliberately does **not** refine ``CambiumCore/TokenResolver``.
Inheritance would force every conformer to be `Sendable`, which would
silently expose single-owner mutable stores as if they were thread-safe.
By keeping the protocols disjoint:

- ``CambiumBuilder/LocalTokenInterner`` is `TokenInterner` only — its
  ``CambiumBuilder/LocalTokenInterner/makeResolver()`` returns a frozen
  ``CambiumCore/TokenTextSnapshot``, and the interner itself cannot be
  passed where a resolver is expected.
- ``CambiumBuilder/SharedTokenInterner`` conforms to both protocols
  separately because it really is thread-safe; its `makeResolver()`
  returns `self` (a live resolver).
- A custom backend (e.g., a query-store-backed interner) opts into
  whichever protocols its semantics actually support.

## Two built-in backends

For most builds, ``CambiumBuilder/GreenTreeContext/init(policy:)`` is
sufficient — it mints a fresh ``CambiumBuilder/LocalTokenInterner``
internally. Reach for the externalized API when you have one of these
needs:

**Parallel parsing.** N workers each parse an independent subtree of one
logical CST. Without a shared interner, every worker mints its own
``CambiumCore/TokenKey``s, and merging via
``CambiumBuilder/GreenTreeBuilder/reuseSubtree(_:)`` falls into
``CambiumBuilder/SubtreeReuseOutcome/remapped`` — re-interning every
dynamic token. With a shared ``CambiumBuilder/SharedTokenInterner``,
every reuse takes the ``CambiumBuilder/SubtreeReuseOutcome/direct``
fast path:

```swift
let interner = SharedTokenInterner()

await withThrowingTaskGroup(of: SyntaxTree<MyLang>.self) { group in
    for source in inputs {
        group.addTask {
            let context = GreenTreeContext<MyLang>(
                interner: interner,
                policy: .documentLocal
            )
            let builder = GreenTreeBuilder<MyLang>(context: consume context)
            // ... drive parsing ...
            return try parser.finish().tree
        }
    }
    // Splice each worker tree into a master builder also bound to
    // `interner` — `reuseSubtree` returns `.direct` every time.
}
```

The Calculator example's ``parseCalculatorExpressionsInParallel(_:interner:)``
demonstrates the full pattern end-to-end.

**Long-lived editor sessions.** A single ``CambiumBuilder/SharedTokenInterner``
shared across every reparse means token vocabulary survives indefinitely;
every ``CambiumBuilder/GreenTreeContext`` minted from
``CambiumBuilder/GreenBuildResult/intoContext()`` keeps the same
namespace, so cross-edit identity-preserving subtree reuse keeps working
across the entire session.

## Backing an interner with a query store

The protocol is small enough to wrap an arbitrary external store. The
pattern is:

1. Define a class that conforms to ``CambiumCore/TokenInterner``.
2. Mint a single ``CambiumCore/TokenKeyNamespace`` instance per backing
   store; expose it via the `namespace` property. The key namespace is
   tied to the **store** identity, not the wrapper instance — multiple
   wrapper instances against the same store should expose the same
   namespace, and a wrapper around a different store gets a different
   namespace.
3. Implement `intern(_ bytes:)` and `storeLargeText(_:)` by delegating
   to the store. Internal id formats (`UInt32` indices, hashed handles,
   GUIDs converted to a `UInt32` via your own scheme) all work as long
   as round-tripping is stable.
4. Pick `makeResolver()`'s policy:
   - For a thread-safe live store, also conform to ``CambiumCore/TokenResolver``
     and return `self` — finished trees see the live store.
   - For a snapshot-only model, return a frozen
     ``CambiumCore/TokenTextSnapshot`` capturing only the keys this
     tree's `finish()` referenced, so the tree is decoupled from
     subsequent store mutations.

Sketch:

```swift
public final class DatabaseTokenInterner<DB: SomeQueryDatabase>:
    TokenInterner, TokenResolver, @unchecked Sendable
{
    public let namespace: TokenKeyNamespace
    public var tokenKeyNamespace: TokenKeyNamespace? { namespace }

    private let db: DB

    public init(_ db: DB, namespace: TokenKeyNamespace) {
        self.db = db
        self.namespace = namespace
    }

    public func intern(_ bytes: UnsafeBufferPointer<UInt8>) throws -> TokenKey {
        // Forward to the store; convert its returned id to TokenKey.
        try db.intern(bytes)
    }

    public func storeLargeText(_ text: String) -> LargeTokenTextID {
        db.storeLargeText(text)
    }

    public func resolve(_ key: TokenKey) -> String {
        db.text(for: key)
    }

    public func withUTF8<R>(
        _ key: TokenKey,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        try db.withTextUTF8(key, body)
    }

    public func makeResolver() -> any TokenResolver { self }
}
```

This is the same shape Rust's [`cstree`](https://github.com/domenicquirl/cstree)
uses to plug in
[`salsa`](https://github.com/salsa-rs/salsa) as a backing store: `cstree`
defines an `Interner` trait, salsa users wrap their database to satisfy
it. Cambium's protocol is the Swift translation; the integration is
purely conceptual (no direct dependency).

## Namespace correctness

``CambiumBuilder/GreenNodeCache`` keys node storage by raw
``CambiumCore/TokenKey`` values. **Mixing a cache populated under one
interner's namespace with another interner silently corrupts text
resolution and defeats green-node identity** as the "same subtree"
signal. ``CambiumBuilder/GreenTreeContext`` makes the pairing structural:

- The public ``CambiumBuilder/GreenTreeContext/init(interner:policy:)``
  always pairs an interner with a fresh cache.
- The convenience ``CambiumBuilder/GreenTreeContext/init(policy:)``
  mints both halves together.
- The only way to forward state across builds is
  ``CambiumBuilder/GreenBuildResult/intoContext()``, which carries the
  prior context's `(interner, cache)` pair as a unit.

There is no public path to construct a context from a freely-chosen
`(interner, cache)` pair — that would reintroduce the silent corruption
hazard.

## Topics

### Protocol

- ``CambiumCore/TokenInterner``
- ``CambiumCore/TokenResolver``
- ``CambiumCore/TokenKeyNamespace``

### Built-in backends

- ``CambiumBuilder/LocalTokenInterner``
- ``CambiumBuilder/SharedTokenInterner``

### Context

- ``CambiumBuilder/GreenTreeContext``
- ``CambiumBuilder/GreenBuildResult``
- ``CambiumBuilder/GreenTreeBuilder``
