import BRCore

// The `config` artifact's JSON document (docs/formats.md, "config"). Every type here is a wire
// type: its coding keys are the format. Rules the types follow, so the encoding is deterministic
// and platform-independent:
// - integers only (no floating point reaches the bytes), with the unit in the key name;
// - no Swift `Set` and no dictionary keyed by anything but `String` (`JSONEncoder` writes a
//   non-String-keyed dictionary as an array of alternating keys and values);
// - set-like arrays are written sorted by the UTF-8 bytes of their key (``ConfigValidation``);
// - enums have full-word raw values and are strict: an unknown value fails the decode;
// - optionals are omitted when nil, and a reader treats `null` as absent.
//
// The engine types (fares, RAPTOR, bike share) live in the app; it maps these onto them.

/// The whole config document: what `config.bin` carries, as JSON.
public struct ConfigDocument: Sendable, Equatable, Codable {
    /// The lowest app engine semantics level that may apply this config. An app whose level is
    /// lower rejects the set before switching to it (the JSON still parses: this is a semantics
    /// gate, not the parse gate `formatVersion` is). The first app build is level 1.
    public var minAppFormat: Int
    /// Feature flags by name. None is defined yet. A flag's meaning, and what its absence means,
    /// is documented when it is defined; readers ignore names they don't know.
    public var flags: [String: Bool]
    public var calendar: ConfigCalendar
    public var fares: ConfigFares
    public var transit: ConfigTransit
    public var bikeShare: ConfigBikeShare
    public var alerts: ConfigAlerts

    public init(minAppFormat: Int, flags: [String: Bool], calendar: ConfigCalendar, fares: ConfigFares,
                transit: ConfigTransit, bikeShare: ConfigBikeShare, alerts: ConfigAlerts) {
        self.minAppFormat = minAppFormat
        self.flags = flags
        self.calendar = calendar
        self.fares = fares
        self.transit = transit
        self.bikeShare = bikeShare
        self.alerts = alerts
    }
}

// MARK: - Calendar

public struct ConfigCalendar: Sendable, Equatable, Codable {
    /// Weekday holidays, ascending by date (Data/config/calendar/holidays.csv).
    public var holidays: [ConfigHoliday]

    public init(holidays: [ConfigHoliday]) {
        self.holidays = holidays
    }
}

public struct ConfigHoliday: Sendable, Equatable, Codable {
    /// The day that is off (the observed day for a fixed-date holiday on a weekend), `YYYYMMDD`.
    public var date: ServiceDate
    public var name: String
    /// Which day type Citi Bike demand follows that day (flows, and later availability). Not the
    /// MTA service calendar: each system's GTFS says which schedule it runs.
    public var bikeShareDayType: ConfigDayType
    /// Every LIRR train that day is off-peak (the fare peak rule does not apply).
    public var lirrOffPeak: Bool

    public init(date: ServiceDate, name: String, bikeShareDayType: ConfigDayType, lirrOffPeak: Bool) {
        self.date = date
        self.name = name
        self.bikeShareDayType = bikeShareDayType
        self.lirrOffPeak = lirrOffPeak
    }
}

public enum ConfigDayType: String, Sendable, Equatable, Codable, CaseIterable {
    case weekday
    case weekend
}

// MARK: - Fares

public struct ConfigFares: Sendable, Equatable, Codable {
    public var mta: ConfigMTAFares
    public var path: ConfigPATHFares
    public var lirr: ConfigLIRRFares
    public var citiBike: ConfigCitiBikeFares

    public init(mta: ConfigMTAFares, path: ConfigPATHFares, lirr: ConfigLIRRFares, citiBike: ConfigCitiBikeFares) {
        self.mta = mta
        self.path = path
        self.lirr = lirr
        self.citiBike = citiBike
    }
}

/// OMNY fares: the subway, local and Select Bus Service buses, express buses, and the Staten
/// Island Railway through its fare stations.
public struct ConfigMTAFares: Sendable, Equatable, Codable {
    /// Subway, local bus and SBS.
    public var baseFareCents: Int
    public var expressBusFareCents: Int
    /// What an express bus costs on a transfer whose table cell is ``ConfigTransferCharge/stepUp``.
    public var expressBusStepUpCents: Int
    /// How long after a paid tap its one free transfer stays valid, inclusive.
    public var transferWindowSeconds: Int
    public var transferTable: ConfigTransferTable
    /// Subway stations where leaving and re-entering on foot still counts as the free transfer
    /// (subway → subway, within the window). Parent-station ids.
    public var outOfSystemTransfers: [ConfigStationPair]
    /// Subway stations joined inside fare control that the feed's `transfers.txt` doesn't link:
    /// a walk between them is an in-station change. Parent-station ids.
    public var inSystemTransfers: [ConfigStationPair]
    public var statenIslandRailway: ConfigStatenIslandRailway

    public init(baseFareCents: Int, expressBusFareCents: Int, expressBusStepUpCents: Int, transferWindowSeconds: Int,
                transferTable: ConfigTransferTable, outOfSystemTransfers: [ConfigStationPair],
                inSystemTransfers: [ConfigStationPair], statenIslandRailway: ConfigStatenIslandRailway) {
        self.baseFareCents = baseFareCents
        self.expressBusFareCents = expressBusFareCents
        self.expressBusStepUpCents = expressBusStepUpCents
        self.transferWindowSeconds = transferWindowSeconds
        self.transferTable = transferTable
        self.outOfSystemTransfers = outOfSystemTransfers
        self.inSystemTransfers = inSystemTransfers
        self.statenIslandRailway = statenIslandRailway
    }
}

/// The OMNY fare classes that carry and use a free transfer.
public enum ConfigFareClass: String, Sendable, Equatable, Codable, CaseIterable {
    /// The subway, and the Staten Island Railway when a ride boards or alights at a fare station.
    case subway
    /// Local and Select Bus Service buses.
    case localBus
    case expressBus
}

/// What boarding a class costs on an unused free transfer.
public enum ConfigTransferCharge: String, Sendable, Equatable, Codable, CaseIterable {
    /// The transfer covers the ride.
    case free
    /// The transfer covers it after paying ``ConfigMTAFares/expressBusStepUpCents``.
    case stepUp
    /// The transfer does not apply: the ride pays a new fare (which carries its own transfer).
    case pay
}

/// Row: the class whose paid fare carries the transfer. Column (``ConfigTransferRow``): the
/// class boarded on it. Every cell is required, so the table is complete by construction.
public struct ConfigTransferTable: Sendable, Equatable, Codable {
    public var subway: ConfigTransferRow
    public var localBus: ConfigTransferRow
    public var expressBus: ConfigTransferRow

    public init(subway: ConfigTransferRow, localBus: ConfigTransferRow, expressBus: ConfigTransferRow) {
        self.subway = subway
        self.localBus = localBus
        self.expressBus = expressBus
    }

    public subscript(paid: ConfigFareClass) -> ConfigTransferRow {
        switch paid {
        case .subway: subway
        case .localBus: localBus
        case .expressBus: expressBus
        }
    }

    /// The charge for boarding `boarded` on the transfer of a fare paid on `paid`.
    public func charge(paid: ConfigFareClass, boarded: ConfigFareClass) -> ConfigTransferCharge {
        self[paid][boarded]
    }
}

public struct ConfigTransferRow: Sendable, Equatable, Codable {
    public var subway: ConfigTransferCharge
    public var localBus: ConfigTransferCharge
    public var expressBus: ConfigTransferCharge

    public init(subway: ConfigTransferCharge, localBus: ConfigTransferCharge, expressBus: ConfigTransferCharge) {
        self.subway = subway
        self.localBus = localBus
        self.expressBus = expressBus
    }

    public subscript(boarded: ConfigFareClass) -> ConfigTransferCharge {
        switch boarded {
        case .subway: subway
        case .localBus: localBus
        case .expressBus: expressBus
        }
    }
}

/// An unordered pair of stops, written as a two-element array, lesser id (by UTF-8 bytes) first.
public struct ConfigStationPair: Sendable, Equatable, Codable {
    public let first: StopID
    public let second: StopID

    /// Orders the two ids by their UTF-8 bytes.
    public init(_ a: StopID, _ b: StopID) {
        (first, second) = a.rawValue.utf8.lexicographicallyPrecedes(b.rawValue.utf8) ? (a, b) : (b, a)
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let a = try container.decode(StopID.self), b = try container.decode(StopID.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "a station pair has exactly two ids")
        }
        self.init(a, b)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(first)
        try container.encode(second)
    }
}

/// Fares are collected only at ``fareStations``, on entry and on exit: a ride between two other
/// stations is free and leaves the OMNY state alone; one that boards or alights at a fare
/// station is priced as ``ConfigFareClass/subway``.
public struct ConfigStatenIslandRailway: Sendable, Equatable, Codable {
    /// Routes of the subway feed that are the SIR.
    public var routes: [RouteID]
    /// Parent-station ids.
    public var fareStations: [StopID]

    public init(routes: [RouteID], fareStations: [StopID]) {
        self.routes = routes
        self.fareStations = fareStations
    }
}

/// PATH: one flat fare per entry; no transfer to or from the MTA, no cap.
public struct ConfigPATHFares: Sendable, Equatable, Codable {
    public var fareCents: Int

    public init(fareCents: Int) {
        self.fareCents = fareCents
    }
}

/// LIRR fares: a zone matrix plus the flat CityTicket and Far Rockaway Ticket, priced per
/// ticket as the cheapest the trip qualifies for (ties to the zone fare).
public struct ConfigLIRRFares: Sendable, Equatable, Codable {
    public var stations: [ConfigLIRRStation]
    /// One row per unordered zone pair, `fromZone ≤ toZone`.
    public var zoneFares: [ConfigLIRRZoneFare]
    /// Between two ``ConfigLIRRCityFare/cityTicket`` stations.
    public var cityTicket: ConfigPeakFare
    public var farRockawayTicket: ConfigFarRockawayTicket
    /// Decides peak only for trains whose timetable carries no peak flag.
    public var peakRule: ConfigLIRRPeakRule
    /// The New York City terminals the peak rule is evaluated at.
    public var nycTerminals: [StopID]

    public init(stations: [ConfigLIRRStation], zoneFares: [ConfigLIRRZoneFare], cityTicket: ConfigPeakFare,
                farRockawayTicket: ConfigFarRockawayTicket, peakRule: ConfigLIRRPeakRule, nycTerminals: [StopID]) {
        self.stations = stations
        self.zoneFares = zoneFares
        self.cityTicket = cityTicket
        self.farRockawayTicket = farRockawayTicket
        self.peakRule = peakRule
        self.nycTerminals = nycTerminals
    }
}

public struct ConfigLIRRStation: Sendable, Equatable, Codable {
    public var stop: StopID
    public var zone: Int
    public var cityFare: ConfigLIRRCityFare

    public init(stop: StopID, zone: Int, cityFare: ConfigLIRRCityFare) {
        self.stop = stop
        self.zone = zone
        self.cityFare = cityFare
    }
}

/// Which flat in-city ticket a station can use.
public enum ConfigLIRRCityFare: String, Sendable, Equatable, Codable, CaseIterable {
    /// Zone fares only.
    case none
    /// CityTicket to any other such station.
    case cityTicket
    /// Sells the Far Rockaway Ticket, for trips from here to its destination zone only.
    case farRockaway
}

public struct ConfigLIRRZoneFare: Sendable, Equatable, Codable {
    public var fromZone: Int
    public var toZone: Int
    public var peakCents: Int
    public var offPeakCents: Int

    public init(fromZone: Int, toZone: Int, peakCents: Int, offPeakCents: Int) {
        self.fromZone = fromZone
        self.toZone = toZone
        self.peakCents = peakCents
        self.offPeakCents = offPeakCents
    }
}

public struct ConfigPeakFare: Sendable, Equatable, Codable {
    public var peakCents: Int
    public var offPeakCents: Int

    public init(peakCents: Int, offPeakCents: Int) {
        self.peakCents = peakCents
        self.offPeakCents = offPeakCents
    }
}

/// One-way, sold only at ``ConfigLIRRCityFare/farRockaway`` stations, valid to stations in
/// ``destinationZone``.
public struct ConfigFarRockawayTicket: Sendable, Equatable, Codable {
    public var peakCents: Int
    public var offPeakCents: Int
    public var destinationZone: Int

    public init(peakCents: Int, offPeakCents: Int, destinationZone: Int) {
        self.peakCents = peakCents
        self.offPeakCents = offPeakCents
        self.destinationZone = destinationZone
    }
}

/// Peak: a weekday (not an ``ConfigHoliday/lirrOffPeak`` holiday) train arriving at a New York
/// City terminal within ``terminalArrivals`` or departing one within ``terminalDepartures``,
/// local time (America/New_York).
public struct ConfigLIRRPeakRule: Sendable, Equatable, Codable {
    public var terminalArrivals: ConfigMinuteWindow
    public var terminalDepartures: ConfigMinuteWindow

    public init(terminalArrivals: ConfigMinuteWindow, terminalDepartures: ConfigMinuteWindow) {
        self.terminalArrivals = terminalArrivals
        self.terminalDepartures = terminalDepartures
    }
}

/// Minutes after local midnight: `startMinute` included, `endMinute` excluded.
public struct ConfigMinuteWindow: Sendable, Equatable, Codable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

/// Citi Bike: one price list for New York City, Jersey City and Hoboken.
public struct ConfigCitiBikeFares: Sendable, Equatable, Codable {
    public var plans: ConfigCitiBikePlans
    /// Until tax treatment is confirmed, every Citi Bike cost is an estimate.
    public var taxConfirmed: Bool

    public init(plans: ConfigCitiBikePlans, taxConfirmed: Bool) {
        self.plans = plans
        self.taxConfirmed = taxConfirmed
    }
}

public struct ConfigCitiBikePlans: Sendable, Equatable, Codable {
    public var nonMember: ConfigCitiBikePlan
    public var member: ConfigCitiBikePlan
    public var dayPass: ConfigCitiBikePlan
    public var reducedFare: ConfigCitiBikePlan

    public init(nonMember: ConfigCitiBikePlan, member: ConfigCitiBikePlan, dayPass: ConfigCitiBikePlan,
                reducedFare: ConfigCitiBikePlan) {
        self.nonMember = nonMember
        self.member = member
        self.dayPass = dayPass
        self.reducedFare = reducedFare
    }
}

/// Per-ride prices for one plan. Billing rounds a partial minute up.
public struct ConfigCitiBikePlan: Sendable, Equatable, Codable {
    /// Charged on every ride, either bike type.
    public var unlockFeeCents: Int
    public var classicIncludedMinutes: Int
    public var classicPerMinuteCents: Int
    /// E-bikes include no minutes.
    public var ebikePerMinuteCents: Int
    /// Absent: no cap.
    public var ebikeManhattanCap: ConfigManhattanCap?
    /// The membership or pass itself, for display; never added to a ride. Absent: none shown.
    public var planPriceCents: Int?
    /// The prices were checked against a published source. An unverified plan is shown as an
    /// estimate.
    public var verified: Bool

    public init(unlockFeeCents: Int, classicIncludedMinutes: Int, classicPerMinuteCents: Int, ebikePerMinuteCents: Int,
                ebikeManhattanCap: ConfigManhattanCap? = nil, planPriceCents: Int? = nil, verified: Bool) {
        self.unlockFeeCents = unlockFeeCents
        self.classicIncludedMinutes = classicIncludedMinutes
        self.classicPerMinuteCents = classicPerMinuteCents
        self.ebikePerMinuteCents = ebikePerMinuteCents
        self.ebikeManhattanCap = ebikeManhattanCap
        self.planPriceCents = planPriceCents
        self.verified = verified
    }
}

/// E-bike usage on a ride of at most `maxRideMinutes` billed minutes that enters or leaves
/// Manhattan from another New York City borough is capped at `amountCents` (never in New Jersey).
public struct ConfigManhattanCap: Sendable, Equatable, Codable {
    public var amountCents: Int
    public var maxRideMinutes: Int

    public init(amountCents: Int, maxRideMinutes: Int) {
        self.amountCents = amountCents
        self.maxRideMinutes = maxRideMinutes
    }
}

// MARK: - Transit

/// The transit systems, by full name (not `TransitSystem`'s one-letter id codes).
public enum ConfigTransitSystem: String, Sendable, Equatable, Codable, CaseIterable {
    case subway, bus, lirr, ferry, path

    public init(_ system: TransitSystem) {
        switch system {
        case .subway: self = .subway
        case .bus: self = .bus
        case .lirr: self = .lirr
        case .ferry: self = .ferry
        case .path: self = .path
        }
    }

    public var system: TransitSystem {
        switch self {
        case .subway: .subway
        case .bus: .bus
        case .lirr: .lirr
        case .ferry: .ferry
        case .path: .path
        }
    }
}

/// One integer per transit system; every system is required.
public struct ConfigSystemValues: Sendable, Equatable, Codable {
    public var subway: Int
    public var bus: Int
    public var lirr: Int
    public var ferry: Int
    public var path: Int

    public init(subway: Int, bus: Int, lirr: Int, ferry: Int, path: Int) {
        self.subway = subway
        self.bus = bus
        self.lirr = lirr
        self.ferry = ferry
        self.path = path
    }

    public subscript(system: TransitSystem) -> Int {
        switch system {
        case .subway: subway
        case .bus: bus
        case .lirr: lirr
        case .ferry: ferry
        case .path: path
        }
    }

    /// In `TransitSystem.allCases` order.
    public var all: [Int] { TransitSystem.allCases.map { self[$0] } }
}

/// Change times, slack and search bounds for the transit router (all whole seconds).
public struct ConfigTransit: Sendable, Equatable, Codable {
    /// Re-boarding at the stop you got off at. A stop-level self row in `transfers.txt` replaces
    /// it for that stop.
    public var sameStopChangeSeconds: ConfigSystemValues
    /// A guaranteed (`transfer_type` 1) trip-to-trip pair's change time.
    public var guaranteedTransferSeconds: Int
    /// Floor on `transfers.txt` platform-to-platform times.
    public var minimumPlatformChangeSeconds: Int
    public var accessSlack: ConfigAccessSlack
    public var afterBikeChange: ConfigAfterBikeChange
    public var extraLeg: ConfigExtraLeg
    /// No label later than departure + this is kept.
    public var maxJourneySeconds: Int
    /// Walk trees reach stops out to this.
    public var accessWalkLimitSeconds: Int
    public var directWalkLimitSeconds: Int
    /// How far a trip's origin or destination may lie from the walk graph.
    public var originSnapMeters: Int
    public var links: ConfigLinks

    public init(sameStopChangeSeconds: ConfigSystemValues, guaranteedTransferSeconds: Int, minimumPlatformChangeSeconds: Int,
                accessSlack: ConfigAccessSlack, afterBikeChange: ConfigAfterBikeChange, extraLeg: ConfigExtraLeg,
                maxJourneySeconds: Int, accessWalkLimitSeconds: Int, directWalkLimitSeconds: Int, originSnapMeters: Int,
                links: ConfigLinks) {
        self.sameStopChangeSeconds = sameStopChangeSeconds
        self.guaranteedTransferSeconds = guaranteedTransferSeconds
        self.minimumPlatformChangeSeconds = minimumPlatformChangeSeconds
        self.accessSlack = accessSlack
        self.afterBikeChange = afterBikeChange
        self.extraLeg = extraLeg
        self.maxJourneySeconds = maxJourneySeconds
        self.accessWalkLimitSeconds = accessWalkLimitSeconds
        self.directWalkLimitSeconds = directWalkLimitSeconds
        self.originSnapMeters = originSnapMeters
        self.links = links
    }
}

/// Slack after walking to the first stop: `baseSeconds + walk × walkPercent / 100` (integer
/// division).
public struct ConfigAccessSlack: Sendable, Equatable, Codable {
    public var baseSeconds: Int
    public var walkPercent: Int

    public init(baseSeconds: Int, walkPercent: Int) {
        self.baseSeconds = baseSeconds
        self.walkPercent = walkPercent
    }
}

/// The change time after a bike leg: `max(minSeconds, ride × ridePercent / 100)`.
public struct ConfigAfterBikeChange: Sendable, Equatable, Codable {
    public var minSeconds: Int
    public var ridePercent: Int

    public init(minSeconds: Int, ridePercent: Int) {
        self.minSeconds = minSeconds
        self.ridePercent = ridePercent
    }
}

/// A journey whose last leg is boarded in round `pruneRound` or later must save more than
/// `minSavingSeconds` over the best with fewer legs.
public struct ConfigExtraLeg: Sendable, Equatable, Codable {
    public var pruneRound: Int
    public var minSavingSeconds: Int

    public init(pruneRound: Int, minSavingSeconds: Int) {
        self.pruneRound = pruneRound
        self.minSavingSeconds = minSavingSeconds
    }
}

/// The `links` build parameters. `links` bakes these in, and its header's `builtAgainst` will
/// name the config it was built from.
public struct ConfigLinks: Sendable, Equatable, Codable {
    /// Station access charged once at every street↔platform transition. At most 65,535.
    public var stationAccessSeconds: ConfigSystemValues
    /// How far an access point may lie from the walk graph.
    public var maxSnapMeters: ConfigSystemValues
    /// A footpath is listed when it walks at most this long, station access at both ends on top.
    public var maxFootpathWalkSeconds: Int
    /// In-station transfers quicker than this are raised to it.
    public var minTransferSeconds: Int
    /// Station links are listed when the walk between the station and a stop's access point is
    /// at most this far.
    public var stationLinkMaxWalkMeters: Int
    /// Walking speed, in hundredths of a mile per hour (350 = 3.5 mph).
    public var walkSpeedHundredthsMph: Int
    /// Systems whose access points outside the service area get no street access.
    public var streetAccessOnlyInsideServiceArea: [ConfigTransitSystem]
    /// Indoor or very short walks between stations of different systems, applied both ways
    /// between every routable platform of each end.
    public var fixedTransfers: [ConfigFixedTransfer]

    public init(stationAccessSeconds: ConfigSystemValues, maxSnapMeters: ConfigSystemValues, maxFootpathWalkSeconds: Int,
                minTransferSeconds: Int, stationLinkMaxWalkMeters: Int, walkSpeedHundredthsMph: Int,
                streetAccessOnlyInsideServiceArea: [ConfigTransitSystem], fixedTransfers: [ConfigFixedTransfer]) {
        self.stationAccessSeconds = stationAccessSeconds
        self.maxSnapMeters = maxSnapMeters
        self.maxFootpathWalkSeconds = maxFootpathWalkSeconds
        self.minTransferSeconds = minTransferSeconds
        self.stationLinkMaxWalkMeters = stationLinkMaxWalkMeters
        self.walkSpeedHundredthsMph = walkSpeedHundredthsMph
        self.streetAccessOnlyInsideServiceArea = streetAccessOnlyInsideServiceArea
        self.fixedTransfers = fixedTransfers
    }
}

/// A configured walk between two stations (or stops) of any systems. Both ends are qualified
/// ids (`P:place_WTC`, `S:E01`).
public struct ConfigFixedTransfer: Sendable, Equatable, Codable {
    public var from: StopID
    public var to: StopID
    public var seconds: Int

    public init(from: StopID, to: StopID, seconds: Int) {
        self.from = from
        self.to = to
        self.seconds = seconds
    }
}

// MARK: - Bike share

public struct ConfigBikeShare: Sendable, Equatable, Codable {
    /// The GBFS `region_id`s of the service area. A station with no `region_id` is decided by the
    /// service-area polygon instead.
    public var regions: ConfigBikeShareRegions
    /// Regions known to be outside the service area (Citi Bike's test regions). Informational
    /// for the filter, which admits only ``regions``; the flows universe drops these.
    public var excludedRegions: [String]
    public var vehicleTypes: ConfigVehicleTypes
    /// A station whose status is older than this is not used.
    public var maxStatusAgeSeconds: Int
    /// Valet stations (the feed has no valet field). May be empty.
    public var valet: [ConfigValetStation]

    public init(regions: ConfigBikeShareRegions, excludedRegions: [String], vehicleTypes: ConfigVehicleTypes,
                maxStatusAgeSeconds: Int, valet: [ConfigValetStation]) {
        self.regions = regions
        self.excludedRegions = excludedRegions
        self.vehicleTypes = vehicleTypes
        self.maxStatusAgeSeconds = maxStatusAgeSeconds
        self.valet = valet
    }
}

public struct ConfigBikeShareRegions: Sendable, Equatable, Codable {
    public var nyc: [String]
    /// Jersey City and Hoboken.
    public var newJersey: [String]

    public init(nyc: [String], newJersey: [String]) {
        self.nyc = nyc
        self.newJersey = newJersey
    }

    public var all: [String] { nyc + newJersey }
}

/// Which GBFS `vehicle_type_id`s count as classic bikes and which as e-bikes.
public struct ConfigVehicleTypes: Sendable, Equatable, Codable {
    public var classic: [String]
    public var ebike: [String]

    public init(classic: [String], ebike: [String]) {
        self.classic = classic
        self.ebike = ebike
    }
}

/// A valet station: GBFS `station_id` and the position it was matched at, in microdegrees.
public struct ConfigValetStation: Sendable, Equatable, Codable {
    public var stationID: String
    public var latE6: Int
    public var lonE6: Int

    public init(stationID: String, latE6: Int, lonE6: Int) {
        self.stationID = stationID
        self.latE6 = latE6
        self.lonE6 = lonE6
    }
}

// MARK: - Alerts

public struct ConfigAlerts: Sendable, Equatable, Codable {
    /// PATH alert titles have no type: the first rule with a keyword the lowercased title
    /// contains gives the severity; no match is ``ConfigAlertSeverity/info``. In priority order.
    public var pathKeywords: [ConfigPathKeywordRule]

    public init(pathKeywords: [ConfigPathKeywordRule]) {
        self.pathKeywords = pathKeywords
    }
}

public struct ConfigPathKeywordRule: Sendable, Equatable, Codable {
    /// Lowercase substrings.
    public var keywords: [String]
    public var severity: ConfigAlertSeverity

    public init(keywords: [String], severity: ConfigAlertSeverity) {
        self.keywords = keywords
        self.severity = severity
    }
}

/// The app's alert severities.
public enum ConfigAlertSeverity: String, Sendable, Equatable, Codable, CaseIterable {
    case noService
    case suspended
    case partSuspended
    case detour
    case reroute
    case stopsSkipped
    case severeDelays
    case expressToLocal
    case delays
    case reducedService
    case plannedWork
    case info
}
