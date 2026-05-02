// CalculatorFold.swift

import Cambium

/// One subtree replacement applied during folding. Carries the
/// witness returned by `replacing(_:with:context:)` so consumers can
/// translate references through the change.
public struct FoldStep: Sendable {
    public let oldKind: CalculatorKind
    public let newKind: CalculatorKind
    public let oldText: String
    public let newText: String
    public let replacedPath: SyntaxNodePath
    public let witness: ReplacementWitness<CalculatorLanguage>
    public let newTree: SharedSyntaxTree<CalculatorLanguage>
}

/// The full record of a fold pass: every step in order plus the
/// final tree.
public struct FoldReport: Sendable {
    public let steps: [FoldStep]
    public let finalTree: SharedSyntaxTree<CalculatorLanguage>
}

/// One foldable expression discovered in a tree.
internal struct FoldCandidate {
    var handle: SyntaxNodeHandle<CalculatorLanguage>
    var path: SyntaxNodePath
    var oldKind: CalculatorKind
    var oldText: String
    var literal: FoldLiteral
}

/// The replacement literal we'd splice for a given evaluated value.
internal struct FoldLiteral {
    var value: CalculatorValue
    var expressionKind: CalculatorKind
    var tokenKind: CalculatorKind
    var digitsText: String
    var needsLeadingMinus: Bool
}
