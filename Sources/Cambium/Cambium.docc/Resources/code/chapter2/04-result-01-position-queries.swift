// CalculatorParseResult.swift

import Cambium

public extension CalculatorParseResult {
    /// What does the parser think about a single byte position?
    /// `withTokenAtOffset` answers in three cases:
    /// - `.none`: the offset is past EOF.
    /// - `.single(token)`: the offset is strictly inside a token.
    /// - `.between(left, right)`: the offset is at a token boundary.
    ///
    /// The closure-per-case shape forces the caller to address every
    /// case. The cursors are borrowed; copy out only what you need
    /// before the closure returns.
    func describeToken(at offset: TextSize) -> String {
        tree.withRoot { root in
            root.withTokenAtOffset(
                offset,
                none: { "(no token at offset \(offset.rawValue))" },
                single: { token in
                    "single: \(CalculatorLanguage.name(for: token.kind)) \(format(token.textRange)) \"\(token.makeString())\""
                },
                between: { left, right in
                    "between: \(CalculatorLanguage.name(for: left.kind)) \(format(left.textRange)) | \(CalculatorLanguage.name(for: right.kind)) \(format(right.textRange))"
                }
            )
        }
    }

    /// What is the smallest node or token wholly covering `range`?
    /// `withCoveringElement` walks down the tree and stops at the
    /// element whose own range contains `range` but none of whose
    /// children do.
    func describeCovering(_ range: TextRange) -> String? {
        tree.withRoot { root in
            root.withCoveringElement(range) { element in
                switch element {
                case .node(let node):
                    "node: \(CalculatorLanguage.name(for: node.kind)) \(format(node.textRange))"
                case .token(let token):
                    "token: \(CalculatorLanguage.name(for: token.kind)) \(format(token.textRange))"
                }
            }
        }
    }
}

private func format(_ range: TextRange) -> String {
    "\(range.start.rawValue)..<\(range.end.rawValue)"
}
