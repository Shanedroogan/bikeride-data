import BRBuild
import BRConfig
import BRCore
import Foundation
import Testing

/// The M2c bike-planning sources (`Data/config/planning/`) and the valet hours columns.
@Suite struct ConfigPlanningSourcesTests {
    let document: ConfigDocument

    init() throws {
        document = try ConfigSources(root: RepositoryData.root).load()
    }

    /// Copies `Data/`, lets `edit` change files under its root, and loads it.
    func load(_ edit: (URL) throws -> Void) throws -> ConfigDocument {
        let scratch = try ScratchDirectory()
        let root = try RepositoryData.copy(into: scratch)
        try edit(root)
        return try ConfigSources(root: root).load()
    }

    /// Copies `Data/`, applies `edit` to one file's text, and returns the load error.
    func loadError(_ file: String, _ edit: (String) -> String) throws -> ConfigSourceError? {
        do {
            _ = try load { root in
                let url = root.appendingPathComponent(file)
                let text = try String(contentsOf: url, encoding: .utf8)
                let edited = edit(text)
                #expect(edited != text, "the edit changed nothing in \(file)")
                try edited.write(to: url, atomically: true, encoding: .utf8)
            }
            return nil
        } catch let error as ConfigSourceError {
            return error
        }
    }

    // MARK: - The committed values are the plan's

    /// Every committed value, typed again from the M2c plan (S0a; the availability audit's §H;
    /// the weather-rules audit's §C; the 2026-09-27 rider decisions: an e-bike allowance of
    /// $2/min of its own, per-type speeds).
    @Test func theCommittedSectionsAreThePlansDefaults() throws {
        #expect(document.planningSections == ["availability", "rules", "weather", "pace", "speeds", "overheads"])
        #expect(document.availability == ConfigAvailability(
            targetPercent: 90, itineraryMinPercent: 80, tightMinPercent: 70,
            bands: [
                ConfigAvailabilityBand(fromSeconds: 0, pickupMinBikes: 1, dropoffMinDocks: 1, pickupFloorBikes: 0, dropoffFloorDocks: 1),
                ConfigAvailabilityBand(fromSeconds: 120, pickupMinBikes: 2, dropoffMinDocks: 2, pickupFloorBikes: 2, dropoffFloorDocks: 2),
                ConfigAvailabilityBand(fromSeconds: 300, pickupMinBikes: 1, dropoffMinDocks: 2, pickupFloorBikes: 0, dropoffFloorDocks: 0),
            ],
            pooled: ConfigAvailabilityPooled(afterSeconds: 1200, radiusMeters: 300, discountPercent: 30, maxStations: 3, pickupMinBikes: 1,
                                             dropoffMinDocks: 2),
            reroute: ConfigAvailabilityReroute(belowPercent: 70, minHorizonSeconds: 120),
            trend: ConfigAvailabilityTrend(minWatchSeconds: 600, windowSeconds: 1200, weightPercent: 50, maxStepCount: 4, maxGapSeconds: 180),
            variance: ConfigAvailabilityVariance(crossBinCorrelationPercent: 0, inflationPercent: 100),
            coldStart: ConfigAvailabilityColdStart(neighborCount: 8, radiusMeters: 1000, farMaxPercent: 89)
        ))
        #expect(document.rules == ConfigRules(
            deltaMinSeconds: 180, deltaPercent: 10, minRideSeconds: 300, stationWalkLimitSeconds: 600, ebikeMinSavingSeconds: 120,
            ebikeAllowanceCentsPerMinute: 200, guardrail: ConfigGuardrail(defaultCentsPerMinute: 100, choicesCentsPerMinute: [50, 100, 200]),
            transferPenaltySeconds: 120, cautionPenaltySeconds: 180, bucketSeconds: 120, alternativesPerLayer: 3, enrichStopsPerLayer: 3
        ))
        #expect(document.pace == ConfigPace(relaxedPercent: 85, typicalPercent: 100, fastPercent: 115, minHundredthsMph: 500,
                                            maxHundredthsMph: 1500, learnAfterRides: 3, emaWeightPercent: 25, planSdHundredths: 25))
        #expect(document.speeds == ConfigSpeeds(classicHundredthsMph: 800, ebikeHundredthsMph: 1000))
        #expect(document.overheads == ConfigOverheads(unlockSeconds: 90, dockSeconds: 60))

        let weather = try #require(document.weather)
        let horizons: [Int] = [weather.bucketSeconds, weather.minuteHorizonSeconds, weather.forecastHorizonHours, weather.pastHours,
                               weather.cacheSeconds, weather.cacheCellMeters, weather.untimedAlertHours, weather.clearWithinSeconds]
        #expect(horizons == [300, 3600, 168, 72, 600, 1000, 12, 3600])
        // Everyday: the plan's table.
        let everyday = ConfigWeatherPreset(
            rainBlockMinuteChancePercent: 50, rainBlockMinuteHundredthsInPerHour: 2, rainBlockHourlyChancePercent: 60,
            rainCautionHourlyChancePercent: 40, rainBeforeHundredthsIn: 1, rainBeforeHours: 2, rainBeforeLongHours: 3,
            rainBeforeHumidityPercent: 85, rainBeforeBelowF: 50, stormMinChancePercent: 50, snowCoverTenthsIn: 20, snowCoverMaxF: 36,
            snowCoverHours: 72, iceMaxF: 34, iceLookbackHours: 12, windBlockMph: 20, gustBlockMph: 35, windCautionMph: 12,
            feelsLikeBlockBelowF: 25, feelsLikeCautionAtOrBelowF: 40, feelsLikeCautionAtOrAboveF: 90, feelsLikeBlockAtOrAboveF: 103,
            cautionBlocks: false,
            alertVerdicts: ConfigWeatherAlertVerdicts(thunderstorm: .block, winterIce: .block, highWind: .block, extremeHeat: .block,
                                                      tornado: .block, informational: .allow, unknown: .caution)
        )
        #expect(weather.presets.everyday == everyday)
        // Fair-weather: caution blocks, 40°F and 90°F limits.
        var fair = everyday
        fair.cautionBlocks = true
        (fair.feelsLikeBlockBelowF, fair.feelsLikeBlockAtOrAboveF) = (40, 90)
        #expect(weather.presets.fairWeather == fair)
        // Hardy: rain ≥ 0.10 in/h, wind 25/40, feels-like 15/105; wind and heat alerts are caution.
        var hardy = everyday
        hardy.rainBlockMinuteHundredthsInPerHour = 10
        hardy.rainBlockRateHundredthsInPerHour = 10
        (hardy.windBlockMph, hardy.gustBlockMph) = (25, 40)
        (hardy.feelsLikeBlockBelowF, hardy.feelsLikeBlockAtOrAboveF) = (15, 105)
        hardy.alertVerdicts.highWind = .caution
        hardy.alertVerdicts.extremeHeat = .caution
        #expect(weather.presets.hardy == hardy)

        #expect(weather.alertKeywords == [
            ConfigWeatherAlertRule(keywords: ["tornado"], alertClass: .tornado),
            ConfigWeatherAlertRule(keywords: ["thunderstorm"], alertClass: .thunderstorm),
            ConfigWeatherAlertRule(keywords: ["blizzard", "cold weather", "extreme cold", "freezing", "ice storm", "sleet", "snow", "wind chill",
                                              "winter"], alertClass: .winterIce),
            ConfigWeatherAlertRule(keywords: ["heat"], alertClass: .extremeHeat),
            ConfigWeatherAlertRule(keywords: ["hurricane", "tropical storm", "wind"], alertClass: .highWind),
            ConfigWeatherAlertRule(keywords: ["air quality", "beach hazards", "coastal flood", "high surf", "rip current", "small craft"],
                                   alertClass: .informational),
        ])
    }

    /// The first rule with a keyword the lowercased event contains, as the gate will classify.
    @Test(arguments: [
        ("Wind Advisory", ConfigWeatherAlertClass.highWind), ("High Wind Warning", .highWind), ("Wind Chill Advisory", .winterIce),
        ("Extreme Cold Warning", .winterIce), ("Extreme Wind Warning", .highWind), ("Winter Storm Warning", .winterIce),
        ("Ice Storm Warning", .winterIce), ("Severe Thunderstorm Warning", .thunderstorm), ("Tornado Watch", .tornado),
        ("Heat Advisory", .extremeHeat), ("Extreme Heat Warning", .extremeHeat), ("Coastal Flood Warning", .informational),
        ("Rip Current Statement", .informational), ("Air Quality Alert", .informational), ("Tropical Storm Warning", .highWind),
        ("Flash Flood Warning", .unknown), ("Dense Fog Advisory", .unknown), ("Special Weather Statement", .unknown),
    ])
    func theCommittedKeywordsClassifyRealAlertNames(event: String, expected: ConfigWeatherAlertClass) throws {
        let rules = try #require(document.weather?.alertKeywords)
        let lowered = event.lowercased()
        let found = rules.first { $0.keywords.contains { lowered.contains($0) } }?.alertClass ?? .unknown
        #expect(found == expected, "\(event)")
    }

    // MARK: - Each section is its file

    @Test(arguments: ConfigSources.planningFiles.map(\.section))
    func removingOneFileRemovesOnlyItsSection(section: String) throws {
        let file = ConfigSources.planningFiles.first { $0.section == section }!.file
        let loaded = try load { try FileManager.default.removeItem(at: $0.appendingPathComponent(file)) }
        #expect(loaded.planningSections == ConfigDocument.planningSectionKeys.filter { $0 != section })
        var expected = document
        switch section {
        case "availability": expected.availability = nil
        case "rules": expected.rules = nil
        case "weather": expected.weather = nil
        case "pace": expected.pace = nil
        case "speeds": expected.speeds = nil
        default: expected.overheads = nil
        }
        #expect(loaded == expected)
    }

    /// Sources from before M2c (no `planning/`, the format-1 valet header) compile to a document
    /// without a single M2c key: the pinned fixtures' config bytes can't move.
    @Test func sourcesWithoutPlanningCompileToTheV1Document() throws {
        let scratch = try ScratchDirectory()
        let root = try RepositoryData.copy(into: scratch)
        try FileManager.default.removeItem(at: root.appendingPathComponent("config/planning"))
        try "station_id,lat_e6,lon_e6,name,source_note\n".write(to: root.appendingPathComponent("config/bikeshare/valet.csv"),
                                                              atomically: true, encoding: .utf8)
        let sources = ConfigSources(root: root)
        let loaded = try sources.load()
        #expect(loaded.planningSections.isEmpty)
        #expect(loaded == HandBuiltM2cConfig.withoutM2cKeys(document))
        let text = try #require(String(data: ConfigArtifactWriter.json(loaded), encoding: .utf8))
        for key in ConfigDocument.planningSectionKeys + ["hours", "validUntilDate"] { #expect(!text.contains("\"\(key)\""), "\(key)") }
        #expect(try !sources.files().contains { $0.hasPrefix("config/planning/") })
        #expect(try ConfigSources(root: RepositoryData.root).files().filter { $0.hasPrefix("config/planning/") } == [
            "config/planning/availability.json", "config/planning/overheads.json", "config/planning/pace.json", "config/planning/rules.json",
            "config/planning/speeds.json", "config/planning/weather-alert-keywords.csv", "config/planning/weather.json",
        ])
    }

    @Test func weatherNeedsItsKeywordsAndOnlyItReadsThem() throws {
        let scratch = try ScratchDirectory()
        let root = try RepositoryData.copy(into: scratch)
        let csv = root.appendingPathComponent(ConfigSources.weatherAlertKeywordsFile)
        try FileManager.default.removeItem(at: csv)
        #expect(throws: ConfigSourceError.missingFile(csv.path)) { try ConfigSources(root: root).load() }
        // Without weather.json the keywords are not read (a bad file there is not an error) nor hashed.
        try FileManager.default.removeItem(at: root.appendingPathComponent("config/planning/weather.json"))
        try "not,a,keyword,file\n".write(to: csv, atomically: true, encoding: .utf8)
        #expect(try ConfigSources(root: root).load().weather == nil)
        #expect(try !ConfigSources(root: root).files().contains(ConfigSources.weatherAlertKeywordsFile))
    }

    /// Only the planning sources (and SOURCES.md) may be in `config/planning/`: a misspelled
    /// name would otherwise drop its section, and bike planning with it, without a word.
    @Test func aStrayFileInPlanningFailsTheBuild() throws {
        let known = "SOURCES.md, availability.json, overheads.json, pace.json, rules.json, speeds.json, weather-alert-keywords.csv, weather.json"
        func strayError(_ edit: (URL) throws -> Void) throws -> ConfigSourceError? {
            do { _ = try load { try edit($0.appendingPathComponent("config/planning")) }; return nil } catch let error as ConfigSourceError { return error }
        }
        func stray(_ names: String) -> ConfigSourceError {
            .invalidValue(file: "config/planning",
                          message: "\(names): not a bike-planning source (expected only \(known); a misspelled name would drop its section)")
        }
        #expect(try strayError { dir in
            try FileManager.default.moveItem(at: dir.appendingPathComponent("availability.json"), to: dir.appendingPathComponent("availabilty.json"))
        } == stray("availabilty.json"))
        #expect(try strayError { try Data("{}".utf8).write(to: $0.appendingPathComponent("extra.json")) } == stray("extra.json"))
        #expect(try strayError { dir in
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("old"), withIntermediateDirectories: false)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("rules.json~"))
        } == stray("old, rules.json~"))
        // Hidden files (Finder's .DS_Store) are ignored; the committed directory passes as is.
        #expect(try strayError { try Data([0, 0, 0, 1]).write(to: $0.appendingPathComponent(".DS_Store")) } == nil)
        // Removing a known file is still just an absent section.
        #expect(try strayError { try FileManager.default.removeItem(at: $0.appendingPathComponent("pace.json")) } == nil)
        #expect(try strayError { dir in
            try FileManager.default.removeItem(at: dir)
            try Data().write(to: dir)
        } == .invalidValue(file: "config/planning", message: "is not a directory"))
    }

    // MARK: - Strictness

    @Test func unknownAndMisspelledKeysFailTheBuild() throws {
        let top = try loadError("config/planning/availability.json") {
            $0.replacingOccurrences(of: #""targetPercent": 90,"#, with: #""targetPercent": 90, "targetPercentt": 90,"#)
        }
        #expect(top == .unknownKey(file: "config/planning/availability.json", path: "$.targetPercentt"))
        let nested = try loadError("config/planning/availability.json") {
            $0.replacingOccurrences(of: #"{ "fromSeconds": 120,"#, with: #"{ "fromSeconds": 120, "note": "2–5 min","#)
        }
        #expect(nested == .unknownKey(file: "config/planning/availability.json", path: "$.bands[1].note"))
        // An optional key misspelled: a lenient decoder would drop it silently.
        let optional = try loadError("config/planning/weather.json") {
            $0.replacingOccurrences(of: #""rainBlockRateHundredthsInPerHour": 10"#, with: #""rainBlockRateHundredthsPerHour": 10"#)
        }
        #expect(optional == .unknownKey(file: "config/planning/weather.json", path: "$.presets.hardy.rainBlockRateHundredthsPerHour"))
        // alertKeywords come from the CSV, not weather.json.
        let keywords = try loadError("config/planning/weather.json") {
            $0.replacingOccurrences(of: #""bucketSeconds": 300,"#, with: #""bucketSeconds": 300, "alertKeywords": [],"#)
        }
        #expect(keywords == .unknownKey(file: "config/planning/weather.json", path: "$.alertKeywords"))
        let decimal = try loadError("config/planning/speeds.json") { $0.replacingOccurrences(of: "800", with: "800.0") }
        #expect(decimal == .changedValue(file: "config/planning/speeds.json", path: "$.classicHundredthsMph"))
        let duplicate = try loadError("config/planning/overheads.json") {
            $0.replacingOccurrences(of: #""dockSeconds": 60"#, with: "\"dockSeconds\": 60,\n  \"dockSeconds\": 45")
        }
        #expect(duplicate == .duplicateKey(file: "config/planning/overheads.json", path: "$.dockSeconds", line: 4))
        let missing = try loadError("config/planning/pace.json") { $0.replacingOccurrences(of: #""learnAfterRides": 3,"#, with: "") }
        guard case .undecodable(_, let message)? = missing else { Issue.record("\(String(describing: missing))"); return }
        #expect(message.contains("missing key 'learnAfterRides'"))
    }

    @Test func structuralAndCanonicalRulesRunOnTheSources() throws {
        let band = try loadError("config/planning/availability.json") { $0.replacingOccurrences(of: #""fromSeconds": 300"#, with: #""fromSeconds": 100"#) }
        #expect(band == .invalidDocument(["availability.bands[2]: fromSeconds 100 must be after 120 (strictly ascending)"]))
        let percent = try loadError("config/planning/availability.json") { $0.replacingOccurrences(of: #""targetPercent": 90"#, with: #""targetPercent": 101"#) }
        #expect(percent == .invalidDocument(["availability.targetPercent: must be 0…100"]))
        let cold = try loadError("config/planning/weather.json") { $0.replacingOccurrences(of: #""feelsLikeBlockBelowF": 15"#, with: #""feelsLikeBlockBelowF": -10"#) }
        #expect(cold == nil)
        let seconds = try loadError("config/planning/overheads.json") { $0.replacingOccurrences(of: #""unlockSeconds": 90"#, with: #""unlockSeconds": -90"#) }
        #expect(seconds == .invalidDocument(["overheads.unlockSeconds: must not be negative"]))
    }

    /// Set-like: the guardrail choices may be in any order in the source.
    @Test func guardrailChoicesAreSorted() throws {
        let loaded = try load { root in
            let url = root.appendingPathComponent("config/planning/rules.json")
            let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "[50, 100, 200]", with: "[200, 50, 100]")
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(loaded.rules?.guardrail.choicesCentsPerMinute == [50, 100, 200])
        #expect(try ConfigArtifactWriter.json(loaded) == ConfigArtifactWriter.json(document))
    }

    /// The same canonical rules as the PATH keywords, on the CSV.
    @Test func alertKeywordsFollowThePathKeywordRules() throws {
        let file = ConfigSources.weatherAlertKeywordsFile
        #expect(try loadError(file) { $0.replacingOccurrences(of: "extremeHeat,heat", with: "extremeHeat,Heat") }
            == .invalidDocument(["weather.alertKeywords: 'Heat' must be lowercase"]))
        #expect(try loadError(file) { $0.replacingOccurrences(of: "extremeHeat,heat", with: "extremeHeat,heat|snow") }
            == .invalidDocument(["weather.alertKeywords: 'snow' is in two rules"]))
        #expect(try loadError(file) { $0 + "tornado,waterspout\n" } == .invalidDocument(["weather.alertKeywords: tornado has two rules (merge them)"]))
        #expect(try loadError(file) { $0 + "unknown,flood\n" }
            == .invalidDocument(["weather.alertKeywords[6]: unknown is the class of no match, not a rule's"]))
        #expect(try loadError(file) { $0 + "hail,hail\n" } == .invalidCSV(file: file, message: "record 8: class 'hail' is not a weather alert class"))
        #expect(try loadError(file) { $0.replacingOccurrences(of: "class,keywords", with: "severity,keywords") }
            == .invalidCSV(file: file, message: "header is severity,keywords, expected class,keywords"))
        #expect(try loadError(file) { $0.replacingOccurrences(of: "extremeHeat,heat", with: "extremeHeat,heat|") }
            == .invalidDocument(["weather.alertKeywords[3]: empty keyword"]))
        // A stray space changes the substring matched.
        #expect(try loadError(file) { $0.replacingOccurrences(of: "extremeHeat,heat", with: "extremeHeat, heat") }
            == .invalidDocument(["weather.alertKeywords: ' heat' has surrounding whitespace"]))
        #expect(try loadError(file) { $0.replacingOccurrences(of: "tropical storm", with: "tropical storm ") }
            == .invalidDocument(["weather.alertKeywords: 'tropical storm ' has surrounding whitespace"]))
        // A keyword containing an earlier row's can never decide a match: highWind before winterIce
        // would make every wind chill alert high wind.
        #expect(try loadError(file) {
            $0.replacingOccurrences(of: "highWind,wind|hurricane|tropical storm\n", with: "")
                .replacingOccurrences(of: "thunderstorm,thunderstorm\n", with: "thunderstorm,thunderstorm\nhighWind,wind|hurricane|tropical storm\n")
        } == .invalidDocument(["weather.alertKeywords: 'wind chill' can never match: it contains 'wind', which an earlier rule has"]))
        // Keywords within a rule may be in any order in the source; the rules' order is kept.
        let loaded = try load { root in
            let url = root.appendingPathComponent(file)
            let text = try String(contentsOf: url, encoding: .utf8)
            try text.replacingOccurrences(of: "highWind,wind|hurricane|tropical storm", with: "highWind,tropical storm|wind|hurricane")
                .write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(loaded == document)
    }

    // MARK: - Valet hours

    func valetDocument(_ csv: String) throws -> ConfigDocument {
        try load { root in
            try csv.write(to: root.appendingPathComponent("config/bikeshare/valet.csv"), atomically: true, encoding: .utf8)
        }
    }

    func valetError(_ csv: String) throws -> ConfigSourceError? {
        do {
            _ = try valetDocument(csv)
            return nil
        } catch let error as ConfigSourceError {
            return error
        }
    }

    static let header = "station_id,lat_e6,lon_e6,name,hours,valid_until_date,source_note\n"

    @Test func valetHoursParse() throws {
        let document = try valetDocument(Self.header + """
            b-2,40760000,-73980000,Station B,,,no hours
            a-1,40750000,-73990000,Station A,67 10:00-16:00|54321 07:00-19:00|3 19:00-24:00,20261231,test

            """)
        #expect(document.bikeShare.valet == [
            ConfigValetStation(stationID: "a-1", latE6: 40_750_000, lonE6: -73_990_000, hours: [
                ConfigValetHours(isoWeekdays: [1, 2, 3, 4, 5], startMinute: 420, endMinute: 1140),
                ConfigValetHours(isoWeekdays: [3], startMinute: 1140, endMinute: 1440),
                ConfigValetHours(isoWeekdays: [6, 7], startMinute: 600, endMinute: 960),
            ], validUntilDate: ServiceDate(year: 2026, month: 12, day: 31)),
            ConfigValetStation(stationID: "b-2", latE6: 40_760_000, lonE6: -73_980_000),
        ])
        // The format-1 header still reads, with no hours.
        let old = try valetDocument("station_id,lat_e6,lon_e6,name,source_note\nb-2,40760000,-73980000,Station B,old header\n")
        #expect(old.bikeShare.valet == [ConfigValetStation(stationID: "b-2", latE6: 40_760_000, lonE6: -73_980_000)])
    }

    @Test func badValetHoursFailTheBuild() throws {
        func row(_ hours: String, _ until: String = "20261231") -> String {
            Self.header + "a-1,40750000,-73990000,Station A,\(hours),\(until),test\n"
        }
        let file = "config/bikeshare/valet.csv"
        // (cell, the window reported)
        for (bad, window) in [("12345", "12345"), ("12345 7:00-19:00", "12345 7:00-19:00"), ("12345 07:00-19:60", "12345 07:00-19:60"),
                              ("12345 07:00-24:30", "12345 07:00-24:30"), ("08 07:00-19:00", "08 07:00-19:00"),
                              ("12345  07:00-19:00", "12345  07:00-19:00"), ("12345 07:00-19:00|", ""), ("12345 07:00", "12345 07:00"),
                              // Only ASCII digits: a fullwidth digit, a digit with a combining mark (one
                              // Character, which a range of Characters would admit), a sign `Int` would take.
                              ("１ 07:00-19:00", "１ 07:00-19:00"), ("1\u{303} 07:00-19:00", "1\u{303} 07:00-19:00"),
                              ("1 +7:00-+9:00", "1 +7:00-+9:00"), ("1 07:+0-09:00", "1 07:+0-09:00"),
                              ("1 07:00-0\u{663}:00", "1 07:00-0\u{663}:00")] {
            #expect(try valetError(row(bad))
                == .invalidCSV(file: file, message: "record 2: hours window '\(window)' is not '<weekday digits 1–7> HH:MM-HH:MM'"), "\(bad)")
        }
        #expect(try valetError(row("12345 19:00-07:00"))
            == .invalidDocument(["bikeShare.valet: a-1 hours[0]: needs 0 ≤ startMinute < endMinute ≤ 1440"]))
        #expect(try valetError(row("112 07:00-19:00")) == .invalidDocument([
            "bikeShare.valet: a-1 hours[0]: a weekday is listed twice", "bikeShare.valet: a-1 hours[0].isoWeekdays: must be strictly ascending",
        ]))
        #expect(try valetError(row("12345 07:00-19:00", ""))
            == .invalidDocument(["bikeShare.valet: a-1 has hours but no validUntilDate (a stale schedule must not apply silently)"]))
        #expect(try valetError(row("", "20261231")) == .invalidDocument(["bikeShare.valet: a-1 has a validUntilDate but no hours"]))
        #expect(try valetError(row("12345 07:00-19:00", "2026-12-31"))
            == .invalidCSV(file: file, message: "record 2: valid_until_date '2026-12-31' is not YYYYMMDD"))
        #expect(try valetError(row("12345 07:00-19:00|5 18:00-20:00"))
            == .invalidDocument(["bikeShare.valet: a-1 hours: two windows overlap on the same weekday"]))
        #expect(try valetError("station_id,lat_e6,lon_e6,name,hours,source_note\n")
            == .invalidCSV(file: file, message: "header is station_id,lat_e6,lon_e6,name,hours,source_note, expected station_id,lat_e6,lon_e6,name,hours,valid_until_date,source_note"))
    }
}
