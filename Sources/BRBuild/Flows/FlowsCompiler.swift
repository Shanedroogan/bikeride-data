import BRCore
import BRData
import BRFlows
import Foundation

/// Builds the `flows` artifact (kind 8): list the public Citi Bike `tripdata` bucket, pick the newest
/// three months published for both NYC and JC, fetch them into the trip cache, count every trip end
/// at a GBFS station (full `station_information`, capacity 0 included), smooth, gate, and write
/// `flows.bin` (+ `.xz`) only when the gate passes. Otherwise the file in place is kept.
///
/// The outcome maps to the CLI's exit status: built 0, gate failure 3, kept previous (no new month,
/// or offline without the inputs) 4.
public struct FlowsCompiler: Sendable {
    public struct Configuration: Sendable {
        /// GBFS goes to `<sources>/gbfs`, shared with `stations`.
        public var sourcesDirectory: URL
        /// The trip-zip cache (default `build/trips`; never inside a repository).
        public var tripsDirectory: URL
        public var outputDirectory: URL
        /// `Data/config/calendar/holidays.csv` and `Data/flows/depots.csv`.
        public var holidaysFile: URL
        public var depotsFile: URL
        /// Months to build instead of the newest three (and no "nothing new" check).
        public var months: [TripMonth]?
        public var monthCount = 3
        public var offline = false
        public var compress = true
        public var threads = ProcessInfo.processInfo.activeProcessorCount
        public var smoothing = FlowSmoothingParameters.m1

        public init(sourcesDirectory: URL, tripsDirectory: URL, outputDirectory: URL, holidaysFile: URL, depotsFile: URL) {
            self.sourcesDirectory = sourcesDirectory
            self.tripsDirectory = tripsDirectory
            self.outputDirectory = outputDirectory
            self.holidaysFile = holidaysFile
            self.depotsFile = depotsFile
        }

        public var gbfsDirectory: URL { sourcesDirectory.appendingPathComponent("gbfs") }
        public var discoveryFile: URL { gbfsDirectory.appendingPathComponent("gbfs.json") }
        public var stationInformationFile: URL { gbfsDirectory.appendingPathComponent("station_information.json") }
        public var artifactFile: URL { outputDirectory.appendingPathComponent(MappedFlows.fileName) }
    }

    public let runner: any ToolRunner
    public let configuration: Configuration

    public init(runner: any ToolRunner, configuration: Configuration) {
        self.runner = runner
        self.configuration = configuration
    }

    /// Runs the build. `previous` is the last report written (its baseline row counts feed the
    /// month comparison). Throws only for errors that are neither a gate failure nor a fail-soft.
    public func run(previous: FlowsReport? = nil, log: (String) -> Void = { _ in }) throws -> FlowsReport {
        let config = configuration
        var seconds: [String: Double] = [:]
        func timed<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            defer { seconds[phase, default: 0] += Date().timeIntervalSince(start) }
            return try body()
        }
        let started = Date()
        var report = FlowsReport(tool: "bikeride-data \(BuildInfo.toolVersion) (Swift \(BuildInfo.swiftVersion))")
        report.baselineMonthRows = previous?.baselineForNext
        report.parameters = config.smoothing
        func finish(_ outcome: FlowsReport.Outcome, _ reason: String? = nil) -> FlowsReport {
            report.outcome = outcome
            report.reason = reason
            if let reason { report.gate.failures.append(contentsOf: outcome == .gateFailed ? [reason] : []) }
            report.gate.passed = outcome == .built
            seconds["total"] = Date().timeIntervalSince(started)
            report.seconds = seconds
            report.peakRSSBytes = TimetableBuild.peakRSSBytes()
            return report
        }

        // 1. Build-only inputs.
        let holidaysData = try Data(contentsOf: config.holidaysFile)
        let depotsData = try Data(contentsOf: config.depotsFile)
        let calendar = try FlowCalendar(csv: holidaysData)
        let depots = try DepotList(csv: depotsData)
        report.depots = FlowsReport.Depots(exact: depots.exact.map { String(decoding: $0, as: UTF8.self) }.sorted(),
                                           prefixes: depots.prefixes.map { String(decoding: $0, as: UTF8.self) })

        // 2. The flows file in place, if any: its window's last month and input pins.
        var previousEnd: TripMonth?
        var previousPins: [String]?
        if FileManager.default.fileExists(atPath: config.artifactFile.path),
           let flows = try? MappedFlows(contentsOf: config.artifactFile, validate: false) {
            previousEnd = TripMonth(year: flows.arrivalWindow.end.year, month: flows.arrivalWindow.end.month)
            previousPins = FlowsArtifactWriter.tripPins(ofDataVersion: flows.header.dataVersion)
            report.previousDataVersion = flows.header.dataVersion
        }

        // 3. The listing and the months.
        let cache = TripCache(directory: config.tripsDirectory, runner: runner, offline: config.offline)
        let listing: TripCache.SavedListing
        do {
            listing = try timed("listing") { try cache.listing() }
        } catch let error as TripCache.CacheError {
            return finish(.keptPrevious, "\(error)")
        }
        report.listingFetchedAt = listing.fetchedAt
        let files = try TripSources.monthlyFiles(listing.objects)
        let months: [TripMonth]
        if let explicit = config.months {
            let missing = TripSystem.allCases.flatMap { system in explicit.filter { files[system]?[$0] == nil }.map { "\(system.rawValue) \($0)" } }
            guard missing.isEmpty else { return finish(.gateFailed, "the listing has no \(missing.joined(separator: ", "))") }
            months = explicit
        } else {
            switch TripSources.choose(files, count: config.monthCount, previousEnd: previousEnd, previousPins: previousPins) {
            case .window(let chosen): months = chosen
            case .nothingNew(let newest):
                return finish(.keptPrevious, "no new month: the newest month published for NYC and JC is \(newest), and flows.bin already ends with it (same inputs)")
            case .missing(let missing): return finish(.gateFailed, "the window lacks \(missing.joined(separator: ", "))")
            case .noCommonMonth: return finish(.gateFailed, "the listing has no month published for both NYC and JC")
            }
        }
        report.months = months
        let window = FlowWindow(start: months[0].firstDay, dayCount: months[0].firstDay.distance(to: months[months.count - 1].lastDay) + 1)
        report.window = window
        try calendar.requireCoverage(from: window.start, through: window.end)
        report.holidays = calendar.weekendHolidays(from: window.start, through: window.end)
        log("window \(window.start)…\(window.end) (\(months.map(\.yyyymm).joined(separator: ", ")))")

        // 4. Trip zips and GBFS.
        let sources = TripSources.files(of: months, in: files)
        report.tripFiles = sources
        var records: [SourceRecord] = []
        do {
            for source in sources {
                log("fetching \(source.object.key) (\(source.object.size) bytes)")
                let record = try timed("download") { try cache.fetch(source) }
                log("  \(record.status)")
                records.append(record)
            }
        } catch let error as TripCache.CacheError {
            if case .notCached = error { return finish(.keptPrevious, "\(error)") }
            throw error
        }
        let fetcher = SourceFetcher(runner: runner, offline: config.offline)
        let (discovery, information) = try timed("download") { () throws -> (SourceRecord, SourceRecord) in
            let discovery = try fetcher.fetch(GBFSStations.discoveryURL, to: config.discoveryFile)
            let url = try GBFSStations.stationInformationURL(discovery: Data(contentsOf: config.discoveryFile))
            return (discovery, try fetcher.fetch(url, to: config.stationInformationFile))
        }
        report.sources = records + [discovery, information]
        let feed = try GBFSStations.parseStationInformation(Data(contentsOf: config.stationInformationFile))
        let universe: FlowUniverse
        do {
            universe = try FlowUniverse(gbfs: feed.stations)
        } catch let error as FlowsInputError {
            return finish(.gateFailed, "\(error)")
        }
        let gbfsVersion = feed.lastUpdated.map { SourceRecord.isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
            ?? information.versionTag
        report.gbfs = FlowsReport.GBFS(
            version: gbfsVersion, feedStations: universe.feedStations, feedEntriesDropped: feed.dropped, keys: universe.stations.count,
            capacityZero: universe.capacityZero, droppedTestRegion: universe.droppedTestRegion,
            droppedNoShortName: universe.droppedNoShortName, droppedDuplicateStationID: universe.droppedDuplicateStationID
        )
        log("universe: \(universe.stations.count) keys (\(universe.capacityZero) at capacity 0) from \(universe.feedStations) GBFS stations")

        // 5. Count, tally, smooth.
        let inputs = zip(sources, records).map { source, record in
            TripInput(system: source.system, month: source.month, archive: ZipTripArchive(archive: URL(fileURLWithPath: record.path), runner: runner))
        }
        let binned = try timed("count") {
            try FlowBinner.count(inputs, universe: universe, depots: depots, window: window, threads: config.threads, log: log)
        }
        log(String(format: "counted %d rows in %.1f s", binned.files.reduce(0) { $0 + $1.rows }, seconds["count"] ?? 0))
        let tallies = timed("tally") { FlowTallies.tally(binned.counts, calendar: calendar) }
        let smoothed = timed("smooth") {
            FlowSmoothing.smooth(tallies, latE6: universe.stations.map(\.latE6), lonE6: universe.stations.map(\.lonE6), parameters: config.smoothing)
        }
        report.record(files: binned.files, tallies: tallies, saturated: binned.counts.saturated, smoothing: smoothed.stats)

        // 6. Gate.
        report.gate = FlowsGate.evaluate(report, baseline: report.baselineMonthRows)
        guard report.gate.failures.isEmpty else {
            for failure in report.gate.failures { log("gate: \(failure)") }
            return finish(.gateFailed)
        }

        // 7. Write through a staging directory, so the file in place changes only as a whole.
        let holidaysSha = try ArtifactOutput.sha256(ofFileAt: config.holidaysFile, runner: runner)
        let depotsSha = try ArtifactOutput.sha256(ofFileAt: config.depotsFile, runner: runner)
        let dataVersion = FlowsArtifactWriter.dataVersion(months: months, sources: sources, gbfs: gbfsVersion,
                                                          holidaysSha: holidaysSha, depotsSha: depotsSha)
        let data = FlowsArtifactWriter.data(universe: universe, tallies: tallies, cells: smoothed.cells, flags: smoothed.flags,
                                            calendar: calendar, parameters: config.smoothing)
        let bytes = try timed("encode") { try data.artifactBytes(dataVersion: dataVersion) }
        let staging = config.outputDirectory.appendingPathComponent(".flows-staging")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var artifact = try ArtifactOutput.write(
            bytes, to: staging.appendingPathComponent(MappedFlows.fileName), compress: config.compress, runner: runner,
            formatVersion: ArtifactKind.flows.currentFormatVersion, payloadRevision: FlowsFormat.payloadRevision,
            dataVersion: dataVersion, builtAgainst: [:], seconds: &seconds
        )
        let fileManager = FileManager.default
        let xzTarget = config.artifactFile.appendingPathExtension("xz")
        if let xzPath = artifact.xzPath {
            if fileManager.fileExists(atPath: xzTarget.path) { try fileManager.removeItem(at: xzTarget) }
            try fileManager.moveItem(at: URL(fileURLWithPath: xzPath), to: xzTarget)
            artifact.xzPath = xzTarget.path
        } else if fileManager.fileExists(atPath: xzTarget.path) {
            try fileManager.removeItem(at: xzTarget) // a stale blob must not outlive its file
        }
        if fileManager.fileExists(atPath: config.artifactFile.path) { try fileManager.removeItem(at: config.artifactFile) }
        try fileManager.moveItem(at: URL(fileURLWithPath: artifact.path), to: config.artifactFile)
        artifact.path = config.artifactFile.path
        report.artifact = artifact
        let openStart = Date()
        let reopened = try MappedFlows(contentsOf: config.artifactFile)
        report.readerOpenMilliseconds = Date().timeIntervalSince(openStart) * 1000
        report.dataVersion = dataVersion
        log("flows: \(reopened.count) keys, \(artifact.rawBytes) bytes raw, \(artifact.xzBytes ?? 0) bytes xz")
        return finish(.built)
    }
}

/// The flows gate: every rule must hold for `flows.bin` to be replaced.
public enum FlowsGate {
    /// Unmatched trip ends ÷ non-empty, non-depot trip ends, per side and per system, in the
    /// window's newest month: below this. The newest month is where the join has to be right (its
    /// stations are today's GBFS). Earlier months also hold trips at stations GBFS has dropped
    /// since (JC, June 2026: 3.8%, almost all at HB106, removed in July), which is no join
    /// failure; their shares are reported, not gated.
    public static let unmatchedLimit = 0.02
    /// A month also in the baseline keeps at least this share of its rows (a re-published file
    /// that lost rows fails).
    public static let sameMonthRowsLimit = 0.9
    /// A new month has at least this share of the baseline's newest month (per system): the
    /// monthly swing is under ±40% on 2024–2026 data, a truncated file is not.
    public static let newMonthRowsLimit = 0.5

    public static func evaluate(_ report: FlowsReport, baseline: [String: [String: Int]]?) -> FlowsReport.Gate {
        var gate = FlowsReport.Gate()
        gate.unmatchedLimit = unmatchedLimit
        for summary in report.systems {
            for (side, stats) in [("start", summary.newestMonthStart), ("end", summary.newestMonthEnd)] where stats.unmatchedShare >= unmatchedLimit {
                gate.failures.append(String(format: "%@ %@ %@ ids: %.3f%% unmatched (limit %.1f%%)", summary.system.rawValue,
                                            summary.newestMonth.yyyymm, side, 100 * stats.unmatchedShare, 100 * unmatchedLimit))
            }
        }
        if !report.daily.emptyDays.isEmpty {
            gate.failures.append("window days without a counted departure or arrival: \(report.daily.emptyDays.map(\.description).joined(separator: ", "))")
        }
        if report.saturatedCounters > 0 { gate.failures.append("\(report.saturatedCounters) counter increments saturated at 65,535") }
        if let baseline {
            for (system, months) in report.monthRows.sorted(by: { $0.key < $1.key }) {
                let previous = baseline[system] ?? [:]
                guard let newestPrevious = previous.keys.max() else { continue }
                for (month, rows) in months.sorted(by: { $0.key < $1.key }) {
                    if let before = previous[month] {
                        gate.checkedMonths.append("\(system) \(month): \(rows) rows, \(before) before")
                        if Double(rows) < sameMonthRowsLimit * Double(before) {
                            gate.failures.append("\(system) \(month): \(rows) rows, \(before) in the previous build (limit \(Int(100 * sameMonthRowsLimit))%)")
                        }
                    } else if let reference = previous[newestPrevious] {
                        gate.checkedMonths.append("\(system) \(month): \(rows) rows, \(reference) in \(newestPrevious)")
                        if Double(rows) < newMonthRowsLimit * Double(reference) {
                            gate.failures.append("\(system) \(month): \(rows) rows, under \(Int(100 * newMonthRowsLimit))% of \(newestPrevious) (\(reference))")
                        }
                    }
                }
            }
        } else {
            gate.checkedMonths.append("no baseline (first build, or no previous report): month row counts not compared")
        }
        gate.passed = gate.failures.isEmpty
        return gate
    }
}

/// `reports/flows.json`.
public struct FlowsReport: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case built
        case gateFailed = "gate-failed"
        /// Fail-soft: no new month, or offline without the inputs. `flows.bin` was not touched.
        case keptPrevious = "kept-previous"
    }

    public struct IDCount: Codable, Sendable, Equatable {
        public var id: String
        public var count: Int
    }

    /// One side of one system, with the shares the gate reads.
    public struct Side: Codable, Sendable, Equatable {
        public var stats: TripEndStats
        public var joinable: Int
        public var unmatchedShare: Double
        public var repairedShare: Double
        /// The most frequent unmatched ids (up to 12).
        public var topUnmatched: [IDCount]
    }

    /// One system over the whole window, and in its newest month (what the unmatched gate reads).
    public struct System: Codable, Sendable, Equatable {
        public var system: TripSystem
        public var rows: Int
        public var classicRows: Int
        public var ebikeRows: Int
        public var unknownRideableTypes: [String: Int]
        public var startSide: Side
        public var endSide: Side
        public var newestMonth: TripMonth
        public var newestMonthStartSide: Side
        public var newestMonthEndSide: Side
        /// Unmatched shares per month, `[start, end]`.
        public var monthlyUnmatchedShares: [String: [Double]]
        public var newestMonthStart: TripEndStats { newestMonthStartSide.stats }
        public var newestMonthEnd: TripEndStats { newestMonthEndSide.stats }
    }

    public struct GBFS: Codable, Sendable, Equatable {
        public var version: String
        public var feedStations: Int
        public var feedEntriesDropped: Int
        public var keys: Int
        public var capacityZero: Int
        public var droppedTestRegion: Int
        public var droppedNoShortName: Int
        public var droppedDuplicateStationID: Int
    }

    public struct Depots: Codable, Sendable, Equatable {
        public var exact: [String] = []
        public var prefixes: [String] = []
    }

    public struct Daily: Codable, Sendable, Equatable {
        public var minDepartures = 0
        public var minArrivals = 0
        public var maxDepartures = 0
        /// Window days with no counted departure or no counted arrival.
        public var emptyDays: [ServiceDate] = []
        public var departures: [Int] = []
        public var arrivals: [Int] = []
    }

    public struct Gate: Codable, Sendable, Equatable {
        public var passed = false
        public var failures: [String] = []
        public var unmatchedLimit = FlowsGate.unmatchedLimit
        public var checkedMonths: [String] = []
    }

    public var generatedAt = SourceRecord.isoFormatter.string(from: Date())
    public var tool: String
    public var outcome = Outcome.gateFailed
    public var reason: String?
    public var listingFetchedAt: String?
    public var previousDataVersion: String?
    public var dataVersion: String?
    public var months: [TripMonth] = []
    public var window: FlowWindow?
    /// Weekend-profile holidays inside the window (the file's `holidays` section).
    public var holidays: [ServiceDate] = []
    public var tripFiles: [TripSourceFile] = []
    public var sources: [SourceRecord] = []
    public var gbfs: GBFS?
    public var depots = Depots()
    public var parameters: FlowSmoothingParameters?
    public var files: [TripFileStats] = []
    public var systems: [System] = []
    /// Data rows per system and month (`YYYYMM`), for the next build's month comparison.
    public var monthRows: [String: [String: Int]] = [:]
    /// The row counts this build was compared against: the last passing build's.
    public var baselineMonthRows: [String: [String: Int]]?
    public var daily = Daily()
    public var saturatedCounters = 0
    public var smoothing: FlowSmoothing.Stats?
    public var gate = Gate()
    public var artifact: BuiltArtifactInfo?
    public var readerOpenMilliseconds: Double?
    public var seconds: [String: Double] = [:]
    public var peakRSSBytes = 0

    public init(tool: String) {
        self.tool = tool
    }

    /// What the next build compares its months against: this build's rows if it passed, else the
    /// baseline it was itself compared against (so a failed build never becomes the reference).
    public var baselineForNext: [String: [String: Int]]? {
        outcome == .built ? monthRows : baselineMonthRows
    }

    mutating func record(files: [TripFileStats], tallies: FlowTallies, saturated: Int, smoothing: FlowSmoothing.Stats) {
        self.files = files
        saturatedCounters = saturated
        self.smoothing = smoothing
        monthRows = [:]
        for file in files { monthRows[file.system.rawValue, default: [:]][file.month.yyyymm, default: 0] += file.rows }
        func side(_ stats: TripEndStats, _ ids: [String: Int]) -> Side {
            let top = ids.map { IDCount(id: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
            return Side(stats: stats, joinable: stats.joinable, unmatchedShare: stats.unmatchedShare, repairedShare: stats.repairedShare,
                        topUnmatched: Array(top.prefix(12)))
        }
        systems = TripSystem.allCases.sorted().compactMap { system in
            let mine = files.filter { $0.system == system }
            guard var total = mine.first, let newest = mine.map(\.month).max() else { return nil }
            for file in mine.dropFirst() { total.add(file) }
            var latest = TripFileStats(system: system, month: newest, location: "")
            var monthly: [String: [Double]] = [:]
            for file in mine {
                if file.month == newest { latest.add(file) }
                monthly[file.month.yyyymm] = [file.start.unmatchedShare, file.end.unmatchedShare]
            }
            return System(system: system, rows: total.rows, classicRows: total.classicRows, ebikeRows: total.ebikeRows,
                          unknownRideableTypes: total.unknownRideableTypes,
                          startSide: side(total.start, total.unmatchedStartIDs), endSide: side(total.end, total.unmatchedEndIDs),
                          newestMonth: newest,
                          newestMonthStartSide: side(latest.start, latest.unmatchedStartIDs), newestMonthEndSide: side(latest.end, latest.unmatchedEndIDs),
                          monthlyUnmatchedShares: monthly)
        }
        var daily = Daily()
        daily.departures = tallies.daily[0]
        daily.arrivals = tallies.daily[1]
        daily.minDepartures = tallies.daily[0].min() ?? 0
        daily.minArrivals = tallies.daily[1].min() ?? 0
        daily.maxDepartures = tallies.daily[0].max() ?? 0
        daily.emptyDays = (0..<tallies.window.dayCount).filter { tallies.daily[0][$0] == 0 || tallies.daily[1][$0] == 0 }
            .map { tallies.window.start.adding(days: $0) }
        self.daily = daily
    }
}
