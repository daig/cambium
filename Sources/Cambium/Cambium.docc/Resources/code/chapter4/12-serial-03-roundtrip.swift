import Cambium
import Foundation

func demoRoundtrip() async throws {
    let original = try parseCalculator("1 + (2 * round(3.5))").tree
    let url = URL(fileURLWithPath: "/tmp/calc-tree.snap")

    try saveCalculatorTree(original, to: url)
    let restored = try loadCalculatorTree(from: url)

    let originalText = original.withRoot { $0.makeString() }
    let restoredText = restored.withRoot { $0.makeString() }
    assert(originalText == restoredText)

    do {
        var bytes = try original.serializeGreenSnapshot()
        bytes[bytes.count / 2] ^= 0xFF
        _ = try GreenSnapshotDecoder.decodeTree(
            bytes, as: CalculatorLanguage.self
        )
    } catch let error as CambiumSerializationError {
        print("decoded with error: \(error)")
    }
}
