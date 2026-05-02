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

    mutating func parse() throws {
        builder.startNode(.root)
        try consumeTrivia()
        try parsePrefix()
        try consumeTrivia()
        try builder.finishNode()
    }

    /// Drain the parser into a `SyntaxTree`. The `consuming` qualifier
    /// is what lets `builder.finish()` move out of the noncopyable
    /// `CalculatorParser` — Cambium's builder is `~Copyable` for the
    /// same reason.
    consuming func finish() throws -> SyntaxTree<CalculatorLanguage> {
        let result = try builder.finish()
        return result.snapshot.makeSyntaxTree()
    }

    private mutating func parsePrefix() throws {
        switch current.kind {
        case .number:
            builder.startNode(.integerExpr)
            try builder.token(.number, text: current.text)
            advance()
            try builder.finishNode()

        case .realNumber:
            builder.startNode(.realExpr)
            try builder.token(.realNumber, text: current.text)
            advance()
            try builder.finishNode()

        case .leftParen:
            builder.startNode(.groupExpr)
            try builder.staticToken(.leftParen)
            try consumeTrivia()
            try parsePrefix()
            try consumeTrivia()
            try builder.staticToken(.rightParen)
            advance()
            try builder.finishNode()

        default:
            return
        }
    }

    private mutating func consumeTrivia() throws {
        while current.kind == .whitespace {
            try builder.token(.whitespace, text: current.text)
            advance()
        }
    }

    @discardableResult
    private mutating func advance() -> LexedToken {
        let token = current
        if token.kind != .eof {
            currentIndex += 1
        }
        return token
    }

    private var current: LexedToken {
        tokens[currentIndex]
    }
}

/// One-shot parse: convenient when callers do not need session-level
/// state (incremental reuse, evaluation caching, fold). Returns a
/// `~Copyable` `SyntaxTree` — promote it to `SharedSyntaxTree` if you
/// need to publish it across actors or store it long-term.
public func parseCalculator(_ input: String) throws -> SyntaxTree<CalculatorLanguage> {
    var parser = CalculatorParser(input: input)
    try parser.parse()
    return try parser.finish()
}
