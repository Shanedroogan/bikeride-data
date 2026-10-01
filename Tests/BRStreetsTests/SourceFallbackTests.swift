@testable import BRBuild
import BRCore
import Foundation
import Testing

/// Stands in for `curl` as ``SourceFetcher`` calls it: a URL `fails` picks exits as curl does
/// after too many redirects (Geofabrik's `-latest` loop of 2026-10-01); any other is answered
/// 200 with `body`. Every URL asked for is recorded, in order. Other tools run for real.
final class CurlStub: ToolRunner, @unchecked Sendable {
    let fails: @Sendable (String) -> Bool
    let body: Data
    private let lock = NSLock()
    private var asked: [String] = []
    let real = ProcessToolRunner()

    init(body: Data = Data("fresh".utf8), fails: @escaping @Sendable (String) -> Bool) {
        self.body = body
        self.fails = fails
    }

    var requested: [String] { lock.withLock { asked } }

    func locate(_ executable: String) -> String? {
        executable == "curl" ? "curl" : real.locate(executable)
    }

    func run(executable: String, args: [String], stdin: Data?) throws -> Data {
        guard executable == "curl" else { return try real.run(executable: executable, args: args, stdin: stdin) }
        let url = try #require(args.last)
        lock.withLock { asked.append(url) }
        if fails(url) { throw ToolError.failed(executable: "curl", status: 47, stderr: "curl: (47) Maximum (50) redirects followed") }
        let output = try #require(args.firstIndex(of: "--output").map { args[$0 + 1] })
        try body.write(to: URL(fileURLWithPath: output))
        return Data("200".utf8)
    }

    func stream(executable: String, args: [String], stdinFile: URL?) throws -> ToolStream {
        try real.stream(executable: executable, args: args, stdinFile: stdinFile)
    }
}

@Suite struct GeofabrikFallbackTests {
    static let latest = StreetsCompiler.osmURL
    /// 2026-10-01 00:30 UTC: still 2026-09-30 in New York, already the 1st in Tokyo; the dated
    /// names count back from the UTC day whatever the process's time zone.
    static let now = Date(timeIntervalSince1970: 1_790_814_600)

    @Test func datedNamesAreUTCDays() throws {
        #expect(GeofabrikExtract.datedURL(latest: Self.latest, day: Self.now)
            == "https://download.geofabrik.de/north-america/us/new-york-261001.osm.pbf")
        #expect(GeofabrikExtract.fallbackURLs(latest: Self.latest, now: Self.now) == [
            "https://download.geofabrik.de/north-america/us/new-york-260930.osm.pbf",
            "https://download.geofabrik.de/north-america/us/new-york-260929.osm.pbf",
        ])
        #expect(GeofabrikExtract.fallbackURLs(latest: StreetsCompiler.njOSMURL, now: Self.now).first
            == "https://download.geofabrik.de/north-america/us/new-jersey-260930.osm.pbf")
        #expect(GeofabrikExtract.datedURL(latest: StreetsCompiler.boroughsURL, day: Self.now) == nil)
    }

    @Test func aFailedLatestFallsBackToYesterdayThenTheDayBefore() throws {
        let scratch = try ScratchDirectory()
        let file = scratch.file("osm/new-york-latest.osm.pbf")
        let runner = CurlStub { $0.hasSuffix("-latest.osm.pbf") || $0.hasSuffix("-260930.osm.pbf") }
        var warnings: [String] = []
        let record = try GeofabrikExtract.fetch(Self.latest, to: file, fetcher: SourceFetcher(runner: runner, offline: false),
                                                now: Self.now, warnings: &warnings, log: { _ in })
        #expect(runner.requested == [Self.latest] + GeofabrikExtract.fallbackURLs(latest: Self.latest, now: Self.now))
        #expect(record.url == "https://download.geofabrik.de/north-america/us/new-york-260929.osm.pbf" && record.status == "downloaded")
        #expect(try Data(contentsOf: file) == Data("fresh".utf8))
        #expect(warnings.count == 1 && warnings[0].contains("used the dated extract https://download.geofabrik.de/north-america/us/new-york-260929.osm.pbf after https://download.geofabrik.de/north-america/us/new-york-260930.osm.pbf failed"),
                "\(warnings)")
    }

    @Test func yesterdayIsEnoughWhenItWorks() throws {
        let scratch = try ScratchDirectory()
        let runner = CurlStub { $0.hasSuffix("-latest.osm.pbf") }
        var warnings: [String] = []
        let record = try GeofabrikExtract.fetch(Self.latest, to: scratch.file("osm/ny.osm.pbf"), fetcher: SourceFetcher(runner: runner, offline: false),
                                                now: Self.now, warnings: &warnings, log: { _ in })
        #expect(runner.requested.count == 2 && record.url.hasSuffix("-260930.osm.pbf") && warnings.count == 1)
    }

    @Test func aWorkingLatestTriesNothingElse() throws {
        let scratch = try ScratchDirectory()
        let runner = CurlStub { _ in false }
        var warnings: [String] = []
        let record = try GeofabrikExtract.fetch(Self.latest, to: scratch.file("osm/ny.osm.pbf"), fetcher: SourceFetcher(runner: runner, offline: false),
                                                now: Self.now, warnings: &warnings, log: { _ in })
        #expect(runner.requested == [Self.latest] && record.url == Self.latest && warnings.isEmpty)
    }

    /// Every URL fails: the `-latest` error is the one reported, and a cached extract is not used
    /// (the workflow restores the last published streets instead).
    @Test func whenEveryDateFailsTheLatestErrorStands() throws {
        let scratch = try ScratchDirectory()
        let file = scratch.file("osm/ny.osm.pbf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: file)
        let runner = CurlStub { _ in true }
        var warnings: [String] = []
        #expect(throws: ToolError.failed(executable: "curl", status: 47, stderr: "curl: (47) Maximum (50) redirects followed")) {
            try GeofabrikExtract.fetch(Self.latest, to: file, fetcher: SourceFetcher(runner: runner, offline: false),
                                       now: Self.now, warnings: &warnings, log: { _ in })
        }
        #expect(runner.requested.count == 3 && warnings.isEmpty)
        #expect(try Data(contentsOf: file) == Data("cached".utf8))
    }

    @Test func offlineThereIsNothingToFallBackTo() throws {
        let scratch = try ScratchDirectory()
        let file = scratch.file("osm/ny.osm.pbf")
        let runner = CurlStub { _ in false }
        var warnings: [String] = []
        #expect(throws: SourceFetcher.FetchError.missingOffline(path: file.path)) {
            try GeofabrikExtract.fetch(Self.latest, to: file, fetcher: SourceFetcher(runner: runner, offline: true),
                                       now: Self.now, warnings: &warnings, log: { _ in })
        }
        #expect(runner.requested.isEmpty)
    }
}

@Suite struct BoroughBoundariesFallbackTests {
    /// A failed download uses the file already there (CI restores the last good copy), marked
    /// `cached`, with a warning.
    @Test func aFailedDownloadUsesTheCachedFile() throws {
        let scratch = try ScratchDirectory()
        let file = scratch.file("nyc/borough-boundaries-water-included.geojson")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file)
        let runner = CurlStub { _ in true }
        var warnings: [String] = []
        let record = try StreetsCompiler.fetchBoroughs(to: file, fetcher: SourceFetcher(runner: runner, offline: false), warnings: &warnings, log: { _ in })
        #expect(record.status == "cached" && record.bytes == 2 && record.url == StreetsCompiler.boroughsURL)
        #expect(warnings.count == 1 && warnings[0].hasPrefix("borough boundaries not refreshed (curl exited with status 47") && warnings[0].hasSuffix("; using the cached file"))
        #expect(try Data(contentsOf: file) == Data("{}".utf8))
    }

    @Test func withoutACachedFileTheErrorStands() throws {
        let scratch = try ScratchDirectory()
        let runner = CurlStub { _ in true }
        var warnings: [String] = []
        #expect(throws: ToolError.self) {
            try StreetsCompiler.fetchBoroughs(to: scratch.file("nyc/b.geojson"), fetcher: SourceFetcher(runner: runner, offline: false),
                                              warnings: &warnings, log: { _ in })
        }
        #expect(warnings.isEmpty)
    }

    @Test func aWorkingDownloadIsUsed() throws {
        let scratch = try ScratchDirectory()
        let file = scratch.file("nyc/b.geojson")
        let runner = CurlStub { _ in false }
        var warnings: [String] = []
        let record = try StreetsCompiler.fetchBoroughs(to: file, fetcher: SourceFetcher(runner: runner, offline: false), warnings: &warnings, log: { _ in })
        #expect(try record.status == "downloaded" && warnings.isEmpty && Data(contentsOf: file) == Data("fresh".utf8))
    }
}
