import Cambium
import CambiumSyntaxMacros

@CambiumSyntaxKind
public enum CalculatorKind: UInt32, Sendable {
    case number = 1
    case whitespace = 2
    case invalid = 3
    case realNumber = 4
}
