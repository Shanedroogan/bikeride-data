@testable import BRBuild
import BRCore
import BRData
import BRFlows
import Foundation
import Testing

/// A whole offline flows build over synthetic zips: a saved listing, three months for NYC and JC,
/// GBFS, the shared holiday file and a depot list.
private struct SyntheticTrips {
    let scratch: ScratchDirectory
    let runner = ProcessToolRunner()
    let months = (6...8).map { TripMonth(year: 2026, month: $0) }

    var trips: URL { scratch.file("trips") }
    var sources: URL { scratch.file("sources") }
    var out: URL { scratch.file("data") }
    static let holidays = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Data/config/calendar/holidays.csv")

    /// Every day: two NYC trips (one ending at a mangled `5343.1`) and one JC trip. `unmatchedNYC`
    /// NYC trips a day in `unmatchedMonth` start at a station GBFS no longer lists; `ebikeType` is
    /// what the NYC August file calls an e-bike.
    init(scratch: ScratchDirectory, unmatchedNYC: Int = 0, unmatchedMonth: Int = 8, ebikeType: String = "electric_bike",
         name: String = "trips") throws {
        self.scratch = scratch
        var objects: [TripListingObject] = []
        for month in months {
            var nyc = [TripFixture.header], jc = [TripFixture.header]
            var day = month.firstDay
            while day <= month.lastDay {
                let d = day.description
                nyc.append(TripFixture.row("classic_bike", "\(d) 08:05:00.000", "\(d) 08:20:00.000", from: "5343.10", to: "6131.1"))
                nyc.append(TripFixture.row(month.month == 8 ? ebikeType : "electric_bike", "\(d) 17:30:00.000", "\(d) 17:50:00.000",
                                           from: "6131.1", to: "5343.1"))
                if month.month == unmatchedMonth {
                    for _ in 0..<unmatchedNYC {
                        nyc.append(TripFixture.row("classic_bike", "\(d) 12:00:00.000", "\(d) 12:10:00.000", from: "5329.08", to: "6306.06"))
                    }
                }
                jc.append(TripFixture.row("electric_bike", "\(d) 09:00:00.000", "\(d) 09:12:00.000", from: "HB101", to: "HB101", quoted: true))
                day = day.adding(days: 1)
            }
            for key in ["\(month.yyyymm)-citibike-tripdata.zip", "JC-\(month.yyyymm)-citibike-tripdata.csv.zip"] {
                let rows = key.hasPrefix("JC-") ? jc : nyc
                let entry = key.replacingOccurrences(of: ".zip", with: "").replacingOccurrences(of: ".csv", with: "") + "_1.csv"
                let zip = scratch.file(name).appendingPathComponent(key)
                try StoredZip.write([(entry, Data((rows.joined(separator: "\n") + "\n").utf8))], to: zip)
                let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as! Int
                objects.append(TripListingObject(key: key, etag: "etag-\(key)", size: size, lastModified: ""))
            }
        }
        let listing = TripCache.SavedListing(fetchedAt: "2026-09-27T00:00:00Z", url: TripCache.listingURL, objects: objects)
        try JSONEncoder().encode(listing).write(to: scratch.file(name).appendingPathComponent("listing.json"))
        let stations = TripFixture.gbfs.filter { !$0.shortName.isEmpty }.map { station in
            "{\"station_id\":\"\(station.stationID)\",\"name\":\"\(station.name)\",\"short_name\":\"\(station.shortName)\",\"lat\":\(station.lat),\"lon\":\(station.lon),\"region_id\":\"\(station.regionID ?? "")\",\"capacity\":\(station.capacity ?? 0)}"
        }
        try scratch.write("sources/gbfs/gbfs.json", """
            {"last_updated":1790309897,"ttl":60,"version":"2.3","data":{"en":{"feeds":[{"name":"station_information","url":"https://example.test/si.json"}]}}}
            """)
        try scratch.write("sources/gbfs/station_information.json",
                          "{\"last_updated\":1790444627,\"data\":{\"stations\":[\(stations.joined(separator: ","))]}}")
        try scratch.write("depots.csv", "id,match,name,note\n1234.56,exact,a,b\nSYS,prefix,c,d\n")
    }

    func configuration(trips name: String = "trips", months: [TripMonth]? = nil, out: URL? = nil) -> FlowsCompiler.Configuration {
        var config = FlowsCompiler.Configuration(sourcesDirectory: sources, tripsDirectory: scratch.file(name), outputDirectory: out ?? self.out,
                                                 holidaysFile: Self.holidays, depotsFile: scratch.file("depots.csv"))
        config.offline = true
        config.threads = 3
        config.months = months
        config.compress = runner.locate("xz") != nil
        return config
    }

    func run(_ config: FlowsCompiler.Configuration, previous: FlowsReport? = nil) throws -> FlowsReport {
        try FlowsCompiler(runner: runner, configuration: config).run(previous: previous?.asPrevious)
    }
}

@Suite struct FlowsCompilerTests {
    @Test(.enabled(if: StoredZip.unzipInstalled)) func buildsThenFailsSoftThenRebuildsIdentically() throws {
        let fixture = try SyntheticTrips(scratch: try ScratchDirectory())
        let first = try fixture.run(fixture.configuration())
        #expect(first.outcome == .built && first.gate.passed && first.gate.failures.isEmpty)
        #expect(first.months == fixture.months)
        // Arrivals over the three months; departures stop a day early (Aug 31's trips that end on
        // Sep 1 are in the September file, which is not read).
        let june1 = ServiceDate(year: 2026, month: 6, day: 1)
        #expect(first.windows == FlowWindows(departures: FlowWindow(start: june1, dayCount: 91), arrivals: FlowWindow(start: june1, dayCount: 92)))
        #expect(first.holidays == [ServiceDate(year: 2026, month: 7, day: 3)])
        #expect(first.monthRows["NYC"] == ["202606": 60, "202607": 62, "202608": 62] && first.monthRows["JC"]?["202608"] == 31)
        let nyc = try #require(first.systems.first { $0.system == .nyc })
        #expect(nyc.newestMonth == TripMonth(year: 2026, month: 8) && nyc.endSide.stats.repaired == 92 && nyc.newestMonthEndSide.unmatchedShare == 0)
        #expect(nyc.startSide.stats.outsideDirectionWindow == 2 && nyc.startSide.stats.counted == 182 && nyc.startSide.stats.dropped == 0)
        #expect(first.daily.emptyDays.isEmpty && first.daily.minDepartures == 3)
        #expect(first.daily.departures.count == 91 && first.daily.arrivals.count == 92)
        #expect(first.gate.checkedMonths.first?.hasPrefix("no baseline") == true)

        let file = fixture.out.appendingPathComponent(MappedFlows.fileName)
        let flows = try MappedFlows(contentsOf: file)
        #expect(flows.header.builtAgainst.isEmpty && flows.header.formatVersion == 0)
        #expect(flows.header.dataVersion.hasPrefix("trips=202606-202608 JC202606:etag-JC-202606-citibike-tripdata.csv.zip:"))
        #expect(FlowsArtifactWriter.tripPins(ofDataVersion: flows.header.dataVersion)?.count == 6)
        #expect(flows.count == 4 && flows.key(0) == "5343.10" && flows.capacity(2) == 0)
        #expect(flows.departureWindow == FlowWindow(start: june1, dayCount: 91) && flows.arrivalWindow == FlowWindow(start: june1, dayCount: 92))
        #expect(flows.holidays == [ServiceDate(year: 2026, month: 7, day: 3)])
        // One classic 08:05 departure every day at 5343.10: the weekday mean at bin 32 is near 1.
        let row = try #require(flows.row(forKey: "5343.10"))
        // Aug 31 2026 is a Monday: one weekday fewer for departures.
        #expect(flows.activeDays(row, .weekday, .departures) == 64 && flows.activeDays(row, .weekend, .departures) == 27)
        #expect(flows.activeDays(row, .weekday, .arrivals) == 65 && flows.activeDays(row, .weekend, .arrivals) == 27)
        #expect(abs(flows.mean(row, .weekday, .departures, .classic, bin: 32) - 1) < 0.1)
        #expect(flows.variance(row, .weekday, .departures, .classic, bin: 32) >= flows.mean(row, .weekday, .departures, .classic, bin: 32))
        if fixture.configuration().compress { #expect(first.artifact?.xzStreams == 1 && first.artifact?.xzBlocks == 1) }
        #expect(!FileManager.default.fileExists(atPath: fixture.out.appendingPathComponent(".flows-staging").path))

        // The same newest month from the same inputs: nothing new, the file stays.
        let bytes = try Data(contentsOf: file)
        let second = try fixture.run(fixture.configuration(), previous: first)
        #expect(second.outcome == .keptPrevious && second.reason?.hasPrefix("no new month") == true)
        #expect(try Data(contentsOf: file) == bytes)
        // Explicit months always build, byte-identically.
        let other = fixture.scratch.file("data2")
        let third = try fixture.run(fixture.configuration(months: fixture.months, out: other), previous: first)
        #expect(third.outcome == .built)
        #expect(try Data(contentsOf: other.appendingPathComponent(MappedFlows.fileName)) == bytes)
        #expect(third.gate.checkedMonths.contains("NYC 202608: 62 rows, 62 before"))
        // Offline without a listing: fail soft.
        let bare = try fixture.run(fixture.configuration(trips: "no-such-cache"))
        #expect(bare.outcome == .keptPrevious && bare.reason?.contains("listing") == true)
    }

    @Test(.enabled(if: StoredZip.unzipInstalled)) func gateFailuresKeepTheFileInPlace() throws {
        let scratch = try ScratchDirectory()
        let fixture = try SyntheticTrips(scratch: scratch)
        let built = try fixture.run(fixture.configuration())
        #expect(built.outcome == .built)
        let file = fixture.out.appendingPathComponent(MappedFlows.fileName)
        let bytes = try Data(contentsOf: file)

        // August NYC: 2 matched and 1 unmatched start a day (33%).
        _ = try SyntheticTrips(scratch: scratch, unmatchedNYC: 1, name: "bad")
        let failed = try fixture.run(fixture.configuration(trips: "bad", months: fixture.months), previous: built)
        #expect(failed.outcome == .gateFailed && !failed.gate.passed)
        #expect(failed.gate.failures.contains { $0.hasPrefix("NYC 202608 start ids: 33.333% unmatched") })
        #expect(failed.artifact == nil)
        #expect(try Data(contentsOf: file) == bytes)
        // A failed build never becomes the baseline.
        #expect(failed.baselineForNext == built.monthRows)

        // Month rows: the same month with far fewer rows than the last passing build.
        var inflated = built
        inflated.monthRows["NYC"]?["202607"] = 1_000
        let shrunk = try fixture.run(fixture.configuration(months: fixture.months), previous: inflated)
        #expect(shrunk.outcome == .gateFailed)
        #expect(shrunk.gate.failures == ["NYC 202607: 62 rows, 1000 in the previous build (limit 90%)"])
        // A new month against the month before it: the baseline's 202605 for 202606, then this
        // build's own counts.
        var older = built
        older.monthRows = ["NYC": ["202605": 1_000], "JC": ["202605": 31]]
        let small = try fixture.run(fixture.configuration(months: fixture.months), previous: older)
        #expect(small.gate.failures == ["NYC 202606: 60 rows, under 50% of 202605 (1000)"])
        #expect(small.gate.checkedMonths.contains("NYC 202607: 62 rows, 60 in 202606"))
        #expect(try Data(contentsOf: file) == bytes)
    }

    /// Citi Bike renames `electric_bike` in the August NYC file: its rows still count and every day
    /// still has classic trips, but half its trip ends are dropped.
    @Test(.enabled(if: StoredZip.unzipInstalled)) func droppedTripEndsFailTheGate() throws {
        let fixture = try SyntheticTrips(scratch: try ScratchDirectory(), ebikeType: "ebike")
        let report = try fixture.run(fixture.configuration())
        #expect(report.outcome == .gateFailed && report.artifact == nil)
        #expect(report.gate.failures == [
            "NYC 202608 start: 50.000% of the trip ends at stations dropped (unknown rideable_type 31, bad time 0, outside the window 0; limit 1.0%)",
            "NYC 202608 end: 50.000% of the trip ends at stations dropped (unknown rideable_type 31, bad time 0, outside the window 0; limit 1.0%)",
        ])
        #expect(report.systems.first { $0.system == .nyc }?.unknownRideableTypes == ["ebike": 31])
        #expect(!FileManager.default.fileExists(atPath: fixture.out.appendingPathComponent(MappedFlows.fileName).path))
    }

    /// A June file with a third of its NYC starts unmatched: the newest month is clean, the window is not.
    @Test(.enabled(if: StoredZip.unzipInstalled)) func anOlderMonthsUnmatchedEndsAreCappedOverTheWindow() throws {
        let fixture = try SyntheticTrips(scratch: try ScratchDirectory(), unmatchedNYC: 1, unmatchedMonth: 6)
        let report = try fixture.run(fixture.configuration())
        #expect(report.outcome == .gateFailed)
        #expect(report.gate.failures == ["NYC window start ids: 14.019% unmatched (limit 5.0%)"])
    }

    @Test(.enabled(if: StoredZip.unzipInstalled)) func failsSoftAndRebuildsForTheRightReasons() throws {
        let scratch = try ScratchDirectory()
        let fixture = try SyntheticTrips(scratch: scratch)
        let file = fixture.out.appendingPathComponent(MappedFlows.fileName)
        // A flows.bin whose dataVersion this builder did not write (no pins) never blocks a build,
        // even when its window ends with the newest month.
        try FileManager.default.createDirectory(at: fixture.out, withIntermediateDirectories: true)
        try HandBuiltFlows.artifact().write(to: file)
        let built = try fixture.run(fixture.configuration())
        #expect(built.outcome == .built && built.previousDataVersion == "hand-built")
        #expect(try MappedFlows(contentsOf: file).header.dataVersion == built.dataVersion)

        // Another holidays.csv (a renamed holiday): the same window again, with the new sha.
        let holidays = try String(contentsOf: SyntheticTrips.holidays, encoding: .utf8)
        let renamed = try scratch.write("holidays.csv", holidays.replacingOccurrences(of: "New Year's Day", with: "New Year's Day (observed)"))
        var config = fixture.configuration()
        config.holidaysFile = renamed
        var lines: [String] = []
        let rebuilt = try FlowsCompiler(runner: fixture.runner, configuration: config).run(previous: built.asPrevious) { lines.append($0) }
        #expect(rebuilt.outcome == .built && rebuilt.dataVersion != built.dataVersion)
        #expect(lines.contains { $0.hasPrefix("rebuilding 202608: holidays.csv or depots.csv changed") })
        #expect(try FlowsCompiler(runner: fixture.runner, configuration: config).run(previous: rebuilt.asPrevious).outcome == .keptPrevious)

        // Offline without GBFS: fail soft (exit 4), not an error.
        var noGBFS = fixture.configuration(months: fixture.months)
        noGBFS.sourcesDirectory = scratch.file("no-sources")
        let bare = try fixture.run(noGBFS)
        #expect(bare.outcome == .keptPrevious && bare.reason?.contains("--offline") == true)
    }

    /// The previous report is read for its row counts alone, so a report with fields this build
    /// does not know (or lacks ones it added since) still serves as the baseline.
    @Test func readsThePreviousReportForItsRowCountsAlone() throws {
        let json = #"{"outcome":"built","monthRows":{"NYC":{"202608":5}},"somethingNew":[1],"gate":{"passed":true}}"#
        let previous = try JSONDecoder().decode(FlowsReport.Previous.self, from: Data(json.utf8))
        #expect(previous.baselineForNext == ["NYC": ["202608": 5]])
        let failed = FlowsReport.Previous(outcome: .gateFailed, monthRows: ["NYC": ["202609": 1]], baselineMonthRows: ["NYC": ["202608": 5]])
        #expect(failed.baselineForNext == ["NYC": ["202608": 5]])
    }

    /// The review's case: October passed, November failed (or was skipped), and December is a
    /// winter month. Each month is compared with the one before it, never across the season.
    @Test func newMonthsAreComparedWithTheMonthBefore() {
        var report = FlowsReport(tool: "test")
        report.monthRows = ["NYC": ["202610": 5_000_000, "202611": 3_500_000, "202612": 2_250_000]]
        let baseline = ["NYC": ["202608": 5_200_000, "202609": 5_300_000, "202610": 5_000_000]]
        var gate = FlowsGate.evaluate(report, baseline: baseline)
        #expect(gate.failures.isEmpty)
        #expect(gate.checkedMonths == ["NYC 202610: 5000000 rows, 5000000 before", "NYC 202611: 3500000 rows, 5000000 in 202610",
                                       "NYC 202612: 2250000 rows, 3500000 in 202611"])
        // A truncated December still fails, against November.
        report.monthRows["NYC"]?["202612"] = 1_000_000
        gate = FlowsGate.evaluate(report, baseline: baseline)
        #expect(gate.failures == ["NYC 202612: 1000000 rows, under 50% of 202611 (3500000)"])
        // A whole window since the baseline: the first month has nothing to be compared with.
        gate = FlowsGate.evaluate(report, baseline: ["NYC": ["202606": 5_000_000]])
        #expect(gate.checkedMonths.first == "NYC 202610: 5000000 rows, not compared (no count for 202609)")
        // No baseline at all: still month to month inside the build.
        gate = FlowsGate.evaluate(report, baseline: nil)
        #expect(gate.checkedMonths.first?.hasPrefix("no baseline") == true && gate.failures == ["NYC 202612: 1000000 rows, under 50% of 202611 (3500000)"])
    }

    @Test func parsesMonthLists() {
        let june = TripMonth(year: 2026, month: 6)
        #expect(TripMonth.parseList("202606-202608") == [june, june.adding(1), june.adding(2)])
        #expect(TripMonth.parseList("202606,202607") == [june, june.adding(1)])
        #expect(TripMonth.parseList("202612-202601") == nil)
        #expect(TripMonth.parseList("202611-202702") == [june.adding(5), june.adding(6), june.adding(7), june.adding(8)])
        for bad in ["", "2026", "202606,202608", "202606-", "202601-202701", "202606,,202607", "202606-202607-202608"] {
            #expect(TripMonth.parseList(bad) == nil, "\(bad)")
        }
    }
}
