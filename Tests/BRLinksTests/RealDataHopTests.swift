import BRBuild
import BRConfig
import BRCore
import BRData
import BRStreetCore
import BRTimetable
import Foundation
import Testing

/// The rail bike hops of a built data directory: a rebuild from its own inputs equals the stored
/// block, and known pairs are kept or dropped for the documented reasons. Runs only when
/// `BR_DATA_DIR` names a data directory whose `links.bin` has hops (and the `config.bin` it was
/// built from, when its `builtAgainst` names one), e.g.
///
///     BR_DATA_DIR=build/data swift test -c release -Xswiftc -enable-testing --filter RealDataHopTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BR_DATA_DIR"] != nil))
struct RealDataHopTests {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BR_DATA_DIR"] ?? ".")

    @Test func hopsEqualARebuildAndKnownPairs() throws {
        let links = try MappedLinks.load(fromDataDirectory: directory)
        let stored = try #require(links.hops, "links.bin has no hop block")
        let stations = try MappedStations.load(fromDataDirectory: directory)
        var timetables: [TransitSystem: Timetable] = [:]
        for system in LinksFormat.systems {
            timetables[system] = try Timetable(contentsOf: directory.appendingPathComponent(TimetableBuild.artifactFileName(system)))
        }
        // The numbering and station links, as stored.
        let t = links.stopCount
        let network = LinkNetwork(
            systemStopCounts: LinksFormat.systems.map { links.stopCount(system: $0) }, routable: (0..<t).map { links.stopFlags($0).contains(.routable) },
            stopAccess: [[Int]](repeating: [], count: t), accessPoints: [], transfers: []
        )
        let raw = links.raw
        var stationLinks = StationLinkTable.empty(stops: t, stations: links.stationCount)
        stationLinks.stationStart = Array(raw.stationStopStart)
        stationLinks.stationStop = Array(raw.stationStopStop)
        stationLinks.stationEnter = Array(raw.stationStopEnter)
        stationLinks.stationExit = Array(raw.stationStopExit)
        stationLinks.stopStart = Array(raw.stopStationStart)
        stationLinks.stopStation = Array(raw.stopStationStation)
        stationLinks.stopEnter = Array(raw.stopStationEnter)
        stationLinks.stopExit = Array(raw.stopStationExit)
        // The hop options links was built with: the holidays and change after the bike of the
        // config its header names. Links built before it named one (P2a) used the literals.
        var options = HopOptions.standard
        if let configSha = links.header.builtAgainst[ArtifactKind.config.name] {
            let configURL = directory.appendingPathComponent(MappedConfig.fileName)
            let sha = try ProcessHasher(runner: ProcessToolRunner()).sha256(ofFileAt: configURL).hex
            try #require(sha == configSha, "config.bin is not the one links.bin was built against (\(configSha.prefix(12)))")
            options = HopOptions(config: try MappedConfig(contentsOf: configURL).document)
        }
        #expect(stored.parameters == options.parameters)
        options.parameters = stored.parameters
        let parents = RailParents.make(timetables: timetables, network: network)
        let inputs = HopBuilder.Inputs(
            systemStopCounts: network.systemStopCounts, parents: parents, stationLinks: stationLinks, stationCount: stations.count,
            distances: stations, oneSeat: OneSeatTable.build(timetables: timetables, network: network, parents: parents, options: options)
        )
        let (rebuilt, stats) = HopBuilder.build(inputs, options: options, threads: ProcessInfo.processInfo.activeProcessorCount)
        #expect(Array(stored.hopStart) == rebuilt.start && Array(stored.hopTarget) == rebuilt.target)
        #expect(Array(stored.hopPickup) == rebuilt.pickups && Array(stored.hopDock) == rebuilt.docks)
        #expect(Array(stored.hopMinDecameters) == rebuilt.minDecameters && Array(stored.hopMinWalkSeconds) == rebuilt.minWalkSeconds)
        #expect(Array(stored.hopFlags) == rebuilt.flags)
        var check = stats
        HopBuilder.checkPlatformLinks(rebuilt, parents: parents, stationLinks: stationLinks, stats: &check)
        #expect(check.platformPickupLinksMissing == 0 && check.platformDockLinksMissing == 0)
        #expect((36_000...38_500).contains(stats.hops), "hops \(stats.hops)")

        func parent(_ id: String) throws -> Int {
            let stop = StopID(id)
            let system = try #require(stop.system), timetable = try #require(timetables[system]), local = try #require(timetable.stop(id: stop))
            return try #require(parents.parents.firstIndex(of: links.globalStop(system: system, stop: timetable.stopParent(local) ?? local)))
        }
        func decision(_ from: String, _ to: String) throws -> HopDecision {
            let result = HopBuilder.evaluate(try parent(from), try parent(to), inputs: inputs, options: options)
            print("RealDataHopTests \(from) → \(to): \(result)")
            return result
        }
        func isKept(_ decision: HopDecision) -> Bool { if case .kept = decision { true } else { false } }
        #expect(isKept(try decision("S:L08", "S:A41")))   // Bedford Av → Jay St-MetroTech, 5.8 km
        #expect(isKept(try decision("S:G22", "S:L10")))   // Court Sq → Lorimer St
        #expect(isKept(try decision("S:635", "S:A27")))   // 14 St-Union Sq → 42 St-Port Authority
        guard case .belowWindow = try decision("S:L08", "S:G29") else {   // Bedford Av → Metropolitan Av (G), about 600 m
            Issue.record("Bedford Av → Metropolitan Av should be too short")
            return
        }
        #expect(!isKept(try decision("P:place_GRV", "P:place_EXP")))   // Grove St → Exchange Pl
        #expect(try decision("P:place_GRV", "P:place_WTC") == .noTuple)   // No bike path crosses the Hudson.
    }
}
