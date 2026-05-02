# Calculator

A complete end-to-end example using Cambium to parse, traverse, edit,
and evaluate a small arithmetic language.

@Metadata {
    @PageKind(sampleCode)
    @CallToAction(
        url: "https://github.com/daig/cambium/tree/main/Examples/Calculator",
        purpose: link,
        label: "View Sample on GitHub"
    )
}

## Overview

The Calculator sample is a standalone SwiftPM package that exercises
Cambium's full public surface against a real grammar. It ships as a
library (`CalculatorCore`) plus an interactive REPL (`calc-repl`) so the
same pieces can be unit-tested and poked at by hand.

> Tip: For a step-by-step walkthrough that builds the calculator one
> Cambium subsystem at a time, see <doc:tutorials/TableOfContents>. The
> tutorials use the same source files documented here as their
> canonical implementation.

The grammar covers integer and real literals, parenthesized
sub-expressions, unary minus, the `round(expr)` built-in, and the four
arithmetic operators with normal precedence. The parser preserves input
text losslessly, recovers from malformed input by emitting missing and
error nodes, and only evaluates trees with no parse diagnostics.

## What it covers

The sample is organized to demonstrate one Cambium concept per source
file, so each topic in the Cambium documentation has a concrete
counterpart you can read, build, and modify.

- **Defining a language.** `CalculatorLanguage.swift` derives a
  ``CambiumCore/SyntaxLanguage`` conformance from a `UInt32`-backed enum
  using `@CambiumSyntaxKind` and `@StaticText`.
- **Lexing.** `CalculatorLexer.swift` produces tokens with byte offsets
  for the parser to feed into a ``CambiumBuilder/GreenTreeBuilder``.
- **Recursive-descent CST construction.** `CalculatorParser.swift`
  uses checkpoints (``CambiumBuilder/GreenTreeBuilder/checkpoint()`` /
  ``CambiumBuilder/GreenTreeBuilder/startNode(at:_:)``) for left-associative
  operator precedence, and emits missing/error nodes for recovery.
- **A typed AST overlay.** `CalculatorTypedAST.swift` defines one
  ``CambiumASTSupport/TypedSyntaxNode`` per AST shape and exposes
  kind-specific accessors over the generic CST.
- **Borrowed traversal.** `CalculatorEvaluator.swift` walks the typed
  AST through borrowed cursors with no per-node allocation.
- **Owned handles.** `CalculatorParseResult.swift` materializes long-lived
  ``CambiumCore/SyntaxNodeHandle`` and ``CambiumCore/SyntaxTokenHandle`` arrays
  for the `:nodes` and `:tokens` REPL commands.
- **Incremental reparse.** `CalculatorParser.swift` consults a
  ``CambiumIncremental/ReuseOracle`` to splice unchanged subtrees from the
  previous tree; `CalculatorSession.swift` builds a
  ``CambiumIncremental/ParseWitness`` and forwards cached evaluator entries
  across edits.
- **Replacement and witnesses.** `CalculatorFold.swift` constant-folds
  one node at a time using `SharedSyntaxTree.replacing(_:with:context:)`
  and classifies references through ``CambiumCore/ReplacementWitness``.
- **Analysis sidecars.** `CalculatorSession.swift` keeps an
  ``CambiumAnalysis/ExternalAnalysisCache`` of evaluated values and a
  ``CambiumAnalysis/SyntaxMetadataStore`` of per-evaluation metadata.
- **Serialization.** `CalculatorSession.swift` round-trips the current
  tree through ``CambiumSerialization/GreenSnapshotDecoder`` and
  `serializeGreenSnapshot()` for the `:save` / `:load` commands.
- **Sharing across tasks.** `CalculatorParallelEvaluator.swift` uses a
  ``CambiumCore/SharedSyntaxTree`` with a structured-concurrent fork/join
  evaluator that shares an ``CambiumAnalysis/ExternalAnalysisCache`` and a
  ``CambiumAnalysis/SyntaxMetadataStore`` across tasks.
- **Parallel parsing.** `CalculatorParallelParser.swift` shows a parser
  variant that splits work across child tasks while preserving the
  same lossless CST output.

## Running it

Clone the repository and run the REPL:

```sh
git clone https://github.com/daig/cambium.git
cd cambium/Examples/Calculator
swift run calc-repl
```

The REPL accepts arithmetic expressions as input and exposes the
sample's behavior through colon-prefixed commands (`:tree`, `:ast`,
`:edit`, `:fold`, `:peval`, `:save`, `:load`, …). Type `:help` at the
prompt for the full list. The example's `README.md` walks through each
command with sample sessions.

## Reading order

If you are new to Cambium, read the files in roughly this order — each
one builds on the concepts established in <doc:GettingStarted>:

1. `CalculatorLanguage.swift` — the kind enum and language conformance.
2. `CalculatorLexer.swift` — token source for the parser.
3. `CalculatorParser.swift` — green-tree construction with checkpoints
   and error recovery.
4. `CalculatorTypedAST.swift` — typed overlay on top of the CST.
5. `CalculatorEvaluator.swift` — borrowed traversal of the typed AST.
6. `CalculatorSession.swift` — wiring incremental reparse, the analysis
   cache, and serialization together for the REPL.
7. `CalculatorFold.swift` — replacement witnesses and persistent edits.
8. `CalculatorParallelEvaluator.swift` and
   `CalculatorParallelParser.swift` — sharing trees across structured
   concurrency.

## Topics

### Concepts demonstrated

- <doc:GettingStarted>
- <doc:tutorials/TableOfContents>
- <doc:ExternalizedInterning>
