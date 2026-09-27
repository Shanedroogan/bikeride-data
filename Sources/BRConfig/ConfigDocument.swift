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

    // The M2c bike-planning sections: optional keys added within format 1. Each is absent in
    // every config written before them; an app plans bikes only when all six are present
    // (absent = bike planning off).
    /// Citi Bike availability model and policy. Absent = bike planning off.
    public var availability: ConfigAvailability?
    /// Admission, ranking and candidate limits of bike itineraries. Absent = bike planning off.
    public var rules: ConfigRules?
    /// The weather gate. Absent = bike planning off.
    public var weather: ConfigWeather?
    /// Riding-pace presets and speed learning. Absent = bike planning off.
    public var pace: ConfigPace?
    /// Default riding speeds per bike type. Absent = bike planning off.
    public var speeds: ConfigSpeeds?
    /// Unlock and dock times. Absent = bike planning off.
    public var overheads: ConfigOverheads?

    public init(minAppFormat: Int, flags: [String: Bool], calendar: ConfigCalendar, fares: ConfigFares,
                transit: ConfigTransit, bikeShare: ConfigBikeShare, alerts: ConfigAlerts,
                availability: ConfigAvailability? = nil, rules: ConfigRules? = nil, weather: ConfigWeather? = nil,
                pace: ConfigPace? = nil, speeds: ConfigSpeeds? = nil, overheads: ConfigOverheads? = nil) {
        self.minAppFormat = minAppFormat
        self.flags = flags
        self.calendar = calendar
        self.fares = fares
        self.transit = transit
        self.bikeShare = bikeShare
        self.alerts = alerts
        self.availability = availability
        self.rules = rules
        self.weather = weather
        self.pace = pace
        self.speeds = speeds
        self.overheads = overheads
    }

    /// The M2c bike-planning sections this document carries, by key, in the order
    /// ``ConfigDocument/planningSectionKeys`` lists them.
    public var planningSections: [String] {
        let present: [String: Bool] = [
            "availability": availability != nil, "rules": rules != nil, "weather": weather != nil,
            "pace": pace != nil, "speeds": speeds != nil, "overheads": overheads != nil,
        ]
        return Self.planningSectionKeys.filter { present[$0] == true }
    }

    /// The keys of the six M2c bike-planning sections.
    public static let planningSectionKeys = ["availability", "rules", "weather", "pace", "speeds", "overheads"]
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

/// The change time after a bike leg: `max(minSeconds, ride × ridePercent / 100)`. `links` builds
/// its hops' one-seat rule with it too.
public struct ConfigAfterBikeChange: Sendable, Equatable, Codable {
    public var minSeconds: Int
    public var ridePercent: Int

    public init(minSeconds: Int, ridePercent: Int) {
        self.minSeconds = minSeconds
        self.ridePercent = ridePercent
    }
}

/// A journey of exactly `pruneRound` transit legs (its last leg boarded in RAPTOR round
/// `pruneRound`; round 0 is access only) must arrive more than `minSavingSeconds` before the best
/// journey with fewer legs. Journeys with more legs are not held to this rule; the engine searches
/// at most 4 legs (`RaptorLimits.maxRounds` 5, not a config value), so with `pruneRound` 4 it
/// covers the last round.
public struct ConfigExtraLeg: Sendable, Equatable, Codable {
    public var pruneRound: Int
    public var minSavingSeconds: Int

    public init(pruneRound: Int, minSavingSeconds: Int) {
        self.pruneRound = pruneRound
        self.minSavingSeconds = minSavingSeconds
    }
}

/// The `links` build parameters. `links` bakes these in, and its header's `builtAgainst` names
/// the config it was built from.
public struct ConfigLinks: Sendable, Equatable, Codable {
    /// Station access charged once at every street↔platform transition. At most 65,534.
    public var stationAccessSeconds: ConfigSystemValues
    /// How far an access point may lie from the walk graph.
    public var maxSnapMeters: ConfigSystemValues
    /// A footpath is listed when it walks at most this long, station access at both ends on top.
    public var maxFootpathWalkSeconds: Int
    /// In-station transfers quicker than this are raised to it. At most 65,534.
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
    /// When the station is valet, in local time (America/New_York). Optional within format 1:
    /// absent = never valet.
    public var hours: [ConfigValetHours]?
    /// The last local date the ``hours`` apply, inclusive; after it the station is not valet.
    /// Optional within format 1: absent = no end date. The compiler requires it whenever
    /// ``hours`` is present, so a stale weekly schedule never applies silently.
    public var validUntilDate: ServiceDate?

    public init(stationID: String, latE6: Int, lonE6: Int, hours: [ConfigValetHours]? = nil, validUntilDate: ServiceDate? = nil) {
        self.stationID = stationID
        self.latE6 = latE6
        self.lonE6 = lonE6
        self.hours = hours
        self.validUntilDate = validUntilDate
    }
}

/// One weekly valet window: on each of ``isoWeekdays`` (1 = Monday … 7 = Sunday, ascending), from
/// `startMinute` (included) to `endMinute` (excluded), minutes after local midnight.
public struct ConfigValetHours: Sendable, Equatable, Codable {
    public var isoWeekdays: [Int]
    public var startMinute: Int
    public var endMinute: Int

    public init(isoWeekdays: [Int], startMinute: Int, endMinute: Int) {
        self.isoWeekdays = isoWeekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
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

// MARK: - Bike planning (M2c)
//
// Six optional top-level sections added within format 1. The compiler writes one only when its
// reviewed source exists (never a compiled-in default), so a document without them is byte for
// byte what it was before they were defined. The app plans bikes only when all six are present.
// Keys inside a present section are required unless marked optional.

/// Citi Bike availability: the probability model's tunables, the threshold bands by horizon,
/// pooled clusters, re-routing, the observed-trend blend and the cold-start prior. Probabilities
/// are whole percents, compared as `P ≥ percent / 100`.
public struct ConfigAvailability: Sendable, Equatable, Codable {
    /// A station passes when its P reaches this.
    public var targetPercent: Int
    /// An itinerary passes when the product of its stations' P reaches this.
    public var itineraryMinPercent: Int
    /// The lowest P labelled "Tight" (on re-plans; at or above the target is "Likely").
    public var tightMinPercent: Int
    /// By effective horizon τ (time to arrival plus the station report's age). Ordered: the first
    /// starts at 0, `fromSeconds` strictly ascends, and each runs to the next one's start; the
    /// last runs to ``ConfigAvailabilityPooled/afterSeconds`` inclusive.
    public var bands: [ConfigAvailabilityBand]
    public var pooled: ConfigAvailabilityPooled
    public var reroute: ConfigAvailabilityReroute
    public var trend: ConfigAvailabilityTrend
    public var variance: ConfigAvailabilityVariance
    public var coldStart: ConfigAvailabilityColdStart

    public init(targetPercent: Int, itineraryMinPercent: Int, tightMinPercent: Int, bands: [ConfigAvailabilityBand],
                pooled: ConfigAvailabilityPooled, reroute: ConfigAvailabilityReroute, trend: ConfigAvailabilityTrend,
                variance: ConfigAvailabilityVariance, coldStart: ConfigAvailabilityColdStart) {
        self.targetPercent = targetPercent
        self.itineraryMinPercent = itineraryMinPercent
        self.tightMinPercent = tightMinPercent
        self.bands = bands
        self.pooled = pooled
        self.reroute = reroute
        self.trend = trend
        self.variance = variance
        self.coldStart = coldStart
    }
}

/// One horizon band: the counts P is computed for, and hard floors on the counts reported now.
public struct ConfigAvailabilityBand: Sendable, Equatable, Codable {
    public var fromSeconds: Int
    /// P(at least this many bikes of the chosen type at pickup).
    public var pickupMinBikes: Int
    /// P(at least this many open docks at drop-off).
    public var dropoffMinDocks: Int
    /// The station fails when it reports fewer bikes of the chosen type than this now.
    public var pickupFloorBikes: Int
    /// The station fails when it reports fewer open docks than this now.
    public var dropoffFloorDocks: Int

    public init(fromSeconds: Int, pickupMinBikes: Int, dropoffMinDocks: Int, pickupFloorBikes: Int, dropoffFloorDocks: Int) {
        self.fromSeconds = fromSeconds
        self.pickupMinBikes = pickupMinBikes
        self.dropoffMinDocks = dropoffMinDocks
        self.pickupFloorBikes = pickupFloorBikes
        self.dropoffFloorDocks = dropoffFloorDocks
    }
}

/// Pooled mode, past the last band (and for depart-at): the target station plus its nearest
/// filtered neighbours count together, discounted.
public struct ConfigAvailabilityPooled: Sendable, Equatable, Codable {
    /// Pooled mode applies when τ is more than this.
    public var afterSeconds: Int
    /// Neighbours within this straight-line distance of the target join the cluster.
    public var radiusMeters: Int
    /// P_adj = P_target + (P_pool − P_target) × (100 − discountPercent) / 100.
    public var discountPercent: Int
    /// The cluster keeps at most this many stations, the target included, nearest walk first.
    public var maxStations: Int
    public var pickupMinBikes: Int
    public var dropoffMinDocks: Int

    public init(afterSeconds: Int, radiusMeters: Int, discountPercent: Int, maxStations: Int, pickupMinBikes: Int, dropoffMinDocks: Int) {
        self.afterSeconds = afterSeconds
        self.radiusMeters = radiusMeters
        self.discountPercent = discountPercent
        self.maxStations = maxStations
        self.pickupMinBikes = pickupMinBikes
        self.dropoffMinDocks = dropoffMinDocks
    }
}

/// During a ride: re-route when the dock's P falls below ``belowPercent`` while τ is at least
/// ``minHorizonSeconds``; closer than that, only when it reports no open dock.
public struct ConfigAvailabilityReroute: Sendable, Equatable, Codable {
    public var belowPercent: Int
    public var minHorizonSeconds: Int

    public init(belowPercent: Int, minHorizonSeconds: Int) {
        self.belowPercent = belowPercent
        self.minHorizonSeconds = minHorizonSeconds
    }
}

/// The observed-trend blend: once a station has been watched for ``minWatchSeconds`` (reports
/// spanning it with no gap over ``maxGapSeconds``), its drift over the last ``windowSeconds``,
/// ignoring report-to-report jumps larger than ``maxStepCount``, is blended into the model's net
/// flow with weight ``weightPercent``.
public struct ConfigAvailabilityTrend: Sendable, Equatable, Codable {
    public var minWatchSeconds: Int
    public var windowSeconds: Int
    public var weightPercent: Int
    public var maxStepCount: Int
    public var maxGapSeconds: Int

    public init(minWatchSeconds: Int, windowSeconds: Int, weightPercent: Int, maxStepCount: Int, maxGapSeconds: Int) {
        self.minWatchSeconds = minWatchSeconds
        self.windowSeconds = windowSeconds
        self.weightPercent = weightPercent
        self.maxStepCount = maxStepCount
        self.maxGapSeconds = maxGapSeconds
    }
}

/// How per-bin flows add up over a horizon.
public struct ConfigAvailabilityVariance: Sendable, Equatable, Codable {
    /// ρ, the correlation of the over-dispersion between bins: 0 = independent bins.
    public var crossBinCorrelationPercent: Int
    /// A scale on the summed variance (100 = as the flows give it). A factor, not a probability:
    /// it may exceed 100.
    public var inflationPercent: Int

    public init(crossBinCorrelationPercent: Int, inflationPercent: Int) {
        self.crossBinCorrelationPercent = crossBinCorrelationPercent
        self.inflationPercent = inflationPercent
    }
}

/// The prior for a station with no flows row: the capacity-scaled average of its
/// ``neighborCount`` nearest stations with trips within ``radiusMeters``; with none that close,
/// the nearest ones anyway, with P capped at ``farMaxPercent``.
public struct ConfigAvailabilityColdStart: Sendable, Equatable, Codable {
    public var neighborCount: Int
    public var radiusMeters: Int
    public var farMaxPercent: Int

    public init(neighborCount: Int, radiusMeters: Int, farMaxPercent: Int) {
        self.neighborCount = neighborCount
        self.radiusMeters = radiusMeters
        self.farMaxPercent = farMaxPercent
    }
}

/// Which bike itineraries are admitted and how options rank, plus the candidate limits.
public struct ConfigRules: Sendable, Equatable, Codable {
    /// Δ = max(deltaMinSeconds, (T0 − t_query) × deltaPercent / 100): a bike itinerary must
    /// arrive at least Δ before the no-bike baseline T0, and each extra bike leg at least Δ
    /// before the best with one bike leg fewer.
    public var deltaMinSeconds: Int
    public var deltaPercent: Int
    /// Every bike ride (unlock to dock) is at least this long.
    public var minRideSeconds: Int
    /// Pickups and docks are considered within this walk of the origin, destination or stop.
    public var stationWalkLimitSeconds: Int
    /// Per bike leg, an e-bike replaces an available classic only if it saves at least this…
    public var ebikeMinSavingSeconds: Int
    /// …and costs at most this much more than the classic per minute it saves (both timed at the
    /// rider's learned speed for their type). A per-leg allowance of its own, separate from the
    /// journey guardrail and by default looser.
    public var ebikeAllowanceCentsPerMinute: Int
    public var guardrail: ConfigGuardrail
    /// Score = arrival + transfers × this + …
    public var transferPenaltySeconds: Int
    /// … + this when the weather is at caution + Σ(1 − P_i) × F_i.
    public var cautionPenaltySeconds: Int
    /// Options scoring within this of the best form one bucket, ordered by fewer mode changes,
    /// then cost.
    public var bucketSeconds: Int
    /// Bike itineraries kept per bike-leg count.
    public var alternativesPerLayer: Int
    /// Stops per bike-leg count enriched with real time.
    public var enrichStopsPerLayer: Int

    public init(deltaMinSeconds: Int, deltaPercent: Int, minRideSeconds: Int, stationWalkLimitSeconds: Int,
                ebikeMinSavingSeconds: Int, ebikeAllowanceCentsPerMinute: Int, guardrail: ConfigGuardrail,
                transferPenaltySeconds: Int, cautionPenaltySeconds: Int, bucketSeconds: Int, alternativesPerLayer: Int,
                enrichStopsPerLayer: Int) {
        self.deltaMinSeconds = deltaMinSeconds
        self.deltaPercent = deltaPercent
        self.minRideSeconds = minRideSeconds
        self.stationWalkLimitSeconds = stationWalkLimitSeconds
        self.ebikeMinSavingSeconds = ebikeMinSavingSeconds
        self.ebikeAllowanceCentsPerMinute = ebikeAllowanceCentsPerMinute
        self.guardrail = guardrail
        self.transferPenaltySeconds = transferPenaltySeconds
        self.cautionPenaltySeconds = cautionPenaltySeconds
        self.bucketSeconds = bucketSeconds
        self.alternativesPerLayer = alternativesPerLayer
        self.enrichStopsPerLayer = enrichStopsPerLayer
    }
}

/// The journey cost guardrail: a bike itinerary may cost at most this much more than the
/// baseline per minute it saves. The rider picks one of ``choicesCentsPerMinute`` or "No limit"
/// (a rider setting, always offered, not a value here).
public struct ConfigGuardrail: Sendable, Equatable, Codable {
    public var defaultCentsPerMinute: Int
    /// Ascending, no repeats; includes the default.
    public var choicesCentsPerMinute: [Int]

    public init(defaultCentsPerMinute: Int, choicesCentsPerMinute: [Int]) {
        self.defaultCentsPerMinute = defaultCentsPerMinute
        self.choicesCentsPerMinute = choicesCentsPerMinute
    }
}

/// The weather gate: g(t) ∈ {allow, caution, block}, per 5-minute bucket of a bike leg's window.
public struct ConfigWeather: Sendable, Equatable, Codable {
    /// Each leg is judged per bucket of this length.
    public var bucketSeconds: Int
    /// Minute data decides rain blocks this far ahead of the fetch; hourly data after it.
    public var minuteHorizonSeconds: Int
    /// Past this the forecast is unavailable and the gate doesn't apply.
    public var forecastHorizonHours: Int
    /// History asked for (rain before the ride, snow cover).
    public var pastHours: Int
    public var cacheSeconds: Int
    public var cacheCellMeters: Int
    /// An alert without an onset and end (WeatherKit's) gates rides that start within this of
    /// the fetch.
    public var untimedAlertHours: Int
    /// A blocked leg offers "Leave at …" when the block clears within this.
    public var clearWithinSeconds: Int
    public var presets: ConfigWeatherPresets
    /// Alert text has no reliable type: the first rule with a keyword the lowercased alert event
    /// (or summary) contains gives its class; no match is ``ConfigWeatherAlertClass/unknown``. In
    /// priority order.
    public var alertKeywords: [ConfigWeatherAlertRule]

    public init(bucketSeconds: Int, minuteHorizonSeconds: Int, forecastHorizonHours: Int, pastHours: Int, cacheSeconds: Int,
                cacheCellMeters: Int, untimedAlertHours: Int, clearWithinSeconds: Int, presets: ConfigWeatherPresets,
                alertKeywords: [ConfigWeatherAlertRule]) {
        self.bucketSeconds = bucketSeconds
        self.minuteHorizonSeconds = minuteHorizonSeconds
        self.forecastHorizonHours = forecastHorizonHours
        self.pastHours = pastHours
        self.cacheSeconds = cacheSeconds
        self.cacheCellMeters = cacheCellMeters
        self.untimedAlertHours = untimedAlertHours
        self.clearWithinSeconds = clearWithinSeconds
        self.presets = presets
        self.alertKeywords = alertKeywords
    }
}

/// The rider's weather preset; every one is required.
public struct ConfigWeatherPresets: Sendable, Equatable, Codable {
    public var everyday: ConfigWeatherPreset
    public var fairWeather: ConfigWeatherPreset
    public var hardy: ConfigWeatherPreset

    public init(everyday: ConfigWeatherPreset, fairWeather: ConfigWeatherPreset, hardy: ConfigWeatherPreset) {
        self.everyday = everyday
        self.fairWeather = fairWeather
        self.hardy = hardy
    }
}

/// One preset's thresholds. Integers compared with measured values: "≥" and "≤" are inclusive,
/// "below" and "above" strict. Temperatures (`…F`, °F) may be negative.
public struct ConfigWeatherPreset: Sendable, Equatable, Codable {
    /// Rain during the ride, minute data: a minute with chance ≥ this…
    public var rainBlockMinuteChancePercent: Int
    /// …at intensity ≥ this blocks.
    public var rainBlockMinuteHundredthsInPerHour: Int
    /// Hourly data: chance ≥ this blocks…
    public var rainBlockHourlyChancePercent: Int
    /// …(when present, only if the hour's forecast amount is also ≥ this per hour). Optional:
    /// absent = the chance alone blocks.
    public var rainBlockRateHundredthsInPerHour: Int?
    /// Hourly chance ≥ this (and below the block chance) is caution.
    public var rainCautionHourlyChancePercent: Int
    /// Rain before the ride: at least this much over the lookback is caution.
    public var rainBeforeHundredthsIn: Int
    public var rainBeforeHours: Int
    /// The lookback when humidity is above ``rainBeforeHumidityPercent``, the temperature is
    /// below ``rainBeforeBelowF``, or it is night.
    public var rainBeforeLongHours: Int
    public var rainBeforeHumidityPercent: Int
    public var rainBeforeBelowF: Int
    /// A thunderstorm, freezing rain, sleet, hail or snow condition blocks, and so does a snow,
    /// sleet, hail or mixed precipitation kind at chance ≥ this.
    public var stormMinChancePercent: Int
    /// Snow cover: snowfall ≥ this over ``snowCoverHours``, with the temperature ≤
    /// ``snowCoverMaxF`` ever since the last snowfall hour, blocks.
    public var snowCoverTenthsIn: Int
    public var snowCoverMaxF: Int
    public var snowCoverHours: Int
    /// Ice: temperature ≤ this with any precipitation in the last ``iceLookbackHours`` blocks.
    public var iceMaxF: Int
    public var iceLookbackHours: Int
    /// Sustained wind ≥ this blocks.
    public var windBlockMph: Int
    /// Gusts ≥ this block.
    public var gustBlockMph: Int
    /// Sustained wind ≥ this (and below the block speed) is caution.
    public var windCautionMph: Int
    /// Feels-like below this blocks.
    public var feelsLikeBlockBelowF: Int
    /// Feels-like ≤ this (and not blocked) is caution.
    public var feelsLikeCautionAtOrBelowF: Int
    /// Feels-like ≥ this (and not blocked) is caution.
    public var feelsLikeCautionAtOrAboveF: Int
    /// Feels-like ≥ this blocks.
    public var feelsLikeBlockAtOrAboveF: Int
    /// Every caution blocks (Fair-weather).
    public var cautionBlocks: Bool
    public var alertVerdicts: ConfigWeatherAlertVerdicts

    public init(rainBlockMinuteChancePercent: Int, rainBlockMinuteHundredthsInPerHour: Int, rainBlockHourlyChancePercent: Int,
                rainBlockRateHundredthsInPerHour: Int? = nil, rainCautionHourlyChancePercent: Int, rainBeforeHundredthsIn: Int,
                rainBeforeHours: Int, rainBeforeLongHours: Int, rainBeforeHumidityPercent: Int, rainBeforeBelowF: Int,
                stormMinChancePercent: Int, snowCoverTenthsIn: Int, snowCoverMaxF: Int, snowCoverHours: Int, iceMaxF: Int,
                iceLookbackHours: Int, windBlockMph: Int, gustBlockMph: Int, windCautionMph: Int, feelsLikeBlockBelowF: Int,
                feelsLikeCautionAtOrBelowF: Int, feelsLikeCautionAtOrAboveF: Int, feelsLikeBlockAtOrAboveF: Int,
                cautionBlocks: Bool, alertVerdicts: ConfigWeatherAlertVerdicts) {
        self.rainBlockMinuteChancePercent = rainBlockMinuteChancePercent
        self.rainBlockMinuteHundredthsInPerHour = rainBlockMinuteHundredthsInPerHour
        self.rainBlockHourlyChancePercent = rainBlockHourlyChancePercent
        self.rainBlockRateHundredthsInPerHour = rainBlockRateHundredthsInPerHour
        self.rainCautionHourlyChancePercent = rainCautionHourlyChancePercent
        self.rainBeforeHundredthsIn = rainBeforeHundredthsIn
        self.rainBeforeHours = rainBeforeHours
        self.rainBeforeLongHours = rainBeforeLongHours
        self.rainBeforeHumidityPercent = rainBeforeHumidityPercent
        self.rainBeforeBelowF = rainBeforeBelowF
        self.stormMinChancePercent = stormMinChancePercent
        self.snowCoverTenthsIn = snowCoverTenthsIn
        self.snowCoverMaxF = snowCoverMaxF
        self.snowCoverHours = snowCoverHours
        self.iceMaxF = iceMaxF
        self.iceLookbackHours = iceLookbackHours
        self.windBlockMph = windBlockMph
        self.gustBlockMph = gustBlockMph
        self.windCautionMph = windCautionMph
        self.feelsLikeBlockBelowF = feelsLikeBlockBelowF
        self.feelsLikeCautionAtOrBelowF = feelsLikeCautionAtOrBelowF
        self.feelsLikeCautionAtOrAboveF = feelsLikeCautionAtOrAboveF
        self.feelsLikeBlockAtOrAboveF = feelsLikeBlockAtOrAboveF
        self.cautionBlocks = cautionBlocks
        self.alertVerdicts = alertVerdicts
    }
}

/// What a weather alert of each class does to a bike leg; every class is required.
public struct ConfigWeatherAlertVerdicts: Sendable, Equatable, Codable {
    public var thunderstorm: ConfigWeatherVerdict
    public var winterIce: ConfigWeatherVerdict
    public var highWind: ConfigWeatherVerdict
    public var extremeHeat: ConfigWeatherVerdict
    public var tornado: ConfigWeatherVerdict
    public var informational: ConfigWeatherVerdict
    public var unknown: ConfigWeatherVerdict

    public init(thunderstorm: ConfigWeatherVerdict, winterIce: ConfigWeatherVerdict, highWind: ConfigWeatherVerdict,
                extremeHeat: ConfigWeatherVerdict, tornado: ConfigWeatherVerdict, informational: ConfigWeatherVerdict,
                unknown: ConfigWeatherVerdict) {
        self.thunderstorm = thunderstorm
        self.winterIce = winterIce
        self.highWind = highWind
        self.extremeHeat = extremeHeat
        self.tornado = tornado
        self.informational = informational
        self.unknown = unknown
    }

    public subscript(alertClass: ConfigWeatherAlertClass) -> ConfigWeatherVerdict {
        switch alertClass {
        case .thunderstorm: thunderstorm
        case .winterIce: winterIce
        case .highWind: highWind
        case .extremeHeat: extremeHeat
        case .tornado: tornado
        case .informational: informational
        case .unknown: unknown
        }
    }
}

public enum ConfigWeatherVerdict: String, Sendable, Equatable, Codable, CaseIterable {
    case allow
    case caution
    case block
}

/// Weather alert classes. Strict, like every config enum: a new class needs a format bump or a
/// new optional key.
public enum ConfigWeatherAlertClass: String, Sendable, Equatable, Codable, CaseIterable {
    case thunderstorm
    case winterIce
    case highWind
    case extremeHeat
    case tornado
    /// Worth showing, not a reason to avoid a bike (coastal flood, rip current, air quality).
    case informational
    /// No rule matched. Never a rule's class.
    case unknown
}

public struct ConfigWeatherAlertRule: Sendable, Equatable, Codable {
    /// Lowercase substrings.
    public var keywords: [String]
    public var alertClass: ConfigWeatherAlertClass

    public init(keywords: [String], alertClass: ConfigWeatherAlertClass) {
        self.keywords = keywords
        self.alertClass = alertClass
    }

    enum CodingKeys: String, CodingKey {
        case keywords
        case alertClass = "class"
    }
}

/// Riding pace and speed learning. Each bike type (classic, e-bike) learns on its own: an
/// exponential moving average of its effective speed plus the residual standard deviation, from
/// ``ConfigSpeeds``' default for that type as seeded by the rider's pace setting.
public struct ConfigPace: Sendable, Equatable, Codable {
    /// The pace presets, as a percent of each type's speed: Relaxed, Typical, Fast. (The rider may
    /// instead enter a speed, clamped like a learned one.)
    public var relaxedPercent: Int
    public var typicalPercent: Int
    public var fastPercent: Int
    /// Learned and entered speeds are clamped to [min, max].
    public var minHundredthsMph: Int
    public var maxHundredthsMph: Int
    /// A type's learned speed is used once it has this many rides.
    public var learnAfterRides: Int
    /// Before a scheduled boarding, ride times use the 60th-percentile speed: the average minus
    /// this many hundredths of a standard deviation (25 = 0.25 SD).
    public var planSdHundredths: Int

    public init(relaxedPercent: Int, typicalPercent: Int, fastPercent: Int, minHundredthsMph: Int, maxHundredthsMph: Int,
                learnAfterRides: Int, planSdHundredths: Int) {
        self.relaxedPercent = relaxedPercent
        self.typicalPercent = typicalPercent
        self.fastPercent = fastPercent
        self.minHundredthsMph = minHundredthsMph
        self.maxHundredthsMph = maxHundredthsMph
        self.learnAfterRides = learnAfterRides
        self.planSdHundredths = planSdHundredths
    }
}

/// Riding speeds per bike type until the rider's own are learned.
public struct ConfigSpeeds: Sendable, Equatable, Codable {
    public var classicHundredthsMph: Int
    public var ebikeHundredthsMph: Int

    public init(classicHundredthsMph: Int, ebikeHundredthsMph: Int) {
        self.classicHundredthsMph = classicHundredthsMph
        self.ebikeHundredthsMph = ebikeHundredthsMph
    }
}

/// Fixed time on every bike ride besides riding: a ride takes unlock + ride + dock.
public struct ConfigOverheads: Sendable, Equatable, Codable {
    public var unlockSeconds: Int
    public var dockSeconds: Int

    public init(unlockSeconds: Int, dockSeconds: Int) {
        self.unlockSeconds = unlockSeconds
        self.dockSeconds = dockSeconds
    }
}
