// CalculatorTypedAST.swift

import Cambium
import CambiumSyntaxMacros

public protocol CalculatorSyntaxNode: TypedSyntaxNode, Sendable, Hashable
    where Lang == CalculatorLanguage
{
    static var kind: CalculatorKind { get }
    var syntax: SyntaxNodeHandle<CalculatorLanguage> { get }
    init(unchecked syntax: SyntaxNodeHandle<CalculatorLanguage>)
}

public extension CalculatorSyntaxNode {
    static var rawKind: RawSyntaxKind {
        CalculatorLanguage.rawKind(for: kind)
    }

    init?(_ syntax: SyntaxNodeHandle<CalculatorLanguage>) {
        guard syntax.rawKind == Self.rawKind else { return nil }
        self.init(unchecked: syntax)
    }

    var range: TextRange {
        syntax.textRange
    }
}

/// Typed wrapper for a single token. Surfaces the token's kind, range,
/// and text without forcing callers to open a `withCursor` scope at
/// every read site.
public struct CalculatorTokenSyntax: Sendable, Hashable {
    public let syntax: SyntaxTokenHandle<CalculatorLanguage>

    public init(_ syntax: SyntaxTokenHandle<CalculatorLanguage>) {
        self.syntax = syntax
    }

    public var kind: CalculatorKind {
        syntax.withCursor { $0.kind }
    }

    public var range: TextRange {
        syntax.withCursor { $0.textRange }
    }

    public var text: String {
        syntax.withCursor { $0.makeString() }
    }

    /// Stream the token's UTF-8 bytes through `body` without
    /// allocating a `String`. The literal-parsing evaluator in
    /// Tutorial 6 uses this to read integers byte-by-byte.
    public func withTextUTF8<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) throws -> R {
        try syntax.withCursor { token in
            try token.withTextUTF8(body)
        }
    }
}
