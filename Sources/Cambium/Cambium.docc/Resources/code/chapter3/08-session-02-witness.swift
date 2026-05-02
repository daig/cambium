// CalculatorSession.swift

import Cambium

public final class CalculatorSession {
    private var context: GreenTreeContext<CalculatorLanguage>?
    private var lastTree: SharedSyntaxTree<CalculatorLanguage>?
    private var lastDiagnostics: [Diagnostic<CalculatorLanguage>] = []
    private var incremental = IncrementalParseSession<CalculatorLanguage>()

    public init() {}

    public var counters: IncrementalParseCounters {
        incremental.counters
    }

    /// Parse `input`, optionally as the result of applying `edits` to
    /// the previous parse's source. The previous tree, the cache
    /// context, and the incremental-session reference are forwarded
    /// automatically.
    public func parse(
        _ input: String,
        edits: [TextEdit] = []
    ) throws -> SharedSyntaxTree<CalculatorLanguage> {
        let previousTree = lastTree

        // Build a fresh `GreenTreeBuilder` bound to either the
        // forwarded context (preserving green-cache hits and
        // namespace identity) or a brand-new one for the first
        // parse.
        let builder: GreenTreeBuilder<CalculatorLanguage>
        if let existing = context.take() {
            builder = GreenTreeBuilder(context: consume existing)
        } else {
            builder = GreenTreeBuilder(policy: .parseSession(maxEntries: 16_384))
        }

        var parser = CalculatorParser(
            input: input,
            builder: consume builder,
            previousTree: previousTree,
            edits: edits,
            incremental: incremental
        )
        try parser.parse()
        let output = try parser.finishBuild()

        // Order matters: read snapshot before consuming the build's
        // context.
        let tree = output.build.snapshot.makeSyntaxTree().intoShared()
        let nextContext = output.build.intoContext()

        context = consume nextContext
        lastTree = tree
        lastDiagnostics = output.diagnostics
        return tree
    }

    /// Build a ``CambiumIncremental/ParseWitness`` describing the
    /// reparse that just happened. The witness pairs old and new
    /// roots with a list of subtrees that were carried by reference
    /// — every subsequent identity-tracking pass can use it to map
    /// old-tree references onto the new tree.
    func makeParseWitness(
        previousTree: SharedSyntaxTree<CalculatorLanguage>?,
        newTree: SharedSyntaxTree<CalculatorLanguage>
    ) -> ParseWitness<CalculatorLanguage> {
        // The parser populated `incremental` with one
        // `recordAcceptedReuse` call per successful splice. Drain
        // that log here.
        return ParseWitness(
            oldRoot: previousTree?.rootGreen,
            newRoot: newTree.rootGreen,
            reusedSubtrees: incremental.consumeAcceptedReuses()
        )
    }
}

// Inside the parser:
//
// When `attemptReuse` returns successfully and the outcome is
// `.direct`, the parser adds a record:
//
//     incremental?.recordAcceptedReuse(
//         oldPath: cursor.childIndexPath(),
//         newPath: <where it landed in the new tree>,
//         green: cursor.green { $0 }
//     )
//
// `oldPath` is read from the previous-tree cursor's path; `newPath`
// is computed by the session after parsing finishes (the parser
// doesn't yet know its own output shape during the splice). The
// witness then carries a `Reuse<Lang>` per record:
//
//     reuse.oldPath          // path in v0
//     reuse.newPath          // path in v1
//     reuse.green            // the spliced green subtree
//
// Tutorial 9 uses this triple to translate per-node analysis cache
// entries from v0 onto v1.
