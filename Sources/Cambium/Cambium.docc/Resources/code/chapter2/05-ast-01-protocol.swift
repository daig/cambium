import Cambium
import CambiumSyntaxMacros

public protocol CalculatorSyntaxNode: TypedSyntaxNode, Sendable, Hashable
    where Lang == CalculatorLanguage
{
    /// The kind every node of this type must have.
    static var kind: CalculatorKind { get }

    /// The wrapped handle. The `@CambiumSyntaxNode` macro will
    /// generate this stored property.
    var syntax: SyntaxNodeHandle<CalculatorLanguage> { get }

    init(unchecked syntax: SyntaxNodeHandle<CalculatorLanguage>)
}

public extension CalculatorSyntaxNode {
    /// `TypedSyntaxNode.rawKind` derived from the kind enum so client
    /// code only states the kind once (in the macro argument).
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
