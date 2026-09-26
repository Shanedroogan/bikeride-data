/// Google's encoded polyline algorithm, at precision 5 (Google) or 6 (OSRM/Valhalla).
public enum Polyline {
    public enum DecodingError: Error, Equatable {
        case invalidCharacter(offset: Int)
        case truncated
        case missingLongitude
        case valueTooLarge(offset: Int)
    }

    public static func encode(_ coordinates: [Coordinate], precision: Int = 5) -> String {
        let factor = scale(precision)
        var output: [UInt8] = []
        output.reserveCapacity(coordinates.count * 8)
        var previousLat = 0, previousLon = 0
        for c in coordinates {
            let lat = Int((c.lat * factor).rounded())
            let lon = Int((c.lon * factor).rounded())
            append(lat - previousLat, to: &output)
            append(lon - previousLon, to: &output)
            previousLat = lat
            previousLon = lon
        }
        return String(decoding: output, as: UTF8.self)
    }

    public static func decode(_ encoded: String, precision: Int = 5) throws(DecodingError) -> [Coordinate] {
        let factor = scale(precision)
        let bytes = Array(encoded.utf8)
        var coordinates: [Coordinate] = []
        var offset = 0
        var lat = 0, lon = 0
        while offset < bytes.count {
            lat += try value(in: bytes, at: &offset)
            guard offset < bytes.count else { throw .missingLongitude }
            lon += try value(in: bytes, at: &offset)
            coordinates.append(Coordinate(lat: Double(lat) / factor, lon: Double(lon) / factor))
        }
        return coordinates
    }

    private static func scale(_ precision: Int) -> Double {
        precondition((0...9).contains(precision), "Unsupported polyline precision \(precision)")
        var factor = 1.0
        for _ in 0..<precision { factor *= 10 }
        return factor
    }

    private static func append(_ value: Int, to output: inout [UInt8]) {
        var remaining = UInt(bitPattern: value < 0 ? ~(value << 1) : value << 1)
        while remaining >= 0x20 {
            output.append(UInt8(0x20 | (remaining & 0x1F)) + 63)
            remaining >>= 5
        }
        output.append(UInt8(remaining) + 63)
    }

    private static func value(in bytes: [UInt8], at offset: inout Int) throws(DecodingError) -> Int {
        var result: UInt = 0
        var shift: UInt = 0
        while true {
            guard offset < bytes.count else { throw .truncated }
            let byte = bytes[offset]
            guard (63...126).contains(byte) else { throw .invalidCharacter(offset: offset) }
            guard shift < 60 else { throw .valueTooLarge(offset: offset) }
            let chunk = UInt(byte - 63)
            result |= (chunk & 0x1F) << shift
            shift += 5
            offset += 1
            if chunk < 0x20 { break }
        }
        let magnitude = Int(bitPattern: result >> 1)
        return result & 1 == 0 ? magnitude : ~magnitude
    }
}
