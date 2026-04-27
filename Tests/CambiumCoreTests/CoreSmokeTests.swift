import CambiumAnalysis
import CambiumASTSupport
import CambiumBuilder
import CambiumCore
import CambiumIncremental
import CambiumOwnedTraversal
import CambiumSerialization
import Testing

private enum OtherLanguage: SyntaxLanguage {
    typealias Kind = TestKind

    static let rootKind: TestKind = .root
    static let missingKind: TestKind = .missing
    static let errorKind: TestKind = .error
    static let serializationID = "org.cambium.tests.other-language"
    static let serializationVersion: UInt32 = 1

    static func rawKind(for kind: TestKind) -> RawSyntaxKind {
        TestLanguage.rawKind(for: kind)
    }

    static func kind(for raw: RawSyntaxKind) -> TestKind {
        TestLanguage.kind(for: raw)
    }
}

private func makeTraversalTree() throws -> SyntaxTree<TestLanguage> {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "a")
    try builder.staticToken(.whitespace)
    builder.startNode(.list)
    try builder.token(.identifier, text: "b")
    try builder.staticToken(.whitespace)
    builder.startNode(.list)
    try builder.token(.identifier, text: "c")
    try builder.staticToken(.whitespace)
    try builder.staticToken(.plus)
    try builder.staticToken(.whitespace)
    try builder.token(.identifier, text: "d")
    try builder.finishNode()
    try builder.staticToken(.whitespace)
    try builder.staticToken(.plus)
    try builder.staticToken(.whitespace)
    builder.startNode(.list)
    try builder.token(.identifier, text: "e")
    try builder.finishNode()
    try builder.finishNode()
    try builder.staticToken(.whitespace)
    try builder.staticToken(.plus)
    try builder.staticToken(.whitespace)
    builder.startNode(.list)
    try builder.token(.identifier, text: "f")
    try builder.finishNode()
    try builder.staticToken(.whitespace)
    try builder.token(.identifier, text: "z")
    try builder.finishNode()

    return try builder.finish().snapshot.makeSyntaxTree()
}

private func makeSyntaxTextTree() throws -> SyntaxTree<TestLanguage> {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "ab")
    try builder.staticToken(.whitespace)
    try builder.staticToken(.plus)
    builder.startNode(.list)
    try builder.token(.identifier, text: "cd")
    try builder.staticToken(.whitespace)
    try builder.largeToken(.identifier, text: "éfg")
    try builder.finishNode()
    try builder.finishNode()

    return try builder.finish().snapshot.makeSyntaxTree()
}

private func describeElement(_ element: borrowing SyntaxElementCursor<TestLanguage>) -> String {
    switch element {
    case .node(let node):
        "node:\(TestLanguage.name(for: node.kind)):\(node.makeString())"
    case .token(let token):
        "token:\(TestLanguage.name(for: token.kind)):\(token.makeString())@\(token.textRange.start.rawValue)"
    }
}

private func describeElementWithOffset(_ element: borrowing SyntaxElementCursor<TestLanguage>) -> String {
    switch element {
    case .node(let node):
        "node:\(TestLanguage.name(for: node.kind)):\(node.makeString())@\(node.textRange.start.rawValue)"
    case .token(let token):
        describeToken(token)
    }
}

private func describeToken(_ token: borrowing SyntaxTokenCursor<TestLanguage>) -> String {
    "token:\(TestLanguage.name(for: token.kind)):\(token.makeString())@\(token.textRange.start.rawValue)"
}

private struct WideTraversalFixture: ~Copyable {
    var tree: SyntaxTree<TestLanguage>
    var topLevelElements: [String]
    var descendants: [String]
    var tokens: [String]
    var probeNodeTokens: [String]
    var probeNodeRange: TextRange
    var probeNodeOrdinal: Int
    var probeTopLevelIndex: Int
    var probeTokenOffset: TextSize
    var probeTokenLabel: String
    var nodeCount: Int
}

private func makeWideTraversalFixture() throws -> WideTraversalFixture {
    let groupCount = 128
    let probeIndex = 73
    var builder = GreenTreeBuilder<TestLanguage>()
    var topLevelElements: [String] = []
    var descendants: [String] = []
    var tokens: [String] = []
    var probeNodeTokens: [String] = []
    var probeNodeRange = TextRange(start: .zero, length: .zero)
    var probeTopLevelIndex = 0
    var probeTokenOffset = TextSize.zero
    var probeTokenLabel = ""
    var offset = 0

    func textSize(_ value: Int) -> TextSize {
        TextSize(rawValue: UInt32(value))
    }

    func tokenLabel(kind: TestKind, text: String, offset: Int) -> String {
        "token:\(TestLanguage.name(for: kind)):\(text)@\(offset)"
    }

    func appendExpectedToken(
        kind: TestKind,
        text: String,
        isTopLevel: Bool,
        includeInProbeNode: Bool = false
    ) {
        let label = tokenLabel(kind: kind, text: text, offset: offset)
        if isTopLevel {
            topLevelElements.append(label)
        }
        descendants.append(label)
        tokens.append(label)
        if includeInProbeNode {
            probeNodeTokens.append(label)
        }
        offset += text.utf8.count
    }

    builder.startNode(.root)
    for index in 0..<groupCount {
        let topIdentifier = "t\(index)"
        try builder.token(.identifier, text: topIdentifier)
        appendExpectedToken(kind: .identifier, text: topIdentifier, isTopLevel: true)

        try builder.staticToken(.whitespace)
        appendExpectedToken(kind: .whitespace, text: " ", isTopLevel: true)

        if index % 17 == 0 {
            builder.missingToken(.missing)
            appendExpectedToken(kind: .missing, text: "", isTopLevel: true)
        }

        let nodeStart = offset
        let nodeText = "n\(index)+m\(index)"
        let nodeLabel = "node:\(TestLanguage.name(for: .list)):\(nodeText)@\(nodeStart)"
        topLevelElements.append(nodeLabel)
        descendants.append(nodeLabel)
        if index == probeIndex {
            probeNodeTokens = []
            probeNodeRange = TextRange(start: textSize(nodeStart), length: textSize(nodeText.utf8.count))
            probeTopLevelIndex = topLevelElements.count - 1
        }

        builder.startNode(.list)
        let leftText = "n\(index)"
        try builder.token(.identifier, text: leftText)
        appendExpectedToken(kind: .identifier, text: leftText, isTopLevel: false, includeInProbeNode: index == probeIndex)

        try builder.staticToken(.plus)
        appendExpectedToken(kind: .plus, text: "+", isTopLevel: false, includeInProbeNode: index == probeIndex)

        if index % 23 == 0 {
            builder.missingToken(.missing)
            appendExpectedToken(kind: .missing, text: "", isTopLevel: false, includeInProbeNode: index == probeIndex)
        }

        let rightText = "m\(index)"
        if index == probeIndex {
            probeTokenOffset = textSize(offset)
            probeTokenLabel = tokenLabel(kind: .identifier, text: rightText, offset: offset)
        }
        try builder.token(.identifier, text: rightText)
        appendExpectedToken(kind: .identifier, text: rightText, isTopLevel: false, includeInProbeNode: index == probeIndex)
        try builder.finishNode()

        try builder.staticToken(.whitespace)
        appendExpectedToken(kind: .whitespace, text: " ", isTopLevel: true)
    }
    try builder.finishNode()

    return WideTraversalFixture(
        tree: try builder.finish().snapshot.makeSyntaxTree(),
        topLevelElements: topLevelElements,
        descendants: descendants,
        tokens: tokens,
        probeNodeTokens: probeNodeTokens,
        probeNodeRange: probeNodeRange,
        probeNodeOrdinal: probeIndex,
        probeTopLevelIndex: probeTopLevelIndex,
        probeTokenOffset: probeTokenOffset,
        probeTokenLabel: probeTokenLabel,
        nodeCount: groupCount
    )
}

private func describeNodeWalkEvent(_ event: borrowing SyntaxNodeWalkEvent<TestLanguage>) -> String {
    switch event {
    case .enter(let node):
        "enter:\(TestLanguage.name(for: node.kind)):\(node.makeString())"
    case .leave(let node):
        "leave:\(TestLanguage.name(for: node.kind)):\(node.makeString())"
    }
}

private func describeElementWalkEvent(_ event: borrowing SyntaxElementWalkEvent<TestLanguage>) -> String {
    switch event {
    case .enter(let element):
        "enter:\(describeElement(element))"
    case .leave(let element):
        "leave:\(describeElement(element))"
    }
}

@Test func textRangeComputesLengthAndChecksUTF8Counts() throws {
    let range = TextRange(start: 4, end: 9)
    #expect(range.length == 5)

    let size = try TextSize(byteCountOf: "é+")
    #expect(size == 3)

    #expect(throws: TextSizeError.overflow) {
        _ = try TextSize(UInt32.max).adding(1)
    }
}

@Test func greenElementExposesKindAndLength() throws {
    let token = try GreenToken<TestLanguage>.internedToken(
        kind: .identifier,
        textLength: 3,
        key: TokenKey(0)
    )
    let element = GreenElement<TestLanguage>.token(token)

    #expect(element.rawKind == RawSyntaxKind(TestKind.identifier.rawValue))
    #expect(element.kind == .identifier)
    #expect(element.textLength == 3)
}

@Test func builderRoundTripsStaticAndInternedText() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "a")
    try builder.staticToken(.plus)
    try builder.token(.identifier, text: "é")
    try builder.finishNode()

    let result = try builder.finish()
    let tree = result.snapshot.makeSyntaxTree()
    let text = tree.withRoot { root in
        root.makeString()
    }

    #expect(text == "a+é")
}

@Test func syntaxTextStreamsChunksAndSlicesByByteRange() throws {
    let tree = try makeSyntaxTextTree()

    try tree.withRoot { root in
        try root.withText { text in
            #expect(text.utf8Count == 11)
            let isEmpty = text.isEmpty
            #expect(!isEmpty)

            var chunks: [String] = []
            try text.forEachUTF8Chunk { bytes in
                chunks.append(String(decoding: bytes, as: UTF8.self))
            }
            #expect(chunks == ["ab", " ", "+", "cd", " ", "éfg"])

            var sink = StringUTF8Sink()
            try text.writeUTF8(to: &sink)
            #expect(sink.result == "ab +cd éfg")
            let equalsFullString = text.equals("ab +cd éfg")
            #expect(equalsFullString)

            let sliceRange = TextRange(start: 1, end: 10)
            let sliceCount = text.sliced(sliceRange).utf8Count
            let sliceString = text.sliced(sliceRange).makeString()
            let partialScalarString = text.sliced(TextRange(start: 8, end: 9)).makeString()
            #expect(sliceCount == 9)
            #expect(sliceString == "b +cd éf")
            #expect(partialScalarString == "�")

            var sliceChunks: [String] = []
            try text.sliced(sliceRange).forEachUTF8Chunk { bytes in
                sliceChunks.append(String(decoding: bytes, as: UTF8.self))
            }
            #expect(sliceChunks == ["b", " ", "+", "cd", " ", "éf"])

            let empty = text.sliced(TextRange(start: 3, end: 3))
            let emptyIsEmpty = empty.isEmpty
            #expect(emptyIsEmpty)
            #expect(empty.utf8Count == 0)
            var emptyChunkCount = 0
            try empty.forEachUTF8Chunk { _ in
                emptyChunkCount += 1
            }
            #expect(emptyChunkCount == 0)
            let emptyNeedleRange = empty.firstRange(of: [])
            let emptyString = empty.makeString()
            #expect(emptyString == "")
            #expect(emptyNeedleRange == .empty)
        }
    }
}

@Test func syntaxTextFindsBytesAcrossChunkBoundaries() throws {
    let tree = try makeSyntaxTextTree()

    tree.withRoot { root in
        root.withText { text in
            let containsPlus = text.contains(UInt8(ascii: "+"))
            let plusIndex = text.firstIndex(of: UInt8(ascii: "+"))
            let unicodeLeadByteIndex = text.firstIndex(of: 0xc3)
            let missingByteIndex = text.firstIndex(of: UInt8(ascii: "z"))
            let containsCrossChunkNeedle = text.contains(Array("b +c".utf8))
            let crossChunkRange = text.firstRange(of: Array("b +c".utf8))
            let largeTokenRange = text.firstRange(of: Array("d éf".utf8))
            let missingRange = text.firstRange(of: Array("missing".utf8))

            #expect(containsPlus)
            #expect(plusIndex == 3)
            #expect(unicodeLeadByteIndex == 7)
            #expect(missingByteIndex == nil)
            #expect(containsCrossChunkNeedle)
            #expect(crossChunkRange == TextRange(start: 1, length: 4))
            #expect(largeTokenRange == TextRange(start: 5, length: 5))
            #expect(missingRange == nil)

            let tail = text.sliced(TextRange(start: 4, end: 11))
            let tailUnicodeLeadByteIndex = tail.firstIndex(of: 0xc3)
            let tailUnicodeRange = tail.firstRange(of: Array("éfg".utf8))
            let tailEmptyNeedleRange = tail.firstRange(of: [])
            #expect(tailUnicodeLeadByteIndex == 3)
            #expect(tailUnicodeRange == TextRange(start: 3, length: 4))
            #expect(tailEmptyNeedleRange == .empty)
        }
    }
}

@Test func syntaxTextComparesStringsAndOtherSyntaxTextWithoutMaterializingFullText() throws {
    let tree = try makeSyntaxTextTree()

    tree.withRoot { root in
        root.withText { text in
            let equalsFull = text.equals("ab +cd éfg")
            let equalsAsciiOnly = text.equals("ab +cd efg")
            let equalsExtraByte = text.equals("ab +cd éfg ")
            #expect(equalsFull)
            #expect(!equalsAsciiOnly)
            #expect(!equalsExtraByte)

            let first = text.sliced(TextRange(start: 1, end: 10))
            let second = text.sliced(TextRange(start: 1, end: 10))
            let equalSlices = first.equals(second)
            #expect(equalSlices)

            let different = text.sliced(TextRange(start: 2, end: 11))
            let unequalSlices = text.sliced(TextRange(start: 1, end: 10)).equals(different)
            let equalsUnicodeTail = text.sliced(TextRange(start: 7, end: 11)).equals("éfg")
            #expect(!unequalSlices)
            #expect(equalsUnicodeTail)
        }
    }
}

@Test func builderCheckpointsWrapExistingChildren() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    let checkpoint = builder.checkpoint()
    try builder.token(.identifier, text: "a")
    try builder.staticToken(.plus)
    try builder.startNode(at: checkpoint, .list)
    try builder.finishNode()
    try builder.finishNode()

    let result = try builder.finish()
    let tree = result.snapshot.makeSyntaxTree()

    let childKind = tree.withRoot { root in
        root.withChildNode(at: 0) { child in
            child.kind
        }
    }
    #expect(childKind == .list)
}

@Test func builderCheckpointStartNodeRejectsDeeperOpenParent() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    let checkpoint = builder.checkpoint()
    builder.startNode(.list)
    try builder.token(.identifier, text: "nested")

    #expect(throws: GreenTreeBuilderError.invalidCheckpoint) {
        try builder.startNode(at: checkpoint, .list)
    }
}

@Test func builderCheckpointStartNodeAllowsReturnedParentContext() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    let checkpoint = builder.checkpoint()
    builder.startNode(.list)
    try builder.token(.identifier, text: "nested")
    try builder.finishNode()

    try builder.startNode(at: checkpoint, .list)
    try builder.finishNode()
    try builder.finishNode()
    let tree = try builder.finish().snapshot.makeSyntaxTree()

    #expect(tree.withRoot { $0.makeString() } == "nested")
}

@Test func builderCheckpointStartNodeRejectsCheckpointFromAnotherBuilder() throws {
    var first = GreenTreeBuilder<TestLanguage>()
    first.startNode(.root)
    let checkpoint = first.checkpoint()

    var second = GreenTreeBuilder<TestLanguage>()
    second.startNode(.root)

    #expect(throws: GreenTreeBuilderError.invalidCheckpoint) {
        try second.startNode(at: checkpoint, .list)
    }
}

@Test func builderCheckpointStartNodeRejectsStaleSameDepthParent() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    builder.startNode(.list)
    let checkpoint = builder.checkpoint()
    try builder.token(.identifier, text: "first")
    try builder.finishNode()
    builder.startNode(.list)

    #expect(throws: GreenTreeBuilderError.invalidCheckpoint) {
        try builder.startNode(at: checkpoint, .list)
    }
}

@Test func builderCheckpointRevertAllowsDeeperOpenParent() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    let checkpoint = builder.checkpoint()
    builder.startNode(.list)
    try builder.token(.identifier, text: "discard")

    try builder.revert(to: checkpoint)
    try builder.token(.identifier, text: "keep")
    try builder.finishNode()
    let tree = try builder.finish().snapshot.makeSyntaxTree()

    #expect(tree.withRoot { $0.makeString() } == "keep")
}

@Test func builderCheckpointRevertRejectsCheckpointFromAnotherBuilder() throws {
    var first = GreenTreeBuilder<TestLanguage>()
    first.startNode(.root)
    let checkpoint = first.checkpoint()

    var second = GreenTreeBuilder<TestLanguage>()
    second.startNode(.root)

    #expect(throws: GreenTreeBuilderError.invalidCheckpoint) {
        try second.revert(to: checkpoint)
    }
}

@Test func cacheDeduplicatesEqualGreenNodesAfterStructuralEquality() throws {
    var cache = GreenNodeCache<TestLanguage>()
    let token = cache.makeToken(kind: RawSyntaxKind(TestKind.plus.rawValue), textLength: 1, text: .staticText)
    let first = try cache.makeNode(kind: RawSyntaxKind(TestKind.list.rawValue), children: [.token(token)])
    let second = try cache.makeNode(kind: RawSyntaxKind(TestKind.list.rawValue), children: [.token(token)])

    #expect(first == second)
    #expect(cache.hitCount >= 1)
}

@Test func redTraversalFindsTokensAndHandlesRetainTree() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "left")
    try builder.staticToken(.whitespace)
    try builder.staticToken(.plus)
    try builder.staticToken(.whitespace)
    try builder.token(.identifier, text: "right")
    try builder.finishNode()

    let result = try builder.finish()
    let tree = result.snapshot.makeSyntaxTree()
    let shared = tree.share()

    let tokenAtFive: String? = shared.withRoot { root in
        root.withTokenAtOffset(
            5,
            none: { nil },
            single: { token in token.makeString() },
            between: { _, right in right.makeString() }
        )
    }
    #expect(tokenAtFive == "+")

    let rootHandle = shared.rootHandle()
    let tokens = rootHandle.tokenHandles()
    #expect(tokens.count == 5)
    #expect(tokens[4].withCursor { $0.makeString() } == "right")
}

@Test func redTraversalHandlesSurviveBorrowedCursorClosures() throws {
    let tree = try makeTraversalTree()

    let handles = tree.withRoot { root in
        let node = root.withDescendant(atPath: [2, 2]) { child in
            child.makeHandle()
        }!
        let token: SyntaxTokenHandle<TestLanguage>? = root.withTokenAtOffset(
            8,
            none: { nil },
            single: { $0.makeHandle() },
            between: { _, right in right.makeHandle() }
        )
        return (node, token!)
    }

    #expect(handles.0.withCursor { $0.makeString() } == "c + d")
    #expect(handles.1.withCursor { $0.makeString() } == "d")
    #expect(handles.1.withCursor { token in
        token.withParent { parent in
            parent.makeString()
        }
    } == "c + d")
}

@Test func redTraversalSupportsConcurrentLazyRealization() async throws {
    let tree = try makeTraversalTree()
    let shared = tree.share()

    let results = await withTaskGroup(of: String.self) { group in
        for _ in 0..<32 {
            group.addTask {
                shared.withRoot { root in
                    var labels: [String] = []
                    root.forEachDescendantOrToken(includingSelf: true) { element in
                        labels.append(describeElement(element))
                    }
                    let token = root.withTokenAtOffset(
                        8,
                        none: { "nil" },
                        single: { $0.makeString() },
                        between: { _, right in right.makeString() }
                    )
                    let path = root.withDescendant(atPath: [2, 2]) { child in
                        child.childIndexPath().map(String.init).joined(separator: ".")
                    } ?? "nil"
                    labels.append("token:\(token)")
                    labels.append("path:\(path)")
                    return labels.joined(separator: "|")
                }
            }
        }

        var results: [String] = []
        for await result in group {
            results.append(result)
        }
        return results
    }

    #expect(results.count == 32)
    #expect(Set(results).count == 1)
    #expect(results.first?.contains("token:d") == true)
    #expect(results.first?.contains("path:2.2") == true)
}

@Test func traversalChildHelpersDistinguishNodesAndTokens() throws {
    let tree = try makeTraversalTree()
    let labels = tree.withRoot { root in
        [
            root.withFirstChild { child in child.makeString() } ?? "nil",
            root.withLastChild { child in child.makeString() } ?? "nil",
            root.withFirstChildOrToken { element in describeElement(element) } ?? "nil",
            root.withLastChildOrToken { element in describeElement(element) } ?? "nil",
        ]
    }

    #expect(labels == [
        "b c + d + e",
        "f",
        "token:identifier:a@0",
        "token:identifier:z@18",
    ])
}

@Test func mutableRootCursorSupportsMoveToNavigation() throws {
    let tree = try makeTraversalTree()
    let labels = tree.withMutableRoot { cursor in
        var labels: [String] = []
        labels.append(cursor.makeString())
        labels.append(cursor.moveToFirstChild() ? cursor.makeString() : "nil")
        labels.append(cursor.moveToNextSibling() ? cursor.makeString() : "nil")
        labels.append(cursor.moveToPreviousSibling() ? cursor.makeString() : "nil")
        labels.append(cursor.moveToParent() ? cursor.makeString() : "nil")
        labels.append(cursor.moveToLastChild() ? cursor.makeString() : "nil")
        return labels
    }

    #expect(labels == [
        "a b c + d + e + f z",
        "b c + d + e",
        "f",
        "b c + d + e",
        "a b c + d + e + f z",
        "f",
    ])

    let shared = tree.share()
    let lastViaHandle = shared.rootHandle().withMutableCursor { cursor in
        cursor.moveToLastChild() ? cursor.makeString() : "nil"
    }
    #expect(lastViaHandle == "f")
}

@Test func ownedTraversalDescendantsExcludeSelfAndRootHelperIncludesRoot() throws {
    let shared = try makeTraversalTree().share()
    let root = shared.rootHandle()

    let descendants = root.descendantHandlesPreorder.map { handle in
        handle.withCursor { cursor in
            cursor.makeString()
        }
    }
    #expect(descendants == [
        "b c + d + e",
        "c + d",
        "e",
        "f",
    ])

    let rootAndDescendants = shared.rootAndDescendantHandlesPreorder.map { handle in
        handle.withCursor { cursor in
            cursor.makeString()
        }
    }
    #expect(rootAndDescendants == [
        "a b c + d + e + f z",
        "b c + d + e",
        "c + d",
        "e",
        "f",
    ])
}

@Test func traversalSiblingAPIsSkipOrIncludeTokens() throws {
    let tree = try makeTraversalTree()
    let labels = tree.withRoot { root in
        var labels: [String] = []

        _ = root.withChildNode(at: 0) { outer in
            labels.append("outer.nextNode:\(outer.withNextSibling { sibling in sibling.makeString() } ?? "nil")")
            labels.append("outer.prevNode:\(outer.withPreviousSibling { sibling in sibling.makeString() } ?? "nil")")
            labels.append("outer.nextElement:\(outer.withNextSiblingOrToken { element in describeElement(element) } ?? "nil")")
            labels.append("outer.prevElement:\(outer.withPreviousSiblingOrToken { element in describeElement(element) } ?? "nil")")

            var forwardNodes: [String] = []
            outer.forEachSibling(direction: .forward, includingSelf: true) { sibling in
                forwardNodes.append(sibling.makeString())
            }
            labels.append("outer.forwardNodes:\(forwardNodes.joined(separator: "|"))")
        }

        _ = root.withChildNode(at: 1) { rhs in
            labels.append("rhs.previousNode:\(rhs.withPreviousSibling { sibling in sibling.makeString() } ?? "nil")")
            labels.append("rhs.nextNode:\(rhs.withNextSibling { sibling in sibling.makeString() } ?? "nil")")

            var backwardNodes: [String] = []
            rhs.forEachSibling(direction: .backward, includingSelf: true) { sibling in
                backwardNodes.append(sibling.makeString())
            }
            labels.append("rhs.backwardNodes:\(backwardNodes.joined(separator: "|"))")
        }

        func describeToken13(_ token: borrowing SyntaxTokenCursor<TestLanguage>) {
            labels.append("token13.prev:\(token.withPreviousSiblingOrToken { element in describeElement(element) } ?? "nil")")
            labels.append("token13.next:\(token.withNextSiblingOrToken { element in describeElement(element) } ?? "nil")")

            var forwardElements: [String] = []
            token.forEachSiblingOrToken(direction: .forward, includingSelf: true) { element in
                forwardElements.append(describeElement(element))
            }
            labels.append("token13.forward:\(forwardElements.joined(separator: "|"))")
        }
        root.withTokenAtOffset(
            13,
            none: {},
            single: { describeToken13($0) },
            between: { _, right in describeToken13(right) }
        )

        func describeToken15(_ token: borrowing SyntaxTokenCursor<TestLanguage>) {
            labels.append("token15.next:\(token.withNextSiblingOrToken { element in describeElement(element) } ?? "nil")")
            labels.append("token15.prev:\(token.withPreviousSiblingOrToken { element in describeElement(element) } ?? "nil")")
        }
        root.withTokenAtOffset(
            15,
            none: {},
            single: { describeToken15($0) },
            between: { _, right in describeToken15(right) }
        )

        return labels
    }

    #expect(labels == [
        "outer.nextNode:f",
        "outer.prevNode:nil",
        "outer.nextElement:token:whitespace: @13",
        "outer.prevElement:token:whitespace: @1",
        "outer.forwardNodes:b c + d + e|f",
        "rhs.previousNode:b c + d + e",
        "rhs.nextNode:nil",
        "rhs.backwardNodes:f|b c + d + e",
        "token13.prev:node:list:b c + d + e",
        "token13.next:token:plus:+@14",
        "token13.forward:token:whitespace: @13|token:plus:+@14|token:whitespace: @15|node:list:f|token:whitespace: @17|token:identifier:z@18",
        "token15.next:node:list:f",
        "token15.prev:token:plus:+@14",
    ])
}

@Test func traversalAncestorsWalkNearestToRoot() throws {
    let tree = try makeTraversalTree()
    let labels = tree.withRoot { root in
        var labels: [String] = []

        _ = root.withDescendant(atPath: [2, 2]) { inner in
            var ancestors: [String] = []
            inner.forEachAncestor { ancestor in
                ancestors.append(ancestor.makeString())
            }
            labels.append("nodeAncestors:\(ancestors.joined(separator: "|"))")

            var includingSelf: [String] = []
            inner.forEachAncestor(includingSelf: true) { ancestor in
                includingSelf.append(ancestor.makeString())
            }
            labels.append("nodeAncestorsSelf:\(includingSelf.joined(separator: "|"))")
        }

        func collectTokenAncestors(_ token: borrowing SyntaxTokenCursor<TestLanguage>) {
            var ancestors: [String] = []
            token.forEachAncestor { ancestor in
                ancestors.append(ancestor.makeString())
            }
            labels.append("tokenAncestors:\(ancestors.joined(separator: "|"))")
        }
        root.withTokenAtOffset(
            8,
            none: {},
            single: { collectTokenAncestors($0) },
            between: { _, right in collectTokenAncestors(right) }
        )

        return labels
    }

    #expect(labels == [
        "nodeAncestors:b c + d + e|a b c + d + e + f z",
        "nodeAncestorsSelf:c + d|b c + d + e|a b c + d + e + f z",
        "tokenAncestors:c + d|b c + d + e|a b c + d + e + f z",
    ])
}

@Test func traversalDescendantsVisitNodesAndTokensInSourceOrder() throws {
    let tree = try makeTraversalTree()
    let labels = tree.withRoot { root in
        var labels: [String] = []

        var nodeDescendants: [String] = []
        root.forEachDescendant { descendant in
            nodeDescendants.append(descendant.makeString())
        }
        labels.append("nodes:\(nodeDescendants.joined(separator: "|"))")

        var nodeDescendantsIncludingRoot: [String] = []
        root.forEachDescendant(includingSelf: true) { descendant in
            nodeDescendantsIncludingRoot.append(descendant.makeString())
        }
        labels.append("nodesSelf:\(nodeDescendantsIncludingRoot.joined(separator: "|"))")

        _ = root.withDescendant(atPath: [2]) { outer in
            var elements: [String] = []
            outer.forEachDescendantOrToken(includingSelf: true) { element in
                elements.append(describeElement(element))
            }
            labels.append("elements:\(elements.joined(separator: "|"))")
        }

        return labels
    }

    #expect(labels == [
        "nodes:b c + d + e|c + d|e|f",
        "nodesSelf:a b c + d + e + f z|b c + d + e|c + d|e|f",
        "elements:node:list:b c + d + e|token:identifier:b@2|token:whitespace: @3|node:list:c + d|token:identifier:c@4|token:whitespace: @5|token:plus:+@6|token:whitespace: @7|token:identifier:d@8|token:whitespace: @9|token:plus:+@10|token:whitespace: @11|node:list:e|token:identifier:e@12",
    ])
}

@Test func wideTraversalPreservesOffsetsAcrossMixedChildren() throws {
    let fixture = try makeWideTraversalFixture()

    let result = fixture.tree.withRoot { root in
        var topLevel: [String] = []
        root.forEachChildOrToken { element in
            topLevel.append(describeElementWithOffset(element))
        }

        var descendants: [String] = []
        root.forEachDescendantOrToken { element in
            descendants.append(describeElementWithOffset(element))
        }

        var tokens: [String] = []
        root.tokens { token in
            tokens.append(describeToken(token))
        }

        var rangeTokens: [String] = []
        root.tokens(in: fixture.probeNodeRange) { token in
            rangeTokens.append(describeToken(token))
        }

        var walkTokens: [String] = []
        let walkControl = root.walkPreorderWithTokens { event in
            switch event {
            case .enter(let element):
                switch element {
                case .node:
                    break
                case .token(let token):
                    walkTokens.append(describeToken(token))
                }
            case .leave:
                break
            }
            return .continue
        }

        let tokenAtProbe: String? = root.withTokenAtOffset(
            fixture.probeTokenOffset,
            none: { nil },
            single: { describeToken($0) },
            between: { _, right in describeToken(right) }
        )

        let coveringProbe = root.withCoveringElement(fixture.probeNodeRange) { element in
            describeElementWithOffset(element)
        }

        let siblingProbe = root.withChildNode(at: fixture.probeNodeOrdinal) { node in
            var forward: [String] = []
            node.forEachSiblingOrToken(direction: .forward) { element in
                forward.append(describeElementWithOffset(element))
            }

            var backward: [String] = []
            node.forEachSiblingOrToken(direction: .backward) { element in
                backward.append(describeElementWithOffset(element))
            }

            let next = node.withNextSiblingOrToken { element in
                describeElementWithOffset(element)
            }
            let previous = node.withPreviousSiblingOrToken { element in
                describeElementWithOffset(element)
            }

            return (forward, backward, next, previous)
        }

        return (
            root.childCount,
            root.childOrTokenCount,
            topLevel,
            descendants,
            tokens,
            rangeTokens,
            walkControl,
            walkTokens,
            tokenAtProbe,
            coveringProbe,
            siblingProbe
        )
    }

    #expect(result.0 == fixture.nodeCount)
    #expect(result.1 == fixture.topLevelElements.count)
    #expect(result.2 == fixture.topLevelElements)
    #expect(result.3 == fixture.descendants)
    #expect(result.4 == fixture.tokens)
    #expect(result.5.filter { !$0.hasPrefix("token:missing:") } == fixture.probeNodeTokens)
    #expect(result.6 == .continue)
    #expect(result.7 == fixture.tokens)
    #expect(result.8 == fixture.probeTokenLabel)
    #expect(result.9 == fixture.topLevelElements[fixture.probeTopLevelIndex])
    #expect(result.10?.0 == Array(fixture.topLevelElements[(fixture.probeTopLevelIndex + 1)...]))
    #expect(result.10?.1 == Array(fixture.topLevelElements[..<fixture.probeTopLevelIndex].reversed()))
    #expect(result.10?.2 == fixture.topLevelElements[fixture.probeTopLevelIndex + 1])
    #expect(result.10?.3 == fixture.topLevelElements[fixture.probeTopLevelIndex - 1])
}

@Test func traversalWalkEventsRespectOrderingSkipAndStop() throws {
    let tree = try makeTraversalTree()

    let nodeWalk = tree.withRoot { root in
        var events: [String] = []
        let control = root.walkPreorder { event in
            events.append(describeNodeWalkEvent(event))
            return .continue
        }
        return (events, control)
    }
    #expect(nodeWalk.1 == .continue)
    #expect(nodeWalk.0 == [
        "enter:root:a b c + d + e + f z",
        "enter:list:b c + d + e",
        "enter:list:c + d",
        "leave:list:c + d",
        "enter:list:e",
        "leave:list:e",
        "leave:list:b c + d + e",
        "enter:list:f",
        "leave:list:f",
        "leave:root:a b c + d + e + f z",
    ])

    let skipVisit = tree.withRoot { root in
        var visited: [String] = []
        let control = root.visitPreorder { node in
            let text = node.makeString()
            visited.append(text)
            if text == "b c + d + e" {
                return .skipChildren
            }
            return .continue
        }
        return (visited, control)
    }
    #expect(skipVisit.1 == .continue)
    #expect(skipVisit.0 == [
        "a b c + d + e + f z",
        "b c + d + e",
        "f",
    ])

    let stopVisit = tree.withRoot { root in
        var visited: [String] = []
        let control = root.visitPreorder { node in
            let text = node.makeString()
            visited.append(text)
            if text == "b c + d + e" {
                return .stop
            }
            return .continue
        }
        return (visited, control)
    }
    #expect(stopVisit.1 == .stop)
    #expect(stopVisit.0 == [
        "a b c + d + e + f z",
        "b c + d + e",
    ])

    let tokenWalk = tree.withRoot { root in
        root.withDescendant(atPath: [2, 2]) { inner in
            var events: [String] = []
            let control = inner.walkPreorderWithTokens { event in
                events.append(describeElementWalkEvent(event))
                return .continue
            }
            return (events, control)
        }!
    }
    #expect(tokenWalk.1 == .continue)
    #expect(tokenWalk.0 == [
        "enter:node:list:c + d",
        "enter:token:identifier:c@4",
        "leave:token:identifier:c@4",
        "enter:token:whitespace: @5",
        "leave:token:whitespace: @5",
        "enter:token:plus:+@6",
        "leave:token:plus:+@6",
        "enter:token:whitespace: @7",
        "leave:token:whitespace: @7",
        "enter:token:identifier:d@8",
        "leave:token:identifier:d@8",
        "leave:node:list:c + d",
    ])

    let skipWalk = tree.withRoot { root in
        var events: [String] = []
        let control = root.walkPreorder { event in
            let label = describeNodeWalkEvent(event)
            events.append(label)
            if label == "enter:list:b c + d + e" {
                return .skipChildren
            }
            return .continue
        }
        return (events, control)
    }
    #expect(skipWalk.1 == .continue)
    #expect(skipWalk.0 == [
        "enter:root:a b c + d + e + f z",
        "enter:list:b c + d + e",
        "leave:list:b c + d + e",
        "enter:list:f",
        "leave:list:f",
        "leave:root:a b c + d + e + f z",
    ])

    let stopWalk = tree.withRoot { root in
        var events: [String] = []
        let control = root.walkPreorder { event in
            let label = describeNodeWalkEvent(event)
            events.append(label)
            if label == "enter:list:b c + d + e" {
                return .stop
            }
            return .continue
        }
        return (events, control)
    }
    #expect(stopWalk.1 == .stop)
    #expect(stopWalk.0 == [
        "enter:root:a b c + d + e + f z",
        "enter:list:b c + d + e",
    ])
}

@Test func handlesReplaceAndRebuildAncestorPathWithWitness() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    builder.startNode(.list)
    try builder.token(.identifier, text: "old")
    try builder.finishNode()
    try builder.finishNode()

    let buildResult = try builder.finish()
    let tree = buildResult.snapshot.makeSyntaxTree()
    let shared = tree.share()

    let listHandle = shared.withRoot { root in
        root.withChildNode(at: 0) { child in
            child.makeHandle()
        }!
    }
    #expect(listHandle.rawKind == RawSyntaxKind(TestKind.list.rawValue))

    var replacementBuilder = GreenTreeBuilder<TestLanguage>()
    replacementBuilder.startNode(.list)
    try replacementBuilder.token(.identifier, text: "new")
    try replacementBuilder.finishNode()
    let replacement = try replacementBuilder.finish()

    var cache = GreenNodeCache<TestLanguage>()
    let result = try shared.replacing(listHandle, with: replacement, cache: &cache)
    let witness = result.witness
    let newTree = result.intoTree()

    let text = newTree.withRoot { root in
        root.makeString()
    }
    #expect(text == "new")

    let oldText = shared.withRoot { root in
        root.makeString()
    }
    #expect(oldText == "old")

    #expect(witness.replacedPath == [0])
    if case .replacedRoot = witness.classify(path: [0]) {} else {
        Issue.record("Expected .replacedRoot for witness path [0]")
    }
    if case .ancestor = witness.classify(path: []) {} else {
        Issue.record("Expected .ancestor for empty path")
    }
}

@Test func incrementalRangeMappingShiftsAndInvalidates() {
    let edit = TextEdit(range: TextRange(start: 2, end: 4), replacement: "abc")
    let after = TextRange(start: 8, end: 10)
    #expect(mapRange(after, through: edit) == .shifted(TextRange(start: 9, end: 11)))

    let overlapping = TextRange(start: 3, end: 5)
    #expect(mapRange(overlapping, through: edit) == .invalidated)
}

private enum ListSpec: TypedSyntaxNode {
    typealias Lang = TestLanguage
    static let rawKind = RawSyntaxKind(TestKind.list.rawValue)
}

@Test func typedHandlesValidateKindAndMetadataStoresValues() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.missingNode(.list)
    try builder.finishNode()

    let result = try builder.finish()
    let tree = result.snapshot.makeSyntaxTree()
    let handle = tree.withRoot { root in
        root.withChildNode(at: 0) { child in
            child.makeHandle()
        }!
    }

    #expect(handle.asTyped(ListSpec.self) != nil)

    let key = SyntaxDataKey<Int>("score")
    let metadata = SyntaxMetadataStore<TestLanguage>()
    metadata.set(42, for: key, on: handle)
    #expect(metadata.value(for: key, on: handle) == 42)
}

@Test func serializationRoundTripsFullTreeAndFreshTreeIdentity() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "alpha")
    try builder.staticToken(.whitespace)
    try builder.staticToken(.plus)
    try builder.staticToken(.whitespace)
    try builder.largeToken(.identifier, text: String(repeating: "z", count: 80))
    builder.missingToken(.missing)
    try builder.finishNode()

    let result = try builder.finish()
    let tree = result.snapshot.makeSyntaxTree()
    let originalTreeID = tree.treeID
    let bytes = try tree.serializeGreenSnapshot()
    let decoded = try GreenSnapshotDecoder.decodeTree(bytes, as: TestLanguage.self)

    let decodedText = decoded.withRoot { root in
        root.makeString()
    }
    #expect(decodedText == "alpha + \(String(repeating: "z", count: 80))")
    #expect(decoded.treeID != originalTreeID)
}

@Test func serializationRoundTripsSubtreeOnly() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    builder.startNode(.list)
    try builder.token(.identifier, text: "left")
    try builder.finishNode()
    builder.startNode(.list)
    try builder.token(.identifier, text: "right")
    try builder.finishNode()
    try builder.finishNode()

    let result = try builder.finish()
    let tree = result.snapshot.makeSyntaxTree()
    let bytes = try tree.withRoot { root in
        try root.withChildNode(at: 1) { child in
            try child.serializeGreenSubtree()
        }!
    }
    let decoded = try GreenSnapshotDecoder.decodeSnapshot(bytes, as: TestLanguage.self)
    let decodedTree = decoded.makeSyntaxTree()

    let text = decodedTree.withRoot { root in
        root.makeString()
    }
    #expect(text == "right")
    #expect(decoded.root.rawKind == RawSyntaxKind(TestKind.list.rawValue))
}

@Test func serializationCanonicalizesRuntimeTokenKeysAfterReplacement() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    builder.startNode(.list)
    try builder.token(.identifier, text: "old")
    try builder.finishNode()
    try builder.finishNode()

    let buildResult = try builder.finish()
    let tree = buildResult.snapshot.makeSyntaxTree()
    let shared = tree.share()
    let listHandle = shared.withRoot { root in
        root.withChildNode(at: 0) { child in
            child.makeHandle()
        }!
    }

    var replacementBuilder = GreenTreeBuilder<TestLanguage>()
    replacementBuilder.startNode(.list)
    try replacementBuilder.token(.identifier, text: "new")
    try replacementBuilder.finishNode()
    let replacement = try replacementBuilder.finish()

    var cache = GreenNodeCache<TestLanguage>()
    let result = try shared.replacing(listHandle, with: replacement, cache: &cache)
    let replaced = result.intoTree()
    let bytes = try replaced.serializeGreenSnapshot()
    let decoded = try GreenSnapshotDecoder.decodeTree(bytes, as: TestLanguage.self)

    let text = decoded.withRoot { root in
        root.makeString()
    }
    #expect(text == "new")
}

@Test func serializationRejectsLanguageMismatchAndTruncation() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "a")
    try builder.finishNode()
    let bytes = try builder.finish().snapshot.serializeGreenSnapshot()

    #expect(throws: CambiumSerializationError.languageMismatch(
        expectedID: OtherLanguage.serializationID,
        foundID: TestLanguage.serializationID,
        expectedVersion: OtherLanguage.serializationVersion,
        foundVersion: TestLanguage.serializationVersion
    )) {
        _ = try GreenSnapshotDecoder.decodeTree(bytes, as: OtherLanguage.self)
    }

    #expect(throws: CambiumSerializationError.truncatedInput) {
        _ = try GreenSnapshotDecoder.decodeTree(Array(bytes.dropLast()), as: TestLanguage.self)
    }
}

@Test func serializationRejectsInvalidStaticTokenLength() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.staticToken(.plus)
    try builder.finishNode()
    var bytes = try builder.finish().snapshot.serializeGreenSnapshot()

    let plusKind = Array(UInt32(TestKind.plus.rawValue).littleEndianBytes)
    let plusIndex = bytes.firstIndex(ofSequence: plusKind)!
    let textLengthIndex = plusIndex + 4
    bytes[textLengthIndex] = 2

    #expect(throws: CambiumSerializationError.staticTextLengthMismatch(
        kind: RawSyntaxKind(TestKind.plus.rawValue),
        expected: 2,
        actual: 1
    )) {
        _ = try GreenSnapshotDecoder.decodeTree(bytes, as: TestLanguage.self)
    }
}

@Test func serializationRejectsStaticTextStorageForDynamicKind() throws {
    let malformed = GreenToken<TestLanguage>(
        kind: .identifier,
        textLength: .zero,
        text: .staticText
    )
    let root = try GreenNode<TestLanguage>(kind: .root, children: [.token(malformed)])
    let tree = SyntaxTree(root: root)

    #expect(throws: CambiumSerializationError.staticTextUnavailable(
        kind: RawSyntaxKind(TestKind.identifier.rawValue)
    )) {
        _ = try tree.serializeGreenSnapshot()
    }
}

@Test func serializationRejectsHashMismatch() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "a")
    try builder.finishNode()
    var bytes = try builder.finish().snapshot.serializeGreenSnapshot()

    let identifierKind = Array(UInt32(TestKind.identifier.rawValue).littleEndianBytes)
    let identifierIndex = bytes.firstIndex(ofSequence: identifierKind)!
    let hashIndex = identifierIndex + 8
    bytes[hashIndex] ^= 0xff

    #expect(throws: CambiumSerializationError.self) {
        _ = try GreenSnapshotDecoder.decodeTree(bytes, as: TestLanguage.self)
    }
}

@Test func serializationRejectsUnknownRawKind() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "a")
    try builder.finishNode()
    var bytes = try builder.finish().snapshot.serializeGreenSnapshot()

    // TestKind has cases 1...7. Locate the identifier kind in the byte
    // stream and overwrite with a UInt32 outside that enum range so the
    // decoder must reject it.
    let identifierKind = Array(UInt32(TestKind.identifier.rawValue).littleEndianBytes)
    let identifierIndex = bytes.firstIndex(ofSequence: identifierKind)!
    let unknownRawKind = UInt32(0xFFFF_FFFF)
    let unknownBytes = Array(unknownRawKind.littleEndianBytes)
    for offset in 0..<unknownBytes.count {
        bytes[identifierIndex + offset] = unknownBytes[offset]
    }

    #expect(throws: CambiumSerializationError.unknownKind(RawSyntaxKind(unknownRawKind))) {
        _ = try GreenSnapshotDecoder.decodeTree(bytes, as: TestLanguage.self)
    }
}

@Test func tokensInRangeExcludesZeroLengthTokenOutsideQueryRange() throws {
    // Audit-finding regression: a tree containing only a zero-length missing
    // token at offset 0 must not surface that token for a query like [10, 11).
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    builder.missingToken(.missing)
    try builder.finishNode()
    let tree = try builder.finish().snapshot.makeSyntaxTree()

    let collected = collectTokenLabels(tree, in: TextRange(start: 10, end: 11))
    #expect(collected.isEmpty)
}

@Test func tokensInRangeIncludesZeroLengthTokenAtLeftBoundary() throws {
    // Half-open semantics: a zero-length token at offset == range.start is
    // included alongside any non-empty tokens whose ranges intersect the
    // query. Without the fix `intersects` undershoots the left boundary for
    // empty candidates and `range.contains(start)` is the rule that
    // restores parity.
    let tree = try makeMixedZeroLengthTree()
    let collected = collectTokenLabels(tree, in: TextRange(start: 3, end: 5))
    #expect(collected == ["token:missing:@3", "token:identifier:de@3"])
}

@Test func tokensInRangeExcludesZeroLengthTokenAtRightBoundary() throws {
    // Half-open semantics: a zero-length token at offset == range.end is
    // excluded, matching how non-empty tokens are excluded at the right edge.
    let tree = try makeMixedZeroLengthTree()
    let collected = collectTokenLabels(tree, in: TextRange(start: 0, end: 3))
    #expect(collected == ["token:identifier:abc@0"])
}

@Test func tokensInRangeWithEmptyQueryYieldsNothing() throws {
    // Empty query is a degenerate range, not a point query. Callers wanting
    // point semantics should use `withTokenAtOffset`.
    let tree = try makeMixedZeroLengthTree()
    let collected = collectTokenLabels(tree, in: TextRange(start: 3, end: 3))
    #expect(collected.isEmpty)
}

@Test func tokensInRangeStillFiltersNonEmptyTokensCorrectly() throws {
    // Non-empty regression: filtering of non-empty tokens is unchanged. A
    // mid-range query yields exactly the tokens whose ranges intersect.
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "abc")     // [0, 3)
    try builder.token(.identifier, text: "def")     // [3, 6)
    builder.missingToken(.missing)                    // [6, 6) zero-length
    try builder.token(.identifier, text: "ghi")     // [6, 9)
    try builder.finishNode()
    let tree = try builder.finish().snapshot.makeSyntaxTree()

    let middle = collectTokenLabels(tree, in: TextRange(start: 3, end: 6))
    #expect(middle == ["token:identifier:def@3"])

    let trailing = collectTokenLabels(tree, in: TextRange(start: 3, end: 9))
    #expect(trailing == [
        "token:identifier:def@3",
        "token:missing:@6",
        "token:identifier:ghi@6",
    ])
}

private func makeMixedZeroLengthTree() throws -> SyntaxTree<TestLanguage> {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "abc")     // [0, 3)
    builder.missingToken(.missing)                    // [3, 3) zero-length
    try builder.token(.identifier, text: "de")      // [3, 5)
    try builder.finishNode()
    return try builder.finish().snapshot.makeSyntaxTree()
}

private func collectTokenLabels(
    _ tree: borrowing SyntaxTree<TestLanguage>,
    in range: TextRange
) -> [String] {
    var labels: [String] = []
    tree.withRoot { root in
        root.tokens(in: range) { token in
            labels.append(describeToken(token))
        }
    }
    return labels
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

private extension Array where Element == UInt8 {
    func firstIndex(ofSequence needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= count else {
            return nil
        }
        for index in 0...(count - needle.count) {
            if Array(self[index..<(index + needle.count)]) == needle {
                return index
            }
        }
        return nil
    }
}
