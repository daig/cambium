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

- `:tree` toggles CST dumps.
- `:ast` toggles typed AST dumps.
- `:fold` constant-folds the current document one replacement at a time and
  prints each `ReplacementWitness` classification demo.
- `:help` prints commands.
- `:q` or `:quit` exits.
