public protocol UTF8Sink {
    mutating func write(_ bytes: UnsafeBufferPointer<UInt8>) throws
}

public struct StringUTF8Sink: UTF8Sink {
    public private(set) var result: String

    public init() {
        self.result = ""
    }

    public mutating func write(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        result += String(decoding: bytes, as: UTF8.self)
    }
}

public struct SyntaxText<Lang: SyntaxLanguage>: ~Copyable {
    private let root: GreenNode<Lang>
    private let resolver: any TokenResolver

    public init(root: GreenNode<Lang>, resolver: any TokenResolver) {
        self.root = root
        self.resolver = resolver
    }

    public var utf8Count: Int {
        Int(root.textLength.rawValue)
    }

    public borrowing func writeUTF8<Sink: UTF8Sink>(to sink: inout Sink) throws {
        try root.writeText(to: &sink, using: resolver)
    }

    public consuming func makeString() -> String {
        root.makeString(using: resolver)
    }
}
