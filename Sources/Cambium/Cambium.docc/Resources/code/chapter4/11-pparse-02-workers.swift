import Cambium

public struct ParallelParseReport: Sendable {
    /// One parsed tree per input expression, in input order.
    public let trees: [SharedSyntaxTree<CalculatorLanguage>]

    public let interner: SharedTokenInterner

    public let internerKeySpaceUsed: Int
    public let totalDynamicTokens: Int
}

public func parseCalculatorExpressionsInParallel(
    _ expressions: [String],
    interner: SharedTokenInterner = SharedTokenInterner()
) async throws -> ParallelParseReport {
    let trees = try await withThrowingTaskGroup(
        of: (Int, SharedSyntaxTree<CalculatorLanguage>).self,
        returning: [SharedSyntaxTree<CalculatorLanguage>].self
    ) { group in
        for (index, source) in expressions.enumerated() {
            group.addTask {
                let context = GreenTreeContext<CalculatorLanguage>(
                    interner: interner,
                    policy: .documentLocal
                )
                let builder = GreenTreeBuilder<CalculatorLanguage>(
                    context: consume context
                )
                var parser = CalculatorParser(
                    input: source,
                    builder: consume builder,
                    previousTree: nil,
                    edits: [],
                    incremental: nil
                )
                try parser.parse()
                let result = try parser.finish()
                return (index, result.tree)
            }
        }

        var ordered = Array<SharedSyntaxTree<CalculatorLanguage>?>(
            repeating: nil, count: expressions.count
        )
        for try await (index, tree) in group {
            ordered[index] = tree
        }
        return ordered.compactMap { $0 }
    }

    return ParallelParseReport(
        trees: trees,
        interner: interner,
        internerKeySpaceUsed: countInternerKeyOccupancy(across: trees),
        totalDynamicTokens: trees.reduce(0) { $0 + countDynamicTokens(in: $1) }
    )
}

private func countDynamicTokens(
    in tree: SharedSyntaxTree<CalculatorLanguage>
) -> Int {
    var count = 0
    walkGreenTokens(in: tree.rootGreen) { token in
        switch token.textStorage {
        case .interned, .ownedLargeText:
            count += 1
        case .staticText, .missing:
            break
        }
    }
    return count
}

private func countInternerKeyOccupancy(
    across trees: [SharedSyntaxTree<CalculatorLanguage>]
) -> Int {
    var seen: Set<UInt32> = []
    for tree in trees {
        walkGreenTokens(in: tree.rootGreen) { token in
            if case .interned(let key) = token.textStorage {
                seen.insert(key.rawValue)
            }
        }
    }
    return seen.count
}

private func walkGreenTokens(
    in node: GreenNode<CalculatorLanguage>,
    visit: (GreenToken<CalculatorLanguage>) -> Void
) {
    for childIndex in 0..<node.childCount {
        switch node.child(at: childIndex) {
        case .node(let child):
            walkGreenTokens(in: child, visit: visit)
        case .token(let token):
            visit(token)
        }
    }
}
