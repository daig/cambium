import CambiumCore
import Synchronization

public enum DiagnosticSeverity: Sendable, Hashable {
    case note
    case warning
    case error
}

public struct Diagnostic<Lang: SyntaxLanguage>: Sendable, Hashable {
    public var range: TextRange
    public var message: String
    public var severity: DiagnosticSeverity
    public var anchor: SyntaxAnchor<Lang>?

    public init(
        range: TextRange,
        message: String,
        severity: DiagnosticSeverity = .error,
        anchor: SyntaxAnchor<Lang>? = nil
    ) {
        self.range = range
        self.message = message
        self.severity = severity
        self.anchor = anchor
    }
}

public struct SyntaxDataKey<Value: Sendable>: Sendable, Hashable {
    public let name: StaticString

    public init(_ name: StaticString) {
        self.name = name
    }

    fileprivate var id: String {
        String(describing: name)
    }

    public static func == (lhs: SyntaxDataKey<Value>, rhs: SyntaxDataKey<Value>) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private final class AnySendableBox: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }
}

public final class SyntaxMetadataStore<Lang: SyntaxLanguage>: @unchecked Sendable {
    private let storage = Mutex<[SyntaxNodeIdentity: [String: AnySendableBox]]>([:])

    public init() {}

    public func value<Value: Sendable>(
        for key: SyntaxDataKey<Value>,
        on handle: SyntaxNodeHandle<Lang>
    ) -> Value? {
        storage.withLock { values in
            values[handle.identity]?[key.id]?.value as? Value
        }
    }

    public func set<Value: Sendable>(
        _ value: Value,
        for key: SyntaxDataKey<Value>,
        on handle: SyntaxNodeHandle<Lang>
    ) {
        storage.withLock { values in
            values[handle.identity, default: [:]][key.id] = AnySendableBox(value)
        }
    }

    public func getOrCompute<Value: Sendable>(
        for key: SyntaxDataKey<Value>,
        on handle: SyntaxNodeHandle<Lang>,
        _ compute: () -> Value
    ) -> Value {
        if let cached: Value = value(for: key, on: handle) {
            return cached
        }
        let computed = compute()
        set(computed, for: key, on: handle)
        return computed
    }
}

public struct AnalysisCacheKey<Lang: SyntaxLanguage>: Sendable, Hashable {
    public let treeID: TreeID
    public let anchor: SyntaxAnchor<Lang>
    public let namespace: String

    public init(treeID: TreeID, anchor: SyntaxAnchor<Lang>, namespace: String) {
        self.treeID = treeID
        self.anchor = anchor
        self.namespace = namespace
    }
}

public final class ExternalAnalysisCache<Lang: SyntaxLanguage, Value: Sendable>: @unchecked Sendable {
    private let storage = Mutex<[AnalysisCacheKey<Lang>: Value]>([:])

    public init() {}

    public func value(for key: AnalysisCacheKey<Lang>) -> Value? {
        storage.withLock { $0[key] }
    }

    public func set(_ value: Value, for key: AnalysisCacheKey<Lang>) {
        storage.withLock { $0[key] = value }
    }

    public func removeValues(notMatching treeID: TreeID) {
        storage.withLock { values in
            values = values.filter { $0.key.treeID == treeID }
        }
    }
}
