// CalculatorFold.swift
//
// Constant folding by repeated subtree replacement. Each fold step:
//
// 1. Walks the current tree in **post-order** (`walkPreorder` consuming
//    `.leave` events) so children are evaluated before their parents,
//    matching how Cambium's typed AST overlays compose.
// 2. Picks the first foldable expression — one whose direct operands are
//    all literals — and evaluates it via `CalculatorEvaluator`.
// 3. Builds a replacement subtree containing the same edge trivia and
//    the new literal token, using a fresh `GreenTreeBuilder`.
// 4. Splices the replacement in via `SharedSyntaxTree.replacing(_:with:cache:)`,
//    recording the `ReplacementWitness` returned for downstream identity
//    translation.
//
// The witness is the central artifact here. It lets the surrounding
// session translate per-node analysis cache entries from the old tree
// to the new one without re-evaluating untouched subtrees — see
// `CalculatorSession.translateEvaluationCache(...)` for the consumer.
//
// Cambium APIs showcased here:
// - `SharedSyntaxTree.replacing(_:with:cache:)` (the central tree-edit API)
// - `ReplacementWitness` / `ReplacementResult.intoTree()` (witness payload)
// - `ResolvedGreenNode` (pairing a green subtree with its resolver)
// - `walkPreorder { .enter / .leave }` for post-order detection
// - `GreenTreeBuilder` reuse across builds via `intoCache()`

import Cambium

// MARK: - Public report types

/// The full record of a `CalculatorSession.fold()` invocation: every
/// replacement step in order, plus the final tree and its source.
public struct FoldReport: Sendable {
    public let steps: [FoldStep]
    public let finalTree: SharedSyntaxTree<CalculatorLanguage>
    public let finalSource: String

    public init(
        steps: [FoldStep],
        finalTree: SharedSyntaxTree<CalculatorLanguage>,
        finalSource: String
    ) {
        self.steps = steps
        self.finalTree = finalTree
        self.finalSource = finalSource
    }
}

/// One subtree replacement applied during folding. Carries the witness
/// returned by `replacing(_:with:cache:)` so consumers can translate
/// references through the change.
public struct FoldStep: Sendable {
    public let oldKind: CalculatorKind
    public let newKind: CalculatorKind
    public let oldText: String
    public let newText: String
    public let replacedPath: SyntaxNodePath
    public let witness: ReplacementWitness<CalculatorLanguage>
    public let newTree: SharedSyntaxTree<CalculatorLanguage>

    public init(
        oldKind: CalculatorKind,
        newKind: CalculatorKind,
        oldText: String,
        newText: String,
        replacedPath: SyntaxNodePath,
        witness: ReplacementWitness<CalculatorLanguage>,
        newTree: SharedSyntaxTree<CalculatorLanguage>
    ) {
        self.oldKind = oldKind
        self.newKind = newKind
        self.oldText = oldText
        self.newText = newText
        self.replacedPath = replacedPath
        self.witness = witness
        self.newTree = newTree
    }

    public var oldKindDisplayName: String {
        foldDisplayName(for: oldKind)
    }

    public var newKindDisplayName: String {
        foldDisplayName(for: newKind)
    }
}

// MARK: - Engine

/// One foldable expression discovered in a tree. The fold loop reads
/// these one at a time; each successful fold rebuilds the tree, so
/// candidate paths are only meaningful within their producing tree.
internal struct FoldCandidate {
    var handle: SyntaxNodeHandle<CalculatorLanguage>
    var path: SyntaxNodePath
    var oldKind: CalculatorKind
    var oldText: String
    var leadingTrivia: [FoldTrivia]
    var trailingTrivia: [FoldTrivia]
    var literal: FoldLiteral
}

internal struct FoldTrivia {
    var kind: CalculatorKind
    var text: String
}

/// The replacement literal we'd splice in for a given evaluated value.
/// Returns `nil` for values whose canonical text is not a plain decimal
/// literal (NaN, infinity, scientific notation), so the fold is skipped
/// rather than producing an invalid replacement subtree.
internal struct FoldLiteral {
    var value: CalculatorValue
    var expressionKind: CalculatorKind
    var tokenKind: CalculatorKind
    var text: String

    init?(_ value: CalculatorValue) {
        self.value = value
        switch value {
        case .integer(let value):
            expressionKind = .integerExpr
            tokenKind = .number
            text = String(value)
        case .real(let value):
            guard value.isFinite else {
                return nil
            }
            let text = String(value)
            guard Self.isPlainDecimal(text) else {
                return nil
            }
            expressionKind = .realExpr
            tokenKind = .realNumber
            self.text = text
        }
    }

    private static func isPlainDecimal(_ text: String) -> Bool {
        var scalars = Array(text.unicodeScalars)
        if scalars.first?.value == 0x2d {
            scalars.removeFirst()
        }
        guard let dotIndex = scalars.firstIndex(where: { $0.value == 0x2e }),
              dotIndex > scalars.startIndex,
              dotIndex < scalars.index(before: scalars.endIndex)
        else {
            return false
        }
        for scalar in scalars[..<dotIndex] {
            guard scalar.value >= 0x30, scalar.value <= 0x39 else {
                return false
            }
        }
        for scalar in scalars[scalars.index(after: dotIndex)...] {
            guard scalar.value >= 0x30, scalar.value <= 0x39 else {
                return false
            }
        }
        return true
    }
}

/// Bundles a `FoldStep` with the `~Copyable` cache the next iteration
/// will consume. Swift tuples can't yet hold `~Copyable` elements, so
/// this struct serves the same role.
internal struct FoldApplyOutput: ~Copyable {
    var step: FoldStep
    private var cache: GreenNodeCache<CalculatorLanguage>

    init(
        step: FoldStep,
        cache: consuming GreenNodeCache<CalculatorLanguage>
    ) {
        self.step = step
        self.cache = cache
    }

    consuming func intoCache() -> GreenNodeCache<CalculatorLanguage> {
        cache
    }
}

/// First foldable expression in `tree`, discovered by post-order walk
/// (so children fold before parents and a single pass picks the
/// innermost-evaluable position).
internal func firstFoldCandidate(
    in tree: SharedSyntaxTree<CalculatorLanguage>
) -> FoldCandidate? {
    tree.withRoot { root in
        var candidate: FoldCandidate?
        _ = root.walkPreorder { event in
            switch event {
            case .enter:
                return .continue
            case .leave(let node):
                guard candidate == nil,
                      let expression = ExprSyntax(node.makeHandle()),
                      let value = foldValue(for: expression),
                      let literal = FoldLiteral(value)
                else {
                    return .continue
                }

                candidate = FoldCandidate(
                    handle: node.makeHandle(),
                    path: node.childIndexPath(),
                    oldKind: node.kind,
                    oldText: node.makeString(),
                    leadingTrivia: node.edgeTrivia.leading,
                    trailingTrivia: node.edgeTrivia.trailing,
                    literal: literal
                )
                return .stop
            }
        }
        return candidate
    }
}

/// Build the replacement subtree, splice it in via `replacing(_:with:cache:)`,
/// and return the resulting step and forwarded cache.
internal func applyFold(
    _ candidate: FoldCandidate,
    in tree: SharedSyntaxTree<CalculatorLanguage>,
    cache: consuming GreenNodeCache<CalculatorLanguage>
) throws -> FoldApplyOutput {
    var builder = GreenTreeBuilder<CalculatorLanguage>(cache: consume cache)
    builder.startNode(candidate.literal.expressionKind)
    for trivia in candidate.leadingTrivia {
        try builder.appendTrivia(trivia)
    }
    try builder.token(candidate.literal.tokenKind, text: candidate.literal.text)
    for trivia in candidate.trailingTrivia {
        try builder.appendTrivia(trivia)
    }
    try builder.finishNode()

    let build = try builder.finish()
    let replacement = ResolvedGreenNode(
        root: build.root,
        resolver: build.tokenText
    )
    var replacementCache = build.intoCache()
    let result = try tree.replacing(
        candidate.handle,
        with: replacement,
        cache: &replacementCache
    )
    let witness = result.witness
    let newTree = result.intoTree().intoShared()
    let step = FoldStep(
        oldKind: candidate.oldKind,
        newKind: candidate.literal.expressionKind,
        oldText: candidate.oldText,
        newText: candidate.literal.text,
        replacedPath: candidate.path,
        witness: witness,
        newTree: newTree
    )
    return FoldApplyOutput(step: step, cache: consume replacementCache)
}

// MARK: - Fold predicates

/// Whether `expression` is foldable: every direct operand must already
/// be a literal. (Recursive folding is handled by repeated passes — one
/// fold per `applyFold` call until the predicate returns `nil` for
/// every node in the tree.)
private func foldValue(for expression: ExprSyntax) -> CalculatorValue? {
    switch expression {
    case .integer, .real:
        return nil
    case .unary(let expression):
        guard expression.operand?.isLiteral == true else {
            return nil
        }
    case .binary(let expression):
        guard expression.lhs?.isLiteral == true,
              expression.operatorToken != nil,
              expression.rhs?.isLiteral == true
        else {
            return nil
        }
    case .group(let expression):
        guard expression.expression?.isLiteral == true else {
            return nil
        }
    case .roundCall(let expression):
        guard expression.argument?.isLiteral == true else {
            return nil
        }
    }
    var evaluator = CalculatorEvaluator()
    return try? evaluator.evaluate(expression)
}

private extension ExprSyntax {
    var isLiteral: Bool {
        switch self {
        case .integer, .real:
            true
        case .unary, .binary, .group, .roundCall:
            false
        }
    }
}

// MARK: - Builder/cursor extensions used by the fold engine

private extension GreenTreeBuilder where Lang == CalculatorLanguage {
    /// Append a trivia token (whitespace, etc.) preserving its
    /// static-vs-dynamic storage class.
    mutating func appendTrivia(_ trivia: FoldTrivia) throws {
        if CalculatorLanguage.staticText(for: trivia.kind) != nil {
            try staticToken(trivia.kind)
        } else {
            try token(trivia.kind, text: trivia.text)
        }
    }
}

private extension SyntaxNodeCursor where Lang == CalculatorLanguage {
    /// The trivia tokens that flank the node's significant content. We
    /// reproduce these around the replacement literal so the source text
    /// stays close to the original (a folded `1 + 2` keeps the surrounding
    /// whitespace of the binaryExpr).
    var edgeTrivia: (leading: [FoldTrivia], trailing: [FoldTrivia]) {
        var leading: [FoldTrivia] = []
        var trailing: [FoldTrivia] = []
        var sawNonTrivia = false

        forEachDescendantOrToken { element in
            switch element {
            case .token(let token) where CalculatorLanguage.isTrivia(token.kind):
                let trivia = FoldTrivia(kind: token.kind, text: token.makeString())
                if sawNonTrivia {
                    trailing.append(trivia)
                } else {
                    leading.append(trivia)
                }
            case .token:
                sawNonTrivia = true
                trailing.removeAll(keepingCapacity: true)
            default:
                break
            }
        }

        return (leading, trailing)
    }
}

// MARK: - Display helpers

internal func foldDisplayName(for kind: CalculatorKind) -> String {
    switch kind {
    case .integerExpr:
        "IntegerExpr"
    case .realExpr:
        "RealExpr"
    case .unaryExpr:
        "UnaryExpr"
    case .binaryExpr:
        "BinaryExpr"
    case .groupExpr:
        "GroupExpr"
    case .roundCallExpr:
        "RoundCallExpr"
    default:
        CalculatorLanguage.name(for: kind)
    }
}
