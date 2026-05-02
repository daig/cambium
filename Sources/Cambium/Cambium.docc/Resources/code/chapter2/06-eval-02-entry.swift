import Cambium

public func evaluateCalculatorTree(
    _ tree: SharedSyntaxTree<CalculatorLanguage>
) throws -> CalculatorValue {
    var evaluator = CalculatorEvaluator()
    return try evaluator.evaluateTree(tree)
}

internal struct CalculatorEvaluator {
    /// Open the tree, project the root through `RootSyntax`, and
    /// evaluate the (single) root expression.
    mutating func evaluateTree(
        _ tree: SharedSyntaxTree<CalculatorLanguage>
    ) throws -> CalculatorValue {
        try tree.withRoot { root in
            guard let root = RootSyntax(root.makeHandle()) else {
                throw CalculatorEvaluationError.unsupportedSyntax(
                    CalculatorLanguage.name(for: root.kind),
                    root.textRange
                )
            }
            let expressions = root.expressions
            guard let only = expressions.first, expressions.count == 1 else {
                throw CalculatorEvaluationError.unsupportedSyntax(
                    "expected a single root expression",
                    root.range
                )
            }
            return try evaluate(only)
        }
    }

    mutating func evaluate(_ expression: ExprSyntax) throws -> CalculatorValue {
        switch expression {
        case .integer(let expression): try evaluateInteger(expression)
        case .real(let expression): try evaluateReal(expression)
        case .unary(let expression): try evaluateUnary(expression)
        case .binary(let expression): try evaluateBinary(expression)
        case .group(let expression): try evaluateGroup(expression)
        case .roundCall(let expression): try evaluateRoundCall(expression)
        }
    }

    private mutating func evaluateInteger(_ expression: IntegerExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateReal(_ expression: RealExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateUnary(_ expression: UnaryExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateBinary(_ expression: BinaryExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateGroup(_ expression: GroupExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateRoundCall(_ expression: RoundCallExprSyntax) throws -> CalculatorValue { fatalError() }
}
