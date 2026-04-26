# cstree Gap Roadmap

This document tracks the remaining practical gaps between Cambium and Rust
`cstree`, with an emphasis on work that can be completed incrementally. Cambium
already has the core runtime shape: syntax kinds, green nodes/tokens, a builder,
interned token text, lazy red storage, shared tree handles, replacement,
serialization, metadata sidecars, and derive-like syntax-kind macros.

The goal is not strict API cloning. Cambium should keep its Swift-native design:
borrowed cursors for hot traversal, explicit copyable handles for ownership,
parser-neutral infrastructure, and immutable trees updated through replacement.

## Current Coverage

- Homogeneous CST tagged by `RawSyntaxKind`.
- Language-specific `SyntaxLanguage` policy and derived `SyntaxKind` support.
- Green nodes and tokens with structural hashes and text lengths.
- Local token interning and immutable `TokenTextSnapshot` values for finished trees.
- Green tree builder with checkpoints, retroactive wrapping, static tokens, and
  cache-preserving `finish()`.
- Green node/token cache with local and shared cache entry points.
- Lazy persistent red arena with shared syntax tree storage, stable red records,
  and lock-free reads for realized children.
- Borrowed node/token cursors and copyable node/token handles.
- Borrowed core traversal for first/last children, node/token siblings,
  ancestors, descendants, and preorder walk events.
- Byte-first `SyntaxText` chunk iteration, search, slicing, and equality.
- Witness-based cross-version change descriptions for replacement and
  incremental parse reuse.
- Node replacement by rebuilding the ancestor path.
- Green snapshot serialization and decoding.
- Basic sidecar metadata and external analysis cache helpers.
- Skeletal incremental parse session, text edits, range mapping, reuse oracle,
  and accepted-reuse logging.

## Priority 1: Traversal API Completeness

cstree exposes a rich red tree navigation surface: ancestors, siblings,
first/last child, first/last token, descendants, preorder walk events, and
node/token-inclusive variants. Cambium has the core cursor primitives, but the
public traversal layer is still sparse.

Status: the borrowed `CambiumCore` traversal slice is complete. The core now
has node-only and token-aware child helpers, sibling traversal, ancestor
traversal, descendant traversal, and preorder enter/leave walk events without
array materialization or implicit owned-handle creation.

Completed work:

1. Added borrowed cursor helpers for first/last child node and first/last child or
   token.
2. Added sibling traversal that can include tokens, not only node siblings.
3. Added ancestor traversal for node cursors and token cursors.
4. Added descendant traversal with node-only and node-or-token variants.
5. Added preorder walk events with enter/exit events, including token-aware
   traversal.

Remaining follow-up:

1. Mirror selected helpers on copyable handles in `CambiumOwnedTraversal` where
   allocation/ownership cost is explicit and a concrete caller needs it.
2. Keep first/last token stream helpers with previous/next token traversal under
   Priority 3, since those cross subtree boundaries rather than only walking raw
   child positions.

Acceptance criteria:

- Common editor queries can now be expressed without materializing arrays in
  `CambiumCore`.
- Token-inclusive traversal no longer requires clients to manually recompute child
  offsets.
- Borrowed traversal remains the primary zero-retain path.

## Priority 2: Richer `SyntaxText`

cstree's `SyntaxText` supports efficient operations over distributed token text
without eagerly building a `String`. Cambium's `SyntaxText` currently supports
UTF-8 writing, byte length, and string materialization.

Status: the byte-first `SyntaxText` slice is complete. `SyntaxText` now supports
range-aware chunk iteration, byte search, byte-range slicing, and streaming
equality against strings and other syntax text values without requiring full
string materialization.

Completed work:

1. Added `isEmpty`.
2. Added chunk iteration over token UTF-8 buffers.
3. Added byte-oriented `contains` helpers.
4. Added byte-oriented `firstIndex` and `firstRange` search helpers.
5. Added slicing by relative `TextRange`.
6. Added efficient equality against strings and other `SyntaxText` values.

Remaining follow-up:

1. Decide whether Unicode `Character` or grapheme-cluster operations belong in
   `SyntaxText` or in a higher-level utility.
2. Add more specialized search APIs only when a concrete parser, formatter, or
   query caller needs them.

Acceptance criteria:

- Formatters, lexers, and query code can now inspect subtree text without allocating
  the full string.
- Slicing preserves byte-offset semantics and validates range bounds.
- Unicode behavior remains explicit: this completed slice is UTF-8 byte oriented.

## Priority 3: Token-Level Navigation And Replacement

Cambium can find and read tokens, but lacks several token-centric operations that
are central for incremental lexing, selections, and formatting.

Incremental work:

1. Add `staticText` convenience on token cursors and handles.
2. Add `TokenAtOffset` with `none`, `single`, and `between` cases so exact
   token-boundary queries are unambiguous.
3. Validate or reject static-token kinds passed through dynamic
   `builder.token(_:text:)` APIs.
4. Add token text-key exposure where it is safe to expose interned identity.
5. Add cheap token text equality helpers.
6. Add previous/next token traversal across subtree boundaries.
7. Add token replacement by rebuilding the ancestor path.
8. Add element replacement for callers that operate on `SyntaxElementCursor`.

Acceptance criteria:

- A formatter can walk token streams without repeatedly descending from root.
- A lexer-style incremental pass can replace a token or token span directly.
- Replacement preserves resolver correctness for interned and large token text.

## Priority 4: Incremental Parsing Session Maturity

The current incremental module has useful pieces, but it is not yet a complete
parser-facing reuse system. The library should remain grammar-neutral while
providing strong building blocks for language parsers.

Incremental work:

1. Define invalidation region computation for one or more text edits.
2. Extend `ReuseOracle` to check range, kind, green hash, and edit overlap.
3. Track reused bytes accurately.
4. Add APIs to reuse green subtrees directly in `GreenTreeBuilder`.
5. Add parse-session ownership for shared caches, interner policy, and counters.
6. Add examples showing a hand-written parser using the reuse oracle.
7. Add small-edit benchmarks comparing full parse and incremental reuse.

Acceptance criteria:

- A parser can ask whether a previous subtree at an offset is reusable without
  knowing Cambium's red arena internals.
- Reuse never returns a subtree overlapping invalidated text.
- Cache/interner reuse across parse versions is explicit and measurable.

## Priority 5: Interner And Cache Maturity

Cambium has local and shared interning plus green caches. The green cache is
now bounded by entry count, uses deterministic FIFO eviction, caches all tokens
when enabled, and applies cstree's default small-node threshold of at most
three children. Cache policy and interner pluggability are still early.

Incremental work:

1. Add clearer APIs for supplying an existing interner/resolver to builders.
2. Decide whether third-party/custom interners need protocol-based integration.
3. Track estimated bytes for cached nodes, tokens, and interned strings.
4. Decide whether configurable or per-kind node cache thresholds are needed.
5. Add richer cache statistics suitable for parser diagnostics and benchmarks.
6. Stress test shared cache and shared interner concurrency.

Acceptance criteria:

- Parse sessions can carry interner/cache state across builder instances.
- Cache budgets are predictable under large files.
- Shared cache and interner behavior is covered by concurrency tests.

## Priority 6: Metadata And Analysis Lifecycle

cstree supports custom data attached to red nodes. Cambium currently provides
sidecar metadata and external analysis caches, which fits Swift better, but the
lifecycle and ergonomics need tightening.

Incremental work:

1. Add `remove` and `clear` operations to `SyntaxMetadataStore`.
2. Add `trySet` semantics for "set only if absent".
3. Decide whether node-handle convenience methods should wrap sidecar stores.
4. Document metadata lifetime relative to `TreeID`.
5. Add pruning helpers keyed by tree identity and by external witness-driven
   identity trackers.
6. Decide whether any metadata should participate in serialization.

Acceptance criteria:

- Callers can safely maintain memoized syntax facts without unbounded growth.
- Metadata invalidation is explicit after tree replacement or reparsing.
- The distinction between node-local facts and semantic caches is documented.

## Priority 7: Typed AST Overlay Tooling

cstree intentionally leaves language-specific typed ASTs above the generic CST
runtime. Cambium currently has only minimal typed-node validation.

Incremental work:

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

## Priority 8: Debugging, Display, And Documentation

Cambium has test-only debug helpers but limited public display/debugging support.

Incremental work:

1. Add public debug tree rendering with raw kind, language name, ranges, and text
   options.
2. Add display helpers for subtree text and tokens.
3. Add a getting-started guide that mirrors the cstree flow: define kinds,
   build a green tree, obtain a red tree, traverse it.
4. Add a parser example with static and dynamic tokens.
5. Add an incremental parsing example once the reuse APIs mature.

Acceptance criteria:

- New users can build and inspect a tiny language without reading tests.
- Debug output is stable enough for snapshot tests.
- Examples show both macro-derived and manually implemented syntax kinds.

## Priority 9: Serialization Parity Decisions

Cambium has custom green snapshot serialization. cstree offers optional serde
support. Cambium should decide how much of the surrounding tree state belongs in
serialization.

Incremental work:

1. Document the current snapshot format and compatibility expectations.
2. Decide whether red tree identity, witness history, metadata, or diagnostics
   should be serializable.
3. Add explicit version migration policy.
4. Add fuzz or malformed-input tests for decoder robustness.

Acceptance criteria:

- Snapshot files have a documented stability contract.
- Decoder failure modes are tested for malformed input.
- Serialization stays green-tree-centric unless there is a concrete need to
  persist higher layers.

## Priority 10: Concurrency And Performance Proof

Cambium's design depends on safe concurrent traversal and predictable allocation
behavior. Several types use `@unchecked Sendable`, so tests and benchmarks need
to carry more of the proof burden.

Status: the first red-arena correctness slice is complete. Realized red records
are now immutable arena-owned objects, cursor reads no longer acquire the arena
mutex, and concurrent lazy realization is covered by focused tests. Broader CI
sanitizer coverage and performance benchmarks remain open.

Incremental work:

1. Add broader concurrent traversal stress tests beyond red child realization.
2. Add Thread Sanitizer test runs in CI or documented local commands.
3. Benchmark cold and warm red traversal.
4. Benchmark builder/cache behavior on large and repeated subtrees.
5. Benchmark incremental reparse with small edits.
6. Add huge-file tests for offset overflow boundaries, wide nodes, deep nodes,
   and large tokens.
7. Add allocation-count or ARC-sensitive benchmarks for borrowed cursors versus
   handle-heavy traversal.

Acceptance criteria:

- Lazy red realization is validated under contention.
- Cache and interner policies can be tuned from measured data.
- Borrowed traversal remains visibly cheaper than owned-handle traversal.

## Work Queue

Suggested next slices:

1. Token stream navigation: previous/next token across subtree boundaries.
2. Token replacement.
3. Owned traversal conveniences for selected borrowed traversal helpers.
4. Incremental reuse oracle correctness upgrade.
5. Debug tree rendering API and getting-started example.
6. Broader concurrency stress tests for shared caches, interners, and traversal.

Each slice should include focused tests and avoid changing parser-neutral core
contracts unless the new API has a clear downstream use case.
