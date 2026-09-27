import BRBuild
import BRCore
import BRData
import Foundation
import Testing

/// `bikeride-data all`'s policy: step names, order, implied skips and what each exit status does.
@Suite struct PipelinePolicyTests {
    @Test func theOrderIsTheOnlyValidOne() {
        #expect(PipelineStep.allCases.map(\.rawValue) == ["streets", "timetables", "stations", "config", "links", "flows", "gate", "manifest", "heartbeat"])
        #expect(PipelineStep.config < .links && PipelineStep.stations < .config && PipelineStep.flows < .gate && PipelineStep.manifest < .heartbeat)
    }

    @Test func skipAcceptsEveryStepAndNothingElse() throws {
        #expect(try Pipeline.steps(named: "") == [])
        #expect(try Pipeline.steps(named: " Streets, config ,FLOWS,gate,manifest,heartbeat,, ") == [.streets, .config, .flows, .gate, .manifest, .heartbeat])
        #expect(try Pipeline.steps(named: PipelineStep.allCases.map(\.rawValue).joined(separator: ",")) == Set(PipelineStep.allCases))
        #expect(throws: Pipeline.UsageError.self) { try Pipeline.steps(named: "streets,tt") }
    }

    @Test func impliedSkips() {
        #expect(Pipeline.effectiveSkips([], compress: true).skip == [])
        let noXZ = Pipeline.effectiveSkips([.streets], compress: false)
        #expect(noXZ.skip == [.streets, .gate, .manifest, .heartbeat] && noXZ.notes.count == 1)
        #expect(Pipeline.effectiveSkips([.manifest], compress: true).skip == [.manifest, .heartbeat])
        #expect(Pipeline.effectiveSkips([.gate], compress: true).skip == [.gate])
    }

    @Test func whatEachStatusMeans() {
        for step in PipelineStep.allCases { #expect(Pipeline.decision(step, status: 0) == .proceed, "\(step)") }
        #expect(Pipeline.decision(.streets, status: 2) != .stop(2))
        #expect(Pipeline.decision(.streets, status: 1) == .stop(1))
        #expect(Pipeline.decision(.config, status: 3) == .stop(3))
        #expect(Pipeline.decision(.config, status: 1) == .stop(1))
        #expect(Pipeline.decision(.links, status: 2) == .stop(2))
        #expect(Pipeline.decision(.flows, status: 4) != .stop(4) && Pipeline.decision(.flows, status: 4) != .proceed)
        #expect(Pipeline.decision(.flows, status: 3) != .stop(3))
        #expect(Pipeline.decision(.flows, status: 1) == .stop(1))
        #expect(Pipeline.decision(.gate, status: 3) == .stop(3))
        #expect(Pipeline.decision(.manifest, status: 3) == .stop(3))
    }

    @Test func aGateHardFailureEndsTheRunBeforeTheManifest() {
        var seen: [PipelineStep] = []
        let outcome = Pipeline.run(skip: [.streets]) { step in
            seen.append(step)
            return step == .flows ? 4 : step == .gate ? 3 : 0
        }
        #expect(seen == [.timetables, .stations, .config, .links, .flows, .gate])
        #expect(outcome.status == 3 && outcome.stoppedAt == .gate && outcome.warnings.count == 1)
    }
}

/// The whole pipeline over ``SyntheticSources``, every step through the library, with the policy
/// `all` applies; then one mutation per hard failure of the gate.
@Suite(.enabled(if: publishToolsInstalled, "needs xz and unzip on PATH"), .serialized)
struct PipelineTests {
    static let systems = ["bus", "ferry", "lirr", "path", "subway"]
    static let artifacts = ["config", "flows", "links", "stations", "streets", "tt-bus", "tt-ferry", "tt-lirr", "tt-path", "tt-subway"]
    static let buildSteps: Set<PipelineStep> = [.streets, .timetables, .stations, .config, .links, .flows]

    /// A full run that must publish.
    static func published(_ sources: SyntheticSources, out: String = "run/data") throws -> SyntheticPipeline {
        var pipeline = SyntheticPipeline(sources: sources, out: out)
        let outcome = pipeline.run()
        #expect(outcome.status == 0, "\(outcome) \(pipeline.errors) \(pipeline.gateReport?.checks.filter { $0.status == .fail } ?? [])")
        #expect(outcome.ran.map(\.step) == PipelineStep.allCases && outcome.warnings.isEmpty)
        return pipeline
    }

    @Test func everyStepRunsAndTheSetIsPublished() throws {
        let sources = try SyntheticSources()
        let pipeline = try Self.published(sources)

        // Ten artifacts, each with its blob, then the published documents.
        let files = try pipeline.files()
        #expect(Set(files.keys) == Set(Self.artifacts.flatMap { ["\($0).bin", "\($0).bin.xz"] } + ["manifest.json", "trip-counts.json", "heartbeat.json"]))

        let gate = try #require(pipeline.gateReport)
        #expect(gate.status == .pass)
        #expect(gate.checks.map(\.name) == ["artifacts", "xz", "coverage", "tripCounts", "streets", "snapping", "configReferences", "flows"])
        #expect(gate.checks.filter { $0.status == .fail }.isEmpty)
        #expect(gate.check("tripCounts")?.status == .skipped)
        let references = try #require(gate.check("configReferences"))
        #expect(references.status == .pass, "\(references)")
        for name in ["mtaStationPairs", "statenIslandRailway", "lirrZones", "fixedTransfers", "valetStations", "stationRegions"] {
            #expect((references.metrics["\(name).checked"] ?? 0) > 0, "\(name)")
        }
        let flows = try #require(gate.check("flows"))
        #expect(flows.status == .pass && flows.metrics["NYC.newestMonthUnmatchedStartPercent"] == 0 && flows.metrics["keys"] == 7)
        #expect(gate.check("streets")?.metrics.keys.sorted() == ["Hoboken.keptSharePercent", "Jersey City.keptSharePercent", "Manhattan.keptSharePercent"])

        // The manifest in the relay's shape: coverage is exactly {system: [YYYY-MM-DD]}.
        let json = try #require(JSONSerialization.jsonObject(with: files["manifest.json"]!) as? [String: Any])
        let coverage = try #require(json["coverage"] as? [String: [String]])
        #expect(coverage.keys.sorted() == Self.systems)
        for (system, dates) in coverage {
            #expect(dates == dates.sorted() && Set(dates).count == dates.count && dates.allSatisfy { SetSystems.serviceDate(isoDay: $0) != nil }, "\(system)")
        }
        let october = { (days: ClosedRange<Int>) in days.map { String(format: "2026-10-%02d", $0) } }
        #expect(coverage["subway"] == october(5...25) && coverage["ferry"] == october(5...31))
        let manifest = try SetManifest.load(pipeline.manifestURL)
        #expect(manifest.artifacts.keys.sorted() == Self.artifacts && manifest.carriedForward.isEmpty && manifest.previousSetId == nil)
        #expect(manifest.systems["subway"]?.days == 20 && manifest.systems["ferry"]?.days == 26 && manifest.systems.values.allSatisfy { $0.status == .ok })
        #expect(try manifest.setId == SetManifest.setId(manifest.artifacts))
        #expect(manifest.gate.status == .pass && manifest.gate.checks.map(\.name) == gate.checks.map(\.name))
        // Two versions of the ferry feed, chosen per date: the newer through 10/15, the older after.
        let ferry = try #require(manifest.sources["tt-ferry"])
        #expect(ferry.map(\.feed) == ["synthetic_F", "synthetic_F"] && ferry[0].name == "synthetic_F" && ferry[1].name.hasPrefix("synthetic_F@"))
        #expect(ferry.map(\.datesSelected) == [11, 16] && ferry[0].lastSelected == "2026-10-15" && ferry[1].firstSelected == "2026-10-16")
        // What links and flows were built against.
        #expect(manifest.artifacts["links"]?.builtAgainst["config"] == manifest.artifacts["config"]?.rawSha256)
        #expect(manifest.artifacts["links"]?.builtAgainst["stations"] == manifest.artifacts["stations"]?.rawSha256)
        #expect(manifest.artifacts["flows"]?.builtAgainst == [:] && manifest.artifacts["config"]?.builtAgainst == [:])
        #expect(manifest.artifacts["flows"]?.dataVersion.hasPrefix("trips=202606-202608 ") == true)

        let heartbeat = try SetHeartbeat.load(pipeline.heartbeatURL)
        #expect(heartbeat.setId == manifest.setId && heartbeat.job == "all" && heartbeat.lastTimetableSuccessAt == heartbeat.checkedAt)
        #expect(heartbeat.checkedAt == manifest.generatedAt)
    }

    @Test func identicalRunsGiveIdenticalBytesAndTheSameSetId() throws {
        let sources = try SyntheticSources()
        var first = try Self.published(sources, out: "run1/data")
        let second = try Self.published(sources, out: "run2/data")
        let bytes = try first.files()
        #expect(bytes == (try second.files()))
        // Sources written again from scratch (other paths, other file times): the same set.
        let elsewhere = try Self.published(try SyntheticSources(), out: "run/data")
        #expect(try SetManifest.load(elsewhere.manifestURL).setId == SetManifest.load(first.manifestURL).setId)
        #expect(bytes == (try elsewhere.files()))

        // Again in the same directory: flows has nothing new (exit 4, fail-soft) and keeps its file.
        let again = first.run()
        #expect(again.status == 0 && again.ran.first { $0.step == .flows }?.status == 4 && again.warnings.count == 1)
        #expect(bytes == (try first.files()))
    }

    // MARK: Hard failures: one mutation each, after a run that published

    /// Runs `steps` (the others skipped) after `mutate`, and expects the gate to stop the run with
    /// 3 and nothing to be published. Returns the gate report.
    static func expectGateFailure(_ pipeline: inout SyntheticPipeline, running steps: Set<PipelineStep>,
                                  sourceLocation: SourceLocation = #_sourceLocation) throws -> GateReport {
        try pipeline.removePublished()
        let outcome = pipeline.run(skip: Self.buildSteps.subtracting(steps))
        #expect(outcome.status == 3 && outcome.stoppedAt == .gate, "\(outcome) \(pipeline.errors)", sourceLocation: sourceLocation)
        #expect(outcome.ran.map(\.step) == PipelineStep.allCases.filter { steps.contains($0) || $0 == .gate }, sourceLocation: sourceLocation)
        for file in [SetManifest.fileName, TripCountSidecar.fileName, SetHeartbeat.fileName] {
            #expect(!FileManager.default.fileExists(atPath: pipeline.out.appendingPathComponent(file).path), "\(file)", sourceLocation: sourceLocation)
        }
        let gate = try #require(pipeline.gateReport, sourceLocation: sourceLocation)
        #expect(gate.status == .fail, sourceLocation: sourceLocation)
        return gate
    }

    @Test func aTwoStreamBlob() throws {
        var pipeline = try Self.published(try SyntheticSources())
        let blob = pipeline.out.appendingPathComponent("tt-lirr.bin.xz")
        try (Data(contentsOf: blob) + Data(contentsOf: blob)).write(to: blob)
        let gate = try Self.expectGateFailure(&pipeline, running: [])
        #expect(gate.check("xz")?.failures.count == 1 && gate.check("xz")?.failures.first?.hasPrefix("tt-lirr: ") == true)
        #expect(gate.checks.filter { $0.status == .fail }.map(\.name) == ["xz"])
    }

    @Test func aStopTheStreetsCannotReach() throws {
        var pipeline = try Self.published(try SyntheticSources())
        var options = SyntheticSources.FeedOptions()
        options.busStopFarFromStreets = true
        try pipeline.sources.writeFeed(.bus, options)
        let gate = try Self.expectGateFailure(&pipeline, running: [.timetables, .links])
        #expect(gate.check("snapping")?.failures == ["B:BC Gamma: routable inside the service area with no street entry and exit"])
        #expect(gate.checks.filter { $0.status == .fail }.map(\.name) == ["snapping"])
    }

    @Test func aRegionLosingMostOfItsStreets() throws {
        var pipeline = try Self.published(try SyntheticSources())
        try pipeline.sources.writeOPL(splitHoboken: true)
        let gate = try Self.expectGateFailure(&pipeline, running: [.streets, .stations, .links])
        let streets = try #require(gate.check("streets"))
        #expect(streets.failures.count == 1 && streets.failures.first?.hasPrefix("Hoboken: 12.") == true, "\(streets.failures)")
        #expect((streets.metrics["Hoboken.keptSharePercent"] ?? 100) < 13 && streets.metrics["Jersey City.keptSharePercent"] == 100)
        #expect(gate.checks.filter { $0.status == .fail }.map(\.name) == ["streets"])
    }

    @Test func tripCountsAgainstThePreviousSet() throws {
        var pipeline = try Self.published(try SyntheticSources())
        pipeline.previous = try pipeline.keepAsPrevious("previous")
        var options = SyntheticSources.FeedOptions()
        options.tripsPerDay = 4
        try pipeline.sources.writeFeed(.bus, options)
        let gate = try Self.expectGateFailure(&pipeline, running: [.timetables, .links])
        let counts = try #require(gate.check("tripCounts"))
        #expect(counts.failures.count == 21 && counts.failures.first == "bus 2026-10-05: 4 trips vs 2 (the previous build's same date), +100.0%")
        #expect(gate.checks.filter { $0.status == .fail }.map(\.name) == ["tripCounts"])
    }

    /// The LIRR gains a stop with service and no fare zone. Built with config, config stops the run
    /// (its reference checks fail: exit 3, fatal); with config reused, as a timetables-only run
    /// would, the gate catches it.
    @Test func anLIRRStopWithoutAFareZone() throws {
        var pipeline = try Self.published(try SyntheticSources())
        var options = SyntheticSources.FeedOptions()
        options.unzonedLIRRStop = true
        try pipeline.sources.writeFeed(.lirr, options)
        let config = try Data(contentsOf: pipeline.out.appendingPathComponent("config.bin"))
        let configXZ = try Data(contentsOf: pipeline.out.appendingPathComponent("config.bin.xz"))

        try pipeline.removePublished()
        let stopped = pipeline.run(skip: [.streets, .stations, .flows])
        #expect(stopped.status == 3 && stopped.stoppedAt == .config && stopped.ran.map(\.step) == [.timetables, .config])
        #expect(!FileManager.default.fileExists(atPath: pipeline.out.appendingPathComponent("config.bin").path))

        try config.write(to: pipeline.out.appendingPathComponent("config.bin"))
        try configXZ.write(to: pipeline.out.appendingPathComponent("config.bin.xz"))
        let gate = try Self.expectGateFailure(&pipeline, running: [.links])
        let references = try #require(gate.check("configReferences"))
        #expect(references.failures == ["lirrZones: fares.lirr.stations: L:LC Gamma has service but no fare zone"])
        #expect(gate.checks.filter { $0.status == .fail }.map(\.name) == ["configReferences"])
    }

    /// The valet station moves about 100 m in GBFS: stations and links are rebuilt, config reused.
    @Test func aValetStationThatMoved() throws {
        var pipeline = try Self.published(try SyntheticSources())
        try pipeline.sources.writeGBFS(moveValet: true)
        let gate = try Self.expectGateFailure(&pipeline, running: [.stations, .links])
        let references = try #require(gate.check("configReferences"))
        #expect(references.failures.count == 1)
        #expect(references.failures.first?.hasPrefix("valetStations: bikeShare.valet: st2 Station st2 is ") == true)
        #expect(references.failures.first?.hasSuffix(" m from its listed coordinate (limit 50 m)") == true)
    }

    /// A station named in the MTA's out-of-system transfers leaves the subway feed.
    @Test func anMTAStationPairThatNoLongerResolves() throws {
        var pipeline = try Self.published(try SyntheticSources())
        var options = SyntheticSources.FeedOptions()
        options.dropSubwayStationC = true
        try pipeline.sources.writeFeed(.subway, options)
        let gate = try Self.expectGateFailure(&pipeline, running: [.timetables, .links])
        #expect(gate.check("configReferences")?.failures == ["mtaStationPairs: fares.mta.outOfSystemTransfers: S:SC is not in the subway feed"])
    }

    /// New trip data with a third of August's NYC starts at a station GBFS does not list: the flows
    /// build fails its own gate (exit 3) and keeps the older flows.bin, and the run goes on to the
    /// set gate, where no report vouches for that file any more. Against a previous set that
    /// published it, it may go out again, with the failure as a warning.
    @Test func flowsWithTooManyUnmatchedTripEnds() throws {
        var pipeline = try Self.published(try SyntheticSources())
        let previous = try pipeline.keepAsPrevious("previous")
        let flows = try Data(contentsOf: pipeline.out.appendingPathComponent("flows.bin"))

        // The gate reads the figures again: a report for this flows.bin whose NYC starts are
        // mostly unmatched fails, whatever the report says of its own gate.
        let reportURL = pipeline.report("flows"), reportBytes = try Data(contentsOf: reportURL)
        var report = try #require(JSONSerialization.jsonObject(with: reportBytes) as? [String: Any])
        var systems = try #require(report["systems"] as? [[String: Any]])
        let nyc = try #require(systems.firstIndex { $0["system"] as? String == "NYC" })
        var side = try #require(systems[nyc]["newestMonthStartSide"] as? [String: Any])
        var stats = try #require(side["stats"] as? [String: Any])
        stats["unmatched"] = 62
        side["stats"] = stats
        systems[nyc]["newestMonthStartSide"] = side
        report["systems"] = systems
        try JSONSerialization.data(withJSONObject: report).write(to: reportURL)
        let tampered = try Self.expectGateFailure(&pipeline, running: [])
        #expect(tampered.check("flows")?.failures == ["NYC 202608 start ids: 50.000% unmatched (limit 2.0%)"])
        try reportBytes.write(to: reportURL)
        try pipeline.sources.writeTrips(unmatchedAugust: 1, version: "v2")
        let gate = try Self.expectGateFailure(&pipeline, running: [.flows])
        #expect(try Data(contentsOf: pipeline.out.appendingPathComponent("flows.bin")) == flows)
        let check = try #require(gate.check("flows"))
        #expect(check.failures.count == 2 && check.failures[0].contains("failed its gate: NYC 202608 start ids: 33.333% unmatched (limit 2.0%)"), "\(check.failures)")
        #expect(check.failures[1] == "reports/flows.json is from a flows build that wrote nothing (gate-failed)")
        #expect(gate.checks.filter { $0.status == .fail }.map(\.name) == ["flows"])

        pipeline.previous = previous
        let republished = pipeline.run(skip: Self.buildSteps)
        #expect(republished.status == 0)
        let again = try #require(pipeline.gateReport?.check("flows"))
        #expect(again.status == .skipped && again.warnings.contains { $0.contains("NYC 202608 start ids: 33.333% unmatched") })
        #expect(try SetManifest.load(pipeline.manifestURL).setId == SetManifest.load(previous).setId)
    }

    // MARK: Optional flows, carried config

    /// No trip data offline: flows fails soft (exit 4) and the set publishes without it, unless
    /// flows is required.
    @Test func withoutTripDataTheSetPublishesWithoutFlows() throws {
        let sources = try SyntheticSources()
        try FileManager.default.removeItem(at: sources.trips)
        var pipeline = SyntheticPipeline(sources: sources)
        let outcome = pipeline.run()
        #expect(outcome.status == 0 && outcome.ran.first { $0.step == .flows }?.status == 4 && outcome.warnings.count == 1, "\(outcome)")
        let manifest = try SetManifest.load(pipeline.manifestURL)
        #expect(manifest.artifacts.keys.sorted() == Self.artifacts.filter { $0 != "flows" })
        let flows = try #require(pipeline.gateReport?.check("flows"))
        #expect(flows.status == .skipped && flows.warnings.first?.hasPrefix("the set has no flows.bin") == true)

        pipeline.requireFlows = true
        let gate = try Self.expectGateFailure(&pipeline, running: [])
        #expect(gate.check("artifacts")?.failures.contains { $0.hasPrefix("flows: not in ") } == true)
    }

    /// A job that rebuilds the timetables must have the config to check them against.
    @Test func aCarriedForwardConfigCannotVouchForNewTimetables() throws {
        var pipeline = try Self.published(try SyntheticSources())
        pipeline.previous = try pipeline.keepAsPrevious("previous")
        let setId = try SetManifest.load(pipeline.previous!).setId
        for name in ["config.bin", "config.bin.xz"] { try FileManager.default.removeItem(at: pipeline.out.appendingPathComponent(name)) }
        let gate = try Self.expectGateFailure(&pipeline, running: [])
        #expect(gate.carriedForward == ["config"] && gate.check("artifacts")?.status == .pass)
        #expect(gate.check("configReferences")?.failures == [
            "config.bin is carried forward from set \(setId), but stations, tt-subway, tt-bus, tt-lirr, tt-ferry, tt-path are new: the reference checks need config.bin in the data directory",
        ])
    }
}
