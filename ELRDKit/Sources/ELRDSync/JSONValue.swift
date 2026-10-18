import Foundation

/// Beliebiger JSON-Wert. Damit beschreibt das Änderungsjournal Feldwerte
/// unabhängig vom konkreten Swift-Typ.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Kennung eines Listenelements: bei Objekten das Feld `id`, bei Texten der Text selbst.
    var elementID: String? {
        switch self {
        case let .string(value): value
        case let .object(object):
            if case let .string(id)? = object["id"] { id } else { nil }
        default: nil
        }
    }
}

/// Wandelt `Codable`-Werte in `JSONValue` um und zurück – mit festen Einstellungen,
/// damit alle Geräte identische Darstellungen erzeugen.
public enum JSONValueCoder {
    public static func encode(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: encoder.encode(value))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
