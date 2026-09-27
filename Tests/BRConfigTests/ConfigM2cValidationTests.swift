import BRConfig
import BRCore
import BRData
import Foundation
import Testing

/// ``ConfigValidation`` on the M2c keys: structural rules (the reader rejects the file) and the
/// writer's canonical rules (the compiler refuses to write it), each only when its section is
/// present.
@Suite struct ConfigM2cValidationTests {
    /// The structural issues of ``HandBuiltM2cConfig`` after `change`, through the reader.
    func structural(_ change: (inout ConfigDocument) -> Void) -> [String] {
        var document = HandBuiltM2cConfig.document
        change(&document)
        let file = try! HandBuiltConfig.artifact(document)
        do {
            _ = try MappedConfig(fileBytes: file)
            #expect(ConfigValidation.structuralIssues(document).isEmpty)
            return []
        } catch ConfigFormatError.invalidDocument(let issues) {
            #expect(ConfigValidation.structuralIssues(document) == issues)
            return issues
        } catch {
            return ["unexpected \(error)"]
        }
    }

    func canonical(_ change: (inout ConfigDocument) -> Void) -> [String] {
        var document = HandBuiltM2cConfig.document
        change(&document)
        return ConfigValidation.canonicalIssues(document)
    }

    @Test func theHandBuiltDocumentIsValid() {
        #expect(structural { _ in }.isEmpty && canonical { _ in }.isEmpty)
    }

    @Test func bandsStartAtZeroAscendAndEndBeforePooling() {
        #expect(structural { $0.availability!.bands.swapAt(1, 2) }
            == ["availability.bands[2]: fromSeconds 120 must be after 300 (strictly ascending)"])
        #expect(structural { $0.availability!.bands[2].fromSeconds = 120 }
            == ["availability.bands[2]: fromSeconds 120 must be after 120 (strictly ascending)"])
        #expect(structural { $0.availability!.bands[0].fromSeconds = 30 }
            == ["availability.bands: the first band must start at fromSeconds 0"])
        #expect(structural { $0.availability!.pooled.afterSeconds = 300 }
            == ["availability.bands: the last band starts at 300 s, not before pooled.afterSeconds 300"])
        #expect(structural { $0.availability!.pooled.afterSeconds = 301 }.isEmpty)
        #expect(structural { $0.availability!.bands = [] } == ["availability.bands: empty"])
        #expect(structural { $0.availability!.bands.removeLast(2) }.isEmpty) // one band from 0 is enough
        #expect(structural { $0.availability!.bands[1].pickupFloorBikes = -1 }
            == ["availability.bands[1].pickupFloorBikes: must not be negative"])
        // P(at least 0) is always 1: the counts are at least 1, while a floor of 0 is no floor.
        #expect(structural { $0.availability!.bands[1].pickupFloorBikes = 0 }.isEmpty)
        #expect(structural { $0.availability!.bands[0].pickupMinBikes = 0 } == ["availability.bands[0].pickupMinBikes: must be positive"])
        #expect(structural { $0.availability!.bands[2].dropoffMinDocks = 0 } == ["availability.bands[2].dropoffMinDocks: must be positive"])
        #expect(structural {
            $0.availability!.pooled.pickupMinBikes = 0
            $0.availability!.pooled.dropoffMinDocks = -1
        } == ["availability.pooled.dropoffMinDocks: must be positive", "availability.pooled.pickupMinBikes: must be positive"])
    }

    /// A capped cold-start station is never "Likely" (the availability design's cold start).
    @Test func theColdStartCapIsBelowTheTarget() {
        #expect(structural { $0.availability!.coldStart.farMaxPercent = 90 }
            == ["availability.coldStart.farMaxPercent: must be below targetPercent"])
        #expect(structural { $0.availability!.targetPercent = 89 }
            == ["availability.coldStart.farMaxPercent: must be below targetPercent"])
        #expect(structural { $0.availability!.coldStart.farMaxPercent = 0 }.isEmpty)
    }

    @Test func probabilitiesAreZeroToOneHundredButFactorsMayExceedIt() {
        #expect(structural { $0.availability!.targetPercent = 101 } == ["availability.targetPercent: must be 0…100"])
        #expect(structural { $0.availability!.coldStart.farMaxPercent = -1 } == ["availability.coldStart.farMaxPercent: must be 0…100"])
        #expect(structural { $0.availability!.targetPercent = 100 }.isEmpty)
        #expect(structural { $0.availability!.tightMinPercent = 91 }
            == ["availability.tightMinPercent: must not exceed targetPercent"])
        #expect(structural { $0.rules!.deltaPercent = 101 } == ["rules.deltaPercent: must be 0…100"])
        #expect(structural { $0.weather!.presets.everyday.rainBlockHourlyChancePercent = 101 }
            == ["weather.presets.everyday.rainBlockHourlyChancePercent: must be 0…100"])
        // Scale factors, not probabilities.
        #expect(structural { $0.pace!.fastPercent = 115 }.isEmpty)
        #expect(structural { $0.pace!.fastPercent = 250 }.isEmpty)
        #expect(structural { $0.availability!.variance.inflationPercent = 150 }.isEmpty)
        #expect(structural { $0.availability!.variance.inflationPercent = 0 } == ["availability.variance.inflationPercent: must be positive"])
        #expect(structural { $0.pace!.relaxedPercent = 0 } == ["pace.relaxedPercent: must be positive"])
        // The learning weight is a weight, and 0 would never learn.
        #expect(structural { $0.pace!.emaWeightPercent = 100 }.isEmpty)
        #expect(structural { $0.pace!.emaWeightPercent = 1 }.isEmpty)
        #expect(structural { $0.pace!.emaWeightPercent = 0 } == ["pace.emaWeightPercent: must be 1…100 (0 would never learn)"])
        #expect(structural { $0.pace!.emaWeightPercent = 101 } == ["pace.emaWeightPercent: must be 1…100 (0 would never learn)"])
    }

    @Test func negativeTimesAndCountsAreRejected() {
        #expect(structural { $0.overheads!.unlockSeconds = -1 } == ["overheads.unlockSeconds: must not be negative"])
        #expect(structural { $0.rules!.minRideSeconds = -300 } == ["rules.minRideSeconds: must not be negative"])
        #expect(structural { $0.rules!.ebikeAllowanceCentsPerMinute = -1 } == ["rules.ebikeAllowanceCentsPerMinute: must not be negative"])
        #expect(structural { $0.availability!.reroute.minHorizonSeconds = -1 }
            == ["availability.reroute.minHorizonSeconds: must not be negative"])
        #expect(structural { $0.weather!.clearWithinSeconds = -1 } == ["weather.clearWithinSeconds: must not be negative"])
        #expect(structural { $0.weather!.bucketSeconds = 0 } == ["weather.bucketSeconds: must be positive"])
        #expect(structural { $0.weather!.presets.hardy.windBlockMph = -1 }
            == ["weather.presets.hardy.windBlockMph: must not be negative", "weather.presets.hardy.windCautionMph: must not exceed windBlockMph"])
        #expect(structural { $0.weather!.presets.hardy.rainBlockRateHundredthsInPerHour = -1 }
            == ["weather.presets.hardy.rainBlockRateHundredthsInPerHour: must not be negative"])
        #expect(structural { $0.rules!.alternativesPerLayer = 0 } == ["rules.alternativesPerLayer: must be positive"])
    }

    /// Temperatures are the one signed quantity, and only in `weather`.
    @Test func negativeTemperaturesAreAcceptedInWeather() {
        #expect(structural { $0.weather!.presets.hardy.feelsLikeBlockBelowF = -10 }.isEmpty)
        #expect(structural {
            $0.weather!.presets.everyday.feelsLikeBlockBelowF = -20
            $0.weather!.presets.everyday.feelsLikeCautionAtOrBelowF = -10
            $0.weather!.presets.everyday.snowCoverMaxF = -10
            $0.weather!.presets.everyday.iceMaxF = -10
            $0.weather!.presets.everyday.rainBeforeBelowF = -10
        }.isEmpty)
    }

    @Test func weatherThresholdsAreOrdered() {
        #expect(structural { $0.weather!.presets.everyday.feelsLikeCautionAtOrBelowF = 20 }
            == ["weather.presets.everyday: needs feelsLikeBlockBelowF ≤ feelsLikeCautionAtOrBelowF < feelsLikeCautionAtOrAboveF ≤ feelsLikeBlockAtOrAboveF"])
        #expect(structural { $0.weather!.presets.everyday.feelsLikeCautionAtOrAboveF = 40 }.count == 1)
        #expect(structural { $0.weather!.presets.everyday.feelsLikeBlockAtOrAboveF = 89 }.count == 1)
        #expect(structural { $0.weather!.presets.everyday.rainCautionHourlyChancePercent = 61 }
            == ["weather.presets.everyday.rainCautionHourlyChancePercent: must not exceed rainBlockHourlyChancePercent"])
        #expect(structural { $0.weather!.presets.fairWeather.rainBeforeLongHours = 1 }
            == ["weather.presets.fairWeather.rainBeforeLongHours: must be at least rainBeforeHours"])
        #expect(structural { $0.weather!.presets.everyday.windCautionMph = 21 }
            == ["weather.presets.everyday.windCautionMph: must not exceed windBlockMph"])
        #expect(structural { $0.weather!.alertKeywords[0].keywords = [] } == ["weather.alertKeywords[0]: no keywords"])
        #expect(structural { $0.weather!.alertKeywords[0].keywords = [""] } == ["weather.alertKeywords[0]: empty keyword"])
    }

    @Test func guardrailAndPaceAndSpeeds() {
        #expect(structural { $0.rules!.guardrail.defaultCentsPerMinute = 150 }
            == ["rules.guardrail.defaultCentsPerMinute: 150 is not one of choicesCentsPerMinute"])
        #expect(structural { $0.rules!.guardrail.choicesCentsPerMinute = [] }
            == ["rules.guardrail.choicesCentsPerMinute: empty", "rules.guardrail.defaultCentsPerMinute: 100 is not one of choicesCentsPerMinute"])
        #expect(structural { $0.rules!.guardrail.choicesCentsPerMinute = [0, 100] }
            == ["rules.guardrail.choicesCentsPerMinute: 0 must be positive"])
        #expect(structural { $0.rules!.guardrail.choicesCentsPerMinute = [100, 100] }
            == ["rules.guardrail.choicesCentsPerMinute: choice 100 listed twice"])
        #expect(structural { $0.pace!.minHundredthsMph = 1600 }
            == ["pace: minHundredthsMph must not exceed maxHundredthsMph", "speeds.classicHundredthsMph: must be within pace.minHundredthsMph…pace.maxHundredthsMph",
                "speeds.ebikeHundredthsMph: must be within pace.minHundredthsMph…pace.maxHundredthsMph"])
        #expect(structural { $0.speeds!.ebikeHundredthsMph = 1600 }
            == ["speeds.ebikeHundredthsMph: must be within pace.minHundredthsMph…pace.maxHundredthsMph"])
        // The clamp is pace's: without pace, speeds are only checked on their own.
        #expect(structural {
            $0.speeds!.ebikeHundredthsMph = 1600
            $0.pace = nil
        }.isEmpty)
        #expect(structural { $0.speeds!.classicHundredthsMph = 0 } == [
            "speeds.classicHundredthsMph: must be positive", "speeds.classicHundredthsMph: must be within pace.minHundredthsMph…pace.maxHundredthsMph",
        ])
    }

    /// A section that is absent is not checked: every section can go, alone or together.
    @Test func absentSectionsAreNotChecked() {
        #expect(structural { $0 = HandBuiltM2cConfig.withoutM2cKeys($0) }.isEmpty)
        #expect(structural {
            $0.availability = nil
            $0.weather = nil
        }.isEmpty)
    }

    @Test func valetHours() {
        #expect(structural { $0.bikeShare.valet[0].hours![0].isoWeekdays = [0, 1] }
            == ["bikeShare.valet: abc-123 hours[0]: isoWeekdays must be 1…7"])
        #expect(structural { $0.bikeShare.valet[0].hours![1].isoWeekdays = [8] }
            == ["bikeShare.valet: abc-123 hours[1]: isoWeekdays must be 1…7"])
        #expect(structural { $0.bikeShare.valet[0].hours![0].isoWeekdays = [] } == ["bikeShare.valet: abc-123 hours[0] has no weekdays"])
        #expect(structural { $0.bikeShare.valet[0].hours![0].isoWeekdays = [2, 2] }
            == ["bikeShare.valet: abc-123 hours[0]: a weekday is listed twice"])
        #expect(structural { $0.bikeShare.valet[0].hours![0].endMinute = 420 }
            == ["bikeShare.valet: abc-123 hours[0]: needs 0 ≤ startMinute < endMinute ≤ 1440"])
        #expect(structural { $0.bikeShare.valet[0].hours![0].endMinute = 1441 }.count == 1)
        #expect(structural { $0.bikeShare.valet[0].hours![0].endMinute = 1440 }.isEmpty)
        // The reader takes hours without a date (absent = no end date); the writer doesn't.
        #expect(structural { $0.bikeShare.valet[0].validUntilDate = nil }.isEmpty)
    }

    @Test func canonicalRulesOnTheM2cKeys() {
        #expect(canonical { $0.rules!.guardrail.choicesCentsPerMinute = [200, 100, 50] }
            == ["rules.guardrail.choicesCentsPerMinute: must be strictly ascending"])
        // Alert keywords: like PATH's.
        #expect(canonical { $0.weather!.alertKeywords[2].keywords = ["Wind"] } == ["weather.alertKeywords: 'Wind' must be lowercase"])
        #expect(canonical { $0.weather!.alertKeywords[2].keywords = ["tornado"] } == ["weather.alertKeywords: 'tornado' is in two rules"])
        #expect(canonical { $0.weather!.alertKeywords[1].keywords = ["winter", "wind chill"] }
            == ["weather.alertKeywords[1].keywords: entry 1 (wind chill) is not after winter (sorted by UTF-8 bytes, no repeats)"])
        #expect(canonical { $0.weather!.alertKeywords[3].alertClass = .highWind }
            == ["weather.alertKeywords: highWind has two rules (merge them)"])
        #expect(canonical { $0.weather!.alertKeywords[3].alertClass = .unknown }
            == ["weather.alertKeywords[3]: unknown is the class of no match, not a rule's"])
        #expect(canonical { $0.weather!.alertKeywords[3].keywords = [" coastal flood"] }
            == ["weather.alertKeywords: ' coastal flood' has surrounding whitespace"])
        #expect(canonical { $0.weather!.alertKeywords[3].keywords = ["coastal flood\t"] }
            == ["weather.alertKeywords: 'coastal flood\t' has surrounding whitespace"])
        // Order between rules is the priority, not a sort: a reorder is fine unless it makes a
        // keyword unreachable (one containing an earlier rule's never decides a match).
        #expect(canonical { $0.weather!.alertKeywords.swapAt(0, 3) }.isEmpty)
        #expect(canonical { $0.weather!.alertKeywords.reverse() }
            == ["weather.alertKeywords: 'wind chill' can never match: it contains 'wind', which an earlier rule has"])
        #expect(canonical { $0.weather!.alertKeywords[3].keywords = ["tornado warning"] }
            == ["weather.alertKeywords: 'tornado warning' can never match: it contains 'tornado', which an earlier rule has"])
        // PATH's table follows the same rules.
        #expect(canonical { $0.alerts.pathKeywords[1].keywords = ["delay", "no service today"] }
            == ["alerts.pathKeywords: 'no service today' can never match: it contains 'no service', which an earlier rule has"])
        #expect(canonical { $0.alerts.pathKeywords[1].keywords = ["delay "] }
            == ["alerts.pathKeywords: 'delay ' has surrounding whitespace"])
        #expect(canonical { $0.alerts.pathKeywords.reverse() }.isEmpty)
        // Valet.
        #expect(canonical { $0.bikeShare.valet[0].validUntilDate = nil }
            == ["bikeShare.valet: abc-123 has hours but no validUntilDate (a stale schedule must not apply silently)"])
        #expect(canonical { $0.bikeShare.valet[0].hours = nil } == ["bikeShare.valet: abc-123 has a validUntilDate but no hours"])
        #expect(canonical { $0.bikeShare.valet[0].hours = [] } == ["bikeShare.valet: abc-123 hours: empty (omit it: absent means never valet)"])
        #expect(canonical { $0.bikeShare.valet[0].hours!.reverse() }
            == ["bikeShare.valet: abc-123 hours: must be strictly ascending by (isoWeekdays, startMinute, endMinute)"])
        #expect(canonical { $0.bikeShare.valet[0].hours![0].isoWeekdays = [5, 4, 3, 2, 1] }
            == ["bikeShare.valet: abc-123 hours[0].isoWeekdays: must be strictly ascending"])
        #expect(canonical { $0.bikeShare.valet[0].hours![1] = ConfigValetHours(isoWeekdays: [5, 6], startMinute: 1000, endMinute: 1200) }
            == ["bikeShare.valet: abc-123 hours: two windows overlap on the same weekday"])
        #expect(canonical { $0.bikeShare.valet[0].hours![1] = ConfigValetHours(isoWeekdays: [5, 6], startMinute: 1140, endMinute: 1200) }
            .isEmpty) // touching, not overlapping
    }
}
