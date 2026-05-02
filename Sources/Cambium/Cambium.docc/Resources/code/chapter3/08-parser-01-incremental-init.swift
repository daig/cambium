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

    /// One-shot init for callers that don't need session-level state.
    init(input: String) {
        self.init(
            input: input,
            builder: GreenTreeBuilder<CalculatorLanguage>(),
            previousTree: nil,
            edits: [],
            incremental: nil
        )
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
        while current.kind != .eof {
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "unexpected token after expression"
            ))
            try parseUnexpectedTokenAsError()
            try consumeTrivia()
        }

        try builder.finishNode()
    }

    consuming func finish() throws -> CalculatorParseResult {
        let output = try finishBuild()
        let tree = output.build.snapshot.makeSyntaxTree().intoShared()
        return CalculatorParseResult(
            tree: tree,
            diagnostics: output.diagnostics
        )
    }

    consuming func finishBuild() throws -> CalculatorBuildOutput {
        let build = try builder.finish()
        return CalculatorBuildOutput(
            build: build,
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

        case .invalid:
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "invalid character '\(current.text)'"
            ))
            try parseUnexpectedTokenAsError()
            try builder.missingNode(.missing)

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

    private mutating func parseUnexpectedTokenAsError() throws {
        let checkpoint = builder.checkpoint()
        guard current.kind != .eof else { return }
        try builder.token(.invalid, text: current.text)
        advance()
        try builder.startNode(at: checkpoint, .error)
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

/// One-shot parse: convenient when callers do not need
/// session-level state (incremental reuse, evaluation caching).
public func parseCalculator(_ input: String) throws -> CalculatorParseResult {
    var parser = CalculatorParser(input: input)
    try parser.parse()
    return try parser.finish()
}
