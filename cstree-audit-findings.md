# Cambium ⇄ Rust `cstree` audit

Cambium implements the green/red separation, builder, interner, witness-based cross-tree identity, and replacement faithfully. After the red cursor read refactor, the green child-offset pass, and the anchor-to-witness redesign, the biggest remaining divergences are cold red-realization contention/proof gaps and a handful of subtle bugs in code paths the test suite does not exercise. Below, "**arch**" is `swift-native-cst-architecture.md`, line numbers pin the original.

Status update: A1/B1/B6 are now resolved by the lock-free red cursor read
refactor. A2/A3 are now resolved by cached node-child counts and running
child-start offsets during traversal. B2 remains open, but is downgraded to a
cold-path contention and benchmark question rather than a hot-read defect. The
remaining critical correctness bugs from the original A-series have been
resolved. The main remaining gaps are operational/API completeness and
performance proof items.

---

## A. Critical bugs (real, not in roadmap)

### A1. Resolved: The arena mutex turned every cursor read into an exclusive lock acquisition

**Status:** fixed. Red records are now stable arena-owned reference objects;
node and token cursors carry unretained record references; copyable handles carry
strong record references; and child slots publish record pointers with
acquire/release atomics. The arena mutex remains for slow-path record allocation
and slot publication only. Focused handle-lifetime and concurrent lazy-realization
tests were added.

**Original finding:**

**Where:** `Sources/CambiumCore/SyntaxTree.swift:122–229` (`RedArena`), `:445–447` (`SyntaxNodeCursor.record`).

`SyntaxNodeCursor.record` is reached on every property access (`rawKind`, `kind`, `textRange`, `textLength`, `childCount`, `greenHash`, `record.parent`, etc.) and runs `storage.arena.record(for: id)`, which calls `state.withLock`. The "fast path" in `realizeChildNode` at line 165 is also inside `state.withLock`:

```swift
let slot = state.withLock { state in
    state.slotChunks[parent.childSlotChunk].load(at: slotIndex)
}
```

So the `Atomic<UInt64>` slot is loaded under the exclusive mutex. The atomicity is decorative — every realized-child read serialises on the arena mutex anyway. The slow path at line 172 immediately reacquires the same mutex.

**Why this matters:** arch §21.1 promises "concurrent traversal of one shared tree is safe", §21.2 lists `node.kind`, `node.textRange`, `node.forEachChild`, `token.text`, `root.token(at:)` as APIs that "must not actor-hop", and §13.4 explicitly described an *atomic-acquire fast path* that bypasses the slow lock. The implementation contradicts all three: two threads traversing one `SharedSyntaxTree` fully serialise on a single `Mutex`. Even single-threaded reads pay the lock fee. cstree achieves true read-parallelism via per-child `parking_lot::RwLock` (cstree `syntax/node.rs:264`), which lets readers proceed in parallel and only takes the write lock on the very first realisation.

**Implemented fix:** the arena keeps records strongly for tree lifetime and
child slots now store non-owning record pointers. Publication initializes the
record, appends it to arena-owned storage, then release-stores the pointer.
Readers acquire-load and read immutable fields directly.

### A2. Resolved: `GreenNode.childStartOffset` was O(N), called O(N²) per node iteration

**Status:** fixed. Red traversal, token lookup, covering-element lookup, and
sibling traversal now thread running child-start offsets through child loops and
pass them into cold red-node realization. `childStartOffset(at:)` remains as a
direct-index fallback only. A wide mixed node regression test covers offsets
across node/token traversal, token walks, sibling traversal, range token lookup,
zero-length missing tokens, and covering-element lookup.

**Where:** `Sources/CambiumCore/GreenElement.swift:383–393`. Hot callers: `RedArena.realizeChildNode:195`, `SyntaxNodeCursor.withRawChildOrToken:596`, `tokens(in:):1085`, `withToken(at:):1122`, `withCoveringElement:1162`, `forEachDescendantOrToken:930`, `walkTokenPreorder:998`.

Every traversal that iterates `0..<childCount` and computes a child offset re-scans children from index 0. For a node with N children, that is O(N²) per node — and full-tree traversal on a wide tree degrades from O(total children) to O(Σ Nᵢ²).

cstree avoids this entirely with `green/iter.rs` + `node.rs:938` (`children_from`) and `:953` (`children_to`), which accumulate offsets in the iterator and visit each child once.

**Implemented fix:** thread an accumulating `offset` through child loops. Wide
node offset tables remain a separate B4 optimization for repeated random child
offset queries, not a prerequisite for linear traversal.

### A3. Resolved: `SyntaxNodeCursor.childCount` was O(N)

**Status:** fixed. `GreenNodeHeader` now caches `nodeChildCount` at construction,
so `SyntaxNodeCursor.childCount` is O(1) while `withChildNode(at:)` remains an
O(N) indexed node-child search.

**Where:** `SyntaxTree.swift:470–472` → `GreenElement.swift:353–361` (`nodeChildCount`). Iterates all green children every call. Combined with `withChildNode(at:)` (`:622–639`) — which itself linearly scans to find the n-th *node* child — node-by-index iteration is O(N²). `childOrTokenCount` is O(1); `childCount` is not.

**Implemented fix:** cache `nodeChildCount` in `GreenNodeHeader` (it never
changes after construction).

### A4. Resolved: `ReuseOracle` always reports `hitBytes = 0`

**Where:** `Sources/CambiumIncremental/IncrementalParsing.swift:139` (historical).

Previously the oracle passed `TextSize.zero` to `recordReuseQuery(hitBytes:)`, leaving `IncrementalParseCounters.reusedBytes` permanently zero. Resolved by changing the private `firstReusableNode` helper to return `(R, TextSize)?` where the `TextSize` is the matched node's length, and threading that real length through to the counter. The semantics of `reusedBytes` now reflect *oracle offers*, not *parser acceptance* — the parser-driven accepted-reuse log (`recordAcceptedReuse` / `consumeAcceptedReuses`) is the authoritative count for what was actually reused.

### A5. Fixed: `missingToken(_:)` of a kind with static text rendered as the static text

**Where:** historical `Sources/CambiumBuilder/GreenTreeBuilder.swift` `missingToken(_:)`; `Sources/CambiumCore/GreenElement.swift` `withTextUTF8` / `makeString`.

Previously `missingToken(_:)` constructed tokens with `text: .staticText, textLength: .zero`. Resolution then dispatched on `.staticText`, called `Lang.staticText(for: kind)`, and streamed the resulting bytes — so a `missingToken(.plus)` rendered "+" while claiming zero length.

Resolved by adding a distinct `case missing` to `TokenTextStorage` (a sentinel meaning "absent"; renders as empty). `missingToken(_:)` now uses `.missing`, the structural hash mixes a fourth tag value to keep `.missing` and `.staticText` cache-distinct, and the snapshot serializer writes a new `missingText` tag so the distinction round-trips. `MissingTokenTests.swift` covers the rendering, hash distinction, and serialization round trip.

### A6. Fixed: `GreenTreeBuilder.reuseSubtree` did not remap interner keys

**Where:** `GreenTreeBuilder.swift:578–583`:

```swift
public mutating func reuseSubtree(_ node: borrowing SyntaxNodeCursor<Lang>) {
    precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
    node.green { green in
        children.append(.node(green))
    }
}
```

The borrowed subtree's `TokenKey`s point into *its* tree's interner. Appending the green node into a different builder's children used to leave those keys aliasing whatever happened to be in the new builder's interner — wrong text on resolution, no error.

Fixed by giving resolvers a `TokenKeyNamespace` identity and making `reuseSubtree` namespace-aware. If the source resolver and builder cache share the same token namespace, the builder appends the green node directly and preserves green storage identity. If they differ, the builder remaps interned and large-token keys into its own cache/interner while preserving static and missing tokens.

### A7. Resolved-by-removal: Anchor "nearby" resolution was hard-capped at 64 bytes

**Where:** historical `SyntaxTree.swift` `nearbyNode` helper.

The four-step anchor-resolution ladder relied on a hardcoded 64-byte tolerance for its final fallback. Resolved by replacing the entire `SyntaxAnchor` / `SharedSyntaxTree.resolve(_:_:)` mechanism with a witness-based design: edits return `ReplacementWitness` and incremental parses return `ParseWitness`, both pure structural descriptions of what changed. Cross-tree identity tracking is now externalized — there is no in-library "find this node again by fingerprint" path, so no magic-number tolerance. See `WITNESS.md` for the design.

### A8. Fixed: `SharedTokenInterner` shard encoding silently overflowed after 16 M tokens per shard

**Where:** `GreenTreeBuilder.swift:105`:

```swift
let key = TokenKey(UInt32(shardIndex << 24 | shard.textByKey.count))
```

Shard ID lives in the high 8 bits, local index in the low 24 — capped at 2²⁴ ≈ 16.7 M tokens per shard. With 8 shards, total ≈ 134 M. Beyond that, `shard.textByKey.count` used to overflow past `0x00ff_ffff` and alias the shard ID, returning a key that resolved to a *different shard's* string.

Fixed by centralizing the 8/24 key layout in `SharedTokenInternerKeyLayout`, constraining `shardCount` to 1...256, and trapping before appending when a shard's 24-bit local key space is exhausted. This preserves the current runtime-local key representation while removing silent corruption.

### A9. Fixed: `SharedTokenInterner.intern` used `abs(keyBytes.hashValue)` for sharding

**Where:** historical `GreenTreeBuilder.swift:100`. `abs(Int.min)` traps. Hash values can in principle land on `Int.min`. Fixed by selecting the shard with `UInt(bitPattern: keyBytes.hashValue) % UInt(shards.count)`.

### A10. Fixed: The cache could not be reused across builders

`GreenTreeBuilder.finish() -> GreenBuildResult` now returns root + `TokenTextSnapshot` + the reusable `GreenNodeCache`, matching cstree's "finish and carry the cache/interner forward" pattern. The cacheless view is explicit as `GreenTreeSnapshot` via `result.snapshot`. Reusing the returned cache in the next builder also carries the token namespace forward, which lets `reuseSubtree` preserve green identity for unchanged subtrees from the previous tree.

---

## B. Major architectural deviations from the spec

### B1. Resolved: `Atomic` slots were decorative

Spec §13.4 fast path: atomic-acquire load → if non-zero, return. The A1 fix
restores that contract for realized child reads: the fast path acquire-loads
the slot before entering the arena mutex.

### B2. Open but downgraded: cold realization still uses one arena mutex

Spec §13.4: "start with arena-level or striped locks for correctness; benchmark per-parent locks only if contention appears." Cambium still has one arena-level mutex, but after the A1 fix that mutex is no longer on ordinary cursor property reads or realized-child traversal. `realizeChildNode` now acquire-loads the parent child slot first; if the slot already contains a published record pointer, it returns without locking.

What remains under `RedArena.state.withLock` is the cold path: allocating slot storage for a newly realized child, assigning the next `RedNodeID`, appending the arena-owned `RedNodeRecord`, double-checking the slot under the lock, and release-publishing the record pointer. This is correct and avoids duplicate publication, but independent threads cold-traversing different unrealized subtrees still queue behind the same mutex.

So B2 no longer describes a hot-path design violation. It is an open concurrency/performance proof item: keep the global lock until cold parallel traversal benchmarks, broader stress tests, or Thread Sanitizer runs show that striped or per-parent locks are worth the extra complexity.

### B3. No per-node-size cache threshold

Spec §12.3: "Cache aggressively: small green nodes; medium nodes below a configurable threshold. Avoid caching huge nodes by default." cstree caches only nodes with ≤3 children (`green/builder.rs:27`, `CHILDREN_CACHE_THRESHOLD`); larger nodes bypass the cache because hit rate is low. Cambium caches every node and trims by FIFO (`GreenTreeBuilder.swift:171–181`). FIFO eviction over arbitrary dictionary order means hot small nodes can be evicted while cold wide nodes survive.

### B4. No offset table for wide nodes

Spec §25.3 sketches `ChildOffsetTable { let childStarts: UnsafeBufferPointer<TextSize> }` and recommends building it lazily for wide nodes. Not implemented. This is no longer needed for ordinary traversal after the A2 fix, but may still be useful for repeated random offset lookups on very wide nodes.

### B5. Green types are copyable wrappers that retain on every child access

Spec §11.1 allowed copyable green refs "as long as the implementation keeps copy cost predictable", with an escape hatch to a `GreenStore + GreenID` arena model. `GreenNode` and `GreenToken` are structs over class storage, so `child(at:)` returning `GreenElement<Lang>` does an ARC retain on every iteration. In tight loops this is per-step ARC traffic — exactly what arch §3.2 wanted to avoid. The escape hatch was not taken; whether it's needed depends on benchmarks not yet run (roadmap Priority 10).

### B6. Resolved: Cursor types locked the arena instead of caching the record

Spec §14.1's "implementation sketch" explicitly mentions "unowned/unsafe pointer to SyntaxTreeStorage / RedNodeID". Cambium followed that literally. The A1 fix now carries a stable record reference in each cursor, so property reads are direct immutable field reads rather than arena lookups.

---

## C. Architecture-document errors that propagated

### C1. "Per-tree refcount" is partially right but oversold (arch §1.3, §40)

> Red nodes are `Send`/`Sync` by atomically reference-counting the syntax tree as a whole rather than individual nodes.

cstree does have one shared `*mut AtomicU32` per tree (`syntax/node.rs:261`), but every `SyntaxNode::clone` *still* increments that shared atomic — once per cloned reference. There is also one `Box<NodeData>` allocation per realised red node. Cambium reasonably interpreted the spec as "no per-node ARC at all", and went further: cursors never retain via `Unmanaged.passUnretained`. The handle path is the only one that takes a retain. The A1 fix now makes cursor reads lock-free as well, so Cambium matches the spec's spirit here; the remaining lesson is that the arch doc should state the lock-free read requirement explicitly instead of only implying it through "predictable copying/sharing."

### C2. Mostly resolved in implementation: the spec under-specified `SyntaxText` (arch §16)

The original spec defined only `utf8Count`, `writeUTF8(to:)`, and `makeString()`, while cstree's `SyntaxText` (`syntax/text.rs`) offers empty checks, search, slicing, chunk iteration/folding, and equality without forcing a full `String` allocation. Cambium has since filled in the byte-first slice: `isEmpty`, `forEachUTF8Chunk`, byte and byte-sequence search, `sliced(_:)`, and equality against `String` and other `SyntaxText` values are implemented and covered by focused tests.

The remaining gap is mostly spec/API shape, not the old implementation gap. The architecture doc should be updated to describe this byte-oriented contract directly and to decide whether higher-level Unicode scalar/character helpers such as `contains_char`, `find_char`, or `char_at` belong on `SyntaxText` itself or in a separate utility layer.

### C3. The spec didn't define `TokenAtOffset.Between`

cstree's `token_at_offset` (`syntax/node.rs:848`, `utility_types.rs:133`) returns `None | Single(T) | Between(T, T)`. The `Between` case occurs at exact token boundaries (cursor placement at a token gap is the canonical IDE situation). Cambium's `withToken(at:)` returns Optional, losing the disambiguation. No editor consumer can correctly select "the token to the left vs the token to the right of the cursor" without re-implementing the logic. This is a spec-level gap, not an implementation oversight.

### C4. Resolved: separate "static text" from "missing" in `TokenTextStorage` (arch §10.1)

Spec previously listed `staticText | interned(TokenKey) | ownedLargeText(LargeTokenTextID)` and conflated "missing" with `.staticText + length 0`, which produced bug A5. The implementation now adds a distinct `case missing` to `TokenTextStorage` and enforces the zero-length invariant at construction time. Architecture doc §10.1 has been updated to describe the four-case storage model and the per-variant rendering/length contracts; §8.2 cross-references §10.1 for the missing-token storage representation.

### C5. Resolved in implementation: the spec said `node.kind`, `node.textRange`, `token.text` "must not actor-hop" but never said "must not lock"

Avoiding actors is necessary but insufficient. The original implementation chose mutex-protected reads, which were not actor-isolated but were still synchronisation points. The A1 fix corrected the implementation by making cursor reads and realized-child reads lock-free. The spec should still be clarified: the performance goals (§3.2: "no per-node ARC traffic", "no per-red-node class allocation") implicitly assumed lock-free reads, but did not say so directly.

### C6. Spec promised "predictable copying/sharing"; the cache eviction is unpredictable

Spec §25.4 prescribes "maximum bytes; maximum entries; eviction strategy; instrumentation counters". Implementation has the counters and a max-entries policy, but eviction key choice is `dict.keys.first` — Swift dictionary iteration order is unspecified across versions and after rehashing. Two builds with identical inputs can produce different cache contents. Spec §25.4's "predictable" goal is unmet.

---

## D. Feature gaps not in `cstree-gap-roadmap.md`

| # | cstree has | Cambium status | Notes |
|---|---|---|---|
| D1 | `TokenAtOffset` (None/Single/Between) | only Optional from `withToken(at:)` | Editor cursor placement at boundaries can't disambiguate |
| D2 | Builder cache extraction after `finish` | `finish()` returns cache-preserving `GreenBuildResult` | OK |
| D3 | Static-text validation in `builder.token(_:text:)` | None | cstree `debug_assert_eq!(static_text, text)` (`green/builder.rs:408`); silently allows mismatched-text static-kind tokens |
| D4 | Per-node user data type `D` | Sidecar `SyntaxMetadataStore` only | Different design choice, but no equivalent to `try_set_data` / `clear_data` directly on a node |
| D5 | `siblings(direction)` returning a lazy iterator | callback-style `forEachSibling` | No `break`/`filter`/`collect` composition without buffer allocation |
| D6 | `children_from(start_index, offset)` & `children_to(...)` | None | Useful for sibling enumeration starting mid-list |
| D7 | `NodeOrToken` rich helpers (`as_node`, `as_token`, `into_node`, `into_token`, `cloned`) | only `rawKind`/`textRange` on `SyntaxElementCursor` | Verbose `switch` at every callsite |
| D8 | `WalkEvent::map` | None | Minor convenience |
| D9 | Display/Debug on cursors and handles | only test-only `debugTree` in `CambiumTesting` | Roadmap Priority 8 covers debug rendering but not Display |
| D10 | `SyntaxNode::write_display` (streaming render) | only `makeString` (allocating) | Cambium has `writeUTF8` on `SyntaxText`, but not as a node convenience |
| D11 | Interner `KeySpaceExhausted` error | explicit precondition before shard-local exhaustion (A8 fixed) | Nonthrowing API choice |
| D12 | `Direction` enum reused across siblings/walks | `TraversalDirection` exists but is only used in `forEachSibling` variants | OK but inconsistent surface |
| D13 | `arity()` (O(N)) and `arity_with_tokens()` (O(1)) | node count and child-or-token count are O(1) | |
| D14 | Replacement at root | works (replacement IS the root, no rebuild) | OK in Cambium too — but path is `if path.isEmpty` (`GreenTreeBuilder.swift:633`); fine |
| D15 | `SyntaxNode::set_data` `try_set_data` `clear_data` | not on handles; only via `SyntaxMetadataStore` | Different design |

---

## E. Test coverage gaps that mask the bugs above

- **Concurrency coverage is still incomplete.** A1/B1 now have focused concurrent lazy-realization coverage, but shared interner/cache contention and broader Thread Sanitizer coverage still need CI-level follow-through. Arch §28 #8/#9 listed "Concurrent traversal tests" and "Thread Sanitizer suite" as required.
- **`missingToken(.plus)`-style coverage is present.** `MissingTokenTests.swift` covers A5 directly: empty rendering, structural-hash distinction from the static-text variant, and serialization round-trip.
- **Cross-interner `reuseSubtree` coverage is present.** `BuilderReuseTests.swift` covers remapping from a different interner and identity-preserving reuse through the cache returned by `finish()`.
- **Wide-node traversal coverage is now present.** A focused mixed node/token
  test covers the A2/A3 offset and node-count regression surface.
- **SharedTokenInterner key-layout coverage is present.** Focused tests cover A8/A9 without allocating 16 M strings.
- **A7 is gone**: anchors no longer exist; `WitnessTests.swift` covers the witness-based replacement contract that replaces them.
- **No `builder.token(.plus, text: "X")` test.** D3 invisible.
- **No `walkPreorderWithTokens` skip/stop test.** Test uses skip on node-only walk only.

---

## Recommended priority

1. **D3** — validate or reject static-token kinds passed through
   `builder.token(_:text:)`. This is the remaining small correctness trap: the
   dynamic-token path can currently build a static-kind token with arbitrary
   text.
2. **D1/C3** — add `TokenAtOffset` with `none`, `single`, and `between` so IDE
   cursor-boundary queries are represented directly.
3. **Incremental reuse oracle maturity** — upgrade matching beyond start
   offset/kind to account for edit invalidation, ranges, and green hashes, then
   document parser acceptance as the authoritative reuse signal.
4. **B3/C6** — replace dictionary-order cache eviction and decide whether to
   bias caching toward small nodes as cstree does.
5. **B2/B4/B5** — benchmark before changing: cold red-realization locking, wide
   node offset tables, and ARC traffic from copyable green wrappers are
   performance proof items, not current correctness bugs.

Cambium's *shape* matches the architecture spec well — green/red split, noncopyable builder, witness-based cross-tree identity, replacement, serialization, macro-derived kinds. The original silent correctness bugs in the A-series are now resolved; remaining work is mostly API completeness, documentation alignment, and performance validation.
