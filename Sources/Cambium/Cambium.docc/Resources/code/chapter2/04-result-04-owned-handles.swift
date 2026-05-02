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

    func sourceFNV1a() -> UInt64 {
        var hasher = FNV1aHasher()
        do {
            try tree.withRoot { root in
                try root.withText { text in
                    try text.writeUTF8(to: &hasher)
                }
            }
        } catch {
            // FNV1aHasher.write does not throw; this branch is unreachable.
            preconditionFailure("FNV1aHasher.write threw unexpectedly: \(error)")
        }
        return hasher.hash
    }

    var expressionHandles: [SyntaxNodeHandle<CalculatorLanguage>] {
        tree.rootAndDescendantHandlesPreorder.filter { handle in
            CalculatorLanguage.kind(for: handle.rawKind).isExpressionNode
        }
    }

    func tokenHandles(
        in range: TextRange? = nil
    ) -> [SyntaxTokenHandle<CalculatorLanguage>] {
        tree.rootHandle().tokenHandles(in: range)
    }
}

private struct FNV1aHasher: UTF8Sink {
    private(set) var hash: UInt64 = 0xcbf29ce484222325
    private let prime: UInt64 = 0x100000001b3

    mutating func write(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* prime
        }
    }
}

private func format(_ range: TextRange) -> String {
    "\(range.start.rawValue)..<\(range.end.rawValue)"
}
