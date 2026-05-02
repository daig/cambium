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

    private mutating func evaluateInteger(_ expression: IntegerExprSyntax) throws -> CalculatorValue {
        guard let token = expression.literal else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                "missing integer literal", expression.range
            )
        }
        let parsed: Int64? = try token.withTextUTF8 { bytes in
            parseInt64(asciiDigits: bytes)
        }
        guard let value = parsed else {
            throw CalculatorEvaluationError.integerLiteralOutOfRange(
                token.text, token.range
            )
        }
        return .integer(expression.minusSign != nil ? -value : value)
    }

    private mutating func evaluateReal(_ expression: RealExprSyntax) throws -> CalculatorValue {
        guard let token = expression.literal else {
            throw CalculatorEvaluationError.unsupportedSyntax(
                "missing real literal", expression.range
            )
        }
        let text = try token.withTextUTF8 { bytes in
            String(decoding: bytes, as: UTF8.self)
        }
        guard let value = Double(text), value.isFinite else {
            throw CalculatorEvaluationError.realLiteralOutOfRange(text, token.range)
        }
        return .real(expression.minusSign != nil ? -value : value)
    }

    private mutating func evaluateUnary(_ expression: UnaryExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateBinary(_ expression: BinaryExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateGroup(_ expression: GroupExprSyntax) throws -> CalculatorValue { fatalError() }
    private mutating func evaluateRoundCall(_ expression: RoundCallExprSyntax) throws -> CalculatorValue { fatalError() }
}

internal func parseInt64(asciiDigits bytes: UnsafeBufferPointer<UInt8>) -> Int64? {
    guard !bytes.isEmpty else { return nil }
    var result: Int64 = 0
    for byte in bytes {
        guard byte >= 0x30, byte <= 0x39 else { return nil }
        let (afterMul, mulOverflow) = result.multipliedReportingOverflow(by: 10)
        guard !mulOverflow else { return nil }
        let (afterAdd, addOverflow) = afterMul.addingReportingOverflow(Int64(byte - 0x30))
        guard !addOverflow else { return nil }
        result = afterAdd
    }
    return result
}
