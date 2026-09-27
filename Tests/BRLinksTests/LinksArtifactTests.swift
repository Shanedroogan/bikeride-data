import BRBuild
import BRCore
import BRData
import BRGeo
import BRStreetCore
import BRTimetable
import Foundation
import Testing

/// The fixture world with stations, compiled links, and every artifact written to a data directory.
struct LinksFixture {
    let world: TransitFixture.World
    let network: LinkNetwork
    let stations: [CompiledStation]
    let stationAnchors: [LinkAnchor?]
    let compiled: CompiledLinks
    let data: URL

    /// k1 and k5 both lie near S1 and S2, so those stops' rows hold two links; k4 lies near S3,
    /// under 1 km from k1 and k5, so no pair of rail stations is far enough apart for a bike hop.
    static let places: [(String, Double, Double)] = [("k1", 2.0, 2.3), ("k2", 9.8, 0.2), ("k3", 9, 8.9), ("k4", 5, 5), ("k5", 2.3, 1.7)]

    /// Bike stations for hops: h1 and h3 west of S1 (and near S2's exit), h2 northeast of S3, over
    /// 1 km from both by bike, and none nearer.
    static let hopPlaces: [(String, Double, Double)] = [("h1", 1.1, 1.3), ("h2", 6.9, 7.1), ("h3", 0.8, 2.6)]

    init(places: [(String, Double, Double)] = Self.places) throws {
        world = try TransitFixture.world()
        let graph = world.city.graph
        let options = LinksOptions()
        network = LinkNetwork.make(timetables: world.timetables, graph: graph, options: options).network
        var (selected, _) = StationsBuilder.select(places.map { id, x, y in
            let c = SyntheticCity.coordinate(x, y)
            return GBFSStation(stationID: id, name: id.uppercased(), lat: c.lat, lon: c.lon, regionID: "71", capacity: 10)
        }, area: graph.serviceArea)
        _ = StationsBuilder.snap(&selected, graph: graph, bikeProfile: .eBike)
        stations = selected
        stationAnchors = selected.map { station in
            station.walkSnap.flatMap { graph.snappedPoint($0, query: station.coordinate) }.map(LinkAnchor.init)
        }
        compiled = LinksBuilder.build(network: network, stationAnchors: stationAnchors, graph: graph, options: options)

        data = world.scratch.url.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try world.city.bytes.write(to: data.appendingPathComponent(MappedStreetGraph.fileName))
        for (system, bytes) in world.bytes { try bytes.write(to: data.appendingPathComponent(TimetableBuild.artifactFileName(system))) }
        let matrix = StationsBuilder.matrix(for: stations, graph: graph, profile: .eBike, threads: 1).matrix
        try StationsArtifactWriter.artifact(stations: stations, matrix: matrix, profile: .eBike, dataVersion: "fixture", builtAgainst: [:])
            .write(to: data.appendingPathComponent(MappedStations.fileName))
    }

    static let builtAgainst = ["streets": "x", "stations": "y"]

    func artifact(_ links: CompiledLinks? = nil) -> Data {
        LinksArtifactWriter.artifact(links ?? compiled, dataVersion: "fixture", builtAgainst: Self.builtAgainst)
    }
}

@Suite struct LinksArtifactTests {
    let fixture: LinksFixture

    init() throws {
        fixture = try LinksFixture()
    }

    func reader(_ bytes: Data) throws -> MappedLinks {
        try MappedLinks(artifact: MappedArtifact(fileBytes: bytes, expecting: .links))
    }

    @Test func roundTripsEverySection() throws {
        let links = try reader(fixture.artifact())
        let network = fixture.network, compiled = fixture.compiled
        #expect(links.header.kind == .links && links.header.builtAgainst == LinksFixture.builtAgainst)
        #expect(links.extensions == .empty)
        #expect(links.stopCount == network.stopCount && links.stationCount == fixture.stations.count)
        #expect(links.maxFootpathWalkSeconds == 480 && links.minTransferSeconds == 30)
        #expect(links.walkSpeedMetersPerSecond == WalkProfile.standard.speedMetersPerSecond && links.stationLinkMaxWalkMeters == 350)
        #expect(links.accessSeconds(system: .subway) == 120 && links.accessSeconds(system: .lirr) == 240 && links.accessSeconds(system: .bus) == 30)
        for (slot, system) in LinksFormat.systems.enumerated() {
            #expect(links.stopCount(system: system) == network.systemStopCounts[slot])
            #expect(links.stopBase(system: system) == network.stopBase(system))
        }
        for stop in 0..<network.stopCount {
            let system = links.system(ofGlobalStop: stop)
            #expect(links.globalStop(system: system, stop: links.localStop(ofGlobalStop: stop)) == stop)
            #expect(links.footpaths(from: stop).map { [$0.stop, $0.seconds] } == compiled.footpaths.footpaths(from: stop).map { [$0.stop, $0.seconds] })
            let access = network.streetAccess(of: stop)
            var flags: LinkStopFlags = network.routable[stop] ? .routable : []
            if network.routable[stop] && access.entry { flags.insert(.streetEntry) }
            if network.routable[stop] && access.exit { flags.insert(.streetExit) }
            #expect(links.stopFlags(stop) == flags)
            let stored = links.accessPoints(ofStop: stop).map { links.accessPoint(Int($0)) }
            let expected = network.stopAccess[stop].map { network.accessPoints[$0] }.filter { $0.anchor != nil }
            #expect(stored.count == expected.count)
            for (a, b) in zip(stored, expected) {
                #expect(a.sourceStop == b.sourceStop && a.segment == b.snap!.segment && a.fraction == b.snap!.fraction)
                #expect(a.snapDecimeters == b.snap!.distanceDecimeters && a.accessSeconds == Int(b.accessSeconds))
                #expect(a.flags.contains(.entry) == b.entry && a.flags.contains(.exit) == b.exit && a.flags.contains(.synthetic) == (b.kind == .station))
                #expect(a.coordinate.distance(to: b.coordinate) < 0.2)
            }
            let near = links.stations(nearStop: stop).map { [$0.index, $0.enterSeconds ?? -1, $0.exitSeconds ?? -1] }
            let range = Int(compiled.stationLinks.stopStart[stop])..<Int(compiled.stationLinks.stopStart[stop + 1])
            #expect(near == range.map { slot in
                [Int(compiled.stationLinks.stopStation[slot]), compiled.stationLinks.stopEnter[slot] == LinksFormat.noSeconds ? -1 : Int(compiled.stationLinks.stopEnter[slot]),
                 compiled.stationLinks.stopExit[slot] == LinksFormat.noSeconds ? -1 : Int(compiled.stationLinks.stopExit[slot])]
            })
        }
        for station in 0..<links.stationCount {
            #expect(links.stops(nearStation: station).count == Int(compiled.stationLinks.stationStart[station + 1] - compiled.stationLinks.stationStart[station]))
        }
        #expect(links.footpathCount == compiled.footpaths.count && links.stationLinkCount == compiled.stationLinks.count)
        let s1n = fixture.network.global(.subway, "S1N", in: fixture.world.timetables), s1s = fixture.network.global(.subway, "S1S", in: fixture.world.timetables)
        #expect(links.footpathSeconds(from: s1n, to: s1s) == 30 && links.footpathSeconds(from: s1n, to: s1n) == nil)
        #expect(links.footpathBoundSeconds(from: s1n, to: s1s) == 720)
    }

    @Test func isDeterministic() {
        #expect(fixture.artifact() == fixture.artifact())
    }

    @Test func rejectsCorruptPayloads() throws {
        let bytes = fixture.artifact()
        let headerLength = Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
        func corrupt(at offset: Int, _ value: UInt8) -> Data {
            var copy = bytes
            copy[copy.startIndex + headerLength + offset] = value
            return copy
        }
        #expect(throws: LinksFormatError.badPayloadMagic) { try reader(corrupt(at: 1, 0)) }
        #expect(throws: LinksFormatError.unsupportedPayloadRevision(7)) { try reader(corrupt(at: 4, 7)) }
        #expect(throws: (any Error).self) { try reader(bytes.dropLast(1)) }
        #expect(throws: DataFormatError.kindMismatch(expected: .links, found: .streets)) {
            try MappedLinks(artifact: MappedArtifact(fileBytes: fixture.world.city.bytes))
        }
        var tooLong = fixture.compiled
        tooLong.footpaths.seconds[0] = 5000
        #expect(throws: LinksFormatError.valueOutOfRange(section: "footpathSeconds", index: 0)) { try reader(fixture.artifact(tooLong)) }
        var outOfRange = fixture.compiled
        outOfRange.footpaths.target[0] = UInt32(fixture.network.stopCount)
        #expect(throws: LinksFormatError.valueOutOfRange(section: "footpathTarget", index: 0)) { try reader(fixture.artifact(outOfRange)) }
    }
}

#if os(macOS) || os(Linux)
@Suite struct LinksCompilerTests {
    @Test func buildsTheArtifactFromADataDirectory() throws {
        let fixture = try LinksFixture()
        var configuration = LinksCompiler.Configuration(dataDirectory: fixture.data)
        configuration.compress = ProcessToolRunner().locate("xz") != nil
        configuration.options.threads = 3
        let report = try LinksCompiler(runner: ProcessToolRunner(), configuration: configuration).run()

        #expect(report.warnings == ["tt-ferry.bin missing; ferry stops are not linked", "tt-path.bin missing; path stops are not linked"])
        #expect(Set(report.inputs.keys) == ["streets", "stations", "tt-subway", "tt-bus", "tt-lirr"])
        for (name, input) in report.inputs {
            let sha = try ProcessHasher(runner: ProcessToolRunner()).sha256(ofFileAt: URL(fileURLWithPath: input.path)).hex
            #expect(input.rawSha256 == sha && report.artifact.builtAgainst[name] == sha)
        }
        #expect(report.footpathCheck?.passed == true && report.asymmetricWalkSegments == 0)
        #expect(report.footpaths.footpaths == fixture.compiled.footpaths.count)
        #expect(report.stationLinks.links == fixture.compiled.stationLinks.count)
        #expect(report.network.systems["subway"]?.stationsWithoutEntrances == ["S3"])

        let links = try MappedLinks(contentsOf: configuration.artifactFile)
        #expect(links.header.builtAgainst == report.artifact.builtAgainst)
        try expectDirectPayload(fixture, configuration.artifactFile)
        // The fixture's rail stations lie under 1 km apart: every pair is too short to bike.
        let hops = try #require(report.hops)
        #expect(hops.railParents == ["subway": 4, "lirr": 2] && hops.hops == 0 && links.hops?.count == 0)
        #expect(hops.candidatePairs == hops.droppedBelowWindow && hops.candidatePairs > 0 && hops.blockBytes > 0)
        #expect(report.parameters["hops.maxSpeedMmPerSecond"] == 5141)
        if configuration.compress {
            #expect(report.artifact.xzStreams == 1 && report.artifact.xzBlocks == 1)
            let decoded = try ProcessToolRunner().run(executable: "xz", args: ["-dc", report.artifact.xzPath!])
            let raw = try Data(contentsOf: configuration.artifactFile)
            #expect(decoded == raw)
        }
    }

    /// Expects the payload of writing the directly compiled links with ``HopBuilder``'s hops.
    func expectDirectPayload(_ fixture: LinksFixture, _ file: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let timetables = fixture.world.timetables
        let parents = RailParents.make(timetables: timetables, network: fixture.network)
        let stations = try MappedStations(contentsOf: fixture.data.appendingPathComponent(MappedStations.fileName))
        let inputs = HopBuilder.Inputs(
            systemStopCounts: fixture.network.systemStopCounts, parents: parents, stationLinks: fixture.compiled.stationLinks,
            stationCount: stations.count, distances: stations,
            oneSeat: OneSeatTable.build(timetables: timetables, network: fixture.network, parents: parents, options: HopOptions())
        )
        var compiled = fixture.compiled
        compiled.hops = HopBuilder.build(inputs, options: HopOptions(), threads: 1).hops
        let written = try MappedArtifact(contentsOf: file)
        #expect(written.payload == (try ArtifactHeader.decode(from: fixture.artifact(compiled)).payload), sourceLocation: sourceLocation)
    }

    /// With h1 and h3 west of S1 and h2 northeast of S3: S1 → S3 and S3 → S1, flagged (trains A1
    /// and A2 ride them without a change, but not at midday), and S2 → S3 (S2's exit-only entrance
    /// gives it pickups but no docks, and no train rides S2 → S3).
    @Test func buildsRailHopsFromADataDirectory() throws {
        let fixture = try LinksFixture(places: LinksFixture.hopPlaces)
        var configuration = LinksCompiler.Configuration(dataDirectory: fixture.data)
        configuration.compress = false
        configuration.options.threads = 2
        let report = try LinksCompiler(runner: ProcessToolRunner(), configuration: configuration).run()
        let stats = try #require(report.hops)
        #expect(stats.hops == 3 && stats.origins == 3 && stats.hopsWithOneSeatRide == 2 && stats.droppedByOneSeat == 0)
        #expect(stats.bySystemPair == ["subway→subway": 3])
        #expect(stats.hopsWithFewerPickups == 1 && stats.hopsWithFewerDocks == 2)
        #expect(stats.platformPickupLinksMissing == 0 && stats.platformDockLinksMissing == 0 && stats.blockBytes > 0)
        #expect(report.seconds["oneSeat"] != nil && report.seconds["hops"] != nil)
        try expectDirectPayload(fixture, configuration.artifactFile)

        let links = try MappedLinks(contentsOf: configuration.artifactFile)
        let hops = try #require(links.hops)
        let timetables = fixture.world.timetables
        let s1 = fixture.network.global(.subway, "S1", in: timetables), s2 = fixture.network.global(.subway, "S2", in: timetables)
        let s3 = fixture.network.global(.subway, "S3", in: timetables)
        func station(_ id: String) throws -> Int { try #require(fixture.stations.firstIndex { $0.id == id }) }
        let h1 = try station("h1"), h2 = try station("h2"), h3 = try station("h3")
        #expect(hops.count == 3 && hops.parameters == HopOptions().parameters)
        #expect(hops.hops(fromParent: s1).map(\.target) == [s3] && hops.hops(fromParent: s2).map(\.target) == [s3])
        #expect(hops.hops(fromParent: s3).map(\.target) == [s1])
        let s1s3 = hops.hops(fromParent: s1)[0], s2s3 = hops.hops(fromParent: s2)[0], s3s1 = hops.hops(fromParent: s3)[0]
        #expect(Set(s1s3.pickups) == [h1, h3] && s1s3.docks == [h2] && s1s3.flags == .oneSeatRideExists)
        #expect(Set(s2s3.pickups) == [h1, h3] && s2s3.docks == [h2] && s2s3.flags == [])
        #expect(s3s1.pickups == [h2] && Set(s3s1.docks) == [h1, h3] && s3s1.flags == .oneSeatRideExists)
        #expect(s1s3.minDecameters >= 92 && s1s3.minWalkSeconds > 2 * 120)
    }

    /// The build fails unless every platform of a hop's parents links to its stored stations.
    @Test func failsForAPlatformWithoutALinkToAStoredStation() throws {
        let fixture = try LinksFixture(places: LinksFixture.hopPlaces)
        let stations = try MappedStations(contentsOf: fixture.data.appendingPathComponent(MappedStations.fileName))
        let timetables = fixture.world.timetables
        func railHops(_ links: StationLinkTable) throws -> (hops: CompiledHops, stats: HopStats) {
            var seconds: [String: Double] = [:]
            return try LinksCompiler.railHops(timetables: timetables, network: fixture.network, stationLinks: links, stationCount: stations.count,
                                              distances: stations, options: HopOptions(), threads: 1, seconds: &seconds)
        }
        func missingLinks(_ links: StationLinkTable) -> Int? {
            do {
                _ = try railHops(links)
                Issue.record("expected hopWithoutPlatformLink")
                return nil
            } catch let LinksCompiler.LinksError.hopWithoutPlatformLink(missing, examples) {
                #expect(!examples.isEmpty)
                return missing
            } catch {
                Issue.record("expected hopWithoutPlatformLink, got \(error)")
                return nil
            }
        }
        let (hops, stats) = try railHops(fixture.compiled.stationLinks)
        #expect(hops.count == 3 && stats.platformPickupLinksMissing == 0 && stats.platformDockLinksMissing == 0)

        // S1N and S1S (S3N and S3S) share their access points. Without S1S's exit link to the
        // S1 → S3 hop's first pickup, S1N still offers it, so the hop keeps it: 1 missing triple.
        // Without S3S's enter link from its dock, which S2 → S3 stores too: 2.
        let s1 = fixture.network.global(.subway, "S1", in: timetables), s3 = fixture.network.global(.subway, "S3", in: timetables)
        let row = Int(hops.start[s1]), kP = hops.parameters.pickupsPerHop, kD = hops.parameters.docksPerHop
        #expect(hops.target[row] == UInt32(s3))
        func without(_ gtfsID: String, _ station: UInt16, exit: Bool) throws -> StationLinkTable {
            let platform = fixture.network.global(.subway, gtfsID, in: timetables)
            var links = fixture.compiled.stationLinks
            let slot = try #require((Int(links.stopStart[platform])..<Int(links.stopStart[platform + 1])).first { links.stopStation[$0] == UInt32(station) })
            if exit { links.stopExit[slot] = LinksFormat.noSeconds } else { links.stopEnter[slot] = LinksFormat.noSeconds }
            return links
        }
        #expect(missingLinks(try without("S1S", hops.pickups[row * kP], exit: true)) == 1)
        #expect(missingLinks(try without("S3S", hops.docks[row * kD], exit: false)) == 2)
        #expect(missingLinks(try without("S1N", hops.pickups[row * kP + 1], exit: true)) == 1)
    }

    @Test func needsTheStreetsArtifact() throws {
        let scratch = try ScratchDirectory()
        #expect(throws: (any Error).self) {
            try LinksCompiler(runner: ProcessToolRunner(), configuration: .init(dataDirectory: scratch.url)).run()
        }
    }
}
#endif
