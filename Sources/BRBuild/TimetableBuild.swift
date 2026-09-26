import BRCore
import BRData
import BRTimetable
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Builds the `tt-*` artifacts: fetch (unless offline), parse, compile, write raw and `.xz`,
/// re-open with the reader, and report.
public struct TimetableBuild: Sendable {
    public var sourcesDirectory: URL
    public var outputDirectory: URL
    /// Report JSON; entries for systems not built this run are kept.
    public var reportURL: URL?
    public var systems: [TransitSystem]
    public var offline: Bool
    public var windowStart: ServiceDate
    /// The day whose trips and stop events are reported: the first Thursday after `today`
    /// that every system built covers (per system if none is common).
    public var today: ServiceDate
    public var compress: Bool
    public var runner: any ToolRunner
    /// Feeds per system; defaults to ``NYCFeeds``.
    public var feeds: [TransitSystem: [GTFSFeedSpec]]

    public init(sourcesDirectory: URL, outputDirectory: URL, reportURL: URL?, systems: [TransitSystem] = TransitSystem.allCases,
                offline: Bool, today: ServiceDate, compress: Bool = true, runner: any ToolRunner) {
        self.sourcesDirectory = sourcesDirectory
        self.outputDirectory = outputDirectory
        self.reportURL = reportURL
        self.systems = systems
        self.offline = offline
        self.today = today
        self.windowStart = today.adding(days: -1)
        self.compress = compress
        self.runner = runner
        self.feeds = Dictionary(grouping: NYCFeeds.all, by: \.system)
    }

    public var gtfsDirectory: URL { sourcesDirectory.appendingPathComponent("gtfs") }
    /// The data.ny.gov subway entrances CSV, cached beside the other NYC open-data sources.
    public var entrancesFile: URL { sourcesDirectory.appendingPathComponent("nyc").appendingPathComponent(SubwayEntrances.fileName) }

    public static func artifactFileName(_ system: TransitSystem) -> String {
        "\(ArtifactKind.timetable(for: system).name).bin"
    }

    /// Runs the build and returns the report (also written to ``reportURL``).
    @discardableResult
    public func run(log: (String) -> Void = { _ in }) throws -> TimetableBuildReport {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fetcher = GTFSFetcher(runner: runner, directory: gtfsDirectory)
        var report = reportURL.flatMap { try? JSONDecoder().decode(TimetableBuildReport.self, from: Data(contentsOf: $0)) }
            ?? TimetableBuildReport()
        report.generatedAt = ISO8601DateFormatter().string(from: Date())
        report.tool = "bikeride-data \(BuildInfo.toolVersion) (Swift \(BuildInfo.swiftVersion))"
        report.windowStart = windowStart.yyyymmdd
        report.today = today.yyyymmdd

        var built: [(TransitSystem, Timetable, TimetableSystemReport)] = []
        for system in systems {
            let totalStart = Date()
            let specs = feeds[system] ?? []
            if !offline {
                for spec in specs {
                    let fetched = try fetcher.fetch(spec)
                    log("  fetch \(spec.name): \(fetched.notModified ? "not modified" : "downloaded \(fetched.bytes) bytes")")
                }
            }
            var warnings: [String] = []
            var entrances: (list: [SubwayEntrance], report: TimetableSystemReport.AuxiliarySource)?
            if system == .subway {
                entrances = loadEntrances(warnings: &warnings, log: log)
            }
            let parseStart = Date()
            let parsed = try parseFeeds(specs, fetcher: fetcher)
            let parseSeconds = Date().timeIntervalSince(parseStart)
            log("  \(system): parsed \(parsed.count) feeds in \(String(format: "%.1f", parseSeconds)) s")

            let compileStart = Date()
            let (data, stats) = try GTFSTimetableCompiler.compile(
                system: system, feeds: parsed, entrances: entrances?.list ?? [], options: GTFSCompileOptions(windowStart: windowStart))
            let compileSeconds = Date().timeIntervalSince(compileStart)

            let writeStart = Date()
            let rawURL = outputDirectory.appendingPathComponent(Self.artifactFileName(system))
            let dataVersion = (parsed.map { "\($0.source.name)@\($0.source.etag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))" }
                + (entrances.map { ["subway-entrances@\($0.report.version)"] } ?? [])
                + ["from=\(windowStart.yyyymmdd)"]).joined(separator: ";")
            let bytes = try data.artifactBytes(dataVersion: dataVersion)
            try Self.writeAtomically(bytes, to: rawURL)
            let writeSeconds = Date().timeIntervalSince(writeStart)
            let rawSha = try Self.sha256(of: rawURL, runner: runner)

            var artifact = TimetableSystemReport.Artifact(file: rawURL.lastPathComponent, rawBytes: bytes.count, rawSha256: rawSha)
            var compressSeconds = 0.0
            if compress {
                let compressStart = Date()
                let xzURL = rawURL.appendingPathExtension("xz")
                try XZ.compress(rawURL, to: xzURL, runner: runner)
                compressSeconds = Date().timeIntervalSince(compressStart)
                artifact.xzFile = xzURL.lastPathComponent
                artifact.xzBytes = (try FileManager.default.attributesOfItem(atPath: xzURL.path)[.size] as? Int) ?? 0
                let listing = try XZ.list(xzURL, runner: runner)
                artifact.xzStreams = listing.streams
                artifact.xzBlocks = listing.blocks
            }

            let openStart = Date()
            let timetable = try Timetable(contentsOf: rawURL)
            let openMillis = Date().timeIntervalSince(openStart) * 1000

            var systemReport = TimetableSystemReport(stats: stats, artifact: artifact)
            systemReport.warnings = warnings
            systemReport.entrancesSource = entrances?.report
            systemReport.sectionBytes = Dictionary(uniqueKeysWithValues: timetable.sectionByteCounts.map { ("\($0.key)", $0.value) })
            systemReport.seconds = .init(parse: parseSeconds, compile: compileSeconds, write: writeSeconds,
                                         compress: compressSeconds, total: Date().timeIntervalSince(totalStart))
            systemReport.readerOpenMillis = openMillis
            systemReport.peakRSSBytesSoFar = Self.peakRSSBytes()
            systemReport.tripCountsByDate = timetable.coveredDates.prefix(14).map { date in
                let view = timetable.dayView(for: date)
                return .init(date: date.yyyymmdd, weekday: "\(date.weekday)", trips: view.activeTripCount, stopEvents: view.stopEventCount)
            }
            log("  \(system): \(stats.trips) trips, \(stats.patternsAfterFIFO) patterns, \(bytes.count) bytes raw"
                + (artifact.xzBytes.map { ", \($0) bytes xz" } ?? "")
                + String(format: " in %.1f s", systemReport.seconds.total))
            built.append((system, timetable, systemReport))
        }

        // Representative weekday: the first Thursday after today that every built system covers.
        let candidates = (1...60).map { today.adding(days: $0) }.filter { $0.weekday == .thursday }
        let common = candidates.first { date in built.allSatisfy { $0.1.covers(date) } }
        var totals = TimetableSystemReport.Day(date: common?.yyyymmdd ?? "", weekday: common.map { "\($0.weekday)" } ?? "",
                                               trips: 0, stopEvents: 0, patternsWithService: 0, dayViewBuildMillis: 0)
        for (system, builtTimetable, var systemReport) in built {
            if let date = common ?? candidates.first(where: { builtTimetable.covers($0) }) {
                // A fresh mapping, so the day view is built (not served from the cache) and timed.
                let timetable = try Timetable(contentsOf: outputDirectory.appendingPathComponent(Self.artifactFileName(system)))
                let started = Date()
                let view = timetable.dayView(for: date)
                let millis = Date().timeIntervalSince(started) * 1000
                var patterns = 0
                for pattern in 0..<timetable.patternCount where view.activeTripCount(inPattern: pattern) > 0 { patterns += 1 }
                let day = TimetableSystemReport.Day(
                    date: date.yyyymmdd, weekday: "\(date.weekday)", trips: view.activeTripCount,
                    stopEvents: view.stopEventCount, patternsWithService: patterns, dayViewBuildMillis: millis)
                systemReport.representativeDay = day
                if common != nil {
                    totals.trips += day.trips
                    totals.stopEvents += day.stopEvents
                    totals.patternsWithService? += patterns
                    totals.dayViewBuildMillis? += millis
                }
            }
            report.systems[ArtifactKind.timetable(for: system).name] = systemReport
        }
        report.representativeDayTotals = common != nil && built.count == TransitSystem.allCases.count ? totals : nil
        report.peakRSSBytes = Self.peakRSSBytes()
        if let reportURL {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        }
        return report
    }

    /// The subway entrances: refreshed unless offline; on failure the cached file is used, and
    /// without one the subway is built without entrances (with a warning).
    func loadEntrances(warnings: inout [String], log: (String) -> Void)
        -> (list: [SubwayEntrance], report: TimetableSystemReport.AuxiliarySource)?
    {
        var status = "cached"
        var version = ""
        do {
            let record = try SourceFetcher(runner: runner, offline: offline).fetch(SubwayEntrances.url, to: entrancesFile)
            status = record.status
            version = record.versionTag
            log("  fetch \(SubwayEntrances.fileName): \(record.status)")
        } catch {
            guard FileManager.default.fileExists(atPath: entrancesFile.path) else {
                warnings.append("subway entrances unavailable (\(error)); built without entrances")
                log("  warning: \(warnings.last!)")
                return nil
            }
            warnings.append("subway entrances not refreshed (\(error)); using the cached file")
            log("  warning: \(warnings.last!)")
        }
        do {
            let parsed = try SubwayEntrances.parse(fileAt: entrancesFile)
            if version.isEmpty {
                let date = (try? FileManager.default.attributesOfItem(atPath: entrancesFile.path)[.modificationDate]) as? Date
                version = date.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
            }
            return (parsed.entrances, .init(file: entrancesFile.path, url: SubwayEntrances.url, status: status, version: version,
                                            rows: parsed.entrances.count, issues: parsed.issues))
        } catch {
            warnings.append("subway entrances unreadable (\(error)); built without entrances")
            log("  warning: \(warnings.last!)")
            return nil
        }
    }

    /// Parses a system's feeds in parallel. Missing zips are an error.
    func parseFeeds(_ specs: [GTFSFeedSpec], fetcher: GTFSFetcher) throws -> [GTFSFeed] {
        for spec in specs where !FileManager.default.fileExists(atPath: fetcher.archiveURL(for: spec).path) {
            throw GTFSError.missingFile(feed: fetcher.archiveURL(for: spec).path, file: "(zip)")
        }
        let results = ParallelResults<GTFSFeed>(count: specs.count)
        let runner = self.runner
        DispatchQueue.concurrentPerform(iterations: specs.count) { index in
            let spec = specs[index]
            results.set(index, Result {
                try GTFSFeed.parse(try ZipGTFSFeed(archive: fetcher.archiveURL(for: spec), runner: runner), source: fetcher.sourceInfo(for: spec))
            })
        }
        return try results.values()
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    static func sha256(of url: URL, runner: any ToolRunner) throws -> String {
        #if canImport(CryptoKit)
        return try CryptoKitHasher().sha256(ofFileAt: url).hex
        #else
        return try ProcessHasher(runner: runner).sha256(ofFileAt: url).hex
        #endif
    }

    /// Peak resident set size of this process so far, in bytes.
    public static func peakRSSBytes() -> Int { ResourceUsage.peakResidentBytes() }
}

/// Collects one result per index from concurrent workers.
final class ParallelResults<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Result<Value, any Error>?]

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ result: Result<Value, any Error>) {
        lock.lock()
        slots[index] = result
        lock.unlock()
    }

    func values() throws -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return try slots.map { try $0!.get() }
    }
}

/// `xz` through a ``ToolRunner``: one stream, one block, CRC32, single-threaded (deterministic).
public enum XZ {
    public static func compress(_ source: URL, to destination: URL, runner: any ToolRunner) throws {
        let partial = destination.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let output = try FileHandle(forWritingTo: partial)
        do {
            let tool = try runner.stream(executable: "xz", args: ["-6", "-T1", "--check=crc32", "-c", "--", source.path])
            while let chunk = try tool.output.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try tool.waitUntilExit()
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    /// Stream and block counts from `xz --robot --list`.
    public static func list(_ file: URL, runner: any ToolRunner) throws -> (streams: Int, blocks: Int) {
        let text = String(decoding: try runner.run(executable: "xz", args: ["--robot", "--list", "--", file.path]), as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.first == "totals", fields.count > 2, let streams = Int(fields[1]), let blocks = Int(fields[2]) {
                return (streams, blocks)
            }
        }
        return (0, 0)
    }
}

// MARK: - Report

public struct TimetableBuildReport: Codable, Sendable {
    public var generatedAt = ""
    public var tool = ""
    public var today = ""
    public var windowStart = ""
    public var peakRSSBytes = 0
    /// Keyed by artifact name (`tt-subway`, …).
    public var systems: [String: TimetableSystemReport] = [:]
    /// Sums over all four systems on their common representative day (only when all four were
    /// built in this run and share one).
    public var representativeDayTotals: TimetableSystemReport.Day?

    public init() {}
}

public struct TimetableSystemReport: Codable, Sendable {
    public struct Artifact: Codable, Sendable {
        public var file: String
        public var rawBytes: Int
        public var rawSha256: String
        public var xzFile: String?
        public var xzBytes: Int?
        public var xzStreams: Int?
        public var xzBlocks: Int?
    }

    public struct Seconds: Codable, Sendable {
        public var parse = 0.0
        public var compile = 0.0
        public var write = 0.0
        public var compress = 0.0
        public var total = 0.0
    }

    public struct Day: Codable, Sendable {
        public var date: String
        public var weekday: String
        public var trips: Int
        public var stopEvents: Int
        public var patternsWithService: Int?
        public var dayViewBuildMillis: Double?
    }

    /// A non-GTFS input, e.g. the subway entrances CSV.
    public struct AuxiliarySource: Codable, Sendable {
        public var file: String
        public var url: String
        /// `downloaded`, `not-modified`, `offline` or `cached` (refresh failed).
        public var status: String
        public var version: String
        public var rows: Int
        public var issues: [String: Int]
    }

    public var stats: GTFSSystemStats
    public var artifact: Artifact
    public var warnings: [String] = []
    public var entrancesSource: AuxiliarySource?
    /// Bytes per payload section, keyed by section name.
    public var sectionBytes: [String: Int] = [:]
    public var seconds = Seconds()
    /// Process peak RSS after this system was built (cumulative within one run; build one
    /// system per run for an isolated figure).
    public var peakRSSBytesSoFar = 0
    public var readerOpenMillis = 0.0
    public var representativeDay: Day?
    /// Active trips and stop events for the first covered dates.
    public var tripCountsByDate: [Day] = []
}
