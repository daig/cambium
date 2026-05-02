// CalculatorLanguage.swift

import Cambium
import CambiumSyntaxMacros

@CambiumSyntaxKind
public enum CalculatorKind: UInt32, Sendable {
    case number = 1
    case whitespace = 2
    case invalid = 3
    case realNumber = 4

    // Static-text tokens always render to the same bytes; `@StaticText`
    // teaches the macro to fold the literal into `staticText(for:)` so
    // the parser passes the kind only — no per-call-site string.
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
}
