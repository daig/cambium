// Calculator.swift — orientation file
//
// `CalculatorCore` is a Swift example library demonstrating how to build
// a real language on top of Cambium's CST primitives. Each file in this
// target is focused on one Cambium subsystem; this file is the entry
// point and a map.
//
// # Layout
//
// **Defining a language**
//
// - `CalculatorLanguage.swift` — the `SyntaxLanguage` conformance plus
//   the `@CambiumSyntaxKind`-derived `CalculatorKind` enum, including
//   `@StaticText` annotations for operator/punctuation tokens.
//
// **Lexing and parsing (build phase)**
//
// - `CalculatorLexer.swift` — pure tokenizer; no Cambium APIs.
// - `CalculatorParser.swift` — recursive-descent parser driving
//   `GreenTreeBuilder`. Demonstrates checkpoint-based retroactive
//   wrapping, missing/error nodes, and incremental subtree reuse via
//   `ReuseOracle`.
//
// **Reading the tree**
//
// - `CalculatorParseResult.swift` — public result type. Owned-handle
//   helpers (`expressionHandles`, `tokenHandles(in:)`) demonstrate
//   `CambiumOwnedTraversal`. The `sourceContains` /
//   `sourceFirstRange(of:)` / `sourceSlice(_:)` / `sourceFNV1a()`
//   methods plus the private `FNV1aHasher` demonstrate `SyntaxText` and
//   `UTF8Sink`.
// - `CalculatorTypedAST.swift` — typed AST overlays via
//   `TypedSyntaxNode` and the `@CambiumSyntaxNode` macro.
// - `CalculatorEvaluator.swift` — recursive evaluator over the typed
//   AST. Demonstrates `ExternalAnalysisCache` / `SyntaxMetadataStore`
//   for per-node analysis sidecar data, and `withTextUTF8` for byte-
//   level literal parsing.
// - `CalculatorDebugDump.swift` — tree and AST pretty-printers.
//
// **Long-lived parsing state**
//
// - `CalculatorSession.swift` — `GreenNodeCache` forwarding via
//   `intoCache()`, `IncrementalParseSession` counters, `ParseWitness`
//   construction, and the cross-version evaluation-cache translation
//   that's the payoff for both `ParseWitness` and `ReplacementWitness`.
//
// **Editing trees**
//
// - `CalculatorFold.swift` — constant folding via
//   `SharedSyntaxTree.replacing(_:with:cache:)`, demonstrating
//   `ReplacementWitness.classify(path:)` for cross-version reference
//   translation.
//
// **Value, error, and formatting types**
//
// - `CalculatorValue.swift` — language-level value, error, and
//   diagnostic types.
// - `CalculatorFormat.swift` — small text-range and diagnostic
//   formatters used everywhere.
//
// The REPL in `Sources/CalculatorREPL/` is the manual test surface; run
// `swift run calc-repl` and use `:help` for the command list.

import Cambium

/// One-shot parse: the convenient entry point for callers that don't
/// need session-level state (incremental reuse, evaluation caching,
/// fold). For long-lived editing scenarios use `CalculatorSession`.
public func parseCalculator(_ input: String) throws -> CalculatorParseResult {
    var parser = CalculatorParser(input: input)
    try parser.parse()
    return try parser.finish()
}
