// CalculatorParser.swift

import Cambium

/// Bundles the noncopyable build result with the diagnostics array.
/// Swift tuples cannot yet hold `~Copyable` elements, so this struct
/// fills the same role.
struct CalculatorBuildOutput: ~Copyable {
    var build: GreenBuildResult<CalculatorLanguage>
    var diagnostics: [Diagnostic<CalculatorLanguage>]
}

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

    fileprivate mutating func parsePrefix() throws {
        try consumeTrivia()

        // Reuse attempt comes first — if it succeeds, the lexer has
        // already been advanced past the spliced subtree's bytes
        // and the relevant `startNode` / `finishNode` calls have
        // already happened inside `reuseSubtree`.
        if try tryReusePrefix(at: TextSize(UInt32(current.byteOffset))) {
            return
        }

        // Otherwise, fall through to the from-scratch parser exactly
        // as in Chapter 1.
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

    fileprivate mutating func consumeTrivia() throws {
        while current.kind == .whitespace {
            try builder.token(.whitespace, text: current.text)
            advance()
        }
    }

    @discardableResult
    fileprivate mutating func advance() -> LexedToken {
        let token = current
        if token.kind != .eof {
            currentIndex += 1
        }
        return token
    }

    fileprivate var current: LexedToken {
        tokens[currentIndex]
    }
}

extension CalculatorParser {
    /// Try to splice an unchanged subtree from the previous parse at
    /// the parser's current source offset. Returns `true` when a
    /// subtree was reused (and the lexer was advanced past its
    /// bytes), `false` otherwise.
    mutating func tryReusePrefix(at newOffset: TextSize) throws -> Bool {
        guard let previousTree else { return false }

        // The parser walks NEW-source coordinates. The reuse oracle
        // walks OLD-tree coordinates. `mapNewOffsetToOld` translates
        // by replaying the edits.
        guard let oldOffset = Self.mapNewOffsetToOld(newOffset, edits: edits) else {
            return false
        }

        // The oracle is `~Copyable`, so we mint one locally inside
        // each prefix attempt. The session reference (carried inside
        // the oracle) is what aggregates counters across attempts.
        let oracle = ReuseOracle<CalculatorLanguage>(
            previousTree: previousTree,
            edits: edits,
            session: incremental
        )

        for kind in Self.reusableKinds {
            if try attemptReuse(
                oracle: oracle,
                oldOffset: oldOffset,
                newOffset: newOffset,
                kind: kind
            ) {
                return true
            }
        }
        return false
    }

    private mutating func attemptReuse(
        oracle: borrowing ReuseOracle<CalculatorLanguage>,
        oldOffset: TextSize,
        newOffset: TextSize,
        kind: CalculatorKind
    ) throws -> Bool {
        var spliced = false
        try oracle.withReusableNode(startingAt: oldOffset, kind: kind) { cursor in
            // Cambium hands the closure a borrowed cursor on the
            // candidate subtree from the *previous* tree. The
            // closure decides whether the splice is safe; here we
            // verify byte-length alignment in the new lexer, then
            // splice via `reuseSubtree`.
            guard let tokenCount = tokenCountMatching(text: cursor.makeString()) else {
                return
            }
            let outcome = try builder.reuseSubtree(cursor)
            // `outcome` is `.direct` (namespaces matched, no
            // remapping) or `.remapped` (dynamic tokens were re-
            // interned into the new namespace). Both produce a
            // structurally-equivalent subtree.
            _ = outcome
            skipTokens(count: tokenCount)
            spliced = true
        }
        return spliced
    }

    private func tokenCountMatching(text: String) -> Int? {
        var consumed = ""
        var index = currentIndex
        let expectedLength = text.utf8.count
        while index < tokens.count, consumed.utf8.count < expectedLength {
            let token = tokens[index]
            if token.kind == .eof { return nil }
            consumed += token.text
            index += 1
        }
        return consumed == text ? index - currentIndex : nil
    }

    private mutating func skipTokens(count: Int) {
        for _ in 0..<count where tokens[currentIndex].kind != .eof {
            currentIndex += 1
        }
    }

    /// Translate a NEW-source byte offset into OLD-tree coordinates.
    /// `edits` are non-overlapping and sorted by start in OLD coords
    /// per the ``CambiumIncremental/ParseInput`` contract. Returns
    /// `nil` if the new offset falls inside an edit's replacement
    /// region — there is no corresponding old offset.
    static func mapNewOffsetToOld(
        _ newOffset: TextSize,
        edits: [TextEdit]
    ) -> TextSize? {
        var shift: Int64 = 0
        let newOff = Int64(newOffset.rawValue)
        for edit in edits {
            let oldStart = Int64(edit.range.start.rawValue)
            let oldEnd = Int64(edit.range.end.rawValue)
            let oldLen = oldEnd - oldStart
            let newLen = Int64(edit.replacementLength.rawValue)
            let newStart = oldStart + shift
            let newEnd = newStart + newLen
            if newOff >= newStart, newOff < newEnd { return nil }
            if newOff >= newEnd { shift += (newLen - oldLen) }
        }
        let oldOff = newOff - shift
        guard oldOff >= 0, oldOff <= Int64(UInt32.max) else { return nil }
        return TextSize(UInt32(oldOff))
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
