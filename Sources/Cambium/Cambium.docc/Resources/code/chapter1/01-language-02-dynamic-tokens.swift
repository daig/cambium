// CalculatorLanguage.swift

import Cambium
import CambiumSyntaxMacros

@CambiumSyntaxKind
public enum CalculatorKind: UInt32, Sendable {
    // Dynamic-text tokens: their text varies per occurrence so the
    // builder will receive an explicit string at each call site.
    case number = 1
    case whitespace = 2
    case invalid = 3
    case realNumber = 4
}
