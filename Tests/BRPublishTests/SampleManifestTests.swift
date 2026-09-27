import BRBuild
import BRCore
import Foundation
import Testing

/// `Tests/Fixtures/manifest/sample-manifest.json` and `sample-heartbeat.json`: what
/// `bikeride-data gate` + `manifest` wrote for the pinned Tier B set static-20260926 (build day
/// 2026-09-26, `--now 2026-09-26T16:31:00Z`). The relay's health test reads them, so they must
/// stay in the exact published shape: these tests fail when the manifest schema drifts from them.
/// To remake them, rebuild the fixture with `all --offline … --today 20260926`, then run `gate`
/// and `manifest` with `--today 20260926 --now 2026-09-26T16:31:00Z` and copy the two files.
@Suite struct SampleManifestTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/manifest")

    static func json(_ name: String) throws -> (data: Data, object: NSDictionary) {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return (data, try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary))
    }

    @Test func theSampleManifestDecodesWithNothingLeftOver() throws {
        let (data, object) = try Self.json("sample-manifest.json")
        let manifest = try JSONDecoder().decode(SetManifest.self, from: data)
        // Every key is a field of SetManifest, and every field is in the file.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let again = try #require(JSONSerialization.jsonObject(with: encoder.encode(manifest)) as? NSDictionary)
        #expect(again == object)
        #expect(manifest.schema == 1 && manifest.buildDay == "20260926" && manifest.gate.status == .pass)
        #expect(try manifest.setId == SetManifest.setId(manifest.artifacts))
        #expect(manifest.artifacts.keys.sorted() == SetManifest.coreKinds.map(\.name).sorted())
        #expect(manifest.artifacts["streets"]?.rawSha256 == "06af80ebc1cfdef901dcfbc498e9d3bb9d6dcc8ffc210a4791bf2bb9e2a5076f")
        #expect(manifest.artifacts["links"]?.builtAgainst["streets"] == manifest.artifacts["streets"]?.rawSha256)
    }

    /// The relay (relay/src/routes/health.ts) treats every key under `coverage` as a system and
    /// counts consecutive `YYYY-MM-DD` strings from today.
    @Test func coverageIsExactlyTheRelaysShape() throws {
        let (_, object) = try Self.json("sample-manifest.json")
        let coverage = try #require(object["coverage"] as? [String: Any])
        #expect(coverage.keys.sorted() == ["bus", "ferry", "lirr", "path", "subway"])
        let manifest = try JSONDecoder().decode(SetManifest.self, from: Self.json("sample-manifest.json").data)
        for (system, value) in coverage {
            let dates = try #require(value as? [String], "\(system)")
            #expect(dates.allSatisfy { $0.count == 10 && SetSystems.serviceDate(isoDay: $0) != nil }, "\(system)")
            #expect(dates == dates.sorted() && Set(dates).count == dates.count, "\(system)")
            // The relay's count from the build day equals the manifest's own.
            let present = Set(dates)
            var days = 0, date = "2026-09-26"
            while present.contains(date) {
                days += 1
                date = SetSystems.isoDay(SetSystems.serviceDate(isoDay: date)!.adding(days: 1))
            }
            #expect(days == manifest.systems[system]?.days, "\(system)")
        }
        #expect(manifest.systems.mapValues(\.days) == ["subway": 36, "bus": 99, "lirr": 44, "ferry": 492, "path": 50])
        #expect(manifest.systems.mapValues(\.dates) == ["subway": 37, "bus": 100, "lirr": 45, "ferry": 493, "path": 51])
    }

    @Test func theSampleHeartbeatNamesTheSet() throws {
        let (data, object) = try Self.json("sample-heartbeat.json")
        let heartbeat = try JSONDecoder().decode(SetHeartbeat.self, from: data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try #require(JSONSerialization.jsonObject(with: encoder.encode(heartbeat)) as? NSDictionary) == object)
        let manifest = try JSONDecoder().decode(SetManifest.self, from: Self.json("sample-manifest.json").data)
        #expect(heartbeat.setId == manifest.setId)
        let iso = ISO8601DateFormatter()
        #expect(iso.date(from: heartbeat.checkedAt) != nil && heartbeat.lastTimetableSuccessAt.flatMap(iso.date(from:)) != nil)
    }

    /// Whether a run resets `lastTimetableSuccessAt`: yes with a fresh tt-*, never when all five are
    /// carried forward unless the job says its sources were unchanged.
    @Test func timetableSuccessIsInferredFromTheSet() throws {
        let iso = ISO8601DateFormatter()
        let manifest = try JSONDecoder().decode(SetManifest.self, from: Self.json("sample-manifest.json").data)
        #expect(SetHeartbeat.timetablesSucceeded(manifest, notRun: false, unchanged: false))
        #expect(!SetHeartbeat.timetablesSucceeded(manifest, notRun: true, unchanged: false))
        var oneCarried = manifest
        oneCarried.carriedForward = ["tt-ferry"]
        #expect(SetHeartbeat.timetablesSucceeded(oneCarried, notRun: false, unchanged: false))
        var flowsOnly = manifest
        flowsOnly.carriedForward = ["links", "stations", "streets", "tt-bus", "tt-ferry", "tt-lirr", "tt-path", "tt-subway"]
        #expect(!SetHeartbeat.timetablesSucceeded(flowsOnly, notRun: false, unchanged: false))
        #expect(SetHeartbeat.timetablesSucceeded(flowsOnly, notRun: false, unchanged: true))
        let previous = SetHeartbeat(checkedAt: "2026-09-26T03:20:00Z", lastTimetableSuccessAt: "2026-09-26T03:20:00Z", setId: "x", job: "timetables")
        let after = SetHeartbeat.after(flowsOnly, now: iso.date(from: "2026-09-26T16:31:00Z")!, job: "flows",
                                       timetablesSucceeded: SetHeartbeat.timetablesSucceeded(flowsOnly, notRun: false, unchanged: false),
                                       previous: previous)
        #expect(after.lastTimetableSuccessAt == "2026-09-26T03:20:00Z" && after.checkedAt == "2026-09-26T16:31:00Z")
    }
}
