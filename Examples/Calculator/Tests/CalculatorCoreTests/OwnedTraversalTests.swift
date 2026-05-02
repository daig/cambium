import CalculatorCore
import Cambium
import Testing

@Test func parseResultExpressionHandlesAreOwnedPreorderSnapshot() throws {
    let parsed = try parseCalculator("1 + round(2.5)")
    #expect(parsed.diagnostics.isEmpty)

    let descriptions = parsed.expressionHandles.map { handle in
        handle.withCursor { node in
            "\(CalculatorLanguage.name(for: node.kind)) \(format(node.textRange)) \"\(node.makeString())\""
        }
    }

    #expect(descriptions == [
        "binaryExpr 0..<14 \"1 + round(2.5)\"",
        "integerExpr 0..<1 \"1\"",
        "roundCallExpr 4..<14 \"round(2.5)\"",
        "realExpr 10..<13 \"2.5\"",
    ])
}

@Test func parseResultTokenHandlesIncludeTriviaAndStaticTokens() throws {
    let parsed = try parseCalculator("1 + round(2.5)")
    #expect(parsed.diagnostics.isEmpty)

    let descriptions = parsed.tokenHandles().map { handle in
        handle.withCursor { token in
            "\(CalculatorLanguage.name(for: token.kind)) \(format(token.textRange)) \"\(token.makeString())\""
        }
    }

    #expect(descriptions == [
        "number 0..<1 \"1\"",
        "whitespace 1..<2 \" \"",
        "plus 2..<3 \"+\"",
        "whitespace 3..<4 \" \"",
        "round 4..<9 \"round\"",
        "leftParen 9..<10 \"(\"",
        "realNumber 10..<13 \"2.5\"",
        "rightParen 13..<14 \")\"",
    ])
}

@Test func parseResultTokenHandlesCanFilterByByteRange() throws {
    let parsed = try parseCalculator("1 + round(2.5)")
    #expect(parsed.diagnostics.isEmpty)

    let range = TextRange(start: TextSize(4), end: TextSize(10))
    let descriptions = parsed.tokenHandles(in: range).map { handle in
        handle.withCursor { token in
            "\(CalculatorLanguage.name(for: token.kind)) \(format(token.textRange)) \"\(token.makeString())\""
        }
    }

    #expect(descriptions == [
        "round 4..<9 \"round\"",
        "leftParen 9..<10 \"(\"",
    ])
}
