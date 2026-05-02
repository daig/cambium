// CalculatorParseResult.swift

import Cambium

public extension CalculatorParseResult {
    // ... position queries, SyntaxText helpers, FNV-1a sink from prior steps ...

    /// Every expression-shape node in the tree, in depth-first
    /// preorder. Returns owned ``CambiumCore/SyntaxNodeHandle`` values
    /// — copyable references that can be iterated, stored in
    /// dictionaries, or sent across actors after the borrowed cursor
    /// scope has ended.
    ///
    /// The `rootAndDescendantHandlesPreorder` extension is from
    /// ``CambiumOwnedTraversal``; it allocates an array. For hot-path
    /// scans, prefer borrowed traversal — handles cost ARC traffic
    /// per-node.
    var expressionHandles: [SyntaxNodeHandle<CalculatorLanguage>] {
        tree.rootAndDescendantHandlesPreorder.filter { handle in
            CalculatorLanguage.kind(for: handle.rawKind).isExpressionNode
        }
    }

    /// Every token in the tree, optionally filtered to a byte range.
    /// `tokenHandles(in:)` is the analogous owned-handle helper for
    /// tokens.
    func tokenHandles(
        in range: TextRange? = nil
    ) -> [SyntaxTokenHandle<CalculatorLanguage>] {
        tree.rootHandle().tokenHandles(in: range)
    }
}
