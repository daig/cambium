import CambiumBuilder
import CambiumSyntaxMacros
import Testing

@CambiumSyntaxKind
private enum MacroKind: UInt32, Sendable {
    case root = 1
    case list = 2
    case identifier = 3
    @StaticText("+")
    case plus = 4
    @StaticText(" ")
    case whitespace = 5
    case missing = 6
    case error = 7
}

private enum MacroLanguage: SyntaxLanguage {
    typealias Kind = MacroKind

    static let rootKind: MacroKind = .root
    static let missingKind: MacroKind = .missing
    static let errorKind: MacroKind = .error
    static let serializationID = "org.cambium.tests.macro-language"
    static let serializationVersion: UInt32 = 1

    static func isTrivia(_ kind: MacroKind) -> Bool {
        kind == .whitespace
    }

    static func isNode(_ kind: MacroKind) -> Bool {
        kind == .root || kind == .list || kind == .error || kind == .missing
    }

    static func isToken(_ kind: MacroKind) -> Bool {
        !isNode(kind)
    }
}

@Test func syntaxKindMacroDerivesEnumBoilerplate() {
    #expect(MacroKind.rawKind(for: .identifier) == RawSyntaxKind(3))
    #expect(MacroKind.kind(for: RawSyntaxKind(4)) == .plus)
    #expect(string(for: MacroKind.staticText(for: .plus)) == "+")
    #expect(MacroKind.staticText(for: .identifier) == nil)
    #expect(MacroKind.name(for: .whitespace) == "whitespace")
}

@Test func syntaxLanguageUsesSyntaxKindDefaults() {
    #expect(MacroLanguage.rawKind(for: .plus) == RawSyntaxKind(4))
    #expect(MacroLanguage.kind(for: RawSyntaxKind(3)) == .identifier)
    #expect(string(for: MacroLanguage.staticText(for: .whitespace)) == " ")
    #expect(MacroLanguage.name(for: .identifier) == "identifier")
    #expect(MacroLanguage.isTrivia(.whitespace))
    #expect(MacroLanguage.isToken(.plus))
}

@Test func macroDerivedKindsBuildStaticAndDynamicTokenText() throws {
    var builder = GreenTreeBuilder<MacroLanguage>()
    builder.startNode(.root)
    try builder.token(.identifier, text: "left")
    try builder.staticToken(.whitespace)
    try builder.staticToken(.plus)
    try builder.staticToken(.whitespace)
    try builder.token(.identifier, text: "right")
    try builder.finishNode()

    let result = try builder.finish()
    let tree = result.snapshot.makeSyntaxTree()
    let text = tree.withRoot { root in
        root.makeString()
    }

    #expect(text == "left + right")
}

private func string(for text: StaticString?) -> String? {
    text?.withUTF8Buffer { bytes in
        String(decoding: bytes, as: UTF8.self)
    }
}
