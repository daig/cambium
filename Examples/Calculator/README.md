# Calculator Example

This is a standalone SwiftPM example package that uses Cambium to build,
traverse, and evaluate a concrete syntax tree for a small calculator
language. It is a manual end-to-end test bed for Cambium itself: the REPL
exercises the library's public surface (parsing, traversal, incremental
reparse, replacement, serialization, …) and lets you poke at it interactively.

The grammar supports integer literals, real literals, whitespace, parentheses,
unary minus, `round(expr)`, and `+`, `-`, `*`, `/` with normal precedence. The
parser preserves the input text losslessly, builds error and missing nodes for
malformed input, and only evaluates trees with no parse diagnostics.

## Run

```sh
swift run calc-repl
```

REPL commands:

- `<expression>` replaces the current document and evaluates it.
- `:edit <start>..<end> <text>` applies a byte-range edit and reparses.
- `:at <offset>` shows which token owns a byte offset, or the adjacent token
  pair at a token boundary.
- `:cover <start>..<end>` shows the smallest node or token covering a byte
  range.
- `:nodes` lists owned handles for expression nodes in depth-first preorder.
- `:tokens [<start>..<end>]` lists owned token handles, optionally filtered to
  a byte range.
- `:show` prints the current document and re-evaluates it.
- `:save <path>` writes the current clean tree as a Cambium green snapshot.
- `:load <path>` loads a Cambium green snapshot as the current document.
- `:tree` toggles CST dumps.
- `:ast` toggles typed AST dumps.
- `:fold` constant-folds the current document one replacement at a time and
  prints each `ReplacementWitness` classification demo.
- `:counters` prints incremental reuse counters and evaluator cache stats.
- `:cached` prints cached evaluator values attached to current-tree nodes.
- `:reset` drops the current session state.
- `:help` prints commands.
- `:q` or `:quit` exits.

## Position Queries

`:at` and `:cover` run against the most recently parsed tree, including trees
with diagnostics. A few useful probes:

```text
calc> 1+2
3
calc> :at 1
between: number 0..<1 | plus 1..<2
calc> :at 3
single: number 2..<3 "2"
calc> :cover 0..<1
token: number 0..<1 "1"
calc> :cover 0..<3
node: binaryExpr 0..<3
calc> (1
error: expected ')' at 2..<2
calc> :at 2
single: rightParen 2..<2 ""
```

## Owned Traversal

Most calculator internals use borrowed cursors because they avoid allocation
and ARC traffic on hot paths. The `:nodes` and `:tokens` commands instead use
`CalculatorParseResult.expressionHandles` and `tokenHandles(in:)`, which
materialize arrays of `SyntaxNodeHandle` and `SyntaxTokenHandle` values that can
be iterated or stored after the original borrow scope has ended.

```text
calc> 1 + round(2.5)
4
calc> :nodes
binaryExpr 0..<14 "1 + round(2.5)"
integerExpr 0..<1 "1"
roundCallExpr 4..<14 "round(2.5)"
realExpr 10..<13 "2.5"
calc> :tokens 4..<10
round 4..<9 "round"
( 9..<10 "("
```

## Analysis Sidecars

`CalculatorSession` keeps an `ExternalAnalysisCache` of evaluated expression
values, keyed by each expression node's `SyntaxNodeIdentity`. A fresh tree
evaluates normally and fills the cache. On incremental reparse, the parser
records direct subtree reuses, the session builds a `ParseWitness`, forwards
cached entries for reused subtrees onto the new tree's identities, then evicts
entries from old tree versions.

The evaluator also uses a `SyntaxMetadataStore` during the most recent
evaluation to annotate nodes with evaluation order and value kind. This is
single-pass metadata; the long-lived values live in `ExternalAnalysisCache`.

Try:

```text
calc> 1.5 + round(2)
3.5
calc> :edit 0..<3 2.5
- 1.5 + round(2)
+ 2.5 + round(2)
4.5
calc> :counters
queries=... hits=... reusedBytes=... evalNodes=3 evalHits=1
calc> :cached
...
```

The evaluator short-circuits cached parents, so a reused `round(2)` hit skips
its literal child during the actual evaluation. `:cached` still shows translated
descendant entries when they exist.
