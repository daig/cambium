import Cambium

public struct ParallelParseReport: Sendable {
    /// One parsed tree per input expression, in input order.
    public let trees: [SharedSyntaxTree<CalculatorLanguage>]

    public let interner: SharedTokenInterner

    public let internerKeySpaceUsed: Int
    public let totalDynamicTokens: Int
}
