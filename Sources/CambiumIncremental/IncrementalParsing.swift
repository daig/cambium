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

/// State kept across the lifetime of an incremental parser. Holds offer-side
/// counters (what the `ReuseOracle` was asked about) and an accepted-reuse
/// log (what the parser/builder actually carried over).
///
/// Concurrency contract: a single `IncrementalParseSession` is safe for
/// **one active parse at a time**. Counters and the accepted-reuse log are
/// session-global; concurrent parses against the same session interleave
/// their data, and `consumeAcceptedReuses()` returns an indeterminate mix.
/// Use one session per parse if you parse concurrently.
public final class IncrementalParseSession<Lang: SyntaxLanguage>: @unchecked Sendable {
    private let countersStorage = Mutex(IncrementalParseCounters())
    private let acceptedReusesStorage = Mutex<[Reuse<Lang>]>([])

    public init() {}

    public var counters: IncrementalParseCounters {
        countersStorage.withLock { $0 }
    }

    /// Record an oracle offer. `hitBytes` is the matched node's text length
    /// when the oracle returned a candidate, or `nil` when no match was
    /// found. Note that an offer is not the same as an accepted reuse —
    /// the parser may inspect a candidate and decline. Counters reflect
    /// offers; the accepted-reuse log is updated separately via
    /// `recordAcceptedReuse(...)`.
    public func recordReuseQuery(hitBytes: TextSize?) {
        countersStorage.withLock { counters in
            counters.reuseQueries += 1
            if let hitBytes {
                counters.reuseHits += 1
                counters.reusedBytes += UInt64(hitBytes.rawValue)
            }
        }
    }

    /// Record that the parser/builder accepted a reused subtree from the
    /// previous tree at `oldPath` and spliced it into the new tree at
    /// `newPath`. The integrator drains this log via
    /// `consumeAcceptedReuses()` to populate `ParseWitness.reusedSubtrees`.
    public func recordAcceptedReuse(
        oldPath: SyntaxNodePath,
        newPath: SyntaxNodePath,
        green: GreenNode<Lang>
    ) {
        acceptedReusesStorage.withLock { log in
            log.append(Reuse(green: green, oldPath: oldPath, newPath: newPath))
        }
    }

    /// Drain the accepted-reuse log atomically. Call after a parse
    /// completes to gather the reuses for `ParseWitness` construction. A
    /// subsequent call before another parse records reuses returns an
    /// empty array — the log does not accumulate across parses.
    public func consumeAcceptedReuses() -> [Reuse<Lang>] {
        acceptedReusesStorage.withLock { log in
            let drained = log
            log.removeAll(keepingCapacity: true)
            return drained
        }
    }

    /// Create a parser-facing reuse oracle for `previousTree`.
    ///
    /// `edits` are interpreted in old-tree coordinates. The oracle will not
    /// offer a candidate whose old text range is invalidated by any edit.
    public func makeReuseOracle(
        previousTree: SharedSyntaxTree<Lang>?,
        edits: [TextEdit] = []
    ) -> ReuseOracle<Lang> {
        ReuseOracle(previousTree: previousTree, edits: edits, session: self)
    }

    public func makeReuseOracle(for input: ParseInput<Lang>) -> ReuseOracle<Lang> {
        makeReuseOracle(previousTree: input.previousTree, edits: input.edits)
    }
}

public struct ReuseOracle<Lang: SyntaxLanguage>: ~Copyable {
    private let previousTree: SharedSyntaxTree<Lang>?
    private let edits: [TextEdit]
    private let session: IncrementalParseSession<Lang>?

    /// Create a parser-facing reuse oracle.
    ///
    /// `edits` are interpreted in old-tree coordinates. Candidates whose old
    /// text ranges map to `.invalidated` through any edit are filtered before
    /// the parser callback is invoked.
    public init(
        previousTree: SharedSyntaxTree<Lang>?,
        edits: [TextEdit] = [],
        session: IncrementalParseSession<Lang>? = nil
    ) {
        self.previousTree = previousTree
        self.edits = edits
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
        let edits = edits
        let outcome = try previousTree.withRoot { root in
            try root.firstReusableNode(
                startingAt: offset,
                rawKind: rawKind,
                invalidatingEdits: edits,
                body
            )
        }
        session?.recordReuseQuery(hitBytes: outcome?.hitBytes)
        return outcome?.value
    }
}

private extension SyntaxNodeCursor {
    borrowing func firstReusableNode<R>(
        startingAt offset: TextSize,
        rawKind: RawSyntaxKind,
        invalidatingEdits edits: [TextEdit],
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> (value: R, hitBytes: TextSize)? {
        var result: (value: R, hitBytes: TextSize)?
        _ = try visitPreorder { candidate in
            let range = candidate.textRange
            guard range.start <= offset, offset <= range.end else {
                return .skipChildren
            }

            if range.start == offset
                && candidate.rawKind == rawKind
                && rangeIsReusable(range, through: edits)
            {
                result = (try body(candidate), range.length)
                return .stop
            }

            return .continue
        }
        return result
    }

    private func rangeIsReusable(_ range: TextRange, through edits: [TextEdit]) -> Bool {
        for edit in edits {
            if case .invalidated = mapRange(range, through: edit) {
                return false
            }
        }
        return true
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
