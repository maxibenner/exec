import Foundation

public enum RemoteJSON: Codable, Sendable, Equatable {
    case object([String: RemoteJSON]), array([RemoteJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let x = try? value.decode(Bool.self) { self = .bool(x) }
        else if let x = try? value.decode(String.self) { self = .string(x) }
        else if let x = try? value.decode(Double.self) { self = .number(x) }
        else if let x = try? value.decode([String: RemoteJSON].self) { self = .object(x) }
        else { self = .array(try value.decode([RemoteJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let x): try value.encode(x)
        case .array(let x): try value.encode(x)
        case .string(let x): try value.encode(x)
        case .number(let x): try value.encode(x)
        case .bool(let x): try value.encode(x)
        case .null: try value.encodeNil()
        }
    }
    public subscript(_ key: String) -> RemoteJSON { if case .object(let x) = self { return x[key] ?? .null }; return .null }
    public var string: String? { if case .string(let x) = self { return x }; return nil }
    public var array: [RemoteJSON] { if case .array(let x) = self { return x }; return [] }
    public var bool: Bool { if case .bool(let x) = self { return x }; return false }
    public var number: Double? { if case .number(let x) = self { return x }; return nil }
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
    public static func optional(_ value: String?) -> Self { value.map(Self.string) ?? .null }
}
public struct RemoteFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
