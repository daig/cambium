# ``Cambium``

A Swift-native concrete syntax tree library inspired by Rust's
[`cstree`](https://github.com/domenicquirl/cstree).

## Overview

Cambium is a generic library for creating and working with **concrete
syntax trees** (CSTs).

"Traditional" abstract syntax trees (ASTs) usually contain different
types of nodes which represent different syntactical elements of the
source text of a document and reduce its information to the minimal
amount necessary to correctly interpret it. In contrast, CSTs are
**lossless** representations of the entire input where all tree nodes
are represented homogeneously (the nodes are *untyped*) but tagged
with a ``CambiumCore/RawSyntaxKind`` to determine the kind of grammatical element
they represent.

One big advantage of this representation is that it can recreate the
original source exactly while also lending itself very well to the
representation of *incomplete or erroneous* trees and is thus highly
suited for usage in contexts such as IDEs or any other application
where a user is *editing* the source text.

The concept and the data structures for Cambium's syntax trees are
inspired in part by Swift's
[libsyntax](https://github.com/apple/swift/tree/5e2c815edfd758f9b1309ce07bfc01c4bc20ec23/lib/Syntax)
and by the Rust [`cstree`](https://github.com/domenicquirl/cstree)
library, which itself is a fork of
[`rowan`](https://github.com/rust-analyzer/rowan/) developed by the
authors of [rust-analyzer](https://github.com/rust-analyzer/rust-analyzer/).

### Two-layer storage

Trees consist of two layers:

- The inner **green tree** contains the actual source text as
  position-independent green nodes. Tokens and nodes that appear
  identically at multiple places in the source are deduplicated in
  this representation in order to store the tree efficiently. This
  means that a green tree may structurally be a DAG rather than a
  unique object per source position.

- To remedy this, the real syntax tree is constructed on top of the
  green tree as a secondary tree (called the **red tree**) which
  models the exact source structure.

As a possible third layer, a strongly typed AST can be built on top of
the red tree (see <doc:GettingStarted#AST-Layer>).

### Notable differences from `cstree`

Cambium tracks `cstree`'s practical guarantees but uses modern Swift
language features rather than imitating Rust mechanically:

- **Borrowed cursors are the primary traversal API.** Walking a tree
  uses `~Copyable` ``CambiumCore/SyntaxNodeCursor``s borrowed inside a closure
  scope. There are no per-node retains during traversal, no implicit
  array allocation for child iteration, and no surprise copies of
  red node references. Copyable ``CambiumCore/SyntaxNodeHandle``s exist for
  long-lived references but are an explicit opt-in.

- **Move-only builders, caches, and trees.** ``CambiumBuilder/GreenTreeBuilder``,
  ``CambiumBuilder/GreenNodeCache``, ``CambiumBuilder/GreenBuildResult``, and ``CambiumCore/SyntaxTree`` are all
  `~Copyable`. Ownership boundaries are visible in the type system;
  you cannot accidentally clone a builder or duplicate a parse cache.

- **Synchronous traversal, `Sendable` snapshots.** Tree navigation
  never goes through an actor. Once a tree is built it can be
  promoted to a `Sendable` ``CambiumCore/SharedSyntaxTree`` with
  ``CambiumCore/SyntaxTree/intoShared()`` and freely shared across actors and
  tasks.

- **Witness-based change tracking.** Editing a tree returns a
  ``CambiumCore/ReplacementWitness`` describing the structural change; an
  incremental reparse returns a ``CambiumIncremental/ParseWitness`` listing the subtrees
  that were carried over by reference. Cambium does not bake an
  identity-tracker into the core; consumers translate identities
  through witness chains.

- **No mutation in place.** Trees are persistent. Editing produces a
  new tree that shares as much green storage with the old as
  possible.

- **Strict serialization.** Snapshots written by
  ``CambiumCore/SharedSyntaxTree/serializeGreenSnapshot()`` and read by
  ``CambiumSerialization/GreenSnapshotDecoder`` are length-, hash-, and kind-validated at
  every record. Bad snapshots are rejected with named errors.

### Modules

Cambium is split into several focused modules. Importing the umbrella
`Cambium` module re-exports the runtime modules; test support and macros
are imported explicitly when you need them. You can also pick individual
modules directly.

- **CambiumCore** — The foundational layer: ``CambiumCore/RawSyntaxKind``,
  ``CambiumCore/SyntaxLanguage``, ``CambiumCore/TextSize``, ``CambiumCore/GreenNode``, ``CambiumCore/GreenToken``,
  ``CambiumCore/SyntaxTree``, ``CambiumCore/SyntaxNodeCursor``, ``CambiumCore/ReplacementWitness``.
- **CambiumBuilder** — ``CambiumBuilder/GreenTreeBuilder``, ``CambiumBuilder/GreenTreeContext``,
  ``CambiumBuilder/GreenNodeCache``, ``CambiumBuilder/LocalTokenInterner``,
  ``CambiumBuilder/SharedTokenInterner``, `SharedSyntaxTree.replacing(_:with:context:)`.
- **CambiumIncremental** — ``CambiumIncremental/ParseInput``, ``CambiumIncremental/IncrementalParseSession``,
  ``CambiumIncremental/ReuseOracle``, ``CambiumIncremental/ParseWitness``.
- **CambiumAnalysis** — ``CambiumAnalysis/Diagnostic``, ``CambiumAnalysis/SyntaxMetadataStore``,
  ``CambiumAnalysis/ExternalAnalysisCache``.
- **CambiumASTSupport** — ``CambiumASTSupport/TypedSyntaxNode``, ``CambiumASTSupport/TypedNodeHandle``.
- **CambiumOwnedTraversal** — Allocating helpers for handle-based
  traversal: `SyntaxNodeHandle.childHandles`,
  `SyntaxNodeHandle.descendantHandlesPreorder`.
- **CambiumSerialization** — ``CambiumSerialization/GreenSnapshotDecoder``,
  `serializeGreenSnapshot()` extensions.
- **CambiumTesting** — Test-support helpers: `assertRoundTrip(_:equals:)`,
  `assertTextLength(_:equals:)`, `debugTree(_:)`.
- **CambiumSyntaxMacros** — `@CambiumSyntaxKind` and `@StaticText`
  macros for deriving ``CambiumCore/SyntaxKind`` conformance.

## Topics

### Essentials

- <doc:GettingStarted>

### Defining a language

- ``CambiumCore/RawSyntaxKind``
- ``CambiumCore/SyntaxKind``
- ``CambiumCore/SyntaxLanguage``

Languages are typically derived from a `UInt32`-backed enum using the
`@CambiumSyntaxKind` and `@StaticText` macros from
`CambiumSyntaxMacros` (see <doc:GettingStarted>).

### Building a tree

- <doc:ExternalizedInterning>
- ``CambiumBuilder/GreenTreeBuilder``
- ``CambiumBuilder/GreenTreeContext``
- ``CambiumBuilder/GreenNodeCache``
- ``CambiumBuilder/GreenCachePolicy``
- ``CambiumBuilder/BuilderCheckpoint``
- ``CambiumBuilder/GreenBuildResult``
- ``CambiumBuilder/GreenTreeSnapshot``
- ``CambiumCore/TokenInterner``
- ``CambiumBuilder/LocalTokenInterner``
- ``CambiumBuilder/SharedTokenInterner``

### Green storage

- ``CambiumCore/GreenNode``
- ``CambiumCore/GreenToken``
- ``CambiumCore/GreenElement``
- ``CambiumCore/ResolvedGreenNode``
- ``CambiumCore/TokenKey``
- ``CambiumCore/LargeTokenTextID``
- ``CambiumCore/TokenKeyNamespace``
- ``CambiumCore/TokenTextStorage``
- ``CambiumCore/TokenResolver``
- ``CambiumCore/TokenTextSnapshot``

### Position and ranges

- ``CambiumCore/TextSize``
- ``CambiumCore/TextRange``
- ``CambiumCore/TextSizeError``

### Working with a tree

- ``CambiumCore/SyntaxTree``
- ``CambiumCore/SharedSyntaxTree``
- ``CambiumCore/SyntaxTreeStorage``
- ``CambiumCore/TreeID``
- ``CambiumCore/RedNodeID``
- ``CambiumCore/SyntaxNodeIdentity``
- ``CambiumCore/SyntaxTokenIdentity``

### Borrowed traversal

- ``CambiumCore/SyntaxNodeCursor``
- ``CambiumCore/SyntaxTokenCursor``
- ``CambiumCore/SyntaxElementCursor``
- ``CambiumCore/TraversalControl``
- ``CambiumCore/TraversalDirection``
- ``CambiumCore/SyntaxNodeWalkEvent``
- ``CambiumCore/SyntaxElementWalkEvent``

### Long-lived references

- ``CambiumCore/SyntaxNodeHandle``
- ``CambiumCore/SyntaxTokenHandle``
- ``CambiumCore/GreenNodeIdentity``
- ``CambiumCore/SyntaxNodePath``
- ``CambiumASTSupport/TypedSyntaxNode``
- ``CambiumASTSupport/TypedNodeHandle``

### Reading text

- ``CambiumCore/SyntaxText``
- ``CambiumCore/UTF8Sink``
- ``CambiumCore/StringUTF8Sink``

### Editing

- ``CambiumCore/ReplacementWitness``
- ``CambiumCore/ReplacementOutcome``
- ``CambiumCore/ReplacementResult``
- ``CambiumBuilder/SubtreeReuseOutcome``

### Incremental parsing

- ``CambiumIncremental/ParseInput``
- ``CambiumIncremental/TextEdit``
- ``CambiumIncremental/RangeMappingResult``
- ``CambiumIncremental/mapRange(_:through:)``
- ``CambiumIncremental/IncrementalParseSession``
- ``CambiumIncremental/IncrementalParseCounters``
- ``CambiumIncremental/ReuseOracle``
- ``CambiumIncremental/ParseWitness``
- ``CambiumIncremental/Reuse``

### Analysis

- ``CambiumAnalysis/Diagnostic``
- ``CambiumAnalysis/DiagnosticSeverity``
- ``CambiumAnalysis/SyntaxDataKey``
- ``CambiumAnalysis/SyntaxMetadataStore``
- ``CambiumAnalysis/AnalysisCacheKey``
- ``CambiumAnalysis/ExternalAnalysisCache``

### Serialization

- ``CambiumSerialization/GreenSnapshotDecoder``
- ``CambiumSerialization/CambiumSerializationError``

### Errors

- ``CambiumCore/GreenStorageError``
- ``CambiumCore/GreenTokenError``
- ``CambiumBuilder/GreenTreeBuilderError``
- ``CambiumCore/TokenTextError``
