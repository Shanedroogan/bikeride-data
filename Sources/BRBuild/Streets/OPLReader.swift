/// A streaming reader for the OSM OPL text format as written by
/// `osmium cat -f opl,add_metadata=false,locations_on_ways=true`, yielding ways with their
/// tags and inline node locations.
///
/// Works on bytes: tag keys and values are byte ranges into the current line, so no `String` is
/// made unless a caller decodes one (``OPLWay/decodedValue(_:)``). Node and relation lines are
/// skipped. Lines are read from any ``ByteChunkSource`` (e.g. an `osmium` pipe).
///
/// OPL escapes a character as `%<hex code point>%`; see <https://osmcode.org/opl-file-format/>.
public struct OPLReader<Source: ByteChunkSource> {
    private var source: Source
    private var pending: [UInt8] = []
    private var finished = false

    // Per-way scratch, reused across lines.
    private var tags: [OPLTag] = []
    private var nodeIDs: [Int64] = []
    private var latE7: [Int32] = []
    private var lonE7: [Int32] = []

    /// Way lines seen, including ones rejected by the callback.
    public private(set) var wayCount = 0
    /// Way nodes without a location (outside the extract), which are left out of their way.
    public private(set) var nodesWithoutLocation = 0

    public init(_ source: Source) {
        self.source = source
    }

    /// Calls `body` once per way, in input order. The way's buffers are valid only during the call.
    public mutating func forEachWay(_ body: (OPLWay) throws -> Void) throws {
        while !finished {
            guard let chunk = try source.nextChunk() else {
                finished = true
                if !pending.isEmpty {
                    let line = pending
                    pending.removeAll()
                    try line.withUnsafeBufferPointer { try handle(line: $0, body) }
                }
                break
            }
            var bytes: [UInt8] = []
            swap(&bytes, &pending)
            bytes.append(contentsOf: chunk)
            let consumed = try bytes.withUnsafeBufferPointer { buffer -> Int in
                var lineStart = 0
                var index = 0
                let count = buffer.count
                while index < count {
                    if buffer[index] == UInt8(ascii: "\n") {
                        try handle(line: UnsafeBufferPointer(rebasing: buffer[lineStart..<index]), body)
                        lineStart = index + 1
                    }
                    index += 1
                }
                return lineStart
            }
            // Keep the unfinished last line; reuse the big buffer when nothing is left over.
            if consumed == bytes.count {
                bytes.removeAll(keepingCapacity: true)
                pending = bytes
            } else {
                pending = Array(bytes[consumed...])
            }
        }
    }

    private mutating func handle(line: UnsafeBufferPointer<UInt8>, _ body: (OPLWay) throws -> Void) throws {
        var end = line.count
        if end > 0 && line[end - 1] == UInt8(ascii: "\r") { end -= 1 }
        guard end > 1, line[0] == UInt8(ascii: "w") else { return }
        wayCount += 1
        tags.removeAll(keepingCapacity: true)
        nodeIDs.removeAll(keepingCapacity: true)
        latE7.removeAll(keepingCapacity: true)
        lonE7.removeAll(keepingCapacity: true)

        var position = 1
        guard let id = OPLNumbers.integer(line, &position, end: end) else {
            throw OPLError.malformedLine(wayCount: wayCount)
        }
        // Fields: ` X...` separated by single spaces.
        while position < end {
            guard line[position] == UInt8(ascii: " ") else { throw OPLError.malformedLine(wayCount: wayCount) }
            position += 1
            guard position < end else { break }
            let kind = line[position]
            position += 1
            var fieldEnd = position
            while fieldEnd < end && line[fieldEnd] != UInt8(ascii: " ") { fieldEnd += 1 }
            switch kind {
            case UInt8(ascii: "T"):
                parseTags(line, from: position, to: fieldEnd)
            case UInt8(ascii: "N"):
                try parseNodes(line, from: position, to: fieldEnd)
            default:
                break
            }
            position = fieldEnd
        }

        try tags.withUnsafeBufferPointer { tagBuffer in
            try nodeIDs.withUnsafeBufferPointer { ids in
                try latE7.withUnsafeBufferPointer { lats in
                    try lonE7.withUnsafeBufferPointer { lons in
                        try body(OPLWay(id: id, line: line, tags: tagBuffer, nodeIDs: ids, latE7: lats, lonE7: lons))
                    }
                }
            }
        }
    }

    private mutating func parseTags(_ line: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) {
        var index = start
        while index < end {
            var separator = index
            while separator < end && line[separator] != UInt8(ascii: "=") && line[separator] != UInt8(ascii: ",") {
                separator += 1
            }
            var valueEnd = separator
            if separator < end && line[separator] == UInt8(ascii: "=") {
                valueEnd = separator + 1
                while valueEnd < end && line[valueEnd] != UInt8(ascii: ",") { valueEnd += 1 }
                tags.append(OPLTag(keyStart: Int32(index), keyEnd: Int32(separator), valueStart: Int32(separator + 1), valueEnd: Int32(valueEnd)))
            }
            index = valueEnd + 1
        }
    }

    private mutating func parseNodes(_ line: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) throws {
        var index = start
        while index < end {
            guard line[index] == UInt8(ascii: "n") else { throw OPLError.malformedLine(wayCount: wayCount) }
            index += 1
            guard let id = OPLNumbers.integer(line, &index, end: end) else { throw OPLError.malformedLine(wayCount: wayCount) }
            var lon: Int32?, lat: Int32?
            if index < end && line[index] == UInt8(ascii: "x") {
                index += 1
                lon = OPLNumbers.degreesE7(line, &index, end: end)
            }
            if index < end && line[index] == UInt8(ascii: "y") {
                index += 1
                lat = OPLNumbers.degreesE7(line, &index, end: end)
            }
            // Skip anything else up to the next reference.
            while index < end && line[index] != UInt8(ascii: ",") { index += 1 }
            index += 1
            if let lat, let lon {
                nodeIDs.append(id)
                latE7.append(lat)
                lonE7.append(lon)
            } else {
                nodesWithoutLocation += 1
            }
        }
    }
}

/// One tag's key and value, as byte ranges into the line (still OPL-escaped).
public struct OPLTag: Sendable {
    let keyStart: Int32
    let keyEnd: Int32
    let valueStart: Int32
    let valueEnd: Int32
}

/// A way from ``OPLReader``, viewing the reader's buffers. Valid only inside the callback.
public struct OPLWay {
    public let id: Int64
    let line: UnsafeBufferPointer<UInt8>
    public let tags: UnsafeBufferPointer<OPLTag>
    public let nodeIDs: UnsafeBufferPointer<Int64>
    /// Latitudes in 10⁻⁷ degrees, the precision OSM stores.
    public let latE7: UnsafeBufferPointer<Int32>
    public let lonE7: UnsafeBufferPointer<Int32>

    public func key(_ tag: OPLTag) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: line[Int(tag.keyStart)..<Int(tag.keyEnd)])
    }

    public func value(_ tag: OPLTag) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: line[Int(tag.valueStart)..<Int(tag.valueEnd)])
    }

    /// The value with OPL escapes decoded.
    public func decodedValue(_ tag: OPLTag) -> String {
        OPLNumbers.unescape(value(tag))
    }
}

public enum OPLError: Error, Equatable, Sendable {
    case malformedLine(wayCount: Int)
}

enum OPLNumbers {
    /// An optionally negative decimal integer; advances `index` past it.
    static func integer(_ bytes: UnsafeBufferPointer<UInt8>, _ index: inout Int, end: Int) -> Int64? {
        var negative = false
        if index < end && bytes[index] == UInt8(ascii: "-") {
            negative = true
            index += 1
        }
        let start = index
        var value: Int64 = 0
        while index < end {
            let digit = bytes[index] &- UInt8(ascii: "0")
            guard digit < 10 else { break }
            value = value &* 10 &+ Int64(digit)
            index += 1
        }
        guard index > start, index - start <= 18 else { return nil }
        return negative ? -value : value
    }

    /// A decimal degree value (e.g. `-73.9892384`) in units of 10⁻⁷ degrees, truncating any
    /// further digits. `nil` if empty or malformed.
    static func degreesE7(_ bytes: UnsafeBufferPointer<UInt8>, _ index: inout Int, end: Int) -> Int32? {
        var negative = false
        if index < end && bytes[index] == UInt8(ascii: "-") {
            negative = true
            index += 1
        }
        let start = index
        var whole: Int64 = 0
        while index < end, case let digit = bytes[index] &- UInt8(ascii: "0"), digit < 10 {
            whole = whole * 10 + Int64(digit)
            index += 1
            guard whole <= 1000 else { return nil }
        }
        var fraction: Int64 = 0
        var fractionDigits = 0
        if index < end && bytes[index] == UInt8(ascii: ".") {
            index += 1
            while index < end, case let digit = bytes[index] &- UInt8(ascii: "0"), digit < 10 {
                if fractionDigits < 7 {
                    fraction = fraction * 10 + Int64(digit)
                    fractionDigits += 1
                }
                index += 1
            }
        }
        guard index > start else { return nil }
        while fractionDigits < 7 {
            fraction *= 10
            fractionDigits += 1
        }
        let value = whole * 10_000_000 + fraction
        guard value <= 1_800_000_000 else { return nil }
        return Int32(negative ? -value : value)
    }

    /// Decodes `%<hex>%` escapes to their Unicode scalars; other bytes are UTF-8 as is.
    static func unescape(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        guard bytes.contains(UInt8(ascii: "%")) else { return String(decoding: bytes, as: UTF8.self) }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%") {
                var cursor = index + 1
                var scalar: UInt32 = 0
                var digits = 0
                while cursor < bytes.count, let nibble = hexValue(bytes[cursor]), digits < 8 {
                    scalar = scalar << 4 | UInt32(nibble)
                    digits += 1
                    cursor += 1
                }
                if digits > 0, cursor < bytes.count, bytes[cursor] == UInt8(ascii: "%"), let decoded = Unicode.Scalar(scalar) {
                    out.append(contentsOf: Array(String(Character(decoded)).utf8))
                    index = cursor + 1
                    continue
                }
            }
            out.append(byte)
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
