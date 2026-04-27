import CambiumCore
import Testing

@Test func greenTokenStaticDerivesLengthFromLanguageStaticText() throws {
    let token = try GreenToken<TestLanguage>.staticToken(kind: .plus)

    #expect(token.kind == .plus)
    #expect(token.textLength == 1)
    if case .staticText = token.textStorage {} else {
        Issue.record("Expected .staticText storage for staticToken(.plus)")
    }
}

@Test func greenTokenStaticRejectsKindWithoutStaticText() {
    #expect(throws: GreenTokenError.staticTextUnavailable(
        RawSyntaxKind(TestKind.identifier.rawValue)
    )) {
        _ = try GreenToken<TestLanguage>.staticToken(kind: .identifier)
    }
}

@Test func greenTokenMissingHasZeroLength() {
    let token = GreenToken<TestLanguage>.missingToken(kind: .missing)

    #expect(token.kind == .missing)
    #expect(token.textLength == .zero)
    if case .missing = token.textStorage {} else {
        Issue.record("Expected .missing storage for missingToken")
    }
}

@Test func greenTokenMissingWorksForKindsWithStaticText() {
    // Error-recovery placeholders use the missing-of-static-kind shape: the
    // language says this kind would have static text, but it's absent in
    // the source. The token renders empty regardless.
    let token = GreenToken<TestLanguage>.missingToken(kind: .plus)

    #expect(token.kind == .plus)
    #expect(token.textLength == .zero)
    if case .missing = token.textStorage {} else {
        Issue.record("Expected .missing storage even when the kind has static text")
    }
}

@Test func greenTokenInternedAcceptsDynamicKind() throws {
    let token = try GreenToken<TestLanguage>.internedToken(
        kind: .identifier,
        textLength: 3,
        key: TokenKey(0)
    )

    #expect(token.kind == .identifier)
    #expect(token.textLength == 3)
    if case .interned(let key) = token.textStorage {
        #expect(key == TokenKey(0))
    } else {
        Issue.record("Expected .interned storage")
    }
}

@Test func greenTokenInternedRejectsStaticKind() {
    #expect(throws: GreenTokenError.staticKindRequiresDynamicToken(
        RawSyntaxKind(TestKind.plus.rawValue)
    )) {
        _ = try GreenToken<TestLanguage>.internedToken(
            kind: .plus,
            textLength: 1,
            key: TokenKey(0)
        )
    }
}

@Test func greenTokenLargeAcceptsDynamicKind() throws {
    let token = try GreenToken<TestLanguage>.largeToken(
        kind: .identifier,
        textLength: 80,
        id: LargeTokenTextID(0)
    )

    #expect(token.kind == .identifier)
    #expect(token.textLength == 80)
    if case .ownedLargeText(let id) = token.textStorage {
        #expect(id == LargeTokenTextID(0))
    } else {
        Issue.record("Expected .ownedLargeText storage")
    }
}

@Test func greenTokenLargeRejectsStaticKind() {
    #expect(throws: GreenTokenError.staticKindRequiresDynamicToken(
        RawSyntaxKind(TestKind.plus.rawValue)
    )) {
        _ = try GreenToken<TestLanguage>.largeToken(
            kind: .plus,
            textLength: 1,
            id: LargeTokenTextID(0)
        )
    }
}
