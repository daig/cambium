// RoundtripDemo.swift

import Cambium
import Foundation

func demoRoundtrip() async throws {
    let original = try parseCalculator("1 + (2 * round(3.5))").tree
    let url = URL(fileURLWithPath: "/tmp/calc-tree.snap")

    try saveCalculatorTree(original, to: url)
    let restored = try loadCalculatorTree(from: url)

    // Round-trip preserves source bytes exactly. Two trees built
    // from the same input through different paths are
    // observationally equivalent for traversal and evaluation.
    let originalText = original.withRoot { $0.makeString() }
    let restoredText = restored.withRoot { $0.makeString() }
    assert(originalText == restoredText)

    // Catch encoding mismatches loudly. Any flipped byte in the
    // snapshot produces a structured error rather than a
    // silently-malformed tree.
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
