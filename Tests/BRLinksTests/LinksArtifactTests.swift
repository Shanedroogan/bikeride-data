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

    init() throws {
        world = try TransitFixture.world()
        let graph = world.city.graph
        let options = LinksOptions()
        network = LinkNetwork.make(timetables: world.timetables, graph: graph, options: options).network
        // k1 and k5 both lie near S1 and S2, so those stops' rows hold two links.
        let places: [(String, Double, Double)] = [("k1", 2.0, 2.3), ("k2", 9.8, 0.2), ("k3", 9, 8.9), ("k4", 5, 5), ("k5", 2.3, 1.7)]
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
        // Same payload as writing the directly compiled links.
        let written = try MappedArtifact(contentsOf: configuration.artifactFile)
        let direct = try ArtifactHeader.decode(from: fixture.artifact()).payload
        #expect(written.payload == direct)
        if configuration.compress {
            #expect(report.artifact.xzStreams == 1 && report.artifact.xzBlocks == 1)
            let decoded = try ProcessToolRunner().run(executable: "xz", args: ["-dc", report.artifact.xzPath!])
            let raw = try Data(contentsOf: configuration.artifactFile)
            #expect(decoded == raw)
        }
    }

    @Test func needsTheStreetsArtifact() throws {
        let scratch = try ScratchDirectory()
        #expect(throws: (any Error).self) {
            try LinksCompiler(runner: ProcessToolRunner(), configuration: .init(dataDirectory: scratch.url)).run()
        }
    }
}
#endif
