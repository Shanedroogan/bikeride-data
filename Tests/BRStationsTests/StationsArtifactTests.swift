import BRBuild
import BRCore
import BRData
import BRGeo
import BRStreetCore
import Foundation
import Testing

@Suite struct StationsArtifactTests {
    let fixture: MatrixCity
    let matrix: [UInt16]
    let bytes: Data

    init() throws {
        fixture = try MatrixCity()
        matrix = StationsBuilder.matrix(for: fixture.stations, graph: fixture.city.graph, profile: .eBike, threads: 2).matrix
        bytes = StationsArtifactWriter.artifact(stations: fixture.stations, matrix: matrix, profile: .eBike,
                                                dataVersion: "fixture", builtAgainst: ["streets": String(repeating: "ab", count: 32)])
    }

    func reader(_ data: Data? = nil) throws -> MappedStations {
        try MappedStations(artifact: MappedArtifact(fileBytes: data ?? bytes, expecting: .stations))
    }

    @Test func roundTripsEveryField() throws {
        let scratch = try ScratchDirectory()
        try bytes.write(to: scratch.file(MappedStations.fileName))
        let stations = try MappedStations.load(fromDataDirectory: scratch.url)
        #expect(stations.header.kind == .stations && stations.header.dataVersion == "fixture")
        #expect(stations.header.builtAgainst["streets"] == String(repeating: "ab", count: 32))
        #expect(stations.count == fixture.stations.count)
        #expect(stations.matrixProfile.speedMetersPerSecond == BikeProfile.eBike.speedMetersPerSecond)
        #expect(stations.matrixProfile.multipliers == BikeProfile.eBike.multipliers)
        for (index, station) in fixture.stations.enumerated() {
            #expect(stations.stationID(index) == station.id)
            #expect(stations.index(ofStationID: station.id) == index)
            #expect(stations.name(index) == station.name && stations.shortName(index) == station.shortName)
            #expect(stations.regionID(index) == station.regionID && stations.capacity(index) == Int(station.capacity))
            #expect(stations.flags(index) == station.flags)
            #expect(stations.coordinate(index) == station.coordinate)
            #expect(stations.bikeSnap(index) == station.bikeSnap && stations.walkSnap(index) == station.walkSnap)
            let row = stations.row(from: index)
            for other in 0..<stations.count {
                #expect(stations.distanceDecameters(from: index, to: other) == matrix[index * stations.count + other])
                #expect(row[other] == matrix[index * stations.count + other])
                let meters = stations.distanceMeters(from: index, to: other)
                #expect(meters == (matrix[index * stations.count + other] == StationsFormat.unreachable ? nil : Double(matrix[index * stations.count + other]) * 10))
            }
        }
        #expect(stations.index(ofStationID: "missing") == nil && stations.index(ofStationID: "") == nil)
    }

    @Test func isDeterministic() throws {
        let again = StationsArtifactWriter.artifact(stations: fixture.stations, matrix: matrix, profile: .eBike,
                                                    dataVersion: "fixture", builtAgainst: ["streets": String(repeating: "ab", count: 32)])
        #expect(again == bytes)
    }

    @Test func viewsAnUnalignedCopySafely() throws {
        // A payload slice that is not 8-aligned in memory is copied, not misread.
        var shifted = Data([0])
        shifted.append(bytes)
        let stations = try reader(shifted.dropFirst())
        #expect(stations.distanceDecameters(from: 0, to: 1) == matrix[1])
    }

    @Test func rejectsCorruptPayloads() throws {
        let headerLength = Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
        func corrupt(at offset: Int, _ value: UInt8) -> Data {
            var copy = bytes
            copy[copy.startIndex + headerLength + offset] = value
            return copy
        }
        #expect(throws: StationsFormatError.badPayloadMagic) { try reader(corrupt(at: 0, 0x58)) }
        #expect(throws: StationsFormatError.unsupportedDraftRevision(9)) { try reader(corrupt(at: 4, 9)) }
        #expect(throws: (any Error).self) { try reader(bytes.dropLast(3)) }
        #expect(throws: DataFormatError.kindMismatch(expected: .stations, found: .streets)) {
            try MappedStations(artifact: MappedArtifact(fileBytes: fixture.city.bytes))
        }
        // A non-zero diagonal is caught.
        var bad = matrix
        bad[0] = 5
        let badBytes = StationsArtifactWriter.artifact(stations: fixture.stations, matrix: bad, profile: .eBike, dataVersion: "x", builtAgainst: [:])
        #expect(throws: StationsFormatError.valueOutOfRange(section: "matrixDiagonal", index: 0)) { try reader(badBytes) }
    }

    @Test func storedSnapsRebuildTheSnappedPoint() throws {
        let graph = fixture.city.graph
        for station in fixture.stations where station.bikeSnap != nil {
            let original = graph.snap(station.coordinate, profile: BikeProfile.eBike)!
            let rebuilt = graph.snappedPoint(StoredSnap(original), query: station.coordinate)!
            #expect(rebuilt.segment == original.segment && rebuilt.nodeA == original.nodeA && rebuilt.nodeB == original.nodeB)
            #expect(rebuilt.forwardEdge == original.forwardEdge && rebuilt.backwardEdge == original.backwardEdge)
            #expect(abs(rebuilt.fraction - original.fraction) < 1e-6)
            #expect(abs(rebuilt.distanceMeters - original.distanceMeters) <= 0.05)
            #expect(rebuilt.coordinate.distance(to: original.coordinate) < 0.05)
        }
        #expect(graph.snappedPoint(StoredSnap(segment: UInt32(graph.segmentCount), fraction: 0, distanceDecimeters: 0), query: Coordinate(lat: 0, lon: 0)) == nil)
        #expect(StoredSnap(segment: 1, fraction: 0, distanceDecimeters: 12).distanceMeters == 1.2)
    }
}

#if os(macOS) || os(Linux)
/// Stands in for `curl`: serves the GBFS fixtures by URL, answering 200 and writing the output
/// file the way `SourceFetcher` asks. Every other tool runs for real.
private struct FixtureCurlRunner: ToolRunner {
    let documents: [String: String]
    let real = ProcessToolRunner()

    func locate(_ executable: String) -> String? { executable == "curl" ? "curl" : real.locate(executable) }

    func run(executable: String, args: [String], stdin: Data?) throws -> Data {
        guard executable == "curl" else { return try real.run(executable: executable, args: args, stdin: stdin) }
        guard let url = args.last, let body = documents[url], let output = args.firstIndex(of: "--output").map({ args[$0 + 1] }) else {
            return Data("404".utf8)
        }
        try Data(body.utf8).write(to: URL(fileURLWithPath: output))
        return Data("200".utf8)
    }

    func stream(executable: String, args: [String], stdinFile: URL?) throws -> ToolStream {
        try real.stream(executable: executable, args: args, stdinFile: stdinFile)
    }
}

@Suite struct StationsCompilerTests {
    @Test func buildsTheArtifactFromFetchedFeeds() throws {
        let fixture = try MatrixCity()
        let scratch = try ScratchDirectory()
        let data = scratch.url.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try fixture.city.bytes.write(to: data.appendingPathComponent(MappedStreetGraph.fileName))
        let entries = fixture.stations.map { station in
            GBFSFixture.station(station.id, lat: station.coordinate.lat, lon: station.coordinate.lon, extra: "\"region_id\":\"71\",")
        } + [GBFSFixture.station("jc", lat: 40.7, lon: -74.0, extra: "\"region_id\":\"70\",")]
        let runner = FixtureCurlRunner(documents: [
            GBFSStations.discoveryURL: GBFSFixture.discovery(),
            "https://example.test/gbfs/en/station_information.json": GBFSFixture.stationInformation(entries),
        ])
        var configuration = StationsCompiler.Configuration(sourcesDirectory: scratch.url.appendingPathComponent("sources"), outputDirectory: data)
        configuration.threads = 3
        configuration.compress = ProcessToolRunner().locate("xz") != nil
        let report = try StationsCompiler(runner: runner, configuration: configuration).run()

        #expect(report.sources.map(\.status) == ["downloaded", "downloaded"])
        #expect(report.selection.feedStations == 9 && report.selection.accepted == 8 && report.selection.rejectedRegion == 1)
        #expect(report.snapping.bikeSnapped == 7 && report.snapping.bikeUnsnapped == ["F: Station F"])
        #expect(report.matrix.stations == 8 && report.feedLastUpdated == 1_790_309_897)
        let streetsSha = try ProcessHasher(runner: ProcessToolRunner()).sha256(of: fixture.city.bytes).hex
        #expect(report.artifact.builtAgainst["streets"] == streetsSha)
        #expect(report.artifact.dataVersion.hasPrefix("gbfs=2026-09-25T"))
        let stations = try MappedStations(contentsOf: configuration.artifactFile)
        #expect(stations.count == 8)
        // The matrix stores decameters, so a fresh route differs by at most half a step.
        #expect(!report.spotChecks.isEmpty && report.spotChecks.allSatisfy { $0.differenceMeters.map { $0.magnitude <= 5.000001 } ?? ($0.matrixMeters == nil) })
        // Same matrix as building directly (the compiler reorders stations along the curve).
        let (ordered, _) = StationsBuilder.select(
            fixture.stations.map { GBFSStation(stationID: $0.id, name: "Station \($0.id)", lat: $0.coordinate.lat, lon: $0.coordinate.lon, regionID: "71", capacity: 20) },
            area: fixture.city.graph.fiveBoroughs)
        #expect((0..<8).map(stations.stationID) == ordered.map(\.id))
        if configuration.compress {
            #expect(report.artifact.xzStreams == 1 && report.artifact.xzBlocks == 1)
            let decoded = try ProcessToolRunner().run(executable: "xz", args: ["-dc", report.artifact.xzPath!])
            let raw = try Data(contentsOf: configuration.artifactFile)
            #expect(decoded == raw)
        }

        // Offline reuses the downloaded files.
        configuration.offline = true
        let offline = try StationsCompiler(runner: runner, configuration: configuration).run()
        #expect(offline.sources.map(\.status) == ["offline", "offline"])
        #expect(offline.artifact.rawSha256 == report.artifact.rawSha256)
    }
}
#endif
