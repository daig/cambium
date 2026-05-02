// CalculatorParseResult.swift

import Cambium

public extension CalculatorParseResult {
    // ... position queries and SyntaxText helpers from prior steps ...

    /// FNV-1a hash of the source bytes, computed by streaming chunks
    /// through a custom ``CambiumCore/UTF8Sink``. The sink sees the
    /// document one buffer at a time without ever holding it as a
    /// `String` — the right shape for hashing, checksums, or any
    /// reduction over bytes.
    ///
    /// Two parses of identical source produce identical hashes; any
    /// byte-level change shifts the hash.
    func sourceFNV1a() -> UInt64 {
        var hasher = FNV1aHasher()
        do {
            try tree.withRoot { root in
                try root.withText { text in
                    try text.writeUTF8(to: &hasher)
                }
            }
        } catch {
            // FNV1aHasher.write does not throw; this branch is
            // unreachable. Crash loudly if the contract changes.
            preconditionFailure("FNV1aHasher.write threw unexpectedly: \(error)")
        }
        return hasher.hash
    }
}

/// A reference `UTF8Sink` conformance: an FNV-1a 64-bit hash that
/// consumes the document's UTF-8 chunks without buffering. The same
/// hash family Cambium uses internally for its green-node identity.
private struct FNV1aHasher: UTF8Sink {
    private(set) var hash: UInt64 = 0xcbf29ce484222325
    private let prime: UInt64 = 0x100000001b3

    mutating func write(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* prime
        }
    }
}
