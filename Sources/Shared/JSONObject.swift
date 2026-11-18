//
//  JSONObject.swift
//  ID3Maps — shared.
//
//  A minimal, Sendable JSON container used to carry `vehicle_parameters`
//  through Codable without flattening the arrays/numbers into fixed Swift types.
//  `value` returns a Foundation object tree (`[String: Any]`) suitable for the
//  Intents formula-argument dictionaries.
//

import Foundation

/// A decoded JSON value that preserves object/array/number/string/bool/null.
enum JSONValue: Sendable, Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case number(Double)
    case string(String)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    /// Foundation object tree for use with Intents / JSONSerialization.
    var foundationValue: Any {
        switch self {
        case .object(let o): return o.mapValues { $0.foundationValue }
        case .array(let a): return a.map { $0.foundationValue }
        case .number(let n): return n
        case .string(let s): return s
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}

/// A JSON object wrapper whose `.value` is a `[String: Any]` tree.
struct JSONObject: Sendable, Codable {
    let fields: [String: JSONValue]

    init(fields: [String: JSONValue]) { self.fields = fields }

    init(from decoder: Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fields)
    }

    var value: [String: Any] {
        fields.mapValues { $0.foundationValue }
    }
}
