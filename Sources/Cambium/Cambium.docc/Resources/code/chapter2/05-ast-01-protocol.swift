// CalculatorTypedAST.swift

import Cambium
import CambiumSyntaxMacros

/// Common protocol for every typed AST wrapper. It refines
/// ``CambiumASTSupport/TypedSyntaxNode`` (which binds a Swift type to
/// one ``CambiumCore/RawSyntaxKind``) and pins `Lang` to
/// `CalculatorLanguage` so all conformers share one grammar.
public protocol CalculatorSyntaxNode: TypedSyntaxNode, Sendable, Hashable
    where Lang == CalculatorLanguage
{
    /// The kind every node of this type must have.
    static var kind: CalculatorKind { get }

    /// The wrapped handle. The `@CambiumSyntaxNode` macro will
    /// generate this stored property.
    var syntax: SyntaxNodeHandle<CalculatorLanguage> { get }

    /// Construct without checking the handle's kind. The macro emits
    /// this initializer; client code should prefer the failable
    /// `init(_:)` extension below.
    init(unchecked syntax: SyntaxNodeHandle<CalculatorLanguage>)
}

public extension CalculatorSyntaxNode {
    /// `TypedSyntaxNode.rawKind` derived from the kind enum so client
    /// code only states the kind once (in the macro argument).
    static var rawKind: RawSyntaxKind {
        CalculatorLanguage.rawKind(for: kind)
    }

    /// Failable down-cast: returns `nil` when the handle's kind does
    /// not match `Self.kind`. The canonical entry point for building a
    /// typed wrapper from an arbitrary handle.
    init?(_ syntax: SyntaxNodeHandle<CalculatorLanguage>) {
        guard syntax.rawKind == Self.rawKind else { return nil }
        self.init(unchecked: syntax)
    }

    var range: TextRange {
        syntax.textRange
    }
}
