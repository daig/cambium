import CambiumCore

public extension SyntaxNodeHandle {
    var childHandles: [SyntaxNodeHandle<Lang>] {
        withCursor { cursor in
            var result: [SyntaxNodeHandle<Lang>] = []
            cursor.forEachChild { child in
                result.append(child.makeHandle())
            }
            return result
        }
    }

    var descendantHandlesPreorder: [SyntaxNodeHandle<Lang>] {
        withCursor { cursor in
            var result: [SyntaxNodeHandle<Lang>] = []
            _ = cursor.visitPreorder { node in
                result.append(node.makeHandle())
                return .continue
            }
            return result
        }
    }

    func tokenHandles(in range: TextRange? = nil) -> [SyntaxTokenHandle<Lang>] {
        withCursor { cursor in
            var result: [SyntaxTokenHandle<Lang>] = []
            cursor.tokens(in: range) { token in
                result.append(token.makeHandle())
            }
            return result
        }
    }
}

public extension SharedSyntaxTree {
    var rootAndDescendantHandlesPreorder: [SyntaxNodeHandle<Lang>] {
        rootHandle().descendantHandlesPreorder
    }
}
