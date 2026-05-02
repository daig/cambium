import Cambium

enum LexedTokenKind: Sendable, Equatable {
    case number
    case realNumber
    case whitespace
    case plus
    case minus
    case star
    case slash
    case leftParen
    case rightParen
    case round
    case invalid
    case eof
}

struct LexedToken: Sendable, Equatable {
    var kind: LexedTokenKind
    var text: String
    var byteOffset: Int
    var byteLength: Int

    var range: TextRange {
        TextRange(
            start: TextSize(rawValue: UInt32(byteOffset)),
            length: TextSize(rawValue: UInt32(byteLength))
        )
    }

    var displayName: String {
        switch kind {
        case .number:
            "number"
        case .realNumber:
            "real number"
        case .whitespace:
            "whitespace"
        case .plus:
            "'+'"
        case .minus:
            "'-'"
        case .star:
            "'*'"
        case .slash:
            "'/'"
        case .leftParen:
            "'('"
        case .rightParen:
            "')'"
        case .round:
            "'round'"
        case .invalid:
            "invalid token"
        case .eof:
            "end of input"
        }
    }
}

struct CalculatorLexer {
    var input: String

    func tokenize() -> [LexedToken] {
        var tokens: [LexedToken] = []
        var index = input.startIndex
        var byteOffset = 0

        while index < input.endIndex {
            let character = input[index]
            let start = index
            let startOffset = byteOffset

            if character.isCalculatorDigit {
                repeat {
                    input.formIndex(after: &index)
                } while index < input.endIndex && input[index].isCalculatorDigit

                var kind = LexedTokenKind.number
                if index < input.endIndex,
                   input[index].asciiValue == 0x2e
                {
                    let dotIndex = index
                    var afterDot = dotIndex
                    input.formIndex(after: &afterDot)
                    if afterDot < input.endIndex && input[afterDot].isCalculatorDigit {
                        index = afterDot
                        repeat {
                            input.formIndex(after: &index)
                        } while index < input.endIndex && input[index].isCalculatorDigit
                        kind = .realNumber
                    }
                }

                let text = String(input[start..<index])
                tokens.append(token(kind, text: text, offset: startOffset))
                byteOffset += text.utf8.count
                continue
            }

            if character.isCalculatorWhitespace {
                repeat {
                    input.formIndex(after: &index)
                } while index < input.endIndex && input[index].isCalculatorWhitespace

                let text = String(input[start..<index])
                tokens.append(token(.whitespace, text: text, offset: startOffset))
                byteOffset += text.utf8.count
                continue
            }

            if character.isCalculatorLetter {
                repeat {
                    input.formIndex(after: &index)
                } while index < input.endIndex && input[index].isCalculatorLetter

                let text = String(input[start..<index])
                tokens.append(token(text == "round" ? .round : .invalid, text: text, offset: startOffset))
                byteOffset += text.utf8.count
                continue
            }

            input.formIndex(after: &index)
            let text = String(input[start..<index])
            let kind: LexedTokenKind
            switch character.asciiValue {
            case 0x2b:
                kind = .plus
            case 0x2d:
                kind = .minus
            case 0x2a:
                kind = .star
            case 0x2f:
                kind = .slash
            case 0x28:
                kind = .leftParen
            case 0x29:
                kind = .rightParen
            default:
                kind = .invalid
            }
            tokens.append(token(kind, text: text, offset: startOffset))
            byteOffset += text.utf8.count
        }

        tokens.append(LexedToken(
            kind: .eof,
            text: "",
            byteOffset: byteOffset,
            byteLength: 0
        ))
        return tokens
    }

    private func token(_ kind: LexedTokenKind, text: String, offset: Int) -> LexedToken {
        LexedToken(
            kind: kind,
            text: text,
            byteOffset: offset,
            byteLength: text.utf8.count
        )
    }
}

private extension Character {
    var isCalculatorDigit: Bool {
        asciiValue.map { 0x30...0x39 ~= $0 } ?? false
    }

    /// ASCII space, tab, newline, or carriage return. The Calculator
    /// grammar is ASCII-only; accepting Unicode whitespace here would
    /// mean operators recognized via `Character.asciiValue` and trivia
    /// recognized via `Unicode.Scalar.Properties.isWhitespace` reach
    /// inconsistent conclusions about the same input.
    var isCalculatorWhitespace: Bool {
        guard let value = asciiValue else { return false }
        return value == 0x20 || value == 0x09 || value == 0x0a || value == 0x0d
    }

    var isCalculatorLetter: Bool {
        asciiValue.map { (0x41...0x5a ~= $0) || (0x61...0x7a ~= $0) } ?? false
    }
}
