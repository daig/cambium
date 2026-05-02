// CalculatorFold.swift

import Cambium

public struct FoldStep: Sendable {
    public let oldKind: CalculatorKind
    public let newKind: CalculatorKind
    public let oldText: String
    public let newText: String
    public let replacedPath: SyntaxNodePath
    public let witness: ReplacementWitness<CalculatorLanguage>
    public let newTree: SharedSyntaxTree<CalculatorLanguage>
}

public struct FoldReport: Sendable {
    public let steps: [FoldStep]
    public let finalTree: SharedSyntaxTree<CalculatorLanguage>
}

internal struct FoldCandidate {
    var handle: SyntaxNodeHandle<CalculatorLanguage>
    var path: SyntaxNodePath
    var oldKind: CalculatorKind
    var oldText: String
    var literal: FoldLiteral
}

internal struct FoldLiteral {
    var value: CalculatorValue
    var expressionKind: CalculatorKind
    var tokenKind: CalculatorKind
    var digitsText: String
    var needsLeadingMinus: Bool
}

internal func firstFoldCandidate(
    in tree: SharedSyntaxTree<CalculatorLanguage>
) -> FoldCandidate? {
    tree.withRoot { root in
        var candidate: FoldCandidate?
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
