@testable import bikeride_data
import BRBuild
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

    /// The bus timetable doubles its trips. The gate fails on tripCounts until a person accepts
    /// bus (`--accept-trip-count-change bus`, the dispatch input); accepting another system does
    /// not help. gate.json records the list either way, and the heartbeat names the job.
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
        let manifest = try SetManifest.load(pipeline.manifestURL)
        #expect(try manifest.gate.status == .pass && manifest.carriedForward.isEmpty && manifest.previousSetId == SetManifest.load(previous).setId)
        #expect(manifest.gate.checks.first { $0.name == "tripCounts" }?.warnings == counts.warnings.count)
        #expect(try SetHeartbeat.load(pipeline.heartbeatURL).job == "timetables")
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
