/// The language-agnostic representation of a node or token kind in a
/// Cambium tree.
///
/// Cambium's green storage tags every element with a `RawSyntaxKind` rather
/// than with a strongly typed enum case. This keeps tree storage homogeneous
/// (one struct shape for every kind of grammatical element) while still
/// letting language authors layer typed enums on top via ``CambiumCore/SyntaxKind`` and
/// ``CambiumCore/SyntaxLanguage``. The two-layer split mirrors Rust `cstree` — the
/// kernel only ever sees a 32-bit integer; the language-specific enum
/// vocabulary lives in the conforming ``CambiumCore/SyntaxLanguage``.
///
/// Use cases for working directly in `RawSyntaxKind`:
/// - Writing language-agnostic tooling (debuggers, tree printers, generic
///   visitors) that doesn't need to know which language it's traversing.
/// - Implementing ``SyntaxLanguage/rawKind(for:)`` and
///   ``SyntaxLanguage/kind(for:)``.
/// - Comparing kinds at hot-path boundaries where unwrapping back through
///   the language enum would add overhead.
///
/// Most application code instead works in `Lang.Kind`, which the language
/// projects from raw kinds via `Lang.kind(for:)`.
///
/// ## Topics
///
/// ### Constructing raw kinds
/// - ``init(rawValue:)``
/// - ``init(_:)``
/// - ``init(integerLiteral:)``
public struct RawSyntaxKind:
    RawRepresentable,
    Sendable,
    Hashable,
    Comparable,
    ExpressibleByIntegerLiteral
{
    /// The 32-bit identifier this kind wraps. Identifiers are language-local;
    /// the same numeric value names different elements in different languages.
    public let rawValue: UInt32

    /// Wrap an existing `UInt32` raw value as a `RawSyntaxKind`.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Wrap an existing `UInt32` raw value as a `RawSyntaxKind`. Equivalent
    /// to ``init(rawValue:)``; provided for the more idiomatic
    /// `RawSyntaxKind(7)` call site.
    public init(_ rawValue: UInt32) {
        self.init(rawValue: rawValue)
    }

    /// Construct a raw kind from an integer literal, allowing
    /// `let plus: RawSyntaxKind = 4`. Useful for fixture and test code.
    public init(integerLiteral value: UInt32) {
        self.init(value)
    }

    public static func < (lhs: RawSyntaxKind, rhs: RawSyntaxKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A typed enum vocabulary that maps to and from ``CambiumCore/RawSyntaxKind`` and
/// optionally carries grammar-determined static text.
///
/// Conform an enum to `SyntaxKind` to give a ``CambiumCore/SyntaxLanguage`` a typed view
/// over its raw kinds. The conforming type is normally a `UInt32`-backed enum
/// whose cases enumerate every node and token kind in the language.
///
/// You almost never need to write the boilerplate by hand. The
/// CambiumSyntaxMacros module ships an attached macro that derives
/// every requirement on this protocol from a `UInt32`-backed enum,
/// paired with a peer macro that records the static text for
/// operator/keyword/punctuation cases. See <doc:GettingStarted> for
/// the calling convention.
///
/// ```swift
/// @CambiumSyntaxKind
/// enum CalcKind: UInt32, Sendable {
///     case root = 1
///     case expr = 2
///     case integer = 3
///     @StaticText("+") case plus = 4
///     @StaticText("-") case minus = 5
/// }
/// ```
///
/// Manual conformances are also straightforward when you cannot use the
/// macro — see ``CambiumCore/SyntaxLanguage`` for an end-to-end manual example.
public protocol SyntaxKind: RawRepresentable, Hashable, Sendable where RawValue == UInt32 {
    /// The ``CambiumCore/RawSyntaxKind`` representation of `kind`. Implementations
    /// typically wrap `kind.rawValue` directly.
    static func rawKind(for kind: Self) -> RawSyntaxKind

    /// The typed `Self` case for `raw`. Implementations should trap on raw
    /// values that fall outside the enum, since green tree decoding rejects
    /// unknown kinds before construction.
    static func kind(for raw: RawSyntaxKind) -> Self

    /// The grammar-determined text for a kind whose spelling is fixed
    /// (operators, keywords, punctuation). Returns `nil` for kinds whose
    /// text varies between source occurrences (identifiers, literals).
    ///
    /// Static-text kinds save space — Cambium does not carry a per-token
    /// text payload for them — and cannot be paired with dynamic-text APIs.
    /// See ``GreenToken/staticToken(kind:)``,
    /// ``GreenToken/internedToken(kind:textLength:key:)``, and the matching
    /// builder methods for the validation rules.
    static func staticText(for kind: Self) -> StaticString?

    /// A short human-readable name for `kind`. Used by the bundled tree
    /// printer in `CambiumTesting.debugTree(_:)` and by diagnostic messages.
    static func name(for kind: Self) -> String
}

/// The language-level descriptor that gives a Cambium tree its meaning.
///
/// `SyntaxLanguage` is the type-level binding that ties a `Lang.Kind`
/// vocabulary, a serialization identity, and a set of element-class
/// predicates to one concrete language. Every Cambium type that touches a
/// tree (``CambiumCore/GreenNode``, ``CambiumCore/GreenToken``, ``CambiumCore/SyntaxTree``, ``CambiumCore/SyntaxNodeCursor``,
/// `GreenTreeBuilder`, …) is generic over a `Lang: SyntaxLanguage`.
///
/// You only need to write a `SyntaxLanguage` once per language. After that,
/// the rest of Cambium specializes to your language automatically.
///
/// ## Conforming
///
/// Most languages declare a private/empty enum and conform it. Pair it with
/// a ``CambiumCore/SyntaxKind``-conforming `Kind` enum (often produced by the
/// CambiumSyntaxMacros macro) to get the `rawKind`/`kind`/`staticText`
/// requirements satisfied by default implementations:
///
/// ```swift
/// @CambiumSyntaxKind
/// enum CalcKind: UInt32, Sendable {
///     case root = 1
///     case expr = 2
///     case integer = 3
///     @StaticText("+") case plus = 4
///     @StaticText("-") case minus = 5
///     case missing = 99
///     case error = 100
/// }
///
/// enum Calc: SyntaxLanguage {
///     typealias Kind = CalcKind
///
///     static let rootKind: CalcKind = .root
///     static let missingKind: CalcKind = .missing
///     static let errorKind: CalcKind = .error
///     static let serializationID = "com.example.calc"
///     static let serializationVersion: UInt32 = 1
/// }
/// ```
///
/// ## Per-kind classification
///
/// Override the `isTrivia(_:)`, `isNode(_:)`, and `isToken(_:)` predicates
/// when your language needs them. The defaults treat any kind with static
/// text as a token, anything else as a node, and nothing as trivia.
///
/// ## Serialization compatibility
///
/// ``CambiumCore/SyntaxLanguage/serializationID`` and ``CambiumCore/SyntaxLanguage/serializationVersion``
/// gate snapshot decoding. Bump the version whenever the meaning of an
/// existing raw kind changes; `GreenSnapshotDecoder` rejects mismatches
/// with `CambiumSerializationError.languageMismatch(expectedID:foundID:expectedVersion:foundVersion:)`.
public protocol SyntaxLanguage: Sendable {
    /// The typed kind vocabulary. Usually a ``CambiumCore/SyntaxKind``-conforming enum,
    /// but can also be ``CambiumCore/RawSyntaxKind`` itself for languages that treat
    /// kinds opaquely.
    associatedtype Kind: RawRepresentable & Hashable & Sendable where Kind.RawValue == UInt32

    /// The conventional kind of the root node in well-formed trees.
    /// Cambium does not enforce that built or decoded trees carry this
    /// kind at the root; parsers and higher-level tooling use it as the
    /// language's root sentinel.
    static var rootKind: Kind { get }

    /// A sentinel kind reserved for "missing" nodes inserted by a parser
    /// during error recovery (for example, an expected expression that
    /// wasn't present in the input).
    static var missingKind: Kind { get }

    /// A sentinel kind reserved for "error" nodes that wrap unrecognized
    /// or malformed input.
    static var errorKind: Kind { get }

    /// The ``CambiumCore/RawSyntaxKind`` form of `kind`. Implementations of the typed
    /// path usually delegate to `Kind.rawKind(for:)`.
    static func rawKind(for kind: Kind) -> RawSyntaxKind

    /// The typed `Kind` for `raw`. The default implementation for
    /// `Kind: SyntaxKind` languages uses `Kind.kind(for:)`.
    static func kind(for raw: RawSyntaxKind) -> Kind

    /// Whether `raw` is a kind this language recognises. Used at decode
    /// boundaries to reject snapshots that carry unknown kinds (truncated
    /// input, version skew, hostile data) before they enter the rest of
    /// the pipeline. The default implementation answers via
    /// `Kind(rawValue: raw.rawValue) != nil`.
    static func isKnown(_ raw: RawSyntaxKind) -> Bool

    /// The grammar-determined text for a static-text kind, or `nil` for
    /// dynamic-text kinds. See ``SyntaxKind/staticText(for:)``.
    static func staticText(for kind: Kind) -> StaticString?

    /// Whether `kind` represents trivia (whitespace, comments). Trivia
    /// classification is purely informational at the core level —
    /// Cambium itself does not skip trivia in any traversal. Higher
    /// layers (formatters, AST overlays) consult this predicate.
    static func isTrivia(_ kind: Kind) -> Bool

    /// Whether `kind` represents a node (interior, child-bearing). The
    /// default implementation is `!isToken(kind)`.
    static func isNode(_ kind: Kind) -> Bool

    /// Whether `kind` represents a token (a leaf with text). The default
    /// implementation classifies any kind with non-`nil` ``staticText(for:)``
    /// as a token; override when you have dynamic-text token kinds.
    static func isToken(_ kind: Kind) -> Bool

    /// A short human-readable name for `kind`. Used by the bundled tree
    /// printer in `CambiumTesting.debugTree(_:)` and by diagnostic messages.
    static func name(for kind: Kind) -> String

    /// The string identity stored in serialized snapshots. Defaults to
    /// `String(reflecting: Self.self)` (the fully qualified type name).
    /// Override when you want a stable ID independent of module renames.
    static var serializationID: String { get }

    /// The major version of the serialized format for this language.
    /// Defaults to `1`. Bump whenever the meaning of an existing raw kind
    /// changes; old snapshots will be rejected at decode time with a clear
    /// mismatch error.
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
