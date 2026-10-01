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
    /// PATH parent-station and platform-transfer synthesis.
    public var pathStations = PATHStationOptions()
    /// `--strict-sources`: a source the build would otherwise go without is an error instead of a
    /// warning. Today that is the subway entrances: with neither a fresh download nor a readable
    /// cached file, the subway is not built rather than built without entrances. CI passes it,
    /// because a fresh runner has no cache unless the restore step put the last good copy there.
    public var strictSources = false
    /// The fewest service days an archived copy must have left, counting the build day, for a feed
    /// whose download failed to be built from it (``archivedCopy(of:fetcher:reasons:)``): its
    /// calendar must run to at least the build day plus this minus one. 3 is the gate's
    /// `coverage.minDays` (Failure policy 4): a copy with less left would only publish a system
    /// the gate marks `noSchedule`, where failing the run keeps the live set. When a copy was
    /// first archived says nothing about whether it is still current (a feed that has not changed
    /// keeps its first date), so it is not a limit.
    public var minArchivedCopyDaysLeft = 3
    /// The version of each feed the live set was built from: feed name to the ETag of its source
    /// named after the feed (not an archived `<feed>@<key8>`) in `--previous`'s manifest
    /// (``liveSources(of:)``). An archived copy older than that version is not used, so a fallback
    /// never publishes a schedule older than the one already live. Nil when there is no previous
    /// set, and a feed it does not name is not compared.
    public var liveSources: [String: String]?

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
        var report = TimetableBuildReport()
        if let reportURL, FileManager.default.fileExists(atPath: reportURL.path) {
            do {
                report = try TimetableBuildReport.decodePrevious(Data(contentsOf: reportURL))
            } catch {
                log("  warning: previous report \(reportURL.path) unreadable (\(error)); it keeps only this run's systems")
            }
        }
        report.generatedAt = ISO8601DateFormatter().string(from: Date())
        report.tool = "bikeride-data \(BuildInfo.toolVersion) (Swift \(BuildInfo.swiftVersion))"
        report.windowStart = windowStart.yyyymmdd
        report.today = today.yyyymmdd

        var built: [(TransitSystem, Timetable, TimetableSystemReport)] = []
        for system in systems {
            let totalStart = Date()
            var warnings: [String] = []
            var archivedCopies: [String: ArchivedCopy] = [:]
            let specs = try selectSources(feeds[system] ?? [], fetcher: fetcher, archivedCopies: &archivedCopies,
                                          warnings: &warnings, log: log)
            var entrances: (list: [SubwayEntrance], report: TimetableSystemReport.AuxiliarySource)?
            if system == .subway {
                entrances = loadEntrances(warnings: &warnings, log: log)
                if entrances == nil, strictSources {
                    throw SourceError.builtWithoutEntrances(warnings.last ?? "subway entrances unavailable")
                }
            }
            let versions = try sourceVersions(specs, fetcher: fetcher, archivedCopies: archivedCopies, log: log)
            let parseStart = Date()
            let parsed = try parseFeeds(versions)
            let parseSeconds = Date().timeIntervalSince(parseStart)
            log("  \(system): parsed \(parsed.count) feeds in \(String(format: "%.1f", parseSeconds)) s")

            let compileStart = Date()
            var (data, stats) = try GTFSTimetableCompiler.compile(
                system: system, feeds: parsed, entrances: entrances?.list ?? [],
                options: GTFSCompileOptions(windowStart: windowStart, pathStations: pathStations))
            // A feed built from its archived copy says so in its row of the source table.
            for index in stats.sources.indices {
                guard let copy = archivedCopies[stats.sources[index].name] else { continue }
                stats.sources[index].status = "cached"
                stats.sources[index].archivedAt = copy.record.archivedAt
                stats.sources[index].archiveKey = copy.record.key
            }
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
                let listing = try XZCheck.verify(xzURL, runner: runner)
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
            systemReport.tripCountsByDate = timetable.coveredDates.map { date in
                let view = timetable.dayView(for: date)
                return .init(date: date.yyyymmdd, weekday: "\(date.weekday)", trips: view.activeTripCount, stopEvents: view.stopEventCount)
            }
            log("  \(system): \(stats.trips) trips, \(stats.patternsAfterFIFO) patterns, \(bytes.count) bytes raw"
                + (artifact.xzBytes.map { ", \($0) bytes xz" } ?? "")
                + String(format: ", stops ≤ %.0f m from their shape vertex in %.1f s", stats.maxStopToShapeVertexMeters,
                         systemReport.seconds.total))
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

    /// Why a build stopped for want of a source.
    public enum SourceError: Error, Equatable, CustomStringConvertible {
        /// The subway entrances could neither be downloaded nor read from the cached file
        /// (``strictSources`` only).
        case builtWithoutEntrances(String)
        /// A feed with no fallback spec failed to download and had no archived copy to use:
        /// the download error, then why each archived copy (if any) was refused.
        case noArchivedCopy(feed: String, download: String, reasons: [String])

        public var description: String {
            switch self {
            case .builtWithoutEntrances(let why): "\(why) (--strict-sources: the subway is not built without entrances)"
            case .noArchivedCopy(let feed, let download, let reasons):
                "\(feed) not refreshed (\(download)), and no archived copy to build from: \(reasons.joined(separator: "; "))"
            }
        }
    }

    /// The archived copy a feed is built from when its download failed, and the other archived
    /// versions it was preferred over because they were refused (too little service left, or not
    /// matching their record): those are not passed to the compiler either.
    struct ArchivedCopy {
        var record: GTFSSourceArchive.Record
        var refusedKeys: Set<String>
    }

    /// Why a downloaded subway entrances file was refused.
    struct EntrancesUnusable: Error, CustomStringConvertible {
        var description: String { "no usable rows" }
    }

    /// The subway entrances: refreshed unless offline; when the download fails, or answers 200 with
    /// a body that has no usable rows (checked before it replaces the file, so a bad answer never
    /// overwrites the last good copy), the cached file is used, and without one the subway is built
    /// without entrances (with a warning; ``strictSources`` makes that an error).
    func loadEntrances(warnings: inout [String], log: (String) -> Void)
        -> (list: [SubwayEntrance], report: TimetableSystemReport.AuxiliarySource)?
    {
        var status = "cached"
        var version = ""
        do {
            let record = try SourceFetcher(runner: runner, offline: offline).fetch(SubwayEntrances.url, to: entrancesFile) {
                guard try !SubwayEntrances.parse(fileAt: $0).entrances.isEmpty else { throw EntrancesUnusable() }
            }
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
            guard !parsed.entrances.isEmpty else {
                // An empty or truncated file is no better than none.
                warnings.append("subway entrances file \(entrancesFile.lastPathComponent) has no usable rows; built without entrances")
                log("  warning: \(warnings.last!)")
                return nil
            }
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

    /// The feeds to parse for one system, refreshing them unless offline. A fallback feed
    /// (``GTFSFeedSpec/isFallback``) is fetched and used only when a primary of its slot fails to
    /// download or has no local zip; a failed primary with a cached zip is still used, and per-date
    /// selection prefers it wherever it covers. Without a fallback spec, a failed download falls
    /// back to the feed's last good archived copy (``archivedCopy(of:fetcher:reasons:)``), noted in
    /// `archivedCopies` and built from in place of the current zip; with none, it is an error.
    func selectSources(_ all: [GTFSFeedSpec], fetcher: GTFSFetcher, archivedCopies: inout [String: ArchivedCopy],
                       warnings: inout [String], log: (String) -> Void) throws -> [GTFSFeedSpec] {
        func exists(_ spec: GTFSFeedSpec) -> Bool { FileManager.default.fileExists(atPath: fetcher.archiveURL(for: spec).path) }
        let fallbackSlots = Set(all.filter(\.isFallback).map(\.slot))
        var failedSlots = Set<String>()
        var specs: [GTFSFeedSpec] = []
        func warn(_ message: String) {
            warnings.append(message)
            log("  warning: \(message)")
        }
        for spec in all where !spec.isFallback {
            if !offline {
                do {
                    let fetched = try fetcher.fetch(spec, warn: warn)
                    log("  fetch \(spec.name): \(fetched.notModified ? "not modified" : "downloaded \(fetched.bytes) bytes")")
                } catch {
                    guard fallbackSlots.contains(spec.slot) else {
                        var reasons: [String] = []
                        guard let copy = archivedCopy(of: spec, fetcher: fetcher, reasons: &reasons) else {
                            throw SourceError.noArchivedCopy(feed: spec.name, download: "\(error)", reasons: reasons)
                        }
                        archivedCopies[spec.name] = copy
                        // Without a live version to compare with, the copy could be older than the live set's.
                        let uncompared = liveSources == nil ? "; no previous set to compare it with"
                            : liveSources?[spec.name] == nil ? "; the previous set has no \(spec.name) to compare it with" : ""
                        warn("\(spec.name) not refreshed (\(error)); using the archived copy \(copy.record.key), first archived \(copy.record.archivedAt)"
                            + uncompared + (reasons.isEmpty ? "" : " (\(reasons.joined(separator: "; ")))"))
                        specs.append(spec)
                        continue
                    }
                    failedSlots.insert(spec.slot)
                    warnings.append("\(spec.name) not refreshed (\(error))" + (exists(spec) ? "; using the cached zip and the fallback" : "; using the fallback"))
                    log("  warning: \(warnings.last!)")
                }
            }
            if fallbackSlots.contains(spec.slot), !exists(spec) {
                failedSlots.insert(spec.slot)
                continue
            }
            specs.append(spec)
        }
        for spec in all where spec.isFallback && failedSlots.contains(spec.slot) {
            if !offline {
                do {
                    let fetched = try fetcher.fetch(spec, warn: warn)
                    log("  fetch \(spec.name) (fallback): \(fetched.notModified ? "not modified" : "downloaded \(fetched.bytes) bytes")")
                } catch {
                    warnings.append("fallback \(spec.name) not refreshed (\(error))")
                    log("  warning: \(warnings.last!)")
                }
            }
            if exists(spec) { specs.append(spec) }
        }
        if specs.isEmpty, let first = all.first {
            throw GTFSError.missingFile(feed: fetcher.archiveURL(for: first).path, file: "(zip)")
        }
        return specs
    }

    /// The last good archived copy of `spec` (``GTFSSourceArchive``; in CI, what restore-state.sh
    /// put there from R2's `sources/`), for when its download failed: the newest version by
    /// Last-Modified (the compiler's order) that is not older than the version the live set was
    /// built from (``liveSources``), whose calendar runs at least ``minArchivedCopyDaysLeft`` days
    /// from the build day, whose zip has its record's size and SHA-256, and whose calendar reads.
    /// Each version refused on the way is named in `reasons`; nil when none is left. When the
    /// live set names a version the archive does not hold (its upload failed, say), no copy can
    /// be placed against it and none is used: the run fails as it did before the fallback.
    func archivedCopy(of spec: GTFSFeedSpec, fetcher: GTFSFetcher, reasons: inout [String]) -> ArchivedCopy? {
        guard let archive = fetcher.archive else {
            reasons.append("the build keeps no archive")
            return nil
        }
        let records: [GTFSSourceArchive.Record]
        do {
            records = try archive.records(feed: spec.name)
        } catch {
            reasons.append("the archive does not read (\(error))")
            return nil
        }
        guard !records.isEmpty else {
            reasons.append("the archive holds no copy of \(spec.name)")
            return nil
        }
        // Newest first, as the compiler ranks versions of one feed; then the later archived.
        func newer(_ a: GTFSSourceArchive.Record, _ b: GTFSSourceArchive.Record) -> Bool {
            (a.publishedAt, a.archivedAt) > (b.publishedAt, b.archivedAt)
        }
        let ordered = records.sorted(by: newer)
        // The version the live set was built from: no copy older than it is used.
        var live: GTFSSourceArchive.Record?
        if let etag = liveSources?[spec.name] {
            guard !etag.isEmpty, let record = ordered.first(where: { $0.etag == etag }) else {
                reasons.append("the live set was built from \(spec.name) with ETag \(etag.isEmpty ? "(none)" : etag), which the archive "
                    + "does not hold, so a copy could be older than it")
                return nil
            }
            live = record
        }
        let lastDay = today.adding(days: max(minArchivedCopyDaysLeft, 1) - 1)
        var refused = Set<String>()
        for record in ordered {
            if let live, newer(live, record) {
                reasons.append("archived copies older than \(live.key), the version the live set was built from, are not used")
                break
            }
            func refuse(_ why: String) {
                reasons.append("archived copy \(record.key) \(why)")
                refused.insert(record.key)
            }
            guard let end = record.calendarEnd.flatMap(ServiceDate.init(yyyymmdd:)), end.daysSinceEpoch >= lastDay.daysSinceEpoch else {
                refuse("has service to \(record.calendarEnd ?? "(no calendar)"), under \(minArchivedCopyDaysLeft) days from \(today.yyyymmdd): not used")
                continue
            }
            let zip = archive.zipURL(feed: spec.name, key: record.key)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? -1
            guard bytes == record.bytes else {
                refuse("has \(bytes) bytes, its record \(record.bytes): not used")
                continue
            }
            guard let sha = try? Self.sha256(of: zip, runner: runner), sha == record.sha256 else {
                refuse("does not match its record's SHA-256: not used")
                continue
            }
            do {
                _ = try GTFSSourceArchive.coverage(of: ZipGTFSFeed(archive: zip, runner: runner))
            } catch {
                refuse("does not read as a GTFS zip (\(error)): not used")
                continue
            }
            return ArchivedCopy(record: record, refusedKeys: refused)
        }
        return nil
    }

    /// ``liveSources`` from the live set's manifest: per timetable, the source named after its
    /// feed is the version that timetable was built from as current (the others are archived
    /// versions, `<feed>@<key8>`, chosen only for dates the current one does not cover).
    public static func liveSources(of manifest: SetManifest) -> [String: String] {
        var sources: [String: String] = [:]
        for source in manifest.sources.values.joined() where source.name == source.feed {
            sources[source.feed] = source.etag
        }
        return sources
    }

    /// Every version of the selected feeds to parse: each feed's current zip, followed by the
    /// archived versions (``GTFSSourceArchive``) that differ from it and can still be selected on
    /// some date of the window, named `<feed>@<key8>` with the feed's slot and priority and
    /// `publishedAt` from their Last-Modified. The compiler then picks the newest covering
    /// version per date. Without archived versions this is exactly the selected feeds, as before.
    /// Online, archived versions that can no longer be selected are deleted; offline, the sources
    /// are only read.
    ///
    /// A feed in `archivedCopies` (its download failed) takes that archived copy as its current
    /// version, under the feed's own name with the copy's ETag and Last-Modified, so it builds the
    /// same bytes as when that version was downloaded; the sources tree is not changed for it.
    /// The versions refused in its place are left out, and not deleted.
    func sourceVersions(_ specs: [GTFSFeedSpec], fetcher: GTFSFetcher, archivedCopies: [String: ArchivedCopy] = [:],
                        log: (String) -> Void) throws -> [GTFSSourceVersion] {
        var versions: [GTFSSourceVersion] = []
        for spec in specs {
            let copy = archivedCopies[spec.name]
            var currentZip = fetcher.archiveURL(for: spec)
            var current = fetcher.sourceInfo(for: spec)
            if let copy, let archive = fetcher.archive {
                currentZip = archive.zipURL(feed: spec.name, key: copy.record.key)
                current = GTFSSourceInfo(name: spec.name, slot: spec.slot, priority: spec.priority,
                                         publishedAt: copy.record.publishedAt, etag: copy.record.etag)
            }
            versions.append(GTFSSourceVersion(spec: spec, zip: currentZip, source: current, archiveKey: copy?.record.key))
            guard let archive = fetcher.archive else { continue }
            let records = try archive.records(feed: spec.name).filter { !(copy?.refusedKeys.contains($0.key) ?? false) }
            guard !records.isEmpty else { continue }
            // The current zip is normally archived too; that copy is not a separate version.
            let currentSHA = try copy?.record.sha256 ?? Self.sha256(of: currentZip, runner: runner)
            let others = records.filter { $0.sha256 != currentSHA }
            guard !others.isEmpty else { continue }
            let currentCoverage = try GTFSSourceArchive.coverage(of: ZipGTFSFeed(archive: currentZip, runner: runner))
            let useful = GTFSSourceArchive.usefulVersions(
                current: .init(publishedAt: current.publishedAt, coverage: currentCoverage),
                archived: others.map { .init(publishedAt: $0.publishedAt, coverage: $0.coverageDays) },
                windowStart: Int32(windowStart.daysSinceEpoch))
            let chosen = useful.map { others[$0] }
            let shortKeys = chosen.map { String($0.key.prefix(8)) }
            let unique = Set(shortKeys).count == shortKeys.count
            for (record, short) in zip(chosen, shortKeys) {
                let name = "\(spec.name)@\(unique ? short : record.key)"
                versions.append(GTFSSourceVersion(
                    spec: spec, zip: archive.zipURL(feed: spec.name, key: record.key),
                    source: GTFSSourceInfo(name: name, slot: spec.slot, priority: spec.priority, publishedAt: record.publishedAt, etag: record.etag),
                    archiveKey: record.key))
                log("  \(spec.name): archived version \(record.key) (\(record.calendarStart ?? "?")–\(record.calendarEnd ?? "?")) is a candidate")
            }
            let dropped = others.indices.filter { !useful.contains($0) }.map { others[$0] }
            for record in dropped {
                if offline {
                    log("  \(spec.name): archived version \(record.key) is superseded on every date; not used")
                } else {
                    try archive.remove(record)
                    log("  \(spec.name): deleted archived version \(record.key), superseded on every date from \(windowStart.yyyymmdd)")
                }
            }
        }
        return versions
    }

    /// Parses a system's feed versions in parallel. Missing zips are an error.
    func parseFeeds(_ versions: [GTFSSourceVersion]) throws -> [GTFSFeed] {
        for version in versions where !FileManager.default.fileExists(atPath: version.zip.path) {
            throw GTFSError.missingFile(feed: version.zip.path, file: "(zip)")
        }
        let results = ParallelResults<GTFSFeed>(count: versions.count)
        let runner = self.runner
        DispatchQueue.concurrentPerform(iterations: versions.count) { index in
            let version = versions[index]
            results.set(index, Result {
                try GTFSFeed.parse(try ZipGTFSFeed(archive: version.zip, runner: runner), source: version.source)
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
/// ``XZCheck`` verifies the result.
public enum XZ {
    public static func compress(_ source: URL, to destination: URL, runner: any ToolRunner) throws {
        let partial = destination.appendingPathExtension("partial")
        _ = FileManager.default.createFile(atPath: partial.path, contents: nil)
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
    /// Sums over every system on their common representative day (only when all of them were
    /// built in this run and share one).
    public var representativeDayTotals: TimetableSystemReport.Day?

    public init() {}

    /// Decodes a report written by this or an earlier tool, so a run that builds some systems
    /// keeps the others' entries. Stats keys added since the file was written take their defaults
    /// (synthesized `Codable` would reject the whole report for one missing key).
    public static func decodePrevious(_ json: Data) throws -> TimetableBuildReport {
        guard var root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              var systems = root["systems"] as? [String: Any]
        else { return try JSONDecoder().decode(TimetableBuildReport.self, from: json) }
        let blank = GTFSSystemStats(system: "", timeZone: "", windowStart: "", dayCount: 0)
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(blank)) as? [String: Any] ?? [:]
        for (name, value) in systems {
            guard var entry = value as? [String: Any], let stats = entry["stats"] as? [String: Any] else { continue }
            entry["stats"] = defaults.merging(stats) { $1 }
            systems[name] = entry
        }
        root["systems"] = systems
        return try JSONDecoder().decode(TimetableBuildReport.self, from: JSONSerialization.data(withJSONObject: root))
    }
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
    /// Active trips and stop events on every covered date (the validation gate's trip-count input).
    public var tripCountsByDate: [Day] = []
}
