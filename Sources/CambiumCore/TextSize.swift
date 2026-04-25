public enum TextSizeError: Error, Sendable, Equatable {
    case overflow
    case negative
}

/// A UTF-8 byte count or offset.
///
/// Cambium stores source positions as compact UInt32 byte offsets. Operations
/// that can exceed this representation either throw or trap at API boundaries
/// where continuing would corrupt tree invariants.
public struct TextSize: RawRepresentable, Sendable, Hashable, Comparable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt32) {
        self.init(rawValue: rawValue)
    }

    public init(exactly value: Int) throws {
        guard value >= 0 else {
            throw TextSizeError.negative
        }
        guard let raw = UInt32(exactly: value) else {
            throw TextSizeError.overflow
        }
        self.init(raw)
    }

    public init(byteCountOf text: String) throws {
        try self.init(exactly: text.utf8.count)
    }

    public static let zero = TextSize(0)

    public static func < (lhs: TextSize, rhs: TextSize) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func adding(_ rhs: TextSize) throws -> TextSize {
        let (value, overflow) = rawValue.addingReportingOverflow(rhs.rawValue)
        guard !overflow else {
            throw TextSizeError.overflow
        }
        return TextSize(value)
    }

    public func subtracting(_ rhs: TextSize) throws -> TextSize {
        let (value, overflow) = rawValue.subtractingReportingOverflow(rhs.rawValue)
        guard !overflow else {
            throw TextSizeError.negative
        }
        return TextSize(value)
    }

    public static func + (lhs: TextSize, rhs: TextSize) -> TextSize {
        do {
            return try lhs.adding(rhs)
        } catch {
            preconditionFailure("TextSize addition overflow")
        }
    }

    public static func - (lhs: TextSize, rhs: TextSize) -> TextSize {
        do {
            return try lhs.subtracting(rhs)
        } catch {
            preconditionFailure("TextSize subtraction underflow")
        }
    }
}

extension TextSize: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt32) {
        self.init(value)
    }
}

public struct TextRange: Sendable, Hashable {
    public let start: TextSize
    public let end: TextSize

    public init(start: TextSize, end: TextSize) {
        precondition(start <= end, "TextRange start must not be after end")
        self.start = start
        self.end = end
    }

    public init(start: TextSize, length: TextSize) {
        self.init(start: start, end: start + length)
    }

    public var length: TextSize {
        end - start
    }

    public var isEmpty: Bool {
        start == end
    }

    public func contains(_ offset: TextSize) -> Bool {
        start <= offset && offset < end
    }

    public func containsAllowingEnd(_ offset: TextSize) -> Bool {
        start <= offset && offset <= end
    }

    public func contains(_ range: TextRange) -> Bool {
        start <= range.start && range.end <= end
    }

    public func intersects(_ range: TextRange) -> Bool {
        start < range.end && range.start < end
    }

    public func shifted(by delta: TextSize) -> TextRange {
        TextRange(start: start + delta, end: end + delta)
    }

    public static let empty = TextRange(start: .zero, end: .zero)
}
