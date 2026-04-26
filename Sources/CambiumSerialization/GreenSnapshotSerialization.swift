import CambiumBuilder
import CambiumCore

public enum CambiumSerializationError: Error, Sendable, Equatable {
    case badMagic
    case unsupportedFormatVersion(UInt32)
    case languageMismatch(expectedID: String, foundID: String, expectedVersion: UInt32, foundVersion: UInt32)
    case truncatedInput
    case trailingBytes(Int)
    case invalidUTF8
    case integerOverflow
    case invalidRootElementID(UInt32)
    case rootIsToken(UInt32)
    case invalidElementReference(UInt32)
    case invalidTokenReference(UInt32)
    case invalidLargeTokenReference(UInt32)
    case invalidRecordTag(UInt8)
    case invalidTextStorageTag(UInt8)
    case staticTextUnavailable(kind: RawSyntaxKind)
    case staticTextLengthMismatch(kind: RawSyntaxKind, expected: TextSize, actual: TextSize)
    case dynamicTextLengthMismatch(kind: RawSyntaxKind, expected: TextSize, actual: TextSize)
    case nodeLengthMismatch(kind: RawSyntaxKind, expected: TextSize, actual: TextSize)
    case hashMismatch(kind: RawSyntaxKind, expected: UInt64, actual: UInt64)
}

private enum GreenSnapshotFormat {
    static let magic: [UInt8] = Array("CMBGRN01".utf8)
    static let version: UInt32 = 1

    static let tokenRecord: UInt8 = 0
    static let nodeRecord: UInt8 = 1

    static let staticText: UInt8 = 0
    static let internedText: UInt8 = 1
    static let largeText: UInt8 = 2
    static let missingText: UInt8 = 3
}

private struct BinaryWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeMagic() {
        bytes.append(contentsOf: GreenSnapshotFormat.magic)
    }

    mutating func writeUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func writeUInt64(_ value: UInt64) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 32))
        bytes.append(UInt8(truncatingIfNeeded: value >> 40))
        bytes.append(UInt8(truncatingIfNeeded: value >> 48))
        bytes.append(UInt8(truncatingIfNeeded: value >> 56))
    }

    mutating func writeString(_ value: String) throws {
        let data = Array(value.utf8)
        guard let count = UInt32(exactly: data.count) else {
            throw CambiumSerializationError.integerOverflow
        }
        writeUInt32(count)
        bytes.append(contentsOf: data)
    }
}

private struct BinaryReader {
    let bytes: [UInt8]
    private(set) var offset: Int = 0

    var remaining: Int {
        bytes.count - offset
    }

    mutating func readMagic() throws {
        guard remaining >= GreenSnapshotFormat.magic.count else {
            throw CambiumSerializationError.truncatedInput
        }
        let found = Array(bytes[offset..<(offset + GreenSnapshotFormat.magic.count)])
        offset += GreenSnapshotFormat.magic.count
        guard found == GreenSnapshotFormat.magic else {
            throw CambiumSerializationError.badMagic
        }
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw CambiumSerializationError.truncatedInput
        }
        defer {
            offset += 1
        }
        return bytes[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else {
            throw CambiumSerializationError.truncatedInput
        }
        let value = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        offset += 4
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        guard remaining >= 8 else {
            throw CambiumSerializationError.truncatedInput
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        offset += 8
        return value
    }

    mutating func readString() throws -> String {
        let count = try readUInt32()
        guard let intCount = Int(exactly: count) else {
            throw CambiumSerializationError.integerOverflow
        }
        guard remaining >= intCount else {
            throw CambiumSerializationError.truncatedInput
        }
        let data = bytes[offset..<(offset + intCount)]
        offset += intCount
        guard let string = String(validating: data, as: UTF8.self) else {
            throw CambiumSerializationError.invalidUTF8
        }
        return string
    }
}

private enum EncodedTextStorage: Hashable {
    case staticText
    case missing
    case interned(UInt32)
    case large(UInt32)
}

private enum EncodedElementRecord {
    case token(
        rawKind: RawSyntaxKind,
        textLength: TextSize,
        structuralHash: UInt64,
        text: EncodedTextStorage
    )
    case node(
        rawKind: RawSyntaxKind,
        textLength: TextSize,
        structuralHash: UInt64,
        childIDs: [UInt32]
    )
}

private struct CollectedElement<Lang: SyntaxLanguage> {
    var id: UInt32
    var element: GreenElement<Lang>
}

private struct GreenSnapshotEncoder<Lang: SyntaxLanguage> {
    private var internedTexts: [String] = []
    private var internedTextIDs: [String: UInt32] = [:]
    private var largeTexts: [String] = []
    private var largeTextIDs: [String: UInt32] = [:]
    private var elementIDs: [GreenElement<Lang>: UInt32] = [:]
    private var records: [EncodedElementRecord] = []

    mutating func encode(root: GreenNode<Lang>, resolver: any TokenResolver) throws -> [UInt8] {
        let rootID = try collect(node: root, resolver: resolver).id
        var writer = BinaryWriter()
        writer.writeMagic()
        writer.writeUInt32(GreenSnapshotFormat.version)
        try writer.writeString(Lang.serializationID)
        writer.writeUInt32(Lang.serializationVersion)
        writer.writeUInt32(rootID)

        try writer.writeUInt32(checkedCount(internedTexts.count))
        for text in internedTexts {
            try writer.writeString(text)
        }

        try writer.writeUInt32(checkedCount(largeTexts.count))
        for text in largeTexts {
            try writer.writeString(text)
        }

        try writer.writeUInt32(checkedCount(records.count))
        for record in records {
            try write(record, to: &writer)
        }
        return writer.bytes
    }

    private mutating func collect(
        node: GreenNode<Lang>,
        resolver: any TokenResolver
    ) throws -> CollectedElement<Lang> {
        var childIDs: [UInt32] = []
        var canonicalChildren: [GreenElement<Lang>] = []
        childIDs.reserveCapacity(node.childCount)
        canonicalChildren.reserveCapacity(node.childCount)

        for index in 0..<node.childCount {
            let collected: CollectedElement<Lang>
            switch node.child(at: index) {
            case .node(let child):
                collected = try collect(node: child, resolver: resolver)
            case .token(let token):
                collected = try collect(token: token, resolver: resolver)
            }
            childIDs.append(collected.id)
            canonicalChildren.append(collected.element)
        }

        let canonicalNode = try GreenNode<Lang>(kind: node.rawKind, children: canonicalChildren)
        guard canonicalNode.textLength == node.textLength else {
            throw CambiumSerializationError.nodeLengthMismatch(
                kind: node.rawKind,
                expected: node.textLength,
                actual: canonicalNode.textLength
            )
        }

        let element = GreenElement<Lang>.node(canonicalNode)
        if let id = elementIDs[element] {
            return CollectedElement(id: id, element: element)
        }

        let id = try checkedCount(records.count)
        elementIDs[element] = id
        records.append(.node(
            rawKind: canonicalNode.rawKind,
            textLength: canonicalNode.textLength,
            structuralHash: canonicalNode.structuralHash,
            childIDs: childIDs
        ))
        return CollectedElement(id: id, element: element)
    }

    private mutating func collect(
        token: GreenToken<Lang>,
        resolver: any TokenResolver
    ) throws -> CollectedElement<Lang> {
        let encodedStorage: EncodedTextStorage
        let canonicalStorage: TokenTextStorage

        switch token.textStorage {
        case .staticText:
            try validateStaticTokenLength(token)
            encodedStorage = .staticText
            canonicalStorage = .staticText
        case .missing:
            try validateMissingTokenLength(token)
            encodedStorage = .missing
            canonicalStorage = .missing
        case .interned(let key):
            let text = resolver.resolve(key)
            try validateDynamicTokenLength(token, text: text)
            let index = try internedTextIndex(for: text)
            encodedStorage = .interned(index)
            canonicalStorage = .interned(TokenKey(index))
        case .ownedLargeText(let id):
            let text = resolver.resolveLargeText(id)
            try validateDynamicTokenLength(token, text: text)
            let index = try largeTextIndex(for: text)
            encodedStorage = .large(index)
            canonicalStorage = .ownedLargeText(LargeTokenTextID(index))
        }

        let canonicalToken = GreenToken<Lang>(
            kind: token.rawKind,
            textLength: token.textLength,
            text: canonicalStorage
        )
        let element = GreenElement<Lang>.token(canonicalToken)
        if let id = elementIDs[element] {
            return CollectedElement(id: id, element: element)
        }

        let id = try checkedCount(records.count)
        elementIDs[element] = id
        records.append(.token(
            rawKind: canonicalToken.rawKind,
            textLength: canonicalToken.textLength,
            structuralHash: canonicalToken.structuralHash,
            text: encodedStorage
        ))
        return CollectedElement(id: id, element: element)
    }

    private mutating func internedTextIndex(for text: String) throws -> UInt32 {
        if let index = internedTextIDs[text] {
            return index
        }
        let index = try checkedCount(internedTexts.count)
        internedTexts.append(text)
        internedTextIDs[text] = index
        return index
    }

    private mutating func largeTextIndex(for text: String) throws -> UInt32 {
        if let index = largeTextIDs[text] {
            return index
        }
        let index = try checkedCount(largeTexts.count)
        largeTexts.append(text)
        largeTextIDs[text] = index
        return index
    }

    private func validateStaticTokenLength(_ token: GreenToken<Lang>) throws {
        guard let text = Lang.staticText(for: token.kind) else {
            guard token.textLength == .zero else {
                throw CambiumSerializationError.staticTextUnavailable(kind: token.rawKind)
            }
            return
        }

        let actual = try staticTextLength(text)
        guard actual == token.textLength else {
            throw CambiumSerializationError.staticTextLengthMismatch(
                kind: token.rawKind,
                expected: token.textLength,
                actual: actual
            )
        }
    }

    private func validateMissingTokenLength(_ token: GreenToken<Lang>) throws {
        guard token.textLength == .zero else {
            throw CambiumSerializationError.staticTextLengthMismatch(
                kind: token.rawKind,
                expected: token.textLength,
                actual: .zero
            )
        }
    }

    private func validateDynamicTokenLength(_ token: GreenToken<Lang>, text: String) throws {
        let actual = try TextSize(byteCountOf: text)
        guard actual == token.textLength else {
            throw CambiumSerializationError.dynamicTextLengthMismatch(
                kind: token.rawKind,
                expected: token.textLength,
                actual: actual
            )
        }
    }

    private func write(_ record: EncodedElementRecord, to writer: inout BinaryWriter) throws {
        switch record {
        case .token(let rawKind, let textLength, let structuralHash, let text):
            writer.writeUInt8(GreenSnapshotFormat.tokenRecord)
            writer.writeUInt32(rawKind.rawValue)
            writer.writeUInt32(textLength.rawValue)
            writer.writeUInt64(structuralHash)
            switch text {
            case .staticText:
                writer.writeUInt8(GreenSnapshotFormat.staticText)
            case .missing:
                writer.writeUInt8(GreenSnapshotFormat.missingText)
            case .interned(let index):
                writer.writeUInt8(GreenSnapshotFormat.internedText)
                writer.writeUInt32(index)
            case .large(let index):
                writer.writeUInt8(GreenSnapshotFormat.largeText)
                writer.writeUInt32(index)
            }
        case .node(let rawKind, let textLength, let structuralHash, let childIDs):
            writer.writeUInt8(GreenSnapshotFormat.nodeRecord)
            writer.writeUInt32(rawKind.rawValue)
            writer.writeUInt32(textLength.rawValue)
            writer.writeUInt64(structuralHash)
            try writer.writeUInt32(checkedCount(childIDs.count))
            for childID in childIDs {
                writer.writeUInt32(childID)
            }
        }
    }
}

private enum DecodedTextStorage {
    case staticText
    case missing
    case interned(UInt32)
    case large(UInt32)
}

private enum DecodedElementRecord {
    case token(
        rawKind: RawSyntaxKind,
        textLength: TextSize,
        structuralHash: UInt64,
        text: DecodedTextStorage
    )
    case node(
        rawKind: RawSyntaxKind,
        textLength: TextSize,
        structuralHash: UInt64,
        childIDs: [UInt32]
    )
}

public enum GreenSnapshotDecoder {
    public static func decodeTree<Lang: SyntaxLanguage>(
        _ bytes: [UInt8],
        as language: Lang.Type = Lang.self
    ) throws -> SyntaxTree<Lang> {
        let result: GreenBuildResult<Lang> = try decodeBuildResult(bytes, as: language)
        return result.makeSyntaxTree()
    }

    public static func decodeBuildResult<Lang: SyntaxLanguage>(
        _ bytes: [UInt8],
        as language: Lang.Type = Lang.self
    ) throws -> GreenBuildResult<Lang> {
        var decoder = GreenSnapshotDecodedTreeBuilder<Lang>(bytes: bytes)
        return try decoder.decode()
    }
}

private struct GreenSnapshotDecodedTreeBuilder<Lang: SyntaxLanguage> {
    var reader: BinaryReader

    init(bytes: [UInt8]) {
        self.reader = BinaryReader(bytes: bytes)
    }

    mutating func decode() throws -> GreenBuildResult<Lang> {
        try reader.readMagic()
        let formatVersion = try reader.readUInt32()
        guard formatVersion == GreenSnapshotFormat.version else {
            throw CambiumSerializationError.unsupportedFormatVersion(formatVersion)
        }

        let languageID = try reader.readString()
        let languageVersion = try reader.readUInt32()
        guard languageID == Lang.serializationID, languageVersion == Lang.serializationVersion else {
            throw CambiumSerializationError.languageMismatch(
                expectedID: Lang.serializationID,
                foundID: languageID,
                expectedVersion: Lang.serializationVersion,
                foundVersion: languageVersion
            )
        }

        let rootID = try reader.readUInt32()
        let internedTexts = try readStringTable()
        let largeTexts = try readStringTable()
        let records = try readRecords()
        guard reader.remaining == 0 else {
            throw CambiumSerializationError.trailingBytes(reader.remaining)
        }
        guard let rootIndex = Int(exactly: rootID), records.indices.contains(rootIndex) else {
            throw CambiumSerializationError.invalidRootElementID(rootID)
        }

        let elements = try rebuildElements(
            records: records,
            internedTexts: internedTexts,
            largeTexts: largeTexts
        )
        guard case .node(let root) = elements[rootIndex] else {
            throw CambiumSerializationError.rootIsToken(rootID)
        }

        return GreenBuildResult(
            root: root,
            resolver: TokenTextResolver(interned: internedTexts, large: largeTexts)
        )
    }

    private mutating func readStringTable() throws -> [String] {
        let count = try reader.readUInt32()
        guard let intCount = Int(exactly: count) else {
            throw CambiumSerializationError.integerOverflow
        }
        var result: [String] = []
        result.reserveCapacity(intCount)
        for _ in 0..<intCount {
            result.append(try reader.readString())
        }
        return result
    }

    private mutating func readRecords() throws -> [DecodedElementRecord] {
        let count = try reader.readUInt32()
        guard let intCount = Int(exactly: count) else {
            throw CambiumSerializationError.integerOverflow
        }
        var records: [DecodedElementRecord] = []
        records.reserveCapacity(intCount)
        for _ in 0..<intCount {
            records.append(try readRecord())
        }
        return records
    }

    private mutating func readRecord() throws -> DecodedElementRecord {
        let tag = try reader.readUInt8()
        let rawKind = RawSyntaxKind(try reader.readUInt32())
        let textLength = TextSize(try reader.readUInt32())
        let structuralHash = try reader.readUInt64()

        switch tag {
        case GreenSnapshotFormat.tokenRecord:
            let textTag = try reader.readUInt8()
            switch textTag {
            case GreenSnapshotFormat.staticText:
                return .token(
                    rawKind: rawKind,
                    textLength: textLength,
                    structuralHash: structuralHash,
                    text: .staticText
                )
            case GreenSnapshotFormat.missingText:
                return .token(
                    rawKind: rawKind,
                    textLength: textLength,
                    structuralHash: structuralHash,
                    text: .missing
                )
            case GreenSnapshotFormat.internedText:
                return .token(
                    rawKind: rawKind,
                    textLength: textLength,
                    structuralHash: structuralHash,
                    text: .interned(try reader.readUInt32())
                )
            case GreenSnapshotFormat.largeText:
                return .token(
                    rawKind: rawKind,
                    textLength: textLength,
                    structuralHash: structuralHash,
                    text: .large(try reader.readUInt32())
                )
            default:
                throw CambiumSerializationError.invalidTextStorageTag(textTag)
            }
        case GreenSnapshotFormat.nodeRecord:
            let childCount = try reader.readUInt32()
            guard let intChildCount = Int(exactly: childCount) else {
                throw CambiumSerializationError.integerOverflow
            }
            var childIDs: [UInt32] = []
            childIDs.reserveCapacity(intChildCount)
            for _ in 0..<intChildCount {
                childIDs.append(try reader.readUInt32())
            }
            return .node(
                rawKind: rawKind,
                textLength: textLength,
                structuralHash: structuralHash,
                childIDs: childIDs
            )
        default:
            throw CambiumSerializationError.invalidRecordTag(tag)
        }
    }

    private func rebuildElements(
        records: [DecodedElementRecord],
        internedTexts: [String],
        largeTexts: [String]
    ) throws -> [GreenElement<Lang>] {
        var elements: [GreenElement<Lang>] = []
        elements.reserveCapacity(records.count)

        for index in records.indices {
            switch records[index] {
            case .token(let rawKind, let textLength, let structuralHash, let text):
                let token = try rebuildToken(
                    rawKind: rawKind,
                    textLength: textLength,
                    structuralHash: structuralHash,
                    text: text,
                    internedTexts: internedTexts,
                    largeTexts: largeTexts
                )
                elements.append(.token(token))
            case .node(let rawKind, let textLength, let structuralHash, let childIDs):
                var children: [GreenElement<Lang>] = []
                children.reserveCapacity(childIDs.count)
                for childID in childIDs {
                    guard let childIndex = Int(exactly: childID), childIndex < index else {
                        throw CambiumSerializationError.invalidElementReference(childID)
                    }
                    children.append(elements[childIndex])
                }
                let node = try GreenNode<Lang>(kind: rawKind, children: children)
                guard node.textLength == textLength else {
                    throw CambiumSerializationError.nodeLengthMismatch(
                        kind: rawKind,
                        expected: textLength,
                        actual: node.textLength
                    )
                }
                guard node.structuralHash == structuralHash else {
                    throw CambiumSerializationError.hashMismatch(
                        kind: rawKind,
                        expected: structuralHash,
                        actual: node.structuralHash
                    )
                }
                elements.append(.node(node))
            }
        }

        return elements
    }

    private func rebuildToken(
        rawKind: RawSyntaxKind,
        textLength: TextSize,
        structuralHash: UInt64,
        text: DecodedTextStorage,
        internedTexts: [String],
        largeTexts: [String]
    ) throws -> GreenToken<Lang> {
        let storage: TokenTextStorage
        switch text {
        case .staticText:
            try validateStaticTokenLength(rawKind: rawKind, textLength: textLength)
            storage = .staticText
        case .missing:
            try validateMissingTokenLength(rawKind: rawKind, textLength: textLength)
            storage = .missing
        case .interned(let index):
            guard let intIndex = Int(exactly: index), internedTexts.indices.contains(intIndex) else {
                throw CambiumSerializationError.invalidTokenReference(index)
            }
            try validateDynamicTokenLength(
                rawKind: rawKind,
                textLength: textLength,
                text: internedTexts[intIndex]
            )
            storage = .interned(TokenKey(index))
        case .large(let index):
            guard let intIndex = Int(exactly: index), largeTexts.indices.contains(intIndex) else {
                throw CambiumSerializationError.invalidLargeTokenReference(index)
            }
            try validateDynamicTokenLength(
                rawKind: rawKind,
                textLength: textLength,
                text: largeTexts[intIndex]
            )
            storage = .ownedLargeText(LargeTokenTextID(index))
        }

        let token = GreenToken<Lang>(kind: rawKind, textLength: textLength, text: storage)
        guard token.structuralHash == structuralHash else {
            throw CambiumSerializationError.hashMismatch(
                kind: rawKind,
                expected: structuralHash,
                actual: token.structuralHash
            )
        }
        return token
    }

    private func validateStaticTokenLength(rawKind: RawSyntaxKind, textLength: TextSize) throws {
        let kind = Lang.kind(for: rawKind)
        guard let text = Lang.staticText(for: kind) else {
            guard textLength == .zero else {
                throw CambiumSerializationError.staticTextUnavailable(kind: rawKind)
            }
            return
        }

        let actual = try staticTextLength(text)
        guard actual == textLength else {
            throw CambiumSerializationError.staticTextLengthMismatch(
                kind: rawKind,
                expected: textLength,
                actual: actual
            )
        }
    }

    private func validateMissingTokenLength(rawKind: RawSyntaxKind, textLength: TextSize) throws {
        guard textLength == .zero else {
            throw CambiumSerializationError.staticTextLengthMismatch(
                kind: rawKind,
                expected: textLength,
                actual: .zero
            )
        }
    }

    private func validateDynamicTokenLength(
        rawKind: RawSyntaxKind,
        textLength: TextSize,
        text: String
    ) throws {
        let actual = try TextSize(byteCountOf: text)
        guard actual == textLength else {
            throw CambiumSerializationError.dynamicTextLengthMismatch(
                kind: rawKind,
                expected: textLength,
                actual: actual
            )
        }
    }
}

private func checkedCount(_ count: Int) throws -> UInt32 {
    guard let value = UInt32(exactly: count) else {
        throw CambiumSerializationError.integerOverflow
    }
    return value
}

private func staticTextLength(_ text: StaticString) throws -> TextSize {
    var count = 0
    text.withUTF8Buffer { bytes in
        count = bytes.count
    }
    return try TextSize(exactly: count)
}

public extension SharedSyntaxTree {
    func serializeGreenSnapshot() throws -> [UInt8] {
        try encodeGreenSnapshot(root: rootGreen, resolver: resolver)
    }
}

public extension SyntaxTree {
    borrowing func serializeGreenSnapshot() throws -> [UInt8] {
        try encodeGreenSnapshot(root: rootGreen, resolver: resolver)
    }
}

public extension SyntaxNodeCursor {
    borrowing func serializeGreenSubtree() throws -> [UInt8] {
        try green { node in
            try encodeGreenSnapshot(root: node, resolver: resolver)
        }
    }
}

public extension GreenBuildResult {
    func serializeGreenSnapshot() throws -> [UInt8] {
        try encodeGreenSnapshot(root: root, resolver: resolver)
    }
}

private func encodeGreenSnapshot<Lang: SyntaxLanguage>(
    root: GreenNode<Lang>,
    resolver: any TokenResolver
) throws -> [UInt8] {
    var encoder = GreenSnapshotEncoder<Lang>()
    return try encoder.encode(root: root, resolver: resolver)
}
