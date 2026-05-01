import CalculatorCore
import Cambium
import Foundation
import Testing

@Test func foldReducesNestedExpressionToLiteral() throws {
    let session = CalculatorSession()
    let parsed = try session.parse("1 + 2 * 3 + 4")
    #expect(parsed.diagnostics.isEmpty)

    let report = try session.fold()

    #expect(report.finalSource == "11")
    #expect(report.steps.count == 3)
    #expect(report.steps.map(\.oldKind) == [.binaryExpr, .binaryExpr, .binaryExpr])
    #expect(report.steps.map(\.newKind) == [.integerExpr, .integerExpr, .integerExpr])
    #expect(report.steps.map(\.newText) == ["6", "7", "11"])

    let reparsed = try session.parse(report.finalSource)
    #expect(reparsed.diagnostics.isEmpty)
    let value = try reparsed.evaluate()
    #expect(value == .integer(11))
}

@Test func foldWitnessClassifiesPathRelations() throws {
    let session = CalculatorSession()
    _ = try session.parse("1 + 2 * 3 + 4")
    let report = try session.fold()
    let witness = report.steps[0].witness

    if case .replacedRoot = witness.classify(path: witness.replacedPath) {
    } else {
        Issue.record("expected replaced path to classify as .replacedRoot")
    }

    let parentPath = SyntaxNodePath(witness.replacedPath.dropLast())
    if case .ancestor = witness.classify(path: parentPath) {
    } else {
        Issue.record("expected replaced parent path to classify as .ancestor")
    }

    guard let deletedPath = firstPath(in: witness.oldRoot, matching: { path in
        if case .deleted = witness.classify(path: path) {
            return true
        }
        return false
    }) else {
        Issue.record("expected a deleted descendant path")
        return
    }
    if case .deleted = witness.classify(path: deletedPath) {
    } else {
        Issue.record("expected deleted descendant path to classify as .deleted")
    }

    guard let unchangedPath = firstPath(in: witness.oldRoot, matching: { path in
        if case .unchanged = witness.classify(path: path) {
            return true
        }
        return false
    }) else {
        Issue.record("expected an unchanged sibling path")
        return
    }
    if case .unchanged = witness.classify(path: unchangedPath) {
    } else {
        Issue.record("expected sibling path to classify as .unchanged")
    }
}

@Test func foldHandlesRoundGroupUnaryAndRealResults() throws {
    let session = CalculatorSession()
    let parsed = try session.parse("round(2.6) + -(3)")
    #expect(parsed.diagnostics.isEmpty)

    let report = try session.fold()

    #expect(report.finalSource == "0")
    #expect(report.steps.map(\.oldKind).contains(.roundCallExpr))
    #expect(report.steps.map(\.oldKind).contains(.groupExpr))
    #expect(report.steps.map(\.oldKind).contains(.unaryExpr))
    #expect(report.steps.map(\.oldKind).contains(.binaryExpr))

    let realSession = CalculatorSession()
    _ = try realSession.parse("1.25 + 2")
    let realReport = try realSession.fold()
    #expect(realReport.finalSource == "3.25")
    #expect(realReport.steps.last?.newKind == .realExpr)
}

@Test func foldRejectsInvalidCurrentDocument() throws {
    let session = CalculatorSession()
    let parsed = try session.parse("1 +")
    #expect(!parsed.diagnostics.isEmpty)

    do {
        _ = try session.fold()
        Issue.record("expected fold to reject invalid syntax")
    } catch CalculatorEvaluationError.invalidSyntax(let message) {
        #expect(message.contains("expected expression"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func foldSkipsThrowingCandidatesAndKeepsSafeFolds() throws {
    let session = CalculatorSession()
    let parsed = try session.parse("1 / 0 + 2 * 3")
    #expect(parsed.diagnostics.isEmpty)

    let report = try session.fold()

    #expect(report.steps.count == 1)
    #expect(report.steps[0].oldText.trimmingCharacters(in: .whitespacesAndNewlines) == "2 * 3")
    #expect(report.steps[0].newText == "6")
    #expect(report.finalSource == "1 / 0 + 6")
}

@Test func foldedSessionCanReparseWithCarriedCache() throws {
    let session = CalculatorSession()
    _ = try session.parse("1 + 2 * 3 + 4")
    let report = try session.fold()
    #expect(report.finalSource == "11")

    let offset = TextSize(UInt32(report.finalSource.utf8.count))
    let edit = TextEdit(
        range: TextRange(start: offset, end: offset),
        replacement: " + 1"
    )
    let reparsed = try session.parse(report.finalSource + " + 1", edits: [edit])

    #expect(reparsed.diagnostics.isEmpty)
    let value = try reparsed.evaluate()
    #expect(value == .integer(12))
    #expect(session.counters.reuseQueries > 0)
    #expect(session.counters.reuseHits > 0)
}

private func firstPath(
    in node: GreenNode<CalculatorLanguage>,
    path: SyntaxNodePath = [],
    matching matches: (SyntaxNodePath) -> Bool
) -> SyntaxNodePath? {
    if matches(path) {
        return path
    }
    for childIndex in 0..<node.childCount {
        guard case .node(let child) = node.child(at: childIndex) else {
            continue
        }
        var childPath = path
        childPath.append(UInt32(childIndex))
        if let found = firstPath(in: child, path: childPath, matching: matches) {
            return found
        }
    }
    return nil
}
