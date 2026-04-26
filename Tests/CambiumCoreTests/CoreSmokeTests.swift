import CambiumAnalysis
import CambiumASTSupport
import CambiumBuilder
import CambiumCore
import CambiumIncremental
import CambiumOwnedTraversal
import CambiumSerialization
import Testing

private enum TestKind: UInt32, Sendable {
    case root = 1
    case list = 2
    case identifier = 3
    case plus = 4
    case whitespace = 5
    case missing = 6
    case error = 7
}

private enum TestLanguage: SyntaxLanguage {
    typealias Kind = TestKind

    static let rootKind: TestKind = .root
    static let missingKind: TestKind = .missing
    static let errorKind: TestKind = .error
    static let serializationID = "org.cambium.tests.test-language"
    static let serializationVersion: UInt32 = 1

    static func rawKind(for kind: TestKind) -> RawSyntaxKind {
        RawSyntaxKind(kind.rawValue)
    }

    static func kind(for raw: RawSyntaxKind) -> TestKind {
        TestKind(rawValue: raw.rawValue) ?? .error
    }

    static func staticText(for kind: TestKind) -> StaticString? {
        switch kind {
        case .plus:
            "+"
        case .whitespace:
            " "
        default:
            nil
        }
    }

    static func isTrivia(_ kind: TestKind) -> Bool {
        kind == .whitespace
    }

    static func isNode(_ kind: TestKind) -> Bool {
        kind == .root || kind == .list || kind == .error || kind == .missing
    }

    static func isToken(_ kind: TestKind) -> Bool {
        !isNode(kind)
    }

    static func name(for kind: TestKind) -> String {
        "\(kind)"
    }
}

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

    return try builder.finish().makeSyntaxTree()
}

private func describeElement(_ element: borrowing SyntaxElementCursor<TestLanguage>) -> String {
    switch element {
    case .node(let node):
        "node:\(TestLanguage.name(for: node.kind)):\(node.makeString())"
    case .token(let token):
        "token:\(TestLanguage.name(for: token.kind)):\(token.makeString())@\(token.textRange.start.rawValue)"
    }
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

@Test func greenElementExposesKindAndLength() {
    let token = GreenToken<TestLanguage>(kind: .identifier, textLength: 3, text: .interned(TokenKey(0)))
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
    let tree = result.makeSyntaxTree()
    let text = tree.withRoot { root in
        root.makeString()
    }

    #expect(text == "a+é")
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
    let tree = result.makeSyntaxTree()

    let childKind = tree.withRoot { root in
        root.withChildNode(at: 0) { child in
            child.kind
        }
    }
    #expect(childKind == .list)
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
    let tree = result.makeSyntaxTree()
    let shared = tree.share()

    let tokenAtFive = shared.withRoot { root in
        root.withToken(at: 5) { token in
            token.makeString()
        }
    }
    #expect(tokenAtFive == "+")

    let rootHandle = shared.rootHandle()
    let tokens = rootHandle.tokenHandles()
    #expect(tokens.count == 5)
    #expect(tokens[4].withCursor { $0.makeString() } == "right")
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

        _ = root.withToken(at: 13) { token in
            labels.append("token13.prev:\(token.withPreviousSiblingOrToken { element in describeElement(element) } ?? "nil")")
            labels.append("token13.next:\(token.withNextSiblingOrToken { element in describeElement(element) } ?? "nil")")

            var forwardElements: [String] = []
            token.forEachSiblingOrToken(direction: .forward, includingSelf: true) { element in
                forwardElements.append(describeElement(element))
            }
            labels.append("token13.forward:\(forwardElements.joined(separator: "|"))")
        }

        _ = root.withToken(at: 15) { token in
            labels.append("token15.next:\(token.withNextSiblingOrToken { element in describeElement(element) } ?? "nil")")
            labels.append("token15.prev:\(token.withPreviousSiblingOrToken { element in describeElement(element) } ?? "nil")")
        }

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

        _ = root.withToken(at: 8) { token in
            var ancestors: [String] = []
            token.forEachAncestor { ancestor in
                ancestors.append(ancestor.makeString())
            }
            labels.append("tokenAncestors:\(ancestors.joined(separator: "|"))")
        }

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

@Test func anchorsResolveAndReplacementRebuildsAncestorPath() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    builder.startNode(.list)
    try builder.token(.identifier, text: "old")
    try builder.finishNode()
    try builder.finishNode()

    let result = try builder.finish()
    let tree = result.makeSyntaxTree()
    let shared = tree.share()

    let anchor = shared.withRoot { root in
        root.withChildNode(at: 0) { child in
            child.makeAnchor()
        }!
    }

    let resolvedKind = shared.resolve(anchor) { node in
        node.kind
    }
    #expect(resolvedKind == .list)

    var replacementBuilder = GreenTreeBuilder<TestLanguage>()
    replacementBuilder.startNode(.list)
    try replacementBuilder.token(.identifier, text: "new")
    try replacementBuilder.finishNode()
    let replacement = try replacementBuilder.finish()

    var cache = GreenNodeCache<TestLanguage>()
    let newTree = try shared.replacing(anchor, with: replacement, cache: &cache)
    let text = newTree?.withRoot { root in
        root.makeString()
    }
    #expect(text == "new")

    let oldText = shared.withRoot { root in
        root.makeString()
    }
    #expect(oldText == "old")
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
    let tree = result.makeSyntaxTree()
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
    let tree = result.makeSyntaxTree()
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
    let tree = result.makeSyntaxTree()
    let bytes = try tree.withRoot { root in
        try root.withChildNode(at: 1) { child in
            try child.serializeGreenSubtree()
        }!
    }
    let decoded = try GreenSnapshotDecoder.decodeBuildResult(bytes, as: TestLanguage.self)
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

    let result = try builder.finish()
    let tree = result.makeSyntaxTree()
    let shared = tree.share()
    let anchor = shared.withRoot { root in
        root.withChildNode(at: 0) { child in
            child.makeAnchor()
        }!
    }

    var replacementBuilder = GreenTreeBuilder<TestLanguage>()
    replacementBuilder.startNode(.list)
    try replacementBuilder.token(.identifier, text: "new")
    try replacementBuilder.finishNode()
    let replacement = try replacementBuilder.finish()

    var cache = GreenNodeCache<TestLanguage>()
    let replaced = try shared.replacing(anchor, with: replacement, cache: &cache)!
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
    let bytes = try builder.finish().serializeGreenSnapshot()

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
    var bytes = try builder.finish().serializeGreenSnapshot()

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

@Test func serializationRejectsHashMismatch() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "a")
    try builder.finishNode()
    var bytes = try builder.finish().serializeGreenSnapshot()

    let identifierKind = Array(UInt32(TestKind.identifier.rawValue).littleEndianBytes)
    let identifierIndex = bytes.firstIndex(ofSequence: identifierKind)!
    let hashIndex = identifierIndex + 8
    bytes[hashIndex] ^= 0xff

    #expect(throws: CambiumSerializationError.self) {
        _ = try GreenSnapshotDecoder.decodeTree(bytes, as: TestLanguage.self)
    }
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
