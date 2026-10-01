@testable import bikeride_data
@testable import BRBuild
import BRCore
import Foundation
import Testing

/// `bikeride-data all` itself, called in process with the arguments the M4 jobs pass: what reaches
/// the gate and the heartbeat through the command line. The steps the CLI can run on the
/// synthetic sources run for real (flows, gate, manifest, heartbeat); the CLI's streets and
/// timetables steps read the real feeds, so the artifacts they would build come from the library
/// pipeline (``SyntheticPipeline``) first.
///
/// The gate reads this repository's `Data/` (`all` has no `--repo-data`). Its street-share
/// thresholds name the five boroughs the synthetic lattice lacks, so these runs keep `streets.bin`
/// as the previous set has it and no streets report: the streets check is skipped as unchanged.
@Suite(.enabled(if: publishToolsInstalled, "needs xz and unzip on PATH"), .serialized)
struct AllCommandTests {
    /// Every artifact but flows: what a flows-only set carries forward.
    static let allButFlows = PipelineTests.artifacts.filter { $0 != "flows" }

    static func common(_ sources: SyntheticSources) -> [String] {
        ["--sources", sources.sources.path, "--trips", sources.trips.path, "--months", "202606-202608", "--offline", "--today", "20261006"]
    }

    static func copy(_ names: [String], from: URL, to: URL) throws {
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        for name in names { try FileManager.default.copyItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name)) }
    }

    /// flows.yml's run: a fresh output directory holding only the previous flows files and report
    /// (decision 2), every other kind carried from `--previous`. The gate passes with tripCounts
    /// and configReferences skipped and flows checked; the heartbeat names the flows job and keeps
    /// the last timetable success.
    @Test func aFlowsOnlyRunPassesTheGateAndCarriesEverythingElse() throws {
        let sources = try SyntheticSources()
        let first = try PipelineTests.published(sources)
        let previous = try first.keepAsPrevious("previous")
        let before = try SetManifest.load(previous)
        let beforeHeartbeat = try SetHeartbeat.load(previous.deletingLastPathComponent().appendingPathComponent(SetHeartbeat.fileName))
        let beforeCounts = try JSONDecoder().decode(TripCountSidecar.self,
                                                    from: Data(contentsOf: previous.deletingLastPathComponent().appendingPathComponent(TripCountSidecar.fileName)))

        let out = sources.root.appendingPathComponent("flows/data"), reports = sources.root.appendingPathComponent("flows/reports")
        try Self.copy(["flows.bin", "flows.bin.xz"], from: first.out, to: out)
        try Self.copy(["flows.json"], from: first.reports, to: reports)
        try sources.writeTrips(version: "v2")   // the trip files changed: flows has something new to build

        let status = runAllCommand(Self.common(sources) + [
            "--out", out.path, "--previous", previous.path, "--skip", "streets,timetables,stations,config,links",
            "--require-flows", "--job", "flows", "--now", "2026-10-06T11:00:00Z",
        ])
        #expect(status == 0)

        let gate = try GateReport.load(reports.appendingPathComponent(GateReport.fileName))
        #expect(gate.status == .pass && gate.previousSetId == before.setId && gate.acceptedTripCountChange == nil)
        #expect(gate.artifacts.keys.sorted() == ["flows"] && gate.carriedForward.sorted() == Self.allButFlows)
        let statuses = Dictionary(uniqueKeysWithValues: gate.checks.map { ($0.name, $0.status) })
        #expect(statuses == ["artifacts": .pass, "xz": .pass, "coverage": .pass, "tripCounts": .skipped, "streets": .skipped,
                             "snapping": .skipped, "configReferences": .skipped, "flows": .pass], "\(gate.checks.filter { $0.status == .fail })")
        #expect(gate.check("configReferences")?.summary == "config and everything it references are carried forward from set \(before.setId); checked when they were built")

        let manifest = try SetManifest.load(out.appendingPathComponent(SetManifest.fileName))
        #expect(manifest.carriedForward == Self.allButFlows && manifest.previousSetId == before.setId && manifest.setId != before.setId)
        #expect(manifest.artifacts["flows"] != before.artifacts["flows"] && manifest.artifacts["flows"]?.dataVersion.contains("etag-v2-") == true)
        for name in Self.allButFlows { #expect(manifest.artifacts[name] == before.artifacts[name], "\(name)") }
        #expect(manifest.coverage == before.coverage && manifest.sources == before.sources && manifest.minAppFormat == before.minAppFormat)
        #expect(manifest.minAppFormat == 1)
        // Every system's trip counts go on to the next set's gate.
        let counts = try JSONDecoder().decode(TripCountSidecar.self, from: Data(contentsOf: out.appendingPathComponent(TripCountSidecar.fileName)))
        #expect(counts.systems == beforeCounts.systems && counts.setId == manifest.setId)

        let heartbeat = try SetHeartbeat.load(out.appendingPathComponent(SetHeartbeat.fileName))
        #expect(heartbeat.job == "flows" && heartbeat.setId == manifest.setId && heartbeat.checkedAt == "2026-10-06T11:00:00Z")
        #expect(heartbeat.lastTimetableSuccessAt == beforeHeartbeat.lastTimetableSuccessAt && heartbeat.lastTimetableSuccessAt != nil)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: out.path))
            == ["flows.bin", "flows.bin.xz", SetManifest.fileName, TripCountSidecar.fileName, SetHeartbeat.fileName])
    }

    /// data-build's timetables run, as the public runner has it: no flows files in `--out` (it never
    /// fetches them), `--require-flows`, flows carried from `--previous`. The bus timetable doubles
    /// its trips. The gate fails on tripCounts until a person accepts bus
    /// (`--accept-trip-count-change bus`, the dispatch input); accepting another system does not
    /// help. gate.json records the list either way, the set carries the previous flows entry
    /// unchanged, and the heartbeat names the job.
    @Test func anAcceptedTripCountChangeReachesTheGateAndIsRecorded() throws {
        let sources = try SyntheticSources()
        var pipeline = try PipelineTests.published(sources)
        let previous = try pipeline.keepAsPrevious("previous")
        pipeline.previous = previous
        var options = SyntheticSources.FeedOptions()
        options.tripsPerDay = 4
        try sources.writeFeed(.bus, options)
        let built = try pipeline.run(skip: [.streets, .stations, .config, .flows, .gate, .manifest])
        #expect(built.status == 0 && built.ran.map(\.step) == [.timetables, .links], "\(built) \(pipeline.errors)")
        try FileManager.default.removeItem(at: pipeline.report("streets"))
        for file in [pipeline.out.appendingPathComponent("flows.bin"), pipeline.out.appendingPathComponent("flows.bin.xz"), pipeline.report("flows")] {
            try FileManager.default.removeItem(at: file)
        }

        let gateURL = pipeline.reports.appendingPathComponent(GateReport.fileName)
        let arguments = Self.common(sources) + [
            "--out", pipeline.out.path, "--previous", previous.path, "--skip", "streets,timetables,stations,config,links,flows",
            "--require-flows", "--job", "timetables", "--now", "2026-10-06T07:20:00Z",
        ]

        #expect(runAllCommand(arguments) == 3)
        var gate = try GateReport.load(gateURL)
        #expect(gate.status == .fail && gate.acceptedTripCountChange == nil)
        #expect(gate.checks.filter { $0.status == .fail }.map(\.name) == ["tripCounts"] && gate.check("tripCounts")?.failures.count == 21)
        #expect(pipeline.publishedFiles.isEmpty)

        #expect(runAllCommand(arguments + ["--accept-trip-count-change", "subway"]) == 3)
        gate = try GateReport.load(gateURL)
        #expect(gate.status == .fail && gate.acceptedTripCountChange == ["subway"] && gate.check("tripCounts")?.failures.count == 21)
        #expect(gate.check("tripCounts")?.warnings.contains("subway: --accept-trip-count-change had nothing to accept (every compared date within ±35%)") == true)

        #expect(runAllCommand(arguments + ["--accept-trip-count-change", "bus"]) == 0)
        gate = try GateReport.load(gateURL)
        #expect(gate.status == .pass && gate.acceptedTripCountChange == ["bus"], "\(gate.checks.filter { $0.status == .fail })")
        let counts = try #require(gate.check("tripCounts"))
        #expect(counts.status == .pass && counts.failures.isEmpty && counts.metrics["bus.acceptedDates"] == 21)
        #expect(counts.warnings.filter { $0.hasPrefix("accepted: bus ") }.count == 21)
        #expect(counts.warnings.contains("accepted: bus 2026-10-05: 4 trips vs 2 (the previous build's same date), +100.0%"))
        #expect(gate.carriedForward == ["flows"] && gate.check("flows")?.status == .skipped)
        let before = try SetManifest.load(previous)
        let manifest = try SetManifest.load(pipeline.manifestURL)
        #expect(manifest.gate.status == .pass && manifest.carriedForward == ["flows"] && manifest.previousSetId == before.setId)
        #expect(manifest.artifacts["flows"] != nil && manifest.artifacts["flows"] == before.artifacts["flows"])
        #expect(manifest.artifacts["tt-bus"] != before.artifacts["tt-bus"])
        #expect(manifest.gate.checks.first { $0.name == "tripCounts" }?.warnings == counts.warnings.count)
        #expect(try SetHeartbeat.load(pipeline.heartbeatURL).job == "timetables")
        #expect(!FileManager.default.fileExists(atPath: pipeline.out.appendingPathComponent("flows.bin").path))
    }

    /// `all --strict-sources` reaches the timetables step: offline, with no subway entrances file,
    /// the subway is not built. The CLI's timetables step reads the NYC feed names, so the
    /// synthetic subway feed is written under both of the subway's (`gtfs_supplemented`,
    /// `gtfs_subway`); the other systems have no zips under their names, so every run stops at
    /// timetables, and what tells the runs apart is whether the subway, built first, was written.
    /// The strict check comes before any zip is read: with the flag nothing is written; without
    /// it the subway is built (with a warning) and the bus stops the step; with the flag and an
    /// entrances file the subway is built again, so the first stop was the entrances and nothing else.
    @Test func strictSourcesReachesTheTimetablesStep() throws {
        let sources = try SyntheticSources()
        let feed = StoredZip.make(SyntheticSources.feed(.subway, SyntheticSources.FeedOptions(), from: "20261005", to: "20261025"))
        for spec in NYCFeeds.feeds(for: .subway) {
            try feed.write(to: sources.gtfs.appendingPathComponent("\(spec.name).zip"))
            let record = GTFSDownloadRecord(url: spec.url, etag: "\"\(spec.name)-v1\"", lastModified: "Sun, 04 Oct 2026 12:00:00 GMT",
                                            checkedAt: "2026-10-06T07:00:00Z", downloadedAt: "2026-10-04T12:05:00Z", bytes: 0, notModified: false)
            try JSONEncoder().encode(record).write(to: sources.gtfs.appendingPathComponent("\(spec.name).zip.json"))
        }
        func run(_ name: String, _ extra: [String]) -> (status: Int32, subwayBuilt: Bool) {
            let out = sources.root.appendingPathComponent("\(name)/data")
            let status = runAllCommand(Self.common(sources) + ["--out", out.path, "--skip", "streets,stations,config,links,flows,gate,manifest"] + extra)
            return (status, FileManager.default.fileExists(atPath: out.appendingPathComponent(TimetableBuild.artifactFileName(.subway)).path))
        }

        let strict = run("strict", ["--strict-sources"])
        #expect(strict.status == 1 && !strict.subwayBuilt)
        let lenient = run("lenient", [])
        #expect(lenient.status == 1 && lenient.subwayBuilt)

        let entrances = TimetableBuild(sourcesDirectory: sources.sources, outputDirectory: sources.root, reportURL: nil, offline: true,
                                       today: SyntheticSources.today, runner: SyntheticSources.runner).entrancesFile
        let alpha = SyntheticSources.coordinate(2, 2)
        try Data((StrictSourcesTests.header + "IRT,Test,M,Alpha,1,Alpha,1,SA,1,Stair,YES,YES,\(alpha.lat),\(alpha.lon),\n").utf8).write(to: entrances)
        let cached = run("cached", ["--strict-sources"])
        #expect(cached.status == 1 && cached.subwayBuilt)
    }

    /// `all --previous` reaches the timetables step, which reads the live version of each feed
    /// from it (for the archive fallback). The subway is written under the NYC names as in
    /// ``strictSourcesReachesTheTimetablesStep()``, with an entrances file, so the subway is built
    /// and the bus stops the step; a previous manifest that does not read stops it before anything
    /// is built, as the gate would.
    @Test func previousReachesTheTimetablesStep() throws {
        let sources = try SyntheticSources()
        let previous = try PipelineTests.published(sources).keepAsPrevious("previous")

        // The live versions are the sources named after their feed; archived ones are left out.
        var manifest = try SetManifest.load(previous)
        let current = manifest.sources.values.joined().filter { $0.name == $0.feed }
        #expect(!current.isEmpty)
        manifest.sources["tt-ferry", default: []].append(.init(name: "ferry_x@0123abcd", feed: "ferry_x", etag: "\"old\"", feedVersion: "",
                                                               datesSelected: 1, firstSelected: nil, lastSelected: nil))
        let live = TimetableBuild.liveSources(of: manifest)
        #expect(live == Dictionary(uniqueKeysWithValues: current.map { ($0.feed, $0.etag) }))
        #expect(live["ferry_x"] == nil)

        let feed = StoredZip.make(SyntheticSources.feed(.subway, SyntheticSources.FeedOptions(), from: "20261005", to: "20261025"))
        for spec in NYCFeeds.feeds(for: .subway) {
            try feed.write(to: sources.gtfs.appendingPathComponent("\(spec.name).zip"))
        }
        let entrances = TimetableBuild(sourcesDirectory: sources.sources, outputDirectory: sources.root, reportURL: nil, offline: true,
                                       today: SyntheticSources.today, runner: SyntheticSources.runner).entrancesFile
        let alpha = SyntheticSources.coordinate(2, 2)
        try Data((StrictSourcesTests.header + "IRT,Test,M,Alpha,1,Alpha,1,SA,1,Stair,YES,YES,\(alpha.lat),\(alpha.lon),\n").utf8).write(to: entrances)
        let garbage = sources.root.appendingPathComponent("garbage/manifest.json")
        try FileManager.default.createDirectory(at: garbage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a manifest".utf8).write(to: garbage)
        func run(_ name: String, previous: URL) -> (status: Int32, subwayBuilt: Bool) {
            let out = sources.root.appendingPathComponent("\(name)/data")
            let status = runAllCommand(Self.common(sources) + ["--out", out.path, "--skip", "streets,stations,config,links,flows,gate,manifest",
                                                               "--previous", previous.path])
            return (status, FileManager.default.fileExists(atPath: out.appendingPathComponent(TimetableBuild.artifactFileName(.subway)).path))
        }
        let unreadable = run("unreadable", previous: garbage)
        #expect(unreadable.status == 1 && !unreadable.subwayBuilt)
        let readable = run("readable", previous: previous)
        #expect(readable.status == 1 && readable.subwayBuilt)
    }

    /// Both values are checked before anything runs, as strictly as the workflow's own check.
    @Test func aBadJobOrSystemListIsAUsageError() throws {
        let scratch = try PublishScratch()
        let out = scratch.url.appendingPathComponent("data")
        for extra in [["--job", "nightly"], ["--job", "Flows"], ["--accept-trip-count-change", "Bus"], ["--accept-trip-count-change", "bus, path"],
                      ["--accept-trip-count-change", ""], ["--accept-trip-count-change", "bus,"]] {
            #expect(runAllCommand(["--out", out.path, "--skip", "streets,timetables,stations,config,links,flows,gate,manifest"] + extra) == 64, "\(extra)")
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}
