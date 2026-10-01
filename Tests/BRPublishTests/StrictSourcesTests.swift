@testable import BRBuild
import BRCore
import Foundation
import Testing

/// `--strict-sources`: the subway is never built without its entrances. Offline, the synthetic
/// sources have no entrances file, which is what a fresh runner has when the restore step could
/// not put the last good copy there.
@Suite(.enabled(if: publishToolsInstalled, "needs xz and unzip on PATH"))
struct StrictSourcesTests {
    static func build(_ sources: SyntheticSources, strict: Bool) -> TimetableBuild {
        var build = TimetableBuild(sourcesDirectory: sources.sources, outputDirectory: sources.root.appendingPathComponent("data"),
                                   reportURL: nil, systems: [.subway], offline: true, today: SyntheticSources.today, runner: SyntheticSources.runner)
        build.feeds = SyntheticSources.feedSpecs
        build.strictSources = strict
        return build
    }

    static let header = "Division,Line,Borough,Stop Name,Complex ID,Constituent Station Name,Station ID,GTFS Stop ID,Daytime Routes,"
        + "Entrance Type,Entry Allowed,Exit Allowed,Entrance Latitude,Entrance Longitude,entrance_georeference\n"

    func writeEntrances(_ sources: SyntheticSources, _ text: String) throws {
        let file = Self.build(sources, strict: false).entrancesFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @Test func withoutEntrancesTheSubwayBuildsWithAWarningUnlessStrict() throws {
        let sources = try SyntheticSources()
        let report = try Self.build(sources, strict: false).run()
        let warnings = try #require(report.systems["tt-subway"]?.warnings)
        #expect(warnings.count == 1 && warnings[0].hasPrefix("subway entrances unavailable (") && warnings[0].hasSuffix("; built without entrances"))

        #expect {
            try Self.build(sources, strict: true).run()
        } throws: { error in
            guard case .builtWithoutEntrances(let why) = error as? TimetableBuild.SourceError else { return false }
            return why == warnings[0] && "\(error)".hasSuffix("(--strict-sources: the subway is not built without entrances)")
        }
    }

    /// A cached file with no usable rows is no better than none.
    @Test func anEmptyEntrancesFileIsNoEntrances() throws {
        let sources = try SyntheticSources()
        try writeEntrances(sources, Self.header)
        let report = try Self.build(sources, strict: false).run()
        #expect(report.systems["tt-subway"]?.warnings == ["subway entrances file subway-entrances.csv has no usable rows; built without entrances"])
        #expect(throws: TimetableBuild.SourceError.self) { try Self.build(sources, strict: true).run() }
    }

    /// With the cached file (offline: as CI uses the restored last good copy) a strict build goes on.
    @Test func theCachedFileIsEnough() throws {
        let sources = try SyntheticSources()
        let alpha = SyntheticSources.coordinate(2, 2)
        try writeEntrances(sources, Self.header
            + "IRT,Test,M,Alpha,1,Alpha,1,SA,1,Stair,YES,YES,\(alpha.lat),\(alpha.lon),\n")
        let report = try Self.build(sources, strict: true).run()
        let subway = try #require(report.systems["tt-subway"])
        #expect(subway.warnings.isEmpty && subway.entrancesSource?.rows == 1 && subway.entrancesSource?.status == "offline")
    }
}
