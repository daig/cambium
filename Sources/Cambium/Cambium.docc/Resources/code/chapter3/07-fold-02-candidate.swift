// CalculatorFold.swift

import Cambium

// ... `FoldStep`, `FoldReport`, `FoldCandidate`, `FoldLiteral` from prior steps ...

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
