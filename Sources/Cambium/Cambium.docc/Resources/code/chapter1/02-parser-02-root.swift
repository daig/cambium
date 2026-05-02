// CalculatorParser.swift

import Cambium

struct CalculatorParser: ~Copyable {
    private var tokens: [LexedToken]
    private var currentIndex: Int
    private var builder: GreenTreeBuilder<CalculatorLanguage>

    init(input: String) {
        self.tokens = CalculatorLexer(input: input).tokenize()
        self.currentIndex = 0
        self.builder = GreenTreeBuilder<CalculatorLanguage>()
    }

    /// Open the root, parse one expression, close the root. Every parse
    /// is bracketed by exactly one matched `startNode` / `finishNode`
    /// pair on the root kind — Cambium would reject an unmatched stack.
    mutating func parse() throws {
        builder.startNode(.root)
        try parsePrefix()
        try builder.finishNode()
    }

    private mutating func parsePrefix() throws {
        // Filled in by the next steps.
    }

    private var current: LexedToken {
        tokens[currentIndex]
    }
}
