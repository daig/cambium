// CalculatorEvaluator.swift

import Cambium

// ... `evaluateCalculatorTree` and `CalculatorEvaluator` from prior steps ...

internal extension CalculatorEvaluator {
    /// Parse the integer literal directly from the token's UTF-8 bytes.
    ///
    /// `withTextUTF8` exposes the token's bytes through a borrowed
    /// buffer pointer — there is no `String` allocation per token.
    /// `parseInt64` accumulates digits with overflow checks; on the
    /// rare error path we materialize `text` for the diagnostic.
    func evaluateInteger(_ expression: IntegerExprSyntax) throws -> CalculatorValue {
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

    /// Reals fall back to `Double(_:)` because the stdlib has no
    /// from-bytes parser. We still avoid `token.makeString()` on the
    /// happy path by going through `withTextUTF8` and decoding the
    /// borrowed slice directly.
    func evaluateReal(_ expression: RealExprSyntax) throws -> CalculatorValue {
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
