import BRCore

/// The intrinsic checks on a ``ConfigDocument``: rules that need nothing but the document.
///
/// Two levels, so a later config never locks out an older app over a writer convention:
/// - ``structuralIssues(_:)``: what an engine needs for the document to mean anything (ranges,
///   uniqueness, a complete LIRR zone matrix). ``MappedConfig`` rejects a document that fails one.
/// - ``canonicalIssues(_:)``: those, plus the writer's rules (set-like arrays sorted by UTF-8
///   bytes, system-qualified ids, holidays on weekdays, CityTicket only in zones 1 and 3,
///   lowercase alert keywords). The compiler refuses to write a document that fails one.
///
/// Each issue is one line naming the key path, e.g. `fares.lirr.zoneFares: no fare for zones 1–3`.
public enum ConfigValidation {
    public static func structuralIssues(_ document: ConfigDocument) -> [String] {
        var issues = Issues()
        structural(document, &issues)
        return issues.list
    }

    public static func canonicalIssues(_ document: ConfigDocument) -> [String] {
        var issues = Issues()
        structural(document, &issues)
        canonical(document, &issues)
        return issues.list
    }

    /// The largest value a `links` `u16` seconds field holds.
    public static let maxLinkSeconds = Int(UInt16.max) - 1
    /// The largest footpath walk bound `links` accepts.
    public static let maxFootpathWalkSeconds = 3600

    // MARK: - Structural

    private static func structural(_ d: ConfigDocument, _ issues: inout Issues) {
        issues.check(d.minAppFormat >= 1, "minAppFormat: must be at least 1")
        issues.check(!d.flags.keys.contains(""), "flags: empty flag name")

        // Calendar.
        issues.unique(d.calendar.holidays.map(\.date.yyyymmdd), "calendar.holidays", what: "date")
        for holiday in d.calendar.holidays where holiday.name.isEmpty {
            issues.add("calendar.holidays: \(holiday.date.yyyymmdd) has no name")
        }

        // MTA.
        let mta = d.fares.mta
        issues.nonNegative(["baseFareCents": mta.baseFareCents, "expressBusFareCents": mta.expressBusFareCents,
                            "expressBusStepUpCents": mta.expressBusStepUpCents], "fares.mta")
        issues.check(mta.transferWindowSeconds > 0, "fares.mta.transferWindowSeconds: must be positive")
        for (key, pairs) in [("outOfSystemTransfers", mta.outOfSystemTransfers), ("inSystemTransfers", mta.inSystemTransfers)] {
            for pair in pairs where pair.first == pair.second {
                issues.add("fares.mta.\(key): \(pair.first) is paired with itself")
            }
            issues.unique(pairs.map { "\($0.first)|\($0.second)" }, "fares.mta.\(key)", what: "pair")
        }
        let outside = Set(mta.outOfSystemTransfers.map { "\($0.first)|\($0.second)" })
        for pair in mta.inSystemTransfers where outside.contains("\(pair.first)|\(pair.second)") {
            issues.add("fares.mta: \(pair.first)–\(pair.second) is both an in-system and an out-of-system transfer")
        }
        issues.check(!mta.statenIslandRailway.routes.isEmpty, "fares.mta.statenIslandRailway.routes: empty")
        issues.unique(mta.statenIslandRailway.routes.map(\.rawValue), "fares.mta.statenIslandRailway.routes", what: "route")
        issues.unique(mta.statenIslandRailway.fareStations.map(\.rawValue), "fares.mta.statenIslandRailway.fareStations", what: "stop")

        // PATH.
        issues.nonNegative(["fareCents": d.fares.path.fareCents], "fares.path")

        // LIRR.
        let lirr = d.fares.lirr
        issues.check(!lirr.stations.isEmpty, "fares.lirr.stations: empty")
        issues.unique(lirr.stations.map(\.stop.rawValue), "fares.lirr.stations", what: "stop")
        for station in lirr.stations where station.zone <= 0 {
            issues.add("fares.lirr.stations: \(station.stop) has zone \(station.zone)")
        }
        var fares: [ZonePair: Int] = [:]
        for fare in lirr.zoneFares {
            let pair = ZonePair(fare.fromZone, fare.toZone)
            if fares[pair] != nil { issues.add("fares.lirr.zoneFares: zones \(pair) listed twice") }
            fares[pair, default: 0] += 1
            if fare.peakCents < 0 || fare.offPeakCents < 0 { issues.add("fares.lirr.zoneFares: zones \(pair) has a negative fare") }
        }
        let zones = Set(lirr.stations.map(\.zone)).sorted()
        for (i, a) in zones.enumerated() {
            for b in zones[i...] where fares[ZonePair(a, b)] == nil {
                issues.add("fares.lirr.zoneFares: no fare for zones \(a)–\(b)")
            }
        }
        issues.nonNegative(["cityTicket.peakCents": lirr.cityTicket.peakCents, "cityTicket.offPeakCents": lirr.cityTicket.offPeakCents,
                            "farRockawayTicket.peakCents": lirr.farRockawayTicket.peakCents,
                            "farRockawayTicket.offPeakCents": lirr.farRockawayTicket.offPeakCents], "fares.lirr")
        issues.check(lirr.farRockawayTicket.destinationZone > 0, "fares.lirr.farRockawayTicket.destinationZone: must be positive")
        for (key, window) in [("terminalArrivals", lirr.peakRule.terminalArrivals), ("terminalDepartures", lirr.peakRule.terminalDepartures)] {
            issues.check(window.startMinute >= 0 && window.startMinute < window.endMinute && window.endMinute <= 24 * 60,
                         "fares.lirr.peakRule.\(key): needs 0 ≤ startMinute < endMinute ≤ 1440")
        }
        issues.unique(lirr.nycTerminals.map(\.rawValue), "fares.lirr.nycTerminals", what: "stop")

        // Citi Bike.
        let plans = d.fares.citiBike.plans
        for (name, plan) in [("nonMember", plans.nonMember), ("member", plans.member), ("dayPass", plans.dayPass),
                             ("reducedFare", plans.reducedFare)] {
            var values = ["unlockFeeCents": plan.unlockFeeCents, "classicIncludedMinutes": plan.classicIncludedMinutes,
                          "classicPerMinuteCents": plan.classicPerMinuteCents, "ebikePerMinuteCents": plan.ebikePerMinuteCents]
            if let price = plan.planPriceCents { values["planPriceCents"] = price }
            if let cap = plan.ebikeManhattanCap {
                values["ebikeManhattanCap.amountCents"] = cap.amountCents
                issues.check(cap.maxRideMinutes > 0, "fares.citiBike.plans.\(name).ebikeManhattanCap.maxRideMinutes: must be positive")
            }
            issues.nonNegative(values, "fares.citiBike.plans.\(name)")
        }

        // Transit.
        let t = d.transit
        issues.nonNegative(t.sameStopChangeSeconds.named("sameStopChangeSeconds"), "transit")
        issues.nonNegative(["guaranteedTransferSeconds": t.guaranteedTransferSeconds,
                            "minimumPlatformChangeSeconds": t.minimumPlatformChangeSeconds,
                            "accessSlack.baseSeconds": t.accessSlack.baseSeconds, "accessSlack.walkPercent": t.accessSlack.walkPercent,
                            "afterBikeChange.minSeconds": t.afterBikeChange.minSeconds,
                            "afterBikeChange.ridePercent": t.afterBikeChange.ridePercent,
                            "extraLeg.minSavingSeconds": t.extraLeg.minSavingSeconds], "transit")
        issues.positive(["extraLeg.pruneRound": t.extraLeg.pruneRound, "maxJourneySeconds": t.maxJourneySeconds,
                         "accessWalkLimitSeconds": t.accessWalkLimitSeconds, "directWalkLimitSeconds": t.directWalkLimitSeconds,
                         "originSnapMeters": t.originSnapMeters], "transit")

        // Links.
        let links = t.links
        for (key, value) in links.stationAccessSeconds.named("stationAccessSeconds") where !(0...maxLinkSeconds).contains(value) {
            issues.add("transit.links.\(key): must be 0…\(maxLinkSeconds)")
        }
        issues.positive(links.maxSnapMeters.named("maxSnapMeters"), "transit.links")
        issues.check((1...maxFootpathWalkSeconds).contains(links.maxFootpathWalkSeconds),
                     "transit.links.maxFootpathWalkSeconds: must be 1…\(maxFootpathWalkSeconds)")
        issues.check((0...maxLinkSeconds).contains(links.minTransferSeconds),
                     "transit.links.minTransferSeconds: must be 0…\(maxLinkSeconds)")
        issues.positive(["stationLinkMaxWalkMeters": links.stationLinkMaxWalkMeters,
                         "walkSpeedHundredthsMph": links.walkSpeedHundredthsMph], "transit.links")
        issues.unique(links.streetAccessOnlyInsideServiceArea.map(\.rawValue), "transit.links.streetAccessOnlyInsideServiceArea",
                      what: "system")
        var fixedPairs = Set<String>()
        for fixed in links.fixedTransfers {
            if fixed.from == fixed.to { issues.add("transit.links.fixedTransfers: \(fixed.from) to itself") }
            if !(1...maxLinkSeconds).contains(fixed.seconds) {
                issues.add("transit.links.fixedTransfers: \(fixed.from)→\(fixed.to) seconds must be 1…\(maxLinkSeconds)")
            }
            let pair = ConfigStationPair(fixed.from, fixed.to)
            if !fixedPairs.insert("\(pair.first)|\(pair.second)").inserted {
                issues.add("transit.links.fixedTransfers: \(pair.first)–\(pair.second) listed twice (each applies both ways)")
            }
        }

        // Bike share.
        let bikes = d.bikeShare
        issues.check(!bikes.regions.all.isEmpty, "bikeShare.regions: empty")
        issues.unique(bikes.regions.all, "bikeShare.regions", what: "region")
        issues.unique(bikes.excludedRegions, "bikeShare.excludedRegions", what: "region")
        issues.check(!bikes.vehicleTypes.classic.isEmpty && !bikes.vehicleTypes.ebike.isEmpty, "bikeShare.vehicleTypes: empty")
        issues.unique(bikes.vehicleTypes.classic + bikes.vehicleTypes.ebike, "bikeShare.vehicleTypes", what: "vehicle type")
        issues.positive(["maxStatusAgeSeconds": bikes.maxStatusAgeSeconds], "bikeShare")
        issues.unique(bikes.valet.map(\.stationID), "bikeShare.valet", what: "station")
        for valet in bikes.valet {
            if valet.stationID.isEmpty { issues.add("bikeShare.valet: empty stationID") }
            if abs(valet.latE6) > 90_000_000 || abs(valet.lonE6) > 180_000_000 {
                issues.add("bikeShare.valet: \(valet.stationID) has an impossible coordinate")
            }
        }

        // Alerts.
        for (index, rule) in d.alerts.pathKeywords.enumerated() {
            if rule.keywords.isEmpty { issues.add("alerts.pathKeywords[\(index)]: no keywords") }
            if rule.keywords.contains("") { issues.add("alerts.pathKeywords[\(index)]: empty keyword") }
        }
    }

    // MARK: - Canonical (writer) rules

    private static func canonical(_ d: ConfigDocument, _ issues: inout Issues) {
        let dates = d.calendar.holidays.map(\.date)
        issues.check(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 }, "calendar.holidays: dates must be strictly ascending")
        for holiday in d.calendar.holidays where holiday.date.weekday.rawValue > Weekday.friday.rawValue {
            issues.add("calendar.holidays: \(holiday.date.yyyymmdd) is not a Monday–Friday (list the observed day)")
        }

        let mta = d.fares.mta
        for (key, pairs) in [("outOfSystemTransfers", mta.outOfSystemTransfers), ("inSystemTransfers", mta.inSystemTransfers)] {
            issues.ascending(pairs.map { [$0.first.rawValue, $0.second.rawValue] }, "fares.mta.\(key)")
            for pair in pairs { issues.qualified([pair.first, pair.second], .subway, "fares.mta.\(key)") }
        }
        issues.ascending(mta.statenIslandRailway.routes.map { [$0.rawValue] }, "fares.mta.statenIslandRailway.routes")
        issues.ascending(mta.statenIslandRailway.fareStations.map { [$0.rawValue] }, "fares.mta.statenIslandRailway.fareStations")
        for route in mta.statenIslandRailway.routes where route.system != .subway {
            issues.add("fares.mta.statenIslandRailway.routes: \(route) is not a subway-feed route (S:…)")
        }
        issues.qualified(mta.statenIslandRailway.fareStations, .subway, "fares.mta.statenIslandRailway.fareStations")

        let lirr = d.fares.lirr
        issues.ascending(lirr.stations.map { [$0.stop.rawValue] }, "fares.lirr.stations")
        issues.qualified(lirr.stations.map(\.stop), .lirr, "fares.lirr.stations")
        for fare in lirr.zoneFares where fare.fromZone > fare.toZone {
            issues.add("fares.lirr.zoneFares: write zones \(fare.fromZone)–\(fare.toZone) as fromZone ≤ toZone")
        }
        let zonePairs = lirr.zoneFares.map { [$0.fromZone, $0.toZone] }
        issues.check(zip(zonePairs, zonePairs.dropFirst()).allSatisfy { $0.lexicographicallyPrecedes($1) },
                     "fares.lirr.zoneFares: must be strictly ascending by (fromZone, toZone)")
        let usedZones = Set(lirr.stations.map(\.zone))
        for fare in lirr.zoneFares where !usedZones.contains(fare.fromZone) || !usedZones.contains(fare.toZone) {
            issues.add("fares.lirr.zoneFares: zones \(fare.fromZone)–\(fare.toZone) include a zone no station is in")
        }
        for station in lirr.stations where station.cityFare == .cityTicket && ![1, 3].contains(station.zone) {
            issues.add("fares.lirr.stations: \(station.stop) is cityTicket in zone \(station.zone) (CityTicket covers zones 1 and 3)")
        }
        issues.check(usedZones.contains(lirr.farRockawayTicket.destinationZone),
                     "fares.lirr.farRockawayTicket.destinationZone: no station is in zone \(lirr.farRockawayTicket.destinationZone)")
        issues.check(lirr.stations.contains { $0.cityFare == .farRockaway }, "fares.lirr.stations: no farRockaway station sells the ticket")
        issues.ascending(lirr.nycTerminals.map { [$0.rawValue] }, "fares.lirr.nycTerminals")
        let zoneOf = Dictionary(lirr.stations.map { ($0.stop, $0.zone) }, uniquingKeysWith: { a, _ in a })
        for terminal in lirr.nycTerminals where zoneOf[terminal] != 1 {
            issues.add("fares.lirr.nycTerminals: \(terminal) is not a zone 1 station")
        }
        issues.check(!lirr.nycTerminals.isEmpty, "fares.lirr.nycTerminals: empty (every peak-rule train would be off-peak)")

        let links = d.transit.links
        issues.ascending(links.streetAccessOnlyInsideServiceArea.map { [$0.rawValue] }, "transit.links.streetAccessOnlyInsideServiceArea")
        issues.ascending(links.fixedTransfers.map { [$0.from.rawValue, $0.to.rawValue] }, "transit.links.fixedTransfers")
        for fixed in links.fixedTransfers where fixed.from.system == nil || fixed.to.system == nil {
            issues.add("transit.links.fixedTransfers: \(fixed.from)→\(fixed.to) needs system-qualified ids")
        }

        let bikes = d.bikeShare
        issues.ascending(bikes.regions.nyc.map { [$0] }, "bikeShare.regions.nyc")
        issues.ascending(bikes.regions.newJersey.map { [$0] }, "bikeShare.regions.newJersey")
        issues.ascending(bikes.excludedRegions.map { [$0] }, "bikeShare.excludedRegions")
        for region in bikes.excludedRegions where bikes.regions.all.contains(region) {
            issues.add("bikeShare.excludedRegions: \(region) is also a service-area region")
        }
        issues.ascending(bikes.vehicleTypes.classic.map { [$0] }, "bikeShare.vehicleTypes.classic")
        issues.ascending(bikes.vehicleTypes.ebike.map { [$0] }, "bikeShare.vehicleTypes.ebike")
        issues.ascending(bikes.valet.map { [$0.stationID] }, "bikeShare.valet")

        var seenKeywords = Set<String>(), seenSeverities = Set<ConfigAlertSeverity>()
        for (index, rule) in d.alerts.pathKeywords.enumerated() {
            issues.ascending(rule.keywords.map { [$0] }, "alerts.pathKeywords[\(index)].keywords")
            for keyword in rule.keywords {
                if keyword != keyword.lowercased() { issues.add("alerts.pathKeywords: '\(keyword)' must be lowercase") }
                if !seenKeywords.insert(keyword).inserted { issues.add("alerts.pathKeywords: '\(keyword)' is in two rules") }
            }
            if !seenSeverities.insert(rule.severity).inserted {
                issues.add("alerts.pathKeywords: \(rule.severity.rawValue) has two rules (merge them)")
            }
        }
    }

    // MARK: - Helpers

    private struct ZonePair: Hashable, CustomStringConvertible {
        let low: Int, high: Int
        init(_ a: Int, _ b: Int) { (low, high) = (min(a, b), max(a, b)) }
        var description: String { "\(low)–\(high)" }
    }

    struct Issues {
        private(set) var list: [String] = []

        mutating func add(_ issue: String) { list.append(issue) }

        mutating func check(_ condition: Bool, _ issue: @autoclosure () -> String) {
            if !condition { list.append(issue()) }
        }

        mutating func nonNegative(_ values: [String: Int], _ prefix: String) {
            for key in values.keys.sorted() where values[key]! < 0 { add("\(prefix).\(key): must not be negative") }
        }

        mutating func positive(_ values: [String: Int], _ prefix: String) {
            for key in values.keys.sorted() where values[key]! <= 0 { add("\(prefix).\(key): must be positive") }
        }

        mutating func unique(_ values: [String], _ path: String, what: String) {
            var seen = Set<String>()
            for value in values where !seen.insert(value).inserted { add("\(path): \(what) \(value) listed twice") }
        }

        /// Strictly ascending by the UTF-8 bytes of each key tuple, compared field by field.
        mutating func ascending(_ keys: [[String]], _ path: String) {
            func precedes(_ a: [String], _ b: [String]) -> Bool {
                for (x, y) in zip(a, b) where x != y { return x.utf8.lexicographicallyPrecedes(y.utf8) }
                return a.count < b.count
            }
            for (index, (a, b)) in zip(keys, keys.dropFirst()).enumerated() where !precedes(a, b) {
                add("\(path): entry \(index + 1) (\(b.joined(separator: " "))) is not after \(a.joined(separator: " ")) (sorted by UTF-8 bytes, no repeats)")
                return
            }
        }

        mutating func qualified(_ stops: [StopID], _ system: TransitSystem, _ path: String) {
            for stop in stops where stop.system != system || stop.gtfsID.isEmpty {
                add("\(path): \(stop) is not a \(system.rawValue):… id")
            }
        }
    }
}

extension ConfigSystemValues {
    /// `prefix.subway` … `prefix.path` → value.
    func named(_ prefix: String) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: TransitSystem.allCases.map { ("\(prefix).\(ConfigTransitSystem($0).rawValue)", self[$0]) })
    }
}
