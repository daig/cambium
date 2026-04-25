public struct RawSyntaxKind:
    RawRepresentable,
    Sendable,
    Hashable,
    Comparable,
    ExpressibleByIntegerLiteral
{
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt32) {
        self.init(rawValue: rawValue)
    }

    public init(integerLiteral value: UInt32) {
        self.init(value)
    }

    public static func < (lhs: RawSyntaxKind, rhs: RawSyntaxKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public protocol SyntaxLanguage: Sendable {
    associatedtype Kind: RawRepresentable & Hashable & Sendable where Kind.RawValue == UInt32

    static var rootKind: Kind { get }
    static var missingKind: Kind { get }
    static var errorKind: Kind { get }

    static func rawKind(for kind: Kind) -> RawSyntaxKind
    static func kind(for raw: RawSyntaxKind) -> Kind

    static func staticText(for kind: Kind) -> StaticString?
    static func isTrivia(_ kind: Kind) -> Bool
    static func isNode(_ kind: Kind) -> Bool
    static func isToken(_ kind: Kind) -> Bool
    static func name(for kind: Kind) -> String
}

public extension SyntaxLanguage {
    static func staticText(for kind: Kind) -> StaticString? {
        nil
    }

    static func isTrivia(_ kind: Kind) -> Bool {
        false
    }

    static func isNode(_ kind: Kind) -> Bool {
        !isToken(kind)
    }

    static func isToken(_ kind: Kind) -> Bool {
        staticText(for: kind) != nil
    }

    static func name(for kind: Kind) -> String {
        "kind\(rawKind(for: kind).rawValue)"
    }

    static func name(for raw: RawSyntaxKind) -> String {
        name(for: kind(for: raw))
    }
}

public extension SyntaxLanguage where Kind == RawSyntaxKind {
    static func rawKind(for kind: Kind) -> RawSyntaxKind {
        kind
    }

    static func kind(for raw: RawSyntaxKind) -> Kind {
        raw
    }
}
