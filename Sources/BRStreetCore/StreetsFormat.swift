import BRGeo
import Foundation

/// Constants and small value types shared by the `streets` artifact writer (BRBuild) and
/// reader (``MappedStreetGraph``). The byte layout is specified in `docs/formats.md`.
public enum StreetsFormat {
    /// The first four payload bytes, `STRT`.
    public static let payloadMagic: [UInt8] = Array("STRT".utf8)
    /// Revision of the draft payload layout, bumped on every change while the artifact's
    /// formatVersion is still 0. Readers reject any other revision. Revision 2 added the New
    /// Jersey service-area regions; revision 3 narrowed them to Jersey City and Hoboken and widened
    /// region codes to `u32` (Census place GEOIDs).
    public static let draftRevision: UInt32 = 3
    /// Set in ``MappedStreetGraph/segment(ofEdge:)`` codes when an edge runs from the segment's
    /// end (B) back to its start (A).
    public static let reversedSegmentBit: UInt32 = 1 << 31
    /// Millionths of a degree per degree.
    public static let microdegreesPerDegree = 1_000_000.0
    /// Bearings are stored in 256ths of a full turn.
    public static let bearingUnitsPerTurn = 256.0

    /// Microdegrees for a coordinate component, rounded to nearest.
    @inline(__always)
    public static func microdegrees(_ degrees: Double) -> Int32 {
        Int32((degrees * microdegreesPerDegree).rounded())
    }

    @inline(__always)
    public static func degrees(_ microdegrees: Int32) -> Double {
        Double(microdegrees) / microdegreesPerDegree
    }

    /// A bearing in degrees clockwise from north, quantized to 256ths of a turn.
    @inline(__always)
    public static func bearingCode(degrees: Double) -> UInt8 {
        let units = (degrees / 360 * bearingUnitsPerTurn).rounded()
        return UInt8(truncatingIfNeeded: Int(units) & 0xFF)
    }

    @inline(__always)
    public static func bearingDegrees(code: UInt8) -> Double {
        Double(code) * 360 / bearingUnitsPerTurn
    }
}

/// Where a street name came from.
public enum StreetNameKind: UInt8, Sendable, CaseIterable {
    /// The way's `name` (or, on a bridge, `bridge:name`) tag.
    case tagged = 0
    /// The way's `ref` tag, e.g. `NY 25`.
    case ref = 1
    /// A generic label the compiler derived from the way's type, e.g. `bike path` or `steps`.
    /// Instructions may prefer to describe the way rather than "turn onto" it.
    case derived = 2
}

/// The uniform grid of the snap index, in microdegrees. Cell `(x, y)` covers longitudes
/// `originLon + x·cellLon ..< originLon + (x + 1)·cellLon` and likewise for latitudes; its entry
/// lists every segment whose stored geometry passes through it.
public struct SnapGridGeometry: Sendable, Equatable {
    public let originLatE6: Int32
    public let originLonE6: Int32
    public let cellLatE6: Int32
    public let cellLonE6: Int32
    public let columns: Int
    public let rows: Int

    public init(originLatE6: Int32, originLonE6: Int32, cellLatE6: Int32, cellLonE6: Int32, columns: Int, rows: Int) {
        self.originLatE6 = originLatE6
        self.originLonE6 = originLonE6
        self.cellLatE6 = cellLatE6
        self.cellLonE6 = cellLonE6
        self.columns = columns
        self.rows = rows
    }

    public var cellCount: Int { columns * rows }

    /// The (unclamped) cell column and row containing a position.
    @inline(__always)
    public func cell(latE6: Int64, lonE6: Int64) -> (x: Int, y: Int) {
        let x = floorDivide(lonE6 - Int64(originLonE6), Int64(cellLonE6))
        let y = floorDivide(latE6 - Int64(originLatE6), Int64(cellLatE6))
        return (Int(x), Int(y))
    }

    public func cell(containing coordinate: Coordinate) -> (x: Int, y: Int) {
        let lat = Int64((max(-90, min(90, coordinate.lat)) * StreetsFormat.microdegreesPerDegree).rounded(.down))
        let lon = Int64((max(-180, min(180, coordinate.lon)) * StreetsFormat.microdegreesPerDegree).rounded(.down))
        return cell(latE6: lat, lonE6: lon)
    }

    /// Meters spanned by one cell north–south and east–west at `latitude`.
    public func cellSizeMeters(atLatitude latitude: Double) -> (northSouth: Double, eastWest: Double) {
        let metersPerDegree = Earth.meanRadiusMeters * .pi / 180
        let ns = Double(cellLatE6) / StreetsFormat.microdegreesPerDegree * metersPerDegree
        let ew = Double(cellLonE6) / StreetsFormat.microdegreesPerDegree * metersPerDegree * cos(latitude * .pi / 180)
        return (ns, ew)
    }

    @inline(__always)
    private func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}

/// A named area stored in the artifact: each NYC borough, keyed by its DCP borough code, and the
/// New Jersey municipalities in the service area, keyed by their Census place GEOID.
public struct StreetRegion: Sendable, Equatable {
    /// NYC DCP borough code: 1 Manhattan, 2 Bronx, 3 Brooklyn, 4 Queens, 5 Staten Island; or a
    /// New Jersey Census place GEOID (state FIPS 34 + place code): 3432250 Hoboken, 3436000
    /// Jersey City.
    public let code: UInt32
    public let name: String
    public let area: MultiPolygon

    public init(code: UInt32, name: String, area: MultiPolygon) {
        self.code = code
        self.name = name
        self.area = area
    }

    public static let manhattanCode: UInt32 = 1
    public static let nycBoroughCodes: ClosedRange<UInt32> = 1...5
    public static let hobokenCode: UInt32 = 3432250
    public static let jerseyCityCode: UInt32 = 3436000

    public var isNYCBorough: Bool { Self.nycBoroughCodes.contains(code) }
}

/// A malformed or incompatible `streets` payload.
public enum StreetsFormatError: Error, Equatable, Sendable {
    case badPayloadMagic
    case unsupportedDraftRevision(UInt32)
    case unsupportedFormatVersion(UInt16)
    case countMismatch(section: String, expected: Int, actual: Int)
    case valueOutOfRange(section: String, index: Int)
    case notMonotonic(section: String, index: Int)
    case trailingBytes(Int)
    case invalidGrid
}
