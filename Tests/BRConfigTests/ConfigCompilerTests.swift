import BRBuild
import BRConfig
import BRCore
import BRData
import Foundation
import Testing

/// `ConfigCompiler` end to end (no xz: the compressor is covered by the other compilers' tests).
@Suite struct ConfigCompilerTests {
    func compiler(data: URL?, out: URL, gbfs: URL? = nil, require: Bool = false) -> ConfigCompiler {
        var configuration = ConfigCompiler.Configuration(sourcesDirectory: RepositoryData.root, dataDirectory: data, outputDirectory: out,
                                                         gbfsDirectory: gbfs)
        configuration.compress = false
        configuration.offline = true
        configuration.requireReferences = require
        return ConfigCompiler(runner: ProcessToolRunner(), configuration: configuration)
    }

    @Test func buildsTheSameBytesTwice() throws {
        let scratch = try ScratchDirectory()
        let a = scratch.file("a"), b = scratch.file("b")
        let first = try compiler(data: nil, out: a).run()
        let second = try compiler(data: nil, out: b).run()
        let bytes = try Data(contentsOf: a.appendingPathComponent(MappedConfig.fileName))
        #expect(bytes == (try Data(contentsOf: b.appendingPathComponent(MappedConfig.fileName))))
        #expect(first.payloadSha256 == second.payloadSha256 && first.artifact?.rawSha256 == second.artifact?.rawSha256)

        // The file is the canonical document, with a content-derived dataVersion and no inputs.
        let config = try MappedConfig(fileBytes: bytes)
        let document = try ConfigSources(root: RepositoryData.root).load()
        #expect(config.document == document)
        #expect(config.header.dataVersion == "config:\(first.jsonSha256)" && config.header.builtAgainst.isEmpty)
        #expect(try sha256Hex(Data(ArtifactHeader.decode(from: bytes).payload)) == first.payloadSha256)
        #expect(first.artifact?.formatVersion == 1 && first.artifact?.payloadRevision == 1)

        // With no data directory every cross-artifact check is skipped, with a warning; the build
        // still succeeds.
        #expect(first.errors.isEmpty)
        #expect(first.checks.filter { $0.skipped == nil }.map(\.name) == ["stationSelectionRegions"])
        #expect(first.warnings.contains("lirrZones skipped: tt-lirr.bin is missing"))
        // 14 files, plus the 7 bike-planning sources (six sections, the weather keywords CSV).
        #expect(first.sources.map(\.path).contains("fares/lirr/lirr-stations-2026.csv") && first.sources.count == 21)
        #expect(first.sources.map(\.path).contains("config/planning/weather-alert-keywords.csv"))
        #expect(first.summary.lirrStations == 126 && first.summary.unverifiedCitiBikePlans == ["dayPass", "reducedFare"])
        #expect(first.summary.planningSections == ConfigDocument.planningSectionKeys)
    }

    @Test func requiredReferencesFailWithoutTheirInputs() throws {
        let scratch = try ScratchDirectory()
        let report = try compiler(data: scratch.file("empty"), out: scratch.file("out"), require: true).run()
        #expect(report.errors == ["reference inputs missing: tt-subway.bin, tt-lirr.bin, tt-path.bin, stations.bin"])
        #expect(report.artifact == nil)
        #expect(!FileManager.default.fileExists(atPath: scratch.file("out").appendingPathComponent(MappedConfig.fileName).path))
    }

    @Test func aFailedRunLeavesNoEarlierArtifact() throws {
        // Downstream steps (links) read config.bin from the same directory: an older one left
        // beside a failed run would be built against as if it were current.
        let scratch = try ScratchDirectory()
        let out = scratch.file("out")
        let bin = out.appendingPathComponent(MappedConfig.fileName), xz = bin.appendingPathExtension("xz")
        func plant() throws {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: bin)
            try Data("old".utf8).write(to: xz)
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        // A reference error (exit 3).
        try plant()
        let failed = try compiler(data: scratch.file("empty"), out: out, require: true).run()
        #expect(failed.artifact == nil && !exists(bin) && !exists(xz))

        // A source error (exit 1): the run throws, and nothing old is left either.
        try plant()
        let data = try RepositoryData.copy(into: scratch)
        try Data("{".utf8).write(to: data.appendingPathComponent("config/app.json"))
        var configuration = compiler(data: nil, out: out).configuration
        configuration.sourcesDirectory = data
        #expect(throws: ConfigSourceError.self) { try ConfigCompiler(runner: ProcessToolRunner(), configuration: configuration).run() }
        #expect(!exists(bin) && !exists(xz))

        // A successful run without compression doesn't keep an older .xz beside the new file.
        try plant()
        let built = try compiler(data: nil, out: out).run()
        #expect(built.artifact != nil && exists(bin) && !exists(xz))
        #expect(try MappedConfig(contentsOf: bin).document == ConfigSources(root: RepositoryData.root).load())
    }

    @Test func aReferenceErrorWritesNoArtifact() throws {
        // A subway feed without the configured MTA stations.
        let world = try ReferenceFixtures.world()
        let data = world.scratch.file("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try world.bytes[.subway]!.write(to: data.appendingPathComponent(TimetableBuild.artifactFileName(.subway)))
        let out = world.scratch.file("out")
        let report = try compiler(data: data, out: out).run()
        #expect(report.artifact == nil)
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent(MappedConfig.fileName).path))
        #expect(report.errors.contains("fares.mta.outOfSystemTransfers: S:629 is not in the subway feed"))
        #expect(report.errors.contains("fares.mta.statenIslandRailway.fareStations: S:S31 is not in the subway feed"))
        #expect(report.inputs.keys.sorted() == ["tt-subway"])
        #expect(report.checks.first { $0.name == "lirrZones" }?.skipped == "tt-lirr.bin is missing")
    }

    @Test func comparesPricesWithDownloadedPricingPlans() throws {
        let scratch = try ScratchDirectory()
        let gbfs = scratch.file("gbfs")
        try FileManager.default.createDirectory(at: gbfs, withIntermediateDirectories: true)
        try Data(ReferenceFixtures.pricingPlans.utf8).write(to: gbfs.appendingPathComponent(ConfigCompiler.pricingPlansFileName))
        let report = try compiler(data: nil, out: scratch.file("out"), gbfs: gbfs).run()
        let pricing = try #require(report.checks.first { $0.name == "citiBikePricing" })
        #expect(pricing.skipped == nil && pricing.checked == 1 && pricing.warnings.isEmpty)

        let drifted = ReferenceFixtures.pricingPlans.replacingOccurrences(of: #""price":"4.99""#, with: #""price":"5.49""#)
        try Data(drifted.utf8).write(to: gbfs.appendingPathComponent(ConfigCompiler.pricingPlansFileName))
        let warned = try compiler(data: nil, out: scratch.file("out2"), gbfs: gbfs).run()
        #expect(warned.errors.isEmpty && warned.artifact != nil)
        #expect(warned.warnings.contains("GBFS EBIKE_SINGLE_RIDE price 5.49 ≠ fares.citiBike.plans.nonMember.unlockFeeCents 499"))
    }

    @Test func findsThePricingPlansURLInTheDiscoveryDocument() throws {
        let scratch = try ScratchDirectory()
        let discovery = scratch.file("gbfs.json")
        #expect(ConfigCompiler.pricingPlansURL(discovery: discovery) == ConfigCompiler.defaultPricingPlansURL)
        try Data(#"{"data":{"en":{"feeds":[{"name":"system_pricing_plans","url":"https://example.test/plans.json"}]}}}"#.utf8).write(to: discovery)
        #expect(ConfigCompiler.pricingPlansURL(discovery: discovery) == "https://example.test/plans.json")
    }
}

/// The compiler on a real built set. Opt in with `BR_DATA_DIR=<dir>` (e.g. build/data).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BR_DATA_DIR"] != nil))
struct RealDataConfigTests {
    @Test func everyReferenceCheckPassesOnTheBuiltSet() throws {
        let data = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BR_DATA_DIR"]), isDirectory: true)
        let scratch = try ScratchDirectory()
        var configuration = ConfigCompiler.Configuration(sourcesDirectory: RepositoryData.root, dataDirectory: data,
                                                         outputDirectory: scratch.file("out"))
        configuration.compress = false
        configuration.requireReferences = true
        let report = try ConfigCompiler(runner: ProcessToolRunner(), configuration: configuration).run()
        for check in report.checks {
            print("CONFIG check \(check.name): checked \(check.checked), errors \(check.errors), warnings \(check.warnings), skipped \(check.skipped ?? "-")")
        }
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.artifact != nil)
        let byName = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.name, $0) })
        #expect(byName["lirrZones"]?.checked ?? 0 > 100)
        #expect(byName["fixedTransfers"]?.checked == 6 && byName["mtaStationPairs"]?.checked == 4)
        #expect(byName["stationRegions"]?.checked ?? 0 > 2000)
    }
}
