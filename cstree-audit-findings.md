# cstree Audit Findings

This document tracks correctness bugs and major performance concerns found by
manual audit that are not already covered by `cstree-gap-roadmap.md`.

The roadmap remains the place for planned feature gaps and maturation work.
This file is intentionally narrower: concrete bugs, invariant violations, and
performance risks that should be triaged before or shortly after v1.

## Validation Notes

- The following findings have been fixed and removed from this list:
  wrong-resolver replacement, snapshot-replacement identity collisions,
  zero-length tokens leaking outside their query range, invalid UTF-8
  breaking text-length invariants, `visitPreorder(.stop)` sibling
  traversal, inconsistent public `GreenToken` construction,
  `firstReusableNode` boundary search lacking early exit and coverage,
  and the snapshot decoder trapping on unknown raw kinds.
- The overlay-fallback replacement namespace issue has been reclassified from
  a correctness bug to intentional cache-lineage design debt. See the
  deferred section below.
- Remaining findings here are based on code inspection and traced behaviour
  rather than executed tests; treat them as high-confidence but unvalidated
  until tests land.

## Deferred Cache-Lineage Design Debt

### Overlay-Fallback Replacement Intentionally Severs Cache Namespace

**Status:** Intentional safe fallback; revisit when cache lineage is redesigned.

**Area:** `OverlayTokenResolver`, the cross-namespace overlay fallback in
`SharedSyntaxTree.replacing(_:with: ResolvedGreenNode, cache:)`

When neither the replacement nor the provided cache shares the target tree's
namespace, replacement falls back to an `OverlayTokenResolver`. The overlay
remaps replacement dynamic token keys into resolver-local synthetic raw keys
above the target tree's existing maxima, preserving structural sharing for
unchanged subtrees and avoiding cache pollution with synthetic identities.

The overlay intentionally reports `tokenKeyNamespace == nil`. Its synthetic
keys are stored in overlay dictionaries, not in the target cache/interner.
Exposing the target namespace would make `reuseSubtree` direct-reuse green
nodes whose token keys a later cache snapshot cannot resolve, which is
unsound. The safe consequence is that subsequent `reuseSubtree` calls from the
overlay-backed result tree take the `.remapped` path until a larger cache
lineage redesign provides a coherent resolver/cache pair.

Relevant code:

- `Sources/CambiumBuilder/GreenTreeBuilder.swift`
  - `OverlayTokenResolver.tokenKeyNamespace`
  - `SharedSyntaxTree.replacing(_:with: ResolvedGreenNode, cache:)` (overlay
    fallback branch at the bottom of the function)
  - `GreenTreeBuilder.reuseSubtree(_:)`

Why it matters:

- A long edit session that lands in the overlay fallback can lose fast-path
  reuse until replacement/build APIs provide a returned cache whose interner
  contains every dynamic key referenced by the result tree.
- Hard to diagnose without comparing `SubtreeReuseOutcome` rates across
  parses.

Deferred direction:

- Do not expose the target namespace from `OverlayTokenResolver` unless the
  matching cache/interner can resolve the overlay's synthetic keys.
- Revisit this as part of the broader cache-lineage redesign, likely by adding
  an API that returns a coherent result cache/interner alongside the tree.

## Priority 0: Correctness Bugs

### 1. Node-Cache Eviction Undercounts Hash-Bucket Entries

**Severity:** Medium-Low

**Area:** `GreenNodeCacheStorage`

`makeNode` stores hash-collision-bucket entries in
`nodeCache: [NodeCacheKey: [GreenNode]]`. `recordNodeInsertion` only enqueues a
queue entry when the bucket key was previously absent — a collision that
appends into an existing bucket bypasses the eviction queue. `trimIfNeeded`
then triggers on `tokenCache.count + nodeCache.count` (buckets, not entries)
and evicts via `nodeCache.removeValue(forKey:)`, which removes the *whole
bucket* but only consumes one queue slot.

Relevant code:

- `Sources/CambiumBuilder/GreenTreeBuilder.swift`
  - `GreenNodeCacheStorage.recordNodeInsertion(for:)`
  - `GreenNodeCacheStorage.trimIfNeeded()`
  - `GreenNodeCache.makeNode(kind:children:)`

Why it matters:

- The size metric is buckets, not entries: with hash collisions the cache can
  exceed `maxEntries`. Realistic input rarely produces degenerate buckets, but
  `maxEntries` is no longer the upper bound the docs imply.
- Eviction count under-reports the number of nodes actually freed.

Likely fix:

- Track total entries (sum of bucket sizes plus token-cache count) for the trim
  metric.
- Enqueue an eviction-queue entry on each append into a bucket, not just on
  bucket creation.

## Priority 1: Performance Risks

### 2. Green Cache Hits Still Allocate Candidate Nodes First

**Severity:** Major performance concern

**Area:** `GreenNodeCache.makeNode`

`makeNode` always constructs a candidate `GreenNode` before doing the cache
lookup. On a hit, that candidate is discarded. The code path also allocates
arrays when finishing nodes, wrapping checkpoints, and rebuilding replacement
ancestors.

Relevant code:

- `Sources/CambiumBuilder/GreenTreeBuilder.swift`
  - `GreenNodeCache.makeNode(kind:children:)`
  - `GreenTreeBuilder.finishNode()`
  - `GreenTreeBuilder.startNode(at:_:)`
  - `rebuildReplacing(root:path:replacement:cache:)`

Why it matters:

- Warm-cache parsing still performs a node allocation per would-be hit.
- Replacements inside wide nodes copy the whole child array at each ancestor.
- The current cache statistics can overstate allocation savings because hits
  still allocate candidates.

Likely fix:

- Compute the node cache key from child metadata before allocating storage.
- Compare candidates lazily against bucket entries without first creating a
  managed buffer.
- Consider specialized small-child storage or builder stack slices to avoid
  repeated `Array` creation on hot paths.

Measurement target:

- Benchmark repeated parse of small recurring subtrees with cache enabled and
  confirm allocation count drops on cache hits.
- Benchmark replacement in wide shallow nodes and deep narrow nodes.

### 3. String Materialization Decodes And Reallocates Per Chunk

**Severity:** Major performance concern

**Area:** `StringUTF8Sink`, `makeString()`

`StringUTF8Sink.write` decodes each UTF-8 chunk into a temporary `String` and
then concatenates it. Swift's `String += String` is amortized linear, so the
worst case is high-constant linear rather than strictly quadratic, but every
chunk pays a temporary-`String` allocation plus a copy into the result's
storage. For large token-heavy trees this dominates `makeString()`.

Relevant code:

- `Sources/CambiumCore/SyntaxText.swift`
  - `StringUTF8Sink.write(_:)`
  - `SyntaxText.makeString()`
- `Sources/CambiumCore/GreenElement.swift`
  - `GreenNode.makeString(using:)`

Why it matters:

- Debugging, serialization-adjacent checks, tests, and client display helpers
  commonly materialize subtree text.
- Token-heavy inputs are exactly the shape where chunk-by-chunk append is most
  expensive.

Likely fix:

- Add a byte-buffer sink that reserves `root.textLength` and appends raw UTF-8
  bytes, then decodes once.
- Keep streaming sinks for callers that do not want materialization.

Measurement target:

- Benchmark `makeString()` on many small tokens versus one large token with the
  same total byte count.
- Track allocations and wall time before/after a byte-buffer sink.

### 4. `withDescendant(atPath:)` Triggers O(childIndex) Per Step On First Realization

**Severity:** Performance concern (cold path)

**Area:** `SyntaxNodeCursor.withDescendant(atPath:)`, `RedArena.realizeChildNode`

`realizeChildNode` is called without `childStartOffset`, so it falls back to
`parent.green.childStartOffset(at: childIndex)`, which iterates `0..<childIndex`
summing `textLength`s. Other realization sites thread the cumulative offset
through, avoiding this. For a path of length D into a tree where each ancestor
has W children, first-time descent is O(D·W) instead of O(D).

`withDescendant(atPath:)` is the documented way to follow stored paths from
`childIndexPath()`, including cross-tree path translation through
`ReplacementWitness`.

Relevant code:

- `Sources/CambiumCore/SyntaxTree.swift`
  - `SyntaxNodeCursor.withDescendant(atPath:_:)`
  - `RedArena.realizeChildNode(parent:childIndex:childStartOffset:)`
- `Sources/CambiumCore/GreenElement.swift`
  - `GreenNode.childStartOffset(at:)`

Likely fix:

- Thread `childStart` through the loop in `withDescendant(atPath:)`, matching
  the pattern used by sibling and child traversal helpers.

### 5. Token Interners Allocate `[UInt8]` On Every Lookup

**Severity:** Major performance concern (hot path)

**Area:** `LocalTokenInterner.intern`, `SharedTokenInterner.intern`

Both interners build an owned `Array(bytes)` to probe the keys-by-text
dictionary on every call, including cache hits. For a parser pumping tens of
thousands of token texts (most of which dedupe), this is one Array-of-`UInt8`
per token.

Relevant code:

- `Sources/CambiumBuilder/GreenTreeBuilder.swift`
  - `LocalTokenInterner.intern(_:)`
  - `SharedTokenInterner.intern(_:)`

Likely fix:

- Probe the dictionary with a hashable wrapper around
  `UnsafeBufferPointer<UInt8>`, allocating an owned `[UInt8]` only on insert.
  (Foundation has no first-class API for this; needs a small helper that
  hashes the byte view directly.)

Measurement target:

- Allocation count per `intern` call drops on cache hits.
- Steady-state interning throughput improves on token-dense input.

### 6. `SharedTokenInterner.resolve` Locks The Shard On Every Read

**Severity:** Performance concern (concurrent reads)

**Area:** `SharedTokenInterner.resolve`, `SharedTokenInterner.withUTF8`

Both methods take the shard mutex per call. A formatter or analyzer iterating
every token in a file calls `withTextUTF8` once per dynamic token — under
shared interning, that's a mutex acquire per token per pass. Becomes a
contention point under concurrent traversal.

`textByKey` is append-only after insert: once a text is interned, its slot
never changes.

Relevant code:

- `Sources/CambiumBuilder/GreenTreeBuilder.swift`
  - `SharedTokenInterner.resolve(_:)`
  - `SharedTokenInterner.withUTF8(_:_:)`

Likely fix:

- Publish `textByKey` as an append-only snapshot reference (e.g. a frozen
  `Array` swapped in via a release-store on each insert) so reads can be
  lock-free.
- Alternatively, expose a borrowed snapshot resolver for read-heavy passes.

### 7. Slot Chunks Over-Provision For Token Children

**Severity:** Memory performance concern

**Area:** `RedArena.allocateSlots`, `AtomicSlotChunk`

`allocateSlots(count: childGreen.childCount, ...)` reserves one `Atomic<UInt>`
per child *including tokens*. The lookup short-circuits on tokens in
`realizeChildNode`, so token slots are never read or written. For a parent
with 5,000 token children and 1,000 node children, ~40 KB of `Atomic<UInt>`s
are allocated and zeroed but never used. Source code is inherently
token-dense, so this scales with file size.

Relevant code:

- `Sources/CambiumCore/SyntaxTree.swift`
  - `RedArena.allocateSlots(count:state:)`
  - `RedArena.realizeChildNode(parent:childIndex:childStartOffset:)`
  - `AtomicSlotChunk`

Likely fix:

- Allocate slots based on `nodeChildCount`, with a `child-index → slot-index`
  map computed from the green node (or precomputed and stored on
  `GreenNodeStorage` for wide nodes). Adds one indirection per realization,
  saves memory proportional to token density.

### 8. `GreenSnapshotEncoder.collect` Allocates Canonical Nodes Before Dedup Check

**Severity:** Performance concern (serialization path)

**Area:** `GreenSnapshotEncoder`

For each visited subtree, the encoder constructs a fresh
`canonicalNode = try GreenNode<Lang>(kind:, children:)` *before* checking the
`elementIDs` dedup map. Trees with heavy structural sharing (the snapshot's
whole point) discard most of these allocations on dedup hits.

Relevant code:

- `Sources/CambiumSerialization/GreenSnapshotSerialization.swift`
  - `GreenSnapshotEncoder.collect(node:resolver:)`
  - `GreenSnapshotEncoder.collect(token:resolver:)`

Likely fix:

- Dedup via a key on `(rawKind, [childIDs])` *before* allocating the canonical
  node.

### 9. `BinaryWriter.bytes` Doesn't Reserve Capacity

**Severity:** Minor performance concern

**Area:** `BinaryWriter`, snapshot encoding

`BinaryWriter` initializes `bytes: [UInt8] = []` and appends one, four, or
eight bytes per call. For a large snapshot, this triggers many array growths.
By the time the encoder starts writing, it knows `records.count`,
`internedTexts.count`, `largeTexts.count`, and the average record size — enough
to pick a usable initial capacity.

Relevant code:

- `Sources/CambiumSerialization/GreenSnapshotSerialization.swift`
  - `BinaryWriter`
  - `GreenSnapshotEncoder.encode(root:resolver:)`

Likely fix:

- Call `bytes.reserveCapacity(estimatedSize)` once before the body of `encode`,
  with an estimate based on the known record/string counts.

### 10. `RedArena.realizeChildNode` Slow Path Serializes On A Single Mutex

**Severity:** Performance concern (concurrent traversal)

**Area:** `RedArena`

The fast path is lock-free, but every cold realization across the whole tree
contends one `Mutex<State>`. Concurrent traversers triggering different
realizations all serialize. The roadmap calls out concurrent stress testing
but not lock granularity.

Relevant code:

- `Sources/CambiumCore/SyntaxTree.swift`
  - `RedArena.realizeChildNode(parent:childIndex:childStartOffset:)`
  - `RedArena.allocateSlots(count:state:)`

Likely fix candidates:

- Per-slot-chunk lock rather than whole-arena lock.
- Thread-local arena that periodically merges into shared state.
- Benchmark first to confirm contention before changing the model.

### 11. Recursive Traversal Risks Stack Overflow On Pathological Inputs

**Severity:** Robustness concern

**Area:** all DFS traversal in `SyntaxTree.swift`

`walkPreorder`, `walkPreorderWithTokens`, `forEachDescendant`,
`forEachDescendantOrToken`, `findTokenLocation`, and `withCoveringElement` are
all straight Swift recursion. For deeply nested input (chained binary
expressions, generated code) this can blow the stack on otherwise-valid trees.
cstree uses an explicit work stack for the equivalent walks.

Relevant code:

- `Sources/CambiumCore/SyntaxTree.swift`
  - `SyntaxNodeCursor.walkPreorder(_:)`
  - `SyntaxNodeCursor.walkPreorderWithTokens(_:)`
  - `SyntaxNodeCursor.forEachDescendant(includingSelf:_:)`
  - `SyntaxNodeCursor.forEachDescendantOrToken(includingSelf:_:)`
  - `SyntaxNodeCursor.findTokenLocation(at:)`
  - `SyntaxNodeCursor.withCoveringElement(_:_:)`

Likely fix:

- Convert public `walkPreorder*` and `forEach*Descendant*` paths to iterative
  work stacks. Internal helpers (`findTokenLocation`, `withCoveringElement`)
  are typically shallower but worth converting if the helpers move.

## Lower-Impact Issues Worth Noting

- `BuilderCheckpoint.startNode(at:)` doesn't enforce that no parents were
  opened or closed since the checkpoint
  (`Sources/CambiumBuilder/GreenTreeBuilder.swift:885-891`). Misuse silently
  produces a corrupted tree shape rather than throwing. Validate
  `parents.count == checkpoint.parentCount`.
- Repeated `replacing(_:with: GreenTreeSnapshot, cache:)` calls produce a
  growing chain of `OverlayTokenResolver` wrappings — each new tree wraps the
  previous tree's overlay. Long edit sessions accumulate resolver lookup
  levels. Either flatten on each call or document.
- `GreenNode.childrenArray()` allocates a fresh `Array` per call, and is
  invoked once per ancestor in `rebuildReplacing`. For deep replacements this
  is O(depth × siblings); could iterate without materializing.
- `forEachAncestor(includingSelf:)` semantics on a token cursor unconditionally
  include the immediate parent; the docstring is fine, but the asymmetry vs.
  node `forEachAncestor(includingSelf: false)` could trip callers.
- `RedArena.allocateSlots` returns `(state.slotChunks[0], 0)` for the
  zero-children case, which means a zero-child node's `childSlotChunk` is the
  root chunk even though no slot is ever read. Harmless but the special case
  is subtle; documenting it would help.
- `SyntaxMetadataStore` and `ExternalAnalysisCache` grow unboundedly across
  tree replacements; only the latter offers a `removeValues(notMatching:)`
  helper. Already in the roadmap (Priority 4), repeated here only as a
  cross-reference.
