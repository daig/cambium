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

@Test func finishReturnsCacheForIdentityPreservingSubtreeReuse() throws {
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
    let cache = firstResult.intoCache()

    var secondBuilder = GreenTreeBuilder<TestLanguage>(cache: consume cache)
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
