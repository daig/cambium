import Cambium
import CambiumSyntaxMacros

@CambiumSyntaxKind
public enum CalculatorKind: UInt32, Sendable {
    case number = 1
    case whitespace = 2
    case invalid = 3
    case realNumber = 4

    @StaticText("+")
    case plus = 10
    @StaticText("-")
    case minus = 11
    @StaticText("*")
    case star = 12
    @StaticText("/")
    case slash = 13
    @StaticText("(")
    case leftParen = 14
    @StaticText(")")
    case rightParen = 15
    @StaticText("round")
    case round = 16

    case root = 100
    case integerExpr = 101
    case unaryExpr = 102
    case binaryExpr = 103
    case groupExpr = 104
    case realExpr = 105
    case roundCallExpr = 106
    case missing = 198
    case error = 199
}
