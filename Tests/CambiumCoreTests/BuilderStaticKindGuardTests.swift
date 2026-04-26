import CambiumBuilder
import CambiumCore
import Testing

@Test func tokenRejectsStaticKindEvenWithMatchingText() throws {
    // Audit D3: even when the text matches `Lang.staticText(for: .plus) == "+"`,
    // calling `token(_:text:)` with a static-text kind is API misuse — the
    // parser should call `staticToken(_:)` instead. Reject loudly.
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)

    #expect(throws: GreenTreeBuilderError.staticKindRequiresStaticToken(
        RawSyntaxKind(TestKind.plus.rawValue)
    )) {
        try builder.token(.plus, text: "+")
    }
}

@Test func tokenRejectsStaticKindWithMismatchedText() throws {
    // The reject is on the kind, not on the text content — so a "creative"
    // misuse like .plus with text "X" is also caught.
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)

    #expect(throws: GreenTreeBuilderError.staticKindRequiresStaticToken(
        RawSyntaxKind(TestKind.plus.rawValue)
    )) {
        try builder.token(.plus, text: "X")
    }
}

@Test func largeTokenRejectsStaticKind() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)

    #expect(throws: GreenTreeBuilderError.staticKindRequiresStaticToken(
        RawSyntaxKind(TestKind.plus.rawValue)
    )) {
        try builder.largeToken(.plus, text: "+")
    }
}

@Test func tokenAcceptsDynamicKind() throws {
    // Control: kinds without grammar-determined text still go through
    // `token(_:text:)` correctly.
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "hello")
    try builder.finishNode()

    let tree = try builder.finish().snapshot.makeSyntaxTree()
    #expect(tree.withRoot { $0.makeString() } == "hello")
}

@Test func largeTokenAcceptsDynamicKind() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.largeToken(.identifier, text: "world")
    try builder.finishNode()

    let tree = try builder.finish().snapshot.makeSyntaxTree()
    #expect(tree.withRoot { $0.makeString() } == "world")
}

@Test func staticTokenStillAcceptsStaticKind() throws {
    // Regression guard: the new validation must not affect the staticToken
    // path. `.plus` going through `staticToken(_:)` continues to render "+".
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.staticToken(.plus)
    try builder.finishNode()

    let tree = try builder.finish().snapshot.makeSyntaxTree()
    #expect(tree.withRoot { $0.makeString() } == "+")
}

@Test func tokenBytesOverloadAlsoRejectsStaticKind() throws {
    // The `text:` overload delegates to `bytes:`, but exercise the bytes
    // overload directly to lock in that the validation lives at the right
    // layer (not just in the String overload).
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)

    var copy = "+"
    let didThrow: Bool = copy.withUTF8 { bytes in
        do {
            try builder.token(.plus, bytes: bytes)
            return false
        } catch GreenTreeBuilderError.staticKindRequiresStaticToken(
            RawSyntaxKind(TestKind.plus.rawValue)
        ) {
            return true
        } catch {
            return false
        }
    }
    #expect(didThrow)
}
