import CambiumBuilder
import CambiumCore
import CambiumIncremental
import Testing

@Test func witnessPreservesStructuralSharingForUnrelatedPaths() throws {
    let shared = try makeTwoListRoot().share()

    // Capture v0 green identity of child[0] for later cross-version comparison.
    let v0Child0Identity = shared.withRoot { root in
        root.withChildNode(at: 0) { child in
            child.green { $0 }.identity
        }!
    }

    // Replace child[1] with a fresh subtree.
    let handleToChild1 = shared.withRoot { root in
        root.withChildNode(at: 1) { $0.makeHandle() }!
    }
    var replacementBuilder = GreenTreeBuilder<TestLanguage>()
    replacementBuilder.startNode(.list)
    try replacementBuilder.token(.identifier, text: "fresh")
    try replacementBuilder.finishNode()
    let replacement = try replacementBuilder.finish().root

    var cache = GreenNodeCache<TestLanguage>()
    let result = try shared.replacing(handleToChild1, with: replacement, cache: &cache)
    let witness = result.witness
    let newTree = result.intoTree()

    #expect(witness.replacedPath == [1])
    #expect(witness.oldRoot.identity == shared.rootGreen.identity)
    #expect(witness.newSubtree.identity == replacement.identity)

    // Sibling at v1 path [0] keeps the same green storage as v0 child[0].
    let v1Child0Identity = newTree.withRoot { root in
        root.withChildNode(at: 0) { child in
            child.green { $0 }.identity
        }!
    }
    #expect(v1Child0Identity == v0Child0Identity)
}

@Test func classifyReturnsCorrectOutcomeForEachPathRelation() throws {
    let shared = try makeTwoListRoot().share()
    let handleToChild1 = shared.withRoot { root in
        root.withChildNode(at: 1) { $0.makeHandle() }!
    }
    var replacementBuilder = GreenTreeBuilder<TestLanguage>()
    replacementBuilder.startNode(.list)
    try replacementBuilder.token(.identifier, text: "fresh")
    try replacementBuilder.finishNode()
    let replacement = try replacementBuilder.finish().root

    var cache = GreenNodeCache<TestLanguage>()
    let result = try shared.replacing(handleToChild1, with: replacement, cache: &cache)
    let witness = result.witness

    // Strict prefix → ancestor
    if case .ancestor = witness.classify(path: []) {} else {
        Issue.record("Expected .ancestor for empty path against replacedPath [1]")
    }

    // Disjoint sibling → unchanged
    if case .unchanged = witness.classify(path: [0]) {} else {
        Issue.record("Expected .unchanged for sibling path [0]")
    }

    // Equal → replacedRoot with newSubtree
    if case .replacedRoot(let returned) = witness.classify(path: [1]) {
        #expect(returned.identity == replacement.identity)
    } else {
        Issue.record("Expected .replacedRoot for path [1]")
    }

    // Strict descendant → deleted
    if case .deleted = witness.classify(path: [1, 0]) {} else {
        Issue.record("Expected .deleted for descendant path [1, 0]")
    }
}

@Test func rootReplacementClassifiesEverythingAsDeletedOrReplacedRoot() throws {
    let shared = try makeTwoListRoot().share()
    let rootHandle = shared.rootHandle()

    var replacementBuilder = GreenTreeBuilder<TestLanguage>()
    replacementBuilder.startNode(.root)
    try replacementBuilder.token(.identifier, text: "new")
    try replacementBuilder.finishNode()
    let replacement = try replacementBuilder.finish().root

    var cache = GreenNodeCache<TestLanguage>()
    let result = try shared.replacing(rootHandle, with: replacement, cache: &cache)
    let witness = result.witness

    #expect(witness.replacedPath == [])
    #expect(witness.oldSubtree.identity == witness.oldRoot.identity)
    #expect(witness.newSubtree.identity == witness.newRoot.identity)

    if case .replacedRoot = witness.classify(path: []) {} else {
        Issue.record("Expected .replacedRoot for empty path against empty replacedPath")
    }
    if case .deleted = witness.classify(path: [0]) {} else {
        Issue.record("Expected .deleted for any non-empty path against root replacement")
    }
    if case .deleted = witness.classify(path: [5, 7]) {} else {
        Issue.record("Expected .deleted for arbitrary descendant path against root replacement")
    }
}

@Test func replacementBySelfShortCircuitsClassifyToUnchanged() throws {
    let shared = try makeTwoListRoot().share()
    let handleToChild1 = shared.withRoot { root in
        root.withChildNode(at: 1) { $0.makeHandle() }!
    }
    let oldChild1Green = handleToChild1.withCursor { cursor in
        cursor.green { $0 }
    }

    var cache = GreenNodeCache<TestLanguage>()
    let result = try shared.replacing(handleToChild1, with: oldChild1Green, cache: &cache)
    let witness = result.witness
    let newTree = result.intoTree()

    #expect(witness.oldSubtree.identity == witness.newSubtree.identity)
    #expect(witness.oldRoot.identity == witness.newRoot.identity)
    #expect(newTree.rootGreen.identity == shared.rootGreen.identity)

    // Every path is .unchanged when the subtree was replaced with itself,
    // including paths at and under replacedPath.
    if case .unchanged = witness.classify(path: []) {} else {
        Issue.record("Expected .unchanged for [] under replacement-by-self")
    }
    if case .unchanged = witness.classify(path: [1]) {} else {
        Issue.record("Expected .unchanged for replacedPath under replacement-by-self")
    }
    if case .unchanged = witness.classify(path: [1, 0]) {} else {
        Issue.record("Expected .unchanged for descendant under replacement-by-self")
    }
    if case .unchanged = witness.classify(path: [0]) {} else {
        Issue.record("Expected .unchanged for sibling under replacement-by-self")
    }
}

@Test func freshReplacementEmitsWitnessAndReplacesText() throws {
    let shared = try makeTwoListRoot().share()
    let handleToChild1 = shared.withRoot { root in
        root.withChildNode(at: 1) { $0.makeHandle() }!
    }

    // Build a replacement freshly. We do not assert structural `==` against
    // the old subtree because token interner keys differ across builders
    // (and we do not assert identity equality because cache dedup is not
    // deterministic). The contract we DO assert: the witness exists, has
    // correct path/subtree fields, and the new tree's text reflects the
    // replacement.
    var replacementBuilder = GreenTreeBuilder<TestLanguage>()
    replacementBuilder.startNode(.list)
    try replacementBuilder.token(.identifier, text: "swapped")
    try replacementBuilder.finishNode()
    let replacementResult = try replacementBuilder.finish()
    let replacement = replacementResult.root

    var cache = GreenNodeCache<TestLanguage>()
    let result = try shared.replacing(handleToChild1, with: replacementResult, cache: &cache)
    let witness = result.witness
    let newTree = result.intoTree()

    #expect(witness.replacedPath == [1])
    #expect(witness.newSubtree.rawKind == replacement.rawKind)

    let text = newTree.withRoot { $0.makeString() }
    #expect(text == "keepswapped")
}

@Test func acceptedReuseLogDrainsAndDoesNotAccumulateAcrossDrains() throws {
    let session = IncrementalParseSession<TestLanguage>()

    // Build a couple of green subtrees to reference.
    var b1 = GreenTreeBuilder<TestLanguage>()
    b1.startNode(.list)
    try b1.token(.identifier, text: "one")
    try b1.finishNode()
    let g1 = try b1.finish().root

    var b2 = GreenTreeBuilder<TestLanguage>()
    b2.startNode(.list)
    try b2.token(.identifier, text: "two")
    try b2.finishNode()
    let g2 = try b2.finish().root

    session.recordAcceptedReuse(oldPath: [0], newPath: [0], green: g1)
    session.recordAcceptedReuse(oldPath: [1], newPath: [2], green: g2)

    let drained = session.consumeAcceptedReuses()
    #expect(drained.count == 2)
    #expect(drained[0].green.identity == g1.identity)
    #expect(drained[0].oldPath == [0])
    #expect(drained[0].newPath == [0])
    #expect(drained[1].green.identity == g2.identity)
    #expect(drained[1].oldPath == [1])
    #expect(drained[1].newPath == [2])

    // Second drain returns empty — no accumulation.
    #expect(session.consumeAcceptedReuses().isEmpty)
}

@Test func reuseOracleReportsRealHitBytes() throws {
    // Audit issue A4 regression: reusedBytes was always 0 because the oracle
    // passed TextSize.zero. After the fix it reflects matched node length.
    var prevBuilder = GreenTreeBuilder<TestLanguage>()
    prevBuilder.startNode(.root)
    prevBuilder.startNode(.list)
    try prevBuilder.token(.identifier, text: "abc")
    try prevBuilder.finishNode()
    try prevBuilder.finishNode()
    let previous = try prevBuilder.finish().snapshot.makeSyntaxTree().share()

    let session = IncrementalParseSession<TestLanguage>()
    let oracle = session.makeReuseOracle(previousTree: previous)

    let listOffset = previous.withRoot { root in
        root.withChildNode(at: 0) { $0.textRange.start }!
    }
    let result: Bool? = oracle.withReusableNode(startingAt: listOffset, kind: .list) { _ in
        true
    }
    #expect(result == true)
    #expect(session.counters.reuseHits == 1)
    #expect(session.counters.reusedBytes > 0)
}

@Test func reuseOracleRejectsNodeOverlappingEdit() throws {
    let previous = try makeTwoListRoot().share()
    let editedListRange = secondListRange(in: previous)
    let edit = TextEdit(range: TextRange(start: 5, end: 6), replacement: "x")
    let session = IncrementalParseSession<TestLanguage>()
    let oracle = session.makeReuseOracle(previousTree: previous, edits: [edit])

    let result: Bool? = oracle.withReusableNode(startingAt: editedListRange.start, kind: .list) { _ in
        Issue.record("Invalidated reuse candidate should not be offered")
        return true
    }

    #expect(result == nil)
    #expect(session.counters.reuseQueries == 1)
    #expect(session.counters.reuseHits == 0)
    #expect(session.counters.reusedBytes == 0)
}

@Test func reuseOracleRejectsInsertionInsideNode() throws {
    let previous = try makeTwoListRoot().share()
    let editedListRange = secondListRange(in: previous)
    let insertion = TextEdit(range: TextRange(start: 5, end: 5), replacement: "x")
    let input = ParseInput<TestLanguage>(
        text: "keepoxld",
        edits: [insertion],
        previousTree: previous
    )
    let session = IncrementalParseSession<TestLanguage>()
    let oracle = session.makeReuseOracle(for: input)

    let result: Bool? = oracle.withReusableNode(startingAt: editedListRange.start, kind: .list) { _ in
        Issue.record("Node with insertion inside its old range should not be offered")
        return true
    }

    #expect(result == nil)
}

@Test func reuseOracleAllowsInsertionAtNodeBoundaries() throws {
    let previous = try makeTwoListRoot().share()
    let listRange = secondListRange(in: previous)
    let startInsertion = TextEdit(range: TextRange(start: listRange.start, end: listRange.start), replacement: "x")
    let endInsertion = TextEdit(range: TextRange(start: listRange.end, end: listRange.end), replacement: "x")
    let startOracle = ReuseOracle<TestLanguage>(previousTree: previous, edits: [startInsertion])
    let endOracle = ReuseOracle<TestLanguage>(previousTree: previous, edits: [endInsertion])

    let startResult: Bool? = startOracle.withReusableNode(startingAt: listRange.start, kind: .list) { _ in
        true
    }
    let endResult: Bool? = endOracle.withReusableNode(startingAt: listRange.start, kind: .list) { _ in
        true
    }

    #expect(startResult == true)
    #expect(endResult == true)
}

@Test func reuseOracleAllowsNodeShiftedByEarlierEdit() throws {
    let previous = try makeTwoListRoot().share()
    let listRange = secondListRange(in: previous)
    let earlierEdit = TextEdit(range: TextRange(start: 1, end: 2), replacement: "xyz")
    let session = IncrementalParseSession<TestLanguage>()
    let oracle = session.makeReuseOracle(previousTree: previous, edits: [earlierEdit])

    let result: Bool? = oracle.withReusableNode(startingAt: listRange.start, kind: .list) { node in
        node.textRange == listRange
    }

    #expect(result == true)
    #expect(session.counters.reuseQueries == 1)
    #expect(session.counters.reuseHits == 1)
    #expect(session.counters.reusedBytes == UInt64(listRange.length.rawValue))
}

@Test func reuseOracleRejectsCandidateInvalidatedByAnyEdit() throws {
    let previous = try makeTwoListRoot().share()
    let listRange = secondListRange(in: previous)
    let edits = [
        TextEdit(range: TextRange(start: 1, end: 2), replacement: "xyz"),
        TextEdit(range: TextRange(start: 5, end: 5), replacement: "x"),
    ]
    let oracle = ReuseOracle<TestLanguage>(previousTree: previous, edits: edits)

    let result: Bool? = oracle.withReusableNode(startingAt: listRange.start, kind: .list) { _ in
        Issue.record("Candidate invalidated by one edit should not be offered")
        return true
    }

    #expect(result == nil)
}

@Test func reuseOracleCanOfferValidDescendantWhenLargerCandidateIsInvalidated() throws {
    let previous = try makeNestedListPrefixTree().share()
    let editAfterInnerList = TextEdit(range: TextRange(start: 2, end: 3), replacement: "y")
    let oracle = ReuseOracle<TestLanguage>(previousTree: previous, edits: [editAfterInnerList])

    let result: TextRange? = oracle.withReusableNode(startingAt: .zero, kind: .list) { node in
        node.textRange
    }

    #expect(result == TextRange(start: 0, end: 2))
}

private func makeTwoListRoot() throws -> SyntaxTree<TestLanguage> {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    builder.startNode(.list)
    try builder.token(.identifier, text: "keep")
    try builder.finishNode()
    builder.startNode(.list)
    try builder.token(.identifier, text: "old")
    try builder.finishNode()
    try builder.finishNode()
    return try builder.finish().snapshot.makeSyntaxTree()
}

private func makeNestedListPrefixTree() throws -> SyntaxTree<TestLanguage> {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    builder.startNode(.list)
    builder.startNode(.list)
    try builder.token(.identifier, text: "ok")
    try builder.finishNode()
    try builder.token(.identifier, text: "x")
    try builder.finishNode()
    try builder.finishNode()
    return try builder.finish().snapshot.makeSyntaxTree()
}

private func secondListRange(in tree: SharedSyntaxTree<TestLanguage>) -> TextRange {
    tree.withRoot { root in
        root.withChildNode(at: 1) { $0.textRange }!
    }
}
