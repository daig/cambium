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
        []
    }
}
