@_exported import CambiumCore

/// Derive a `SyntaxKind` conformance from a `UInt32`-backed enum.
///
/// Apply `@CambiumSyntaxKind` to an enum whose raw type is `UInt32` and
/// whose every case has an explicit raw value. The macro generates an
/// extension conforming to `SyntaxKind` with implementations of:
///
/// - `rawKind(for:)` — wraps `kind.rawValue` into a `RawSyntaxKind`.
/// - `kind(for:)` — looks up `Self(rawValue:)` and traps on unknown values.
/// - `staticText(for:)` — switches over cases annotated with
///   `@StaticText` and returns `nil` otherwise.
/// - `name(for:)` — returns each case's Swift name as a `String`.
///
/// ## Example
///
/// ```swift
/// @CambiumSyntaxKind
/// enum CalcKind: UInt32, Sendable {
///     case root = 1
///     case expr = 2
///     case integer = 3
///     @StaticText("+") case plus = 4
///     @StaticText("-") case minus = 5
///     @StaticText("(") case lparen = 6
///     @StaticText(")") case rparen = 7
/// }
/// ```
///
/// ## Diagnostics
///
/// The macro emits errors on:
/// - Non-enum targets.
/// - Enums whose raw type is not `UInt32` / `Swift.UInt32`.
/// - Cases with associated values.
/// - Cases without explicit raw values, or with non-literal raw values.
/// - Duplicate raw values.
/// - Invalid `@StaticText` annotations.
///
/// All errors prevent extension generation, so the macro is a hard wall
/// against schema mistakes.
@attached(extension, conformances: SyntaxKind, names: named(rawKind), named(kind), named(staticText), named(name))
public macro CambiumSyntaxKind() =
    #externalMacro(module: "CambiumSyntaxMacrosPlugin", type: "CambiumSyntaxKindMacro")

/// Annotate an enum case with the static text its kind always renders to.
///
/// `@StaticText` is a peer macro recognized by `@CambiumSyntaxKind`;
/// it is purely declarative and produces no peer declarations of its
/// own. `@CambiumSyntaxKind`'s generated `staticText(for:)` switches on
/// every `@StaticText`-annotated case.
///
/// ## Example
///
/// ```swift
/// @StaticText("+") case plus = 4
/// @StaticText("(") case lparen = 6
/// ```
///
/// Using `@StaticText` outside an enum case, or with anything other
/// than a single string literal argument, produces a compiler error.
@attached(peer)
public macro StaticText(_ text: StaticString) =
    #externalMacro(module: "CambiumSyntaxMacrosPlugin", type: "StaticTextMacro")
