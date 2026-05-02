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

    func sourceContains(_ needle: String) -> Bool {
        let bytes = Array(needle.utf8)
        return tree.withRoot { root in
            root.withText { text in
                text.contains(bytes)
            }
        }
    }

    func sourceFirstRange(of needle: String) -> TextRange? {
        let bytes = Array(needle.utf8)
        return tree.withRoot { root in
            root.withText { text in
                text.firstRange(of: bytes)
            }
        }
    }

    /// Bytes covered by `range`, materialized as a `String`. Only the
    /// slice's bytes are copied.
    func sourceSlice(_ range: TextRange) -> String? {
        tree.withRoot { root -> String? in
            root.withText { text -> String? in
                let bounds = TextRange(
                    start: .zero,
                    length: TextSize(UInt32(text.utf8Count))
                )
                guard bounds.contains(range) else { return nil }
                return text.sliced(range).makeString()
            }
        }
    }
}

private func format(_ range: TextRange) -> String {
    "\(range.start.rawValue)..<\(range.end.rawValue)"
}
