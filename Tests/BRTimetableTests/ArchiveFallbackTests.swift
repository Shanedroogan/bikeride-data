import BRBuild
import BRCore
import BRData
import BRTimetable
import Foundation
import Testing

private let unzipInstalled = ProcessToolRunner().locate("unzip") != nil

/// A feed with no fallback spec whose download fails is built from its last good archived copy
/// (``TimetableBuild/archivedCopy(of:fetcher:reasons:)``): what a fresh CI runner has after
/// restore-state.sh put R2's `sources/` into `sources/gtfs/archive/`, with no flat zip beside it.
/// The build day is 2026-10-06 (``VersionedSources/build(scratch:output:offline:runner:feeds:)``).
@Suite(.enabled(if: unzipInstalled, "needs unzip on PATH")) struct ArchiveFallbackTests {
    static let version = VersionedSources.feed(trip: "V1", from: "20261005", to: "20261020")
    static let etag = "\"v-etag\""
    static let lastModified = "Sun, 04 Oct 2026 12:00:00 GMT"

    static func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    static let newerEtag = "\"n-etag\""
    static let newerLastModified = "Mon, 05 Oct 2026 12:00:00 GMT"

    /// A sources tree holding only an archived copy of `files` (``version`` by default), first
    /// archived at `archivedAt`.
    static func restored(_ scratch: ScratchDirectory, archivedAt: String,
                         files: [String: String] = version) throws -> (VersionedSources, GTFSSourceArchive.Record) {
        let tree = try VersionedSources(root: scratch.url.appendingPathComponent("sources"))
        let record = try tree.archive(files, etag: etag, lastModified: lastModified, now: at(archivedAt))
        return (tree, record)
    }

    static func expectNoArchivedCopy(_ body: () throws -> Void, reason: String,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(sourceLocation: sourceLocation) {
            try body()
        } throws: { error in
            guard case .noArchivedCopy(let feed, let download, let reasons) = error as? TimetableBuild.SourceError else { return false }
            return feed == "ferry_test" && download.hasPrefix("curl exited with status 22")
                && reasons.contains { $0.contains(reason) }
                && "\(error)".hasPrefix("ferry_test not refreshed (curl exited with status 22")
        }
    }

    @Test func aFailedDownloadIsBuiltFromTheArchivedCopy() throws {
        let scratch = try ScratchDirectory()
        let (tree, record) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z")
        let before = try tree.listing()

        let curl = FakeCurlRunner(responses: [.fail])
        let (timetable, report, file) = try tree.build(scratch: scratch, output: "cached", offline: false, runner: curl)
        #expect(curl.remaining == 0)
        #expect(timetable.sourceCount == 1 && timetable.source(0).name == "ferry_test" && timetable.source(0).etag == Self.etag)
        #expect(timetable.coveredDates.count == 16)

        let ferry = try #require(report.systems["tt-ferry"])
        let source = try #require(ferry.stats.sources.first)
        #expect(source.status == "cached")
        #expect(source.archivedAt == "2026-10-03T12:00:00Z" && source.archiveKey == record.key && record.key == "v-etag")
        #expect(source.publishedAt == "2026-10-04T12:00:00Z")
        #expect(ferry.warnings.count == 1)
        #expect(ferry.warnings[0].hasPrefix("ferry_test not refreshed (curl exited with status 22"))
        #expect(ferry.warnings[0].hasSuffix("; using the archived copy v-etag, first archived 2026-10-03T12:00:00Z; no previous set to compare it with"))
        // The archived copy is read where it is: nothing under the sources changes.
        #expect(try tree.listing() == before)

        // The same bytes as a build where that version downloaded.
        let fresh = try ScratchDirectory()
        let downloaded = try VersionedSources(root: fresh.url.appendingPathComponent("sources"))
        let ok = FakeCurlRunner(responses: [.ok(StoredZip.make(Self.version), etag: Self.etag, lastModified: Self.lastModified)])
        let (_, freshReport, freshFile) = try downloaded.build(scratch: fresh, output: "fresh", offline: false, runner: ok)
        #expect(try Data(contentsOf: file) == Data(contentsOf: freshFile))
        #expect(freshReport.systems["tt-ferry"]?.stats.sources.first?.status == nil)
    }

    /// The newest version by Last-Modified that passes is used; the newer copies refused on the way
    /// are named in the warning, not passed to the compiler, and not deleted.
    @Test func theLastGoodCopyIsTheNewestThatPasses() throws {
        let scratch = try ScratchDirectory()
        let (tree, older) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z")
        let newer = try tree.archive(VersionedSources.feed(trip: "N1", from: "20261005", to: "20261025"), etag: Self.newerEtag,
                                     lastModified: Self.newerLastModified, now: Self.at("2026-10-05T12:00:00Z"))
        let newerZip = tree.archiveStore.zipURL(feed: "ferry_test", key: newer.key)
        try Self.flipOneByte(newerZip)

        let (timetable, report, _) = try tree.build(scratch: scratch, offline: false, runner: FakeCurlRunner(responses: [.fail]))
        #expect(timetable.sourceCount == 1 && timetable.source(0).etag == Self.etag)
        let ferry = try #require(report.systems["tt-ferry"])
        #expect(ferry.stats.sources.map(\.archiveKey) == [older.key])
        #expect(ferry.warnings.count == 1 && ferry.warnings[0].contains("using the archived copy v-etag"))
        #expect(ferry.warnings[0].hasSuffix("(archived copy n-etag does not match its record's SHA-256: not used)"))
        #expect(FileManager.default.fileExists(atPath: newerZip.path))
    }

    /// Of two good copies the newer by Last-Modified is the current version, under the feed's own
    /// name; the older one is still a candidate for the window day only it covers.
    @Test func theNewestOfTwoGoodCopiesIsUsed() throws {
        let scratch = try ScratchDirectory()
        let (tree, older) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z",
                                              files: VersionedSources.feed(trip: "V1", from: "20261001", to: "20261020"))
        let newer = try tree.archive(VersionedSources.feed(trip: "N1", from: "20261006", to: "20261025"), etag: Self.newerEtag,
                                     lastModified: Self.newerLastModified, now: Self.at("2026-10-05T12:00:00Z"))

        let (timetable, report, _) = try tree.build(scratch: scratch, offline: false, runner: FakeCurlRunner(responses: [.fail]))
        let sources = (0..<timetable.sourceCount).map { (timetable.source($0).name, timetable.source($0).etag) }
        #expect(sources.first { $0.0 == "ferry_test" }?.1 == Self.newerEtag)
        #expect(sources.first { $0.0 == "ferry_test@v-etag" }?.1 == Self.etag)
        let ferry = try #require(report.systems["tt-ferry"])
        let current = try #require(ferry.stats.sources.first { $0.name == "ferry_test" })
        #expect(current.status == "cached" && current.archiveKey == newer.key && current.publishedAt == "2026-10-05T12:00:00Z")
        #expect(older.key == "v-etag")
        let candidate = try #require(ferry.stats.sources.first { $0.name == "ferry_test@v-etag" })
        #expect(candidate.status == nil && candidate.publishedAt == "2026-10-04T12:00:00Z")
        #expect(ferry.warnings.count == 1 && ferry.warnings[0].contains("using the archived copy n-etag, first archived 2026-10-05T12:00:00Z"))
    }

    /// When a copy was first archived does not matter: a feed that has not changed upstream keeps
    /// its first date (the bus feeds, the subway and the ferry, first archived 2026-09-27), and its
    /// copy is still the current version.
    @Test func aCopyFirstArchivedLongAgoIsUsed() throws {
        let scratch = try ScratchDirectory()
        let (tree, record) = try Self.restored(scratch, archivedAt: "2026-06-01T12:00:00Z",
                                               files: VersionedSources.feed(trip: "V1", from: "20260601", to: "20270102"))
        let (_, report, _) = try tree.build(scratch: scratch, offline: false, runner: FakeCurlRunner(responses: [.fail]),
                                            liveSources: ["ferry_test": Self.etag])
        let ferry = try #require(report.systems["tt-ferry"])
        #expect(ferry.stats.sources.map(\.status) == ["cached"] && ferry.stats.sources.map(\.archiveKey) == [record.key])
        #expect(ferry.warnings.count == 1 && ferry.warnings[0].hasSuffix("; using the archived copy v-etag, first archived 2026-06-01T12:00:00Z"))
    }

    /// A copy must have service on at least 3 days from the build day (the gate's minDays):
    /// 10-06 to 10-07 is refused, 10-06 to 10-08 is used.
    @Test func aCopyWithUnderThreeDaysLeftIsNotUsed() throws {
        let scratch = try ScratchDirectory()
        let (tree, _) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z",
                                          files: VersionedSources.feed(trip: "V1", from: "20261001", to: "20261007"))
        Self.expectNoArchivedCopy({
            _ = try tree.build(scratch: scratch, offline: false, runner: FakeCurlRunner(responses: [.fail]))
        }, reason: "archived copy v-etag has service to 20261007, under 3 days from 20261006: not used")
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("out/tt-ferry.bin").path))

        let edge = try ScratchDirectory()
        let (edgeTree, _) = try Self.restored(edge, archivedAt: "2026-10-03T12:00:00Z",
                                              files: VersionedSources.feed(trip: "V1", from: "20261001", to: "20261008"))
        let (_, report, _) = try edgeTree.build(scratch: edge, offline: false, runner: FakeCurlRunner(responses: [.fail]))
        #expect(report.systems["tt-ferry"]?.stats.sources.first?.status == "cached")
    }

    /// The live set was built from the newer version, whose archived copy is damaged: the older
    /// copy would publish a schedule older than the live one, so it is not used.
    @Test func aCopyOlderThanTheLiveVersionIsNotUsed() throws {
        let scratch = try ScratchDirectory()
        let (tree, _) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z")
        let newer = try tree.archive(VersionedSources.feed(trip: "N1", from: "20261005", to: "20261025"), etag: Self.newerEtag,
                                     lastModified: Self.newerLastModified, now: Self.at("2026-10-05T12:00:00Z"))
        try Self.flipOneByte(tree.archiveStore.zipURL(feed: "ferry_test", key: newer.key))
        Self.expectNoArchivedCopy({
            _ = try tree.build(scratch: scratch, offline: false, runner: FakeCurlRunner(responses: [.fail]),
                               liveSources: ["ferry_test": Self.newerEtag])
        }, reason: "archived copies older than n-etag, the version the live set was built from, are not used")
    }

    /// The live set was built from a version the archive does not hold (its sources upload
    /// failed): the copies cannot be placed against it, so none is used.
    @Test func aLiveVersionMissingFromTheArchiveStopsTheFallback() throws {
        let scratch = try ScratchDirectory()
        let (tree, _) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z")
        Self.expectNoArchivedCopy({
            _ = try tree.build(scratch: scratch, offline: false, runner: FakeCurlRunner(responses: [.fail]),
                               liveSources: ["ferry_test": Self.newerEtag])
        }, reason: "the live set was built from ferry_test with ETag \"n-etag\", which the archive does not hold")
    }

    /// A copy newer than the live version is used; so is the live version's own copy, and a
    /// previous set without the feed only says so.
    @Test func theLiveVersionOrANewerCopyIsUsed() throws {
        func build(live: [String: String]) throws -> TimetableSystemReport {
            let scratch = try ScratchDirectory()
            let (tree, _) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z")
            try tree.archive(VersionedSources.feed(trip: "N1", from: "20261005", to: "20261025"), etag: Self.newerEtag,
                             lastModified: Self.newerLastModified, now: Self.at("2026-10-05T12:00:00Z"))
            let (_, report, _) = try tree.build(scratch: scratch, offline: false, runner: FakeCurlRunner(responses: [.fail]), liveSources: live)
            return try #require(report.systems["tt-ferry"])
        }
        for live in [Self.etag, Self.newerEtag] {
            let ferry = try build(live: ["ferry_test": live])
            #expect(ferry.stats.sources.first?.archiveKey == "n-etag", "\(live)")
            #expect(ferry.warnings.count == 1 && ferry.warnings[0].hasSuffix("; using the archived copy n-etag, first archived 2026-10-05T12:00:00Z"))
        }
        let other = try build(live: ["other_feed": Self.etag])
        #expect(other.stats.sources.first?.archiveKey == "n-etag")
        #expect(other.warnings.count == 1 && other.warnings[0].hasSuffix("; the previous set has no ferry_test to compare it with"))
    }

    @Test func aTruncatedCopyIsNotUsed() throws {
        let scratch = try ScratchDirectory()
        let (tree, record) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z")
        let zip = tree.archiveStore.zipURL(feed: "ferry_test", key: record.key)
        try Data(contentsOf: zip).prefix(record.bytes / 2).write(to: zip)
        Self.expectNoArchivedCopy({
            _ = try tree.build(scratch: scratch, offline: false, runner: FakeCurlRunner(responses: [.fail]))
        }, reason: "archived copy v-etag has \(record.bytes / 2) bytes, its record \(record.bytes): not used")
    }

    @Test func aCopyNotMatchingItsHashIsNotUsed() throws {
        let scratch = try ScratchDirectory()
        let (tree, record) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z")
        try Self.flipOneByte(tree.archiveStore.zipURL(feed: "ferry_test", key: record.key))
        Self.expectNoArchivedCopy({
            _ = try tree.build(scratch: scratch, offline: false, runner: FakeCurlRunner(responses: [.fail]))
        }, reason: "archived copy v-etag does not match its record's SHA-256: not used")
    }

    /// A record that vouches for bytes that are not a zip (its size and hash match them).
    @Test func aCopyThatIsNotAZipIsNotUsed() throws {
        let scratch = try ScratchDirectory()
        let (tree, record) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z")
        let html = Data("<html><body>Service Unavailable</body></html>\n".utf8)
        try html.write(to: tree.archiveStore.zipURL(feed: "ferry_test", key: record.key))
        var forged = record
        forged.bytes = html.count
        forged.sha256 = try ProcessHasher(runner: ProcessToolRunner()).sha256(of: html).hex
        try JSONEncoder().encode(forged).write(to: tree.archiveStore.recordURL(feed: "ferry_test", key: record.key))
        Self.expectNoArchivedCopy({
            _ = try tree.build(scratch: scratch, offline: false, runner: FakeCurlRunner(responses: [.fail]))
        }, reason: "archived copy v-etag does not read as a GTFS zip")
    }

    @Test func noArchivedCopyFailsAsBefore() throws {
        let scratch = try ScratchDirectory()
        let tree = try VersionedSources(root: scratch.url.appendingPathComponent("sources"))
        Self.expectNoArchivedCopy({
            _ = try tree.build(scratch: scratch, offline: false, runner: FakeCurlRunner(responses: [.fail]))
        }, reason: "the archive holds no copy of ferry_test")
    }

    /// A download that works never reads the archived copy as the current version, and an
    /// unchanged version leaves the archive exactly as it was.
    @Test func aWorkingDownloadLeavesTheArchiveAlone() throws {
        let scratch = try ScratchDirectory()
        let (tree, _) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z")
        let archiveListing = { try tree.listing().filter { $0.contains("/gtfs/archive/") } }
        let before = try archiveListing()
        let ok = FakeCurlRunner(responses: [.ok(StoredZip.make(Self.version), etag: Self.etag, lastModified: Self.lastModified)])
        let (timetable, report, _) = try tree.build(scratch: scratch, offline: false, runner: ok)
        #expect(ok.remaining == 0 && timetable.sourceCount == 1)
        let ferry = try #require(report.systems["tt-ferry"])
        #expect(ferry.stats.sources.map(\.status) == [nil] && ferry.stats.sources.map(\.archiveKey) == [nil])
        #expect(ferry.warnings.isEmpty)
        #expect(try archiveListing() == before)
    }

    /// A slot with a fallback spec still goes to that spec, never to the archive.
    @Test func aSlotWithAFallbackSpecKeepsIt() throws {
        let scratch = try ScratchDirectory()
        let (tree, _) = try Self.restored(scratch, archivedAt: "2026-10-03T12:00:00Z")
        let fallback = GTFSFeedSpec(system: .ferry, name: "ferry_fallback", url: "https://example.test/fallback.zip", slot: "ferry",
                                    priority: 1, isFallback: true)
        let curl = FakeCurlRunner(responses: [
            .fail,
            .ok(StoredZip.make(VersionedSources.feed(trip: "F1", from: "20261005", to: "20261012")), etag: "\"f\"",
                lastModified: "Sat, 03 Oct 2026 12:00:00 GMT"),
        ])
        let (_, report, _) = try tree.build(scratch: scratch, offline: false, runner: curl, feeds: [VersionedSources.spec, fallback])
        let ferry = try #require(report.systems["tt-ferry"])
        #expect(ferry.stats.sources.map(\.name) == ["ferry_fallback"])
        #expect(ferry.stats.sources.allSatisfy { $0.status == nil })
        #expect(ferry.warnings.count == 1 && ferry.warnings[0].hasSuffix("; using the fallback"))
    }

    static func flipOneByte(_ url: URL) throws {
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: url)
    }
}
