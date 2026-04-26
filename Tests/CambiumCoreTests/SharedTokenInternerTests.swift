@testable import CambiumBuilder
import CambiumCore
import Testing

@Test func sharedTokenInternerShardIndexHandlesIntMinHash() {
    let index = SharedTokenInternerKeyLayout.shardIndex(
        forHash: Int.min,
        shardCount: 8
    )

    #expect((0..<8).contains(index))
}

@Test func sharedTokenInternerShardIndexHandlesPositiveAndNegativeHashes() {
    for hash in [-123_456, -1, 0, 1, 123_456] {
        let index = SharedTokenInternerKeyLayout.shardIndex(
            forHash: hash,
            shardCount: 8
        )

        #expect((0..<8).contains(index))
    }
}

@Test func sharedTokenInternerKeyLayoutRoundTripsMaximumRepresentableKey() {
    let key = SharedTokenInternerKeyLayout.makeKey(
        shardIndex: 255,
        localIndex: 0x00ff_ffff
    )

    guard let key else {
        Issue.record("Expected maximum representable shared token key to be valid")
        return
    }

    let decoded = SharedTokenInternerKeyLayout.decode(key)
    #expect(decoded.shardIndex == 255)
    #expect(decoded.localIndex == 0x00ff_ffff)
}

@Test func sharedTokenInternerKeyLayoutRejectsUnrepresentableComponents() {
    #expect(SharedTokenInternerKeyLayout.makeKey(
        shardIndex: 256,
        localIndex: 0
    ) == nil)
    #expect(SharedTokenInternerKeyLayout.makeKey(
        shardIndex: 0,
        localIndex: 0x0100_0000
    ) == nil)
}

@Test func sharedTokenInternerInternsResolvesAndStreamsUTF8() {
    let interner = SharedTokenInterner()

    let first = interner.intern("hello")
    let duplicate = interner.intern("hello")
    let second = interner.intern("world")

    #expect(first == duplicate)
    #expect(first != second)
    #expect(interner.resolve(first) == "hello")
    #expect(interner.resolve(second) == "world")

    let bytes = interner.withUTF8(first) { Array($0) }
    #expect(bytes == Array("hello".utf8))
}
