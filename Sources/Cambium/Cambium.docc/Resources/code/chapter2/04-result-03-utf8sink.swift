// CalculatorParseResult.swift
//
// Lifted from CalculatorParser.swift into its own file. We grow it
// here with query helpers built on the borrowed-cursor APIs.

import Cambium

public struct CalculatorParseResult: Sendable {
    public let tree: SharedSyntaxTree<CalculatorLanguage>
    public let diagnostics: [Diagnostic<CalculatorLanguage>]
}

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

    /// Whether the source bytes contain `needle` as a UTF-8 substring.
    /// Streams the document via ``CambiumCore/SyntaxText`` — only
    /// `needle.utf8` is materialized as an `Array`, the document
    /// itself is never copied.
    ///
    /// Per `SyntaxText`'s contract an empty needle returns `true`.
    func sourceContains(_ needle: String) -> Bool {
        let bytes = Array(needle.utf8)
        return tree.withRoot { root in
            root.withText { text in
                text.contains(bytes)
            }
        }
    }

    /// First byte-range matching `needle` in source order.
    /// `firstRange(of:)` runs a KMP-style scan over the chunk-by-chunk
    /// view that `SyntaxText` exposes — no per-chunk allocation.
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

    /// FNV-1a hash of the source bytes, computed by streaming chunks
    /// through a custom ``CambiumCore/UTF8Sink``. The sink sees the
    /// document one buffer at a time without ever holding it as a
    /// `String` — the right shape for hashing, checksums, or any
    /// reduction over bytes.
    ///
    /// Two parses of identical source produce identical hashes; any
    /// byte-level change shifts the hash.
    func sourceFNV1a() -> UInt64 {
        var hasher = FNV1aHasher()
        do {
            try tree.withRoot { root in
                try root.withText { text in
                    try text.writeUTF8(to: &hasher)
                }
            }
        } catch {
            // FNV1aHasher.write does not throw; this branch is
            // unreachable. Crash loudly if the contract changes.
            preconditionFailure("FNV1aHasher.write threw unexpectedly: \(error)")
        }
        return hasher.hash
    }
}

/// A reference `UTF8Sink` conformance: an FNV-1a 64-bit hash that
/// consumes the document's UTF-8 chunks without buffering. The same
/// hash family Cambium uses internally for its green-node identity.
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
