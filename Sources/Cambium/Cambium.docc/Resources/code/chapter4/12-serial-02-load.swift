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
    let bytes = try tree.serializeGreenSnapshot()
    try Data(bytes).write(to: url)
}

/// Decode a previously-serialized snapshot from `url` and project
/// it into a `SharedSyntaxTree`. The decoder validates the entire
/// payload (length headers, per-record kinds, structural hash) and
/// throws ``CambiumSerialization/CambiumSerializationError`` on any
/// mismatch.
public func loadCalculatorTree(
    from url: URL
) throws -> SharedSyntaxTree<CalculatorLanguage> {
    let data = try Data(contentsOf: url)
    let bytes = Array(data)
    return try GreenSnapshotDecoder
        .decodeTree(bytes, as: CalculatorLanguage.self)
        .intoShared()
}

// Inside a `CalculatorSession`, an `adopt(_:)` method makes a freshly
// loaded tree the session's current tree:
//
//     public func adopt(_ tree: SharedSyntaxTree<CalculatorLanguage>) {
//         context = nil           // namespace mismatch — drop forwarded context
//         lastTree = tree
//         lastDiagnostics = []
//         evaluationCache.removeAll()
//         evaluationMetadata = SyntaxMetadataStore<CalculatorLanguage>()
//     }
//
// The adopted tree's resolver carries its own token-key namespace,
// disjoint from any prior session context. Dropping the cached
// context forces the next parse to mint a fresh context bound to
// the new namespace; the analysis cache is cleared because all of
// its entries are keyed by old `SyntaxNodeIdentity`s that don't
// resolve in the loaded tree.
