// CalculatorFold.swift

import Cambium

/// One subtree replacement applied during folding. Carries the
/// witness returned by `replacing(_:with:context:)` so consumers can
/// translate references through the change.
public struct FoldStep: Sendable {
    public let oldKind: CalculatorKind
    public let newKind: CalculatorKind
    public let oldText: String
    public let newText: String
    public let replacedPath: SyntaxNodePath
    public let witness: ReplacementWitness<CalculatorLanguage>
    public let newTree: SharedSyntaxTree<CalculatorLanguage>
}

/// The full record of a fold pass: every step in order plus the
/// final tree.
public struct FoldReport: Sendable {
    public let steps: [FoldStep]
    public let finalTree: SharedSyntaxTree<CalculatorLanguage>
}

/// One foldable expression discovered in a tree.
internal struct FoldCandidate {
    var handle: SyntaxNodeHandle<CalculatorLanguage>
    var path: SyntaxNodePath
    var oldKind: CalculatorKind
    var oldText: String
    var literal: FoldLiteral
}

/// The replacement literal we'd splice for a given evaluated value.
internal struct FoldLiteral {
    var value: CalculatorValue
    var expressionKind: CalculatorKind
    var tokenKind: CalculatorKind
    var digitsText: String
    var needsLeadingMinus: Bool
}

/// First foldable expression in `tree`, discovered by post-order
/// walk. Children fold before their parents, so a single pass picks
/// the innermost evaluable position.
internal func firstFoldCandidate(
    in tree: SharedSyntaxTree<CalculatorLanguage>
) -> FoldCandidate? {
    tree.withRoot { root in
        var candidate: FoldCandidate?
        // `walkPreorder` emits both `.enter` and `.leave` events.
        // Acting on `.leave` gives us post-order: children visited
        // before their parents.
        _ = root.walkPreorder { event in
            switch event {
            case .enter:
                return .continue
            case .leave(let node):
                guard candidate == nil,
                      let expression = ExprSyntax(node.makeHandle()),
                      let value = evaluatedValue(for: expression),
                      let literal = makeLiteral(for: value)
                else {
                    return .continue
                }
                candidate = FoldCandidate(
                    handle: node.makeHandle(),
                    path: node.childIndexPath(),
                    oldKind: node.kind,
                    oldText: node.makeString(),
                    literal: literal
                )
                return .stop
            }
        }
        return candidate
    }
}

/// Whether `expression` is foldable: every direct operand must
/// already be a literal, in which case we evaluate it. Recursive
/// folding happens by repeated passes — one fold per call until
/// `firstFoldCandidate` returns `nil`.
private func evaluatedValue(for expression: ExprSyntax) -> CalculatorValue? {
    switch expression {
    case .integer, .real:
        return nil
    case .unary(let expression):
        guard expression.operand?.isLiteral == true else { return nil }
    case .binary(let expression):
        guard expression.lhs?.isLiteral == true,
              expression.rhs?.isLiteral == true,
              expression.operatorToken != nil else { return nil }
    case .group(let expression):
        guard expression.expression?.isLiteral == true else { return nil }
    case .roundCall(let expression):
        guard expression.argument?.isLiteral == true else { return nil }
    }
    var evaluator = CalculatorEvaluator()
    return try? evaluator.evaluate(expression)
}

private func makeLiteral(for value: CalculatorValue) -> FoldLiteral? {
    switch value {
    case .integer(let value):
        guard value != .min else { return nil }
        return FoldLiteral(
            value: .integer(value),
            expressionKind: .integerExpr,
            tokenKind: .number,
            digitsText: String(value.magnitude),
            needsLeadingMinus: value < 0
        )
    case .real(let value):
        guard value.isFinite else { return nil }
        // Real literal canonicalization elided for tutorial brevity.
        return nil
    }
}

private extension ExprSyntax {
    var isLiteral: Bool {
        switch self {
        case .integer, .real: true
        default: false
        }
    }
}

/// Bundles a `FoldStep` with the noncopyable context the next
/// iteration will consume. Swift tuples can't yet hold `~Copyable`
/// elements, so this struct fills the same role.
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
