// CalculatorParser.swift

import Cambium

struct CalculatorParser: ~Copyable {
    private static let prefixPrecedence = 3
    /// The kinds we consider for subtree reuse. Atomic prefix forms
    /// are safe to splice as-is — their identity does not depend on
    /// surrounding context. `binaryExpr` is *deliberately excluded*:
    /// a binary expression's precedence context is encoded by the
    /// caller's `minPrecedence`, not by the subtree itself, so
    /// splicing one in at the wrong precedence would silently change
    /// associativity.
    private static let reusableKinds: [CalculatorKind] = [
        .groupExpr, .roundCallExpr, .unaryExpr, .realExpr, .integerExpr,
    ]

    private var tokens: [LexedToken]
    private var currentIndex: Int
    private var builder: GreenTreeBuilder<CalculatorLanguage>
    private var diagnostics: [Diagnostic<CalculatorLanguage>]

    // Incremental-reuse inputs. The previous tree and edits come from
    // the surrounding session; the session also owns the
    // `IncrementalParseSession` so its counters aggregate across many
    // parses.
    private let previousTree: SharedSyntaxTree<CalculatorLanguage>?
    private let edits: [TextEdit]
    private let incremental: IncrementalParseSession<CalculatorLanguage>?

    init(
        input: String,
        builder: consuming GreenTreeBuilder<CalculatorLanguage>,
        previousTree: SharedSyntaxTree<CalculatorLanguage>?,
        edits: [TextEdit],
        incremental: IncrementalParseSession<CalculatorLanguage>?
    ) {
        self.tokens = CalculatorLexer(input: input).tokenize()
        self.currentIndex = 0
        self.builder = builder
        self.diagnostics = []
        self.previousTree = previousTree
        self.edits = edits
        self.incremental = incremental
    }
}
