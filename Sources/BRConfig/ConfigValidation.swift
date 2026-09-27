import BRCore

/// The intrinsic checks on a ``ConfigDocument``: rules that need nothing but the document.
///
/// Two levels, so a later config never locks out an older app over a writer convention:
/// - ``structuralIssues(_:)``: what an engine needs for the document to mean anything (ranges,
///   uniqueness, a complete LIRR zone matrix). ``MappedConfig`` rejects a document that fails one.
/// - ``canonicalIssues(_:)``: those, plus the writer's rules (set-like arrays sorted by UTF-8
///   bytes, system-qualified ids, holidays on weekdays, CityTicket only in zones 1 and 3,
///   lowercase and reachable alert keywords). The compiler refuses to write a document that fails one.
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
            for (index, window) in (valet.hours ?? []).enumerated() {
                let path = "bikeShare.valet: \(valet.stationID) hours[\(index)]"
                if window.isoWeekdays.isEmpty { issues.add("\(path) has no weekdays") }
                if window.isoWeekdays.contains(where: { !(1...7).contains($0) }) { issues.add("\(path): isoWeekdays must be 1…7") }
                if Set(window.isoWeekdays).count != window.isoWeekdays.count { issues.add("\(path): a weekday is listed twice") }
                issues.check(window.startMinute >= 0 && window.startMinute < window.endMinute && window.endMinute <= 24 * 60,
                             "\(path): needs 0 ≤ startMinute < endMinute ≤ 1440")
            }
        }

        // Alerts.
        for (index, rule) in d.alerts.pathKeywords.enumerated() {
            if rule.keywords.isEmpty { issues.add("alerts.pathKeywords[\(index)]: no keywords") }
            if rule.keywords.contains("") { issues.add("alerts.pathKeywords[\(index)]: empty keyword") }
        }

        // The M2c bike-planning sections, each only when present.
        if let availability = d.availability { structural(availability, &issues) }
        if let rules = d.rules { structural(rules, &issues) }
        if let weather = d.weather { structural(weather, &issues) }
        if let pace = d.pace {
            issues.positive(["relaxedPercent": pace.relaxedPercent, "typicalPercent": pace.typicalPercent, "fastPercent": pace.fastPercent,
                             "minHundredthsMph": pace.minHundredthsMph, "maxHundredthsMph": pace.maxHundredthsMph], "pace")
            issues.nonNegative(["learnAfterRides": pace.learnAfterRides, "planSdHundredths": pace.planSdHundredths], "pace")
            issues.check(pace.minHundredthsMph <= pace.maxHundredthsMph, "pace: minHundredthsMph must not exceed maxHundredthsMph")
        }
        if let speeds = d.speeds {
            let values = ["classicHundredthsMph": speeds.classicHundredthsMph, "ebikeHundredthsMph": speeds.ebikeHundredthsMph]
            issues.positive(values, "speeds")
            if let pace = d.pace {
                for key in values.keys.sorted() where !(pace.minHundredthsMph...max(pace.minHundredthsMph, pace.maxHundredthsMph)).contains(values[key]!) {
                    issues.add("speeds.\(key): must be within pace.minHundredthsMph…pace.maxHundredthsMph")
                }
            }
        }
        if let overheads = d.overheads {
            issues.nonNegative(["unlockSeconds": overheads.unlockSeconds, "dockSeconds": overheads.dockSeconds], "overheads")
        }
    }

    private static func structural(_ a: ConfigAvailability, _ issues: inout Issues) {
        issues.percent(["targetPercent": a.targetPercent, "itineraryMinPercent": a.itineraryMinPercent, "tightMinPercent": a.tightMinPercent,
                        "pooled.discountPercent": a.pooled.discountPercent, "reroute.belowPercent": a.reroute.belowPercent,
                        "trend.weightPercent": a.trend.weightPercent,
                        "variance.crossBinCorrelationPercent": a.variance.crossBinCorrelationPercent,
                        "coldStart.farMaxPercent": a.coldStart.farMaxPercent], "availability")
        issues.check(a.tightMinPercent <= a.targetPercent, "availability.tightMinPercent: must not exceed targetPercent")
        // A capped cold-start station is never "Likely".
        issues.check(a.coldStart.farMaxPercent < a.targetPercent, "availability.coldStart.farMaxPercent: must be below targetPercent")
        if a.bands.isEmpty {
            issues.add("availability.bands: empty")
        } else {
            issues.check(a.bands[0].fromSeconds == 0, "availability.bands: the first band must start at fromSeconds 0")
            for (index, (earlier, later)) in zip(a.bands, a.bands.dropFirst()).enumerated() where later.fromSeconds <= earlier.fromSeconds {
                issues.add("availability.bands[\(index + 1)]: fromSeconds \(later.fromSeconds) must be after \(earlier.fromSeconds) (strictly ascending)")
            }
            let last = a.bands[a.bands.count - 1].fromSeconds
            issues.check(last < a.pooled.afterSeconds,
                         "availability.bands: the last band starts at \(last) s, not before pooled.afterSeconds \(a.pooled.afterSeconds)")
        }
        // The counts P is asked about are at least 1 (P of ≥ 0 is always 1); a floor of 0 is no floor.
        for (index, band) in a.bands.enumerated() {
            issues.nonNegative(["fromSeconds": band.fromSeconds, "pickupFloorBikes": band.pickupFloorBikes,
                                "dropoffFloorDocks": band.dropoffFloorDocks], "availability.bands[\(index)]")
            issues.positive(["pickupMinBikes": band.pickupMinBikes, "dropoffMinDocks": band.dropoffMinDocks], "availability.bands[\(index)]")
        }
        issues.positive(["pooled.afterSeconds": a.pooled.afterSeconds, "pooled.radiusMeters": a.pooled.radiusMeters,
                         "pooled.pickupMinBikes": a.pooled.pickupMinBikes, "pooled.dropoffMinDocks": a.pooled.dropoffMinDocks,
                         "pooled.maxStations": a.pooled.maxStations, "trend.maxGapSeconds": a.trend.maxGapSeconds,
                         "variance.inflationPercent": a.variance.inflationPercent, "coldStart.neighborCount": a.coldStart.neighborCount,
                         "coldStart.radiusMeters": a.coldStart.radiusMeters], "availability")
        issues.nonNegative(["reroute.minHorizonSeconds": a.reroute.minHorizonSeconds, "trend.minWatchSeconds": a.trend.minWatchSeconds,
                            "trend.windowSeconds": a.trend.windowSeconds, "trend.maxStepCount": a.trend.maxStepCount], "availability")
        issues.check(a.trend.windowSeconds >= a.trend.minWatchSeconds, "availability.trend.windowSeconds: must be at least minWatchSeconds")
    }

    private static func structural(_ r: ConfigRules, _ issues: inout Issues) {
        issues.nonNegative(["deltaMinSeconds": r.deltaMinSeconds, "minRideSeconds": r.minRideSeconds,
                            "stationWalkLimitSeconds": r.stationWalkLimitSeconds, "ebikeMinSavingSeconds": r.ebikeMinSavingSeconds,
                            "ebikeAllowanceCentsPerMinute": r.ebikeAllowanceCentsPerMinute,
                            "guardrail.defaultCentsPerMinute": r.guardrail.defaultCentsPerMinute,
                            "transferPenaltySeconds": r.transferPenaltySeconds, "cautionPenaltySeconds": r.cautionPenaltySeconds,
                            "bucketSeconds": r.bucketSeconds], "rules")
        issues.percent(["deltaPercent": r.deltaPercent], "rules")
        issues.positive(["alternativesPerLayer": r.alternativesPerLayer, "enrichStopsPerLayer": r.enrichStopsPerLayer], "rules")
        let choices = r.guardrail.choicesCentsPerMinute
        issues.check(!choices.isEmpty, "rules.guardrail.choicesCentsPerMinute: empty")
        issues.unique(choices.map(String.init), "rules.guardrail.choicesCentsPerMinute", what: "choice")
        for choice in choices where choice <= 0 { issues.add("rules.guardrail.choicesCentsPerMinute: \(choice) must be positive") }
        issues.check(choices.contains(r.guardrail.defaultCentsPerMinute),
                     "rules.guardrail.defaultCentsPerMinute: \(r.guardrail.defaultCentsPerMinute) is not one of choicesCentsPerMinute")
    }

    private static func structural(_ w: ConfigWeather, _ issues: inout Issues) {
        issues.positive(["bucketSeconds": w.bucketSeconds, "minuteHorizonSeconds": w.minuteHorizonSeconds,
                         "forecastHorizonHours": w.forecastHorizonHours, "pastHours": w.pastHours, "cacheSeconds": w.cacheSeconds,
                         "cacheCellMeters": w.cacheCellMeters], "weather")
        issues.nonNegative(["untimedAlertHours": w.untimedAlertHours, "clearWithinSeconds": w.clearWithinSeconds], "weather")
        for (name, p) in [("everyday", w.presets.everyday), ("fairWeather", w.presets.fairWeather), ("hardy", w.presets.hardy)] {
            let prefix = "weather.presets.\(name)"
            issues.percent(["rainBlockMinuteChancePercent": p.rainBlockMinuteChancePercent,
                            "rainBlockHourlyChancePercent": p.rainBlockHourlyChancePercent,
                            "rainCautionHourlyChancePercent": p.rainCautionHourlyChancePercent,
                            "rainBeforeHumidityPercent": p.rainBeforeHumidityPercent, "stormMinChancePercent": p.stormMinChancePercent], prefix)
            // Every quantity but the temperatures (`…F`, which may be negative).
            var quantities = ["rainBlockMinuteHundredthsInPerHour": p.rainBlockMinuteHundredthsInPerHour,
                              "rainBeforeHundredthsIn": p.rainBeforeHundredthsIn, "rainBeforeHours": p.rainBeforeHours,
                              "rainBeforeLongHours": p.rainBeforeLongHours, "snowCoverTenthsIn": p.snowCoverTenthsIn,
                              "snowCoverHours": p.snowCoverHours, "iceLookbackHours": p.iceLookbackHours, "windBlockMph": p.windBlockMph,
                              "gustBlockMph": p.gustBlockMph, "windCautionMph": p.windCautionMph]
            if let rate = p.rainBlockRateHundredthsInPerHour { quantities["rainBlockRateHundredthsInPerHour"] = rate }
            issues.nonNegative(quantities, prefix)
            issues.check(p.rainCautionHourlyChancePercent <= p.rainBlockHourlyChancePercent,
                         "\(prefix).rainCautionHourlyChancePercent: must not exceed rainBlockHourlyChancePercent")
            issues.check(p.rainBeforeHours <= p.rainBeforeLongHours, "\(prefix).rainBeforeLongHours: must be at least rainBeforeHours")
            issues.check(p.windCautionMph <= p.windBlockMph, "\(prefix).windCautionMph: must not exceed windBlockMph")
            issues.check(p.feelsLikeBlockBelowF <= p.feelsLikeCautionAtOrBelowF
                            && p.feelsLikeCautionAtOrBelowF < p.feelsLikeCautionAtOrAboveF
                            && p.feelsLikeCautionAtOrAboveF <= p.feelsLikeBlockAtOrAboveF,
                         "\(prefix): needs feelsLikeBlockBelowF ≤ feelsLikeCautionAtOrBelowF < feelsLikeCautionAtOrAboveF ≤ feelsLikeBlockAtOrAboveF")
        }
        for (index, rule) in w.alertKeywords.enumerated() {
            if rule.keywords.isEmpty { issues.add("weather.alertKeywords[\(index)]: no keywords") }
            if rule.keywords.contains("") { issues.add("weather.alertKeywords[\(index)]: empty keyword") }
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
        for valet in bikes.valet {
            if let hours = valet.hours {
                let path = "bikeShare.valet: \(valet.stationID)"
                issues.check(!hours.isEmpty, "\(path) hours: empty (omit it: absent means never valet)")
                issues.check(valet.validUntilDate != nil, "\(path) has hours but no validUntilDate (a stale schedule must not apply silently)")
                for (index, window) in hours.enumerated() {
                    issues.check(zip(window.isoWeekdays, window.isoWeekdays.dropFirst()).allSatisfy { $0 < $1 },
                                 "\(path) hours[\(index)].isoWeekdays: must be strictly ascending")
                }
                issues.check(zip(hours, hours.dropFirst()).allSatisfy { Self.valetOrder($0, $1) },
                             "\(path) hours: must be strictly ascending by (isoWeekdays, startMinute, endMinute)")
                for (i, a) in hours.enumerated() {
                    for b in hours[(i + 1)...] where !Set(a.isoWeekdays).isDisjoint(with: b.isoWeekdays)
                        && a.startMinute < b.endMinute && b.startMinute < a.endMinute {
                        issues.add("\(path) hours: two windows overlap on the same weekday")
                    }
                }
            } else if valet.validUntilDate != nil {
                issues.add("bikeShare.valet: \(valet.stationID) has a validUntilDate but no hours")
            }
        }

        keywordTable(d.alerts.pathKeywords.map(\.keywords), "alerts.pathKeywords", &issues)
        var seenSeverities = Set<ConfigAlertSeverity>()
        for rule in d.alerts.pathKeywords {
            if !seenSeverities.insert(rule.severity).inserted {
                issues.add("alerts.pathKeywords: \(rule.severity.rawValue) has two rules (merge them)")
            }
        }

        if let rules = d.rules {
            let choices = rules.guardrail.choicesCentsPerMinute
            issues.check(zip(choices, choices.dropFirst()).allSatisfy { $0 < $1 },
                         "rules.guardrail.choicesCentsPerMinute: must be strictly ascending")
        }

        // The weather alert keywords follow the PATH keywords' rules, and `unknown` (what no match
        // gives) is never a rule's class.
        if let weather = d.weather {
            keywordTable(weather.alertKeywords.map(\.keywords), "weather.alertKeywords", &issues)
            var seenClasses = Set<ConfigWeatherAlertClass>()
            for (index, rule) in weather.alertKeywords.enumerated() {
                if rule.alertClass == .unknown {
                    issues.add("weather.alertKeywords[\(index)]: unknown is the class of no match, not a rule's")
                }
                if !seenClasses.insert(rule.alertClass).inserted {
                    issues.add("weather.alertKeywords: \(rule.alertClass.rawValue) has two rules (merge them)")
                }
            }
        }
    }

    /// The writer's rules for an ordered first-match keyword table (PATH and weather alerts): each
    /// rule's keywords sorted, lowercase, without surrounding whitespace (a stray space changes
    /// the substring matched), each in one rule only, and none unreachable (a keyword containing
    /// an earlier rule's keyword never decides a match).
    private static func keywordTable(_ rules: [[String]], _ path: String, _ issues: inout Issues) {
        var seen = Set<String>()
        for (index, keywords) in rules.enumerated() {
            issues.ascending(keywords.map { [$0] }, "\(path)[\(index)].keywords")
            for keyword in keywords {
                if keyword != keyword.lowercased() { issues.add("\(path): '\(keyword)' must be lowercase") }
                if keyword.first?.isWhitespace == true || keyword.last?.isWhitespace == true {
                    issues.add("\(path): '\(keyword)' has surrounding whitespace")
                }
                if !seen.insert(keyword).inserted { issues.add("\(path): '\(keyword)' is in two rules") }
                for earlier in rules[..<index].joined() where earlier != keyword && !earlier.isEmpty && keyword.contains(earlier) {
                    issues.add("\(path): '\(keyword)' can never match: it contains '\(earlier)', which an earlier rule has")
                }
            }
        }
    }

    /// Valet windows in canonical order: by weekdays (lexicographically), then start, then end.
    private static func valetOrder(_ a: ConfigValetHours, _ b: ConfigValetHours) -> Bool {
        if a.isoWeekdays != b.isoWeekdays { return a.isoWeekdays.lexicographicallyPrecedes(b.isoWeekdays) }
        return (a.startMinute, a.endMinute) < (b.startMinute, b.endMinute)
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

        /// A probability or weight in whole percents.
        mutating func percent(_ values: [String: Int], _ prefix: String) {
            for key in values.keys.sorted() where !(0...100).contains(values[key]!) { add("\(prefix).\(key): must be 0…100") }
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
