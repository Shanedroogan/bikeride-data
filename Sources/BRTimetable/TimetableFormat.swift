/// Layout constants for the `tt-*` payloads. The byte layout is documented in `docs/formats.md`
/// ("Timetables"); this file and that section must change together.
public enum TimetableFormat {
    /// ASCII `BRTT`, the first four payload bytes.
    public static let magic: [UInt8] = Array("BRTT".utf8)
    /// The payload revision, stored in ``InfoField/payloadRevision``: `1` in format 1, and readers
    /// require exactly this value for the formatVersion they read. The format-0 drafts counted
    /// breaking changes (2 added ``TimetableSection/tripFlags``) until the format froze at 1 on
    /// 2026-09-26.
    public static let payloadRevision: Int64 = 1
    /// Bytes per table-of-contents entry: `u32 id, u32 elementSize, u64 offset, u64 count`.
    static let tocEntrySize = 24
    /// Size of the payload preamble before the table of contents: magic + `u32` section count.
    static let preambleSize = 8

    /// "No value" for any `u32` index or time field.
    public static let none = UInt32.max
    /// Grace period after a calendar rule's end date during which the coverage policy may
    /// extrapolate it ("Schedule may be outdated").
    public static let extrapolationGraceDays = 14
}

/// Section identifiers in a timetable payload's table of contents. Raw values are permanent.
///
/// Every section is an array of one scalar type. Sections named `…Start` are CSR offsets with
/// one more element than the table they index; the last element equals the length of the
/// target array.
public enum TimetableSection: UInt32, CaseIterable, Sendable {
    // Scalars and strings
    case info = 1                    // i64 × InfoField.count
    case stringOffsets = 2           // u32 × (strings + 1)
    case stringBytes = 3             // u8

    // Feed sources (one per GTFS zip version that contributed trips)
    case sourceName = 10             // u32 string
    case sourceVersion = 11          // u32 string (feed_info.feed_version, or empty)
    case sourceETag = 12             // u32 string
    case sourceSlot = 13             // u32 (sources in one slot are alternative versions of one feed)
    case sourceSelectedDays = 14     // u64 × sources × wordsPerSource; bit d = window day d selected

    // Agencies
    case agencyGTFSID = 20           // u32 string
    case agencyName = 21             // u32 string
    case agencyTimezone = 22         // u32 string

    // Routes
    case routeAgency = 30            // u32 agency index
    case routeGTFSID = 31            // u32 string
    case routeShortName = 32         // u32 string
    case routeLongName = 33          // u32 string
    case routeColor = 34             // u32 0xRRGGBB or none
    case routeTextColor = 35         // u32 0xRRGGBB or none
    case routeMode = 36              // u8 RouteMode
    case routeType = 37              // u16 GTFS route_type

    // Stops
    case stopGTFSID = 40             // u32 string (bare, without the system prefix)
    case stopName = 41               // u32 string
    case stopCode = 42               // u32 string
    case stopLatE6 = 43              // i32 microdegrees
    case stopLonE6 = 44              // i32 microdegrees
    case stopParent = 45             // u32 stop index or none
    case stopKind = 46               // u8 StopKind (GTFS location_type)
    case stopAccess = 47             // u8 StopAccess: bit 0 entry allowed, bit 1 exit allowed
    case stopEntranceType = 48       // u32 string, e.g. "Stair", "Elevator" (entrances only; else empty)

    // Service rules (one per source × service_id)
    case ruleGTFSID = 50             // u32 string
    case ruleSource = 51             // u32 source index
    case ruleWeekdays = 52           // u8 bit 0 = Monday … bit 6 = Sunday; bit 7 = has calendar.txt row
    case ruleStartDay = 53           // i32 days since 1970-01-01 (calendar start_date)
    case ruleEndDay = 54             // i32 days since 1970-01-01 (calendar end_date, inclusive)
    case ruleExceptionStart = 55     // u32 × (rules + 1)
    case exceptionDay = 56           // i32 days since 1970-01-01, ascending within a rule
    case exceptionType = 57          // u8 1 = added, 2 = removed

    // Route patterns
    case patternRoute = 60           // u32 route index
    case patternStopStart = 61       // u32 × (patterns + 1) into patternStop*
    case patternTripStart = 62       // u32 × (patterns + 1); a pattern's trips are contiguous
    case patternFlags = 63           // u8 PatternFlags
    case patternDepartureStart = 64  // u32 into departures
    case patternArrivalStart = 65    // u32 into arrivals, or none when arrivals equal departures
    case patternShape = 66           // u32 shape index or none
    case patternBaseKey = 67         // u32; sub-patterns split for FIFO share their base key

    case patternStopIndex = 70       // u32 stop index
    case patternStopFlags = 71       // u8 bit 0 = pickup allowed, bit 1 = drop-off allowed
    case patternStopShapeVertex = 72 // u32 vertex index into the pattern's shape, or none

    // Stop times: per pattern a trip-major matrix, trip j stop i at start + j * stopCount + i
    case departures = 80             // u32 seconds from the service day's origin
    case arrivals = 81               // u32 seconds from the service day's origin

    // Trips (ordered by pattern, then first departure)
    case tripPattern = 90            // u32
    case tripRule = 91               // u32
    case tripGTFSID = 92             // u32 string
    case tripHeadsign = 93           // u32 string
    case tripShortName = 94          // u32 string
    case tripDirection = 95          // u8 0, 1, or 255 when absent
    case tripFlags = 96              // u8 TripFlags: bit 0 = peak (LIRR peak_offpeak = 1)

    // Stop → patterns serving it
    case stopPatternStart = 100      // u32 × (stops + 1)
    case stopPatternRef = 101        // u32 pattern index
    case stopPatternPosition = 102   // u32 position of the stop within that pattern

    // transfers.txt, raw (stop-level, parent-level and trip-to-trip rows)
    case transferFromStop = 110      // u32
    case transferToStop = 111        // u32
    case transferFromTrip = 112      // u32 or none
    case transferToTrip = 113        // u32 or none
    case transferType = 114          // u8 GTFS transfer_type
    case transferMinSeconds = 115    // u32 or none

    // Simplified shapes
    case shapeGTFSID = 120           // u32 string (empty for shapes synthesized from stops)
    case shapePointStart = 121       // u32 × (shapes + 1)
    case shapeLatE6 = 122            // i32
    case shapeLonE6 = 123            // i32

    // Real-time match tables
    case subwayKeyRoute = 130        // u32 string (route token of the trip id)
    case subwayKeyDirection = 131    // u8 ASCII N or S
    case subwayKeyOrigin = 132       // i32 origin in hundredths of a minute
    case subwayKeyPath = 133         // u32 string
    case subwayKeyTrip = 134         // u32 trip index
    case tripIDOrder = 140           // u32 trip indices sorted by GTFS trip_id bytes
    case stopIDOrder = 141           // u32 stop indices sorted by GTFS stop_id bytes

    var elementSize: Int {
        switch self {
        case .info: 8
        case .sourceSelectedDays: 8
        case .stringBytes, .routeMode, .stopKind, .stopAccess, .ruleWeekdays, .exceptionType, .patternFlags,
             .patternStopFlags, .tripDirection, .tripFlags, .transferType, .subwayKeyDirection:
            1
        case .routeType: 2
        default: 4
        }
    }
}

/// Positions in the `info` section.
public enum InfoField: Int, CaseIterable, Sendable {
    /// ASCII code of the ``BRCore/TransitSystem`` raw value.
    case system = 0
    /// Days since 1970-01-01 of window day 0.
    case windowStartDay = 1
    /// Number of days in the window.
    case dayCount = 2
    /// String id of the IANA time zone of the service days (every agency's `agency_timezone`).
    case timeZone = 3
    /// `u64` words per source in `sourceSelectedDays`.
    case wordsPerSource = 4
    /// ``TimetableFormat/payloadRevision`` of the writer.
    case payloadRevision = 5
    // The info array may gain entries past these; readers ignore entries they don't know.
}

/// How a route is presented and priced. Readers reject any other value.
public enum RouteMode: UInt8, CaseIterable, Sendable, Codable {
    case subway = 0
    case localBus = 1
    /// Select Bus Service (`route_id` ends with `+`).
    case sbs = 2
    /// Express bus (`route_id` starts with X, BM, BxM, QM or SIM).
    case expressBus = 3
    case lirr = 4
    case ferry = 5
    /// PATH (PANYNJ), `route_type` 1.
    case path = 6
}

/// GTFS `location_type`. Readers reject any other value.
public enum StopKind: UInt8, CaseIterable, Sendable {
    case stop = 0
    case station = 1
    case entrance = 2
    case genericNode = 3
    case boardingArea = 4
}

public struct PatternFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Every trip's arrival equals its departure at every stop; only departures are stored.
    public static let arrivalEqualsDeparture = PatternFlags(rawValue: 1 << 0)
    /// The pattern's shape was synthesized from its stop coordinates (no usable GTFS shape).
    public static let synthesizedShape = PatternFlags(rawValue: 1 << 1)
    /// Every bit defined so far; readers mask the rest off.
    public static let known: PatternFlags = [.arrivalEqualsDeparture, .synthesizedShape]
}

/// Per-trip flags (``TimetableSection/tripFlags``). Writers write undefined bits as 0; readers
/// ignore them.
public struct TripFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// A peak-fare trip (LIRR `trips.txt` `peak_offpeak` = 1).
    public static let peak = TripFlags(rawValue: 1 << 0)
    /// Every bit defined so far.
    public static let known: TripFlags = [.peak]
}

/// Whether riders may enter or leave the system through a stop. Always both for GTFS stops;
/// some subway entrances are entry-only or exit-only.
public struct StopAccess: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let entry = StopAccess(rawValue: 1 << 0)
    public static let exit = StopAccess(rawValue: 1 << 1)
    /// Every bit defined so far; readers mask the rest off.
    public static let known: StopAccess = [.entry, .exit]
}

public struct StopEventFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Riders may board here (`pickup_type` ≠ 1).
    public static let pickup = StopEventFlags(rawValue: 1 << 0)
    /// Riders may alight here (`drop_off_type` ≠ 1).
    public static let dropOff = StopEventFlags(rawValue: 1 << 1)
    /// Every bit defined so far. ``Timetable/patternStopFlags(_:)`` hands out the raw bytes for
    /// the hot path, so consumers test single bits and never compare whole bytes.
    public static let known: StopEventFlags = [.pickup, .dropOff]
}

/// `ruleWeekdays` bit 7: the rule has a `calendar.txt` row (weekday mask and valid range).
let ruleHasCalendarBit: UInt8 = 1 << 7

/// The values each enum-like `u8` section may hold; a reader rejects any other when it opens the
/// file (never a silent fallback). New values need a format bump.
enum TimetableEnums {
    static func isKnownRouteMode(_ value: UInt8) -> Bool { RouteMode(rawValue: value) != nil }
    static func isKnownStopKind(_ value: UInt8) -> Bool { StopKind(rawValue: value) != nil }
    /// `calendar_dates.txt` `exception_type`: 1 added, 2 removed.
    static func isKnownExceptionType(_ value: UInt8) -> Bool { value == 1 || value == 2 }
    /// GTFS `transfer_type` 0–5 (4 and 5 are in-seat rows).
    static func isKnownTransferType(_ value: UInt8) -> Bool { value <= 5 }
    /// `direction_id` 0 or 1, or 255 when the feed gives none.
    static func isKnownDirection(_ value: UInt8) -> Bool { value <= 1 || value == 255 }
    /// ASCII `N` or `S`.
    static func isKnownSubwayKeyDirection(_ value: UInt8) -> Bool { value == UInt8(ascii: "N") || value == UInt8(ascii: "S") }
}
