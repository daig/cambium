# Cambium ⇄ Rust `cstree` audit

Cambium implements the green/red separation, builder, interner, anchors, and replacement faithfully. The biggest divergences are not where the roadmap currently looks — they are in the red layer's hot path, the green text-offset arithmetic, and a handful of subtle bugs in code paths the test suite does not exercise. Below, "**arch**" is `swift-native-cst-architecture.md`, line numbers pin the original.

---

## A. Critical bugs (real, not in roadmap)

### A1. The arena mutex turns every cursor read into an exclusive lock acquisition

**Where:** `Sources/CambiumCore/SyntaxTree.swift:122–229` (`RedArena`), `:445–447` (`SyntaxNodeCursor.record`).

`SyntaxNodeCursor.record` is reached on every property access (`rawKind`, `kind`, `textRange`, `textLength`, `childCount`, `greenHash`, `record.parent`, etc.) and runs `storage.arena.record(for: id)`, which calls `state.withLock`. The "fast path" in `realizeChildNode` at line 165 is also inside `state.withLock`:

```swift
let slot = state.withLock { state in
    state.slotChunks[parent.childSlotChunk].load(at: slotIndex)
}
```

So the `Atomic<UInt64>` slot is loaded under the exclusive mutex. The atomicity is decorative — every realized-child read serialises on the arena mutex anyway. The slow path at line 172 immediately reacquires the same mutex.

**Why this matters:** arch §21.1 promises "concurrent traversal of one shared tree is safe", §21.2 lists `node.kind`, `node.textRange`, `node.forEachChild`, `token.text`, `root.token(at:)` as APIs that "must not actor-hop", and §13.4 explicitly described an *atomic-acquire fast path* that bypasses the slow lock. The implementation contradicts all three: two threads traversing one `SharedSyntaxTree` fully serialise on a single `Mutex`. Even single-threaded reads pay the lock fee. cstree achieves true read-parallelism via per-child `parking_lot::RwLock` (cstree `syntax/node.rs:264`), which lets readers proceed in parallel and only takes the write lock on the very first realisation.

**Fix sketch:** keep the arena `Mutex` for `records.append` / chunk allocation only. Cache `RedNodeRecord` snapshots on each cursor at construction (records are immutable after publication) so property reads never lock. Use the existing `Atomic<UInt64>` slot loads on the fast path with `.acquiring` ordering, and only enter the mutex when a slot reads zero. This was the architecture spec's design.

### A2. `GreenNode.childStartOffset` is O(N), called O(N²) per node iteration

**Where:** `Sources/CambiumCore/GreenElement.swift:383–393`. Hot callers: `RedArena.realizeChildNode:195`, `SyntaxNodeCursor.withRawChildOrToken:596`, `tokens(in:):1085`, `withToken(at:):1122`, `withCoveringElement:1162`, `forEachDescendantOrToken:930`, `walkTokenPreorder:998`.

Every traversal that iterates `0..<childCount` and computes a child offset re-scans children from index 0. For a node with N children, that is O(N²) per node — and full-tree traversal on a wide tree degrades from O(total children) to O(Σ Nᵢ²).

cstree avoids this entirely with `green/iter.rs` + `node.rs:938` (`children_from`) and `:953` (`children_to`), which accumulate offsets in the iterator and visit each child once.

**Fix sketch:** thread an accumulating `offset` through every `for childIndex in 0..<green.childCount` loop, or precompute a child-start table either eagerly in `GreenNodeStorage` (extra storage per wide node) or lazily as arch §25.3 already proposed. The lazy table was specified but not built.

### A3. `SyntaxNodeCursor.childCount` is O(N)

**Where:** `SyntaxTree.swift:470–472` → `GreenElement.swift:353–361` (`nodeChildCount`). Iterates all green children every call. Combined with `withChildNode(at:)` (`:622–639`) — which itself linearly scans to find the n-th *node* child — node-by-index iteration is O(N²). `childOrTokenCount` is O(1); `childCount` is not.

**Fix sketch:** cache `nodeChildCount` in `GreenNodeHeader` (it never changes after construction) — then `cursor.childCount` becomes O(1), matching cstree's `arity_with_tokens()`.

### A4. `ReuseOracle` always reports `hitBytes = 0`

**Where:** `Sources/CambiumIncremental/IncrementalParsing.swift:139`:

```swift
session?.recordReuseQuery(hitBytes: result == nil ? nil : TextSize.zero)
```

`IncrementalParseCounters.reusedBytes` is therefore always zero on any tree — silently breaking benchmarks, telemetry, and cache-tuning. Roadmap Priority 4 lists "Track reused bytes accurately" as future work; it is in fact present-day broken accounting. The `firstReusableNode` callback already has the matched cursor in hand; `cursor.textLength` is the value that should flow back.

### A5. `missingToken(_:)` of a kind with static text renders as the static text

**Where:** `Sources/CambiumBuilder/GreenTreeBuilder.swift:544–552` creates a token with `text: .staticText` and `textLength: .zero`. `Sources/CambiumCore/GreenElement.swift:202–215` resolves `.staticText` by calling `Lang.staticText(for: kind)`. If that returns non-nil (e.g. `.plus → "+"`), the bytes "+" are streamed regardless of `textLength`. The token claims length 0 but renders 1 byte — the parent's aggregate `textLength` no longer matches its rendered text.

The test suite uses `.missing` (which has no static text, so the precondition path at line 205 catches it) and never exercises the buggy branch. Easily reproduced: `builder.missingToken(.plus)` followed by `tree.makeString()` produces a "+".

**Fix sketch:** add a `case missing` to `TokenTextStorage`, or have `missingToken` validate `Lang.staticText(for: kind) == nil` and trap/throw otherwise. Encode "missing" as a distinct sentinel from `.staticText`.

### A6. `GreenTreeBuilder.reuseSubtree` does not remap interner keys

**Where:** `GreenTreeBuilder.swift:578–583`:

```swift
public mutating func reuseSubtree(_ node: borrowing SyntaxNodeCursor<Lang>) {
    precondition(!finished, "Cannot mutate a finished GreenTreeBuilder")
    node.green { green in
        children.append(.node(green))
    }
}
```

The borrowed subtree's `TokenKey`s point into *its* tree's interner. Appending the green node into a different builder's children leaves those keys aliasing whatever happens to be in the new builder's interner — wrong text on resolution, no error. Cambium has the right machinery already (`ReplacementTokenRemapper`, `OverlayTokenResolver`), but only the replacement path uses it. Reuse silently doesn't.

It is correct only when the builder shares the source tree's resolver verbatim (e.g. inside one `IncrementalParseSession`). The API doesn't enforce that.

### A7. Anchor "nearby" resolution is hard-capped at 64 bytes

**Where:** `SyntaxTree.swift:1278`. Magic constant, not configurable, not documented. Any edit that moves a node by > 64 bytes (paste, large refactor, reformat) silently fails to resolve a previously-valid anchor. Anchors are explicitly designed to survive edits — this implementation makes them fragile in exactly the cases where you want them most.

**Fix sketch:** parameterise the tolerance on `SharedSyntaxTree.resolve(_:_:)` and document the trade-off; or compute a tolerance from the anchor's `range.length`.

### A8. `SharedTokenInterner` shard encoding silently overflows after 16 M tokens per shard

**Where:** `GreenTreeBuilder.swift:105`:

```swift
let key = TokenKey(UInt32(shardIndex << 24 | shard.textByKey.count))
```

Shard ID lives in the high 8 bits, local index in the low 24 — capped at 2²⁴ ≈ 16.7 M tokens per shard. With 8 shards, total ≈ 134 M. Beyond that, `shard.textByKey.count` overflows past `0x00ff_ffff` and the OR aliases the shard ID, returning a key that resolves to a *different shard's* string. No assertion, no error.

cstree's interner returns `InternerError::KeySpaceExhausted` (`interning/default_interner.rs:71-79`). Cambium silently corrupts.

**Fix sketch:** trap or throw when `shard.textByKey.count >= 0x0100_0000`; or use 16/16 splits and fewer shards; or use the full 32 bits with a separate `shardIndex` array.

### A9. `SharedTokenInterner.intern` uses `abs(keyBytes.hashValue)` for sharding

**Where:** `GreenTreeBuilder.swift:100`. `abs(Int.min)` traps. Hash values can in principle land on `Int.min`. Easily fixed with `keyBytes.hashValue & Int.max` or `UInt(bitPattern: keyBytes.hashValue) % UInt(shards.count)`.

### A10. The cache cannot be reused across builders

`GreenTreeBuilder.finish() -> GreenBuildResult` returns root + resolver but discards `cacheStorage`. cstree's `finish()` returns `(GreenNode, Option<NodeCache>)`, allowing `into_interner()` and reuse for the next build — the central pattern for incremental parsing. Cambium has no extraction API; cross-builder structural sharing requires holding a `GreenNodeCache` outside and constructing each builder via `init(cache:)`, but you can never get it back from the builder. This is the cache half of arch §19.1's "shared green node cache" goal, half-built.

---

## B. Major architectural deviations from the spec

### B1. `Atomic<UInt64>` slots are decorative

Spec §13.4 fast path: atomic-acquire load → if non-zero, return. Implementation: load is *inside* `state.withLock`. The `Synchronization.Atomic` primitive is used but the contract it enables (lock-free reads) is not. See A1.

### B2. No striped or per-parent locks

Spec §13.4: "start with arena-level or striped locks for correctness; benchmark per-parent locks only if contention appears." Cambium has only the single arena mutex, with no path to upgrade. Spec §13.4's "Preferred lock granularity" bullet list isn't reflected in the code.

### B3. No per-node-size cache threshold

Spec §12.3: "Cache aggressively: small green nodes; medium nodes below a configurable threshold. Avoid caching huge nodes by default." cstree caches only nodes with ≤3 children (`green/builder.rs:27`, `CHILDREN_CACHE_THRESHOLD`); larger nodes bypass the cache because hit rate is low. Cambium caches every node and trims by FIFO (`GreenTreeBuilder.swift:171–181`). FIFO eviction over arbitrary dictionary order means hot small nodes can be evicted while cold wide nodes survive.

### B4. No offset table for wide nodes

Spec §25.3 sketches `ChildOffsetTable { let childStarts: UnsafeBufferPointer<TextSize> }` and recommends building it lazily for wide nodes. Not implemented; A2 is the consequence.

### B5. Green types are copyable wrappers that retain on every child access

Spec §11.1 allowed copyable green refs "as long as the implementation keeps copy cost predictable", with an escape hatch to a `GreenStore + GreenID` arena model. `GreenNode` and `GreenToken` are structs over class storage, so `child(at:)` returning `GreenElement<Lang>` does an ARC retain on every iteration. In tight loops this is per-step ARC traffic — exactly what arch §3.2 wanted to avoid. The escape hatch was not taken; whether it's needed depends on benchmarks not yet run (roadmap Priority 10).

### B6. Cursor types lock the arena instead of caching the record

Spec §14.1's "implementation sketch" explicitly mentions "unowned/unsafe pointer to SyntaxTreeStorage / RedNodeID". Cambium followed that literally. But because RedNodeRecord is locked behind `Mutex<State>`, every property access pays the lock. A simple cache (read once at cursor construction, reuse on every property access) would convert reads to direct struct field loads. Records never change after publication, so the cache stays valid for the cursor's lifetime.

---

## C. Architecture-document errors that propagated

### C1. "Per-tree refcount" is partially right but oversold (arch §1.3, §40)

> Red nodes are `Send`/`Sync` by atomically reference-counting the syntax tree as a whole rather than individual nodes.

cstree does have one shared `*mut AtomicU32` per tree (`syntax/node.rs:261`), but every `SyntaxNode::clone` *still* increments that shared atomic — once per cloned reference. There is also one `Box<NodeData>` allocation per realised red node. Cambium reasonably interpreted the spec as "no per-node ARC at all", and went further: cursors never retain via `Unmanaged.passUnretained`. The handle path is the only one that takes a retain. So the architecture matches the spec's *spirit* — but only if the *reads* are also lock-free, which they aren't (A1). The arch doc didn't connect the two requirements.

### C2. The spec under-specified `SyntaxText` (arch §16)

Spec defines `utf8Count`, `writeUTF8(to:)`, `makeString()`. cstree's `SyntaxText` (`syntax/text.rs`) ships `is_empty`, `contains_char`, `find_char`, `char_at`, `slice`, `try_for_each_chunk`, `try_fold_chunks`, equality with `&str`/`String`/other `SyntaxText`. Roadmap Priority 2 acknowledges some of this, but the spec itself never set the bar. The implementation is faithful to the spec — the spec is impoverished.

### C3. The spec didn't define `TokenAtOffset.Between`

cstree's `token_at_offset` (`syntax/node.rs:848`, `utility_types.rs:133`) returns `None | Single(T) | Between(T, T)`. The `Between` case occurs at exact token boundaries (cursor placement at a token gap is the canonical IDE situation). Cambium's `withToken(at:)` returns Optional, losing the disambiguation. No editor consumer can correctly select "the token to the left vs the token to the right of the cursor" without re-implementing the logic. This is a spec-level gap, not an implementation oversight.

### C4. The spec didn't separate "static text" from "missing" in `TokenTextStorage` (arch §10.1)

Spec lists `staticText | interned(TokenKey) | ownedLargeText(LargeTokenTextID)`. The implementation faithfully kept this set. But "missing" is a different concept — an absent token of a kind that has static text. Conflating it into `.staticText + length 0` is exactly the bug at A5. Spec §8.2 mentions missing-token semantics (zero text length) but never says how to distinguish "missing" from "real static text" at storage level.

### C5. The spec said `node.kind`, `node.textRange`, `token.text` "must not actor-hop" but never said "must not lock"

Avoiding actors is necessary but insufficient. The implementation chose mutex-protected reads, which are not actor-isolated but are still synchronisation points. The spec's performance goals (§3.2: "no per-node ARC traffic", "no per-red-node class allocation") implicitly assumed lock-free reads but never said it directly.

### C6. Spec promised "predictable copying/sharing"; the cache eviction is unpredictable

Spec §25.4 prescribes "maximum bytes; maximum entries; eviction strategy; instrumentation counters". Implementation has the counters and a max-entries policy, but eviction key choice is `dict.keys.first` — Swift dictionary iteration order is unspecified across versions and after rehashing. Two builds with identical inputs can produce different cache contents. Spec §25.4's "predictable" goal is unmet.

---

## D. Feature gaps not in `cstree-gap-roadmap.md`

| # | cstree has | Cambium status | Notes |
|---|---|---|---|
| D1 | `TokenAtOffset` (None/Single/Between) | only Optional from `withToken(at:)` | Editor cursor placement at boundaries can't disambiguate |
| D2 | Builder cache extraction after `finish` | None | Blocks cross-builder structural sharing without lifetime gymnastics |
| D3 | Static-text validation in `builder.token(_:text:)` | None | cstree `debug_assert_eq!(static_text, text)` (`green/builder.rs:408`); silently allows mismatched-text static-kind tokens |
| D4 | Per-node user data type `D` | Sidecar `SyntaxMetadataStore` only | Different design choice, but no equivalent to `try_set_data` / `clear_data` directly on a node |
| D5 | `siblings(direction)` returning a lazy iterator | callback-style `forEachSibling` | No `break`/`filter`/`collect` composition without buffer allocation |
| D6 | `children_from(start_index, offset)` & `children_to(...)` | None | Useful for sibling enumeration starting mid-list |
| D7 | `NodeOrToken` rich helpers (`as_node`, `as_token`, `into_node`, `into_token`, `cloned`) | only `rawKind`/`textRange` on `SyntaxElementCursor` | Verbose `switch` at every callsite |
| D8 | `WalkEvent::map` | None | Minor convenience |
| D9 | Display/Debug on cursors and handles | only test-only `debugTree` in `CambiumTesting` | Roadmap Priority 8 covers debug rendering but not Display |
| D10 | `SyntaxNode::write_display` (streaming render) | only `makeString` (allocating) | Cambium has `writeUTF8` on `SyntaxText`, but not as a node convenience |
| D11 | Interner `KeySpaceExhausted` error | silent overflow / aliased keys (A8) | |
| D12 | `Direction` enum reused across siblings/walks | `TraversalDirection` exists but is only used in `forEachSibling` variants | OK but inconsistent surface |
| D13 | `arity()` (O(N)) and `arity_with_tokens()` (O(1)) | both O(N) due to A3 | |
| D14 | Replacement at root | works (replacement IS the root, no rebuild) | OK in Cambium too — but path is `if path.isEmpty` (`GreenTreeBuilder.swift:633`); fine |
| D15 | `SyntaxNode::set_data` `try_set_data` `clear_data` | not on handles; only via `SyntaxMetadataStore` | Different design |

---

## E. Test coverage gaps that mask the bugs above

- **No concurrency tests at all.** A1, A6, B1, B2 are completely uncovered. Arch §28 #8/#9 listed "Concurrent traversal tests" and "Thread Sanitizer suite" as required.
- **No `missingToken(.plus)`-style test.** A5 hides because every test uses `.missing` (no static text).
- **No cross-interner `reuseSubtree` test.** A6 hides because tests don't reuse a subtree from a tree with a different interner.
- **No wide-node tests.** A2 / A3 quadratic regression invisible — every test uses small trees (under ~10 children).
- **No SharedTokenInterner stress tests.** A8 / A9 invisible.
- **No anchor-after-edit tests with delta > 64 bytes.** A7 invisible.
- **No `builder.token(.plus, text: "X")` test.** D3 invisible.
- **No `walkPreorderWithTokens` skip/stop test.** Test uses skip on node-only walk only.

---

## Recommended priority

1. **A1** (lock everywhere) — single biggest concurrency/perf regression, undermines a load-bearing arch claim. Fix before any benchmark suite is meaningful.
2. **A2 + A3 + B4** (childStartOffset / childCount / no offset table) — these compound; one fix (cache nodeChildCount in header, accumulate offsets in iterators, optional offset table) addresses all three.
3. **A5, A6, A8, A9** — silent correctness bugs that will eventually bite real users.
4. **A4, A7, A10** — operational gaps that limit incremental parsing usefulness.
5. **C-series spec fixes** — update arch doc to make `TokenAtOffset.Between`, `missing`-as-distinct-storage, and lock-free read goals explicit, so future contributors don't re-derive the wrong constraints.
6. **D-series and roadmap** — most of D maps onto roadmap priorities 2/3; D1, D2, D3 should be added.

Cambium's *shape* matches the architecture spec well — green/red split, noncopyable builder, anchors, replacement, serialization, macro-derived kinds. Where it diverges is mostly invisible from the type signatures (A1, A2, A3) and from happy-path tests (A5, A6). A focused performance + correctness pass on the red layer would close the largest gaps with the spec without re-architecting.
