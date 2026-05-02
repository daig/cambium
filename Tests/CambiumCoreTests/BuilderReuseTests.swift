import CambiumBuilder
import CambiumCore
import Testing

@Test func reuseSubtreeRemapsDynamicTokenKeysFromDifferentInterner() throws {
    var sourceBuilder = GreenTreeBuilder<TestLanguage>()
    sourceBuilder.startNode(.root)
    sourceBuilder.startNode(.list)
    try sourceBuilder.token(.identifier, text: "source")
    try sourceBuilder.staticToken(.plus)
    sourceBuilder.missingToken(.plus)
    try sourceBuilder.largeToken(.identifier, text: "é")
    try sourceBuilder.finishNode()
    try sourceBuilder.finishNode()
    let sourceTree = try sourceBuilder.finish().snapshot.makeSyntaxTree()

    var targetBuilder = GreenTreeBuilder<TestLanguage>()
    targetBuilder.startNode(.root)
    try targetBuilder.token(.identifier, text: "target")
    let outcome: SubtreeReuseOutcome? = try sourceTree.withRoot { root in
        try root.withChildNode(at: 0) { list in
            try targetBuilder.reuseSubtree(list)
        }
    }
    try targetBuilder.finishNode()
    let targetTree = try targetBuilder.finish().snapshot.makeSyntaxTree()

    #expect(outcome == .remapped)
    #expect(targetTree.withRoot { $0.makeString() } == "targetsource+é")
}

@Test func finishReturnsContextForIdentityPreservingSubtreeReuse() throws {
    var firstBuilder = GreenTreeBuilder<TestLanguage>()
    firstBuilder.startNode(.root)
    firstBuilder.startNode(.list)
    try firstBuilder.token(.identifier, text: "shared")
    try firstBuilder.finishNode()
    try firstBuilder.finishNode()

    let firstResult = try firstBuilder.finish()
    let firstTree = firstResult.snapshot.makeSyntaxTree()
    let originalListIdentity = firstTree.withRoot { root in
        root.withChildNode(at: 0) { list in
            list.green { $0.identity }
        }
    }
    guard let originalListIdentity else {
        Issue.record("Expected source list node")
        return
    }
    let context = firstResult.intoContext()

    var secondBuilder = GreenTreeBuilder<TestLanguage>(context: consume context)
    secondBuilder.startNode(.root)
    let outcome: SubtreeReuseOutcome? = try firstTree.withRoot { root in
        try root.withChildNode(at: 0) { list in
            try secondBuilder.reuseSubtree(list)
        }
    }
    try secondBuilder.finishNode()

    let secondResult = try secondBuilder.finish()
    let secondTree = secondResult.snapshot.makeSyntaxTree()
    let reusedListIdentity = secondTree.withRoot { root in
        root.withChildNode(at: 0) { list in
            list.green { $0.identity }
        }
    }

    #expect(outcome == .direct)
    #expect(reusedListIdentity == originalListIdentity)
    #expect(secondTree.withRoot { $0.makeString() } == "shared")
}

@Test func parallelBuildersWithSharedInternerMutuallyDirectReuse() throws {
    // Four worker contexts, each with its own GreenNodeCache but bound
    // to one shared interner. Each worker builds a small subtree
    // containing the same identifier text. The master builder splices
    // each worker's subtree via reuseSubtree; every outcome must be
    // .direct because they share a token namespace.
    //
    // Note: we do NOT assert green-storage identity equivalence across
    // workers — they have independent green caches, so structurally-
    // equal subtrees may have distinct ObjectIdentifiers. Cross-cache
    // structural sharing requires SharedGreenNodeCache integration,
    // which is a separate follow-up.
    let shared = SharedTokenInterner()
    let commonKey = shared.intern("common")

    var workerOutcomes: [SubtreeReuseOutcome] = []
    var masterBuilder = GreenTreeBuilder<TestLanguage>(interner: shared)
    masterBuilder.startNode(.root)

    // Build each worker subtree, hand it to the master via reuseSubtree
    // immediately. SyntaxTree is ~Copyable so we can't collect a batch
    // first; structuring the loop this way also matches how a real
    // parallel-parsing pipeline would funnel worker results into the
    // master builder via Swift concurrency.
    for workerIndex in 0..<4 {
        var workerBuilder = GreenTreeBuilder<TestLanguage>(
            interner: shared,
            policy: .documentLocal
        )
        workerBuilder.startNode(.list)
        try workerBuilder.token(.identifier, text: "shared\(workerIndex)")
        try workerBuilder.token(.identifier, text: "common")
        try workerBuilder.finishNode()
        let workerResult = try workerBuilder.finish()
        let workerTree = workerResult.snapshot.makeSyntaxTree()

        let outcome = try workerTree.withRoot { root in
            try masterBuilder.reuseSubtree(root)
        }
        workerOutcomes.append(outcome)
    }

    try masterBuilder.finishNode()
    let masterResult = try masterBuilder.finish()
    let masterTree = masterResult.snapshot.makeSyntaxTree()

    // Every reuse should hit the .direct fast path because all workers
    // share the master's interner (and therefore its namespace).
    #expect(workerOutcomes.count == 4)
    #expect(workerOutcomes.allSatisfy { $0 == .direct })

    // Calling intern("common") again on the shared interner returns
    // the same key, because the interner deduplicates and every worker
    // contributed via the same interner instance.
    #expect(shared.intern("common") == commonKey)

    // The master tree renders the concatenation of every worker's
    // contribution, with token text resolved through the shared interner.
    let expected = (0..<4).map { "shared\($0)common" }.joined()
    #expect(masterTree.withRoot { $0.makeString() } == expected)
}

@Test func greenBuildResultExposesCacheStatistics() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    // Two identical tokens — the second hits the cache.
    try builder.token(.identifier, text: "x")
    try builder.token(.identifier, text: "x")
    try builder.finishNode()
    let result = try builder.finish()

    // The exact counters depend on the language's static-token shape,
    // but with a non-disabled policy and two equal dynamic tokens we
    // should observe at least one hit and one miss, and zero bypasses.
    #expect(result.cacheHitCount >= 1)
    #expect(result.cacheMissCount >= 1)
    #expect(result.cacheBypassCount == 0)
    #expect(result.cacheEvictionCount == 0)
}

@Test func greenBuildResultResolverIsSealedAtFinishForSharedInterner() throws {
    // For SharedTokenInterner-backed builds, `result.resolver` should
    // be the live interner instance — i.e., the same object regardless
    // of mutations the user makes between reads. A stored `let`
    // (versus a computed property re-invoking `makeResolver()`) is the
    // performance contract.
    let interner = SharedTokenInterner()
    var builder = GreenTreeBuilder<TestLanguage>(interner: interner)
    builder.startNode(.root)
    try builder.token(.identifier, text: "before")
    try builder.finishNode()
    let result = try builder.finish()

    let firstRead = result.resolver
    _ = interner.intern("after-finish")
    let secondRead = result.resolver

    // Both reads return the same interner instance.
    #expect(ObjectIdentifier(firstRead as AnyObject)
        == ObjectIdentifier(secondRead as AnyObject))
    // And it is the live SharedTokenInterner the builder was bound to.
    #expect(ObjectIdentifier(firstRead as AnyObject)
        == ObjectIdentifier(interner))
}
