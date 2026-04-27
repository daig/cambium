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

public protocol SyntaxKind: RawRepresentable, Hashable, Sendable where RawValue == UInt32 {
    static func rawKind(for kind: Self) -> RawSyntaxKind
    static func kind(for raw: RawSyntaxKind) -> Self
    static func staticText(for kind: Self) -> StaticString?
    static func name(for kind: Self) -> String
}

public protocol SyntaxLanguage: Sendable {
    associatedtype Kind: RawRepresentable & Hashable & Sendable where Kind.RawValue == UInt32

    static var rootKind: Kind { get }
    static var missingKind: Kind { get }
    static var errorKind: Kind { get }

    static func rawKind(for kind: Kind) -> RawSyntaxKind
    static func kind(for raw: RawSyntaxKind) -> Kind

    /// Whether `raw` is a kind this language recognises. Used at decode
    /// boundaries to reject snapshots that carry unknown kinds (truncated
    /// input, version skew, hostile data) before they enter the rest of
    /// the pipeline. The default implementation answers via
    /// `Kind(rawValue: raw.rawValue) != nil`.
    static func isKnown(_ raw: RawSyntaxKind) -> Bool

    static func staticText(for kind: Kind) -> StaticString?
    static func isTrivia(_ kind: Kind) -> Bool
    static func isNode(_ kind: Kind) -> Bool
    static func isToken(_ kind: Kind) -> Bool
    static func name(for kind: Kind) -> String

    static var serializationID: String { get }
    static var serializationVersion: UInt32 { get }
}

public extension SyntaxLanguage {
    static var serializationID: String {
        String(reflecting: Self.self)
    }

    static var serializationVersion: UInt32 {
        1
    }

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

    static func isKnown(_ raw: RawSyntaxKind) -> Bool {
        Kind(rawValue: raw.rawValue) != nil
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

public extension SyntaxLanguage where Kind: SyntaxKind {
    static func rawKind(for kind: Kind) -> RawSyntaxKind {
        Kind.rawKind(for: kind)
    }

    static func kind(for raw: RawSyntaxKind) -> Kind {
        Kind.kind(for: raw)
    }

    static func staticText(for kind: Kind) -> StaticString? {
        Kind.staticText(for: kind)
    }

    static func name(for kind: Kind) -> String {
        Kind.name(for: kind)
    }
}
