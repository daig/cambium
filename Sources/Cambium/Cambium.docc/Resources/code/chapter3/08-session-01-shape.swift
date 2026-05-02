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
}
