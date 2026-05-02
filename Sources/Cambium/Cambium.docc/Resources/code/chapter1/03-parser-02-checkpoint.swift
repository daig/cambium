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
        // Replace the bare `parsePrefix()` call with a precedence-aware
        // expression parser. `minPrecedence: 0` accepts any operator.
        try parseExpression(minPrecedence: 0)
        try consumeTrivia()
        try builder.finishNode()
    }

    consuming func finish() throws -> SyntaxTree<CalculatorLanguage> {
        let result = try builder.finish()
        return result.snapshot.makeSyntaxTree()
    }

    /// Pratt-style precedence climbing.
    ///
    /// 1. Record the builder position with `checkpoint()` *before*
    ///    parsing the left-hand side.
    /// 2. Parse the prefix.
    /// 3. While the next token is a binary operator whose precedence
    ///    meets `minPrecedence`, retroactively wrap everything since
    ///    the checkpoint inside a `binaryExpr` and recurse for the
    ///    right operand at higher precedence.
    private mutating func parseExpression(minPrecedence: Int) throws {
        let checkpoint = builder.checkpoint()
        try parsePrefix()

        while true {
            try consumeTrivia()
            guard let precedence = current.calculatorKind?.binaryPrecedence,
                  precedence >= minPrecedence
            else {
                return
            }

            advance()
            // `startNode(at:_:)` is the retroactive open: it looks up
            // the children appended since `checkpoint` and reparents
            // them under a fresh `binaryExpr` frame.
            try builder.startNode(at: checkpoint, .binaryExpr)
            try parseExpression(minPrecedence: precedence + 1)
            try builder.finishNode()
        }
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
            // The inner of a group is a full expression — recurse via
            // `parseExpression` so `(1 + 2)` works.
            try parseExpression(minPrecedence: 0)
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

private extension LexedToken {
    /// Map a `LexedToken` back to its `CalculatorKind` so we can read
    /// `binaryPrecedence`. Returns `nil` for kinds that are not also
    /// represented in the language enum (only `.eof`).
    var calculatorKind: CalculatorKind? {
        switch kind {
        case .number: .number
        case .realNumber: .realNumber
        case .whitespace: .whitespace
        case .plus: .plus
        case .minus: .minus
        case .star: .star
        case .slash: .slash
        case .leftParen: .leftParen
        case .rightParen: .rightParen
        case .round: .round
        case .invalid: .invalid
        case .eof: nil
        }
    }
}

public func parseCalculator(_ input: String) throws -> SyntaxTree<CalculatorLanguage> {
    var parser = CalculatorParser(input: input)
    try parser.parse()
    return try parser.finish()
}
