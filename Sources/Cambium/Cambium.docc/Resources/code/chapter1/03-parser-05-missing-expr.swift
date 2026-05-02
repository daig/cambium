import Cambium

struct CalculatorParser: ~Copyable {
    private static let prefixPrecedence = 3

    private var tokens: [LexedToken]
    private var currentIndex: Int
    private var builder: GreenTreeBuilder<CalculatorLanguage>
    private var diagnostics: [Diagnostic<CalculatorLanguage>]

    init(input: String) {
        self.tokens = CalculatorLexer(input: input).tokenize()
        self.currentIndex = 0
        self.builder = GreenTreeBuilder<CalculatorLanguage>()
        self.diagnostics = []
    }

    mutating func parse() throws {
        builder.startNode(.root)
        try consumeTrivia()
        if current.kind == .eof {
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "expected expression"
            ))
            try builder.missingNode(.missing)
        } else {
            try parseExpression(minPrecedence: 0)
        }
        try consumeTrivia()
        try builder.finishNode()
    }

    consuming func finish() throws -> CalculatorParseResult {
        let result = try builder.finish()
        return CalculatorParseResult(
            tree: result.snapshot.makeSyntaxTree().intoShared(),
            diagnostics: diagnostics
        )
    }

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

        case .minus:
            builder.startNode(.unaryExpr)
            try builder.staticToken(.minus)
            advance()
            try parseExpression(minPrecedence: Self.prefixPrecedence)
            try builder.finishNode()

        case .leftParen:
            try parseGroup()

        case .round:
            try parseRoundCall()

        default:
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "expected expression"
            ))
            try builder.missingNode(.missing)
        }
    }

    private mutating func parseGroup() throws {
        builder.startNode(.groupExpr)
        try builder.staticToken(.leftParen)
        advance()
        try consumeTrivia()
        try parseExpression(minPrecedence: 0)
        try consumeTrivia()
        if current.kind == .rightParen {
            try builder.staticToken(.rightParen)
            advance()
        } else {
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "expected ')'"
            ))
            builder.missingToken(.rightParen)
        }
        try builder.finishNode()
    }

    private mutating func parseRoundCall() throws {
        builder.startNode(.roundCallExpr)
        try builder.staticToken(.round)
        advance()
        try consumeTrivia()
        if current.kind == .leftParen {
            try builder.staticToken(.leftParen)
            advance()
        } else {
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "expected '(' after round"
            ))
            builder.missingToken(.leftParen)
        }
        try consumeTrivia()
        try parseExpression(minPrecedence: 0)
        try consumeTrivia()
        if current.kind == .rightParen {
            try builder.staticToken(.rightParen)
            advance()
        } else {
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "expected ')'"
            ))
            builder.missingToken(.rightParen)
        }
        try builder.finishNode()
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

public struct CalculatorParseResult: Sendable {
    public let tree: SharedSyntaxTree<CalculatorLanguage>
    public let diagnostics: [Diagnostic<CalculatorLanguage>]
}

public func parseCalculator(_ input: String) throws -> CalculatorParseResult {
    var parser = CalculatorParser(input: input)
    try parser.parse()
    return try parser.finish()
}
