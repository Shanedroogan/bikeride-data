import BRConfig
import BRCore
import BRData
import Foundation
import Testing

/// ``HandBuiltConfig``'s document with every optional key added within format 1 for M2c filled
/// in: the six bike-planning sections and a valet station's hours. Every value is hand-set (none
/// comes from `Data/`), so the payload golden doesn't move when the reviewed sources do. Mostly
/// the plan's defaults, with a negative temperature and the optional Hardy rain rate so both
/// reach the bytes.
enum HandBuiltM2cConfig {
    static let everyday = ConfigWeatherPreset(
        rainBlockMinuteChancePercent: 50, rainBlockMinuteHundredthsInPerHour: 2, rainBlockHourlyChancePercent: 60,
        rainCautionHourlyChancePercent: 40, rainBeforeHundredthsIn: 1, rainBeforeHours: 2, rainBeforeLongHours: 3,
        rainBeforeHumidityPercent: 85, rainBeforeBelowF: 50, stormMinChancePercent: 50, snowCoverTenthsIn: 20, snowCoverMaxF: 36,
        snowCoverHours: 72, iceMaxF: 34, iceLookbackHours: 12, windBlockMph: 20, gustBlockMph: 35, windCautionMph: 12,
        feelsLikeBlockBelowF: 25, feelsLikeCautionAtOrBelowF: 40, feelsLikeCautionAtOrAboveF: 90, feelsLikeBlockAtOrAboveF: 103,
        cautionBlocks: false,
        alertVerdicts: ConfigWeatherAlertVerdicts(thunderstorm: .block, winterIce: .block, highWind: .block, extremeHeat: .block,
                                                  tornado: .block, informational: .allow, unknown: .caution)
    )

    static let availability = ConfigAvailability(
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
    )

    static let rules = ConfigRules(
        deltaMinSeconds: 180, deltaPercent: 10, minRideSeconds: 300, stationWalkLimitSeconds: 600, ebikeMinSavingSeconds: 120,
        ebikeAllowanceCentsPerMinute: 200, guardrail: ConfigGuardrail(defaultCentsPerMinute: 100, choicesCentsPerMinute: [50, 100, 200]),
        transferPenaltySeconds: 120, cautionPenaltySeconds: 180, bucketSeconds: 120, alternativesPerLayer: 3, enrichStopsPerLayer: 3
    )

    static let weather: ConfigWeather = {
        var fair = everyday
        fair.cautionBlocks = true
        (fair.feelsLikeBlockBelowF, fair.feelsLikeBlockAtOrAboveF) = (40, 90)
        var hardy = everyday
        hardy.rainBlockMinuteHundredthsInPerHour = 10
        hardy.rainBlockRateHundredthsInPerHour = 10
        (hardy.windBlockMph, hardy.gustBlockMph) = (25, 40)
        (hardy.feelsLikeBlockBelowF, hardy.feelsLikeBlockAtOrAboveF) = (-5, 105)
        hardy.alertVerdicts.highWind = .caution
        hardy.alertVerdicts.extremeHeat = .caution
        return ConfigWeather(
            bucketSeconds: 300, minuteHorizonSeconds: 3600, forecastHorizonHours: 168, pastHours: 72, cacheSeconds: 600,
            cacheCellMeters: 1000, untimedAlertHours: 12, clearWithinSeconds: 3600,
            presets: ConfigWeatherPresets(everyday: everyday, fairWeather: fair, hardy: hardy),
            alertKeywords: [
                ConfigWeatherAlertRule(keywords: ["tornado"], alertClass: .tornado),
                ConfigWeatherAlertRule(keywords: ["wind chill", "winter"], alertClass: .winterIce),
                ConfigWeatherAlertRule(keywords: ["wind"], alertClass: .highWind),
                ConfigWeatherAlertRule(keywords: ["coastal flood"], alertClass: .informational),
            ]
        )
    }()

    static let pace = ConfigPace(relaxedPercent: 85, typicalPercent: 100, fastPercent: 115, minHundredthsMph: 500, maxHundredthsMph: 1500,
                                 learnAfterRides: 3, emaWeightPercent: 25, planSdHundredths: 25)
    static let speeds = ConfigSpeeds(classicHundredthsMph: 800, ebikeHundredthsMph: 1000)
    static let overheads = ConfigOverheads(unlockSeconds: 90, dockSeconds: 60)

    static let document: ConfigDocument = {
        var document = HandBuiltConfig.document
        document.availability = availability
        document.rules = rules
        document.weather = weather
        document.pace = pace
        document.speeds = speeds
        document.overheads = overheads
        document.bikeShare.valet[0].hours = [
            ConfigValetHours(isoWeekdays: [1, 2, 3, 4, 5], startMinute: 420, endMinute: 1140),
            ConfigValetHours(isoWeekdays: [6, 7], startMinute: 600, endMinute: 960),
        ]
        document.bikeShare.valet[0].validUntilDate = ServiceDate(year: 2026, month: 12, day: 31)
        return document
    }()

    /// ``document`` with every M2c key removed again.
    static func withoutM2cKeys(_ document: ConfigDocument = document) -> ConfigDocument {
        var copy = document
        (copy.availability, copy.rules, copy.weather, copy.pace, copy.speeds, copy.overheads) = (nil, nil, nil, nil, nil, nil)
        for index in copy.bikeShare.valet.indices {
            copy.bikeShare.valet[index].hours = nil
            copy.bikeShare.valet[index].validUntilDate = nil
        }
        return copy
    }
}

/// The optional keys added to `config` format 1 for M2c (`docs/formats.md`, "config"): the payload
/// golden of a document that fills every one, and the promise that a document without them is the
/// format-1 document as it froze (``ConfigV1Tests``' golden and committed file are unchanged).
@Suite struct ConfigV1M2cTests {
    /// SHA-256 of the writer's payload for ``HandBuiltM2cConfig`` (header left out: it embeds
    /// builderSwiftVersion). The same on macOS and Linux, run after run. What may change it: a
    /// deliberate change to the hand-built document, or a newly defined optional key it fills.
    /// Never a change to a key already here: that is a new formatVersion.
    static let payloadGolden = "51acf006470f6ba58e0bfe5d2ab3e8541d33148bbe4a1bbe37c1465378182962"

    func reader(_ file: Data) throws -> MappedConfig {
        try MappedConfig(artifact: MappedArtifact(fileBytes: file, expecting: .config))
    }

    func file(_ document: ConfigDocument) throws -> Data {
        try HandBuiltConfig.artifact(document, dataVersion: V1Fixtures.dataVersion)
    }

    @Test func payloadMatchesTheGolden() throws {
        let file = try file(HandBuiltM2cConfig.document)
        let digest = try V1Fixtures.payloadSHA256(file)
        print("CONFIG M2c payload sha256 \(digest)")
        #expect(digest == Self.payloadGolden)
        let config = try reader(file)
        #expect(config.document == HandBuiltM2cConfig.document)
        #expect(config.document.planningSections == ConfigDocument.planningSectionKeys)
        #expect(ConfigValidation.canonicalIssues(HandBuiltM2cConfig.document).isEmpty)
    }

    /// Without its M2c keys the document writes ``ConfigV1Tests``' frozen payload, byte for byte.
    @Test func withoutTheM2cKeysThePayloadIsTheFrozenV1One() throws {
        let stripped = HandBuiltM2cConfig.withoutM2cKeys()
        #expect(stripped == HandBuiltConfig.document)
        #expect(try V1Fixtures.payloadSHA256(file(stripped)) == ConfigV1Tests.payloadGolden)
        let text = try #require(String(data: ConfigArtifactWriter.json(HandBuiltConfig.document), encoding: .utf8))
        for key in ConfigDocument.planningSectionKeys + ["hours", "validUntilDate"] {
            #expect(!text.contains("\"\(key)\""), "\(key)")
        }
        #expect(HandBuiltConfig.document.planningSections.isEmpty)
    }

    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func theCommittedV1FileHasNoM2cKeys() throws {
        let config = try reader(V1Fixtures.data(ConfigV1Tests.fixtureName))
        #expect(config.document.planningSections.isEmpty)
        #expect(config.document.bikeShare.valet.allSatisfy { $0.hours == nil && $0.validUntilDate == nil })
    }

    @Test func theNewKeysAreWrittenCanonically() throws {
        let text = try #require(String(data: ConfigArtifactWriter.json(HandBuiltM2cConfig.document), encoding: .utf8))
        #expect(text.contains(#""hours":[{"endMinute":1140,"isoWeekdays":[1,2,3,4,5],"startMinute":420},{"endMinute":960,"isoWeekdays":[6,7],"startMinute":600}],"latE6":40750000"#))
        #expect(text.contains(#""validUntilDate":"20261231"}"#))
        #expect(text.contains(#""feelsLikeBlockBelowF":-5,"#))
        #expect(text.contains(#"{"class":"winterIce","keywords":["wind chill","winter"]}"#))
        #expect(text.contains(#""overheads":{"dockSeconds":60,"unlockSeconds":90}"#))
        #expect(text.contains(#""guardrail":{"choicesCentsPerMinute":[50,100,200],"defaultCentsPerMinute":100}"#))
        // The optional Hardy rain rate appears once: the other presets omit it.
        #expect(text.components(separatedBy: "rainBlockRateHundredthsInPerHour").count == 2)
        #expect(!text.contains("null") && !text.contains("\n") && !text.contains("."))
    }

    /// Each section is optional on its own: a reader of a document missing one reads it as nil
    /// and the rest as written.
    @Test(arguments: ConfigDocument.planningSectionKeys)
    func eachSectionIsOptional(key: String) throws {
        var tree = try HandBuiltConfig.tree(HandBuiltM2cConfig.document)
        tree[key] = nil
        let document = try MappedConfig(fileBytes: HandBuiltConfig.file(json: HandBuiltConfig.json(tree))).document
        #expect(document.planningSections == ConfigDocument.planningSectionKeys.filter { $0 != key })
        var expected = HandBuiltM2cConfig.document
        switch key {
        case "availability": expected.availability = nil
        case "rules": expected.rules = nil
        case "weather": expected.weather = nil
        case "pace": expected.pace = nil
        case "speeds": expected.speeds = nil
        default: expected.overheads = nil
        }
        #expect(document == expected)
    }

    @Test func readsNullSectionsAsAbsentAndIgnoresUnknownKeysInThem() throws {
        var tree = try HandBuiltConfig.tree(HandBuiltM2cConfig.document)
        tree["pace"] = NSNull()
        tree.set("availability.futureKey", 7)
        tree.set("weather.presets.hardy.futureThreshold", 1)
        tree.set("rules.guardrail.futureKey", true)
        let document = try MappedConfig(fileBytes: HandBuiltConfig.file(json: HandBuiltConfig.json(tree))).document
        var expected = HandBuiltM2cConfig.document
        expected.pace = nil
        #expect(document == expected)
    }

    /// Each value is JSON text.
    @Test(arguments: [
        ("weather.presets.everyday.alertVerdicts.tornado", #""avoid""#),
        ("weather.alertKeywords", #"[{"class":"hail","keywords":["hail"]}]"#),
        ("availability.bands", #"[{"fromSeconds":0,"pickupMinBikes":1,"dropoffMinDocks":1,"pickupFloorBikes":0}]"#),
        ("rules.guardrail", #"{"defaultCentsPerMinute":100}"#),
        ("speeds.classicHundredthsMph", "8.5"),
        ("weather.presets.hardy.cautionBlocks", #""yes""#),
    ])
    func rejectsUnknownEnumValuesMissingKeysAndWrongTypesInASection(path: String, value: String) throws {
        var tree = try HandBuiltConfig.tree(HandBuiltM2cConfig.document)
        tree.set(path, try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed))
        let file = HandBuiltConfig.file(json: try HandBuiltConfig.json(tree))
        #expect {
            try MappedConfig(fileBytes: file)
        } throws: { error in
            guard case .undecodableDocument(let message)? = error as? ConfigFormatError else { return false }
            print("CONFIG rejects \(path) = \(value): \(message)")
            return true
        }
    }

    @Test(arguments: ["weather.presets.fairWeather", "availability.pooled", "weather.presets.hardy.alertVerdicts.unknown",
                      "rules.ebikeAllowanceCentsPerMinute", "pace.planSdHundredths", "pace.emaWeightPercent", "overheads.dockSeconds"])
    func rejectsAMissingRequiredKeyInAPresentSection(path: String) throws {
        var tree = try HandBuiltConfig.tree(HandBuiltM2cConfig.document)
        tree.set(path, nil)
        let file = HandBuiltConfig.file(json: try HandBuiltConfig.json(tree))
        #expect {
            try MappedConfig(fileBytes: file)
        } throws: { error in
            guard case .undecodableDocument(let message)? = error as? ConfigFormatError else { return false }
            return message.contains("missing key")
        }
    }
}
