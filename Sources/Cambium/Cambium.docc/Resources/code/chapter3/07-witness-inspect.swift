// WitnessDemo.swift
//
// Demonstrates `ReplacementWitness.classify(path:)`. The witness lets
// any consumer reason about how a path in the *old* tree maps onto
// the *new* tree.

import Cambium

func describeFoldStep(_ step: FoldStep) {
    print("folded \(step.oldText) -> \(step.newText)")
    print("  replaced path = \(step.replacedPath)")

    // The witness's `classify(path:)` returns a `ReplacementOutcome`:
    //
    // - `.unchanged`                   → path's node is preserved in
    //                                    the new tree.
    // - `.ancestor`                    → path is a strict prefix of
    //                                    the replaced path; the
    //                                    ancestor still exists.
    // - `.replacedRoot(newSubtree:)`   → path == replacedPath; the
    //                                    associated value is the new
    //                                    green subtree at that
    //                                    position.
    // - `.deleted`                     → path was inside the
    //                                    replaced region; the node
    //                                    it referred to is gone.
    //
    // Long-lived references to old-tree nodes use this classification
    // to decide whether to keep, retarget, or evict.
    let cases: [SyntaxNodePath] = [
        [],                   // root
        step.replacedPath,    // the replaced node itself
    ]
    for path in cases {
        switch step.witness.classify(path: path) {
        case .unchanged:
            print("  classify(\(path)) = .unchanged")
        case .ancestor:
            print("  classify(\(path)) = .ancestor")
        case .replacedRoot(let newSubtree):
            print(
                "  classify(\(path)) = .replacedRoot",
                "(\(CalculatorLanguage.name(for: newSubtree.kind)))"
            )
        case .deleted:
            print("  classify(\(path)) = .deleted")
        }
    }
}
