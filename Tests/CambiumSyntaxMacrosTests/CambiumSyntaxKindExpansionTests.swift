import CambiumSyntaxMacrosPlugin
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class CambiumSyntaxKindExpansionTests: XCTestCase {
    private let testMacros: [String: Macro.Type] = [
        "CambiumSyntaxKind": CambiumSyntaxKindMacro.self,
        "CambiumSyntaxNode": CambiumSyntaxNodeMacro.self,
        "StaticText": StaticTextMacro.self,
    ]

    func testSyntaxKindExpansion() {
        assertMacroExpansion(
            """
            @CambiumSyntaxKind
            enum MacroKind: UInt32 {
                case root = 1
                @StaticText("+")
                case plus = 2
                case identifier = 3
            }
            """,
            expandedSource:
            """
            enum MacroKind: UInt32 {
                case root = 1
                case plus = 2
                case identifier = 3
            }

            extension MacroKind: CambiumCore.SyntaxKind {
                static func rawKind(for kind: Self) -> CambiumCore.RawSyntaxKind {
                    CambiumCore.RawSyntaxKind(kind.rawValue)
                }
                static func kind(for raw: CambiumCore.RawSyntaxKind) -> Self {
                    guard let kind = Self(rawValue: raw.rawValue) else {
                        preconditionFailure("Unknown raw syntax kind \\(raw.rawValue) for MacroKind")
                    }
                    return kind
                }
                static func staticText(for kind: Self) -> StaticString? {
                    switch kind {
                    case .plus:
                        "+"
                    default:
                        nil
                    }
                }
                static func name(for kind: Self) -> String {
                    switch kind {
                    case .root:
                        "root"
                    case .plus:
                        "plus"
                    case .identifier:
                        "identifier"
                    }
                }
            }
            """,
            macros: testMacros
        )
    }

    func testSyntaxKindExpansionPropagatesPublicAccess() {
        assertMacroExpansion(
            """
            @CambiumSyntaxKind
            public enum MacroKind: UInt32 {
                case root = 1
                @StaticText("+")
                case plus = 2
                case identifier = 3
            }
            """,
            expandedSource:
            """
            public enum MacroKind: UInt32 {
                case root = 1
                case plus = 2
                case identifier = 3
            }

            extension MacroKind: CambiumCore.SyntaxKind {
                public static func rawKind(for kind: Self) -> CambiumCore.RawSyntaxKind {
                    CambiumCore.RawSyntaxKind(kind.rawValue)
                }
                public static func kind(for raw: CambiumCore.RawSyntaxKind) -> Self {
                    guard let kind = Self(rawValue: raw.rawValue) else {
                        preconditionFailure("Unknown raw syntax kind \\(raw.rawValue) for MacroKind")
                    }
                    return kind
                }
                public static func staticText(for kind: Self) -> StaticString? {
                    switch kind {
                    case .plus:
                        "+"
                    default:
                        nil
                    }
                }
                public static func name(for kind: Self) -> String {
                    switch kind {
                    case .root:
                        "root"
                    case .plus:
                        "plus"
                    case .identifier:
                        "identifier"
                    }
                }
            }
            """,
            macros: testMacros
        )
    }

    func testSyntaxKindExpansionPropagatesPackageAccess() {
        assertMacroExpansion(
            """
            @CambiumSyntaxKind
            package enum MacroKind: UInt32 {
                case root = 1
            }
            """,
            expandedSource:
            """
            package enum MacroKind: UInt32 {
                case root = 1
            }

            extension MacroKind: CambiumCore.SyntaxKind {
                package static func rawKind(for kind: Self) -> CambiumCore.RawSyntaxKind {
                    CambiumCore.RawSyntaxKind(kind.rawValue)
                }
                package static func kind(for raw: CambiumCore.RawSyntaxKind) -> Self {
                    guard let kind = Self(rawValue: raw.rawValue) else {
                        preconditionFailure("Unknown raw syntax kind \\(raw.rawValue) for MacroKind")
                    }
                    return kind
                }
                package static func staticText(for kind: Self) -> StaticString? {
                    nil
                }
                package static func name(for kind: Self) -> String {
                    switch kind {
                    case .root:
                        "root"
                    }
                }
            }
            """,
            macros: testMacros
        )
    }

    func testRejectsNonEnumTargets() {
        assertMacroExpansion(
            """
            @CambiumSyntaxKind
            struct NotKind {
            }
            """,
            expandedSource:
            """
            struct NotKind {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@CambiumSyntaxKind can only be attached to an enum",
                    line: 1,
                    column: 1
                ),
            ],
            macros: testMacros
        )
    }

    func testRejectsInvalidEnumShape() {
        assertMacroExpansion(
            """
            @CambiumSyntaxKind
            enum BadKind: UInt32 {
                case root = 1
                case missing
                case alsoRoot = 1
                case payload(String) = 2
            }
            """,
            expandedSource:
            """
            enum BadKind: UInt32 {
                case root = 1
                case missing
                case alsoRoot = 1
                case payload(String) = 2
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@CambiumSyntaxKind cases must have explicit raw values",
                    line: 4,
                    column: 10
                ),
                DiagnosticSpec(
                    message: "duplicate raw value 1 already used by case root",
                    line: 5,
                    column: 21
                ),
                DiagnosticSpec(
                    message: "@CambiumSyntaxKind cases cannot have associated values",
                    line: 6,
                    column: 10
                ),
            ],
            macros: testMacros
        )
    }

    func testRejectsNonUInt32RawType() {
        assertMacroExpansion(
            """
            @CambiumSyntaxKind
            enum BadKind: Int {
                case root = 1
            }
            """,
            expandedSource:
            """
            enum BadKind: Int {
                case root = 1
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@CambiumSyntaxKind requires an enum with raw type UInt32",
                    line: 2,
                    column: 6
                ),
            ],
            macros: testMacros
        )
    }

    func testRejectsInvalidStaticTextArgument() {
        assertMacroExpansion(
            """
            @CambiumSyntaxKind
            enum BadKind: UInt32 {
                @StaticText(1)
                case plus = 1
            }
            """,
            expandedSource:
            """
            enum BadKind: UInt32 {
                case plus = 1
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@StaticText requires a single string literal argument",
                    line: 3,
                    column: 5
                ),
            ],
            macros: testMacros
        )
    }

    func testSyntaxNodeExpansion() {
        assertMacroExpansion(
            """
            @CambiumSyntaxNode(CalculatorKind.self, for: .integerExpr)
            public struct IntegerExprSyntax: CalculatorSyntaxNode {
                public var literal: CalculatorTokenSyntax? {
                    nil
                }
            }
            """,
            expandedSource:
            """
            public struct IntegerExprSyntax: CalculatorSyntaxNode {
                public var literal: CalculatorTokenSyntax? {
                    nil
                }

                public static let kind: CalculatorKind = .integerExpr

                public let syntax: CambiumCore.SyntaxNodeHandle<Lang>

                public init(unchecked syntax: CambiumCore.SyntaxNodeHandle<Lang>) {
                    self.syntax = syntax
                }
            }
            """,
            macros: testMacros
        )
    }

    func testSyntaxNodeExpansionUsesInternalAccessByDefault() {
        assertMacroExpansion(
            """
            @CambiumSyntaxNode(CalculatorKind.self, for: .integerExpr)
            struct IntegerExprSyntax: CalculatorSyntaxNode {
            }
            """,
            expandedSource:
            """
            struct IntegerExprSyntax: CalculatorSyntaxNode {

                static let kind: CalculatorKind = .integerExpr

                let syntax: CambiumCore.SyntaxNodeHandle<Lang>

                init(unchecked syntax: CambiumCore.SyntaxNodeHandle<Lang>) {
                    self.syntax = syntax
                }
            }
            """,
            macros: testMacros
        )
    }

    func testSyntaxNodeRejectsNonStructTargets() {
        assertMacroExpansion(
            """
            @CambiumSyntaxNode(CalculatorKind.self, for: .integerExpr)
            enum IntegerExprSyntax {
            }
            """,
            expandedSource:
            """
            enum IntegerExprSyntax {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@CambiumSyntaxNode can only be attached to a struct",
                    line: 1,
                    column: 1
                ),
            ],
            macros: testMacros
        )
    }

    func testSyntaxNodeRejectsInvalidArguments() {
        assertMacroExpansion(
            """
            @CambiumSyntaxNode(for: .integerExpr)
            struct IntegerExprSyntax: CalculatorSyntaxNode {
            }
            """,
            expandedSource:
            """
            struct IntegerExprSyntax: CalculatorSyntaxNode {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@CambiumSyntaxNode requires arguments '<Kind>.self, for: <kind>'",
                    line: 1,
                    column: 1
                ),
            ],
            macros: testMacros
        )
    }

}
