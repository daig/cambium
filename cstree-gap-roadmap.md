# cstree Gap Roadmap

This document tracks the remaining practical gaps between Cambium and Rust
`cstree`. It is future-oriented: the baseline below describes what Cambium can
already rely on, and the roadmap tracks work still worth doing.

The goal is not strict API cloning. Cambium should keep its Swift-native design:
borrowed cursors for hot traversal, explicit copyable handles for ownership,
parser-neutral infrastructure, and immutable trees updated through replacement.

## Current Baseline

- Homogeneous CST tagged by `RawSyntaxKind`, with language-specific
  `SyntaxLanguage` policy and macro-derived `SyntaxKind` support.
- Green nodes and tokens with structural hashes, byte lengths, static tokens,
  missing tokens, dynamic-token validation, and local/shared token interning.
- Green tree builder with checkpoints, retroactive wrapping, cache-preserving
  `finish()`, namespace-aware subtree reuse, and bounded FIFO green caches.
- Lazy persistent red arena with shared syntax tree storage, stable red records,
  and lock-free reads for realized children.
- Borrowed node/token cursors and copyable node/token handles.
- Borrowed traversal for first/last child helpers, node/token siblings,
  ancestors, descendants, preorder walk events, visible-range token walks, and
  callback-based `withTokenAtOffset(_:none:single:between:)`.
- Byte-first `SyntaxText` chunk iteration, search, slicing, streaming write, and
  equality without full string materialization.
- Witness-based cross-version change descriptions for replacement and
  incremental parse reuse.
- Node replacement by rebuilding the ancestor path, including root replacement.
- Green snapshot serialization and decoding.
- Sidecar metadata and external analysis cache helpers.
- Incremental parse session primitives: text edits, range mapping, reuse oracle,
  accepted-reuse logging, cache/interner carry-forward, and reuse diagnostics.

## Priority 1: Token Streams And Editing

Cambium has token lookup and in-subtree token enumeration. The next token-level
slice should focus on formatter/editor workflows that need stream navigation and
small replacements.

Planned work:

1. Add `staticText` convenience on token cursors and handles.
2. Add safe token text-key exposure where interned identity is useful.
3. Add cheap token text equality helpers.
4. Add previous/next token traversal across subtree boundaries.
5. Add token replacement by rebuilding the ancestor path.
6. Add element replacement for callers operating on `SyntaxElementCursor`.
7. Revisit a value-typed `TokenAtOffset` enum once Swift can reliably
   pattern-match multi-payload `~Copyable` enum cases.

Acceptance criteria:

- Formatters can walk token streams without repeatedly descending from root.
- Lexer-style incremental passes can replace a token or token span directly.
- Replacement preserves resolver correctness for interned and large token text.

## Priority 2: Incremental Parsing Maturity

The incremental module is grammar-neutral and already has useful reuse pieces.
It still needs parser-facing examples, stronger matching, and measured behavior
under real parse loops.

Planned work:

1. Add green-hash matching to `ReuseOracle` when parser integration exposes a
   concrete need beyond offset, kind, and edit-overlap checks.
2. Add examples showing a hand-written parser using the reuse oracle and
   accepted-reuse log.
3. Add small-edit benchmarks comparing full parse and incremental reuse.
4. Clarify cache/interner carry-forward patterns for parser integrations.

Acceptance criteria:

- A parser can ask whether a previous subtree at an offset is reusable without
  knowing Cambium's red arena internals.
- Reuse never returns a subtree overlapping invalidated text.
- Cache/interner reuse across parse versions is explicit and measurable.

## Priority 3: Interner And Cache Policy

Cambium has local/shared interning and bounded green caches. Cache policy and
interner customization should mature from measured parser needs.

Planned work:

1. Add clearer APIs for supplying existing interner/resolver state to builders.
2. Decide whether third-party/custom interners need protocol-based integration.
3. Track estimated bytes for cached nodes, tokens, and interned strings.
4. Decide whether configurable or per-kind node cache thresholds are needed.
5. Add cache statistics suitable for parser diagnostics and benchmarks.
6. Stress test shared cache and shared interner concurrency.

Acceptance criteria:

- Parse sessions can carry interner/cache state across builder instances.
- Cache budgets are predictable under large files.
- Shared cache and interner behavior is covered by concurrency tests.

## Priority 4: Metadata And Analysis Lifecycle

cstree supports custom data attached to red nodes. Cambium uses sidecar metadata
and external analysis caches instead, which fits Swift better, but the lifecycle
and ergonomics need tightening.

Planned work:

1. Add `remove` and `clear` operations to `SyntaxMetadataStore`.
2. Add `trySet` semantics for "set only if absent".
3. Decide whether node-handle convenience methods should wrap sidecar stores.
4. Document metadata lifetime relative to `TreeID`.
5. Add pruning helpers keyed by tree identity and by external witness-driven
   identity trackers.
6. Decide whether any metadata should participate in serialization.

Acceptance criteria:

- Callers can maintain memoized syntax facts without unbounded growth.
- Metadata invalidation is explicit after tree replacement or reparsing.
- The distinction between node-local facts and semantic caches is documented.

## Priority 5: Typed AST Overlay Tooling

cstree intentionally leaves language-specific typed ASTs above the generic CST
runtime. Cambium should provide enough patterns for language packages without
moving language-specific concepts into the core.

Planned work:

1. Add typed cursor and typed handle wrapper examples.
2. Add child accessor patterns that preserve borrowed traversal.
3. Add optional generated wrapper support from a grammar or schema.
4. Add visitor and query helper patterns outside `CambiumCore`.
5. Decide how trivia-skipping accessors should be expressed.

Acceptance criteria:

- Language packages can build ergonomic typed overlays without duplicating tree
  storage.
- Typed accessors do not force handle allocation in hot traversal paths.
- Generated wrappers remain optional and separate from the core CST runtime.

## Priority 6: Debugging, Display, And Documentation

Cambium has test-only debug helpers but limited public display/debugging support
and no getting-started path for new users.

Planned work:

1. Add public debug tree rendering with raw kind, language name, ranges, and text
   options.
2. Add display helpers for subtree text and tokens, including streaming render
   conveniences that do not require `makeString()`.
3. Add a getting-started guide that mirrors the cstree flow: define kinds,
   build a green tree, obtain a red tree, traverse it.
4. Add a parser example with static, dynamic, and missing tokens.
5. Add an incremental parsing example once the reuse APIs mature.

Acceptance criteria:

- New users can build and inspect a tiny language without reading tests.
- Debug output is stable enough for snapshot tests.
- Examples show both macro-derived and manually implemented syntax kinds.

## Priority 7: Serialization Policy

Cambium has custom green snapshot serialization. cstree offers optional serde
support. Cambium should define the surrounding policy before broad use.

Planned work:

1. Document the current snapshot format and compatibility expectations.
2. Decide whether red tree identity, witness history, metadata, or diagnostics
   should be serializable.
3. Add explicit version migration policy.
4. Add fuzz or malformed-input tests for decoder robustness.
5. Revisit cache-aware decoding for load-then-edit workflows if real
   parser/editor integrations show first-edit `.remapped` latency.

Acceptance criteria:

- Snapshot files have a documented stability contract.
- Decoder failure modes are tested for malformed input.
- Serialization stays green-tree-centric unless there is a concrete need to
  persist higher layers.

## Priority 8: Concurrency And Performance Proof

Cambium's design depends on safe concurrent traversal and predictable allocation
behavior. Several types use `@unchecked Sendable`, so tests and benchmarks need
to carry more of the proof burden.

Planned work:

1. Add broader concurrent traversal stress tests beyond red child realization.
2. Add Thread Sanitizer test runs in CI or documented local commands.
3. Benchmark cold and warm red traversal, including cold realization contention.
4. Benchmark builder/cache behavior on large and repeated subtrees.
5. Benchmark incremental reparse with small edits.
6. Add huge-file tests for offset overflow boundaries, wide nodes, deep nodes,
   and large tokens.
7. Add allocation-count or ARC-sensitive benchmarks for borrowed cursors versus
   handle-heavy traversal.
8. Benchmark whether wide-node child offset tables or green arena storage are
   worth their implementation complexity.

Acceptance criteria:

- Lazy red realization is validated under contention.
- Cache and interner policies can be tuned from measured data.
- Borrowed traversal remains visibly cheaper than owned-handle traversal.

## Priority 9: API Polish

Several cstree conveniences are useful but not MVP-critical. Add them only when
they simplify real callers or examples.

Planned work:

1. Add lazy or breakable sibling/child-range iteration patterns, including
   `children_from` and `children_to` equivalents if needed.
2. Add richer `SyntaxElementCursor` helpers such as node/token projections.
3. Add `WalkEvent.map`-style conveniences if they reduce boilerplate.
4. Decide whether Unicode scalar, `Character`, or grapheme-cluster operations
   belong on `SyntaxText` or in a higher-level utility.
5. Consider handle-based convenience mirrors in `CambiumOwnedTraversal` where
   allocation and ownership costs are explicit.

Acceptance criteria:

- Convenience APIs remove real call-site friction.
- Borrowed traversal remains the primary zero-retain path.
- Unicode behavior stays explicit and byte offsets remain the core contract.

## Work Queue

Suggested next slices:

1. Token stream navigation across subtree boundaries.
2. Token and element replacement.
3. Incremental reuse oracle green-hash matching or parser example.
4. Debug tree rendering API and getting-started guide.
5. Metadata lifecycle helpers.
6. Shared cache/interner stress tests and TSan documentation.

Each slice should include focused tests and avoid changing parser-neutral core
contracts unless the new API has a clear downstream use case.
