// CalculatorParser.swift

import Cambium

extension CalculatorParser {
    /// Try to splice an unchanged subtree from the previous parse at
    /// the parser's current source offset. Returns `true` when a
    /// subtree was reused (and the lexer was advanced past its
    /// bytes), `false` otherwise.
    mutating func tryReusePrefix(at newOffset: TextSize) throws -> Bool {
        guard let previousTree else { return false }

        // The parser walks NEW-source coordinates. The reuse oracle
        // walks OLD-tree coordinates. `mapNewOffsetToOld` translates
        // by replaying the edits.
        guard let oldOffset = Self.mapNewOffsetToOld(newOffset, edits: edits) else {
            return false
        }

        // The oracle is `~Copyable`, so we mint one locally inside
        // each prefix attempt. The session reference (carried inside
        // the oracle) is what aggregates counters across attempts.
        let oracle = ReuseOracle<CalculatorLanguage>(
            previousTree: previousTree,
            edits: edits,
            session: incremental
        )

        for kind in Self.reusableKinds {
            if try attemptReuse(
                oracle: oracle,
                oldOffset: oldOffset,
                newOffset: newOffset,
                kind: kind
            ) {
                return true
            }
        }
        return false
    }

    private mutating func attemptReuse(
        oracle: borrowing ReuseOracle<CalculatorLanguage>,
        oldOffset: TextSize,
        newOffset: TextSize,
        kind: CalculatorKind
    ) throws -> Bool {
        var spliced = false
        try oracle.withReusableNode(startingAt: oldOffset, kind: kind) { cursor in
            // Cambium hands the closure a borrowed cursor on the
            // candidate subtree from the *previous* tree. The
            // closure decides whether the splice is safe; here we
            // verify byte-length alignment in the new lexer, then
            // splice via `reuseSubtree`.
            guard let tokenCount = tokenCountMatching(text: cursor.makeString()) else {
                return
            }
            let outcome = try builder.reuseSubtree(cursor)
            // `outcome` is `.direct` (namespaces matched, no
            // remapping) or `.remapped` (dynamic tokens were re-
            // interned into the new namespace). Both produce a
            // structurally-equivalent subtree.
            _ = outcome
            skipTokens(count: tokenCount)
            spliced = true
        }
        return spliced
    }

    private func tokenCountMatching(text: String) -> Int? {
        var consumed = ""
        var index = currentIndex
        let expectedLength = text.utf8.count
        while index < tokens.count, consumed.utf8.count < expectedLength {
            let token = tokens[index]
            if token.kind == .eof { return nil }
            consumed += token.text
            index += 1
        }
        return consumed == text ? index - currentIndex : nil
    }

    private mutating func skipTokens(count: Int) {
        for _ in 0..<count where tokens[currentIndex].kind != .eof {
            currentIndex += 1
        }
    }

    /// Translate a NEW-source byte offset into OLD-tree coordinates.
    /// `edits` are non-overlapping and sorted by start in OLD coords
    /// per the ``CambiumIncremental/ParseInput`` contract. Returns
    /// `nil` if the new offset falls inside an edit's replacement
    /// region — there is no corresponding old offset.
    static func mapNewOffsetToOld(
        _ newOffset: TextSize,
        edits: [TextEdit]
    ) -> TextSize? {
        var shift: Int64 = 0
        let newOff = Int64(newOffset.rawValue)
        for edit in edits {
            let oldStart = Int64(edit.range.start.rawValue)
            let oldEnd = Int64(edit.range.end.rawValue)
            let oldLen = oldEnd - oldStart
            let newLen = Int64(edit.replacementLength.rawValue)
            let newStart = oldStart + shift
            let newEnd = newStart + newLen
            if newOff >= newStart, newOff < newEnd { return nil }
            if newOff >= newEnd { shift += (newLen - oldLen) }
        }
        let oldOff = newOff - shift
        guard oldOff >= 0, oldOff <= Int64(UInt32.max) else { return nil }
        return TextSize(UInt32(oldOff))
    }
}
