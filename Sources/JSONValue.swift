import Foundation

/// An order-preserving JSON tree.
///
/// `JSONSerialization` returns unordered dictionaries, which would shuffle the
/// user's config every time we saved it. Since this app rewrites a live config
/// file, faithful round-tripping matters more than convenience: numbers keep
/// their original text, object keys keep their original order, and untouched
/// sections come back out byte-identical.
indirect enum JSONValue {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])
}

// MARK: - Accessors

extension JSONValue {
    var objectPairs: [(key: String, value: JSONValue)]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }

    var arrayValues: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let pairs) = self else { return nil }
            return pairs.first { $0.key == key }?.value
        }
        set {
            guard case .object(var pairs) = self else { return }
            if let index = pairs.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    pairs[index].value = newValue
                } else {
                    pairs.remove(at: index)
                }
            } else if let newValue {
                pairs.append((key: key, value: newValue))
            }
            self = .object(pairs)
        }
    }

    /// String values of an array, skipping anything that isn't a string.
    var stringArray: [String] {
        (arrayValues ?? []).compactMap(\.stringValue)
    }

    /// Flattens an object of string values into ordered key/value pairs.
    /// Non-string values are rendered back to compact JSON so nothing is lost.
    var stringMap: [(String, String)] {
        (objectPairs ?? []).map { pair in
            (pair.key, pair.value.stringValue ?? pair.value.serialized(pretty: false))
        }
    }

    static func from(_ strings: [String]) -> JSONValue {
        .array(strings.map { .string($0) })
    }

    static func from(_ pairs: [(String, String)]) -> JSONValue {
        .object(pairs.map { (key: $0.0, value: .string($0.1)) })
    }
}

// MARK: - Parsing

struct JSONParseError: LocalizedError {
    let message: String
    let line: Int
    let column: Int

    var errorDescription: String? { "Line \(line), column \(column): \(message)" }
}

extension JSONValue {
    static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(text: text)
        let value = try parser.parseValue()
        try parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw parser.error("unexpected text after the end of the JSON value")
        }
        return value
    }
}

private struct JSONParser {
    let scalars: [Character]
    var index: Int = 0

    init(text: String) {
        scalars = Array(text)
    }

    var isAtEnd: Bool { index >= scalars.count }

    func error(_ message: String) -> JSONParseError {
        var line = 1
        var column = 1
        for position in 0..<min(index, scalars.count) {
            if scalars[position] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return JSONParseError(message: message, line: line, column: column)
    }

    mutating func skipWhitespace() throws {
        while index < scalars.count {
            let character = scalars[index]
            if character == " " || character == "\n" || character == "\t" || character == "\r" {
                index += 1
            } else {
                break
            }
        }
    }

    mutating func parseValue() throws -> JSONValue {
        try skipWhitespace()
        guard index < scalars.count else { throw error("unexpected end of input") }
        switch scalars[index] {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t": try expect("true"); return .bool(true)
        case "f": try expect("false"); return .bool(false)
        case "n": try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ word: String) throws {
        for character in word {
            guard index < scalars.count, scalars[index] == character else {
                throw error("expected '\(word)'")
            }
            index += 1
        }
    }

    mutating func parseObject() throws -> JSONValue {
        index += 1 // consume '{'
        var pairs: [(key: String, value: JSONValue)] = []
        try skipWhitespace()
        if index < scalars.count, scalars[index] == "}" {
            index += 1
            return .object(pairs)
        }
        while true {
            try skipWhitespace()
            guard index < scalars.count, scalars[index] == "\"" else {
                throw error("expected a quoted key, or '}' to close the object")
            }
            let key = try parseString()
            try skipWhitespace()
            guard index < scalars.count, scalars[index] == ":" else {
                throw error("expected ':' after the key \"\(key)\"")
            }
            index += 1
            let value = try parseValue()
            pairs.append((key: key, value: value))
            try skipWhitespace()
            guard index < scalars.count else { throw error("unterminated object") }
            if scalars[index] == "," {
                index += 1
                continue
            }
            if scalars[index] == "}" {
                index += 1
                return .object(pairs)
            }
            throw error("expected ',' between entries or '}' to close the object")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        index += 1 // consume '['
        var values: [JSONValue] = []
        try skipWhitespace()
        if index < scalars.count, scalars[index] == "]" {
            index += 1
            return .array(values)
        }
        while true {
            values.append(try parseValue())
            try skipWhitespace()
            guard index < scalars.count else { throw error("unterminated array") }
            if scalars[index] == "," {
                index += 1
                continue
            }
            if scalars[index] == "]" {
                index += 1
                return .array(values)
            }
            throw error("expected ',' between items or ']' to close the array")
        }
    }

    mutating func parseString() throws -> String {
        index += 1 // consume opening quote
        var result = ""
        while index < scalars.count {
            let character = scalars[index]
            if character == "\"" {
                index += 1
                return result
            }
            if character == "\\" {
                index += 1
                guard index < scalars.count else { throw error("unterminated escape sequence") }
                switch scalars[index] {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    let scalar = try parseUnicodeEscape()
                    result.append(scalar)
                default: throw error("unsupported escape '\\\(scalars[index])'")
                }
                index += 1
                continue
            }
            result.append(character)
            index += 1
        }
        throw error("unterminated string")
    }

    /// Reads the four hex digits after `\u`, joining surrogate pairs so that
    /// emoji and other astral-plane characters survive a round trip.
    mutating func parseUnicodeEscape() throws -> Character {
        let high = try parseHexQuad()
        if high >= 0xD800, high <= 0xDBFF,
           index + 6 < scalars.count,
           scalars[index + 1] == "\\", scalars[index + 2] == "u" {
            let saved = index
            index += 2
            let low = try parseHexQuad()
            if low >= 0xDC00, low <= 0xDFFF {
                let combined = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else { throw error("invalid surrogate pair") }
                return Character(scalar)
            }
            index = saved
        }
        guard let scalar = Unicode.Scalar(high) else { throw error("invalid \\u escape") }
        return Character(scalar)
    }

    mutating func parseHexQuad() throws -> Int {
        var digits = ""
        for _ in 0..<4 {
            index += 1
            guard index < scalars.count else { throw error("incomplete \\u escape") }
            digits.append(scalars[index])
        }
        guard let value = Int(digits, radix: 16) else { throw error("invalid hex in \\u escape") }
        return value
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        if index < scalars.count, scalars[index] == "-" { index += 1 }
        while index < scalars.count, scalars[index].isNumber { index += 1 }
        if index < scalars.count, scalars[index] == "." {
            index += 1
            while index < scalars.count, scalars[index].isNumber { index += 1 }
        }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
            while index < scalars.count, scalars[index].isNumber { index += 1 }
        }
        let text = String(scalars[start..<index])
        guard !text.isEmpty, Double(text) != nil else {
            index = start
            throw error("expected a value")
        }
        return .number(text)
    }
}

// MARK: - Serializing

extension JSONValue {
    func serialized(pretty: Bool = true) -> String {
        var output = ""
        write(to: &output, indent: 0, pretty: pretty)
        return output
    }

    private func write(to output: inout String, indent: Int, pretty: Bool) {
        let pad = pretty ? String(repeating: " ", count: indent * 2) : ""
        let innerPad = pretty ? String(repeating: " ", count: (indent + 1) * 2) : ""
        let newline = pretty ? "\n" : ""
        let colon = pretty ? ": " : ":"

        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let text):
            output += text
        case .string(let text):
            output += JSONValue.quote(text)
        case .array(let values):
            if values.isEmpty {
                output += "[]"
                return
            }
            output += "[" + newline
            for (offset, value) in values.enumerated() {
                output += innerPad
                value.write(to: &output, indent: indent + 1, pretty: pretty)
                if offset < values.count - 1 { output += "," }
                output += newline
            }
            output += pad + "]"
        case .object(let pairs):
            if pairs.isEmpty {
                output += "{}"
                return
            }
            output += "{" + newline
            for (offset, pair) in pairs.enumerated() {
                output += innerPad + JSONValue.quote(pair.key) + colon
                pair.value.write(to: &output, indent: indent + 1, pretty: pretty)
                if offset < pairs.count - 1 { output += "," }
                output += newline
            }
            output += pad + "}"
        }
    }

    /// Escapes only what JSON requires. Notably forward slashes are left alone,
    /// so file paths stay readable instead of turning into `\/Users\/...`.
    static func quote(_ text: String) -> String {
        var result = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if character.value < 0x20 {
                    result += String(format: "\\u%04x", character.value)
                } else {
                    result.unicodeScalars.append(character)
                }
            }
        }
        return result + "\""
    }
}
