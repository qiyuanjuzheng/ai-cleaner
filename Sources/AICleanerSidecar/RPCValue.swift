#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// JSON-RPC values preserve integral numbers and request IDs without a Double round trip.
enum RPCValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([RPCValue])
    case object([String: RPCValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let int = try? value.decode(Int64.self) { self = .integer(int) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = .object(try value.decode([String: Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var output = encoder.singleValueContainer()
        switch self {
        case .null: try output.encodeNil()
        case .bool(let value): try output.encode(value)
        case .integer(let value): try output.encode(value)
        case .number(let value): try output.encode(value)
        case .string(let value): try output.encode(value)
        case .array(let value): try output.encode(value)
        case .object(let value): try output.encode(value)
        }
    }

    var object: [String: Self]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var array: [Self]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .integer(let value) = self { return Int(exactly: value) }
        return nil
    }

    subscript(key: String) -> Self? { object?[key] }

    var isRequestID: Bool {
        switch self {
        case .null, .string, .integer, .number: return true
        case .bool, .array, .object: return false
        }
    }

    static func count(_ value: Int) -> Self { .integer(Int64(value)) }

    static func model<T: Encodable>(_ value: T) throws -> Self {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(Self.self, from: encoder.encode(value))
    }
}

struct RPCError: Error, Sendable {
    let code: Int64
    let message: String
    let name: String?
    let reason: String?

    init(_ code: Int64, _ message: String, name: String? = nil, reason: String? = nil) {
        self.code = code
        self.message = message
        self.name = name
        self.reason = reason
    }

    var value: RPCValue {
        var error: [String: RPCValue] = ["code": .integer(code), "message": .string(message)]
        if let name {
            var data: [String: RPCValue] = ["name": .string(name)]
            if let reason { data["reason"] = .string(reason) }
            error["data"] = .object(data)
        }
        return .object(error)
    }

    static let invalidRequest = Self(-32600, "Invalid Request")
    static let invalidParams = Self(-32602, "Invalid params")
    static let methodNotFound = Self(-32601, "Method not found")
    static let versionMismatch = Self(-32000, "Protocol version mismatch", name: "PROTOCOL_VERSION_MISMATCH")
    static let scanInProgress = Self(-32001, "Scan already running", name: "SCAN_IN_PROGRESS")
    static let scanNotFound = Self(-32002, "Scan not found", name: "SCAN_NOT_FOUND")
    static let scanNotReady = Self(-32003, "Scan not ready", name: "SCAN_NOT_READY")
    static let riskConfirmation = Self(-32005, "Risk confirmation required", name: "RISK_CONFIRMATION_REQUIRED")
    static let invalidConfirmation = Self(-32006, "Preview confirmation expired", name: "CONFIRMATION_TOKEN_INVALID")

    static func storage(_ error: Error) -> Self {
        Self(-32020, "Storage error", name: "STORAGE_IO_ERROR", reason: String(describing: error))
    }
}
