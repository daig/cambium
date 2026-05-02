// CalculatorParseResult.swift
//
// The public surface most consumers touch. Wraps a `SharedSyntaxTree`
// plus the parser's diagnostics, and exposes convenience helpers that
// each demonstrate a different Cambium subsystem:
//
// - `tree` is the raw `SharedSyntaxTree<CalculatorLanguage>`. Hand it to
//   any `Cambium` API that takes a tree.
// - `expressionHandles` / `tokenHandles(in:)` (in **Owned-handle**
//   extension) demonstrate `CambiumOwnedTraversal`. Returns
//   reference-counted handles that survive outside borrow scopes.
// - `sourceContains` / `sourceFirstRange(of:)` / `sourceSlice(_:)` /
//   `sourceFNV1a()` (in **SyntaxText** extension) demonstrate
//   `SyntaxText` + `UTF8Sink`: scan and slice the document's UTF-8
//   bytes without materializing a `String` for the document.

import Cambium

public struct CalculatorParseResult: Sendable {
    public let tree: SharedSyntaxTree<CalculatorLanguage>
    public let diagnostics: [CalculatorDiagnostic]

    public init(
        tree: SharedSyntaxTree<CalculatorLanguage>,
        diagnostics: [CalculatorDiagnostic]
    ) {
        self.tree = tree
        self.diagnostics = diagnostics
    }

    init(
        tree: SharedSyntaxTree<CalculatorLanguage>,
        diagnostics: [Diagnostic<CalculatorLanguage>]
    ) {
        self.init(
            tree: tree,
            diagnostics: diagnostics.map(CalculatorDiagnostic.init(_:))
        )
    }

    public var isValid: Bool {
        diagnostics.isEmpty
    }

    /// The full source text the tree was parsed from. Allocates the whole
    /// document; for byte-level scans that don't need a `String`, use
    /// `sourceContains` / `sourceFirstRange(of:)` / `sourceSlice(_:)`.
    public var sourceText: String {
        tree.withRoot { root in
            root.makeString()
        }
    }

    /// Evaluate the parsed expression, throwing if any diagnostics were
    /// emitted by the parser.
    public func evaluate() throws -> CalculatorValue {
        guard diagnostics.isEmpty else {
            throw CalculatorEvaluationError.invalidSyntax(
                diagnostics.map(formatDiagnostic).joined(separator: "\n")
            )
        }
        return try evaluateCalculatorTree(tree)
    }

    public func debugTree() -> String {
        calculatorDebugTree(tree)
    }

    public func debugTypedAST() -> String {
        calculatorDebugTypedAST(self)
    }
}

// MARK: - Owned-handle extensions (CambiumOwnedTraversal)

public extension CalculatorParseResult {
    /// Every expression-shape node in the tree, in depth-first preorder.
    ///
    /// Returns owned handles so callers can iterate, store, or pass node
    /// references outside Cambium's borrowed cursor closures. For
    /// hot-path analysis prefer borrowed traversal.
    var expressionHandles: [SyntaxNodeHandle<CalculatorLanguage>] {
        tree.rootAndDescendantHandlesPreorder.filter { handle in
            CalculatorLanguage.kind(for: handle.rawKind).isExpressionNode
        }
    }

    /// Every token in the tree, optionally filtered to a byte range.
    func tokenHandles(
        in range: TextRange? = nil
    ) -> [SyntaxTokenHandle<CalculatorLanguage>] {
        tree.rootHandle().tokenHandles(in: range)
    }
}

// MARK: - SyntaxText byte-streaming queries

public extension CalculatorParseResult {
    /// Whether the source text contains `needle` as a UTF-8 byte
    /// substring. Streams the document's bytes via `SyntaxText`; no
    /// `String` is materialized for the document.
    ///
    /// Per `SyntaxText`'s contract, an empty `needle` returns `true`.
    func sourceContains(_ needle: String) -> Bool {
        let bytes = Array(needle.utf8)
        return tree.withRoot { root in
            root.withText { text in
                text.contains(bytes)
            }
        }
    }

    /// First byte-range in the source text matching `needle`, or `nil`
    /// if not found. Uses `SyntaxText`'s KMP-style scan over chunks; only
    /// the needle's UTF-8 bytes are buffered.
    func sourceFirstRange(of needle: String) -> TextRange? {
        let bytes = Array(needle.utf8)
        return tree.withRoot { root in
            root.withText { text in
                text.firstRange(of: bytes)
            }
        }
    }

    /// Bytes covered by `range` materialized as a `String`, or `nil` if
    /// `range` is not contained in the source. Uses
    /// `SyntaxText.sliced(_:).makeString()` so only the slice's bytes
    /// are copied — the rest of the document is never touched.
    func sourceSlice(_ range: TextRange) -> String? {
        tree.withRoot { root -> String? in
            root.withText { text -> String? in
                let bounds = TextRange(
                    start: .zero,
                    length: TextSize(UInt32(text.utf8Count))
                )
                guard bounds.contains(range) else {
                    return nil
                }
                let slice = text.sliced(range)
                return slice.makeString()
            }
        }
    }

    /// FNV-1a hash of the source bytes, computed by streaming through a
    /// custom `UTF8Sink`. Demonstrates the protocol's intended use:
    /// transform bytes without materializing a `String` or buffering
    /// them. Two parses of identical source produce identical hashes;
    /// any byte-level change shifts the hash.
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
            preconditionFailure("FNV1aHasher write threw unexpectedly: \(error)")
        }
        return hasher.hash
    }
}

/// Reference `UTF8Sink` conformance: an FNV-1a-style 64-bit hash that
/// consumes the document's UTF-8 byte chunks one buffer at a time
/// without ever materializing a `String`. Same hash family Cambium uses
/// internally in `GreenHash`; inlined here as a demonstration of the
/// protocol's intended downstream use.
private struct FNV1aHasher: UTF8Sink {
    private(set) var hash: UInt64 = 0xcbf29ce484222325
    private let prime: UInt64 = 0x100000001b3

    mutating func write(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* prime
        }
    }
}
