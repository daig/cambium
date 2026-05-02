// CalculatorParallelEvaluator.swift

import Cambium
import Synchronization

/// Mutex-protected box for parallel-evaluator stats. Mirrors the
/// thread-safe sidecar pattern Cambium uses internally for
/// `IncrementalParseSession` counter aggregation.
///
/// `Mutex` is from `Synchronization`; the `withLock` API guarantees
/// the closure runs while holding the lock and panics on
/// re-entrance, so we cannot accidentally read inconsistent state
/// from a different task.
internal final class ParallelEvalStatsBox: @unchecked Sendable {
    private struct State {
        var stats = ParallelEvaluationReport()
        var inFlight = 0
    }

    private let storage = Mutex(State())

    /// `enter`/`exit` form a balanced bracket around each
    /// recursive evaluator call so we can observe the high-water
    /// mark of in-flight tasks.
    func enter() {
        storage.withLock { state in
            state.inFlight += 1
            if state.inFlight > state.stats.maxObservedConcurrency {
                state.stats.maxObservedConcurrency = state.inFlight
            }
        }
    }

    func exit() {
        storage.withLock { state in
            state.inFlight -= 1
        }
    }

    func recordCacheHit() {
        storage.withLock { state in state.stats.cacheHits += 1 }
    }

    func recordEvaluation() {
        storage.withLock { state in state.stats.nodeEvaluations += 1 }
    }

    func recordFork() {
        storage.withLock { state in state.stats.forkPoints += 1 }
    }

    func snapshot() -> ParallelEvaluationReport {
        storage.withLock { state in state.stats }
    }
}
