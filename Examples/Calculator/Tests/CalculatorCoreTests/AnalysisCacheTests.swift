import CalculatorCore
import Cambium
import Testing

@Test func sessionEvaluationPopulatesAndHitsCache() throws {
    let session = CalculatorSession()
    let parsed = try session.parse("1 + 2 * 3")
    #expect(parsed.diagnostics.isEmpty)

    #expect(try session.evaluate() == .integer(7))
    #expect(session.evaluationStats.evalNodes == 5)
    #expect(session.evaluationStats.evalHits == 0)
    #expect(!session.cachedValues().isEmpty)

    #expect(try session.evaluate() == .integer(7))
    #expect(session.evaluationStats.evalNodes == 1)
    #expect(session.evaluationStats.evalHits == 1)
}

@Test func reparseTranslatesEvaluationCacheThroughAcceptedReuse() throws {
    let session = CalculatorSession()
    let parsed = try session.parse("1.5 + round(2)")
    #expect(parsed.diagnostics.isEmpty)
    #expect(try session.evaluate() == .real(3.5))

    let edit = TextEdit(
        range: TextRange(start: TextSize(0), end: TextSize(3)),
        replacement: "2.5"
    )
    let reparsed = try session.parse("2.5 + round(2)", edits: [edit])
    #expect(reparsed.diagnostics.isEmpty)

    let translated = session.cachedValues()
    #expect(translated.contains { cached in
        cached.range == TextRange(start: TextSize(6), end: TextSize(14))
            && cached.value == .integer(2)
    })
    #expect(translated.contains { cached in
        cached.range == TextRange(start: TextSize(12), end: TextSize(13))
            && cached.value == .integer(2)
    })

    #expect(try session.evaluate() == .real(4.5))
    #expect(session.evaluationStats == CalculatorEvaluationStats(evalNodes: 3, evalHits: 1))

    let cachedAfterEvaluation = session.cachedValues()
    #expect(cachedAfterEvaluation.contains { cached in
        cached.range == TextRange(start: TextSize(6), end: TextSize(14))
            && cached.evaluationOrder != nil
            && cached.valueKind == .integer
    })
}

@Test func resetAdoptAndFoldClearOrTranslateEvaluationCache() throws {
    let session = CalculatorSession()
    _ = try session.parse("1 + 2")
    #expect(try session.evaluate() == .integer(3))
    #expect(!session.cachedValues().isEmpty)

    session.reset()
    #expect(session.cachedValues().isEmpty)
    #expect(session.evaluationStats == CalculatorEvaluationStats())

    let decoded = try parseCalculator("3 + 4").tree
    session.adopt(decoded)
    #expect(session.cachedValues().isEmpty)

    _ = try session.parse("1 + 2 * 3")
    #expect(try session.evaluate() == .integer(7))
    let report = try session.fold()
    #expect(report.finalSource == "7")

    #expect(try session.evaluate() == .integer(7))
    #expect(session.evaluationStats == CalculatorEvaluationStats(evalNodes: 1, evalHits: 1))
}
