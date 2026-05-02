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
        try parsePrefix()
        try builder.finishNode()
    }

    private mutating func parsePrefix() throws {
        switch current.kind {
        case .number:
            builder.startNode(.integerExpr)
            try builder.token(.number, text: current.text)
            advance()
            try builder.finishNode()
        default:
            return
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
