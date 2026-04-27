/// Errors thrown by ``CambiumCore/TextSize`` arithmetic that would otherwise lose
/// information.
public enum TextSizeError: Error, Sendable, Equatable {
    /// The result exceeded ``CambiumCore/TextSize``'s 32-bit range. Cambium stores
    /// every source offset in 4 bytes; documents larger than ~4 GiB are
    /// not representable and would silently wrap without this error.
    case overflow

    /// The operation would have produced a negative offset or accepted a
    /// negative input. Used by the throwing initializer
    /// ``TextSize/init(exactly:)`` and by ``TextSize/subtracting(_:)``.
    case negative
}

/// A UTF-8 byte count or offset.
///
/// Cambium represents every source position as a 32-bit byte offset. Using
/// `UInt32` instead of `Int` keeps green storage compact (positions appear
/// throughout green and red trees) and makes the byte-count contract
/// explicit: positions and lengths in this library are **always** UTF-8 byte
/// counts, never code-point or grapheme counts.
///
/// All arithmetic exposed by `TextSize` is checked. The throwing variants
/// (``adding(_:)``, ``subtracting(_:)``, ``init(exactly:)``) report
/// overflow/underflow through ``CambiumCore/TextSizeError``. The operator forms
/// (`+`, `-`) trap on overflow — they exist for paths where Cambium has
/// already proved the arithmetic is in range, and would corrupt tree
/// invariants if it weren't.
///
/// ## Topics
///
/// ### Constants
/// - ``zero``
///
/// ### Constructing
/// - ``init(rawValue:)``
/// - ``init(_:)``
/// - ``init(exactly:)``
/// - ``init(byteCountOf:)``
/// - ``init(integerLiteral:)``
///
/// ### Checked arithmetic
/// - ``adding(_:)``
/// - ``subtracting(_:)``
public struct TextSize: RawRepresentable, Sendable, Hashable, Comparable {
    /// The wrapped UTF-8 byte count.
    public let rawValue: UInt32

    /// Wrap a `UInt32` byte count.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Wrap a `UInt32` byte count. Equivalent to ``init(rawValue:)``;
    /// provided for the more idiomatic `TextSize(7)` call site.
    public init(_ rawValue: UInt32) {
        self.init(rawValue: rawValue)
    }

    /// Convert from an `Int` byte count, rejecting negative values
    /// (``TextSizeError/negative``) and values too large to fit in a
    /// `UInt32` (``TextSizeError/overflow``).
    public init(exactly value: Int) throws {
        guard value >= 0 else {
            throw TextSizeError.negative
        }
        guard let raw = UInt32(exactly: value) else {
            throw TextSizeError.overflow
        }
        self.init(raw)
    }

    /// Convenience initializer that returns the UTF-8 byte length of `text`.
    /// Throws ``TextSizeError/overflow`` for strings longer than `UInt32.max`
    /// bytes.
    public init(byteCountOf text: String) throws {
        try self.init(exactly: text.utf8.count)
    }

    /// The zero offset, i.e. the start of the document.
    public static let zero = TextSize(0)

    public static func < (lhs: TextSize, rhs: TextSize) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Add two text sizes, throwing ``TextSizeError/overflow`` if the result
    /// would exceed `UInt32.max`.
    public func adding(_ rhs: TextSize) throws -> TextSize {
        let (value, overflow) = rawValue.addingReportingOverflow(rhs.rawValue)
        guard !overflow else {
            throw TextSizeError.overflow
        }
        return TextSize(value)
    }

    /// Subtract two text sizes, throwing ``TextSizeError/negative`` if the
    /// result would go below zero.
    public func subtracting(_ rhs: TextSize) throws -> TextSize {
        let (value, overflow) = rawValue.subtractingReportingOverflow(rhs.rawValue)
        guard !overflow else {
            throw TextSizeError.negative
        }
        return TextSize(value)
    }

    /// Trapping addition. Use only when overflow is structurally impossible;
    /// prefer ``adding(_:)`` at boundaries that take untrusted input.
    public static func + (lhs: TextSize, rhs: TextSize) -> TextSize {
        do {
            return try lhs.adding(rhs)
        } catch {
            preconditionFailure("TextSize addition overflow")
        }
    }

    /// Trapping subtraction. Use only when underflow is structurally
    /// impossible; prefer ``subtracting(_:)`` at boundaries that take
    /// untrusted input.
    public static func - (lhs: TextSize, rhs: TextSize) -> TextSize {
        do {
            return try lhs.subtracting(rhs)
        } catch {
            preconditionFailure("TextSize subtraction underflow")
        }
    }
}

extension TextSize: ExpressibleByIntegerLiteral {
    /// Allow integer literals such as `let size: TextSize = 8`. Useful for
    /// fixture and test code.
    public init(integerLiteral value: UInt32) {
        self.init(value)
    }
}

/// A half-open `[start, end)` UTF-8 byte range within a source document.
///
/// Cambium uses `TextRange` everywhere a source span needs to be expressed —
/// node and token extents, edit ranges in `TextEdit`, search ranges for
/// `tokens(in:)`. Empty ranges (`start == end`) are valid and represent a
/// zero-length location, such as the position of a missing token.
///
/// `TextRange` is value-typed and `Sendable`; pass it freely across actor
/// boundaries.
///
/// ## Topics
///
/// ### Constants
/// - ``empty``
///
/// ### Constructing
/// - ``init(start:end:)``
/// - ``init(start:length:)``
///
/// ### Geometry
/// - ``length``
/// - ``isEmpty``
///
/// ### Containment and intersection
/// - ``contains(_:)-(TextSize)``
/// - ``contains(_:)-(TextRange)``
/// - ``containsAllowingEnd(_:)``
/// - ``intersects(_:)``
///
/// ### Translation
/// - ``shifted(by:)``
public struct TextRange: Sendable, Hashable {
    /// The first byte offset included in the range.
    public let start: TextSize

    /// The byte offset one past the last included byte. Equal to ``start``
    /// for empty ranges.
    public let end: TextSize

    /// Construct a range from explicit endpoints. Traps if `start > end`.
    public init(start: TextSize, end: TextSize) {
        precondition(start <= end, "TextRange start must not be after end")
        self.start = start
        self.end = end
    }

    /// Construct a range from a start offset and a length.
    public init(start: TextSize, length: TextSize) {
        self.init(start: start, end: start + length)
    }

    /// The number of bytes covered by this range.
    public var length: TextSize {
        end - start
    }

    /// Whether the range covers zero bytes.
    public var isEmpty: Bool {
        start == end
    }

    /// Whether `offset` lies strictly inside the range. Excludes the
    /// terminal `end` boundary; use ``containsAllowingEnd(_:)`` to include
    /// it (useful for cursor-position queries).
    public func contains(_ offset: TextSize) -> Bool {
        start <= offset && offset < end
    }

    /// Like ``contains(_:)-(TextSize)`` but also returns `true` when
    /// `offset == end`. Useful for caret-position queries where a cursor
    /// at the very end of the range is "inside" for editing purposes.
    public func containsAllowingEnd(_ offset: TextSize) -> Bool {
        start <= offset && offset <= end
    }

    /// Whether `range` is fully contained within `self` (inclusive of
    /// matching endpoints).
    public func contains(_ range: TextRange) -> Bool {
        start <= range.start && range.end <= end
    }

    /// Whether `self` and `range` share at least one byte. Two ranges that
    /// touch at a single endpoint (`a.end == b.start`) do **not** intersect.
    public func intersects(_ range: TextRange) -> Bool {
        start < range.end && range.start < end
    }

    /// Return a copy of this range translated forward by `delta` bytes.
    /// Useful for adjusting old-tree ranges after an edit shifted the
    /// document.
    public func shifted(by delta: TextSize) -> TextRange {
        TextRange(start: start + delta, end: end + delta)
    }

    /// The empty range at offset zero. Useful as a sentinel/default.
    public static let empty = TextRange(start: .zero, end: .zero)
}
