/// Constants shared by the `stations` artifact writer (BRBuild `StationsArtifactWriter`) and
/// reader (``MappedStations``). The byte layout is specified in `docs/formats.md`.
public enum StationsFormat {
    /// The first four payload bytes, `STNS`.
    public static let payloadMagic: [UInt8] = Array("STNS".utf8)
    /// Revision of the draft payload layout, bumped on every change while the artifact's
    /// formatVersion is still 0. Readers reject any other revision.
    public static let draftRevision: UInt32 = 1
    /// Matrix value for a pair with no bike path, or one longer than 655,340 m.
    public static let unreachable: UInt16 = .max
    /// The largest storable distance, in decameters.
    public static let maxDecameters: UInt16 = .max - 1
    /// Snap segment value for a station that did not snap.
    public static let noSegment: UInt32 = .max
    /// Values in the matrix-profile array: speed, dismount speed, then the four bike-class
    /// multipliers in ``BikeClass`` order.
    static let profileValueCount = 6
}

/// Per-station attribute bits.
public struct StationFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The feed marked the station as charging e-bikes (`is_charging` / `is_charging_station`).
    public static let charging = StationFlags(rawValue: 1 << 0)
    /// The feed gave no `region_id`; the station was kept because it lies inside the five boroughs.
    public static let acceptedByArea = StationFlags(rawValue: 1 << 1)
    /// The station snapped to a rideable segment; its matrix row and column are meaningful.
    public static let bikeSnapped = StationFlags(rawValue: 1 << 2)
    /// The station snapped to a walkable segment.
    public static let walkSnapped = StationFlags(rawValue: 1 << 3)

    static let known: StationFlags = [.charging, .acceptedByArea, .bikeSnapped, .walkSnapped]
}

/// A malformed or incompatible `stations` payload.
public enum StationsFormatError: Error, Equatable, Sendable {
    case badPayloadMagic
    case unsupportedDraftRevision(UInt32)
    case unsupportedFormatVersion(UInt16)
    case countMismatch(section: String, expected: Int, actual: Int)
    case valueOutOfRange(section: String, index: Int)
    case notMonotonic(section: String, index: Int)
    /// The id-sorted index must list ids strictly ascending by their UTF-8 bytes (so they are unique).
    case idsNotSorted(index: Int)
    case trailingBytes(Int)
}
