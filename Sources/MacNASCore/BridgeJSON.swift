import Foundation

/// Bounded JSON parser preserving number lexemes and rejecting duplicate decoded keys.
indirect enum BridgeJSON {
    case object([String: BridgeJSON]), array([BridgeJSON]), string(String), number(String), bool(Bool), null
    func fields(required: Set<String>, optional: Set<String> = []) throws -> [String: BridgeJSON] {
        guard case .object(let fields) = self else { throw NASError.invalidSchema }
        let keys = Set(fields.keys)
        try require(required.isSubset(of: keys) && keys.isSubset(of: required.union(optional)), .invalidSchema)
        return fields
    }
    func text(maximumBytes: Int, allowEmpty: Bool = false) throws -> String {
        guard case .string(let value) = self else { throw NASError.invalidSchema }
        try require((allowEmpty || !value.isEmpty) && value.utf8.count <= maximumBytes && !value.contains("\0"), .invalidSchema)
        return value
    }
    func integer(in range: ClosedRange<Int64>) throws -> Int64 {
        guard case .number(let token) = self, !token.isEmpty,
              token.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int64(token) else { throw NASError.invalidSchema }
        try require(range.contains(value) && value <= 9_007_199_254_740_991, .invalidSchema)
        return value
    }
    static func decode(_ data: Data, maximumBytes: Int = 65536) throws -> BridgeJSON {
        try require(data.count <= maximumBytes, .budgetExceeded)
        try require(!data.isEmpty, .invalidSchema)
        try require(String(data: data, encoding: .utf8) != nil, .invalidSchema)
        var parser = Parser(bytes: Array(data))
        let result = try parser.value(depth: 0)
        parser.whitespace()
        try require(parser.index == parser.bytes.count, .invalidSchema)
        return result
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        mutating func whitespace() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count && bytes[index] == byte else { return false }
            index += 1; return true
        }
        mutating func expect(_ byte: UInt8) throws { try require(consume(byte), .invalidSchema) }
        mutating func literal(_ text: String) throws {
            for byte in text.utf8 { try expect(byte) }
        }
        mutating func value(depth: Int) throws -> BridgeJSON {
            try require(depth <= 16 && nodes < 4096, .budgetExceeded)
            nodes += 1; whitespace()
            guard index < bytes.count else { throw NASError.invalidSchema }
            switch bytes[index] {
            case 123:
                index += 1; whitespace(); var fields: [String: BridgeJSON] = [:]
                if consume(125) { return .object(fields) }
                while true {
                    whitespace(); let key = try string()
                    try require(fields[key] == nil, .invalidSchema)
                    whitespace(); try expect(58)
                    fields[key] = try value(depth: depth + 1)
                    whitespace(); if consume(125) { return .object(fields) }
                    try expect(44)
                }
            case 91:
                index += 1; whitespace(); var values: [BridgeJSON] = []
                if consume(93) { return .array(values) }
                while true {
                    values.append(try value(depth: depth + 1))
                    whitespace(); if consume(93) { return .array(values) }
                    try expect(44)
                }
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            case 45,48...57: return .number(try number())
            default: throw NASError.invalidSchema
            }
        }
        mutating func hexUnit() throws -> UInt16 {
            var value: UInt16 = 0
            for _ in 0..<4 {
                guard index < bytes.count else { throw NASError.invalidSchema }
                let byte = bytes[index], digit: UInt16
                switch byte {
                case 48...57: digit = UInt16(byte - 48)
                case 65...70: digit = UInt16(byte - 55)
                case 97...102: digit = UInt16(byte - 87)
                default: throw NASError.invalidSchema
                }
                value = value * 16 + digit; index += 1
            }
            return value
        }
        mutating func string() throws -> String {
            let start = index; try expect(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw NASError.invalidSchema }
                }
                try require(byte >= 32, .invalidSchema)
                if byte == 92 {
                    guard index < bytes.count else { throw NASError.invalidSchema }
                    let escaped = bytes[index]; index += 1
                    if escaped == 117 {
                        let unit = try hexUnit()
                        if (0xD800...0xDBFF).contains(unit) {
                            try expect(92); try expect(117)
                            try require((0xDC00...0xDFFF).contains(try hexUnit()), .invalidSchema)
                        } else { try require(!(0xDC00...0xDFFF).contains(unit), .invalidSchema) }
                    } else { try require([34,47,92,98,102,110,114,116].contains(escaped), .invalidSchema) }
                }
            }
            throw NASError.invalidSchema
        }
        mutating func digits() -> Int {
            let start = index
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            return index - start
        }
        mutating func number() throws -> String {
            let start = index; _ = consume(45)
            guard index < bytes.count else { throw NASError.invalidSchema }
            if consume(48) { /* a following digit is rejected by the enclosing grammar */ }
            else {
                try require(index < bytes.count && (49...57).contains(bytes[index]), .invalidSchema)
                _ = digits()
            }
            if consume(46) { try require(digits() > 0, .invalidSchema) }
            if index < bytes.count && [69,101].contains(bytes[index]) {
                index += 1
                if index < bytes.count && [43,45].contains(bytes[index]) { index += 1 }
                try require(digits() > 0, .invalidSchema)
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}
