import CambiumBuilder
@testable import CambiumCore
import Testing

private let cacheIdentifierKind = RawSyntaxKind(TestKind.identifier.rawValue)
private let cacheListKind = RawSyntaxKind(TestKind.list.rawValue)
private let cachePlusKind = RawSyntaxKind(TestKind.plus.rawValue)

private func plusToken() -> GreenToken<TestLanguage> {
    GreenToken(kind: cachePlusKind, textLength: 1, text: .staticText)
}

@Test func parseSessionAndSharedPoliciesRejectNonPositiveEntryCounts() async {
    await #expect(processExitsWith: .failure) {
        _ = GreenNodeCache<TestLanguage>(policy: .parseSession(maxEntries: 0))
    }

    await #expect(processExitsWith: .failure) {
        _ = SharedGreenNodeCache<TestLanguage>(policy: .shared(maxEntries: -1))
    }
}

@Test func tokensRemainCacheableUnderBoundedPolicy() {
    var cache = GreenNodeCache<TestLanguage>(policy: .parseSession(maxEntries: 1))

    let first = cache.makeToken(kind: cacheIdentifierKind, textLength: 1, text: .interned(TokenKey(0)))
    let second = cache.makeToken(kind: cacheIdentifierKind, textLength: 1, text: .interned(TokenKey(0)))

    #expect(ObjectIdentifier(first.storage) == ObjectIdentifier(second.storage))
    #expect(cache.hitCount == 1)
    #expect(cache.missCount == 1)
    #expect(cache.bypassCount == 0)
    #expect(cache.evictionCount == 0)
}

@Test func smallNodesDeduplicateAndPreserveGreenIdentity() throws {
    var cache = GreenNodeCache<TestLanguage>(policy: .parseSession(maxEntries: 2))
    let token = plusToken()

    let first = try cache.makeNode(kind: cacheListKind, children: [.token(token), .token(token), .token(token)])
    let second = try cache.makeNode(kind: cacheListKind, children: [.token(token), .token(token), .token(token)])

    #expect(first == second)
    #expect(ObjectIdentifier(first.storage) == ObjectIdentifier(second.storage))
    #expect(cache.hitCount == 1)
    #expect(cache.missCount == 1)
    #expect(cache.bypassCount == 0)
    #expect(cache.evictionCount == 0)
}

@Test func wideNodesBypassCacheAndDoNotPreserveGreenIdentity() throws {
    var cache = GreenNodeCache<TestLanguage>(policy: .parseSession(maxEntries: 8))
    let token = plusToken()
    let children: [GreenElement<TestLanguage>] = [
        .token(token),
        .token(token),
        .token(token),
        .token(token),
    ]

    let first = try cache.makeNode(kind: cacheListKind, children: children)
    let second = try cache.makeNode(kind: cacheListKind, children: children)

    #expect(first == second)
    #expect(ObjectIdentifier(first.storage) != ObjectIdentifier(second.storage))
    #expect(cache.hitCount == 0)
    #expect(cache.missCount == 0)
    #expect(cache.bypassCount == 2)
    #expect(cache.evictionCount == 0)
}

@Test func fifoEvictionRemovesOldestLiveEntryDeterministically() {
    var cache = GreenNodeCache<TestLanguage>(policy: .parseSession(maxEntries: 2))

    let firstA = cache.makeToken(kind: cacheIdentifierKind, textLength: 1, text: .interned(TokenKey(0)))
    let firstB = cache.makeToken(kind: cacheIdentifierKind, textLength: 1, text: .interned(TokenKey(1)))
    _ = cache.makeToken(kind: cacheIdentifierKind, textLength: 1, text: .interned(TokenKey(2)))

    #expect(cache.evictionCount == 1)

    let secondB = cache.makeToken(kind: cacheIdentifierKind, textLength: 1, text: .interned(TokenKey(1)))
    let secondA = cache.makeToken(kind: cacheIdentifierKind, textLength: 1, text: .interned(TokenKey(0)))

    #expect(ObjectIdentifier(firstB.storage) == ObjectIdentifier(secondB.storage))
    #expect(ObjectIdentifier(firstA.storage) != ObjectIdentifier(secondA.storage))
    #expect(cache.hitCount == 1)
    #expect(cache.missCount == 4)
    #expect(cache.bypassCount == 0)
    #expect(cache.evictionCount == 2)
}

@Test func disabledPolicyBypassesTokenCache() {
    var cache = GreenNodeCache<TestLanguage>(policy: .disabled)

    let first = cache.makeToken(kind: cacheIdentifierKind, textLength: 1, text: .interned(TokenKey(0)))
    let second = cache.makeToken(kind: cacheIdentifierKind, textLength: 1, text: .interned(TokenKey(0)))

    #expect(ObjectIdentifier(first.storage) != ObjectIdentifier(second.storage))
    #expect(cache.hitCount == 0)
    #expect(cache.missCount == 0)
    #expect(cache.bypassCount == 2)
    #expect(cache.evictionCount == 0)
}

@Test func disabledPolicyBypassesNodeCache() throws {
    var cache = GreenNodeCache<TestLanguage>(policy: .disabled)
    let token = plusToken()

    // A 3-child node would be eligible under any non-disabled policy. Under
    // `.disabled` it bypasses regardless of size.
    let first = try cache.makeNode(kind: cacheListKind, children: [.token(token), .token(token), .token(token)])
    let second = try cache.makeNode(kind: cacheListKind, children: [.token(token), .token(token), .token(token)])

    #expect(first == second)
    #expect(ObjectIdentifier(first.storage) != ObjectIdentifier(second.storage))
    #expect(cache.hitCount == 0)
    #expect(cache.missCount == 0)
    #expect(cache.bypassCount == 2)
    #expect(cache.evictionCount == 0)
}
