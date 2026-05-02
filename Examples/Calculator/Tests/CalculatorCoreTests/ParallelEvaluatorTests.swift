import CalculatorCore
import Cambium
import Testing

@Test func parallelEvaluationMatchesSequential() async throws {
    let session = CalculatorSession()
    _ = try session.parse("(1 + 2) * (3 + 4) - round(5.5) / 2")

    let sequentialValue = try session.evaluate()

    // `session.evaluateInParallel()` uses a fresh cache every call so
    // the demo always exercises the fork/join evaluator. Successive
    // calls therefore look the same — full evaluation, no cache hits.
    let firstParallel = try await session.evaluateInParallel()
    #expect(firstParallel.value == sequentialValue)
    #expect(firstParallel.report.cacheHits == 0)
    #expect(firstParallel.report.nodeEvaluations > 0)
    #expect(firstParallel.report.forkPoints > 0)

    let secondParallel = try await session.evaluateInParallel()
    #expect(secondParallel.value == sequentialValue)
    #expect(secondParallel.report.cacheHits == 0)
    #expect(secondParallel.report.nodeEvaluations == firstParallel.report.nodeEvaluations)
}

@Test func parallelEvaluatorSharesCacheAcrossPasses() async throws {
    // Drives `evaluateCalculatorTreeInParallel` directly with an
    // explicit `ExternalAnalysisCache`. First pass populates every
    // entry; second pass short-circuits at the root because the cache
    // serves that key.
    let parsed = try parseCalculator("(1 + 2) * (3 + 4) - round(5.5) / 2")
    let cache = ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>()

    let firstPass = try await evaluateCalculatorTreeInParallel(parsed.tree, cache: cache)
    #expect(firstPass.report.cacheHits == 0)
    #expect(firstPass.report.nodeEvaluations > 0)

    let secondPass = try await evaluateCalculatorTreeInParallel(parsed.tree, cache: cache)
    #expect(secondPass.value == firstPass.value)
    #expect(secondPass.report.cacheHits == 1)
    #expect(secondPass.report.nodeEvaluations == 0)
    #expect(secondPass.report.forkPoints == 0)
}

@Test func parallelEvaluatorReportTracksForkSites() async throws {
    let session = CalculatorSession()
    _ = try session.parse("1 + 2 * 3 + 4")  // three binaryExpr nodes

    let outcome = try await session.evaluateInParallel()
    #expect(outcome.value == .integer(11))
    #expect(outcome.report.forkPoints == 3)
    #expect(outcome.report.maxObservedConcurrency >= 2)
}

@Test func concurrentParallelEvaluationsAreConsistent() async throws {
    // Parse once, share the resulting `SharedSyntaxTree` (Sendable),
    // one `ExternalAnalysisCache` (thread-safe), and one
    // `SyntaxMetadataStore` (thread-safe) across 16 concurrent
    // evaluator tasks. This is the canonical "concurrent readers of a
    // promoted tree" shape from the Cambium concurrency story.
    let parsed = try parseCalculator("(1 + 2) * (3 + 4) - round(5.5) / 2")
    let tree = parsed.tree
    let expected = try parsed.evaluate()

    let cache = ExternalAnalysisCache<CalculatorLanguage, CalculatorValue>()
    let metadata = SyntaxMetadataStore<CalculatorLanguage>()

    let results = try await withThrowingTaskGroup(
        of: CalculatorValue.self
    ) { group in
        for _ in 0..<16 {
            group.addTask {
                let outcome = try await evaluateCalculatorTreeInParallel(
                    tree,
                    cache: cache,
                    metadata: metadata
                )
                return outcome.value
            }
        }
        var collected: [CalculatorValue] = []
        for try await value in group {
            collected.append(value)
        }
        return collected
    }

    #expect(results.count == 16)
    for value in results {
        #expect(value == expected)
    }
}
