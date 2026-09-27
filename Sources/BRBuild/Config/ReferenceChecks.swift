import BRConfig
import BRCore
import BRData
import BRGeo
import BRStreetCore
import BRTimetable
import Foundation

/// The outcome of one cross-artifact check of the config.
public struct ReferenceCheck: Codable, Sendable, Equatable {
    /// A stable name, e.g. `lirrZones`.
    public var name: String
    /// Items looked at (ids, rows, plans).
    public var checked: Int
    /// Each fails the build (the compiler) or the set (the gate).
    public var errors: [String]
    /// Reported, never fatal.
    public var warnings: [String]
    /// Why the check did not run (an input artifact is missing), or `nil`.
    public var skipped: String?

    public init(name: String, checked: Int = 0, errors: [String] = [], warnings: [String] = [], skipped: String? = nil) {
        self.name = name
        self.checked = checked
        self.errors = errors
        self.warnings = warnings
        self.skipped = skipped
    }

    public var passed: Bool { errors.isEmpty && skipped == nil }

    static func skipped(_ name: String, _ reason: String) -> ReferenceCheck {
        ReferenceCheck(name: name, skipped: reason)
    }
}

/// Checks that tie the config to the artifacts and feeds it describes, written once for both the
/// config compiler and the validation gate. The compiler runs them against the set being built;
/// the gate runs them on every build, because `tt-*` change twice a day while config is rebuilt
/// only when `Data/` changes (config's `builtAgainst` is empty on purpose).
///
/// Each function is pure over opened artifacts and returns one ``ReferenceCheck``; ``run(_:inputs:)``
/// runs them all over whatever inputs are present.
public enum ReferenceChecks {
    /// What the checks read. Any may be absent; the checks that need it are then skipped.
    public struct Inputs {
        public var timetables: [TransitSystem: Timetable]
        public var stations: MappedStations?
        /// Citi Bike's GBFS `system_pricing_plans.json`, for the price drift warning.
        public var pricingPlans: Data?
        /// The regions the stations compiler keeps (``StationSelection/regionIDs``).
        public var stationSelectionRegions: Set<String>?

        public init(timetables: [TransitSystem: Timetable] = [:], stations: MappedStations? = nil, pricingPlans: Data? = nil,
                    stationSelectionRegions: Set<String>? = StationSelection().regionIDs) {
            self.timetables = timetables
            self.stations = stations
            self.pricingPlans = pricingPlans
            self.stationSelectionRegions = stationSelectionRegions
        }
    }

    /// The most a valet station may lie from its listed coordinate.
    public static let valetMaxMeters = 50.0

    public static func run(_ document: ConfigDocument, inputs: Inputs) -> [ReferenceCheck] {
        let subway = inputs.timetables[.subway], lirr = inputs.timetables[.lirr]
        var checks: [ReferenceCheck] = []
        checks.append(subway.map { mtaStationPairs(document.fares.mta, subway: $0) }
            ?? .skipped("mtaStationPairs", "tt-subway.bin is missing"))
        checks.append(subway.map { statenIslandRailway(document.fares.mta.statenIslandRailway, subway: $0) }
            ?? .skipped("statenIslandRailway", "tt-subway.bin is missing"))
        checks.append(lirr.map { lirrZones(document.fares.lirr, lirr: $0) } ?? .skipped("lirrZones", "tt-lirr.bin is missing"))
        let fixedSystems = Set(document.transit.links.fixedTransfers.flatMap { [$0.from.system, $0.to.system] }.compactMap { $0 })
        let missing = fixedSystems.filter { inputs.timetables[$0] == nil }.map { ArtifactKind.timetable(for: $0).name }.sorted()
        checks.append(missing.isEmpty ? fixedTransfers(document.transit.links.fixedTransfers, timetables: inputs.timetables)
            : .skipped("fixedTransfers", missing.map { "\($0).bin" }.joined(separator: ", ") + " missing"))
        checks.append(inputs.stations.map { valetStations(document.bikeShare.valet, stations: $0) }
            ?? .skipped("valetStations", "stations.bin is missing"))
        checks.append(inputs.stations.map { stationRegions(document.bikeShare, stations: $0) }
            ?? .skipped("stationRegions", "stations.bin is missing"))
        if let regions = inputs.stationSelectionRegions {
            checks.append(stationSelectionRegions(document.bikeShare, selection: regions))
        }
        checks.append(inputs.pricingPlans.map { citiBikePricing(document.fares.citiBike, pricingPlans: $0) }
            ?? .skipped("citiBikePricing", "no GBFS system_pricing_plans.json"))
        return checks
    }

    // MARK: - MTA

    /// Every out-of-system and in-system pair names two stations (parent stops) of the subway
    /// feed, and no in-system pair is already linked by `transfers.txt` (it would be stale: drop
    /// it from the config). A pair that doesn't resolve would silently turn that walk into an
    /// in-station change or a second fare in the app.
    public static func mtaStationPairs(_ mta: ConfigMTAFares, subway: Timetable) -> ReferenceCheck {
        var check = ReferenceCheck(name: "mtaStationPairs")
        let listed = Set((0..<subway.transferCount).map(subway.transfer).map { StopPairKey($0.fromStop, $0.toStop) })
        for (key, pairs) in [("outOfSystemTransfers", mta.outOfSystemTransfers), ("inSystemTransfers", mta.inSystemTransfers)] {
            for pair in pairs {
                check.checked += 1
                var stops: [Int] = []
                for id in [pair.first, pair.second] {
                    guard let stop = subway.stop(id: id) else {
                        check.errors.append("fares.mta.\(key): \(id) is not in the subway feed")
                        continue
                    }
                    guard subway.stopKind(stop) == .station else {
                        check.errors.append("fares.mta.\(key): \(id) is a \(subway.stopKind(stop)), not a station")
                        continue
                    }
                    stops.append(stop)
                }
                if key == "inSystemTransfers", stops.count == 2, listed.contains(StopPairKey(stops[0], stops[1])) {
                    check.errors.append("fares.mta.inSystemTransfers: \(pair.first)–\(pair.second) is in transfers.txt now; drop it from Data/fares/mta.json")
                }
            }
        }
        return check
    }

    /// The SIR's routes are routes of the subway feed, and its fare stations are stations there.
    public static func statenIslandRailway(_ sir: ConfigStatenIslandRailway, subway: Timetable) -> ReferenceCheck {
        var check = ReferenceCheck(name: "statenIslandRailway")
        let routes = Set((0..<subway.routeCount).map { subway.route($0).id })
        for route in sir.routes {
            check.checked += 1
            if !routes.contains(route) { check.errors.append("fares.mta.statenIslandRailway.routes: \(route) is not a subway-feed route") }
        }
        for id in sir.fareStations {
            check.checked += 1
            guard let stop = subway.stop(id: id) else {
                check.errors.append("fares.mta.statenIslandRailway.fareStations: \(id) is not in the subway feed")
                continue
            }
            if subway.stopKind(stop) != .station {
                check.errors.append("fares.mta.statenIslandRailway.fareStations: \(id) is a \(subway.stopKind(stop)), not a station")
            }
        }
        return check
    }

    // MARK: - LIRR

    /// Every LIRR stop where some pattern lets riders board or alight has a fare zone, and every
    /// NYC terminal is such a stop. A zoned station riders can't use (Belmont Park today: the
    /// timetable compiler drops stops no trip calls at) is a warning: it prices again as soon as
    /// service returns.
    public static func lirrZones(_ fares: ConfigLIRRFares, lirr: Timetable) -> ReferenceCheck {
        var check = ReferenceCheck(name: "lirrZones")
        func served(_ stop: Int) -> Bool {
            lirr.patterns(servingStop: stop).contains {
                lirr.canBoard(pattern: $0.pattern, position: $0.position) || lirr.canAlight(pattern: $0.pattern, position: $0.position)
            }
        }
        let zoned = Set(fares.stations.map(\.stop))
        for stop in 0..<lirr.stopCount where served(stop) {
            check.checked += 1
            if !zoned.contains(lirr.stopID(stop)) {
                check.errors.append("fares.lirr.stations: \(lirr.stopID(stop)) \(lirr.stopName(stop)) has service but no fare zone")
            }
        }
        for station in fares.stations {
            guard let stop = lirr.stop(id: station.stop) else {
                check.warnings.append("fares.lirr.stations: \(station.stop) is zoned but not in tt-lirr")
                continue
            }
            if !served(stop) {
                check.warnings.append("fares.lirr.stations: \(station.stop) \(lirr.stopName(stop)) is zoned but riders can't board or alight there")
            }
        }
        for terminal in fares.nycTerminals {
            check.checked += 1
            guard let stop = lirr.stop(id: terminal) else {
                check.errors.append("fares.lirr.nycTerminals: \(terminal) is not in tt-lirr")
                continue
            }
            if !served(stop) {
                check.errors.append("fares.lirr.nycTerminals: \(terminal) \(lirr.stopName(stop)) has no boarding or alighting in tt-lirr")
            }
        }
        return check
    }

    // MARK: - Links

    /// Both ends of every fixed transfer resolve to a routable stop of their system's timetable:
    /// the stop itself, or a station with routable child platforms (the rule the links builder
    /// applies). An unresolved row would silently drop that walk from `links`.
    public static func fixedTransfers(_ transfers: [ConfigFixedTransfer], timetables: [TransitSystem: Timetable]) -> ReferenceCheck {
        var check = ReferenceCheck(name: "fixedTransfers")
        func routablePlatforms(_ id: StopID) -> Int? {
            guard let system = id.system, let timetable = timetables[system],
                  let stop = timetable.stop(gtfsID: String(id.gtfsID)) else { return nil }
            if !timetable.patterns(servingStop: stop).isEmpty { return 1 }
            return timetable.children(ofStop: stop).filter { !timetable.patterns(servingStop: Int($0)).isEmpty }.count
        }
        for fixed in transfers {
            check.checked += 1
            for id in [fixed.from, fixed.to] {
                switch routablePlatforms(id) {
                case nil: check.errors.append("transit.links.fixedTransfers: \(id) (\(fixed.from)→\(fixed.to)) is not in its timetable")
                case 0?: check.errors.append("transit.links.fixedTransfers: \(id) (\(fixed.from)→\(fixed.to)) has no routable platform")
                default: break
                }
            }
        }
        return check
    }

    // MARK: - Bike share

    /// Every valet station is a station of `stations.bin`, within ``valetMaxMeters`` of the
    /// coordinate it is listed at (a moved or renumbered station must be re-checked by hand).
    public static func valetStations(_ valet: [ConfigValetStation], stations: MappedStations,
                                     maxMeters: Double = valetMaxMeters) -> ReferenceCheck {
        var check = ReferenceCheck(name: "valetStations")
        for entry in valet {
            check.checked += 1
            guard let index = stations.index(ofStationID: entry.stationID) else {
                check.errors.append("bikeShare.valet: \(entry.stationID) is not in stations.bin")
                continue
            }
            let listed = Coordinate(lat: Double(entry.latE6) / 1e6, lon: Double(entry.lonE6) / 1e6)
            let meters = stations.coordinate(index).distance(to: listed)
            if meters > maxMeters {
                check.errors.append("bikeShare.valet: \(entry.stationID) \(stations.name(index)) is \(Int(meters.rounded())) m from its listed coordinate (limit \(Int(maxMeters)) m)")
            }
        }
        return check
    }

    /// Every station in `stations.bin` is in one of the config's regions, or has no region (it
    /// was kept by the service-area polygon).
    public static func stationRegions(_ bikeShare: ConfigBikeShare, stations: MappedStations) -> ReferenceCheck {
        var check = ReferenceCheck(name: "stationRegions")
        let allowed = Set(bikeShare.regions.all)
        var outside: [String: Int] = [:]
        for index in 0..<stations.count {
            check.checked += 1
            if let region = stations.regionID(index), !allowed.contains(region) { outside[region, default: 0] += 1 }
        }
        for (region, count) in outside.sorted(by: { $0.key < $1.key }) {
            check.errors.append("stations.bin: \(count) station(s) in region \(region), which bikeShare.regions doesn't list")
        }
        return check
    }

    /// The stations compiler's region list (a literal of the frozen `stations` build) equals the
    /// config's. Warning only: the two are built separately, and `stationRegions` catches a
    /// station that is actually outside.
    public static func stationSelectionRegions(_ bikeShare: ConfigBikeShare, selection: Set<String>) -> ReferenceCheck {
        var check = ReferenceCheck(name: "stationSelectionRegions", checked: selection.count)
        let config = Set(bikeShare.regions.all)
        if config != selection {
            check.warnings.append("bikeShare.regions \(config.sorted()) differ from the stations compiler's \(selection.sorted())")
        }
        return check
    }

    // MARK: - Citi Bike prices

    /// Compares the non-member e-bike price with Citi Bike's GBFS `system_pricing_plans`
    /// (`EBIKE_SINGLE_RIDE`: `price` is the unlock fee, the first `per_min_pricing` segment the
    /// per-minute rate). Warnings only: the feed is Lyft's, not the fare authority, and a price
    /// change needs a reviewed edit of `Data/fares/citibike.json` anyway. Plans the feed lists that
    /// nothing is compared with are reported too, so a new plan is noticed.
    public static func citiBikePricing(_ fares: ConfigCitiBikeFares, pricingPlans json: Data) -> ReferenceCheck {
        var check = ReferenceCheck(name: "citiBikePricing")
        let feed: PricingPlansFeed
        do {
            feed = try JSONDecoder().decode(PricingPlansFeed.self, from: json)
        } catch {
            check.warnings.append("system_pricing_plans.json does not decode: \(error)")
            return check
        }
        let nonMember = fares.plans.nonMember
        for plan in feed.data.plans {
            check.checked += 1
            guard plan.planID == "EBIKE_SINGLE_RIDE" else {
                check.warnings.append("GBFS plan \(plan.planID) (\(plan.name ?? "")) is not compared with any config plan")
                continue
            }
            if plan.price.cents != nonMember.unlockFeeCents {
                check.warnings.append("GBFS \(plan.planID) price \(plan.price.text) ≠ fares.citiBike.plans.nonMember.unlockFeeCents \(nonMember.unlockFeeCents)")
            }
            let rate = plan.perMinutePricing?.first { $0.start.cents == 0 }
            if let rate, rate.interval.cents != 100 {
                check.warnings.append("GBFS \(plan.planID) per-minute interval \(rate.interval.text) is not 1 minute")
            }
            if rate?.rate.cents != nonMember.ebikePerMinuteCents {
                check.warnings.append("GBFS \(plan.planID) per-minute rate \(rate?.rate.text ?? "none") ≠ fares.citiBike.plans.nonMember.ebikePerMinuteCents \(nonMember.ebikePerMinuteCents)")
            }
        }
        if !feed.data.plans.contains(where: { $0.planID == "EBIKE_SINGLE_RIDE" }) {
            check.warnings.append("GBFS system_pricing_plans lists no EBIKE_SINGLE_RIDE plan; nothing compared")
        }
        return check
    }

    private struct PricingPlansFeed: Decodable {
        struct Payload: Decodable { let plans: [Plan] }
        struct Plan: Decodable {
            let planID: String
            let name: String?
            let price: Amount
            let perMinutePricing: [Segment]?
            enum CodingKeys: String, CodingKey { case planID = "plan_id", name, price, perMinutePricing = "per_min_pricing" }
        }
        struct Segment: Decodable {
            let start: Amount
            let rate: Amount
            let interval: Amount
        }
        let data: Payload
    }

    /// A GBFS amount written as a number or a decimal string (`"4.99"`), read exactly: parsed
    /// as a decimal, never through binary floating point.
    struct Amount: Decodable {
        let text: String
        /// Hundredths (cents for prices; hundredths of the unit otherwise), or `nil` if the
        /// amount has more than two decimals.
        let cents: Int?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                text = string
            } else {
                // A JSON number: Decimal keeps its decimal digits (0.41 stays 0.41).
                text = "\(try container.decode(Decimal.self))"
            }
            cents = Self.hundredths(text)
        }

        static func hundredths(_ text: String) -> Int? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let whole = Int(parts[0]), whole >= 0 else { return nil }
            var fraction = parts.count == 2 ? String(parts[1]) : ""
            while fraction.count > 2, fraction.hasSuffix("0") { fraction.removeLast() }
            guard fraction.count <= 2, fraction.allSatisfy(\.isASCII), fraction.allSatisfy(\.isNumber) else { return nil }
            return whole * 100 + (Int(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0)
        }
    }
}

/// An unordered pair of stop indices.
private struct StopPairKey: Hashable {
    let low: Int, high: Int
    init(_ a: Int, _ b: Int) { (low, high) = (min(a, b), max(a, b)) }
}
