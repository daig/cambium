# Getting Started

Build your first Cambium tree by writing a tiny calculator parser.

## Overview

If you're looking at Cambium, you're probably writing a parser and
considering using concrete syntax trees as its output. We'll walk
through a complete example from defining a language all the way to
walking the resulting tree.

We'll support addition and subtraction on integers, with parentheses
for grouping. The user is allowed to write nested expressions like
`1-(2+5)`.

The full pipeline:

1. Define an enumeration of the kinds of tokens (like keywords) and
   nodes (like "an expression") that you want in your syntax, and
   conform it to ``CambiumCore/SyntaxLanguage``.
2. Create a ``CambiumBuilder/GreenTreeBuilder`` and call ``CambiumBuilder/GreenTreeBuilder/startNode(_:)``,
   ``CambiumBuilder/GreenTreeBuilder/token(_:text:)``, and
   ``CambiumBuilder/GreenTreeBuilder/finishNode()`` from your parser.
3. Call ``CambiumBuilder/GreenTreeBuilder/finish()`` to obtain a ``CambiumBuilder/GreenBuildResult``,
   then call `result.snapshot.makeSyntaxTree()` to get a ``CambiumCore/SyntaxTree``
   you can traverse.

## Defining the language

First, list the different parts of your grammar. We use a `UInt32`-backed
enum and let the `@CambiumSyntaxKind` macro derive every requirement
on ``CambiumCore/SyntaxKind`` for us. Operators and parentheses always render to
the same text, so we mark them with `@StaticText`; integers vary
between occurrences and stay un-annotated.

```swift
import Cambium
import CambiumSyntaxMacros

@CambiumSyntaxKind
enum CalcKind: UInt32, Sendable {
    // Tokens
    case integer = 1
    @StaticText("+") case plus = 2
    @StaticText("-") case minus = 3
    @StaticText("(") case lparen = 4
    @StaticText(")") case rparen = 5
    @StaticText(" ") case whitespace = 6

    // Nodes
    case expr = 100
    case root = 101

    // Sentinels for missing/error recovery
    case missing = 200
    case error = 201
}
```

Next we tie the kind enum to a language type. Most of the
``CambiumCore/SyntaxLanguage`` requirements have default implementations that work
for any ``CambiumCore/SyntaxKind``-conforming enum, so the conformance is short:

```swift
enum Calc: SyntaxLanguage {
    typealias Kind = CalcKind

    static let rootKind: CalcKind = .root
    static let missingKind: CalcKind = .missing
    static let errorKind: CalcKind = .error

    // Stable IDs in case we ever serialize trees.
    static let serializationID = "com.example.calc"
    static let serializationVersion: UInt32 = 1

    // Trivia and node/token classification.
    static func isTrivia(_ kind: CalcKind) -> Bool {
        kind == .whitespace
    }

    static func isNode(_ kind: CalcKind) -> Bool {
        switch kind {
        case .expr, .root, .missing, .error:
            return true
        default:
            return false
        }
    }

    static func isToken(_ kind: CalcKind) -> Bool {
        !isNode(kind)
    }
}
```

That's everything Cambium needs to specialize its generic types for our
language. Override ``CambiumCore/SyntaxLanguage/isNode(_:)`` and
``CambiumCore/SyntaxLanguage/isToken(_:)`` when your language has dynamic-text token
kinds like `integer`; the default classifier treats static-text kinds as
tokens and non-static kinds as nodes.

## Parsing into a green tree

For the purposes of this introduction, assume there is a lexer that
yields the following tokens:

```swift
enum Token: Equatable {
    // Number strings are not yet parsed into actual numbers; we
    // remember the slice of the input that contains their digits.
    case integer(String)
    case plus
    case minus
    case lparen
    case rparen
    case eof
}
```

A simple `Lexer` over a `String` is part of the example flow but we
won't show it inline; whatever lexer you have works fine as long as it
yields `Token`s in source order. To keep the parser short, these
snippets skip whitespace; a production CST parser should append trivia
tokens such as `.whitespace` to keep the tree fully lossless.
Let's wire the lexer up to a parser
that owns a ``CambiumBuilder/GreenTreeBuilder``:

```swift
struct Parser {
    private var lexer: Lexer
    private var builder: GreenTreeBuilder<Calc>

    init(input: String) {
        self.lexer = Lexer(input: input)
        self.builder = GreenTreeBuilder<Calc>()
    }
}
```

In contrast to parsers that return abstract syntax trees, with Cambium
the syntax tree nodes for every element of the language grammar have
the same type: ``CambiumCore/GreenNode`` for the inner ("green") tree and
``CambiumCore/SyntaxNodeCursor`` (with optional ``CambiumCore/SyntaxNodeHandle`` projection)
for the outer ("red") tree. Different kinds of nodes and tokens are
differentiated by their kind tag.

You can implement many types of parsers with Cambium. To get a feel for
how it works, consider a recursive-descent parser. With a more
traditional AST one would define different AST structs for each
syntactic category and have parsing functions return the matching AST
type. Because Cambium's syntax trees are untyped, there is no explicit
AST representation that the parser would build. Instead, parsing into
a CST using the builder follows the source code more closely: you
tell Cambium about each new element you enter and every token the
parser consumes.

The most trivial example is the root parser entry point, which just
opens a root node containing the whole expression and finishes it
again:

```swift
extension Parser {
    mutating func parse() throws {
        builder.startNode(.root)
        try parseExpr()
        try builder.finishNode()
    }
}
```

As there isn't a static AST type to return, the parser is very
flexible as to what is part of a node. If the user is editing a struct
and has not yet typed a field's type, the CST node for the struct
doesn't care that its child slot is empty. Similarly, leftover
identifiers from a half-deleted field can be a part of the struct
node without any modifications to the syntax tree definition. This
property is the key to why CSTs are such a good fit as a lossless
input representation, which necessitates the syntax tree to mirror the
user-specific layout of whitespace and comments around the AST items.

### Speculative wrapping with checkpoints

In our calculator we have to deal with the fact that, when we see a
number, the parser doesn't yet know whether more operations follow.
That is, in the expression `1 + 2`, the parser only knows it's looking
at a binary operation once it sees the `+`. The event-like model of
building trees in Cambium implies that when reaching the `+`, the
parser would already need to have entered a `CalcKind.expr` node
for the whole input to be part of the expression.

To get around this, ``CambiumBuilder/GreenTreeBuilder`` provides
``CambiumBuilder/GreenTreeBuilder/checkpoint()``, which we can call to "remember" the
current builder position. Later, when the parser sees the following
`+`, it can wrap everything since the checkpoint inside an
`CalcKind.expr` node using
``CambiumBuilder/GreenTreeBuilder/startNode(at:_:)``:

```swift
extension Parser {
    mutating func parseLhs() throws {
        switch try lexer.peek() {
        case .integer(let n):
            _ = try lexer.next()
            try builder.token(.integer, text: n)

        case .lparen:
            // Wrap the grouped expression inside a node containing it
            // and its parentheses.
            builder.startNode(.expr)
            _ = try lexer.next()
            try builder.staticToken(.lparen)
            try parseExpr()
            guard case .rparen = try lexer.next() else {
                throw ParseError.missingRParen
            }
            try builder.staticToken(.rparen)
            try builder.finishNode()

        case .eof:
            throw ParseError.unexpectedEOF

        case let other:
            throw ParseError.unexpectedToken(other)
        }
    }

    mutating func parseExpr() throws {
        // Remember our current position.
        let beforeExpr = builder.checkpoint()

        // Parse the start of the expression.
        try parseLhs()

        // Check whether the expression continues with `+ <more>` or
        // `- <more>`.
        let nextToken = try lexer.peek()
        let opKind: CalcKind
        switch nextToken {
        case .plus:  opKind = .plus
        case .minus: opKind = .minus
        case .rparen, .eof: return
        case let other:
            throw ParseError.unexpectedToken(other)
        }

        // If so, retroactively wrap the (already parsed) LHS and the
        // following RHS inside an `expr` node.
        try builder.startNode(at: beforeExpr, .expr)
        _ = try lexer.next()
        try builder.staticToken(opKind)
        try parseExpr() // RHS
        try builder.finishNode()
    }
}
```

### Static-text and dynamic-text tokens

Notice the split between
``CambiumBuilder/GreenTreeBuilder/token(_:text:)``,
``CambiumBuilder/GreenTreeBuilder/staticToken(_:)``, and
``CambiumBuilder/GreenTreeBuilder/missingToken(_:)``:

- ``CambiumBuilder/GreenTreeBuilder/staticToken(_:)`` only works on kinds whose
  ``CambiumCore/SyntaxLanguage/staticText(for:)`` returns non-`nil`. The text comes
  from the language definition; you don't have to repeat it at the
  call site.
- ``CambiumBuilder/GreenTreeBuilder/token(_:text:)`` only works on kinds with
  *no* static text — typically identifiers and literals. The supplied
  string is interned in the builder's ``CambiumBuilder/GreenNodeCache``, so two
  occurrences of the same identifier dedupe to one allocation.
- ``CambiumBuilder/GreenTreeBuilder/missingToken(_:)`` records a parser-recovered
  placeholder. It always renders to nothing.
- ``CambiumBuilder/GreenTreeBuilder/largeToken(_:text:)`` is the right choice for
  inherently unique payloads like long string literals, where
  hash-interning would only waste hash work.

Mixing them up — for example, calling `token(.plus, text: "+")` —
throws ``CambiumBuilder/GreenTreeBuilderError/staticKindRequiresStaticToken(_:)`` so
schema mistakes are caught at the call site instead of producing a
silently malformed tree.

## Obtaining the parser result

Our parser can now parse our little arithmetic language, but its
methods don't return anything. Where does the syntax tree come from?
The answer is ``CambiumBuilder/GreenTreeBuilder/finish()``, which finally consumes
the builder and returns a ``CambiumBuilder/GreenBuildResult``:

```swift
extension Parser {
    consuming func finish() throws -> GreenBuildResult<Calc> {
        try builder.finish()
    }
}
```

The result includes the green ``CambiumBuilder/GreenBuildResult/root``, the immutable
``CambiumBuilder/GreenBuildResult/tokenText`` resolver, and the underlying
``CambiumBuilder/GreenNodeCache`` (accessible via
``CambiumBuilder/GreenBuildResult/intoCache()``). The cache is what lets you preserve
structural sharing across reparses — pass it to the next builder via
`GreenTreeBuilder(cache:)` to keep token-key namespace identity
stable.

To work with the syntax tree, materialize a ``CambiumCore/SyntaxTree`` from the
build result's ``CambiumBuilder/GreenBuildResult/snapshot``:

```swift
let input = "11+2-(5+4)"
var parser = Parser(input: input)
try parser.parse()

let result = try parser.finish()
let tree = result.snapshot.makeSyntaxTree()
```

`tree` is a `~Copyable` ``CambiumCore/SyntaxTree``. To traverse it, hand a closure
to ``CambiumCore/SyntaxTree/withRoot(_:)``; the closure receives a borrowed
``CambiumCore/SyntaxNodeCursor`` on the root.

## Traversing the tree

The cursor API mirrors how you'd write a recursive-descent walker, but
without the per-node allocations. Borrow-on-demand instead of
`return [Cursor]`:

```swift
tree.withRoot { root in
    print("root kind: \(Calc.name(for: root.kind))")
    print("root range: \(root.textRange)")

    root.forEachChild { child in
        print(" child: \(Calc.name(for: child.kind)) \(child.textRange)")
    }
}
```

For a depth-first walk over every descendant:

```swift
tree.withRoot { root in
    _ = root.visitPreorder { node in
        // Return .skipChildren or .stop to control descent.
        print("\(Calc.name(for: node.kind)) \(node.textRange)")
        return .continue
    }
}
```

For a token-aware walk (most editor scenarios), use
``CambiumCore/SyntaxNodeCursor/walkPreorderWithTokens(_:)`` or
``CambiumCore/SyntaxNodeCursor/tokens(in:_:)``.

### Reading text without allocating

Materializing source text as `String` is occasionally what you want
(``CambiumCore/SyntaxNodeCursor/makeString()``), but for hot-path scans prefer the
borrowed text view:

```swift
tree.withRoot { root in
    root.withText { text in
        if text.contains(0x2B) { // '+'
            // ...
        }
    }
}
```

``CambiumCore/SyntaxText`` walks the green tree on demand and yields chunks
straight from the resolver's interned bytes — no copies, no
allocations unless you ask for a `String`.

### Promoting to a copyable, Sendable tree

`SyntaxTree` is `~Copyable` so traversal stays unambiguous about
ownership. When you need to publish a tree to SwiftUI, hand it to a
`Task`, or store it in a long-lived snapshot, promote it to a
``CambiumCore/SharedSyntaxTree``:

```swift
let shared = tree.intoShared()

// Sendable across actors, retained until the last reference is gone.
await Task.detached {
    shared.withRoot { root in
        // ... background work
    }
}.value
```

For long-lived references to *specific nodes*, use
``CambiumCore/SharedSyntaxTree/rootHandle()`` and
``CambiumCore/SyntaxNodeCursor/makeHandle()`` to obtain copyable
``CambiumCore/SyntaxNodeHandle`` values that you can store in dictionaries,
attach diagnostics to, or send across actors.

## Editing a tree

Trees are persistent. To "edit" one, call
`SharedSyntaxTree.replacing(_:with:cache:)` with the handle of the
node to replace and a ``CambiumCore/ResolvedGreenNode`` (or ``CambiumBuilder/GreenTreeSnapshot``,
or ``CambiumBuilder/GreenBuildResult``) of the replacement. The result is a
``CambiumCore/ReplacementResult`` with the new tree and a ``CambiumCore/ReplacementWitness``
describing the structural change:

```swift
let original = tree.intoShared()

// Build a replacement subtree.
var rebuilder = GreenTreeBuilder<Calc>(cache: result.intoCache())
rebuilder.startNode(.expr)
try rebuilder.token(.integer, text: "42")
try rebuilder.finishNode()
let replacement = try rebuilder.finish()
let replacementSnapshot = replacement.snapshot

// Decide which node to replace — for example, the root's first child.
let target: SyntaxNodeHandle<Calc> = original.withRoot { root in
    root.withFirstChild { $0.makeHandle() }!
}

var cache = replacement.intoCache()
let edit = try original.replacing(target, with: replacementSnapshot, cache: &cache)
let witness = edit.witness
let next = edit.intoTree()
```

Inspect `witness` to translate any v0 references (handles you
held before the edit) into v1: `witness.classify(path:)` returns a
``CambiumCore/ReplacementOutcome`` telling you whether the path is unchanged, an
ancestor of the edit, the replaced node itself, or a descendant of
the deleted region.

## Incremental parsing

For an editor that reparses on every keystroke, you don't want to
discard the entire tree each time. The CambiumIncremental module
provides:

- ``CambiumIncremental/ParseInput`` — the bundle of `(textUTF8, edits, previousTree)` your
  parser receives for each parse pass.
- ``CambiumIncremental/IncrementalParseSession`` — long-lived state that aggregates
  reuse counters and an accepted-reuse log across parses.
- ``CambiumIncremental/ReuseOracle`` — the parser-facing interface that offers candidate
  subtrees from the previous tree at given offsets.
- ``CambiumIncremental/ParseWitness`` — the post-parse summary: which subtrees were
  carried over by reference, which regions were freshly parsed.

A typical reparse loop:

```swift
let session = IncrementalParseSession<Calc>()
var sharedTree: SharedSyntaxTree<Calc>? = nil

// On each edit:
let input = ParseInput<Calc>(text: newText, edits: edits, previousTree: sharedTree)
let oracle = session.makeReuseOracle(for: input)

// Inside your parser, before parsing a node of kind .expr at an old-tree
// offset that survived edit invalidation:
let accepted = try oracle.withReusableNode(startingAt: oldExprStart, kind: .expr) { reusable in
    // Capture the witness data before the borrowed cursor leaves scope.
    let oldPath = reusable.childIndexPath()
    let green = reusable.green { $0 }

    // Splice the reused subtree into the new tree without re-parsing it.
    try builder.reuseSubtree(reusable)

    // The parser/integrator owns new-path bookkeeping because it knows
    // where this node is being appended in the output tree.
    return Reuse(green: green, oldPath: oldPath, newPath: newExprPath)
}

if let accepted {
    session.recordAcceptedReuse(
        oldPath: accepted.oldPath,
        newPath: accepted.newPath,
        green: accepted.green
    )
}

let result = try builder.finish()
sharedTree = result.snapshot.makeSyntaxTree().intoShared()

let witness = ParseWitness(
    oldRoot: input.previousTree?.rootGreen,
    newRoot: result.root,
    reusedSubtrees: session.consumeAcceptedReuses()
)
```

The witness is the right anchor for higher-layer identity tracking:
diagnostics, selections, fold state, anything attached to nodes by
identity. Cambium does not maintain those mappings itself — it
provides the structural primitive and lets you compose the policy
appropriate for your editor.

## AST Layer

While Cambium is built for concrete syntax trees, applications often
want to work with either a CST or an AST representation, or freely
switch between them. The CambiumASTSupport module gives you the
minimal vocabulary to do this: define one ``CambiumASTSupport/TypedSyntaxNode``-conforming
type per AST kind, then use ``CambiumCore/SyntaxNodeHandle/asTyped(_:)`` and
``CambiumCore/SyntaxNodeCursor/withTyped(_:_:)`` to safely down-cast generic
nodes.

```swift
enum ExprNode: TypedSyntaxNode {
    typealias Lang = Calc
    static let rawKind = Calc.rawKind(for: .expr)
}

if let exprHandle = nodeHandle.asTyped(ExprNode.self) {
    exprHandle.withCursor { exprCursor in
        // ... statically known to be an expr
    }
}
```

A grammar-specific layer (likely generated by tooling) is the right
place to define one spec type per kind, with kind-specific accessors
built on top. Cambium does not ship grammar generators in core — the
``CambiumASTSupport/TypedSyntaxNode`` protocol is the contract that an AST overlay
should target.

## License

Cambium is distributed under the same dual MIT / Apache-2.0 license as
the upstream `cstree` it draws inspiration from.
