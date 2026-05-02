// CalculatorFold.swift

import Cambium

// ... `FoldStep`, `FoldReport`, and `firstFoldCandidate` from prior steps ...

internal struct FoldApplyOutput: ~Copyable {
    var step: FoldStep
    private var context: GreenTreeContext<CalculatorLanguage>

    init(step: FoldStep, context: consuming GreenTreeContext<CalculatorLanguage>) {
        self.step = step
        self.context = context
    }

    consuming func intoContext() -> GreenTreeContext<CalculatorLanguage> {
        context
    }
}

/// Build the replacement subtree, splice it in, and return the
/// resulting step plus the forwarded context. The context comes back
/// because `replacing(_:with:context:)` consumes it; the caller will
/// pass it to the next iteration.
internal func applyFold(
    _ candidate: FoldCandidate,
    in tree: SharedSyntaxTree<CalculatorLanguage>,
    context: consuming GreenTreeContext<CalculatorLanguage>
) throws -> FoldApplyOutput {
    // Build a tiny replacement tree using the same context the
    // surrounding edit will splice into. Reusing the context keeps
    // token-key namespace identity intact, so the splice takes the
    // direct (non-remapping) path.
    var builder = GreenTreeBuilder<CalculatorLanguage>(context: consume context)
    builder.startNode(candidate.literal.expressionKind)
    if candidate.literal.needsLeadingMinus {
        try builder.staticToken(.minus)
    }
    try builder.token(candidate.literal.tokenKind, text: candidate.literal.digitsText)
    try builder.finishNode()
    let build = try builder.finish()

    // The replacement is a `ResolvedGreenNode` — a green subtree
    // bundled with the resolver that produced its tokens. The
    // surrounding tree's context will splice it as-is when their
    // namespaces match.
    let replacement = ResolvedGreenNode(
        root: build.root,
        resolver: build.resolver
    )
    var replacementContext = build.intoContext()

    let result = try tree.replacing(
        candidate.handle,
        with: replacement,
        context: &replacementContext
    )

    let step = FoldStep(
        oldKind: candidate.oldKind,
        newKind: candidate.literal.expressionKind,
        oldText: candidate.oldText,
        newText: candidate.literal.needsLeadingMinus
            ? "-\(candidate.literal.digitsText)"
            : candidate.literal.digitsText,
        replacedPath: candidate.path,
        witness: result.witness,
        newTree: result.intoTree().intoShared()
    )
    return FoldApplyOutput(step: step, context: consume replacementContext)
}
