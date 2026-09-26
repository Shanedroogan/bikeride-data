#if os(macOS) || os(Linux)
@testable import BRBuild
import BRCore
import BRData
import BRStreetCore
import Foundation
import Testing

/// Stands in for `osmium`: the clip/filter/locate steps do nothing, `export` returns the park
/// fixture and `cat` streams the OPL fixture. Every other tool (`xz`, hashing) runs for real.
private struct FixtureOsmiumRunner: ToolRunner {
    let real = ProcessToolRunner()

    func locate(_ executable: String) -> String? {
        executable == "osmium" ? "osmium" : real.locate(executable)
    }

    func run(executable: String, args: [String], stdin: Data?) throws -> Data {
        guard executable == "osmium" else { return try real.run(executable: executable, args: args, stdin: stdin) }
        return args.first == "export" ? try StreetsFixtures.data("parks-fixture.geojsonseq") : Data()
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
        try StreetsFixtures.data("boroughs-fixture.geojson").write(to: configuration.boroughsFile)

        let report = try StreetsCompiler(runner: FixtureOsmiumRunner(), configuration: configuration).run()

        #expect(report.sources.map(\.status) == ["offline", "offline"])
        #expect(report.commands.count == 6)
        #expect(report.commands.first?.hasPrefix("osmium extract --bbox=-74.271,40.468,-73.688,40.927") == true)
        #expect(report.commands.last == "osmium cat \(configuration.workDirectory.path)/nyc-highways-located.osm.pbf -t way -f opl,add_metadata=false,locations_on_ways=true")
        #expect(report.regions == ["Manhattan", "Staten Island"])
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
