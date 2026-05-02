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
        let canonical = String(value)
        guard isPlainDecimal(canonical) else { return nil }
        let needsLeadingMinus = canonical.hasPrefix("-")
        return FoldLiteral(
            value: .real(value),
            expressionKind: .realExpr,
            tokenKind: .realNumber,
            digitsText: needsLeadingMinus
                ? String(canonical.dropFirst())
                : canonical,
            needsLeadingMinus: needsLeadingMinus
        )
    }
}

private func isPlainDecimal(_ text: String) -> Bool {
    var scalars = Array(text.unicodeScalars)
    if scalars.first?.value == 0x2d {
        scalars.removeFirst()
    }
    guard let dotIndex = scalars.firstIndex(where: { $0.value == 0x2e }),
          dotIndex > scalars.startIndex,
          dotIndex < scalars.index(before: scalars.endIndex)
    else {
        return false
    }
    for scalar in scalars[..<dotIndex] {
        guard scalar.value >= 0x30, scalar.value <= 0x39 else {
            return false
        }
    }
    for scalar in scalars[scalars.index(after: dotIndex)...] {
        guard scalar.value >= 0x30, scalar.value <= 0x39 else {
            return false
        }
    }
    return true
}

private extension ExprSyntax {
    var isLiteral: Bool {
        switch self {
        case .integer, .real: true
        default: false
        }
    }
}
