// CalculatorSession.swift

import Cambium

extension CalculatorSession {
    /// Build a ``CambiumIncremental/ParseWitness`` describing the
    /// reparse that just happened. The witness pairs old and new
    /// roots with a list of subtrees that were carried by reference
    /// — every subsequent identity-tracking pass can use it to map
    /// old-tree references onto the new tree.
    func makeParseWitness(
        previousTree: SharedSyntaxTree<CalculatorLanguage>?,
        newTree: SharedSyntaxTree<CalculatorLanguage>
    ) -> ParseWitness<CalculatorLanguage> {
        // The parser populated `incremental` with one
        // `recordAcceptedReuse` call per successful splice. Drain
        // that log here.
        return ParseWitness(
            oldRoot: previousTree?.rootGreen,
            newRoot: newTree.rootGreen,
            reusedSubtrees: incremental.consumeAcceptedReuses()
        )
    }
}

// Inside the parser:
//
// When `attemptReuse` returns successfully and the outcome is
// `.direct`, the parser adds a record:
//
//     incremental?.recordAcceptedReuse(
//         oldPath: cursor.childIndexPath(),
//         newPath: <where it landed in the new tree>,
//         green: cursor.green { $0 }
//     )
//
// `oldPath` is read from the previous-tree cursor's path; `newPath`
// is computed by the session after parsing finishes (the parser
// doesn't yet know its own output shape during the splice). The
// witness then carries a `Reuse<Lang>` per record:
//
//     reuse.oldPath          // path in v0
//     reuse.newPath          // path in v1
//     reuse.green            // the spliced green subtree
//
// Tutorial 9 uses this triple to translate per-node analysis cache
// entries from v0 onto v1.
