import Foundation

/// A streaming RFC 4180 CSV reader that works on bytes.
///
/// - Quoted fields may contain commas, line breaks and doubled quotes (`""` → `"`).
/// - Records end at LF, CRLF or a lone CR. A final record without a line break is still read.
/// - A leading UTF-8 byte order mark is skipped.
/// - Blank lines are skipped. A quote inside an unquoted field is kept literally.
///
/// Records are returned as byte slices; no `String` is made unless a caller asks for one. The
/// reader reuses its buffers, so a record costs no allocation once the caller drops the
/// previous one.
public struct CSVReader<Source: ByteChunkSource> {
    private enum State {
        case fieldStart, unquoted, quoted, quoteInQuoted
    }

    private var source: Source
    private var chunk: [UInt8] = []
    private var position = 0
    private var started = false
    private var finished = false
    private var state = State.fieldStart
    private var skipLineFeed = false
    private var record = CSVRecord()
    /// Records returned so far, counting the header. Errors report the 1-based record number.
    public private(set) var recordCount = 0

    public init(_ source: Source) {
        self.source = source
    }

    public mutating func next() throws -> CSVRecord? {
        guard !finished else { return nil }
        if !started {
            try loadFirstChunk()
            started = true
        }
        record.reset()
        state = .fieldStart
        while true {
            if position == chunk.count {
                if let next = try source.nextChunk() {
                    chunk = next
                    position = 0
                    continue
                }
                finished = true
                return try recordAtEndOfInput()
            }
            if try scanToEndOfRecord() {
                recordCount += 1
                return record
            }
        }
    }

    /// Buffers enough input to recognize a byte order mark split across chunks.
    private mutating func loadFirstChunk() throws {
        var first: [UInt8] = []
        while first.count < 3, let next = try source.nextChunk() {
            first.append(contentsOf: next)
        }
        if first.starts(with: [0xEF, 0xBB, 0xBF]) { first.removeFirst(3) }
        chunk = first
        position = 0
    }

    /// Consumes bytes from the current chunk. Returns `true` once a record is complete.
    private mutating func scanToEndOfRecord() throws -> Bool {
        let bytes = chunk
        var index = position
        defer { position = index }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if skipLineFeed {
                skipLineFeed = false
                if byte == ASCII.lf { continue }
            }
            switch state {
            case .fieldStart:
                switch byte {
                case ASCII.quote:
                    state = .quoted
                case ASCII.comma:
                    record.endField()
                case ASCII.lf, ASCII.cr:
                    skipLineFeed = byte == ASCII.cr
                    if record.count == 0 { continue } // blank line
                    record.endField()
                    return true
                default:
                    record.append(byte)
                    state = .unquoted
                }
            case .unquoted:
                switch byte {
                case ASCII.comma:
                    record.endField()
                    state = .fieldStart
                case ASCII.lf, ASCII.cr:
                    skipLineFeed = byte == ASCII.cr
                    record.endField()
                    return true
                default:
                    record.append(byte)
                }
            case .quoted:
                if byte == ASCII.quote {
                    state = .quoteInQuoted
                } else {
                    record.append(byte)
                }
            case .quoteInQuoted:
                switch byte {
                case ASCII.quote:
                    record.append(byte)
                    state = .quoted
                case ASCII.comma:
                    record.endField()
                    state = .fieldStart
                case ASCII.lf, ASCII.cr:
                    skipLineFeed = byte == ASCII.cr
                    record.endField()
                    return true
                default:
                    throw CSVError.unexpectedByteAfterQuote(record: recordCount + 1)
                }
            }
        }
        return false
    }

    private mutating func recordAtEndOfInput() throws -> CSVRecord? {
        switch state {
        case .quoted:
            throw CSVError.unterminatedQuote(record: recordCount + 1)
        case .fieldStart where record.count == 0:
            return nil
        case .fieldStart, .unquoted, .quoteInQuoted:
            record.endField()
            recordCount += 1
            return record
        }
    }
}

extension CSVReader where Source == DataChunkSource {
    public init(bytes: some Sequence<UInt8>, chunkSize: Int = 1 << 16) {
        self.init(DataChunkSource(Data(bytes), chunkSize: chunkSize))
    }
}

/// One CSV record. Fields index from 0; reading past the last field yields an empty field, as
/// some GTFS producers drop trailing empty columns.
public struct CSVRecord: Sendable {
    private var bytes: [UInt8] = []
    private var fieldEnds: [Int] = []

    public var count: Int { fieldEnds.count }

    public subscript(index: Int) -> CSVField {
        guard index >= 0, index < fieldEnds.count else { return CSVField(bytes: []) }
        let start = index == 0 ? 0 : fieldEnds[index - 1]
        return CSVField(bytes: bytes[start..<fieldEnds[index]])
    }

    public var fields: [CSVField] { (0..<count).map { self[$0] } }

    mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
        fieldEnds.removeAll(keepingCapacity: true)
    }

    @inline(__always) mutating func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    @inline(__always) mutating func endField() {
        fieldEnds.append(bytes.count)
    }
}

/// A field's unescaped bytes.
public struct CSVField: Hashable, Sendable {
    public let bytes: ArraySlice<UInt8>

    public var isEmpty: Bool { bytes.isEmpty }

    /// Decodes as UTF-8, replacing invalid sequences.
    public var string: String { String(decoding: bytes, as: UTF8.self) }

    /// Parses an optionally signed ASCII decimal integer; `nil` if empty, malformed or out of range.
    public func int() -> Int? {
        var digits = bytes[...]
        var negative = false
        if let sign = digits.first, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") {
            negative = sign == UInt8(ascii: "-")
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty else { return nil }
        var value = 0
        for byte in digits {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            let digit = Int(byte - UInt8(ascii: "0"))
            let (shifted, o1) = value.multipliedReportingOverflow(by: 10)
            let (next, o2) = negative ? shifted.subtractingReportingOverflow(digit) : shifted.addingReportingOverflow(digit)
            guard !o1, !o2 else { return nil }
            value = next
        }
        return value
    }

    /// Byte-wise comparison with a string's UTF-8, without allocating.
    public static func == (field: CSVField, string: String) -> Bool {
        field.bytes.elementsEqual(string.utf8)
    }
}

public enum CSVError: Error, Equatable, Sendable {
    case unterminatedQuote(record: Int)
    case unexpectedByteAfterQuote(record: Int)
    case missingColumn(String)
}

private enum ASCII {
    static let lf = UInt8(ascii: "\n")
    static let cr = UInt8(ascii: "\r")
    static let quote = UInt8(ascii: "\"")
    static let comma = UInt8(ascii: ",")
}
