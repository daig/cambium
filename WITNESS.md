# Witness-Based Cross-Tree Identity

**Document date:** 2026-04-25
**Status:** Architectural decision; supersedes the `SyntaxAnchor` design from `swift-native-cst-architecture.md` §18
**Audience:** Lead engineer planning the implementation
**Resolves:** audit issue A7 in `cstree-audit-findings.md`

---

## 1. Executive summary

Cambium currently provides cross-tree node identity through `SyntaxAnchor` and `SharedSyntaxTree.resolve(_:_:)`: a stored fingerprint (path, range, kind, structural hash) plus a four-step retrieval ladder that tries each fingerprint dimension against the new tree, falling back to a nearby-match heuristic with a hardcoded 64-byte tolerance.

This design is being replaced. Edits and incremental reparses will return **witnesses** — structural descriptions of what changed — and consumers will translate identities through those witnesses rather than re-discovering them by fingerprint match. Cross-tree identity tracking moves out of `CambiumCore` entirely; it becomes a higher-layer concern that consumes Cambium's witnesses and composes whatever identity model an editor needs.

This mirrors how cstree externalizes incremental computation to salsa: the CST library provides structural primitives, and the consuming framework builds identity-and-memoization on top.

Same-tree identity is not affected. `SyntaxNodeCursor` (borrowed traversal), `SyntaxNodeHandle` (retained, hashable reference), and `SyntaxNodeIdentity` (value-typed identity, no retain) already cover within-tree identity completely. The cleanup is mostly subtractive: remove anchors, add witnesses, document the externalization boundary.

---

## 2. Problem statement

### 2.1 How anchors work today

A `SyntaxAnchor` is constructed from a cursor and stores five fields:

```swift
public struct SyntaxAnchor<Lang: SyntaxLanguage>: Sendable, Hashable {
    public let originalTreeID: TreeID
    public let path: [UInt32]
    public let range: TextRange
    public let rawKind: RawSyntaxKind
    public let greenHash: UInt64
}
```

`SharedSyntaxTree.resolve(_:_:)` then walks a four-step ladder against the target tree:

1. Exact path + kind + hash match (`withDescendant(atPath:)` then verify)
2. First node by range + kind + hash (depth-first scan)
3. First node by range + kind (less strict; loses hash check)
4. First node by kind + hash within 64 bytes of the original range start

If all four fail, resolution returns nil.

### 2.2 Why this is fragile

The resolver has access to v1 plus a fingerprint of v0. The information that links them — *the edit that produced v1 from v0* — has been thrown away. The resolver is therefore reconstructing a correspondence from incomplete data, and every step in the ladder is a heuristic about which fingerprint dimension is most reliable for which class of edit. None of those heuristics are right in general:

- The **path** breaks the moment any ancestor's children-before-this-index are inserted into or deleted from
- The **range** breaks when text earlier in the file shifts by any amount
- The **hash** breaks when the node's content changes at all
- The **kind** is ambiguous when multiple nodes share a kind (which is normal — e.g. multiple `if` statements)
- The **64-byte cutoff** is a magic number with no principled justification; arbitrary edits exceed it

A particularly bad failure mode: structurally-identical adjacent nodes (e.g. two `if x { }` statements) are indistinguishable to the hash, so step 4 can match the wrong one with no signal to the caller.

Making the resolver "smarter" — more dimensions, weighted scoring, configurable tolerances — does not address the structural problem. Fingerprints have low entropy under perturbation, exactly the wrong shape for the task. Any retrieval-shaped solution has the same fundamental defect.

### 2.3 Why salsa-style memoization isn't the answer either

Salsa solves a different problem: incremental re-derivation of computed values keyed by their inputs. If you ask "is this computed value still valid?", salsa answers by checking whether its inputs changed. It does not track identity correspondences across versions; it just detects when memoized outputs need to be recomputed.

Editor UI state (diagnostics attached to nodes, selections, fold state) isn't computed values — it's *attachments*. The UI doesn't ask "is this diagnostic still valid?", it asks "where in the new tree is the node my diagnostic is anchored to?" Salsa has no mechanism for that question. We need change *propagation* on attached references, not change *detection* on derived values.

---

## 3. Design principles

The new design follows five principles:

1. **Transport, not retrieve.** Edit operations know what they did. They carry that information forward as a witness, and consumers translate identities through the witness chain. Resolution after the fact, with no provenance, is rejected as a primary mechanism.

2. **Same-tree identity is already solved.** Cambium's existing primitives — `SyntaxNodeCursor`, `SyntaxNodeHandle`, `SyntaxNodeIdentity` — completely cover within-tree identity. The only change there is removing the anchor's accidental same-tree role.

3. **Externalize the policy.** Cambium emits witnesses describing structural change. It does not interpret them, does not maintain identity tables, does not impose semantics for deletion handling, redirection, or fallback. Those policies belong in the editor framework or wherever identity-tracking is needed.

4. **Fail explicitly.** When an edit deletes a node, the witness says it was deleted. Consumers handle that case explicitly. There is no silent-nil heuristic substitution that pretends to have found a "nearby" match.

5. **Library remains parser-neutral.** Witnesses describe structural changes in vocabulary the library already exposes — green nodes, paths, ranges, operation kinds. They do not encode grammar-specific semantics or commit to any particular identity model.

---

## 4. Goals and non-goals

### Goals

- Provide a stable, exact mechanism for tracking node identity through edits applied via Cambium's `replacing(...)` API
- Provide a stable, exact mechanism for tracking node identity through incremental reparse via `IncrementalParseSession`
- Keep `CambiumCore` minimal and free of any identity-tracking policy
- Support editor use cases (diagnostics, selections, fold state, code actions, semantic caches) via composition outside the core

### Non-goals (deferred to future work or higher layers)

- **Identity recovery without a witness chain.** Cold-start lookups, disk roundtrips, third-party tree mutation — these break the witness chain. If such cases need to be supported, the higher layer computes its own fingerprints and accepts heuristic matching. Cambium does not bless any heuristic.
- **Bidirectional editing / lens-style refactoring.** The Boomerang/Augeas-style "edit the tree, regenerate text with formatting preserved" feature is acknowledged as a valuable future direction. The witness primitive is a foundation that supports it, but designing it is out of scope here.
- **Tree-edit-distance / structural alignment.** Computing a correspondence between two trees with no provenance information (e.g. via GumTree-style algorithms) is also future work. Mentioned but explicitly deferred.
- **Concurrency reconciliation.** CRDT/OT systems for collaborative editing are out of scope. Cambium assumes single-author editing.

---

## 5. Same-tree identity (no change beyond cleanup)

Within a single tree, Cambium's identity story is already complete and unchanged. The triad:

| Primitive | Lifetime | Retains tree? | Hashable? | Purpose |
|---|---|---|---|---|
| `SyntaxNodeCursor` | borrow scope | no | n/a | active traversal |
| `SyntaxNodeHandle` | unbounded | yes | yes | persistent reference; map keys; cross-task |
| `SyntaxNodeIdentity` | unbounded | no | yes | pure identity; map keys without retention |

(Same shape for `SyntaxTokenCursor` / `SyntaxTokenHandle` / `SyntaxTokenIdentity`.)

This maps cleanly onto cstree's model. cstree's `&SyntaxNode<S, D>` is the borrowed-cursor analogue (its identity is the heap pointer to `NodeData`). cstree's cloned `SyntaxNode` (which bumps a per-tree refcount and produces an owned reference) is the handle analogue. The only thing Cambium has that cstree doesn't is the value-typed `SyntaxNodeIdentity` — useful for retain-free dictionary keys (e.g. a diagnostics index that should let trees be reclaimed when no consumer holds them).

After the witness-based design is adopted, anchors no longer have any role here. Same-tree code that today does `cursor.makeAnchor()` followed by `tree.resolve(anchor) { ... }` should use `cursor.makeHandle()` followed by `handle.withCursor { ... }` instead — the same outcome with O(1) dereference instead of an O(D) path walk and four-step ladder.

### 5.1 Optional follow-up: SyntaxElementHandle

cstree exposes `NodeOrToken<SyntaxNode, SyntaxToken>` as the "either-or" identity. Cambium has `SyntaxElementCursor` (the noncopyable enum) but no corresponding handle type. A `SyntaxElementHandle` enum would round out the symmetry:

```swift
public enum SyntaxElementHandle<Lang: SyntaxLanguage>: Sendable, Hashable {
    case node(SyntaxNodeHandle<Lang>)
    case token(SyntaxTokenHandle<Lang>)
}
```

Not required for the witness work, but a small addition that fixes a real ergonomic gap. Flag for the implementation plan; the lead engineer can decide whether to bundle it with the witness changes or treat it as separate.

---

## 6. Cross-tree identity via witnesses

### 6.1 The shape of the change

Edit-producing operations gain witness output:

```
Before:  func replacing(...) -> SyntaxTree<Lang>
After:   func replacing(...) -> ReplacementResult<Lang>

For incremental parse, `ParseWitness` is constructed by the integrator
from data the parser/builder records on `IncrementalParseSession` during
the parse — there is no parser-owning `parse(...)` method in the library.
See §8 for the integrator pattern.
```

Witnesses are **pure descriptions** of what changed. They contain no resolution logic, no policy, no opinion about what callers should do. A consumer holding a witness has all the information needed to translate any v0 reference into v1 — exactly, when the reference is preserved; explicitly *deleted*, when it isn't.

### 6.2 Witness vocabulary

Witnesses are expressed in primitives that are already public and stable:

- **`GreenNode<Lang>` identity.** Because Cambium deduplicates green storage during construction, the same `GreenNode` instance literally appears in both the old tree and the new one wherever a subtree is structurally preserved. This makes "same green node" a cross-tree concept by construction; the witness can use green node identity to mark "this part is unchanged" without further machinery. Tested publicly via `node.identity` — a `GreenNodeIdentity` value type backed by `ObjectIdentifier(storage)`. Note that `GreenNodeIdentity` is *live-only* (the underlying `ObjectIdentifier` can be reused once storage deallocates), so it is not durable / persistable — compare two identities only when both source values are reachable.
- **`[UInt32]` paths.** Identifies a subtree by its position from the root.
- **`TextRange`.** Identifies a position in source text.
- **Operation kinds.** What kind of change happened (replaced, reused, inserted, deleted).

None of these depend on cursor representation, arena layout, lock strategy, or any internal mechanism that we might want to evolve. Witnesses are a stable contract.

### 6.3 Two witness types

`ReplacementWitness` describes a structural edit applied via `SharedSyntaxTree.replacing(...)`. Discussed in §7.

`ParseWitness` describes the result of an incremental reparse via `IncrementalParseSession`. Discussed in §8.

These are the two edit-producing paths in Cambium today. If new edit operations are added later (batch replacement, structural rewrite, splice-children), each gets its own witness type or extends the existing types as appropriate. The pattern — operation returns `(NewTree, Witness)` — is uniform.

---

## 7. ReplacementWitness

### 7.1 Sketch

The final API shape is the lead engineer's call. The minimum information content is:

```swift
public struct ReplacementWitness<Lang: SyntaxLanguage>: Sendable {
    public let oldRoot: GreenNode<Lang>
    public let newRoot: GreenNode<Lang>
    public let replacedPath: [UInt32]
    public let oldSubtree: GreenNode<Lang>
    public let newSubtree: GreenNode<Lang>
}
```

A consumer with this witness can categorize any reference into v0:

- **Replacement-by-self (`oldSubtree.identity == newSubtree.identity`)** → unchanged for every path. The API returns a tree rooted at `oldRoot`, so green identity is preserved throughout.
- **Path is unrelated to `replacedPath` (neither prefix-of nor descended-from)** → unchanged. The same `GreenNode` is at the same path in v1.
- **Path is a strict prefix of `replacedPath`** → ancestor. The ancestor still exists in v1, but one of its descendants changed.
- **Path is a strict descendant of `replacedPath`** → deleted. The old subtree is gone; what's at that path now is a node from the new subtree, which is by definition a different node.
- **Path equals `replacedPath`** → replaced root. The reference's node is the old subtree root, which no longer exists unless this was replacement-by-self; consumers that want to redirect can use `newSubtree` as the redirection target.

The key property that makes this exact: structural sharing. Outside the replaced subtree, the new tree literally contains the same `GreenNode` instances as the old tree. So "same green node" testing is enough to identify preservation; no fingerprint comparison required.

### 7.2 Implications for an external tracker

A tracker holding handles to v0 nodes can update them to point at v1:

- For paths outside the replaced subtree: the new handle has the same path, the same green node identity, but a fresh `RedNodeID` in the new arena. The tracker realizes the corresponding red node in v1 (an O(D) walk, O(1) on already-cached paths) and stores the new handle.
- For paths inside the replaced subtree: the tracker emits a deletion to its consumer (which decides whether to drop the diagnostic, redirect to the replaced subtree's root, or surface to the user).

Note that the witness alone tells you *what* changed; it does not pre-translate handles. The tracker is responsible for the translation. This keeps the witness type small and the policy decisions in the right place.

### 7.3 Edge cases the lead engineer should consider

- **Replacement at root (path is empty).** The entire tree is replaced; every previously-tracked handle is deleted. This is a degenerate but legal case.
- **Replacement that doesn't change identity.** If the replacement subtree is the same live green node as the old subtree, the returned tree is rooted at `oldRoot`, the witness is still emitted, and `classify(path:)` returns `.unchanged` for every path.
- **Replacement that consumes a `GreenBuildResult` with its own resolver.** This is the path that today goes through `ReplacementTokenRemapper`. The witness vocabulary is unaffected by interner remapping; the witness describes structural change, not resolver state.

---

## 8. ParseWitness

### 8.1 Sketch

`ParseWitness` is conceptually richer than `ReplacementWitness` because incremental parse can reuse many disjoint subtrees from the previous tree. A reasonable starting shape:

```swift
public struct ParseWitness<Lang: SyntaxLanguage>: Sendable {
    public let oldRoot: GreenNode<Lang>?         // nil if this was a fresh parse
    public let newRoot: GreenNode<Lang>
    public let reusedSubtrees: [Reuse<Lang>]
    public let invalidatedRegions: [TextRange]   // in old-tree coordinates
}

public struct Reuse<Lang: SyntaxLanguage>: Sendable {
    public let green: GreenNode<Lang>
    public let oldPath: [UInt32]
    public let newPath: [UInt32]
}
```

A `Reuse` entry says: "this `GreenNode` was at `oldPath` in v0 and is now at `newPath` in v1." A consumer with the entries can update tracked handles whose paths fall within reused subtrees — the green node identity matches, only the path changes.

Anything not covered by a `Reuse` entry is freshly parsed; tracked handles whose paths point into freshly-parsed regions are deleted from the perspective of identity tracking.

### 8.2 Information source

`ParseWitness` is constructed *cooperatively* between Cambium and the parser/integrator. The library cannot derive it on its own:

- `ReuseOracle.withReusableNode(...)` exposes *offers* — candidate reusable subtrees the parser may inspect and decline. Offers are recorded as counters on `IncrementalParseSession` (`reuseQueries`, `reuseHits`, `reusedBytes`) but are not the right input for ParseWitness, since a parser can offer-and-reject.
- The parser/builder records *accepted reuses* — what was actually spliced into the new tree at a known new path — by calling `IncrementalParseSession.recordAcceptedReuse(oldPath:newPath:green:)`.
- After the parse completes, the integrator drains the accepted-reuse log via `IncrementalParseSession.consumeAcceptedReuses()` and constructs `ParseWitness(oldRoot:, newRoot:, reusedSubtrees: drained, ...)`.

The library provides the data plumbing (the `IncrementalParseSession` API and the `ParseWitness` / `Reuse` types); the integrator owns the parse and stamps the new paths.

`IncrementalParseSession` is documented as supporting **one active parse at a time** — counters and the accepted-reuse log are session-global, so concurrent parses against one session interleave. Use one session per parse if you parse concurrently.

### 8.3 Open implementation question

Representation efficiency is the real implementation concern. A long-running incremental session might reuse hundreds of small subtrees on each reparse; an array of `Reuse` entries works but may be heavy. Possible alternatives:

- A path-keyed map (faster lookup, less compact)
- A tree-shaped diff structure (compact but more complex to consume)
- A pre-computed "translation function" closure that the consumer calls per reference

This is left as a design choice for the lead engineer. The conceptual contract — "witness lets a consumer translate v0 paths to v1 paths exactly for reused subtrees, and identify deletions explicitly otherwise" — is what matters; the representation can evolve without breaking the contract.

---

## 9. Where witness types live

Module placement:

- **`ReplacementWitness<Lang>`** lives in `CambiumCore`. It references `GreenNode<Lang>` and is produced by APIs that today are split between Core and Builder (the `replacing()` extensions on `SharedSyntaxTree` are declared in `CambiumBuilder` because they need the cache, but the type itself belongs in Core).
- **`ParseWitness<Lang>`** lives in `CambiumIncremental`. It belongs to the incremental parse session and references `GreenNode<Lang>` from the core.

Neither type lives in `CambiumAnalysis` or any consumer-facing layer. Witnesses are core primitives; they describe what Cambium did, in vocabulary Cambium owns.

The rough dependency graph after the change:

```
CambiumCore                  ← ReplacementWitness type, GreenNode primitives
  ↑
CambiumBuilder               ← witness-returning replacing()
  ↑
CambiumIncremental           ← ParseWitness type, accepted-reuse logging
  ↑
[external] identity tracker  ← consumes both witness types
  ↑
[external] editor framework  ← uses tracker for diagnostics, selections, etc.
```

---

## 10. The externalized identity tracker

The identity tracker is **not** part of `CambiumCore` and is **not designed in this document**. Its design and implementation belong in a higher layer — either a separate Cambium-aligned package (working name suggestion: `CambiumStableID`) or as part of an editor framework's own infrastructure.

This section describes only its role and the Cambium contract, not its internal design.

### 10.1 Role

A typical tracker:

- **Accepts handles from clients.** A client (e.g. a diagnostic store, a selection tracker, a folding-state component) registers a `SyntaxNodeHandle` with the tracker, receives back an opaque stable identifier, and uses that identifier to refer to the node in subsequent versions.
- **Consumes witnesses from edits and parses.** When the client applies an edit and gets a `(NewTree, Witness)`, it hands the witness to the tracker. The tracker walks its registered identifiers, classifies each (preserved, deleted, etc.), and updates its internal mapping accordingly.
- **Resolves stable identifier → current handle.** Given a stable identifier and the current tree, the tracker returns either the current `SyntaxNodeHandle` for the corresponding node, or a deletion signal.

### 10.2 What Cambium does not impose

- **Deletion policy.** When a witness reports a node as deleted, the tracker may drop it, redirect it (to the nearest surviving ancestor, to the root of the replacement subtree, to a sentinel "deleted" entry that surfaces to the user), or run a custom heuristic. None of these are Cambium's concern.
- **Cold-start fallback.** Loading a stable identifier from disk after restart breaks the witness chain. A tracker that cares about this case may compute and store its own fingerprints (path, range, kind, hash) at registration time and run its own retrieval algorithm against the loaded tree. Cambium does not provide such an algorithm.
- **Persistence format.** If the tracker persists state, it owns the format.
- **Observability.** Resolution success rates, deletion counts, performance metrics — all the tracker's responsibility.

### 10.3 Compose, don't impose

Multiple trackers with different policies can coexist in the same application. A diagnostics store might use a strict policy ("anchor deleted → drop diagnostic"); a selection tracker might use a redirect policy ("anchor deleted → snap to the replacement subtree"); a code-action tracker might use a retention-with-grace-period policy. Cambium provides the same witness primitives to all of them.

---

## 11. Migration: what gets removed

The following parts of the current implementation are removed when this design ships:

| Removed | Location |
|---|---|
| `SyntaxAnchor<Lang>` type | `CambiumCore/SyntaxTree.swift:58` |
| `SharedSyntaxTree.resolve(_:_:)` | `CambiumCore/SyntaxTree.swift:339` |
| `SyntaxNodeCursor.makeAnchor()` | `CambiumCore/SyntaxTree.swift:1488` |
| `SyntaxNodeCursor.firstNode(...)` and `nearbyNode(...)` internal helpers, including the 64-byte tolerance | `CambiumCore/SyntaxTree.swift:1529`–`:1568` |
| `SharedSyntaxTree.replacing(_ anchor:with:cache:)` overloads | `CambiumBuilder/GreenTreeBuilder.swift:655`–`:697` |
| `Diagnostic.anchor` field and related `init` | `CambiumAnalysis/Analysis.swift:14`, `:20` |
| `AnalysisCacheKey.anchor` field | `CambiumAnalysis/Analysis.swift:97`, `:100` |
| Anchor-using tests | `Tests/CambiumCoreTests/CoreSmokeTests.swift:925`, `:929`, `:1054` |

Note: `withDescendant(atPath:)` (`CambiumCore/SyntaxTree.swift:1508`) remains. It's a useful primitive in its own right — the lead engineer may decide whether to keep it public, mark it internal, or remove it. The path-descent operation itself is not specific to anchors.

The audit issue **A7** (hardcoded 64-byte tolerance) is resolved by virtue of the entire `nearbyNode` helper being removed.

---

## 12. Migration: what gets added

| Added | Location |
|---|---|
| `ReplacementWitness<Lang>` type | `CambiumCore` |
| `ParseWitness<Lang>` type | `CambiumIncremental` |
| `SharedSyntaxTree.replacing(_ handle:with:cache:)` returning `ReplacementResult<Lang>` | `CambiumBuilder` (where today's `replacing` lives) |
| `IncrementalParseSession.recordAcceptedReuse` and `consumeAcceptedReuses` for parser-driven `ParseWitness` construction | `CambiumIncremental` |
| `GreenNodeIdentity` (public storage-identity primitive on `GreenNode`) | `CambiumCore` |
| `SyntaxNodePath` typealias for path-shaped APIs | `CambiumCore` |
| `ReplacementResult` (`~Copyable` wrapper bundling new tree + witness) | `CambiumCore` |
| Tests covering the witness contract | new tests in `CoreSmokeTests` or a new test file |

Test coverage should include at minimum:

- After a replacement, paths outside the replaced subtree resolve via `GreenNode` identity to the same node in the new tree
- After a replacement, paths inside the replaced subtree are reported as deleted
- Replacement at the root path (empty `[UInt32]`) deletes everything
- `ParseWitness` correctly identifies reused subtrees from parser-recorded accepted reuses
- Replacement by the same live green subtree still emits a witness, preserves root identity, and classifies every path as unchanged

---

## 13. What stays the same

- All cursor traversal APIs (`forEachChild`, `withChildNode`, `walkPreorder`, `tokens(in:)`, etc.)
- `SyntaxNodeHandle`, `SyntaxTokenHandle`
- `SyntaxNodeIdentity`, `SyntaxTokenIdentity`
- The green tree, builder, cache, and interner — entirely unaffected
- `IncrementalParseSession`'s overall machinery — augmented with witness output but not redesigned
- The serialization layer — does not depend on anchors
- The macro layer — does not depend on anchors

The change is structurally contained to a small surface area in three modules (Core, Builder, Analysis) plus tests.

---

## 14. Tradeoffs and explicit costs

### Lost

- **The "save anchor, deserialize after restart, find node" use case.** This was a genuine feature of the anchor system, however unreliable. Users who need cold-start identity recovery now compute their own fingerprints in the higher layer and accept their own heuristic. Cambium does not bless any heuristic and does not provide a built-in fallback.
- **API ergonomics for casual cross-version use.** "Make an anchor and use it later" is replaced by "register a handle with an identity tracker, drive the tracker with witnesses." For an editor framework consumer this is hidden behind the tracker; for a raw Cambium user it's more API surface.
- **Future flexibility to add cross-tree identity to core.** By committing to "core does not track cross-tree identity" we accept that this constraint is permanent. Adding it later would be a breaking change to the design contract.

### Gained

- **Identity tracking that's exact when an edit witness is available** — which is the dominant editor case (every keystroke goes through a witness-emitting parse or edit).
- **Room to evolve cross-tree identity policy in higher layers** without churning the core API. Different consumers can adopt different policies.
- **Removal of the fragile resolver.** No more silent-nil failures, no more arbitrary tolerance constants, no more heuristic ladders that fail in surprising ways.
- **A foundation for future bidirectional editing** (Boomerang/Augeas style). The witness primitive plus an unparse-with-position-map mechanism gives the building blocks; the lens itself is a future feature.

---

## 15. Open questions for the implementation plan

The lead engineer's implementation plan should resolve these:

1. **Witness type representation.** Sealed enum, marker protocol, or discrete structs? `ReplacementWitness` and `ParseWitness` are different enough that a unified type may not be useful, but a marker protocol could enable generic tooling.
2. **Compact `ParseWitness` representation.** Array of reuse entries, path-keyed map, or something more structural? See §8.3.
3. **API surface for `replacing`.** Should it accept handles only, or also raw green-node-at-path? Probably handles only (it's the simplest contract), but the question is worth flagging.
4. **Interaction with `GreenTreeBuilder.reuseSubtree(_:)`.** This API in the builder is separate from the incremental parse path but related. Currently it doesn't remap interner keys — that's audit issue **A6**, separate but related. The implementation plan should consider whether `reuseSubtree` should emit witnesses too, and how it handles cross-interner reuse.
5. **Tracker package placement.** Should `CambiumStableID` (or whatever name) live in this repository as a sibling package, or in a downstream consumer? Recommendation: outside this repository. The tracker is the editor framework's concern and its API will be shaped by editor needs more than by Cambium's preferences.
6. **Migration strategy.** Big-bang removal of anchors plus addition of witnesses, or a deprecation period where both coexist? The codebase is small enough that big-bang is feasible; the question is whether external consumers (which may not yet exist) need a transition.

---

## 16. Future work (noted, not designed)

Two natural extensions of the witness foundation, both deferred:

### 16.1 Bidirectional editing

If Cambium grows an unparse-with-position-map mechanism (each node serializes back to text along with a record of which byte range it occupies in the output), then combining that with structural editing produces a lens in the Boomerang/Augeas sense:

- `parse(text) -> tree` (the "get" direction; already exists)
- `unparse(tree) -> (text, positionMap)` (the "put" direction; doesn't exist yet)
- Tree edits via the witness-emitting `replacing(...)` API
- `unparse` after edits produces new text with formatting preserved on unchanged nodes (because trivia is part of the green tree and travels with unchanged subtrees by structural sharing)

This is the refactoring story: programmatic tree edits that produce text edits with comments and whitespace preserved. Not in scope here. Designed when there's a concrete consumer.

### 16.2 Structural alignment for the no-witness case

Some consumer use cases break the witness chain (loaded from disk, third-party tree mutation, two trees with no recorded relationship). For those, a proper tree-diff algorithm — GumTree, change distilling, etc. — could provide reliable identity recovery without the fragility of fingerprint heuristics. This would be an opt-in escape hatch, layered above the core, and is research-grade work. Mentioned but explicitly deferred.

---

## 17. References

- `swift-native-cst-architecture.md`, particularly:
  - §7 (Ownership-first public API model)
  - §14 (Borrowed cursor API)
  - §15 (Explicit handle API)
  - §18 (Stable anchors across tree versions) — the section this document supersedes
- `cstree-audit-findings.md`, particularly issue **A7** (hardcoded 64-byte tolerance) — resolved by this design
- The Boomerang paper (Foster et al., "Combinators for Bidirectional Tree Transformations") — the conceptual lineage for §16.1
- The Augeas configuration editing tool — applied use of Boomerang-style lenses, referenced as an existence proof
- cstree's documentation, for the salsa-decomposition analogy that motivated externalizing identity tracking

---

## 18. Summary for implementation

The work is focused and bounded:

1. Add two witness types in their respective modules
2. Update two API entry points (`replacing`, `parse`) to return them
3. Remove `SyntaxAnchor`, the resolver, the `replacing(anchor:)` overloads, and the `anchor` fields in `Diagnostic` and `AnalysisCacheKey`
4. Update tests to use handles for same-tree identity and witnesses for cross-tree
5. Update or remove documentation that references anchors (chiefly §18 of the original architecture document)

The lead engineer's implementation plan should sequence these changes, resolve the open questions in §15, and identify any additional surface that needs to evolve to land cleanly. Once the witness primitives are stable, the higher-layer identity tracker can be built independently — that work is not part of this document and not part of `CambiumCore`.
