import CambiumCore

public protocol TypedSyntaxNode {
    associatedtype Lang: SyntaxLanguage

    static var rawKind: RawSyntaxKind { get }
}

public struct TypedNodeHandle<Spec: TypedSyntaxNode>: Sendable, Hashable {
    public let syntax: SyntaxNodeHandle<Spec.Lang>

    public init?(_ syntax: SyntaxNodeHandle<Spec.Lang>) {
        guard syntax.rawKind == Spec.rawKind else {
            return nil
        }
        self.syntax = syntax
    }

    public func withCursor<R>(
        _ body: (borrowing SyntaxNodeCursor<Spec.Lang>) throws -> R
    ) rethrows -> R {
        try syntax.withCursor(body)
    }
}

public extension SyntaxNodeHandle {
    func asTyped<Spec: TypedSyntaxNode>(_ type: Spec.Type) -> TypedNodeHandle<Spec>? where Spec.Lang == Lang {
        TypedNodeHandle<Spec>(self)
    }
}

public extension SyntaxNodeCursor {
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
