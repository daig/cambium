import Cambium
import Foundation

public func saveCalculatorTree(
    _ tree: SharedSyntaxTree<CalculatorLanguage>,
    to url: URL
) throws {
    let bytes = try tree.serializeGreenSnapshot()
    try Data(bytes).write(to: url)
}
