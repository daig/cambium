import CambiumCore
import Synchronization

/// A single splice on a UTF-8 source document: replace the bytes in
/// `range` with `replacementUTF8`.
///
/// `TextEdit` is the unit of change consumed by ``CambiumIncremental/ParseInput`` and by
/// ``mapRange(_:through:)``. Edits are expressed in **old-tree
/// coordinates** — the byte offsets refer to positions in the source
/// before the edit is applied.
///
/// Multiple edits in a single ``CambiumIncremental/ParseInput`` should be expressed in
/// non-overlapping order against the same baseline document.
public struct TextEdit: Sendable, Hashable {
    /// The byte range to replace, in old-tree coordinates.
    public let range: TextRange

    /// The UTF-8 bytes to splice into `range`.
    public let replacementUTF8: [UInt8]

    /// Construct an edit from explicit UTF-8 replacement bytes.
    public init(range: TextRange, replacementUTF8: [UInt8]) {
        self.range = range
        self.replacementUTF8 = replacementUTF8
    }

    /// Convenience initializer that takes a Swift `String`.
    public init(range: TextRange, replacement: String) {
        self.range = range
        self.replacementUTF8 = Array(replacement.utf8)
    }

    /// The byte length of the replacement text.
    public var replacementLength: TextSize {
        do {
            return try TextSize(exactly: replacementUTF8.count)
        } catch {
            preconditionFailure("Replacement text exceeds UInt32 byte offset space")
        }
    }
}

/// Outcome of mapping an old-tree range through a single ``CambiumIncremental/TextEdit``.
public enum RangeMappingResult: Sendable, Hashable {
    /// The mapped range is byte-for-byte identical to the input.
    /// Returned when the input range is strictly before the edit.
    case unchanged(TextRange)

    /// The mapped range was shifted by the edit's net length delta.
    /// Returned when the input range is strictly after the edit.
    case shifted(TextRange)

    /// The mapped range overlaps the edit and is invalidated. The
    /// underlying source bytes have been replaced; old offsets do not
    /// translate cleanly to the new document.
    case invalidated
}

/// Map an old-tree byte range through a single ``CambiumIncremental/TextEdit``.
///
/// Use this to update old-tree offsets after an edit has been applied —
/// for example, to translate a diagnostic's byte range to the new
/// document. Returns ``CambiumIncremental/RangeMappingResult/invalidated`` for ranges that
/// overlap the edit.
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

/// The bundle a parser receives for one parse pass: the new document
/// text, the edits that produced it, and the previous tree (if any).
///
/// Cambium itself does not parse — `ParseInput` is the contract a
/// language-specific parser implements against. The parser feeds
/// `previousTree` to ``CambiumIncremental/IncrementalParseSession/makeReuseOracle(for:)``
/// and uses the returned ``CambiumIncremental/ReuseOracle`` to splice unchanged subtrees
/// from the old tree into the new build.
public struct ParseInput<Lang: SyntaxLanguage>: Sendable {
    /// The full source text of the new document, as UTF-8 bytes.
    public let textUTF8: [UInt8]

    /// The edits, in old-tree coordinates, that transformed the previous
    /// document into ``textUTF8``. Empty for a fresh parse with no prior
    /// tree.
    public let edits: [TextEdit]

    /// The tree from the previous parse, or `nil` for a cold-start parse.
    /// The reuse oracle scans this tree for splice candidates.
    public let previousTree: SharedSyntaxTree<Lang>?

    /// Construct an input from explicit UTF-8 bytes.
    public init(
        textUTF8: [UInt8],
        edits: [TextEdit] = [],
        previousTree: SharedSyntaxTree<Lang>? = nil
    ) {
        self.textUTF8 = textUTF8
        self.edits = edits
        self.previousTree = previousTree
    }

    /// Convenience initializer that takes a Swift `String`.
    public init(
        text: String,
        edits: [TextEdit] = [],
        previousTree: SharedSyntaxTree<Lang>? = nil
    ) {
        self.init(textUTF8: Array(text.utf8), edits: edits, previousTree: previousTree)
    }
}

/// Aggregate counters tracking how often the parser asked the
/// ``CambiumIncremental/ReuseOracle`` for a candidate and how often the oracle answered.
///
/// **Offer-side semantics.** These counters reflect what the oracle was
/// asked about, not what the parser actually accepted into the new tree.
/// A high `reuseQueries` with low `reuseHits` typically means the parser
/// is asking for kinds that don't exist at the offset; a high
/// `reuseHits` with low ultimately accepted reuses (visible via
/// ``CambiumIncremental/IncrementalParseSession/consumeAcceptedReuses()``) means the parser
/// inspects candidates and rejects them, often because of context the
/// oracle cannot see.
public struct IncrementalParseCounters: Sendable, Hashable {
    /// Number of `withReusableNode` calls the parser made.
    public var reuseQueries: Int

    /// Subset of queries that returned a candidate.
    public var reuseHits: Int

    /// Sum of byte lengths of every offered candidate (not necessarily
    /// accepted).
    public var reusedBytes: UInt64

    /// Construct a counter set with explicit values. Most code reads
    /// counters from ``IncrementalParseSession/counters`` rather than
    /// constructing them.
    public init(reuseQueries: Int = 0, reuseHits: Int = 0, reusedBytes: UInt64 = 0) {
        self.reuseQueries = reuseQueries
        self.reuseHits = reuseHits
        self.reusedBytes = reusedBytes
    }
}

/// State kept across the lifetime of an incremental parser. Holds
/// offer-side counters (what the ``CambiumIncremental/ReuseOracle`` was asked about) and an
/// accepted-reuse log (what the parser/builder actually carried over).
///
/// One session typically lives for the lifetime of an editor's view of a
/// document. Each parse pass:
///
/// 1. Constructs a ``CambiumIncremental/ReuseOracle`` via
///    ``makeReuseOracle(for:)`` or ``makeReuseOracle(previousTree:edits:)``.
/// 2. Hands the oracle to the parser, which queries it for splice
///    candidates and records accepted reuses with
///    ``recordAcceptedReuse(oldPath:newPath:green:)``.
/// 3. After the parse, drains accepted reuses with
///    ``consumeAcceptedReuses()`` and uses them to construct a
///    ``CambiumIncremental/ParseWitness`` for downstream identity tracking.
///
/// **Concurrency contract.** A single `IncrementalParseSession` is safe
/// for **one active parse at a time**. Counters and the accepted-reuse
/// log are session-global; concurrent parses against the same session
/// interleave their data, and ``consumeAcceptedReuses()`` returns an
/// indeterminate mix. Use one session per parse if you parse
/// concurrently.
public final class IncrementalParseSession<Lang: SyntaxLanguage>: @unchecked Sendable {
    private let countersStorage = Mutex(IncrementalParseCounters())
    private let acceptedReusesStorage = Mutex<[Reuse<Lang>]>([])

    /// Construct a fresh session with zeroed counters.
    public init() {}

    /// The current counter snapshot. Inspecting this snapshot is
    /// thread-safe; counter values may have advanced by the time you read
    /// them if a parse is in flight.
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

    /// Convenience overload that pulls `previousTree` and `edits` from a
    /// ``CambiumIncremental/ParseInput``.
    public func makeReuseOracle(for input: ParseInput<Lang>) -> ReuseOracle<Lang> {
        makeReuseOracle(previousTree: input.previousTree, edits: input.edits)
    }
}

/// A non-copyable, parser-facing oracle that offers candidates from a
/// previous tree for splicing into a new build.
///
/// The oracle does the bookkeeping the parser shouldn't have to: it walks
/// the previous tree looking for a node of the requested kind starting at
/// the requested offset, filters candidates whose old text range was
/// invalidated by any edit, and counts offers on the parse session.
///
/// The actual splice — appending the green node to the new builder — is
/// done by the parser via `GreenTreeBuilder.reuseSubtree(_:)`. A
/// session's accepted-reuse log is updated separately with
/// ``CambiumIncremental/IncrementalParseSession/recordAcceptedReuse(oldPath:newPath:green:)``.
public struct ReuseOracle<Lang: SyntaxLanguage>: ~Copyable {
    private let previousTree: SharedSyntaxTree<Lang>?
    private let edits: [TextEdit]
    private let session: IncrementalParseSession<Lang>?

    /// Create a parser-facing reuse oracle.
    ///
    /// `edits` are interpreted in old-tree coordinates. Candidates whose
    /// old text ranges map to ``CambiumIncremental/RangeMappingResult/invalidated`` through
    /// any edit are filtered before the parser callback is invoked.
    public init(
        previousTree: SharedSyntaxTree<Lang>?,
        edits: [TextEdit] = [],
        session: IncrementalParseSession<Lang>? = nil
    ) {
        self.previousTree = previousTree
        self.edits = edits
        self.session = session
    }

    /// Look for a node of `kind` starting exactly at `offset` in the
    /// previous tree.
    ///
    /// If a candidate exists and survives the edit-validity filter, the
    /// closure runs with a borrowed cursor on the candidate. The closure
    /// can inspect the cursor and decide whether to splice it (typically
    /// via `GreenTreeBuilder.reuseSubtree(_:)`) or reject it on
    /// grammar-context grounds the oracle cannot see.
    ///
    /// Returns the closure's result, or `nil` when no candidate is
    /// offered.
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
    /// Visit every token whose range overlaps `visibleRange`.
    ///
    /// Convenience wrapper around ``SyntaxNodeCursor/tokens(in:_:)``.
    /// Useful for editor highlighters that want to render tokens for the
    /// currently visible portion of a document.
    func tokens(
        in visibleRange: TextRange,
        _ body: (borrowing SyntaxTokenCursor<Lang>) throws -> Void
    ) rethrows {
        try withRoot { root in
            try root.tokens(in: visibleRange, body)
        }
    }
}
