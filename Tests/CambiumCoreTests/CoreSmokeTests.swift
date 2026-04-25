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
