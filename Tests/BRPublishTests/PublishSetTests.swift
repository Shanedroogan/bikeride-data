import BRBuild
import BRCore
import BRData
import Foundation
import Testing

/// Gate, manifest and heartbeat over a set built by the real compilers (``SyntheticSet``).
@Suite(.enabled(if: publishToolsInstalled, "needs xz and unzip on PATH"), .serialized)
struct PublishSetTests {
    static let systems = ["bus", "ferry", "lirr", "path", "subway"]

    @Test func aCleanSetPassesAndGetsItsManifest() throws {
        let set = try SyntheticSet()
        let gate = try set.gate()
        #expect(gate.status == .pass, "\(gate.checks.filter { $0.status == .fail })")
        #expect(gate.checks.map(\.name) == ["artifacts", "xz", "coverage", "tripCounts", "streets", "snapping"])
        #expect(gate.check("tripCounts")?.status == .skipped)
        #expect(gate.check("streets")?.status == .pass)
        #expect(gate.check("snapping")?.metrics["stopsInServiceArea"] ?? 0 >= 10)
        #expect(Set(gate.artifacts.keys) == Set(SetManifest.coreKinds.map(\.name)))
        #expect(FileManager.default.fileExists(atPath: set.reports.appendingPathComponent("gate.json").path))

        let builder = set.manifestBuilder()
        let manifest = try builder.write()
        // coverage is exactly {subway, bus, lirr, ferry, path: [YYYY-MM-DD]}, as the relay reads it.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: builder.manifestURL)) as! [String: Any]
        let coverage = try #require(json["coverage"] as? [String: [String]])
        #expect(coverage.keys.sorted() == Self.systems)
        let expectedDates = (0..<21).map { SetSystems.isoDay(SyntheticSet.windowStart.adding(days: $0)) }
        for (_, dates) in coverage { #expect(dates == expectedDates) }
        #expect(expectedDates.first == "2026-10-05" && expectedDates.last == "2026-10-25")
        #expect(manifest.systems["subway"] == SetManifest.System(artifact: "tt-subway", first: "2026-10-05", last: "2026-10-25",
                                                                  dates: 21, days: 20, status: .ok))

        // rawSha256 by artifact name (TransitDataSet's `.known` input), from the files themselves.
        #expect(manifest.artifacts.keys.sorted() == SetManifest.coreKinds.map(\.name).sorted())
        for (name, entry) in manifest.artifacts {
            let raw = set.data.appendingPathComponent("\(name).bin")
            #expect(entry.rawSha256 == (try set.sha256(raw)), "\(name)")
            #expect(entry.sha == (try set.sha256(raw.appendingPathExtension("xz"))), "\(name)")
            #expect(entry.rawBytes == (try Data(contentsOf: raw)).count)
        }
        #expect(manifest.artifacts["links"]?.builtAgainst["tt-bus"] == manifest.artifacts["tt-bus"]?.rawSha256)
        #expect(manifest.artifacts["links"]?.builtAgainst["stations"] == manifest.artifacts["stations"]?.rawSha256)
        #expect(manifest.setId.count == 16 && manifest.setId == SetManifest.setId(manifest.artifacts))
        #expect(manifest.sources["tt-bus"] == [SetManifest.Source(name: "fixture_B", feed: "fixture_B", etag: "\"e\"", feedVersion: "",
                                                                  datesSelected: 21, firstSelected: "2026-10-05", lastSelected: "2026-10-25")])
        #expect(manifest.gate.status == .pass && manifest.buildDay == "20261006" && manifest.previousSetId == nil)

        let sidecar = try manifest.loadTripCounts(nextTo: builder.manifestURL, runner: publishRunner)
        #expect(sidecar.systems.keys.sorted() == Self.systems)
        #expect(sidecar.systems["ferry"]?["2026-10-17"] == 2 && sidecar.systems["ferry"]?.count == 21)

        let heartbeat = SetHeartbeat.after(manifest, now: Date(timeIntervalSince1970: 1_791_300_600), job: "all", timetablesSucceeded: true, previous: nil)
        #expect(heartbeat.lastTimetableSuccessAt == heartbeat.checkedAt && heartbeat.setId == manifest.setId)
        let later = SetHeartbeat.after(manifest, now: Date(timeIntervalSince1970: 1_791_400_000), job: "streets", timetablesSucceeded: false, previous: heartbeat)
        #expect(later.lastTimetableSuccessAt == heartbeat.checkedAt && later.checkedAt != heartbeat.checkedAt)
    }

    @Test func setIdIsStableAndIgnoresTime() throws {
        let set = try SyntheticSet()
        _ = try set.gate()
        let first = try set.manifestBuilder(now: Date(timeIntervalSince1970: 1_791_300_000)).build()
        let second = try set.manifestBuilder(now: Date(timeIntervalSince1970: 1_791_999_999)).build()
        #expect(first.manifest.setId == second.manifest.setId)
        #expect(first.manifest.generatedAt != second.manifest.generatedAt)
        var aligned = second.manifest
        aligned.generatedAt = first.manifest.generatedAt
        #expect(aligned == first.manifest)
        #expect(first.tripCountsBytes == second.tripCountsBytes)
    }

    // MARK: Hard failures: one mutation each

    @Test func aTwoStreamBlobFailsTheGateAndBlocksTheManifest() throws {
        let set = try SyntheticSet()
        let blob = set.data.appendingPathComponent("tt-lirr.bin.xz")
        try (Data(contentsOf: blob) + Data(contentsOf: blob)).write(to: blob)
        let gate = try set.gate()
        #expect(gate.status == .fail)
        #expect(gate.check("xz")?.failures.count == 1 && gate.check("xz")!.failures[0].hasPrefix("tt-lirr: "))
        #expect(throws: SetManifest.ManifestError.gateFailed(set.reports.appendingPathComponent("gate.json").path)) {
            try set.manifestBuilder().write()
        }
        #expect(!FileManager.default.fileExists(atPath: set.data.appendingPathComponent("manifest.json").path))
    }

    @Test func aBlobOfOtherBytesFails() throws {
        let set = try SyntheticSet()
        let raw = set.data.appendingPathComponent("tt-path.bin")
        let other = set.scratch.file("other.bin")
        var bytes = try Data(contentsOf: raw)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: other)
        try XZ.compress(other, to: raw.appendingPathExtension("xz"), runner: publishRunner)
        let gate = try set.gate()
        #expect(gate.check("xz")?.status == .fail)
        #expect(gate.check("xz")?.failures.first?.contains("decodes to sha256") == true)
    }

    @Test func anInputRebuiltWithoutItsDependentsFails() throws {
        let set = try SyntheticSet()
        try set.buildTimetable(.bus, tripsPerDay: 3)   // links still names the old tt-bus
        let gate = try set.gate()
        #expect(gate.status == .fail)
        #expect(gate.check("artifacts")?.failures.contains { $0.hasPrefix("links: built against tt-bus ") } == true)
    }

    @Test func aStopWithoutStreetAccessFailsUnlessAllowlisted() throws {
        let set = try SyntheticSet()
        try set.buildTimetable(.bus, thirdStop: (20, 20))   // inside the region, about a kilometre from any street
        try set.buildLinks()
        let gate = try set.gate()
        #expect(gate.status == .fail)
        #expect(gate.check("snapping")?.failures == ["B:BC Gamma: routable inside the service area with no street entry and exit"])
        let allowed = try set.gate(configuration: SyntheticSet.configuration(exceptions: [.init(stop: "B:BC", rule: .noStreetAccess, maxMeters: nil, reason: "test")]))
        #expect(allowed.status == .pass)
        #expect(allowed.check("snapping")?.notes.first?.hasPrefix("allowlisted: B:BC Gamma") == true)
    }

    @Test func aRegionLosingItsStreetsFails() throws {
        let set = try SyntheticSet()
        let strict = try set.gate(configuration: SyntheticSet.configuration(regionMinimum: 99.99))   // the stub is dropped
        #expect(strict.check("streets")?.status == .fail)
        #expect(strict.check("streets")?.failures.first?.hasPrefix("Manhattan: ") == true)
        // A report for other streets bytes cannot vouch for these.
        try set.writeStreetsReport(rawSha256: String(repeating: "0", count: 64), regions: ["Manhattan": .init(totalMeters: 1, keptMeters: 1)])
        let stale = try set.gate()
        #expect(stale.check("streets")?.status == .fail)
        #expect(stale.check("streets")?.failures == ["streets.json describes another streets.bin"])
    }

    @Test func tripCountsAgainstThePreviousBuild() throws {
        let set = try SyntheticSet()
        _ = try set.gate()
        let (manifest, sidecar, _) = try set.manifestBuilder().build()

        // The previous build had twice the bus trips on every date.
        var doubled = sidecar
        doubled.systems["bus"] = sidecar.systems["bus"]!.mapValues { $0 * 2 }
        let previous = try writePrevious(manifest, sidecar: doubled, to: set.scratch.url.appendingPathComponent("prev-doubled"))
        let failing = try set.gate(previous: previous)
        #expect(failing.status == .fail)
        #expect(failing.check("tripCounts")?.failures.count == 21)
        #expect(failing.check("tripCounts")?.failures.first == "bus 2026-10-05: 2 trips vs 4 (the previous build's same date), -50.0%")

        // Against itself: every date on the same-date path, all deltas 0.
        let same = try writePrevious(manifest, sidecar: sidecar, to: set.scratch.url.appendingPathComponent("prev-same"))
        let passing = try set.gate(previous: same)
        #expect(passing.status == .pass)
        #expect(passing.check("tripCounts")?.metrics["bus.sameDate"] == 21 && passing.check("tripCounts")?.metrics["bus.worstChangePercent"] == 0)
        #expect(passing.previousSetId == manifest.setId)

        // A sidecar that does not match the manifest's record is not trusted: skipped, with a warning.
        try Data("{}".utf8).write(to: set.scratch.url.appendingPathComponent("prev-same/trip-counts.json"))
        let tampered = try set.gate(previous: same)
        #expect(tampered.check("tripCounts")?.status == .skipped)
        #expect(tampered.check("tripCounts")?.warnings.first?.hasPrefix("previous trip counts unusable") == true)
    }

    // MARK: Soft failure

    @Test func shortCoverageMarksNoScheduleAndStillPublishes() throws {
        let set = try SyntheticSet()
        try set.buildTimetable(.lirr, lastDay: "20261007")
        try set.buildLinks()
        let gate = try set.gate()
        #expect(gate.status == .softFail)
        #expect(gate.systems["lirr"] == GateSystem(status: .noSchedule, coverageDays: 2, dates: 3, first: "2026-10-05", last: "2026-10-07"))
        let manifest = try set.manifestBuilder().write()
        #expect(manifest.gate.status == .softFail)
        #expect(manifest.systems["lirr"]?.status == .noSchedule && manifest.systems["lirr"]?.days == 2)
        #expect(manifest.systems["subway"]?.status == .ok)
        // The real dates stay, so the relay sees 2 days and returns 503.
        #expect(manifest.coverage["lirr"] == ["2026-10-05", "2026-10-06", "2026-10-07"])
    }

    // MARK: The gate report must describe this set

    @Test func theManifestRefusesAStaleOrMissingGateReport() throws {
        let set = try SyntheticSet()
        #expect(throws: SetManifest.ManifestError.noGateReport(set.reports.appendingPathComponent("gate.json").path)) {
            try set.manifestBuilder().build()
        }
        _ = try set.gate()
        try set.buildTimetable(.ferry, tripsPerDay: 3)   // changed after the gate ran
        #expect(throws: SetManifest.ManifestError.self) { try set.manifestBuilder().build() }
        do {
            _ = try set.manifestBuilder().build()
        } catch let error as SetManifest.ManifestError {
            #expect("\(error)".contains("tt-ferry"))
        }
        try set.buildLinks()
        _ = try set.gate()
        // A blob replaced after the gate ran (same raw file): the published bytes must be the checked ones.
        let blob = set.data.appendingPathComponent("tt-ferry.bin.xz")
        let checked = try Data(contentsOf: blob)
        try Data((0..<checked.count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }).write(to: blob)
        #expect(throws: SetManifest.ManifestError.gateStale("checked the blob of tt-ferry with other bytes (or not at all)")) {
            try set.manifestBuilder().build()
        }
        try checked.write(to: blob)
        #expect(throws: Never.self) { try set.manifestBuilder().build() }
        var otherDay = set.manifestBuilder()
        otherDay.today = day("20261007")
        #expect(throws: SetManifest.ManifestError.gateStale("the gate ran for build day 20261006, not 20261007")) { try otherDay.build() }
    }

    // MARK: Carrying artifacts forward

    @Test func kindsNotRebuiltAreCarriedForward() throws {
        let set = try SyntheticSet()
        _ = try set.gate()
        let (first, sidecar, _) = try set.manifestBuilder().build()

        // The previous set also had flows and config, which this job does not build.
        var previous = first
        let flows = SetManifest.Artifact(sha: String(repeating: "f", count: 64), bytes: 3_600_000, rawBytes: 9_700_000,
                                         rawSha256: String(repeating: "a", count: 64), formatVersion: 0, dataVersion: "trips=202606-202608", builtAgainst: [:])
        let config = SetManifest.Artifact(sha: String(repeating: "c", count: 64), bytes: 4_000, rawBytes: 25_000,
                                          rawSha256: String(repeating: "b", count: 64), formatVersion: 0, dataVersion: "config", builtAgainst: [:])
        previous.artifacts["flows"] = flows
        previous.artifacts["config"] = config
        previous.setId = SetManifest.setId(previous.artifacts)
        let previousURL = try writePrevious(previous, sidecar: sidecar, to: set.scratch.url.appendingPathComponent("prev"))

        // This job also did not rebuild the ferry: its files are gone from the data directory.
        for name in ["tt-ferry.bin", "tt-ferry.bin.xz"] { try FileManager.default.removeItem(at: set.data.appendingPathComponent(name)) }
        let gate = try set.gate(previous: previousURL)
        #expect(gate.status == .pass, "\(gate.checks.filter { $0.status == .fail })")
        #expect(gate.carriedForward == ["tt-ferry", "flows", "config"])
        #expect(gate.check("tripCounts")?.metrics["bus.sameDate"] == 21)
        #expect(gate.systems["ferry"]?.coverageDays == 20)

        let manifest = try set.manifestBuilder(previous: previousURL).write()
        #expect(manifest.carriedForward == ["config", "flows", "tt-ferry"])
        #expect(manifest.artifacts["flows"] == flows && manifest.artifacts["config"] == config)
        #expect(manifest.artifacts["tt-ferry"] == first.artifacts["tt-ferry"])
        #expect(manifest.coverage["ferry"] == first.coverage["ferry"] && manifest.sources["tt-ferry"] == first.sources["tt-ferry"])
        #expect(manifest.previousSetId == previous.setId && manifest.setId == previous.setId)   // same blobs, same set
        let counts = try manifest.loadTripCounts(nextTo: set.manifestBuilder().manifestURL, runner: publishRunner)
        #expect(counts.systems["ferry"] == sidecar.systems["ferry"])
    }

    @Test func aCarriedArtifactMustMatchWhatWasBuiltAgainstIt() throws {
        let set = try SyntheticSet()
        _ = try set.gate()
        let (first, sidecar, _) = try set.manifestBuilder().build()
        for name in ["tt-ferry.bin", "tt-ferry.bin.xz"] { try FileManager.default.removeItem(at: set.data.appendingPathComponent(name)) }

        // The previous set's ferry is not the one links was built against.
        var previous = first
        previous.artifacts["tt-ferry"]?.rawSha256 = String(repeating: "9", count: 64)
        let mismatched = try writePrevious(previous, sidecar: sidecar, to: set.scratch.url.appendingPathComponent("prev-ferry"))
        let gate = try set.gate(previous: mismatched)
        #expect(gate.status == .fail)
        #expect(gate.check("artifacts")?.failures == ["links: built against tt-ferry \(first.artifacts["tt-ferry"]!.rawSha256.prefix(12)), but the set has 999999999999; rebuild links"])

        // A carried artifact built against inputs the set no longer has.
        var stale = first
        stale.artifacts["flows"] = .init(sha: String(repeating: "f", count: 64), bytes: 1, rawBytes: 1, rawSha256: String(repeating: "a", count: 64),
                                         formatVersion: 0, dataVersion: "", builtAgainst: ["stations": String(repeating: "d", count: 64)])
        let staleURL = try writePrevious(stale, sidecar: sidecar, to: set.scratch.url.appendingPathComponent("prev-flows"))
        let staleGate = try set.gate(previous: staleURL)
        #expect(staleGate.check("artifacts")?.failures.contains { $0.hasPrefix("flows: built against stations dddddddddddd") } == true)

        // And with nothing to carry, a missing kind fails.
        let alone = try set.gate()
        #expect(alone.check("artifacts")?.failures.contains { $0.hasPrefix("tt-ferry: not in ") } == true)
    }

    // MARK: Hooks

    struct FixedCheck: GateCheck {
        let name: String
        let result: GateCheckStatus?

        func run(_ context: GateContext) throws -> GateCheckResult {
            guard let result else { throw CocoaError(.fileReadCorruptFile) }
            #expect(context.artifacts[.links] != nil && context.today == SyntheticSet.today)
            return GateCheckResult(name: name, status: result, summary: "fixed")
        }
    }

    @Test func extraChecksJoinTheVerdict() throws {
        let set = try SyntheticSet()
        let passing = try set.gate(extra: [FixedCheck(name: "lirrZones", result: .pass)])
        #expect(passing.status == .pass && passing.checks.last?.name == "lirrZones")
        #expect(try set.gate(extra: [FixedCheck(name: "valet", result: .fail)]).status == .fail)
        let thrown = try set.gate(extra: [FixedCheck(name: "flows", result: nil)])
        #expect(thrown.status == .fail && thrown.check("flows")?.summary == "check failed to run")
    }
}
