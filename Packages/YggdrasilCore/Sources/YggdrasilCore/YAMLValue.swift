import Foundation

/// A minimal, order-preserving YAML value model covering the subset of YAML
/// actually used by the `_heimdal/**` note substrate (scalars, block sequences,
/// block mappings, sequences of mappings). Not a general-purpose YAML engine —
/// see `YAMLCodec` for the parsing/serialization rules this subset supports.
public indirect enum YAMLValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([YAMLValue])
    case map(YAMLMap)
}

/// An order-preserving string-keyed map. Field order is preserved on
/// round-trip so unknown fields written by another party (the Python
/// backend, Obsidian) are never reordered or silently dropped.
public struct YAMLMap: Equatable {
    public private(set) var keys: [String] = []
    private var storage: [String: YAMLValue] = [:]

    public init() {}

    public init(_ pairs: [(String, YAMLValue)]) {
        for (key, value) in pairs {
            self[key] = value
        }
    }

    public subscript(key: String) -> YAMLValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil {
                    keys.append(key)
                }
                storage[key] = newValue
            } else if storage[key] != nil {
                storage.removeValue(forKey: key)
                keys.removeAll { $0 == key }
            }
        }
    }

    public var pairs: [(String, YAMLValue)] {
        keys.compactMap { key in
            guard let value = storage[key] else { return nil }
            return (key, value)
        }
    }

    public var isEmpty: Bool { keys.isEmpty }
}

// MARK: - Convenience accessors

public extension YAMLValue {
    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [YAMLValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var mapValue: YAMLMap? {
        if case .map(let value) = self { return value }
        return nil
    }

    /// A list of scalar strings, e.g. `watched:` / `filters:`.
    var stringArray: [String]? {
        arrayValue?.compactMap { $0.stringValue }
    }
}
