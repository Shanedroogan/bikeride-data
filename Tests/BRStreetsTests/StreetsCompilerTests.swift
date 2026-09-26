#if os(macOS) || os(Linux)
@testable import BRBuild
import BRCore
import BRData
import BRGeo
import BRStreetCore
import Foundation
import Testing

/// Stands in for `osmium`: the clip/merge/filter/locate steps do nothing, `export` returns the
/// Jersey City and Hoboken fixture for the boundaries and the park fixture otherwise, and `cat` streams the
/// OPL fixture. Every other tool (`xz`, hashing) runs for real.
private struct FixtureOsmiumRunner: ToolRunner {
    let real = ProcessToolRunner()

    func locate(_ executable: String) -> String? {
        executable == "osmium" ? "osmium" : real.locate(executable)
    }

    func run(executable: String, args: [String], stdin: Data?) throws -> Data {
        guard executable == "osmium" else { return try real.run(executable: executable, args: args, stdin: stdin) }
        guard args.first == "export" else { return Data() }
        let boundary = args.count > 1 && args[1].hasSuffix("nj-municipal-boundaries.osm.pbf")
        return try StreetsFixtures.data(boundary ? "nj-municipalities-fixture.geojsonseq" : "parks-fixture.geojsonseq")
    }

    func stream(executable: String, args: [String], stdinFile: URL?) throws -> ToolStream {
        guard executable == "osmium", args.first == "cat" else {
            return try real.stream(executable: executable, args: args, stdinFile: stdinFile)
        }
        let handle = try FileHandle(forReadingFrom: StreetsFixtures.url("streets-fixture.opl"))
        return ToolStream(output: handle, waitUntilExit: { try handle.close() }, terminate: { try? handle.close() })
    }
}

@Suite struct StreetsCompilerTests {
    @Test func buildsTheArtifactFromOfflineSources() throws {
        let scratch = try ScratchDirectory()
        let sources = scratch.url.appendingPathComponent("sources")
        var configuration = StreetsCompiler.Configuration(
            sourcesDirectory: sources, outputDirectory: scratch.url.appendingPathComponent("data")
        )
        configuration.offline = true
        configuration.options.snapCellMeters = 50
        configuration.compress = ProcessToolRunner().locate("xz") != nil
        try FileManager.default.createDirectory(at: configuration.osmFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuration.boroughsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: configuration.osmFile)
        try Data().write(to: configuration.njOSMFile)
        try StreetsFixtures.data("boroughs-fixture.geojson").write(to: configuration.boroughsFile)

        let report = try StreetsCompiler(runner: FixtureOsmiumRunner(), configuration: configuration).run()

        #expect(report.sources.map(\.status) == ["offline", "offline", "offline"])
        let work = configuration.workDirectory.path
        #expect(report.commands.map { $0.split(separator: " ").prefix(2).joined(separator: " ") } == [
            "osmium tags-filter", "osmium export", // Jersey City's and Hoboken's boundaries
            "osmium extract", "osmium extract", "osmium merge", "osmium time-filter",
            "osmium tags-filter", "osmium tags-filter", "osmium add-locations-to-ways", "osmium export", "osmium cat",
        ])
        #expect(report.commands[0].hasSuffix("new-jersey-latest.osm.pbf r/wikidata=Q138578,Q26339 --overwrite --no-progress -o \(work)/nj-municipal-boundaries.osm.pbf"))
        // The New York clip is unchanged; New Jersey is clipped to its regions' grown hull.
        #expect(report.commands[2].hasPrefix("osmium extract --bbox=-74.271,40.468,-73.688,40.927 --strategy=complete_ways") == true)
        #expect(report.commands[3].hasPrefix("osmium extract --polygon=\(work)/nj-clip.geojson --strategy=complete_ways"))
        #expect(report.commands[4] == "osmium merge \(work)/nyc-bbox.osm.pbf \(work)/nj-clip.osm.pbf --overwrite --no-progress -o \(work)/merged.osm.pbf")
        #expect(report.commands.last == "osmium cat \(work)/service-area-highways-located.osm.pbf -t way -f opl,add_metadata=false,locations_on_ways=true")
        #expect(report.regions == ["Manhattan", "Staten Island", "Hoboken", "Jersey City"])

        // The clip polygon holds both New Jersey regions with room to spare.
        let clip = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(work)/nj-clip.geojson"))) as? [String: Any]
        let polygons = try GeoJSONAreas.polygons(fromGeometry: clip?["geometry"] as? [String: Any] ?? [:])
        let ring = try #require(polygons.first)
        // (The fixture's Jersey City spans 40.695–40.715 N, 74.04–74.02 W; Hoboken reaches 40.725 N.)
        for point in [Coordinate(lat: 40.705, lon: -74.03), Coordinate(lat: 40.725 + 0.012, lon: -74.03), Coordinate(lat: 40.705, lon: -74.04 - 0.017)] {
            #expect(ring.contains(point))
        }
        #expect(!ring.contains(Coordinate(lat: 40.725 + 0.016, lon: -74.03))) // 1.8 km north of Hoboken
        #expect(!ring.contains(Coordinate(lat: 40.7345, lon: -74.1644))) // Newark Penn
        #expect(report.parkPolygons == 1)

        // Same graph as compiling the fixture directly; only the header's dataVersion differs.
        let direct = try FixtureStreets.build()
        let artifactURL = URL(fileURLWithPath: report.artifact.path)
        let written = try MappedArtifact(contentsOf: artifactURL, expecting: .streets)
        let directPayload = try ArtifactHeader.decode(from: direct.bytes).payload
        #expect(written.payload == directPayload)
        #expect(written.header.dataVersion == report.artifact.dataVersion)
        #expect(report.stats == direct.stats)
        let raw = try Data(contentsOf: artifactURL)
        let sha = try CryptoHashing.sha256Hex(ofFileAt: report.artifact.path)
        #expect(report.artifact.rawBytes == raw.count)
        #expect(report.artifact.rawSha256 == sha)

        if configuration.compress {
            #expect(report.artifact.xzStreams == 1 && report.artifact.xzBlocks == 1)
            let xz = try #require(report.artifact.xzPath)
            let decoded = try ProcessToolRunner().run(executable: "xz", args: ["-dc", xz])
            #expect(decoded == raw)
        }
    }

    @Test func offlineBuildsNeedTheSources() throws {
        let scratch = try ScratchDirectory()
        var configuration = StreetsCompiler.Configuration(
            sourcesDirectory: scratch.url.appendingPathComponent("sources"), outputDirectory: scratch.url.appendingPathComponent("data")
        )
        configuration.offline = true
        #expect(throws: SourceFetcher.FetchError.missingOffline(path: configuration.osmFile.path)) {
            try StreetsCompiler(runner: FixtureOsmiumRunner(), configuration: configuration).run()
        }
    }
}

/// An independent check of the report's hash: an external tool, not the compiler's hasher.
private enum CryptoHashing {
    static func sha256Hex(ofFileAt path: String) throws -> String {
        try ProcessHasher(runner: ProcessToolRunner()).sha256(ofFileAt: URL(fileURLWithPath: path)).hex
    }
}
#endif
