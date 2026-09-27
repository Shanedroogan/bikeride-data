import BRCore

/// Layout constants for the `flows` payload (kind 8). The byte layout is documented in
/// `docs/formats.md` ("flows"); this file and that section must change together.
///
/// The payload is sectioned like the timetables: a preamble, a table of contents, then one array
/// per section. Unlike `tt-*`, the payload revision sits in the preamble (right after the magic),
/// like the fixed-layout kinds.
public enum FlowsFormat {
    /// ASCII `FLOW`, the first four payload bytes.
    public static let magic: [UInt8] = Array("FLOW".utf8)
    /// The payload's `u32` revision: `1` in format 1, and readers require exactly this value
    /// (`docs/formats.md`, "Compatibility"). The format-0 draft had one revision, also 1, and froze
    /// unchanged as format 1 on 2026-09-27.
    public static let payloadRevision: UInt32 = 1
    /// `magic`, `u32 payloadRevision`, `u32 sectionCount`, `u32 0`.
    static let preambleSize = 16
    /// Bytes per table-of-contents entry: `u32 id, u32 elementSize, u64 offset, u64 count`.
    static let tocEntrySize = 24
    /// A reader refuses a table of contents longer than this (a corrupt count).
    static let maxSections = 1_024

    /// Minutes per bin and bins per day. Fixed by the format: a change is a new formatVersion.
    public static let binMinutes = 15
    public static let binsPerDay = 96
    /// Day types, directions, bike types and slots per series, also fixed by the format.
    public static let dayTypeCount = FlowDayType.allCases.count
    public static let directionCount = FlowDirection.allCases.count
    public static let bikeTypeCount = FlowBikeType.allCases.count
    public static let slotCount = FlowSlot.allCases.count
    /// `u16` cells per key: day types × directions × slots × bins (3,840 bytes per key).
    public static let cellsPerKey = dayTypeCount * directionCount * slotCount * binsPerDay
    /// The largest key count: row numbers must fit a `u16` with ``noRow`` to spare.
    public static let maxKeys = Int(UInt16.max) - 1
    /// "No flows row" in a stations → row table (``MappedFlows/rowTable(forKeys:)``).
    public static let noRow = UInt16.max

    /// Index of one cell in the `cells` section: `[key][dayType][direction][slot][bin]`.
    @inline(__always)
    public static func cellIndex(row: Int, dayType: FlowDayType, direction: FlowDirection, slot: FlowSlot, bin: Int) -> Int {
        (((row * dayTypeCount + dayType.index) * directionCount + direction.index) * slotCount + slot.index) * binsPerDay + bin
    }

    /// Index of one entry in the `stationActiveDays` section: `[key][dayType][direction]`.
    @inline(__always)
    public static func activeDaysIndex(row: Int, dayType: FlowDayType, direction: FlowDirection) -> Int {
        (row * dayTypeCount + dayType.index) * directionCount + direction.index
    }
}

/// Section identifiers in the `flows` table of contents. Raw values are permanent.
public enum FlowsSection: UInt32, CaseIterable, Sendable {
    case info = 1               // i64 × FlowsInfoField (readers ignore entries past the ones they know)
    case holidays = 2           // i32 days since 1970-01-01, strictly ascending
    case keyOffsets = 3         // u32 × (keys + 1)
    case keyBytes = 4           // u8: GBFS short_name bytes, strictly ascending by bytes
    case stationLatE6 = 5       // i32 × keys
    case stationLonE6 = 6       // i32 × keys
    case stationCapacity = 7    // u16 × keys
    case stationActiveDays = 8  // u16 × keys × dayTypes × directions
    case stationFlags = 9       // u8 × keys (FlowStationFlags)
    case cells = 10             // u16 IEEE binary16 × keys × FlowsFormat.cellsPerKey

    public var elementSize: Int {
        switch self {
        case .info: 8
        case .holidays, .keyOffsets, .stationLatE6, .stationLonE6: 4
        case .stationCapacity, .stationActiveDays, .cells: 2
        case .keyBytes, .stationFlags: 1
        }
    }
}

/// Positions in the `info` section (`i64` each).
public enum FlowsInfoField: Int, CaseIterable, Sendable {
    /// Days since 1970-01-01 of the first day whose departures are counted.
    case departureWindowStartDay = 0
    case departureWindowDayCount = 1
    /// Days since 1970-01-01 of the first day whose arrivals are counted.
    case arrivalWindowStartDay = 2
    case arrivalWindowDayCount = 3
    /// ``FlowsFormat/binMinutes``, ``FlowsFormat/binsPerDay``, ``FlowsFormat/dayTypeCount``,
    /// ``FlowsFormat/bikeTypeCount`` and ``FlowsFormat/slotCount``: stored so a file describes
    /// itself; readers require exactly the format's values.
    case binMinutes = 4
    case binsPerDay = 5
    case dayTypes = 6
    case bikeTypes = 7
    case slotsPerSeries = 8
    /// ``FlowsInfoFlags``.
    case flags = 9
    /// The smoothing parameters (``FlowSmoothingParameters``); the κs in thousandths.
    case kappaCellMilli = 10
    case kappaHourMilli = 11
    case kappaDispersionMilli = 12
    case neighborCount = 13
    case neighborRadiusMeters = 14
}

/// Whole-file flags (`info.flags`). Writers write undefined bits as 0; readers ignore them.
public struct FlowsInfoFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }

    /// The counts are customer trips only: rebalancing, valet and staff moves are not in the
    /// public trip data (and depot trip ends are dropped), so flows understate station turnover.
    public static let customerTripsOnly = FlowsInfoFlags(rawValue: 1 << 0)
    public static let known: FlowsInfoFlags = [.customerTripsOnly]
}

/// Per-key hint bits (`stationFlags`). Writers write undefined bits as 0; readers ignore them.
public struct FlowStationFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The key was in GBFS `station_information` when the file was built (every key, today: the
    /// key universe is that feed).
    public static let inGBFS = FlowStationFlags(rawValue: 1 << 0)
    /// Fewer trip ends in the window than active days (or no active days): the station's own
    /// counts say little.
    public static let lowData = FlowStationFlags(rawValue: 1 << 1)
    /// For some day type the station has fewer active days than ``FlowSmoothingParameters/kappaCellMilli``
    /// (in days), so the smoothing prior outweighs its own counts in every cell of that day type.
    public static let neighborhoodDominated = FlowStationFlags(rawValue: 1 << 2)
    public static let known: FlowStationFlags = [.inGBFS, .lowData, .neighborhoodDominated]
}

/// Weekday or weekend/holiday. A date is `weekend` when it is a Saturday or Sunday, or a holiday
/// with the `weekend` profile in `Data/config/calendar/holidays.csv` (inside the window, those
/// are the file's `holidays` section).
public enum FlowDayType: UInt8, CaseIterable, Sendable, Codable {
    case weekday = 0
    case weekend = 1
    @inline(__always) var index: Int { Int(rawValue) }
}

/// Trips leaving a station (by `started_at`) or arriving at it (by `ended_at`).
public enum FlowDirection: UInt8, CaseIterable, Sendable, Codable {
    case departures = 0
    case arrivals = 1
    @inline(__always) var index: Int { Int(rawValue) }
}

/// The trip data's `rideable_type`: `classic_bike` or `electric_bike`.
public enum FlowBikeType: UInt8, CaseIterable, Sendable, Codable {
    case classic = 0
    case ebike = 1
    @inline(__always) var index: Int { Int(rawValue) }
}

/// The five series stored per (key, day type, direction), 96 bins each. Every value is per
/// 15-minute bin: the mean trip count, or its variance.
public enum FlowSlot: UInt8, CaseIterable, Sendable, Codable {
    case meanClassic = 0
    case varianceClassic = 1
    case meanEbike = 2
    case varianceEbike = 3
    /// Variance of the classic + e-bike count (its mean is `meanClassic + meanEbike`). Not the sum
    /// of the two variances: the types covary (by about 1.13× on 2026 data).
    case varianceAny = 4
    @inline(__always) var index: Int { Int(rawValue) }

    public static func mean(_ type: FlowBikeType) -> FlowSlot { type == .classic ? .meanClassic : .meanEbike }
    public static func variance(_ type: FlowBikeType) -> FlowSlot { type == .classic ? .varianceClassic : .varianceEbike }
}

/// The days a direction counts: `dayCount` days from `start`.
public struct FlowWindow: Sendable, Hashable, Codable {
    public var start: ServiceDate
    public var dayCount: Int

    public init(start: ServiceDate, dayCount: Int) {
        self.start = start
        self.dayCount = dayCount
    }

    /// The last day, inclusive.
    public var end: ServiceDate { start.adding(days: dayCount - 1) }

    public func contains(_ date: ServiceDate) -> Bool {
        let offset = start.distance(to: date)
        return offset >= 0 && offset < dayCount
    }
}

/// The empirical-Bayes smoothing parameters a file was built with (`docs/formats.md`, "flows").
/// Integers on the wire: the κs are pseudo-days in thousandths.
public struct FlowSmoothingParameters: Sendable, Hashable, Codable {
    /// κc: pseudo-days of the station-hour estimate mixed into each cell mean.
    public var kappaCellMilli: Int64
    /// κh: pseudo-days of the neighborhood prior mixed into each station-hour mean.
    public var kappaHourMilli: Int64
    /// κφ: pseudo-days of the station-hour dispersion mixed into each cell's dispersion.
    public var kappaDispersionMilli: Int64
    /// Nearest neighbors that make the neighborhood prior, and the radius they must lie within.
    public var neighborCount: Int64
    public var neighborRadiusMeters: Int64

    public init(kappaCellMilli: Int64, kappaHourMilli: Int64, kappaDispersionMilli: Int64, neighborCount: Int64, neighborRadiusMeters: Int64) {
        self.kappaCellMilli = kappaCellMilli
        self.kappaHourMilli = kappaHourMilli
        self.kappaDispersionMilli = kappaDispersionMilli
        self.neighborCount = neighborCount
        self.neighborRadiusMeters = neighborRadiusMeters
    }

    /// The M1 starting values (κc = 4, κh = 8, κφ = 6 pseudo-days; 8 neighbors within 1 km), to be
    /// tuned in the M6 backtest.
    public static let m1 = FlowSmoothingParameters(
        kappaCellMilli: 4_000, kappaHourMilli: 8_000, kappaDispersionMilli: 6_000, neighborCount: 8, neighborRadiusMeters: 1_000
    )
}

/// A malformed or incompatible `flows` payload.
public enum FlowsFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFlows(found: UInt16)
    case unsupportedFormatVersion(UInt16)
    case unsupportedPayloadRevision(UInt32)
    case badMagic
    case truncated
    case duplicateSection(UInt32)
    case missingSection(FlowsSection)
    case elementSizeMismatch(FlowsSection, found: UInt32)
    case misalignedSection(FlowsSection)
    case sectionOutOfBounds(UInt32)
    case sectionsOverlap(UInt32)
    case nonZeroPadding(offset: Int)
    case countMismatch(FlowsSection, expected: Int, actual: Int)
    /// An `info` value outside what the format allows (a layout constant that differs, a window
    /// of no days, a negative κ, …).
    case invalidInfo(FlowsInfoField, Int64)
    /// Keys must be non-empty UTF-8, strictly ascending by bytes (so unique).
    case keysNotSorted(row: Int)
    case invalidKey(row: Int)
    case invalidKeyOffsets
    case tooManyKeys(Int)
    case holidaysNotSorted(index: Int)
    case holidayOutsideWindow(index: Int)
    /// More active days than the window has days of that type.
    case activeDaysOutOfRange(row: Int)
    /// A cell that is NaN, infinite or negative (sign bit set).
    case invalidCell(index: Int)
    /// A variance below its mean (`varianceAny` below `meanClassic + meanEbike`).
    case varianceBelowMean(index: Int)

    public var description: String {
        switch self {
        case .notFlows(let kind): "artifact kind \(kind) is not flows"
        case .unsupportedFormatVersion(let version): "unsupported flows format version \(version)"
        case .unsupportedPayloadRevision(let revision): "unsupported flows payload revision \(revision)"
        case .badMagic: "flows payload does not start with FLOW"
        case .truncated: "flows payload is truncated"
        case .duplicateSection(let id): "flows section \(id) appears twice"
        case .missingSection(let section): "flows section \(section) is missing"
        case .elementSizeMismatch(let section, let size): "flows section \(section) has element size \(size)"
        case .misalignedSection(let section): "flows section \(section) is not 8-aligned"
        case .sectionOutOfBounds(let id): "flows section \(id) extends past the payload"
        case .sectionsOverlap(let id): "flows section \(id) overlaps another"
        case .nonZeroPadding(let offset): "flows payload has non-zero padding at \(offset)"
        case .countMismatch(let section, let expected, let actual): "flows section \(section) has \(actual) elements, expected \(expected)"
        case .invalidInfo(let field, let value): "flows info \(field) = \(value) is invalid"
        case .keysNotSorted(let row): "flows keys are not strictly ascending at row \(row)"
        case .invalidKey(let row): "flows key \(row) is empty or not UTF-8"
        case .invalidKeyOffsets: "flows key offsets are inconsistent"
        case .tooManyKeys(let count): "flows has \(count) keys (at most \(FlowsFormat.maxKeys))"
        case .holidaysNotSorted(let index): "flows holidays are not strictly ascending at \(index)"
        case .holidayOutsideWindow(let index): "flows holiday \(index) lies outside the window"
        case .activeDaysOutOfRange(let row): "flows active days of row \(row) exceed the window"
        case .invalidCell(let index): "flows cell \(index) is not a finite non-negative number"
        case .varianceBelowMean(let index): "flows cell \(index) holds a variance below its mean"
        }
    }
}
