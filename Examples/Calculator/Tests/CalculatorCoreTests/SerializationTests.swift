import CalculatorCore
import Cambium
import Testing

@Test func serializedSnapshotRoundTripsAndCanBeAdopted() throws {
    let source = "1 + 2 * round(3.4)"
    let parsed = try parseCalculator(source)
    #expect(parsed.diagnostics.isEmpty)

    let bytes = try parsed.tree.serializeGreenSnapshot()
    let decoded = try GreenSnapshotDecoder
        .decodeTree(bytes, as: CalculatorLanguage.self)
        .intoShared()

    #expect(decoded.withRoot { root in root.makeString() } == source)
    let decodedValue = try evaluateCalculatorTree(decoded)
    let parsedValue = try parsed.evaluate()
    #expect(decodedValue == parsedValue)

    let session = CalculatorSession()
    session.adopt(decoded)

    let edit = TextEdit(
        range: TextRange(
            start: TextSize(UInt32(source.utf8.count)),
            end: TextSize(UInt32(source.utf8.count))
        ),
        replacement: " + 5"
    )
    let reparsed = try session.parse(source + " + 5", edits: [edit])

    #expect(reparsed.diagnostics.isEmpty)
    #expect(try reparsed.evaluate() == .integer(12))
}
