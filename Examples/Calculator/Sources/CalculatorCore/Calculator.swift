import Cambium
import CambiumSyntaxMacros

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

    public var sourceText: String {
        tree.withRoot { root in
            root.makeString()
        }
    }

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

public struct CalculatorDiagnostic: Sendable, Hashable {
    public let range: TextRange
    public let message: String
    public let severity: DiagnosticSeverity

    public init(range: TextRange, message: String, severity: DiagnosticSeverity = .error) {
        self.range = range
        self.message = message
        self.severity = severity
    }

    init(_ diagnostic: Diagnostic<CalculatorLanguage>) {
        self.range = diagnostic.range
        self.message = diagnostic.message
        self.severity = diagnostic.severity
    }
}

public enum CalculatorValue: Sendable, Equatable, CustomStringConvertible {
    case integer(Int64)
    case real(Double)

    public var description: String {
        switch self {
        case .integer(let value):
            "\(value)"
        case .real(let value):
            "\(value)"
        }
    }
}

public enum CalculatorEvaluationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSyntax(String)
    case integerLiteralOutOfRange(String, TextRange)
    case realLiteralOutOfRange(String, TextRange)
    case divisionByZero(TextRange)
    case overflow(TextRange)
    case nonFiniteResult(TextRange)
    case roundedValueOutOfRange(Double, TextRange)
    case unsupportedSyntax(String, TextRange)

    public var description: String {
        switch self {
        case .invalidSyntax(let message):
            message
        case .integerLiteralOutOfRange(let text, let range):
            "integer literal '\(text)' is outside Int64 range at \(format(range))"
        case .realLiteralOutOfRange(let text, let range):
            "real literal '\(text)' is outside Double range at \(format(range))"
        case .divisionByZero(let range):
            "division by zero at \(format(range))"
        case .overflow(let range):
            "arithmetic overflow at \(format(range))"
        case .nonFiniteResult(let range):
            "non-finite real result at \(format(range))"
        case .roundedValueOutOfRange(let value, let range):
            "rounded value '\(value)' is outside Int64 range at \(format(range))"
        case .unsupportedSyntax(let kind, let range):
            "unsupported syntax \(kind) at \(format(range))"
        }
    }
}

public protocol CalculatorSyntaxNode: TypedSyntaxNode, Sendable, Hashable where Lang == CalculatorLanguage {
    static var kind: CalculatorKind { get }
    var syntax: SyntaxNodeHandle<CalculatorLanguage> { get }

    init(unchecked syntax: SyntaxNodeHandle<CalculatorLanguage>)
}

public extension CalculatorSyntaxNode {
    static var rawKind: RawSyntaxKind {
        CalculatorLanguage.rawKind(for: kind)
    }

    init?(_ syntax: SyntaxNodeHandle<CalculatorLanguage>) {
        guard syntax.rawKind == Self.rawKind else {
            return nil
        }
        self.init(unchecked: syntax)
    }

    var range: TextRange {
        syntax.textRange
    }
}

public struct CalculatorTokenSyntax: Sendable, Hashable {
    public let syntax: SyntaxTokenHandle<CalculatorLanguage>

    public init(_ syntax: SyntaxTokenHandle<CalculatorLanguage>) {
        self.syntax = syntax
    }

    public var kind: CalculatorKind {
        syntax.withCursor { token in
            token.kind
        }
    }

    public var range: TextRange {
        syntax.withCursor { token in
            token.textRange
        }
    }

    public var text: String {
        syntax.withCursor { token in
            token.makeString()
        }
    }
}

public struct CalculatorBinaryOperatorTokenSyntax: Sendable, Hashable {
    public let token: CalculatorTokenSyntax
    public let operatorKind: CalculatorBinaryOperator

    public init?(_ token: CalculatorTokenSyntax) {
        guard let operatorKind = CalculatorBinaryOperator(token.kind) else {
            return nil
        }
        self.token = token
        self.operatorKind = operatorKind
    }

    public var range: TextRange {
        token.range
    }
}

public enum CalculatorBinaryOperator: Sendable, Hashable, CustomStringConvertible {
    case add
    case subtract
    case multiply
    case divide

    public var description: String {
        switch self {
        case .add:
            "+"
        case .subtract:
            "-"
        case .multiply:
            "*"
        case .divide:
            "/"
        }
    }

    init?(_ kind: CalculatorKind) {
        switch kind {
        case .plus:
            self = .add
        case .minus:
            self = .subtract
        case .star:
            self = .multiply
        case .slash:
            self = .divide
        default:
            return nil
        }
    }
}

public enum ExprSyntax: Sendable, Hashable {
    case integer(IntegerExprSyntax)
    case real(RealExprSyntax)
    case unary(UnaryExprSyntax)
    case binary(BinaryExprSyntax)
    case group(GroupExprSyntax)
    case roundCall(RoundCallExprSyntax)

    public init?(_ syntax: SyntaxNodeHandle<CalculatorLanguage>) {
        switch CalculatorLanguage.kind(for: syntax.rawKind) {
        case .integerExpr:
            self = .integer(IntegerExprSyntax(unchecked: syntax))
        case .realExpr:
            self = .real(RealExprSyntax(unchecked: syntax))
        case .unaryExpr:
            self = .unary(UnaryExprSyntax(unchecked: syntax))
        case .binaryExpr:
            self = .binary(BinaryExprSyntax(unchecked: syntax))
        case .groupExpr:
            self = .group(GroupExprSyntax(unchecked: syntax))
        case .roundCallExpr:
            self = .roundCall(RoundCallExprSyntax(unchecked: syntax))
        default:
            return nil
        }
    }

    public var range: TextRange {
        switch self {
        case .integer(let expression):
            expression.range
        case .real(let expression):
            expression.range
        case .unary(let expression):
            expression.range
        case .binary(let expression):
            expression.range
        case .group(let expression):
            expression.range
        case .roundCall(let expression):
            expression.range
        }
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .root)
public struct RootSyntax: CalculatorSyntaxNode {
    public var expressions: [ExprSyntax] {
        expressionChildren()
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .integerExpr)
public struct IntegerExprSyntax: CalculatorSyntaxNode {
    public var literal: CalculatorTokenSyntax? {
        firstToken(kind: .number)
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .realExpr)
public struct RealExprSyntax: CalculatorSyntaxNode {
    public var literal: CalculatorTokenSyntax? {
        firstToken(kind: .realNumber)
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .unaryExpr)
public struct UnaryExprSyntax: CalculatorSyntaxNode {
    public var operand: ExprSyntax? {
        expression(at: 0)
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .binaryExpr)
public struct BinaryExprSyntax: CalculatorSyntaxNode {
    public var lhs: ExprSyntax? {
        expression(at: 0)
    }

    public var operatorToken: CalculatorBinaryOperatorTokenSyntax? {
        binaryOperatorToken()
    }

    public var rhs: ExprSyntax? {
        expression(at: 1)
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .groupExpr)
public struct GroupExprSyntax: CalculatorSyntaxNode {
    public var expression: ExprSyntax? {
        expression(at: 0)
    }
}

@CambiumSyntaxNode(CalculatorKind.self, for: .roundCallExpr)
public struct RoundCallExprSyntax: CalculatorSyntaxNode {
    public var argument: ExprSyntax? {
        expression(at: 0)
    }
}

private extension CalculatorSyntaxNode {
    func expressionChildren() -> [ExprSyntax] {
        syntax.withCursor { node in
            var expressions: [ExprSyntax] = []
            node.forEachChild { child in
                if let expression = ExprSyntax(child.makeHandle()) {
                    expressions.append(expression)
                }
            }
            return expressions
        }
    }

    func expression(at index: Int) -> ExprSyntax? {
        let expressions = expressionChildren()
        guard index >= 0, index < expressions.count else {
            return nil
        }
        return expressions[index]
    }

    func firstToken(kind: CalculatorKind) -> CalculatorTokenSyntax? {
        firstToken { $0 == kind }
    }

    func binaryOperatorToken() -> CalculatorBinaryOperatorTokenSyntax? {
        guard let token = firstToken(where: { CalculatorBinaryOperator($0) != nil }) else {
            return nil
        }
        return CalculatorBinaryOperatorTokenSyntax(token)
    }

    func firstInvalidChildRange() -> TextRange? {
        syntax.withCursor { node in
            var range: TextRange?
            node.forEachChild { child in
                if range == nil, child.kind == .missing || child.kind == .error {
                    range = child.textRange
                }
            }
            return range
        }
    }

    private func firstToken(where matches: (CalculatorKind) -> Bool) -> CalculatorTokenSyntax? {
        syntax.withCursor { node in
            var result: CalculatorTokenSyntax?
            node.forEachChildOrToken { element in
                switch element {
                case .token(let token) where result == nil && matches(token.kind):
                    result = CalculatorTokenSyntax(token.makeHandle())
                default:
                    break
                }
            }
            return result
        }
    }
}

public func parseCalculator(_ input: String) throws -> CalculatorParseResult {
    var parser = CalculatorParser(input: input)
    try parser.parse()
    return try parser.finish()
}

/// Long-lived parsing context that carries a `GreenNodeCache` and an
/// `IncrementalParseSession` across reparses, so successive parses can
/// share green-node storage and splice unchanged subtrees from the
/// previous tree into the new one.
///
/// Use a single session per logical document. For one-shot parses
/// (REPL-style "evaluate this expression"), `parseCalculator(_:)` is
/// the right entry point.
public final class CalculatorSession {
    private var cache: GreenNodeCache<CalculatorLanguage>?
    private var lastTree: SharedSyntaxTree<CalculatorLanguage>?
    private var lastDiagnostics: [CalculatorDiagnostic] = []
    private let incremental = IncrementalParseSession<CalculatorLanguage>()

    public init() {}

    /// Parse `input`, optionally as the result of applying `edits` to the
    /// previous parse's source. The cache and previous tree are forwarded
    /// automatically; callers do not need to thread them.
    ///
    /// `edits` are interpreted in old-tree coordinates per
    /// `CambiumIncremental`'s contract: non-overlapping, sorted by start.
    /// Pass `[]` for a fresh document.
    public func parse(
        _ input: String,
        edits: [TextEdit] = []
    ) throws -> CalculatorParseResult {
        let builder: GreenTreeBuilder<CalculatorLanguage>
        if let existing = cache.take() {
            builder = GreenTreeBuilder(cache: existing)
        } else {
            builder = GreenTreeBuilder(policy: .parseSession(maxEntries: 16_384))
        }

        var parser = CalculatorParser(
            input: input,
            builder: consume builder,
            previousTree: lastTree,
            edits: edits,
            incremental: incremental
        )
        try parser.parse()
        let output = try parser.finishBuild()

        // Read the snapshot before consuming the build for its cache. Order
        // matters: `intoCache()` is `consuming`, after which `output.build`
        // is gone.
        let tree = output.build.snapshot.makeSyntaxTree().intoShared()
        let diagnostics = output.diagnostics
        let nextCache = output.build.intoCache()
        let calculatorDiagnostics = diagnostics.map(CalculatorDiagnostic.init(_:))

        cache = consume nextCache
        lastTree = tree
        lastDiagnostics = calculatorDiagnostics
        return CalculatorParseResult(
            tree: tree,
            diagnostics: calculatorDiagnostics
        )
    }

    /// Adopt an externally-produced tree, such as a decoded serialized
    /// snapshot, as this session's current tree.
    ///
    /// The adopted tree's resolver carries its own token-key namespace, so
    /// any existing cache cannot safely be shared with subsequent parses. The
    /// next `parse(_:edits:)` call will mint a fresh cache; any subtree reuse
    /// from the adopted tree will remap dynamic token keys into that cache.
    public func adopt(_ tree: SharedSyntaxTree<CalculatorLanguage>) {
        cache = nil
        lastTree = tree
        lastDiagnostics = []
    }

    /// Constant-fold the current document one subtree replacement at a time.
    ///
    /// Each step replaces exactly one foldable expression with an integer or
    /// real literal and records the `ReplacementWitness` returned by Cambium's
    /// central tree-editing API.
    public func fold() throws -> FoldReport {
        guard var currentTree = lastTree else {
            throw CalculatorEvaluationError.invalidSyntax("no current document")
        }
        guard lastDiagnostics.isEmpty else {
            throw CalculatorEvaluationError.invalidSyntax(
                lastDiagnostics.map(formatDiagnostic).joined(separator: "\n")
            )
        }

        var foldCache: GreenNodeCache<CalculatorLanguage>
        if let existing = cache.take() {
            foldCache = existing
        } else {
            foldCache = GreenNodeCache(policy: .parseSession(maxEntries: 16_384))
        }

        var steps: [FoldStep] = []
        while let candidate = firstFoldCandidate(in: currentTree) {
            let output = try applyFold(
                candidate,
                in: currentTree,
                cache: consume foldCache
            )
            let step = output.step
            foldCache = output.intoCache()
            currentTree = step.newTree
            steps.append(step)
        }

        let finalSource = currentTree.withRoot { root in
            root.makeString()
        }
        cache = consume foldCache
        lastTree = currentTree
        lastDiagnostics = []
        return FoldReport(
            steps: steps,
            finalTree: currentTree,
            finalSource: finalSource
        )
    }

    /// Aggregate reuse-oracle counters since the session was created (or last
    /// `reset()`). See `IncrementalParseCounters` for semantics.
    public var counters: IncrementalParseCounters {
        incremental.counters
    }

    /// Drop the carried cache and previous tree. The next `parse(_:)` call
    /// behaves like a fresh session. Note: `IncrementalParseSession` itself
    /// carries counters as well; calling `reset()` does NOT zero counters
    /// because Cambium does not expose a counter reset on the session type.
    /// Callers who want a clean slate should construct a new
    /// `CalculatorSession`.
    public func reset() {
        cache = nil
        lastTree = nil
        lastDiagnostics = []
    }
}

private struct FoldCandidate {
    var handle: SyntaxNodeHandle<CalculatorLanguage>
    var path: SyntaxNodePath
    var oldKind: CalculatorKind
    var oldText: String
    var leadingTrivia: [FoldTrivia]
    var trailingTrivia: [FoldTrivia]
    var literal: FoldLiteral
}

private struct FoldTrivia {
    var kind: CalculatorKind
    var text: String
}

private struct FoldLiteral {
    var expressionKind: CalculatorKind
    var tokenKind: CalculatorKind
    var text: String

    init?(_ value: CalculatorValue) {
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

private struct FoldApplyOutput: ~Copyable {
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

private func firstFoldCandidate(
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

private func applyFold(
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

private extension GreenTreeBuilder where Lang == CalculatorLanguage {
    mutating func appendTrivia(_ trivia: FoldTrivia) throws {
        if CalculatorLanguage.staticText(for: trivia.kind) != nil {
            try staticToken(trivia.kind)
        } else {
            try token(trivia.kind, text: trivia.text)
        }
    }
}

private extension SyntaxNodeCursor where Lang == CalculatorLanguage {
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
    return try? evaluate(expression)
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

private func foldDisplayName(for kind: CalculatorKind) -> String {
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

public func evaluateCalculatorTree(_ tree: SharedSyntaxTree<CalculatorLanguage>) throws -> CalculatorValue {
    try tree.withRoot { root in
        guard let root = RootSyntax(root.makeHandle()) else {
            throw CalculatorEvaluationError.unsupportedSyntax(CalculatorLanguage.name(for: root.kind), root.textRange)
        }
        return try evaluateRoot(root)
    }
}

public func calculatorDebugTree(_ tree: SharedSyntaxTree<CalculatorLanguage>) -> String {
    tree.withRoot { root in
        var lines: [String] = []

        func visit(_ node: borrowing SyntaxNodeCursor<CalculatorLanguage>, depth: Int) {
            lines.append("\(indent(depth))\(CalculatorLanguage.name(for: node.kind)) \(format(node.textRange))")
            node.forEachChildOrToken { element in
                switch element {
                case .node(let child):
                    visit(child, depth: depth + 1)
                case .token(let token):
                    lines.append(
                        "\(indent(depth + 1))\(CalculatorLanguage.name(for: token.kind)) \(format(token.textRange)) \"\(escaped(token.makeString()))\""
                    )
                }
            }
        }

        visit(root, depth: 0)
        return lines.joined(separator: "\n")
    }
}

public func calculatorDebugTypedAST(_ result: CalculatorParseResult) -> String {
    guard result.diagnostics.isEmpty else {
        return result.diagnostics.map(formatDiagnostic).joined(separator: "\n")
    }
    return calculatorDebugTypedAST(result.tree)
}

public func calculatorDebugTypedAST(_ tree: SharedSyntaxTree<CalculatorLanguage>) -> String {
    tree.withRoot { root in
        guard let root = RootSyntax(root.makeHandle()) else {
            return "unsupported syntax \(CalculatorLanguage.name(for: root.kind)) at \(format(root.textRange))"
        }

        var lines: [String] = []
        lines.append("RootSyntax \(format(root.range))")

        for expression in root.expressions {
            appendTypedOverlayDebug(expression, depth: 1, lines: &lines)
        }
        return lines.joined(separator: "\n")
    }
}

private func appendTypedOverlayDebug(_ expression: ExprSyntax, depth: Int, lines: inout [String]) {
    lines.append("\(indent(depth))\(expression.debugLabel) \(format(expression.range))")
    for child in expression.children {
        appendTypedOverlayDebug(child, depth: depth + 1, lines: &lines)
    }
}

private extension ExprSyntax {
    var debugLabel: String {
        switch self {
        case .integer:
            "IntegerExprSyntax"
        case .real:
            "RealExprSyntax"
        case .unary:
            "UnaryExprSyntax"
        case .binary:
            "BinaryExprSyntax"
        case .group:
            "GroupExprSyntax"
        case .roundCall:
            "RoundCallExprSyntax"
        }
    }

    var children: [ExprSyntax] {
        switch self {
        case .integer, .real:
            []
        case .unary(let expression):
            expression.operand.map { [$0] } ?? []
        case .binary(let expression):
            [expression.lhs, expression.rhs].compactMap { $0 }
        case .group(let expression):
            expression.expression.map { [$0] } ?? []
        case .roundCall(let expression):
            expression.argument.map { [$0] } ?? []
        }
    }
}

private func evaluateRoot(_ root: RootSyntax) throws -> CalculatorValue {
    if let invalidRange = root.firstInvalidChildRange() {
        throw CalculatorEvaluationError.invalidSyntax("parse error node at \(format(invalidRange))")
    }

    let expressions = root.expressions
    guard expressions.count == 1 else {
        let message = expressions.isEmpty ? "expected expression" : "multiple root expressions"
        throw CalculatorEvaluationError.invalidSyntax("\(message) at \(format(root.range))")
    }
    return try evaluate(expressions[0])
}

private func evaluate(_ expression: ExprSyntax) throws -> CalculatorValue {
    switch expression {
    case .integer(let expression):
        return try evaluateInteger(expression)
    case .real(let expression):
        return try evaluateReal(expression)
    case .unary(let expression):
        return try evaluateUnary(expression)
    case .binary(let expression):
        return try evaluateBinary(expression)
    case .group(let expression):
        return try evaluateGroup(expression)
    case .roundCall(let expression):
        return try evaluateRoundCall(expression)
    }
}

private func evaluateInteger(_ expression: IntegerExprSyntax) throws -> CalculatorValue {
    guard let token = expression.literal else {
        throw CalculatorEvaluationError.unsupportedSyntax("missing integer literal", expression.range)
    }
    guard let value = Int64(token.text) else {
        throw CalculatorEvaluationError.integerLiteralOutOfRange(token.text, token.range)
    }
    return .integer(value)
}

private func evaluateReal(_ expression: RealExprSyntax) throws -> CalculatorValue {
    guard let token = expression.literal else {
        throw CalculatorEvaluationError.unsupportedSyntax("missing real literal", expression.range)
    }
    guard let value = Double(token.text), value.isFinite else {
        throw CalculatorEvaluationError.realLiteralOutOfRange(token.text, token.range)
    }
    return .real(value)
}

private func evaluateUnary(_ expression: UnaryExprSyntax) throws -> CalculatorValue {
    guard let operand = expression.operand else {
        throw CalculatorEvaluationError.unsupportedSyntax("unary expression is missing an operand", expression.range)
    }

    switch try evaluate(operand) {
    case .integer(let value):
        let result = Int64(0).subtractingReportingOverflow(value)
        guard !result.overflow else {
            throw CalculatorEvaluationError.overflow(expression.range)
        }
        return .integer(result.partialValue)
    case .real(let value):
        let result = -value
        guard result.isFinite else {
            throw CalculatorEvaluationError.nonFiniteResult(expression.range)
        }
        return .real(result)
    }
}

private func evaluateBinary(_ expression: BinaryExprSyntax) throws -> CalculatorValue {
    guard let lhs = expression.lhs else {
        throw CalculatorEvaluationError.unsupportedSyntax("binary expression is missing a left operand", expression.range)
    }
    guard let operatorToken = expression.operatorToken else {
        throw CalculatorEvaluationError.unsupportedSyntax("binary expression is missing an operator", expression.range)
    }
    guard let rhs = expression.rhs else {
        throw CalculatorEvaluationError.unsupportedSyntax("binary expression is missing a right operand", expression.range)
    }

    let leftValue = try evaluate(lhs)
    let rightValue = try evaluate(rhs)

    switch (leftValue, rightValue) {
    case (.integer(let left), .integer(let right)):
        return try evaluateIntegerBinary(
            left,
            right,
            operatorKind: operatorToken.operatorKind,
            operatorRange: operatorToken.range
        )
    default:
        return try evaluateRealBinary(
            leftValue.realValue,
            rightValue.realValue,
            operatorKind: operatorToken.operatorKind,
            operatorRange: operatorToken.range
        )
    }
}

private func evaluateGroup(_ expression: GroupExprSyntax) throws -> CalculatorValue {
    guard let nestedExpression = expression.expression else {
        throw CalculatorEvaluationError.unsupportedSyntax("group expression is missing an expression", expression.range)
    }
    return try evaluate(nestedExpression)
}

private func evaluateRoundCall(_ expression: RoundCallExprSyntax) throws -> CalculatorValue {
    guard let argument = expression.argument else {
        throw CalculatorEvaluationError.unsupportedSyntax("round call is missing an argument", expression.range)
    }

    switch try evaluate(argument) {
    case .integer(let value):
        return .integer(value)
    case .real(let value):
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        guard rounded.isFinite, let integer = Int64(exactly: rounded) else {
            throw CalculatorEvaluationError.roundedValueOutOfRange(rounded, expression.range)
        }
        return .integer(integer)
    }
}

private func evaluateIntegerBinary(
    _ lhs: Int64,
    _ rhs: Int64,
    operatorKind: CalculatorBinaryOperator,
    operatorRange: TextRange
) throws -> CalculatorValue {
    let result: (partialValue: Int64, overflow: Bool)
    switch operatorKind {
    case .add:
        result = lhs.addingReportingOverflow(rhs)
    case .subtract:
        result = lhs.subtractingReportingOverflow(rhs)
    case .multiply:
        result = lhs.multipliedReportingOverflow(by: rhs)
    case .divide:
        guard rhs != 0 else {
            throw CalculatorEvaluationError.divisionByZero(operatorRange)
        }
        result = lhs.dividedReportingOverflow(by: rhs)
    }

    guard !result.overflow else {
        throw CalculatorEvaluationError.overflow(operatorRange)
    }
    return .integer(result.partialValue)
}

private func evaluateRealBinary(
    _ lhs: Double,
    _ rhs: Double,
    operatorKind: CalculatorBinaryOperator,
    operatorRange: TextRange
) throws -> CalculatorValue {
    let result: Double
    switch operatorKind {
    case .add:
        result = lhs + rhs
    case .subtract:
        result = lhs - rhs
    case .multiply:
        result = lhs * rhs
    case .divide:
        guard rhs != 0 else {
            throw CalculatorEvaluationError.divisionByZero(operatorRange)
        }
        result = lhs / rhs
    }

    guard result.isFinite else {
        throw CalculatorEvaluationError.nonFiniteResult(operatorRange)
    }
    return .real(result)
}

public func formatDiagnostic(_ diagnostic: CalculatorDiagnostic) -> String {
    "\(diagnostic.severity): \(diagnostic.message) at \(format(diagnostic.range))"
}

public func format(_ range: TextRange) -> String {
    "\(range.start.rawValue)..<\(range.end.rawValue)"
}

private extension CalculatorValue {
    var realValue: Double {
        switch self {
        case .integer(let value):
            Double(value)
        case .real(let value):
            value
        }
    }
}

private func indent(_ depth: Int) -> String {
    String(repeating: "  ", count: depth)
}

private func escaped(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\n":
            result += "\\n"
        case "\r":
            result += "\\r"
        case "\t":
            result += "\\t"
        case "\"":
            result += "\\\""
        case "\\":
            result += "\\\\"
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}
