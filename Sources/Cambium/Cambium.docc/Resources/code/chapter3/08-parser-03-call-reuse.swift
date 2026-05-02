// CalculatorParser.swift

import Cambium

extension CalculatorParser {
    /// Modified `parsePrefix()`: try to reuse a subtree from the
    /// previous parse before doing fresh work. The reuse path is the
    /// only thing that changed.
    private mutating func parsePrefix() throws {
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
        let checkpoint = builder.checkpoint()
        switch current.kind {
        case .number:
            advance()
            try builder.startNode(at: checkpoint, .integerExpr)
            try builder.finishNode()

        // ... `.realNumber`, `.minus`, `.leftParen`, `.round`, default cases unchanged from Chapter 1 ...
        default:
            return
        }
    }
}
