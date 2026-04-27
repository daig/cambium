import CambiumCore

/// A type-level binding from a Swift type to one `RawSyntaxKind` in a
/// language.
///
/// Conform a "spec" type to `TypedSyntaxNode` to attach a static raw kind
/// to a Swift type. ``CambiumASTSupport/TypedNodeHandle`` and the
/// `SyntaxNodeCursor.withTyped(_:_:)` extension then use that binding
/// to safely down-cast a generic node handle to a kind-restricted view.
///
/// ```swift
/// enum Calc: SyntaxLanguage { /* ... */ }
///
/// enum CallExprNode: TypedSyntaxNode {
///     typealias Lang = Calc
///     static let rawKind = Calc.rawKind(for: .callExpr)
/// }
///
/// if let call = handle.asTyped(CallExprNode.self) {
///     call.withCursor { cursor in
///         // ... node is statically known to be a `callExpr`
///     }
/// }
/// ```
///
/// `TypedSyntaxNode` is intentionally minimal — Cambium is a CST library,
/// not a typed-AST framework. A grammar-specific layer (likely generated
/// by tooling) is the right place to define one spec type per kind, with
/// kind-specific accessors built on top.
public protocol TypedSyntaxNode {
    /// The language this typed node belongs to.
    associatedtype Lang: SyntaxLanguage

    /// The raw kind a node must have to legally be viewed as `Self`.
    static var rawKind: RawSyntaxKind { get }
}

/// A copyable handle restricted to nodes whose raw kind matches
/// `Spec.rawKind`.
///
/// Construct via the failable initializer ``init(_:)`` (or the
/// `SyntaxNodeHandle.asTyped(_:)` extension), which returns `nil`
/// when the handle's kind doesn't match. The wrapped ``syntax`` handle
/// behaves exactly like a regular `SyntaxNodeHandle` — the typed
/// wrapper exists purely to communicate the kind invariant in the
/// type system.
public struct TypedNodeHandle<Spec: TypedSyntaxNode>: Sendable, Hashable {
    /// The underlying generic handle.
    public let syntax: SyntaxNodeHandle<Spec.Lang>

    /// Construct a typed handle from a generic one. Returns `nil` when
    /// `syntax`'s kind does not match `Spec.rawKind`.
    public init?(_ syntax: SyntaxNodeHandle<Spec.Lang>) {
        guard syntax.rawKind == Spec.rawKind else {
            return nil
        }
        self.syntax = syntax
    }

    /// Run `body` with a borrowed cursor on the referenced node.
    public func withCursor<R>(
        _ body: (borrowing SyntaxNodeCursor<Spec.Lang>) throws -> R
    ) rethrows -> R {
        try syntax.withCursor(body)
    }
}

public extension SyntaxNodeHandle {
    /// Down-cast this handle to a ``CambiumASTSupport/TypedNodeHandle`` for `Spec`. Returns
    /// `nil` when the handle's kind doesn't match.
    func asTyped<Spec: TypedSyntaxNode>(_ type: Spec.Type) -> TypedNodeHandle<Spec>? where Spec.Lang == Lang {
        TypedNodeHandle<Spec>(self)
    }
}

public extension SyntaxNodeCursor {
    /// Run `body` with this cursor only when its kind matches
    /// `Spec.rawKind`. Returns `nil` (and does not call `body`) for
    /// non-matching kinds.
    ///
    /// A common shape for typed visitors:
    ///
    /// ```swift
    /// _ = root.visitPreorder { node in
    ///     _ = node.withTyped(CallExprNode.self) { call in
    ///         // ... handle calls
    ///     }
    ///     return .continue
    /// }
    /// ```
    borrowing func withTyped<Spec: TypedSyntaxNode, R>(
        _ type: Spec.Type,
        _ body: (borrowing SyntaxNodeCursor<Lang>) throws -> R
    ) rethrows -> R? where Spec.Lang == Lang {
        guard rawKind == Spec.rawKind else {
            return nil
        }
        return try body(self)
    }
}
