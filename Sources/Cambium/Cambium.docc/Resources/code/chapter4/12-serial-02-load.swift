import Cambium
import Foundation

public func saveCalculatorTree(
    _ tree: SharedSyntaxTree<CalculatorLanguage>,
    to url: URL
) throws {
    let bytes = try tree.serializeGreenSnapshot()
    try Data(bytes).write(to: url)
}

public func loadCalculatorTree(
    from url: URL
) throws -> SharedSyntaxTree<CalculatorLanguage> {
    let data = try Data(contentsOf: url)
    let bytes = Array(data)
    return try GreenSnapshotDecoder
        .decodeTree(bytes, as: CalculatorLanguage.self)
        .intoShared()
}
