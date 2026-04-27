# Cambium

Cambium is a Swift-native concrete syntax tree (CST) library inspired by
Rust's [`cstree`](https://github.com/domenicquirl/cstree).

The main documentation lives in the DocC catalog at
[`Sources/Cambium/Cambium.docc`](Sources/Cambium/Cambium.docc). GitHub can
render the source Markdown, but the intended reading experience is the local
DocC site, where symbol links, topics, and API reference pages are connected.

Start with:

- [Cambium overview](Sources/Cambium/Cambium.docc/Cambium.md)
- [Getting started](Sources/Cambium/Cambium.docc/GettingStarted.md)

## Requirements

- Swift tools 6.3 or newer
- Xcode toolchain with `xcrun docc`
- macOS 15 or newer

The package uses Swift 6 language mode and currently depends on
`swift-syntax` 603.0.0 for syntax-kind macro support.

## Using Cambium

As a SwiftPM dependency:

```swift
dependencies: [
    .package(url: "<this-repository-url>", from: "0.1.0"),
]
```

Then depend on the umbrella product:

```swift
.product(name: "Cambium", package: "cambium")
```

The `Cambium` product re-exports the runtime modules. Import
`CambiumTesting` for test helpers and `CambiumSyntaxMacros` when using the
`@CambiumSyntaxKind` and `@StaticText` macros.

## Build And Test

```sh
swift build
swift test
```

## Read The DocC Documentation

First generate public symbol graphs. DocC needs these to connect the article
pages to the API reference:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/cambium-clang-cache \
swift package dump-symbol-graph --minimum-access-level public
```

Then start the live DocC preview server:

```sh
xcrun docc preview Sources/Cambium/Cambium.docc \
  --fallback-display-name Cambium \
  --fallback-bundle-identifier org.cambium.Cambium \
  --fallback-bundle-version 0.1.0 \
  --additional-symbol-graph-dir .build/arm64-apple-macosx/symbolgraph \
  --port 8080
```

Open:

```text
http://localhost:8080/documentation/cambium
```

Rerun `swift package dump-symbol-graph` after changing public APIs or source
documentation comments. For edits only inside `Sources/Cambium/Cambium.docc`,
the preview server watches and rebuilds automatically.

## Build A Static DocC Archive

For release checks or static hosting, build the DocC output directly:

```sh
mkdir -p .build/docs

xcrun docc convert Sources/Cambium/Cambium.docc \
  --fallback-display-name Cambium \
  --fallback-bundle-identifier org.cambium.Cambium \
  --fallback-bundle-version 0.1.0 \
  --additional-symbol-graph-dir .build/arm64-apple-macosx/symbolgraph \
  --output-path .build/docs/Cambium.doccarchive \
  --warnings-as-errors
```

To read that static output locally:

```sh
python3 -m http.server 8081 --directory .build/docs/Cambium.doccarchive
```

Then open:

```text
http://localhost:8081/documentation/cambium
```

## Module Layout

- `CambiumCore`: raw kinds, language contracts, green/red tree storage,
  borrowed cursors, handles, text, and replacement witnesses.
- `CambiumBuilder`: green tree builder, caches, token interners, and editing
  integration.
- `CambiumIncremental`: edit mapping, reuse oracle, parse sessions, and parse
  witnesses.
- `CambiumAnalysis`: diagnostics and metadata/cache helpers.
- `CambiumASTSupport`: typed node overlays on top of homogeneous CST nodes.
- `CambiumOwnedTraversal`: allocating convenience helpers for handles.
- `CambiumSerialization`: strict green snapshot encoding and decoding.
- `CambiumTesting`: test-support helpers.
- `CambiumSyntaxMacros`: syntax-kind derivation macros.
