import CambiumBuilder
import CambiumCore
import CambiumSerialization
import Testing

@Test func missingTokenOfStaticKindRendersEmpty() throws {
    // Audit A5 regression: `.plus` has static text "+", but a missing-token of
    // `.plus` represents an absent token (error recovery placeholder) that
    // should render as nothing, not "+". Pre-fix this would render "+".
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    builder.missingToken(.plus)
    try builder.finishNode()

    let tree = try builder.finish().snapshot.makeSyntaxTree()

    let text = tree.withRoot { $0.makeString() }
    #expect(text == "")

    let rootLength = tree.withRoot { $0.textRange.length }
    #expect(rootLength == .zero)

    guard case .token(let token) = tree.rootGreen.child(at: 0) else {
        Issue.record("Expected missing token at child index 0")
        return
    }
    #expect(token.textLength == .zero)
    #expect(token.textStorage == .missing)
}

@Test func missingAndStaticTokensOfSameKindAreDistinguishable() throws {
    var staticBuilder = GreenTreeBuilder<TestLanguage>()
    staticBuilder.startNode(.root)
    try staticBuilder.staticToken(.plus)
    try staticBuilder.finishNode()
    let staticTree = try staticBuilder.finish().snapshot.makeSyntaxTree()

    var missingBuilder = GreenTreeBuilder<TestLanguage>()
    missingBuilder.startNode(.root)
    missingBuilder.missingToken(.plus)
    try missingBuilder.finishNode()
    let missingTree = try missingBuilder.finish().snapshot.makeSyntaxTree()

    // Same kind, different storage: structural hashes must diverge so cache
    // dedup doesn't collapse them.
    #expect(staticTree.rootGreen.structuralHash != missingTree.rootGreen.structuralHash)

    let staticText = staticTree.withRoot { $0.makeString() }
    let missingText = missingTree.withRoot { $0.makeString() }
    #expect(staticText == "+")
    #expect(missingText == "")
}

@Test func missingTokenSurvivesSerializationRoundTrip() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "x")
    builder.missingToken(.plus)
    try builder.token(.identifier, text: "y")
    try builder.finishNode()

    let original = try builder.finish().snapshot.makeSyntaxTree()
    let bytes = try original.serializeGreenSnapshot()
    let decoded = try GreenSnapshotDecoder.decodeTree(bytes, as: TestLanguage.self)

    let originalText = original.withRoot { $0.makeString() }
    let decodedText = decoded.withRoot { $0.makeString() }
    #expect(originalText == "xy")
    #expect(decodedText == "xy")

    // The middle token is the missing one — verify the storage round-trips as
    // .missing, not merely as some other zero-length token representation.
    guard case .token(let token) = decoded.rootGreen.child(at: 1) else {
        Issue.record("Expected token at child index 1")
        return
    }
    #expect(token.rawKind == RawSyntaxKind(TestKind.plus.rawValue))
    #expect(token.textLength == .zero)
    #expect(token.textStorage == .missing)
}
