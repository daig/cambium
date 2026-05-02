import Cambium

/// Bundles the noncopyable build result with the diagnostics array. Used as
/// the return type of `CalculatorParser.finishBuild()` because Swift tuples
/// cannot yet contain `~Copyable` elements.
struct CalculatorBuildOutput: ~Copyable {
    var build: GreenBuildResult<CalculatorLanguage>
    var diagnostics: [Diagnostic<CalculatorLanguage>]
    var acceptedReuses: [CalculatorAcceptedReuse]
}

struct CalculatorAcceptedReuse: Sendable {
    var oldPath: SyntaxNodePath
    var green: GreenNode<CalculatorLanguage>
    var newOffset: TextSize
}

struct CalculatorParser: ~Copyable {
    private static let prefixPrecedence = 3
    private static let reusableKinds: [CalculatorKind] = [
        // Order: try the largest structurally-self-contained kind first so we
        // splice the biggest unchanged piece available. Atomic prefix kinds
        // only — see `tryReusePrefix(at:)` for why `.binaryExpr` is excluded.
        .groupExpr,
        .roundCallExpr,
        .unaryExpr,
        .realExpr,
        .integerExpr,
    ]

    private var tokens: [LexedToken]
    private var currentIndex: Int
    private var builder: GreenTreeBuilder<CalculatorLanguage>
    private var diagnostics: [Diagnostic<CalculatorLanguage>]
    private var acceptedReuses: [CalculatorAcceptedReuse]

    // Incremental-reuse state. We don't store a `ReuseOracle` directly because
    // it is `~Copyable`; instead we keep its inputs and construct a fresh
    // oracle inside `tryReusePrefix(at:)`. The oracle is a thin wrapper, and
    // counters live on `incremental` (which the oracle borrows by reference).
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
        self.acceptedReuses = []
        self.previousTree = previousTree
        self.edits = edits
        self.incremental = incremental
    }

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
                message: "unexpected \(current.displayName) after expression"
            ))
            try parseUnexpectedTokenAsError()
            try consumeTrivia()
        }

        try builder.finishNode()
    }

    consuming func finish() throws -> CalculatorParseResult {
        let output = try finishBuild()
        let tree = output.build.snapshot.makeSyntaxTree().intoShared()
        return CalculatorParseResult(tree: tree, diagnostics: output.diagnostics)
    }

    consuming func finishBuild() throws -> CalculatorBuildOutput {
        let build = try builder.finish()
        return CalculatorBuildOutput(
            build: build,
            diagnostics: diagnostics,
            acceptedReuses: acceptedReuses
        )
    }

    private var current: LexedToken {
        tokens[currentIndex]
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

            _ = try advance()
            try builder.startNode(at: checkpoint, .binaryExpr)
            try parseExpression(minPrecedence: precedence + 1)
            try builder.finishNode()
        }
    }

    private mutating func parsePrefix() throws {
        try consumeTrivia()

        if try tryReusePrefix(at: TextSize(UInt32(current.byteOffset))) {
            return
        }

        let checkpoint = builder.checkpoint()

        switch current.kind {
        case .number:
            _ = try advance()
            try builder.startNode(at: checkpoint, .integerExpr)
            try builder.finishNode()

        case .realNumber:
            _ = try advance()
            try builder.startNode(at: checkpoint, .realExpr)
            try builder.finishNode()

        case .minus:
            _ = try advance()
            try builder.startNode(at: checkpoint, .unaryExpr)
            try parseExpression(minPrecedence: Self.prefixPrecedence)
            try builder.finishNode()

        case .leftParen:
            _ = try advance()
            try builder.startNode(at: checkpoint, .groupExpr)
            try parseExpression(minPrecedence: 0)
            try consumeTrivia()
            if current.kind == .rightParen {
                _ = try advance()
            } else {
                diagnostics.append(Diagnostic(
                    range: current.range,
                    message: "expected ')'"
                ))
                builder.missingToken(.rightParen)
            }
            try builder.finishNode()

        case .round:
            try parseRoundCall(at: checkpoint)

        default:
            try parseMissingExpression(at: checkpoint)
        }
    }

    private mutating func parseRoundCall(at checkpoint: BuilderCheckpoint) throws {
        _ = try advance()
        try builder.startNode(at: checkpoint, .roundCallExpr)

        try consumeTrivia()
        if current.kind == .leftParen {
            _ = try advance()
        } else {
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "expected '(' after round"
            ))
            builder.missingToken(.leftParen)
        }

        try consumeTrivia()
        if current.kind == .rightParen || current.kind == .eof {
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "expected expression"
            ))
            try builder.missingNode(.missing)
        } else {
            try parseExpression(minPrecedence: 0)
        }

        try consumeTrivia()
        if current.kind == .rightParen {
            _ = try advance()
        } else {
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "expected ')'"
            ))
            builder.missingToken(.rightParen)
        }

        try builder.finishNode()
    }

    private mutating func parseMissingExpression(at checkpoint: BuilderCheckpoint) throws {
        switch current.kind {
        case .invalid:
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "invalid character '\(current.text)'"
            ))
            try parseUnexpectedTokenAsError(at: checkpoint)

        case .eof, .rightParen:
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "expected expression"
            ))

        default:
            diagnostics.append(Diagnostic(
                range: current.range,
                message: "expected expression before \(current.displayName)"
            ))
            try parseUnexpectedTokenAsError(at: checkpoint)
        }

        try builder.missingNode(.missing)
    }

    private mutating func parseUnexpectedTokenAsError() throws {
        let checkpoint = builder.checkpoint()
        try parseUnexpectedTokenAsError(at: checkpoint)
    }

    private mutating func parseUnexpectedTokenAsError(at checkpoint: BuilderCheckpoint) throws {
        guard current.kind != .eof else {
            return
        }

        _ = try advance()
        try builder.startNode(at: checkpoint, .error)
        try builder.finishNode()
    }

    private mutating func consumeTrivia() throws {
        while current.kind == .whitespace {
            _ = try advance()
        }
    }

    @discardableResult
    private mutating func advance() throws -> LexedToken {
        let token = current
        if token.kind != .eof {
            currentIndex += 1
        }
        try append(token)
        return token
    }

    private mutating func append(_ token: LexedToken) throws {
        switch token.kind {
        case .number:
            try builder.token(.number, text: token.text)
        case .realNumber:
            try builder.token(.realNumber, text: token.text)
        case .whitespace:
            try builder.token(.whitespace, text: token.text)
        case .plus:
            try builder.staticToken(.plus)
        case .minus:
            try builder.staticToken(.minus)
        case .star:
            try builder.staticToken(.star)
        case .slash:
            try builder.staticToken(.slash)
        case .leftParen:
            try builder.staticToken(.leftParen)
        case .rightParen:
            try builder.staticToken(.rightParen)
        case .round:
            try builder.staticToken(.round)
        case .invalid:
            try builder.token(.invalid, text: token.text)
        case .eof:
            break
        }
    }

    // MARK: - Incremental reuse

    /// Try to splice an unchanged subtree from the previous parse at the
    /// parser's current source offset. Returns `true` if a subtree was reused
    /// (and the lexer was advanced past its bytes), `false` otherwise.
    ///
    /// We only attempt reuse for self-bounded prefix kinds (atomic literals,
    /// unary, parenthesized groups, `round(...)` calls). `binaryExpr` is
    /// deliberately excluded because its precedence context is encoded by
    /// the caller's `minPrecedence`, not by the subtree itself; splicing one
    /// in at the wrong precedence would silently change associativity.
    private mutating func tryReusePrefix(at newOffset: TextSize) throws -> Bool {
        guard let previousTree else {
            return false
        }
        guard let oldOffset = Self.mapNewOffsetToOld(newOffset, edits: edits) else {
            return false
        }

        // Build a fresh oracle locally; it's a thin wrapper over previousTree
        // and edits, and counters live on the session reference. Storing the
        // oracle on `self` would create exclusive-access conflicts with
        // mutating builder calls inside its closure.
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
            // Only reuse clean subtrees. Sentinels would propagate stale
            // diagnostics into a region that may now parse cleanly.
            if Self.subtreeContainsSentinels(cursor) {
                return
            }
            // Verify token alignment and identity in the new source. A full
            // document replacement may still have same-length tokens at the
            // same offset, but that is not an unchanged subtree.
            guard let tokenCount = tokenCountMatching(text: cursor.makeString()) else {
                return
            }
            let outcome = try builder.reuseSubtree(cursor)
            skipTokens(count: tokenCount)
            recordAcceptedReuse(cursor: cursor, outcome: outcome, newOffset: newOffset)
            spliced = true
        }
        return spliced
    }

    private mutating func recordAcceptedReuse(
        cursor: borrowing SyntaxNodeCursor<CalculatorLanguage>,
        outcome: SubtreeReuseOutcome,
        newOffset: TextSize
    ) {
        guard outcome == .direct else {
            return
        }
        let oldPath = cursor.childIndexPath()
        let green = cursor.green { $0 }
        acceptedReuses.append(CalculatorAcceptedReuse(
            oldPath: oldPath,
            green: green,
            newOffset: newOffset
        ))
    }

    private static func subtreeContainsSentinels(
        _ cursor: borrowing SyntaxNodeCursor<CalculatorLanguage>
    ) -> Bool {
        var hasSentinel = false
        _ = cursor.visitPreorder { node in
            if node.kind == .missing || node.kind == .error {
                hasSentinel = true
                return .stop
            }
            return .continue
        }
        return hasSentinel
    }

    /// Returns the number of new-source lexer tokens (starting at
    /// `currentIndex`) whose concatenated text exactly matches `text`, or
    /// `nil` if the candidate would split a token or no longer represents the
    /// same source text.
    private func tokenCountMatching(text: String) -> Int? {
        var consumed = ""
        var index = currentIndex
        let expectedLength = text.utf8.count

        while index < tokens.count, consumed.utf8.count < expectedLength {
            let token = tokens[index]
            if token.kind == .eof {
                return nil
            }
            consumed += token.text
            index += 1
        }
        guard consumed == text else {
            return nil
        }
        return index - currentIndex
    }

    /// Advance past `count` lexer tokens without appending them to the
    /// builder. Used after a successful subtree splice — the tokens are
    /// already inside the spliced green subtree.
    private mutating func skipTokens(count: Int) {
        for _ in 0..<count {
            if tokens[currentIndex].kind != .eof {
                currentIndex += 1
            }
        }
    }

    /// Translate a NEW-source byte offset into OLD-tree coordinates, walking
    /// `edits` (which are non-overlapping and sorted by start in OLD coords
    /// per the `ParseInput` contract). Returns `nil` if the new offset falls
    /// inside an edit's replacement region (no corresponding old offset).
    private static func mapNewOffsetToOld(
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

            if newOff >= newStart, newOff < newEnd {
                return nil
            }
            if newOff >= newEnd {
                shift += (newLen - oldLen)
            }
        }

        let oldOff = newOff - shift
        guard oldOff >= 0, oldOff <= Int64(UInt32.max) else {
            return nil
        }
        return TextSize(UInt32(oldOff))
    }
}

private extension LexedToken {
    var calculatorKind: CalculatorKind? {
        switch kind {
        case .number:
            .number
        case .realNumber:
            .realNumber
        case .whitespace:
            .whitespace
        case .plus:
            .plus
        case .minus:
            .minus
        case .star:
            .star
        case .slash:
            .slash
        case .leftParen:
            .leftParen
        case .rightParen:
            .rightParen
        case .round:
            .round
        case .invalid:
            .invalid
        case .eof:
            nil
        }
    }
}
