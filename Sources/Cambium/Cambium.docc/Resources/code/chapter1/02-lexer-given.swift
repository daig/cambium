// CalculatorLexer.swift
//
// A pre-built tokenizer. The lexer is intentionally not a focus of this
// tutorial: it converts UTF-8 input into a flat stream of token kinds
// with byte offsets, and does not touch any Cambium API. The parser in
// the following sections consumes its output token-by-token.

import Cambium

enum LexedTokenKind: Sendable, Equatable {
    case number, realNumber, whitespace
    case plus, minus, star, slash
    case leftParen, rightParen, round
    case invalid, eof
}

struct LexedToken: Sendable, Equatable {
    var kind: LexedTokenKind
    var text: String
    var byteOffset: Int
    var byteLength: Int

    var range: TextRange {
        TextRange(
            start: TextSize(rawValue: UInt32(byteOffset)),
            length: TextSize(rawValue: UInt32(byteLength))
        )
    }
}

struct CalculatorLexer {
    var input: String

    /// Tokenize `input`, always appending a trailing `.eof` so the parser
    /// can rely on a sentinel.
    func tokenize() -> [LexedToken] {
        // ... ASCII-only scanner; emits `.number` / `.realNumber`,
        // `.whitespace`, the static-text operators / parens, and the
        // `round` keyword. Returns one `.invalid` token per unrecognized
        // byte so the parser can wrap it in an `error` node.
        []
    }
}
