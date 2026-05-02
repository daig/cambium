import Cambium

public struct CalculatorParseResult: Sendable {
    public let tree: SharedSyntaxTree<CalculatorLanguage>
    public let diagnostics: [Diagnostic<CalculatorLanguage>]
}

public extension CalculatorParseResult {
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
