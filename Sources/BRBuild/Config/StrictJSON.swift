/// Any JSON value, as ``StrictJSON`` reads it. Numbers keep their written form: an integer
/// literal (`325`) is ``integer``; one with a fraction or an exponent (`325.0`, `3.25e2`) is
/// ``number``, so the two never compare equal.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    enum Difference: Equatable {
        case unknownKey(String)
        case changed(String)
    }

    /// The first place, in key order, where `self` (what was read) differs from `other` (the
    /// decoded value re-encoded). A `null` in `self` matches an absent key.
    func firstDifference(from other: JSONValue, path: String) -> Difference? {
        switch (self, other) {
        case (.object(let a), .object(let b)):
            for key in a.keys.sorted() {
                let value = a[key]!
                guard let counterpart = b[key] else {
                    if value == .null { continue }
                    return .unknownKey("\(path).\(key)")
                }
                if let difference = value.firstDifference(from: counterpart, path: "\(path).\(key)") { return difference }
            }
            for key in b.keys.sorted() where a[key] == nil { return .changed("\(path).\(key)") }
            return nil
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return .changed(path) }
            for (index, (x, y)) in zip(a, b).enumerated() {
                if let difference = x.firstDifference(from: y, path: "\(path)[\(index)]") { return difference }
            }
            return nil
        default:
            return self == other ? nil : .changed(path)
        }
    }
}

/// A strict JSON reader for the reviewed config sources: RFC 8259 syntax over UTF-8 bytes, no
/// key twice in one object, number forms kept (``JSONValue``).
///
/// `JSONDecoder` can't be the reference here: it keeps the first of two equal keys without a
/// word, and reads `325.0` and `3.25e2` into an `Int` as 325, so a comparison of two
/// JSONDecoder-built trees can't see either. Keys are compared after unescaping (`"a"` and
/// `"a"` are the same key). Pure Swift, so it reads the same on every platform.
struct StrictJSON {
    enum Failure: Error, Equatable {
        /// `path` in ``JSONValue/firstDifference(from:path:)``'s notation (`$.a[2].b`); `line`
        /// is the 1-based line of the second occurrence.
        case duplicateKey(path: String, line: Int)
        case syntax(line: Int, column: Int, message: String)
    }

    /// Deeper nesting is refused (the config sources nest about five levels).
    static let maxDepth = 64

    static func parse(_ bytes: some Collection<UInt8>) throws -> JSONValue {
        var reader = StrictJSON(bytes: Array(bytes))
        if reader.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { throw reader.failure("starts with a byte-order mark") }
        let value = try reader.value(path: "$", depth: 0)
        reader.skipWhitespace()
        guard reader.index == reader.bytes.count else { throw reader.failure("unexpected text after the JSON value") }
        return value
    }

    private let bytes: [UInt8]
    private var index = 0

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func value(path: String, depth: Int) throws -> JSONValue {
        skipWhitespace()
        guard let byte = current else { throw failure("unexpected end of input") }
        switch byte {
        case UInt8(ascii: "{"): return try object(path: path, depth: depth)
        case UInt8(ascii: "["): return try array(path: path, depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
        default: throw failure("unexpected character")
        }
    }

    private mutating func object(path: String, depth: Int) throws -> JSONValue {
        guard depth < Self.maxDepth else { throw failure("nested deeper than \(Self.maxDepth) levels") }
        index += 1
        var members: [String: JSONValue] = [:]
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else { throw failure("expected a key string") }
            let keyLine = position().line
            let key = try string()
            let keyPath = "\(path).\(key)"
            guard members[key] == nil else { throw Failure.duplicateKey(path: keyPath, line: keyLine) }
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { throw failure("expected ':' after a key") }
            index += 1
            members[key] = try value(path: keyPath, depth: depth + 1)
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(members)
            default: throw failure("expected ',' or '}' in an object")
            }
        }
    }

    private mutating func array(path: String, depth: Int) throws -> JSONValue {
        guard depth < Self.maxDepth else { throw failure("nested deeper than \(Self.maxDepth) levels") }
        index += 1
        var elements: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            elements.append(try value(path: "\(path)[\(elements.count)]", depth: depth + 1))
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(elements)
            default: throw failure("expected ',' or ']' in an array")
            }
        }
    }

    /// A string starting at the opening quote; escapes resolved, UTF-8 checked.
    private mutating func string() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while true {
            guard let byte = current else { throw failure("unterminated string") }
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                let text = String(decoding: buffer, as: UTF8.self)
                // Invalid UTF-8 decodes to U+FFFD, so it doesn't survive the round trip.
                guard text.utf8.elementsEqual(buffer) else { throw failure("a string is not valid UTF-8") }
                return text
            case UInt8(ascii: "\\"):
                index += 1
                guard let escape = current else { throw failure("unterminated string") }
                index += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): buffer.append(escape)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    let scalar = try unicodeEscape()
                    UTF8.encode(scalar) { buffer.append($0) }
                default:
                    index -= 1
                    throw failure("invalid escape")
                }
            case 0x00..<0x20:
                throw failure("unescaped control character in a string")
            default:
                buffer.append(byte)
                index += 1
            }
        }
    }

    /// The scalar of a `\uXXXX` escape (the `\u` already read), joining a surrogate pair.
    private mutating func unicodeEscape() throws -> Unicode.Scalar {
        let first = try hex4()
        switch first {
        case 0xD800...0xDBFF:
            guard current == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") else {
                throw failure("unpaired surrogate escape")
            }
            index += 2
            let second = try hex4()
            guard (0xDC00...0xDFFF).contains(second) else { throw failure("unpaired surrogate escape") }
            let value = 0x10000 + ((UInt32(first) - 0xD800) << 10) + (UInt32(second) - 0xDC00)
            return Unicode.Scalar(value)!
        case 0xDC00...0xDFFF:
            throw failure("unpaired surrogate escape")
        default:
            return Unicode.Scalar(first)!
        }
    }

    private mutating func hex4() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw failure("a \\u escape needs four hex digits") }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw failure("a \\u escape needs four hex digits")
            }
            value = value << 4 | UInt16(digit)
            index += 1
        }
        return value
    }

    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
    private mutating func number() throws -> JSONValue {
        let start = index
        func isDigit(_ byte: UInt8?) -> Bool { byte.map { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } ?? false }
        if current == UInt8(ascii: "-") { index += 1 }
        guard isDigit(current) else { throw failure("expected a digit") }
        if current == UInt8(ascii: "0") {
            index += 1
            if isDigit(current) { throw failure("a number has a leading zero") }
        } else {
            while isDigit(current) { index += 1 }
        }
        var integral = true
        if current == UInt8(ascii: ".") {
            integral = false
            index += 1
            guard isDigit(current) else { throw failure("expected a digit after '.'") }
            while isDigit(current) { index += 1 }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            integral = false
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
            guard isDigit(current) else { throw failure("expected a digit in the exponent") }
            while isDigit(current) { index += 1 }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if integral, let value = Int64(text) { return .integer(value) }
        guard let value = Double(text), value.isFinite else { throw failure("number \(text) is out of range") }
        return .number(value)
    }

    private mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard bytes[index...].starts(with: expected) else { throw failure("unexpected character") }
        index += expected.count
    }

    mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
    }

    /// 1-based line and column (in bytes) of ``index``.
    private func position() -> (line: Int, column: Int) {
        var line = 1, lineStart = 0
        for (offset, byte) in bytes[..<min(index, bytes.count)].enumerated() where byte == 0x0A {
            line += 1
            lineStart = offset + 1
        }
        return (line, index - lineStart + 1)
    }

    private func failure(_ message: String) -> Failure {
        let (line, column) = position()
        return .syntax(line: line, column: column, message: message)
    }
}
