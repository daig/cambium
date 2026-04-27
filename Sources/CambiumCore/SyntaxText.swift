/// A streaming sink for UTF-8 byte chunks.
///
/// `UTF8Sink` is the abstraction `GreenNode.writeText(to:using:)` and
/// ``CambiumCore/SyntaxText/writeUTF8(to:)`` use to emit text without committing to a
/// single output type. Implement it to write into a file, network buffer,
/// hash, or any other UTF-8-consuming target. ``CambiumCore/StringUTF8Sink`` is the
/// bundled allocating implementation.
public protocol UTF8Sink {
    /// Append `bytes` to the sink. Implementations may buffer or write
    /// through directly; the only requirement is that calls are processed
    /// in order.
    mutating func write(_ bytes: UnsafeBufferPointer<UInt8>) throws
}

/// A ``CambiumCore/UTF8Sink`` that accumulates bytes into a `String`.
///
/// Useful for materializing text from a tree when you want a `String` at
/// the end. For incremental output (writing to a file, computing a hash),
/// implement ``CambiumCore/UTF8Sink`` directly to avoid building an intermediate
/// string.
public struct StringUTF8Sink: UTF8Sink {
    /// The accumulated string built so far.
    public private(set) var result: String

    /// Construct an empty sink.
    public init() {
        self.result = ""
    }

    /// Append `bytes` (decoded as UTF-8) to ``result``.
    public mutating func write(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        result += String(decoding: bytes, as: UTF8.self)
    }
}

/// A non-allocating, borrowed view over a contiguous UTF-8 byte range
/// inside a green subtree.
///
/// `SyntaxText` lets you scan source text — searching for bytes or byte
/// sequences, comparing for equality, slicing, streaming — without
/// materializing a `String`. Internally it walks the green tree on demand,
/// yielding chunks that point straight at the resolver's interned bytes
/// or at static-text storage; nothing is copied or allocated unless you
/// explicitly call ``makeString()``.
///
/// Obtain a `SyntaxText` via ``SyntaxNodeCursor/withText(_:)``:
///
/// ```swift
/// tree.withRoot { root in
///     root.withText { text in
///         if text.contains(0x2B) {  // '+'
///             // ...
///         }
///     }
/// }
/// ```
///
/// `SyntaxText` is `~Copyable` and is meant to live entirely inside the
/// borrow scope. Slice it with ``sliced(_:)`` to drill into a sub-range.
public struct SyntaxText<Lang: SyntaxLanguage>: ~Copyable {
    private let root: GreenNode<Lang>
    private let resolver: any TokenResolver
    private let range: TextRange

    /// Construct a view over the entire text of `root`, resolving any
    /// dynamic token keys through `resolver`.
    public init(root: GreenNode<Lang>, resolver: any TokenResolver) {
        self.root = root
        self.resolver = resolver
        self.range = TextRange(start: .zero, length: root.textLength)
    }

    private init(root: GreenNode<Lang>, resolver: any TokenResolver, range: TextRange) {
        self.root = root
        self.resolver = resolver
        self.range = range
    }

    /// The byte length of the visible range.
    public var utf8Count: Int {
        Int(range.length.rawValue)
    }

    /// Whether the visible range is empty.
    public var isEmpty: Bool {
        range.isEmpty
    }

    /// Stream every byte in the visible range into `sink`. No allocation.
    public borrowing func writeUTF8<Sink: UTF8Sink>(to sink: inout Sink) throws {
        try forEachUTF8Chunk { bytes in
            try sink.write(bytes)
        }
    }

    /// Call `body` for each contiguous UTF-8 byte chunk in the visible
    /// range, in source order. The buffer is valid only for the duration
    /// of each call; do not let it escape `body`.
    ///
    /// Throwing from `body` propagates. To stop iteration early without
    /// signalling an error, throw a sentinel and catch it outside.
    public borrowing func forEachUTF8Chunk(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws {
        guard !range.isEmpty else {
            return
        }
        try SyntaxText.forEachUTF8Chunk(
            in: root,
            resolver: resolver,
            nodeStart: .zero,
            range: range,
            body
        )
    }

    /// Whether `byte` appears anywhere in the visible range.
    public borrowing func contains(_ byte: UInt8) -> Bool {
        firstIndex(of: byte) != nil
    }

    /// Whether the byte sequence `needle` appears anywhere in the visible
    /// range. Empty needles always match.
    public borrowing func contains(_ needle: [UInt8]) -> Bool {
        firstRange(of: needle) != nil
    }

    /// The byte offset (relative to the visible range's start) of the first
    /// occurrence of `byte`, or `nil` if `byte` does not appear.
    public borrowing func firstIndex(of byte: UInt8) -> TextSize? {
        var offset = 0
        var result: TextSize?
        do {
            try forEachUTF8Chunk { bytes in
                if result != nil {
                    throw SyntaxTextScanStop.stop
                }
                for index in 0..<bytes.count where bytes[index] == byte {
                    result = try TextSize(exactly: offset + index)
                    throw SyntaxTextScanStop.stop
                }
                offset += bytes.count
            }
        } catch SyntaxTextScanStop.stop {
            return result
        } catch {
            preconditionFailure("Unexpected SyntaxText byte search error: \(error)")
        }
        return result
    }

    /// The byte range (relative to the visible range's start) of the first
    /// occurrence of `needle`, or `nil` if `needle` does not appear. Uses a
    /// KMP-style scan, so each byte of input is examined at most a constant
    /// number of times.
    public borrowing func firstRange(of needle: [UInt8]) -> TextRange? {
        if needle.isEmpty {
            return TextRange(start: .zero, length: .zero)
        }
        guard needle.count <= utf8Count else {
            return nil
        }

        let prefix = SyntaxText.prefixTable(for: needle)
        var matched = 0
        var offset = 0
        var result: TextRange?

        do {
            try forEachUTF8Chunk { bytes in
                if result != nil {
                    throw SyntaxTextScanStop.stop
                }

                for index in 0..<bytes.count {
                    while matched > 0 && bytes[index] != needle[matched] {
                        matched = prefix[matched - 1]
                    }

                    if bytes[index] == needle[matched] {
                        matched += 1
                    }

                    if matched == needle.count {
                        let end = offset + index + 1
                        let start = end - needle.count
                        result = TextRange(
                            start: try TextSize(exactly: start),
                            length: try TextSize(exactly: needle.count)
                        )
                        throw SyntaxTextScanStop.stop
                    }
                }
                offset += bytes.count
            }
        } catch SyntaxTextScanStop.stop {
            return result
        } catch {
            preconditionFailure("Unexpected SyntaxText byte search error: \(error)")
        }

        return result
    }

    /// A `SyntaxText` view restricted to `sliceRange` (interpreted relative
    /// to this view's start). Traps if `sliceRange` is not contained in the
    /// current visible range.
    public borrowing func sliced(_ sliceRange: TextRange) -> SyntaxText<Lang> {
        let bounds = TextRange(start: .zero, length: range.length)
        precondition(bounds.contains(sliceRange), "SyntaxText slice range out of bounds")
        return SyntaxText(
            root: root,
            resolver: resolver,
            range: TextRange(start: range.start + sliceRange.start, length: sliceRange.length)
        )
    }

    /// Whether the visible range is byte-for-byte equal to `string`'s
    /// UTF-8 encoding.
    public borrowing func equals(_ string: String) -> Bool {
        guard string.utf8.count == utf8Count else {
            return false
        }

        if let result = string.utf8.withContiguousStorageIfAvailable({ bytes in
            equals(bytes)
        }) {
            return result
        }

        return Array(string.utf8).withUnsafeBufferPointer { bytes in
            equals(bytes)
        }
    }

    /// Whether two `SyntaxText` views are byte-for-byte equal.
    public borrowing func equals(_ other: borrowing SyntaxText<Lang>) -> Bool {
        guard utf8Count == other.utf8Count else {
            return false
        }

        var offset = 0
        var equal = true

        do {
            try forEachUTF8Chunk { bytes in
                guard equal else {
                    throw SyntaxTextScanStop.stop
                }

                let comparisonRange = TextRange(
                    start: try TextSize(exactly: offset),
                    length: try TextSize(exactly: bytes.count)
                )
                if !other.equals(bytes, in: comparisonRange) {
                    equal = false
                    throw SyntaxTextScanStop.stop
                }
                offset += bytes.count
            }
        } catch SyntaxTextScanStop.stop {
            return equal
        } catch {
            preconditionFailure("Unexpected SyntaxText equality error: \(error)")
        }

        return equal
    }

    /// Consume the view and return its bytes as a `String`. Allocates.
    /// Prefer ``forEachUTF8Chunk(_:)`` when you can stream the bytes.
    public consuming func makeString() -> String {
        var sink = StringUTF8Sink()
        do {
            try writeUTF8(to: &sink)
        } catch {
            preconditionFailure("Unexpected SyntaxText string materialization error: \(error)")
        }
        return sink.result
    }

    private borrowing func equals(_ expected: UnsafeBufferPointer<UInt8>) -> Bool {
        var offset = 0
        var equal = true

        do {
            try forEachUTF8Chunk { bytes in
                guard equal else {
                    throw SyntaxTextScanStop.stop
                }
                if !SyntaxText.buffer(bytes, equals: expected, startingAt: offset) {
                    equal = false
                    throw SyntaxTextScanStop.stop
                }
                offset += bytes.count
            }
        } catch SyntaxTextScanStop.stop {
            return equal
        } catch {
            preconditionFailure("Unexpected SyntaxText equality error: \(error)")
        }

        return equal
    }

    private borrowing func equals(
        _ expected: UnsafeBufferPointer<UInt8>,
        in comparisonRange: TextRange
    ) -> Bool {
        let text = sliced(comparisonRange)
        return text.equals(expected)
    }

    private static func forEachUTF8Chunk(
        in node: GreenNode<Lang>,
        resolver: any TokenResolver,
        nodeStart: TextSize,
        range: TextRange,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws {
        let nodeRange = TextRange(start: nodeStart, length: node.textLength)
        guard nodeRange.intersects(range) else {
            return
        }

        var childStart = nodeStart
        for childIndex in 0..<node.childCount {
            let child = node.child(at: childIndex)
            let childEnd = childStart + child.textLength
            let childRange = TextRange(start: childStart, end: childEnd)
            defer {
                childStart = childEnd
            }

            guard childRange.intersects(range) else {
                continue
            }

            switch child {
            case .node(let childNode):
                try forEachUTF8Chunk(
                    in: childNode,
                    resolver: resolver,
                    nodeStart: childStart,
                    range: range,
                    body
                )
            case .token(let token):
                try token.withTextUTF8(using: resolver) { bytes in
                    let chunkStart = max(range.start, childStart)
                    let chunkEnd = min(range.end, childEnd)
                    guard chunkStart < chunkEnd else {
                        return
                    }

                    let localStart = Int(chunkStart.rawValue - childStart.rawValue)
                    let localEnd = Int(chunkEnd.rawValue - childStart.rawValue)
                    let chunk = UnsafeBufferPointer(rebasing: bytes[localStart..<localEnd])
                    if !chunk.isEmpty {
                        try body(chunk)
                    }
                }
            }
        }
    }

    private static func prefixTable(for needle: [UInt8]) -> [Int] {
        var prefix = Array(repeating: 0, count: needle.count)
        var matched = 0
        for index in 1..<needle.count {
            while matched > 0 && needle[index] != needle[matched] {
                matched = prefix[matched - 1]
            }
            if needle[index] == needle[matched] {
                matched += 1
                prefix[index] = matched
            }
        }
        return prefix
    }

    private static func buffer(
        _ buffer: UnsafeBufferPointer<UInt8>,
        equals expected: UnsafeBufferPointer<UInt8>,
        startingAt offset: Int
    ) -> Bool {
        guard offset + buffer.count <= expected.count else {
            return false
        }

        for index in 0..<buffer.count where buffer[index] != expected[offset + index] {
            return false
        }
        return true
    }
}

private enum SyntaxTextScanStop: Error {
    case stop
}
