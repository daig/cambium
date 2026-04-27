import CambiumBuilder
import CambiumCore
import Testing

private enum Outcome: Equatable {
    case none
    case single(String)
    case between(left: String, right: String)
}

@Test func tokenAtOffsetReturnsNoneOutsideTreeRange() throws {
    let tree = try makeFooBarTree() // "foo bar" = 7 bytes
    let outcome = tree.withRoot { root in
        root.withTokenAtOffset(
            TextSize(99),
            none: { Outcome.none },
            single: { .single($0.makeString()) },
            between: { l, r in .between(left: l.makeString(), right: r.makeString()) }
        )
    }
    #expect(outcome == .none)
}

@Test func tokenAtOffsetReturnsSingleStrictlyInsideToken() throws {
    let tree = try makeFooBarTree()
    let outcome = tree.withRoot { root in
        root.withTokenAtOffset(
            TextSize(1), // inside "foo"
            none: { Outcome.none },
            single: { .single($0.makeString()) },
            between: { l, r in .between(left: l.makeString(), right: r.makeString()) }
        )
    }
    #expect(outcome == .single("foo"))
}

@Test func tokenAtOffsetReturnsSingleAtTreeStart() throws {
    let tree = try makeFooBarTree()
    let outcome = tree.withRoot { root in
        root.withTokenAtOffset(
            .zero,
            none: { Outcome.none },
            single: { .single($0.makeString()) },
            between: { l, r in .between(left: l.makeString(), right: r.makeString()) }
        )
    }
    #expect(outcome == .single("foo"))
}

@Test func tokenAtOffsetReturnsSingleAtTreeEnd() throws {
    let tree = try makeFooBarTree()
    let outcome = tree.withRoot { root in
        root.withTokenAtOffset(
            TextSize(7), // end of "bar"
            none: { Outcome.none },
            single: { .single($0.makeString()) },
            between: { l, r in .between(left: l.makeString(), right: r.makeString()) }
        )
    }
    #expect(outcome == .single("bar"))
}

@Test func tokenAtOffsetReturnsBetweenAtAdjacentTokenBoundary() throws {
    let tree = try makeFooBarTree()
    // "foo" is [0,3), " " is [3,4), "bar" is [4,7).
    let outcomeAt3 = tree.withRoot { root in
        root.withTokenAtOffset(
            TextSize(3),
            none: { Outcome.none },
            single: { .single($0.makeString()) },
            between: { l, r in .between(left: l.makeString(), right: r.makeString()) }
        )
    }
    #expect(outcomeAt3 == .between(left: "foo", right: " "))

    let outcomeAt4 = tree.withRoot { root in
        root.withTokenAtOffset(
            TextSize(4),
            none: { Outcome.none },
            single: { .single($0.makeString()) },
            between: { l, r in .between(left: l.makeString(), right: r.makeString()) }
        )
    }
    #expect(outcomeAt4 == .between(left: " ", right: "bar"))
}

@Test func tokenAtOffsetReturnsBetweenAcrossSubtreeBoundary() throws {
    let tree = try makeNestedSubtreeTree() // root[ list["foo"], list["bar"] ]
    // "foo" is in list-1 at [0,3); "bar" is in list-2 at [3,6).
    // Boundary at offset 3 crosses subtree boundary.
    let outcome = tree.withRoot { root in
        root.withTokenAtOffset(
            TextSize(3),
            none: { Outcome.none },
            single: { .single($0.makeString()) },
            between: { l, r in .between(left: l.makeString(), right: r.makeString()) }
        )
    }
    #expect(outcome == .between(left: "foo", right: "bar"))
}

@Test func tokenAtOffsetReturnsSingleForZeroLengthTokenAtBoundary() throws {
    // foo + missingPlus + bar:
    // "foo" [0,3), missing(.plus) at 3 (zero length), "bar" [3,6).
    let tree = try makeFooMissingBarTree()
    let outcome = tree.withRoot { root in
        root.withTokenAtOffset(
            TextSize(3),
            none: { Outcome.none },
            single: { token in
                .single(
                    token.textLength == .zero
                        ? "<missing>"
                        : token.makeString()
                )
            },
            between: { l, r in .between(left: l.makeString(), right: r.makeString()) }
        )
    }
    // The zero-length missing token should win the lookup at offset 3,
    // surfacing as `.single` rather than `.between(foo, bar)`.
    #expect(outcome == .single("<missing>"))
}

@Test func tokenAtOffsetReturnsNonePastTreeEndEvenWithTrailingZeroLengthToken() throws {
    // "foo" [0,3), missing(.plus) at 3, tree end is still 3.
    let tree = try makeFooTrailingMissingTree()
    let outcome = tree.withRoot { root in
        root.withTokenAtOffset(
            TextSize(4),
            none: { Outcome.none },
            single: { token in
                .single(
                    token.textLength == .zero
                        ? "<missing>"
                        : token.makeString()
                )
            },
            between: { l, r in .between(left: l.makeString(), right: r.makeString()) }
        )
    }
    #expect(outcome == .none)
}

@Test func tokenAtOffsetFindsNestedZeroLengthTokenAtChildEnd() throws {
    // list("foo", missingPlus) has text range [0,3); the missing token sits
    // at that child node's end and should still win at offset 3.
    let tree = try makeNestedMissingAtChildEndTree()
    let outcome = tree.withRoot { root in
        root.withTokenAtOffset(
            TextSize(3),
            none: { Outcome.none },
            single: { token in
                .single(
                    token.textLength == .zero
                        ? "<missing>"
                        : token.makeString()
                )
            },
            between: { l, r in .between(left: l.makeString(), right: r.makeString()) }
        )
    }
    #expect(outcome == .single("<missing>"))
}

@Test func tokenAtOffsetOnTreeWithoutTokensReturnsNone() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.finishNode()
    let tree = try builder.finish().snapshot.makeSyntaxTree()

    let outcome = tree.withRoot { root in
        root.withTokenAtOffset(
            .zero,
            none: { Outcome.none },
            single: { .single($0.makeString()) },
            between: { l, r in .between(left: l.makeString(), right: r.makeString()) }
        )
    }
    #expect(outcome == .none)
}

private func makeFooBarTree() throws -> SyntaxTree<TestLanguage> {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "foo")
    try builder.staticToken(.whitespace)
    try builder.token(.identifier, text: "bar")
    try builder.finishNode()
    return try builder.finish().snapshot.makeSyntaxTree()
}

private func makeNestedSubtreeTree() throws -> SyntaxTree<TestLanguage> {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    builder.startNode(.list)
    try builder.token(.identifier, text: "foo")
    try builder.finishNode()
    builder.startNode(.list)
    try builder.token(.identifier, text: "bar")
    try builder.finishNode()
    try builder.finishNode()
    return try builder.finish().snapshot.makeSyntaxTree()
}

private func makeFooMissingBarTree() throws -> SyntaxTree<TestLanguage> {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "foo")
    builder.missingToken(.plus)
    try builder.token(.identifier, text: "bar")
    try builder.finishNode()
    return try builder.finish().snapshot.makeSyntaxTree()
}

private func makeFooTrailingMissingTree() throws -> SyntaxTree<TestLanguage> {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "foo")
    builder.missingToken(.plus)
    try builder.finishNode()
    return try builder.finish().snapshot.makeSyntaxTree()
}

private func makeNestedMissingAtChildEndTree() throws -> SyntaxTree<TestLanguage> {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    builder.startNode(.list)
    try builder.token(.identifier, text: "foo")
    builder.missingToken(.plus)
    try builder.finishNode()
    try builder.token(.identifier, text: "bar")
    try builder.finishNode()
    return try builder.finish().snapshot.makeSyntaxTree()
}
