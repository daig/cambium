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

    let tree = try builder.finish().makeSyntaxTree()

    let text = tree.withRoot { $0.makeString() }
    #expect(text == "")

    let rootLength = tree.withRoot { $0.textRange.length }
    #expect(rootLength == .zero)
}

@Test func missingAndStaticTokensOfSameKindAreDistinguishable() throws {
    var staticBuilder = GreenTreeBuilder<TestLanguage>()
    staticBuilder.startNode(.root)
    try staticBuilder.staticToken(.plus)
    try staticBuilder.finishNode()
    let staticTree = try staticBuilder.finish().makeSyntaxTree()

    var missingBuilder = GreenTreeBuilder<TestLanguage>()
    missingBuilder.startNode(.root)
    missingBuilder.missingToken(.plus)
    try missingBuilder.finishNode()
    let missingTree = try missingBuilder.finish().makeSyntaxTree()

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

    let original = try builder.finish().makeSyntaxTree()
    let bytes = try original.serializeGreenSnapshot()
    let decoded = try GreenSnapshotDecoder.decodeTree(bytes, as: TestLanguage.self)

    let originalText = original.withRoot { $0.makeString() }
    let decodedText = decoded.withRoot { $0.makeString() }
    #expect(originalText == "xy")
    #expect(decodedText == "xy")

    // The middle token is the missing one — verify it's still .missing
    // after the round trip rather than being silently re-encoded as
    // .staticText (which would also render "" but for the wrong reason).
    let probedKindAndLength: (RawSyntaxKind, TextSize)? = decoded.withRoot { root in
        root.withChildOrToken(at: 1) { element in
            switch element {
            case .token(let token):
                return (token.rawKind, token.textRange.length)
            case .node:
                return nil
            }
        } ?? nil
    }
    guard let (kind, length) = probedKindAndLength else {
        Issue.record("Expected token at child index 1")
        return
    }
    #expect(kind == RawSyntaxKind(TestKind.plus.rawValue))
    #expect(length == .zero)
}
