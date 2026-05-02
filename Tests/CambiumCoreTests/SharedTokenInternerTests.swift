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

@Test func largeTokenWorksWithSharedTokenInterner() {
    let interner = SharedTokenInterner()

    let alpha = "alpha-payload-α"
    let beta = "beta-payload-β"
    let alphaID = interner.storeLargeText(alpha)
    let betaID = interner.storeLargeText(beta)

    #expect(alphaID.rawValue == 0)
    #expect(betaID.rawValue == 1)

    // Equal payloads do NOT deduplicate (large-text contract).
    let alphaAgainID = interner.storeLargeText(alpha)
    #expect(alphaAgainID.rawValue == 2)

    #expect(interner.resolveLargeText(alphaID) == alpha)
    #expect(interner.resolveLargeText(betaID) == beta)
    #expect(interner.resolveLargeText(alphaAgainID) == alpha)

    let alphaBytes = interner.withLargeTextUTF8(alphaID) { Array($0) }
    #expect(alphaBytes == Array(alpha.utf8))
}

@Test func sharedTokenInternerExposesNamespaceAndMakeResolverReturnsSelf() {
    let interner = SharedTokenInterner()

    // namespace (TokenInterner) and tokenKeyNamespace (TokenResolver)
    // bridge to the same instance.
    #expect(interner.tokenKeyNamespace === interner.namespace)

    // Two distinct interners get distinct namespaces.
    let other = SharedTokenInterner()
    #expect(interner.namespace !== other.namespace)

    // makeResolver returns the live interner itself.
    let resolver = interner.makeResolver()
    #expect(ObjectIdentifier(resolver as AnyObject) == ObjectIdentifier(interner))
}

@Test func sharedTokenInternerCountTracksUniqueKeys() {
    let interner = SharedTokenInterner()
    #expect(interner.count == 0)

    _ = interner.intern("alpha")
    _ = interner.intern("beta")
    _ = interner.intern("alpha")  // dedup; count unchanged

    #expect(interner.count == 2)

    _ = interner.intern("gamma")
    #expect(interner.count == 3)
}

@Test func sharedTokenInternerLargeTextCountTracksAppendsWithoutDedup() {
    let interner = SharedTokenInterner()
    #expect(interner.largeTextCount == 0)

    _ = interner.storeLargeText("payload-a")
    _ = interner.storeLargeText("payload-b")
    _ = interner.storeLargeText("payload-a")  // no dedup; count grows

    #expect(interner.largeTextCount == 3)
}

