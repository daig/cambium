import CalculatorCore
import Cambium
import Foundation

@main
struct CalculatorREPL {
    static func main() {
        var session = CalculatorSession()
        var document: String = ""
        var lastResult: CalculatorParseResult?
        var showTree = false
        var showTypedAST = false

        while true {
            print("calc> ", terminator: "")
            guard let line = readLine() else {
                print()
                return
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            switch trimmed {
            case "":
                continue
            case ":q", ":quit":
                return
            case ":help":
                printHelp()
                continue
            case ":tree":
                showTree.toggle()
                print("tree dumps \(showTree ? "on" : "off")")
                continue
            case ":ast":
                showTypedAST.toggle()
                print("typed AST dumps \(showTypedAST ? "on" : "off")")
                continue
            case ":show":
                if document.isEmpty {
                    print("(empty document)")
                } else {
                    print(document)
                    runAndPrint(
                        document,
                        edits: [],
                        session: session,
                        lastResult: &lastResult,
                        showTree: showTree,
                        showTypedAST: showTypedAST
                    )
                }
                continue
            case ":fold":
                if document.isEmpty {
                    print("error: no current document")
                } else {
                    foldAndPrint(
                        session: session,
                        document: &document,
                        lastResult: &lastResult
                    )
                }
                continue
            case ":counters":
                let c = session.counters
                let eval = session.evaluationStats
                print(
                    "queries=\(c.reuseQueries) hits=\(c.reuseHits) reusedBytes=\(c.reusedBytes) evalNodes=\(eval.evalNodes) evalHits=\(eval.evalHits)"
                )
                continue
            case ":cached":
                printCachedValues(session.cachedValues())
                continue
            case ":reset":
                session = CalculatorSession()
                document = ""
                lastResult = nil
                print("session reset")
                continue
            default:
                break
            }

            if trimmed == ":save" {
                print("error: usage is :save <path>")
                continue
            }

            if trimmed.hasPrefix(":save ") {
                let path = String(trimmed.dropFirst(":save ".count))
                    .trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else {
                    print("error: usage is :save <path>")
                    continue
                }
                guard let result = lastResult else {
                    print("error: no document to save")
                    continue
                }
                guard result.diagnostics.isEmpty else {
                    print("error: cannot save a tree with parse diagnostics")
                    continue
                }

                do {
                    let bytes = try result.tree.serializeGreenSnapshot()
                    try Data(bytes).write(to: URL(fileURLWithPath: path))
                    print("saved \(bytes.count) bytes to \(path)")
                } catch let error as CambiumSerializationError {
                    print("serialization error: \(error)")
                } catch {
                    print("error: \(error)")
                }
                continue
            }

            if trimmed == ":load" {
                print("error: usage is :load <path>")
                continue
            }

            if trimmed.hasPrefix(":load ") {
                let path = String(trimmed.dropFirst(":load ".count))
                    .trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else {
                    print("error: usage is :load <path>")
                    continue
                }

                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let bytes = Array(data)
                    let tree = try GreenSnapshotDecoder
                        .decodeTree(bytes, as: CalculatorLanguage.self)
                        .intoShared()
                    document = tree.withRoot { root in
                        root.makeString()
                    }
                    session.adopt(tree)
                    let result = CalculatorParseResult(tree: tree, diagnostics: [])
                    lastResult = result
                    print("loaded \(bytes.count) bytes from \(path)")
                    printResult(
                        result,
                        session: session,
                        showTree: showTree,
                        showTypedAST: showTypedAST
                    )
                } catch let error as CambiumSerializationError {
                    print("serialization error: \(error)")
                } catch {
                    print("error: \(error)")
                }
                continue
            }

            if trimmed == ":at" {
                print("error: usage is :at <offset>")
                continue
            }

            if trimmed.hasPrefix(":at ") {
                let body = String(trimmed.dropFirst(":at ".count))
                printTokenAtOffset(body, in: lastResult)
                continue
            }

            if trimmed == ":cover" {
                print("error: usage is :cover <start>..<end>")
                continue
            }

            if trimmed.hasPrefix(":cover ") {
                let body = String(trimmed.dropFirst(":cover ".count))
                printCoveringElement(body, in: lastResult)
                continue
            }

            if trimmed.hasPrefix(":edit ") {
                let body = String(trimmed.dropFirst(":edit ".count))
                guard let parsed = parseEditCommand(body) else {
                    print("error: usage is :edit <start>..<end> <replacement>")
                    continue
                }

                let edit = TextEdit(
                    range: TextRange(
                        start: TextSize(UInt32(parsed.start)),
                        end: TextSize(UInt32(parsed.end))
                    ),
                    replacement: parsed.replacement
                )

                guard let newDocument = applyEdit(edit, to: document) else {
                    print("error: edit range out of bounds for current document")
                    continue
                }

                print("- \(document)")
                print("+ \(newDocument)")
                document = newDocument
                runAndPrint(
                    document,
                    edits: [edit],
                    session: session,
                    lastResult: &lastResult,
                    showTree: showTree,
                    showTypedAST: showTypedAST
                )
                continue
            }

            // Plain input — replace the document and reparse with no edits.
            document = line
            runAndPrint(
                document,
                edits: [],
                session: session,
                lastResult: &lastResult,
                showTree: showTree,
                showTypedAST: showTypedAST
            )
        }
    }

    private static func printHelp() {
        print("""
        commands:
          <expression>                replace document and evaluate
          :edit <start>..<end> <text> apply a byte-range edit and reparse
          :at <offset>                show token ownership at a byte offset
          :cover <start>..<end>       show smallest element covering a byte range
          :show                       show current document and re-evaluate
          :save <path>                write current clean tree snapshot
          :load <path>                load a tree snapshot as the document
          :fold                       constant-fold current document, showing witnesses
          :counters                   print incremental reuse and evaluator cache counters
          :cached                     print cached evaluator values for the current tree
          :reset                      drop session state (cache, last tree, counters)
          :tree                       toggle CST dumps
          :ast                        toggle typed AST dumps
          :help                       this listing
          :q | :quit                  exit
        """)
    }

    private static func runAndPrint(
        _ input: String,
        edits: [TextEdit],
        session: CalculatorSession,
        lastResult: inout CalculatorParseResult?,
        showTree: Bool,
        showTypedAST: Bool
    ) {
        do {
            let result = try session.parse(input, edits: edits)
            lastResult = result
            printResult(
                result,
                session: session,
                showTree: showTree,
                showTypedAST: showTypedAST
            )
        } catch let error as CalculatorEvaluationError {
            print("error: \(error)")
        } catch {
            print("internal error: \(error)")
        }
    }

    private static func printResult(
        _ result: CalculatorParseResult,
        session: CalculatorSession,
        showTree: Bool,
        showTypedAST: Bool
    ) {
        if showTree {
            print(result.debugTree())
        }
        if showTypedAST {
            print(result.debugTypedAST())
        }

        guard result.diagnostics.isEmpty else {
            for diagnostic in result.diagnostics {
                print(formatDiagnostic(diagnostic))
            }
            return
        }

        do {
            print(try session.evaluate())
        } catch let error as CalculatorEvaluationError {
            print("error: \(error)")
        } catch {
            print("internal error: \(error)")
        }
    }

    private static func printCachedValues(_ values: [CalculatorCachedValue]) {
        guard !values.isEmpty else {
            print("(cache empty)")
            return
        }

        for value in values {
            let metadata: String
            if let order = value.evaluationOrder, let kind = value.valueKind {
                metadata = " order=\(order) kind=\(kind)"
            } else {
                metadata = ""
            }
            print("\(format(value.range)) = \(value.value)\(metadata)")
        }
    }

    private static func printTokenAtOffset(
        _ body: String,
        in lastResult: CalculatorParseResult?
    ) {
        guard let lastResult else {
            print("(no document parsed yet)")
            return
        }

        let offsetText = body.trimmingCharacters(in: .whitespaces)
        guard let rawOffset = UInt32(offsetText) else {
            print("error: usage is :at <offset>")
            return
        }

        let offset = TextSize(rawOffset)
        lastResult.tree.withRoot { root in
            root.withTokenAtOffset(
                offset,
                none: {
                    print("(no token at offset \(rawOffset))")
                },
                single: { token in
                    print("single: \(describeToken(token))")
                },
                between: { left, right in
                    print("between: \(describeTokenBoundary(left)) | \(describeTokenBoundary(right))")
                }
            )
        }
    }

    private static func printCoveringElement(
        _ body: String,
        in lastResult: CalculatorParseResult?
    ) {
        guard let lastResult else {
            print("(no document parsed yet)")
            return
        }

        let rangeText = body.trimmingCharacters(in: .whitespaces)
        guard let byteRange = parseByteRange(rangeText) else {
            print("error: usage is :cover <start>..<end>")
            return
        }

        let range = TextRange(
            start: TextSize(UInt32(byteRange.start)),
            end: TextSize(UInt32(byteRange.end))
        )
        let result: String? = lastResult.tree.withRoot { root in
            root.withCoveringElement(range) { element in
                describeElement(element)
            }
        }

        print(result ?? "(no element covers \(format(range)))")
    }

    private static func describeElement(
        _ element: borrowing SyntaxElementCursor<CalculatorLanguage>
    ) -> String {
        switch element {
        case .node(let node):
            "node: \(CalculatorLanguage.name(for: node.kind)) \(format(node.textRange))"
        case .token(let token):
            "token: \(describeToken(token))"
        }
    }

    private static func describeToken(
        _ token: borrowing SyntaxTokenCursor<CalculatorLanguage>
    ) -> String {
        "\(describeTokenBoundary(token)) \"\(escaped(token.makeString()))\""
    }

    private static func describeTokenBoundary(
        _ token: borrowing SyntaxTokenCursor<CalculatorLanguage>
    ) -> String {
        "\(CalculatorLanguage.name(for: token.kind)) \(format(token.textRange))"
    }

    private static func foldAndPrint(
        session: CalculatorSession,
        document: inout String,
        lastResult: inout CalculatorParseResult?
    ) {
        do {
            let report = try session.fold()
            document = report.finalSource
            lastResult = CalculatorParseResult(
                tree: report.finalTree,
                diagnostics: []
            )
            guard !report.steps.isEmpty else {
                print("no folds available")
                return
            }

            for step in report.steps {
                print(
                    "folded \(step.oldKindDisplayName) \"\(escaped(displayFoldText(step.oldText)))\" at path \(formatPath(step.replacedPath)) -> \(step.newKindDisplayName) \"\(escaped(step.newText))\""
                )
                print(
                    "  witness: oldRoot kind=\(CalculatorLanguage.name(for: step.witness.oldRoot.kind)), newRoot kind=\(CalculatorLanguage.name(for: step.witness.newRoot.kind))"
                )
                for path in classificationSamplePaths(for: step.witness) {
                    print(
                        "    classify(\(formatPath(path))) = \(formatOutcome(step.witness.classify(path: path)))"
                    )
                }
            }
        } catch let error as CalculatorEvaluationError {
            print("error: \(error)")
        } catch {
            print("internal error: \(error)")
        }
    }

    private static func classificationSamplePaths(
        for witness: ReplacementWitness<CalculatorLanguage>
    ) -> [SyntaxNodePath] {
        var paths: [SyntaxNodePath] = []
        appendSample(witness.replacedPath, to: &paths)

        if let deleted = firstPath(in: witness.oldRoot, matching: { path in
            if case .deleted = witness.classify(path: path) {
                return true
            }
            return false
        }) {
            appendSample(deleted, to: &paths)
        }

        if !witness.replacedPath.isEmpty {
            appendSample(Array(witness.replacedPath.dropLast()), to: &paths)
        }

        if let unchanged = firstPath(in: witness.oldRoot, matching: { path in
            if case .unchanged = witness.classify(path: path) {
                return true
            }
            return false
        }) {
            appendSample(unchanged, to: &paths)
        }

        return paths
    }

    private static func appendSample(
        _ path: SyntaxNodePath,
        to paths: inout [SyntaxNodePath]
    ) {
        if !paths.contains(path) {
            paths.append(path)
        }
    }

    private static func firstPath(
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

    private static func formatPath(_ path: SyntaxNodePath) -> String {
        "[\(path.map(String.init).joined(separator: ", "))]"
    }

    private static func displayFoldText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    private static func formatOutcome(
        _ outcome: ReplacementOutcome<CalculatorLanguage>
    ) -> String {
        switch outcome {
        case .unchanged:
            ".unchanged"
        case .ancestor:
            ".ancestor"
        case .replacedRoot:
            ".replacedRoot"
        case .deleted:
            ".deleted"
        }
    }
}

private struct ParsedEdit {
    var start: Int
    var end: Int
    var replacement: String
}

private struct ParsedByteRange {
    var start: Int
    var end: Int
}

private func parseEditCommand(_ body: String) -> ParsedEdit? {
    // Form: "<digits>..<digits>[ <replacement-rest-of-line>]"
    // The replacement is everything after the first space following the range.
    let separatorIndex: String.Index
    if let space = body.firstIndex(of: " ") {
        separatorIndex = space
    } else {
        separatorIndex = body.endIndex
    }

    let rangePart = body[..<separatorIndex]
    let replacement: String
    if separatorIndex < body.endIndex {
        replacement = String(body[body.index(after: separatorIndex)...])
    } else {
        replacement = ""
    }

    guard let range = parseByteRange(String(rangePart)) else {
        return nil
    }
    return ParsedEdit(start: range.start, end: range.end, replacement: replacement)
}

private func parseByteRange(_ text: String) -> ParsedByteRange? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let pieces: [String]
    if trimmed.contains("..<") {
        pieces = trimmed.components(separatedBy: "..<")
    } else {
        pieces = trimmed.components(separatedBy: "..")
    }

    guard pieces.count == 2,
          let start = UInt32(pieces[0].trimmingCharacters(in: .whitespaces)),
          let end = UInt32(pieces[1].trimmingCharacters(in: .whitespaces)),
          end >= start
    else {
        return nil
    }
    return ParsedByteRange(start: Int(start), end: Int(end))
}

private func applyEdit(_ edit: TextEdit, to source: String) -> String? {
    let sourceBytes = Array(source.utf8)
    let start = Int(edit.range.start.rawValue)
    let end = Int(edit.range.end.rawValue)
    guard start >= 0, end >= start, end <= sourceBytes.count else {
        return nil
    }

    var result: [UInt8] = []
    result.reserveCapacity(sourceBytes.count - (end - start) + edit.replacementUTF8.count)
    result.append(contentsOf: sourceBytes[..<start])
    result.append(contentsOf: edit.replacementUTF8)
    result.append(contentsOf: sourceBytes[end...])

    return String(decoding: result, as: UTF8.self)
}

private func escaped(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\n":
            result += "\\n"
        case "\r":
            result += "\\r"
        case "\t":
            result += "\\t"
        case "\"":
            result += "\\\""
        case "\\":
            result += "\\\\"
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}
