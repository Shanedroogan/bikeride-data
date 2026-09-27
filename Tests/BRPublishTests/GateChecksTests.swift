import BRBuild
import BRCore
import Foundation
import Testing

/// The gate's rules on plain inputs.
@Suite struct GateChecksTests {
    // MARK: Trip counts

    /// Daily counts for `from…to`: weekdays `weekday`, Saturdays `saturday`, Sundays `sunday`,
    /// with `overrides` on top.
    static func counts(_ from: String, _ to: String, weekday: Int = 1000, saturday: Int = 700, sunday: Int = 600,
                       overrides: [String: Int] = [:]) -> [ServiceDate: Int] {
        var result: [ServiceDate: Int] = [:]
        var date = day(from)
        while date <= day(to) {
            result[date] = overrides[date.yyyymmdd] ?? (date.weekday == .saturday ? saturday : date.weekday == .sunday ? sunday : weekday)
            date = date.adding(days: 1)
        }
        return result
    }

    static let holidays: Set<ServiceDate> = [day("20261012"), day("20261111"), day("20261126"), day("20261127"), day("20261225")]

    @Test func sameDateComparisonLetsAHolidayDropPass() {
        // Thanksgiving at the Sunday level (−40 % against a Thursday) in both builds.
        let thanksgiving = ["20261126": 600]
        let previous = Self.counts("20261001", "20261231", overrides: thanksgiving)
        let current = Self.counts("20261002", "20261231", overrides: thanksgiving)
        let result = GateChecks.tripCounts(current: ["bus": current], previous: ["bus": previous], holidays: Self.holidays, maxChangePercent: 35)
        #expect(result.status == .pass)
        #expect(result.metrics["bus.sameDate"] == Double(current.count))
        #expect(result.metrics["bus.worstChangePercent"] == 0)
    }

    @Test func newHolidaysUseTheNearestProfile() {
        // The previous build ended 10/31; the current one adds November and December.
        let previous = Self.counts("20261001", "20261031", overrides: ["20261012": 1000])
        let current = Self.counts("20261002", "20261231", overrides: [
            "20261111": 980,    // Veterans Day on the weekday schedule
            "20261126": 600,    // Thanksgiving on the Sunday schedule (−40 % against a Thursday)
            "20261127": 780,    // the day after, nearest the Saturday level
            "20261225": 610,
        ])
        let result = GateChecks.tripCounts(current: ["bus": current], previous: ["bus": previous], holidays: Self.holidays, maxChangePercent: 35)
        #expect(result.status == .pass, "\(result.failures)")
        #expect(result.metrics["bus.weekdayProfile"] == Double(current.keys.filter { $0 > day("20261031") }.count))
        #expect(result.notes.contains { $0.contains("worst:") })

        // Sunday alone (the rule as first written) fails Veterans Day on the weekday schedule.
        let sundayOnly = GateChecks.tripCounts(current: ["bus": current], previous: ["bus": previous], holidays: Self.holidays,
                                               maxChangePercent: 35, holidayProfiles: [.sunday])
        #expect(sundayOnly.status == .fail)
        #expect(sundayOnly.failures.count == 1 && sundayOnly.failures[0].contains("2026-11-11"))
        // Without the holiday list, Thanksgiving is a Thursday at −40 %.
        let noHolidays = GateChecks.tripCounts(current: ["bus": current], previous: ["bus": previous], holidays: [], maxChangePercent: 35)
        #expect(noHolidays.failures.contains { $0.contains("2026-11-26") })
    }

    @Test func holidaysAreLeftOutOfTheWeekdayMedians() {
        // Four Mondays in the previous build, one of them Columbus Day at 1 trip: excluded, so the
        // median Monday stays 1000 and a new Monday at 1000 passes.
        let previous = Self.counts("20261001", "20261031", overrides: ["20261012": 1])
        let current = Self.counts("20261102", "20261102")
        let result = GateChecks.tripCounts(current: ["subway": current], previous: ["subway": previous], holidays: Self.holidays, maxChangePercent: 35)
        #expect(result.status == .pass)
        #expect(result.metrics["subway.worstChangePercent"] == 0)
    }

    @Test func aDropBeyondTheLimitFailsEitherWay() {
        let previous = Self.counts("20261001", "20261031")
        for (trips, fails) in [(640, true), (660, false), (1340, false), (1360, true)] {
            let current = Self.counts("20261005", "20261031", overrides: ["20261014": trips])
            let result = GateChecks.tripCounts(current: ["lirr": current], previous: ["lirr": previous], holidays: [], maxChangePercent: 35)
            #expect((result.status == .fail) == fails, "\(trips)")
            if fails { #expect(result.failures == [result.failures[0]] && result.failures[0].hasPrefix("lirr 2026-10-14: \(trips) trips vs 1000")) }
        }
        // A covered date with no trips at all.
        let empty = GateChecks.tripCounts(current: ["lirr": Self.counts("20261005", "20261010", overrides: ["20261007": 0])],
                                          previous: ["lirr": previous], holidays: [], maxChangePercent: 35)
        #expect(empty.status == .fail && empty.failures[0].contains("-100.0%"))
    }

    @Test func missingPreviousIsSkippedWithAWarning() {
        let current = Self.counts("20261005", "20261010")
        let none = GateChecks.tripCounts(current: ["bus": current], previous: nil, holidays: [], maxChangePercent: 35)
        #expect(none.status == .skipped && !none.warnings.isEmpty)
        let newSystem = GateChecks.tripCounts(current: ["bus": current, "path": current], previous: ["bus": current], holidays: [], maxChangePercent: 35)
        #expect(newSystem.status == .pass)
        #expect(newSystem.warnings == ["path: no previous trip counts; not compared"])
    }

    // MARK: Coverage

    @Test func shortCoverageFailsSoftAndKeepsTheDates() {
        let today = day("20261006")
        let dates = (0..<20).map { day("20261005").adding(days: $0) }
        let (result, systems) = GateChecks.coverage(
            ["subway": dates, "lirr": [day("20261005"), day("20261006"), day("20261007")], "path": [day("20261006"), day("20261007"), day("20261009")]],
            today: today, minDays: 3)
        #expect(result.status == .softFail)
        #expect(systems["subway"] == GateSystem(status: .ok, coverageDays: 19, dates: 20, first: "2026-10-05", last: "2026-10-24"))
        #expect(systems["lirr"]?.status == .noSchedule && systems["lirr"]?.coverageDays == 2)
        // A gap ends the run of days, as the relay counts.
        #expect(systems["path"]?.status == .noSchedule && systems["path"]?.coverageDays == 2 && systems["path"]?.dates == 3)
        #expect(result.failures.count == 2)
        let (ok, _) = GateChecks.coverage(["subway": dates], today: today, minDays: 3)
        #expect(ok.status == .pass)
    }

    // MARK: Streets

    @Test func regionsBelowTheirShareFail() {
        let thresholds = GateConfiguration.Thresholds.Streets(minKeptSharePercent: 90, regions: ["Hoboken": 89, "Brooklyn": 96])
        let regions: [String: StreetBuildStats.RegionLength] = [
            "Hoboken": .init(totalMeters: 1000, keptMeters: 900), "Brooklyn": .init(totalMeters: 1000, keptMeters: 992),
            "Queens": .init(totalMeters: 1000, keptMeters: 905),
        ]
        #expect(GateChecks.streetRegions(regions, thresholds: thresholds).status == .pass)
        var broken = regions
        broken["Brooklyn"] = .init(totalMeters: 1000, keptMeters: 500)
        broken["Queens"] = .init(totalMeters: 1000, keptMeters: 899)   // the default minimum
        let result = GateChecks.streetRegions(broken, thresholds: thresholds)
        #expect(result.status == .fail && result.failures.count == 2)
        var missing = regions
        missing["Hoboken"] = nil
        #expect(GateChecks.streetRegions(missing, thresholds: thresholds).failures == ["Hoboken: not in the streets report's regions"])
        // A region that lost every street (the report calls that a 100 % share), configured or not.
        var emptied = regions
        emptied["Hoboken"] = .init(totalMeters: 0, keptMeters: 0)
        emptied["Queens"] = .init(totalMeters: 0, keptMeters: 0)
        #expect(emptied["Hoboken"]?.keptShare == 1)
        let empty = GateChecks.streetRegions(emptied, thresholds: thresholds)
        #expect(empty.status == .fail)
        #expect(empty.failures == ["Hoboken: no street length in the region before the component filter",
                                   "Queens: no street length in the region before the component filter"])
    }

    // MARK: Snapping

    @Test func snappingHonorsTheAllowlistAndFlagsStaleEntries() {
        func stop(_ id: String, inside: Bool = true, entry: Bool = true, exit: Bool = true, snap: Double = 20) -> GateChecks.SnapStop {
            GateChecks.SnapStop(id: id, name: "Stop \(id)", inServiceArea: inside, streetEntry: entry, streetExit: exit, maxSnapMeters: snap)
        }
        let exceptions = [
            GateConfiguration.SnapException(stop: "B:203592", rule: .snap, maxMeters: 110, reason: "far street"),
            GateConfiguration.SnapException(stop: "B:904251", rule: .noStreetAccess, maxMeters: nil, reason: "airport"),
            GateConfiguration.SnapException(stop: "B:999999", rule: .noStreetAccess, maxMeters: nil, reason: "gone"),
        ]
        let stops = [stop("S:101"), stop("B:203592", snap: 105.8), stop("B:904251", entry: false, exit: false),
                     stop("B:805054", inside: false, snap: 100.9), stop("L:1", inside: false, entry: false)]
        let result = GateChecks.snapping(stops, maxSnapMeters: 100, exceptions: exceptions)
        #expect(result.status == .pass, "\(result.failures)")
        #expect(result.notes.count == 2 && result.notes.allSatisfy { $0.hasPrefix("allowlisted: ") })
        #expect(result.warnings.count == 1 && result.warnings[0].contains("B:999999"))
        #expect(result.metrics["stopsInServiceArea"] == 3 && result.metrics["stopsOutside"] == 2)

        let failing = GateChecks.snapping(stops + [stop("B:1", snap: 100.5), stop("B:2", exit: false), stop("B:203592x", snap: 120)],
                                          maxSnapMeters: 100, exceptions: exceptions)
        #expect(failing.status == .fail && failing.failures.count == 3)
        // An allowlisted stop that drifts past its allowance fails again.
        let drifted = GateChecks.snapping([stop("B:203592", snap: 111)], maxSnapMeters: 100, exceptions: exceptions)
        #expect(drifted.status == .fail)
        // The allowance is per rule: a snap exception does not excuse missing street access.
        let wrongRule = GateChecks.snapping([stop("B:203592", entry: false)], maxSnapMeters: 100, exceptions: exceptions)
        #expect(wrongRule.status == .fail)
        // Nothing to check is a failure, not a skip: a broken service area puts every stop outside.
        let outside = GateChecks.snapping([stop("S:101", inside: false), stop("B:1", inside: false)], maxSnapMeters: 100, exceptions: [])
        #expect(outside.status == .fail && outside.failures.first?.hasPrefix("none of the 2 routable stops is inside the service area") == true)
        let none = GateChecks.snapping([], maxSnapMeters: 100, exceptions: [])
        #expect(none.status == .fail && none.failures == ["no routable stops in links"])
    }

    // MARK: setId

    #if !canImport(CryptoKit)
    /// On Linux the digest comes from `sha256sum`: without it there is no setId, never an empty one.
    @Test func setIdThrowsWithoutAHashTool() {
        struct NoTools: ToolRunner {
            func locate(_ executable: String) -> String? { nil }
            func run(executable: String, args: [String], stdin: Data?) throws -> Data { throw ToolError.notFound(executable: executable) }
            func stream(executable: String, args: [String], stdinFile: URL?) throws -> ToolStream { throw ToolError.notFound(executable: executable) }
        }
        #expect(throws: (any Error).self) { try SetManifest.setId([:], runner: NoTools()) }
    }
    #endif

    // MARK: Configuration files

    @Test func theRepositoryConfigurationLoads() throws {
        let configuration = try GateConfiguration.load(repoData: SyntheticSet.repoData)
        #expect(configuration.thresholds.tripCounts == .init(maxChangePercent: 35, holidayProfiles: [.weekday, .saturday, .sunday]))
        #expect(configuration.thresholds.coverage.minDays == 3)
        #expect(configuration.thresholds.snapping.maxSnapMeters == 100)
        #expect(configuration.thresholds.streets.regions.count == 7)
        #expect(configuration.snapExceptions.map(\.stop) == ["B:203592", "B:552077", "B:904251", "B:982174"])
        #expect(configuration.snapExceptions.first?.maxMeters == 110)
        #expect(configuration.holidays.count == 25 && configuration.holidays.contains(day("20261126")))
    }

    @Test func configurationFilesAreReadStrictly() throws {
        let scratch = try PublishScratch()
        let repo = scratch.url
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("gate"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("config/calendar"), withIntermediateDirectories: true)
        for path in [GateConfiguration.allowlistPath, GateConfiguration.holidaysPath] {
            try FileManager.default.copyItem(at: SyntheticSet.repoData.appendingPathComponent(path), to: repo.appendingPathComponent(path))
        }
        let original = try String(contentsOf: SyntheticSet.repoData.appendingPathComponent(GateConfiguration.thresholdsPath), encoding: .utf8)
        let thresholds = repo.appendingPathComponent(GateConfiguration.thresholdsPath)
        try original.replacingOccurrences(of: "\"maxSnapMeters\"", with: "\"maxSnapMeter\"").write(to: thresholds, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try GateConfiguration.load(repoData: repo) }   // missing key
        try original.replacingOccurrences(of: "\"minDays\": 3", with: "\"minDays\": 3, \"minDayz\": 4").write(to: thresholds, atomically: true, encoding: .utf8)
        #expect(throws: GateConfiguration.ConfigurationError.unknownKeys(file: thresholds.path, keys: ["coverage.minDayz"])) {
            try GateConfiguration.load(repoData: repo)
        }
        try original.replacingOccurrences(of: "\"sunday\"]", with: "\"monday\"]").write(to: thresholds, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try GateConfiguration.load(repoData: repo) }

        #expect(throws: (any Error).self) { try GateConfiguration.parseAllowlist("stop,rule,maxMeters,reason\nB:1,snapp,110,x\n") }
        #expect(throws: (any Error).self) { try GateConfiguration.parseAllowlist("stop,rule,maxMeters,reason\nB:1,snap,,x\n") }
        #expect(throws: (any Error).self) { try GateConfiguration.parseAllowlist("stop,rule,maxMeters,reason\nB:1,noStreetAccess,5,x\n") }
        #expect(throws: (any Error).self) { try GateConfiguration.parseAllowlist("stop,rule,maxMeters,reason\nB:1,snap,110,a\nB:1,snap,120,b\n") }
        #expect(try GateConfiguration.parseAllowlist("stop,rule,maxMeters,reason\n# note\n\nB:1,snap,110,a, with commas\n")[0].reason == "a, with commas")
        #expect(throws: (any Error).self) { try GateConfiguration.parseHolidays("date,name,profile\n20261010,Saturday,weekend\n") }
        #expect(throws: (any Error).self) { try GateConfiguration.parseHolidays("date,name,profile\n20261126,A,weekend\n20261012,B,weekday\n") }
    }

    @Test func theRepositoryDataIsFoundFromTheAppRepositoryRoot() throws {
        let scratch = try PublishScratch()
        #expect(GateConfiguration.defaultRepoData(currentDirectory: SyntheticSet.repoData.deletingLastPathComponent())?.standardizedFileURL
                    == SyntheticSet.repoData.standardizedFileURL)
        // From a directory without Data/, the source tree this binary was built from.
        #expect(GateConfiguration.defaultRepoData(currentDirectory: scratch.url) != nil)
        let appRoot = scratch.url.appendingPathComponent("Vendor/bikeride-data/Data/gate")
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: appRoot.appendingPathComponent("thresholds.json"))
        #expect(GateConfiguration.defaultRepoData(currentDirectory: scratch.url)?.path.hasSuffix("Vendor/bikeride-data/Data") == true)
    }
}
