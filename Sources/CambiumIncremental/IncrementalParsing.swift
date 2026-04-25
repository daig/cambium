import CambiumCore
import Synchronization

public struct TextEdit: Sendable, Hashable {
    public let range: TextRange
    public let replacementUTF8: [UInt8]

    public init(range: TextRange, replacementUTF8: [UInt8]) {
        self.range = range
        self.replacementUTF8 = replacementUTF8
    }

    public init(range: TextRange, replacement: String) {
        self.range = range
        self.replacementUTF8 = Array(replacement.utf8)
    }

    public var replacementLength: TextSize {
        do {
            return try TextSize(exactly: replacementUTF8.count)
        } catch {
            preconditionFailure("Replacement text exceeds UInt32 byte offset space")
        }
    }
}

public enum RangeMappingResult: Sendable, Hashable {
    case unchanged(TextRange)
    case shifted(TextRange)
    case invalidated
}

public func mapRange(_ range: TextRange, through edit: TextEdit) -> RangeMappingResult {
    if range.end <= edit.range.start {
        return .unchanged(range)
    }

    let oldLength = edit.range.length.rawValue
    let newLength = edit.replacementLength.rawValue

    if edit.range.end <= range.start {
        if newLength >= oldLength {
            return .shifted(range.shifted(by: TextSize(newLength - oldLength)))
        }

        let delta = oldLength - newLength
        return .shifted(TextRange(
            start: TextSize(range.start.rawValue - delta),
            end: TextSize(range.end.rawValue - delta)
        ))
    }

    return .invalidated
}

public struct ParseInput<Lang: SyntaxLanguage>: Sendable {
    public let textUTF8: [UInt8]
    public let edits: [TextEdit]
    public let previousTree: SharedSyntaxTree<Lang>?

    public init(
        textUTF8: [UInt8],
        edits: [TextEdit] = [],
        previousTree: SharedSyntaxTree<Lang>? = nil
    ) {
        self.textUTF8 = textUTF8
        self.edits = edits
        self.previousTree = previousTree
    }

    public init(
        text: String,
        edits: [TextEdit] = [],
        previousTree: SharedSyntaxTree<Lang>? = nil
    ) {
        self.init(textUTF8: Array(text.utf8), edits: edits, previousTree: previousTree)
    }
}

public struct IncrementalParseCounters: Sendable, Hashable {
    public var reuseQueries: Int
    public var reuseHits: Int
    public var reusedBytes: UInt64

    public init(reuseQueries: Int = 0, reuseHits: Int = 0, reusedBytes: UInt64 = 0) {
        self.reuseQueries = reuseQueries
        self.reuseHits = reuseHits
        self.reusedBytes = reusedBytes
    }
}

public final class IncrementalParseSession<Lang: SyntaxLanguage>: @unchecked Sendable {
    private let countersStorage = Mutex(IncrementalParseCounters())

    public init() {}

    public var counters: IncrementalParseCounters {
        countersStorage.withLock { $0 }
    }

    public func recordReuseQuery(hitBytes: TextSize?) {
        countersStorage.withLock { counters in
            counters.reuseQueries += 1
            if let hitBytes {
                counters.reuseHits += 1
                counters.reusedBytes += UInt64(hitBytes.rawValue)
            }
        }
    }

    public func makeReuseOracle(previousTree: SharedSyntaxTree<Lang>?) -> ReuseOracle<Lang> {
        ReuseOracle(previousTree: previousTree, session: self)
    }
}

public struct ReuseOracle<Lang: SyntaxLanguage>: ~Copyable {
    private let previousTree: SharedSyntaxTree<Lang>?
    private let session: IncrementalParseSession<Lang>?

    public init(previousTree: SharedSyntaxTree<Lang>?, session: IncrementalParseSession<Lang>? = nil) {
        self.previousTree = previousTree
        self.session = session
    }

    public borrowing func withReusableNode<R>(
        startingAt offset: TextSize,
        kind: Lang.Kind,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        guard let previousTree else {
            session?.recordReuseQuery(hitBytes: nil)
            return nil
        }

        let rawKind = Lang.rawKind(for: kind)
        let result = try previousTree.withRoot { root in
            try root.firstReusableNode(startingAt: offset, rawKind: rawKind, body)
        }
        session?.recordReuseQuery(hitBytes: result == nil ? nil : TextSize.zero)
        return result
    }
}

private extension SyntaxNodeCursor {
    borrowing func firstReusableNode<R>(
        startingAt offset: TextSize,
        rawKind: RawSyntaxKind,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? {
        if textRange.start == offset && self.rawKind == rawKind {
            return try body(self)
        }

        var result: R?
        try forEachChild { child in
            if result == nil, child.textRange.start <= offset, offset <= child.textRange.end {
                result = try child.firstReusableNode(startingAt: offset, rawKind: rawKind, body)
            }
        }
        return result
    }
}

public extension SharedSyntaxTree {
    func tokens(
        in visibleRange: TextRange,
        _ body: (borrowing SyntaxTokenCursor<Lang>) throws -> Void
    ) rethrows {
        try withRoot { root in
            try root.tokens(in: visibleRange, body)
        }
    }
}
