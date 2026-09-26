import BRCore

/// Byte-level parsers for GTFS field values. None allocates.
enum GTFSField {
    @inline(__always)
    static func isBlank(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

    /// The field without surrounding spaces and tabs.
    @inline(__always)
    static func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var start = bytes.startIndex, end = bytes.endIndex
        while start < end, isBlank(bytes[start]) { start += 1 }
        while end > start, isBlank(bytes[end - 1]) { end -= 1 }
        return bytes[start..<end]
    }

    /// `H:MM:SS` (hours may exceed 23 and have any number of digits) → seconds, or `nil` when
    /// empty or malformed.
    @inline(__always)
    static func time(_ raw: ArraySlice<UInt8>) -> UInt32? {
        let bytes = trimmed(raw)
        guard !bytes.isEmpty else { return nil }
        var parts: (UInt32, UInt32, UInt32) = (0, 0, 0)
        var part = 0
        var digits = 0
        for byte in bytes {
            if byte == UInt8(ascii: ":") {
                guard digits > 0, part < 2 else { return nil }
                part += 1
                digits = 0
                continue
            }
            guard byte >= 48, byte <= 57, digits < 6 else { return nil }
            let digit = UInt32(byte - 48)
            switch part {
            case 0: parts.0 = parts.0 * 10 + digit
            case 1: parts.1 = parts.1 * 10 + digit
            default: parts.2 = parts.2 * 10 + digit
            }
            digits += 1
        }
        guard part == 2, digits > 0, parts.1 < 60, parts.2 < 60 else { return nil }
        return parts.0 * 3600 + parts.1 * 60 + parts.2
    }

    /// A decimal number of degrees → microdegrees, rounded half away from zero. Accepts an
    /// optional sign and surrounding blanks; `nil` when empty or malformed.
    static func microdegrees(_ raw: ArraySlice<UInt8>) -> Int32? {
        let bytes = trimmed(raw)
        guard !bytes.isEmpty else { return nil }
        var index = bytes.startIndex
        var negative = false
        if bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
            negative = bytes[index] == UInt8(ascii: "-")
            index += 1
        }
        var integer: Int64 = 0
        var fraction: Int64 = 0
        var fractionDigits = 0
        var roundUp = false
        var sawDigit = false
        var inFraction = false
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: ".") {
                guard !inFraction else { return nil }
                inFraction = true
                continue
            }
            guard byte >= 48, byte <= 57 else { return nil }
            sawDigit = true
            let digit = Int64(byte - 48)
            if !inFraction {
                integer = integer * 10 + digit
                guard integer <= 1000 else { return nil }
            } else if fractionDigits < 6 {
                fraction = fraction * 10 + digit
                fractionDigits += 1
            } else if fractionDigits == 6 {
                roundUp = digit >= 5
                fractionDigits += 1
            }
        }
        guard sawDigit else { return nil }
        while fractionDigits < 6 {
            fraction *= 10
            fractionDigits += 1
        }
        var value = integer * 1_000_000 + fraction + (roundUp ? 1 : 0)
        if negative { value = -value }
        return Int32(value)
    }

    /// A non-negative decimal integer with optional blanks; `nil` when empty or malformed.
    @inline(__always)
    static func int(_ raw: ArraySlice<UInt8>) -> Int? {
        let bytes = trimmed(raw)
        guard !bytes.isEmpty, bytes.count <= 18 else { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= 48, byte <= 57 else { return nil }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }

    /// `RRGGBB` (optionally with `#`) → `0xRRGGBB`; `nil` when empty or malformed.
    static func color(_ raw: ArraySlice<UInt8>) -> UInt32? {
        var bytes = trimmed(raw)
        if bytes.first == UInt8(ascii: "#") { bytes = bytes.dropFirst() }
        guard bytes.count == 6 else { return nil }
        var value: UInt32 = 0
        for byte in bytes {
            let nibble: UInt8
            switch byte {
            case 48...57: nibble = byte - 48
            case 65...70: nibble = byte - 55
            case 97...102: nibble = byte - 87
            default: return nil
            }
            value = value << 4 | UInt32(nibble)
        }
        return value
    }

    /// `YYYYMMDD` → days since 1970-01-01.
    static func day(_ raw: ArraySlice<UInt8>) -> Int32? {
        ServiceDate(yyyymmddBytes: trimmed(raw)).map { Int32($0.daysSinceEpoch) }
    }

    static func string(_ raw: ArraySlice<UInt8>) -> String {
        String(decoding: trimmed(raw), as: UTF8.self)
    }
}
