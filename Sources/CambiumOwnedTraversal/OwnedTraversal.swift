import CambiumCore

/// Allocating, owned-handle convenience APIs over the borrowed cursor
/// primitives in CambiumCore.
///
/// CambiumCore's traversal API is borrowed and cursor-based on purpose:
/// it lets parsers and analyzers walk a tree without ARC traffic or
/// `Array` allocation. But sometimes you really do want a `[Handle]` you
/// can iterate from, store, or pass across actor boundaries — for SwiftUI
/// `ForEach` over child nodes, for capturing a snapshot of every token
/// in a range, for a quick test assertion. CambiumOwnedTraversal exposes
/// those convenience helpers as extensions on `SyntaxNodeHandle` and
/// `SharedSyntaxTree`.
///
/// Every helper here allocates an `Array`. That cost is fine for the
/// use cases above; for hot-path traversal stay on the borrowed cursor
/// API.

public extension SyntaxNodeHandle {
    /// Allocate and return a copyable handle for every direct node child.
    /// Skips token children. Suitable for SwiftUI `ForEach` over a
    /// node's children.
    var childHandles: [SyntaxNodeHandle<Lang>] {
        withCursor { cursor in
            var result: [SyntaxNodeHandle<Lang>] = []
            cursor.forEachChild { child in
                result.append(child.makeHandle())
            }
            return result
        }
    }

    /// Allocate and return a copyable handle for every descendant node in
    /// depth-first preorder, excluding `self`.
    var descendantHandlesPreorder: [SyntaxNodeHandle<Lang>] {
        withCursor { cursor in
            var result: [SyntaxNodeHandle<Lang>] = []
            cursor.forEachDescendant { node in
                result.append(node.makeHandle())
            }
            return result
        }
    }

    /// Allocate and return a copyable handle for every token in this
    /// subtree whose range overlaps `range` (or every token, when
    /// `range == nil`).
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
    /// Allocate and return a copyable handle for the root and every
    /// descendant node in depth-first preorder.
    var rootAndDescendantHandlesPreorder: [SyntaxNodeHandle<Lang>] {
        let root = rootHandle()
        return [root] + root.descendantHandlesPreorder
    }
}
