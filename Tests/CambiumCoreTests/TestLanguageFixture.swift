import CambiumCore

enum TestKind: UInt32, Sendable {
    case root = 1
    case list = 2
    case identifier = 3
    case plus = 4
    case whitespace = 5
    case missing = 6
    case error = 7
}

enum TestLanguage: SyntaxLanguage {
    typealias Kind = TestKind

    static let rootKind: TestKind = .root
    static let missingKind: TestKind = .missing
    static let errorKind: TestKind = .error
    static let serializationID = "org.cambium.tests.test-language"
    static let serializationVersion: UInt32 = 1

    static func rawKind(for kind: TestKind) -> RawSyntaxKind {
        RawSyntaxKind(kind.rawValue)
    }

    static func kind(for raw: RawSyntaxKind) -> TestKind {
        TestKind(rawValue: raw.rawValue) ?? .error
    }

    static func staticText(for kind: TestKind) -> StaticString? {
        switch kind {
        case .plus:
            "+"
        case .whitespace:
            " "
        default:
            nil
        }
    }

    static func isTrivia(_ kind: TestKind) -> Bool {
        kind == .whitespace
    }

    static func isNode(_ kind: TestKind) -> Bool {
        kind == .root || kind == .list || kind == .error || kind == .missing
    }

    static func isToken(_ kind: TestKind) -> Bool {
        !isNode(kind)
    }

    static func name(for kind: TestKind) -> String {
        "\(kind)"
    }
}
