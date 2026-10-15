import Foundation

public indirect enum JSONValue: Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(String), bool(Bool), null
}

public enum BoundedJSON {
    public static func decode(_ payload: Data) throws -> JSONValue {
        guard payload.count <= WireLimits.maxPayloadBytes,
              String(data: payload, encoding: .utf8) != nil else { throw ProtocolFailure(.invalidJSON) }
        var parser = JSONParser(bytes: Array(payload))
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.offset == parser.bytes.count else { throw ProtocolFailure(.invalidJSON) }
        return value
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var offset = 0
    var values = 0
    var current: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    mutating func whitespace() {
        while let current, [UInt8(9), 10, 13, 32].contains(current) { offset += 1 }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        if current == byte { offset += 1; return true }
        return false
    }

    mutating func value(depth: Int) throws -> JSONValue {
        whitespace()
        values += 1
        guard values <= 16_384 else { throw ProtocolFailure(.valueLimit) }
        guard let current else { throw ProtocolFailure(.invalidJSON) }
        switch current {
        case 123, 91:
            guard depth < 32 else { throw ProtocolFailure(.nestingLimit) }
            offset += 1
            whitespace()
            if current == 123 {
                var object: [String: JSONValue] = [:]
                if consume(125) { return .object(object) }
                repeat {
                    whitespace()
                    let key = try string()
                    guard object[key] == nil else { throw ProtocolFailure(.duplicateKey) }
                    whitespace()
                    guard consume(58) else { throw ProtocolFailure(.invalidJSON) }
                    object[key] = try value(depth: depth + 1)
                    whitespace()
                    if consume(125) { return .object(object) }
                    guard consume(44) else { throw ProtocolFailure(.invalidJSON) }
                } while true
            }
            var array: [JSONValue] = []
            if consume(93) { return .array(array) }
            repeat {
                array.append(try value(depth: depth + 1))
                whitespace()
                if consume(93) { return .array(array) }
                guard consume(44) else { throw ProtocolFailure(.invalidJSON) }
            } while true
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        case 45, 48...57: return .number(try number())
        default: throw ProtocolFailure(.invalidJSON)
        }
    }

    mutating func literal(_ text: String) throws {
        let expected = Array(text.utf8)
        guard bytes.count - offset >= expected.count,
              Array(bytes[offset..<(offset + expected.count)]) == expected else { throw ProtocolFailure(.invalidJSON) }
        offset += expected.count
    }

    mutating func string() throws -> String {
        let start = offset
        guard consume(34) else { throw ProtocolFailure(.invalidJSON) }
        while let current {
            guard current >= 32 else { throw ProtocolFailure(.invalidJSON) }
            offset += 1
            if current == 34 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                catch { throw ProtocolFailure(.invalidJSON) }
            }
            if current == 92 {
                guard offset < bytes.count else { throw ProtocolFailure(.invalidJSON) }
                offset += 1
            }
        }
        throw ProtocolFailure(.invalidJSON)
    }

    mutating func number() throws -> String {
        let start = offset
        _ = consume(45)
        if !consume(48) {
            guard let current, (49...57).contains(current) else { throw ProtocolFailure(.invalidJSON) }
            digits()
        }
        if consume(46) {
            let fraction = offset
            digits()
            guard offset > fraction else { throw ProtocolFailure(.invalidJSON) }
        }
        if consume(101) || consume(69) {
            if !consume(43) { _ = consume(45) }
            let exponent = offset
            digits()
            guard offset > exponent else { throw ProtocolFailure(.invalidJSON) }
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    mutating func digits() {
        while let current, (48...57).contains(current) { offset += 1 }
    }
}
