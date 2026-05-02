// SaveAndLoad.swift

import Cambium
import Foundation

/// Serialize `tree` and write the bytes to `url`. The output format
/// is length-, hash-, and kind-validated — bad snapshots are
/// rejected at decode time with named errors.
public func saveCalculatorTree(
    _ tree: SharedSyntaxTree<CalculatorLanguage>,
    to url: URL
) throws {
    // `serializeGreenSnapshot()` returns a `[UInt8]` with the
    // canonical encoding for this tree. The serialization is keyed
    // by the language's `serializationID` and `serializationVersion`
    // — values you set on `CalculatorLanguage` in Tutorial 1.
    let bytes = try tree.serializeGreenSnapshot()
    try Data(bytes).write(to: url)
}
