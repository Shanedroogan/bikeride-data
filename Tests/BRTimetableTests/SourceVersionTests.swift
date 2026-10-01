import BRBuild
import BRCore
import BRData
import BRTimetable
import Foundation
import Testing

private let unzipInstalled = ProcessToolRunner().locate("unzip") != nil

/// The source archive (`sources/gtfs/archive/<feed>/<key>.zip`) and per-date selection among
/// versions of one feed, end to end through ``TimetableBuild`` and ``GTFSFetcher``.
@Suite(.enabled(if: unzipInstalled, "needs unzip on PATH")) struct SourceVersionTests {
    // MARK: Keys

    @Test func etagCleaningOnTheRealShapes() {
        let sha = String(repeating: "ab", count: 32)
        #expect(GTFSSourceArchive.key(etag: "\"c24d1ad9f012144677fbc32536b5216f-2\"", sha256: sha) == "c24d1ad9f012144677fbc32536b5216f-2")
        #expect(GTFSSourceArchive.key(etag: "\"8ad53c97c828dd1:0\"", sha256: sha) == "8ad53c97c828dd1_0")
        #expect(GTFSSourceArchive.key(etag: "\"6968f6d9-2589\"", sha256: sha) == "6968f6d9-2589")
        #expect(GTFSSourceArchive.key(etag: "\"9f103209cef591ba68f5fd0037c8583c\"", sha256: sha) == "9f103209cef591ba68f5fd0037c8583c")
        #expect(GTFSSourceArchive.key(etag: "W/\"aW5k/YWJj+==\"", sha256: sha) == "aW5k_YWJj___")
        // Never empty, never a dot file or a path.
        for unsafe in ["", "\"\"", "\".\"", "\"..\"", "\"...\"", "\".hidden\"", "W/\"\""] {
            #expect(GTFSSourceArchive.key(etag: unsafe, sha256: sha) == "sha256-abababababababab", "\(unsafe)")
        }
        #expect(GTFSSourceArchive.key(etag: "\"../../etc\"", sha256: sha) == "sha256-abababababababab")
        #expect(GTFSSourceArchive.key(etag: "\"a/../b\"", sha256: sha) == "a_.._b")
        let long = GTFSSourceArchive.key(etag: String(repeating: "x", count: 200), sha256: sha)
        #expect(long.count == 93 && long.hasSuffix("-abababababab"))
    }

    // MARK: Coverage and dominance

    @Test func coverageIsCalendarSpansAndAddedDates() throws {
        let scratch = try ScratchDirectory()
        let feed = try scratch.feed("cal", [
            "calendar.txt": """
                service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
                A,1,1,1,1,1,0,0,20261005,20261009
                B,0,0,0,0,0,1,1,20261010,20261011
                C,1,0,0,0,0,0,0,20261020,20261019
                """,
            "calendar_dates.txt": """
                service_id,date,exception_type
                X,20261101,1
                X,20261103,1
                X,20261103,2
                A,20261006,2
                """,
        ])
        let days = try GTFSSourceArchive.coverage(of: feed)
        let d = { (text: String) in Int32(date(text).daysSinceEpoch) }
        // A and B join; C is empty (start after end); 11/03 is removed by its last row.
        #expect(days == [d("20261005")...d("20261011"), d("20261101")...d("20261101")])
    }

    @Test func dominatedVersionsAreNotUseful() {
        let d = { (text: String) in Int32(date(text).daysSinceEpoch) }
        let start = d("20261005")
        let current = GTFSSourceArchive.Candidate(publishedAt: "2026-10-04T00:00:00Z", coverage: [d("20261005")...d("20261011")])
        let archived: [GTFSSourceArchive.Candidate] = [
            .init(publishedAt: "2026-10-01T00:00:00Z", coverage: [d("20261001")...d("20261016")]),   // 10/12–16 only it has
            .init(publishedAt: "2026-10-02T00:00:00Z", coverage: [d("20261003")...d("20261009")]),   // inside the current
            .init(publishedAt: "2026-09-20T00:00:00Z", coverage: [d("20260920")...d("20261004")]),   // ended before the window
            .init(publishedAt: "2026-10-05T00:00:00Z", coverage: [d("20261020")...d("20261021")]),   // newer than the current
            .init(publishedAt: "2026-09-30T00:00:00Z", coverage: [d("20261012")...d("20261014")]),   // under version 0
        ]
        #expect(GTFSSourceArchive.usefulVersions(current: current, archived: archived, windowStart: start) == [3, 0])
        // Without a current version, ranking alone decides.
        #expect(GTFSSourceArchive.usefulVersions(current: nil, archived: archived, windowStart: start) == [3, 1, 0])
    }

    // MARK: Per-date choice through TimetableBuild

    /// A newer version (10/05–10/11) and an older one (10/05–10/16) of the same feed, same slot and
    /// priority: each date takes the newest version covering it, and no date mixes both.
    @Test func olderArchivedVersionFillsOnlyTheDatesTheNewerLacks() throws {
        let scratch = try ScratchDirectory()
        let sources = scratch.url.appendingPathComponent("sources")
        let tree = try VersionedSources(root: sources)
        try tree.writeCurrent(VersionedSources.feed(trip: "NEW1", from: "20261005", to: "20261011"),
                              etag: "\"new-etag\"", lastModified: "Sun, 04 Oct 2026 12:00:00 GMT")
        let older = try tree.archive(VersionedSources.feed(trip: "OLD1", from: "20261005", to: "20261016"),
                                     etag: "\"6968f6d9-2589\"", lastModified: "Thu, 01 Oct 2026 12:00:00 GMT")
        #expect(older.key == "6968f6d9-2589")
        #expect(older.calendarStart == "20261005" && older.calendarEnd == "20261016")

        let (timetable, report, _) = try tree.build(scratch: scratch)
        #expect(timetable.sourceCount == 2)
        let current = timetable.source(0), archived = timetable.source(1)
        #expect(current.name == "ferry_test")
        #expect(archived.name == "ferry_test@6968f6d9")
        #expect(archived.etag == "\"6968f6d9-2589\"")
        #expect(current.selectedDates == (5...11).map { date(String(format: "202610%02d", $0)) })
        #expect(archived.selectedDates == (12...16).map { date(String(format: "202610%02d", $0)) })
        #expect(timetable.coveredDates.count == 12)
        for day in 5...16 {
            let serviceDate = date(String(format: "202610%02d", day))
            let view = timetable.dayView(for: serviceDate)
            var trips: [String] = []
            for pattern in 0..<timetable.patternCount {
                trips += view.activeTrips(inPattern: pattern).map { timetable.tripGTFSID(Int($0)) }
            }
            #expect(trips.sorted() == (day <= 11 ? ["NEW1", "NEW1b"] : ["OLD1", "OLD1b"]), "\(serviceDate)")
        }
        let stats = try #require(report.systems["tt-ferry"]?.stats.sources)
        #expect(stats.map(\.name) == ["ferry_test", "ferry_test@6968f6d9"])
        #expect(stats.map(\.datesSelected) == [7, 5])
        #expect(report.systems["tt-ferry"]?.tripCountsByDate.count == 12)
    }

    /// No archive, or an archive holding only a copy of the current zip: today's bytes exactly, and
    /// an offline build creates nothing under the sources.
    @Test func emptyArchiveGivesTodaysBehavior() throws {
        let scratch = try ScratchDirectory()
        let tree = try VersionedSources(root: scratch.url.appendingPathComponent("sources"))
        try tree.writeCurrent(VersionedSources.feed(trip: "NEW1", from: "20261005", to: "20261011"),
                              etag: "\"new-etag\"", lastModified: "Sun, 04 Oct 2026 12:00:00 GMT")
        let listingBefore = try tree.listing()
        let (plain, _, plainFile) = try tree.build(scratch: scratch, output: "plain")
        #expect(try tree.listing() == listingBefore, "an offline build wrote under the sources")
        #expect(!FileManager.default.fileExists(atPath: tree.gtfs.appendingPathComponent("archive").path))

        // The fetcher's copy of the current version is not a second version.
        try tree.archiveCurrentCopy(etag: "\"new-etag\"", lastModified: "Sun, 04 Oct 2026 12:00:00 GMT")
        let (withCopy, _, copyFile) = try tree.build(scratch: scratch, output: "copy")
        #expect(withCopy.sourceCount == 1)
        #expect(try Data(contentsOf: plainFile) == Data(contentsOf: copyFile))
        #expect(plain.source(0).name == "ferry_test")
    }

    /// Online, a version every date of which a newer one covers is deleted; offline it is only skipped.
    @Test func supersededVersionsArePrunedOnlyOnline() throws {
        let scratch = try ScratchDirectory()
        let tree = try VersionedSources(root: scratch.url.appendingPathComponent("sources"))
        try tree.writeCurrent(VersionedSources.feed(trip: "NEW1", from: "20261005", to: "20261016"),
                              etag: "\"new-etag\"", lastModified: "Sun, 04 Oct 2026 12:00:00 GMT")
        let superseded = try tree.archive(VersionedSources.feed(trip: "OLD1", from: "20261001", to: "20261012"),
                                          etag: "\"old-etag\"", lastModified: "Thu, 01 Oct 2026 12:00:00 GMT")
        let zip = tree.archiveStore.zipURL(feed: "ferry_test", key: superseded.key)

        let (offline, _, offlineFile) = try tree.build(scratch: scratch, output: "offline")
        #expect(offline.sourceCount == 1)
        #expect(FileManager.default.fileExists(atPath: zip.path))

        // Online with the server answering 304: the current zip is archived and the superseded one goes.
        let curl = FakeCurlRunner(responses: [.notModified])
        let (online, _, onlineFile) = try tree.build(scratch: scratch, output: "online", offline: false, runner: curl)
        #expect(online.sourceCount == 1)
        #expect(!FileManager.default.fileExists(atPath: zip.path))
        #expect(try tree.archiveStore.records(feed: "ferry_test").map(\.etag) == ["\"new-etag\""])
        #expect(try Data(contentsOf: offlineFile) == Data(contentsOf: onlineFile))
    }

    // MARK: Fetcher

    @Test func fetcherArchivesEveryVersionOnce() throws {
        let scratch = try ScratchDirectory()
        let gtfs = scratch.url.appendingPathComponent("gtfs")
        let v1 = StoredZip.make(VersionedSources.feed(trip: "T1", from: "20261005", to: "20261011"))
        let v2 = StoredZip.make(VersionedSources.feed(trip: "T2", from: "20261010", to: "20261020"))
        let curl = FakeCurlRunner(responses: [
            .ok(v1, etag: "\"8ad53c97c828dd1:0\"", lastModified: "Mon, 10 Aug 2026 13:03:08 GMT"),
            .notModified,
            .ok(v2, etag: "\"second-2\"", lastModified: "Tue, 01 Sep 2026 10:00:00 GMT"),
            // New ETag, same bytes: not a new version.
            .ok(v2, etag: "\"second-3\"", lastModified: "Wed, 02 Sep 2026 10:00:00 GMT"),
        ])
        let fetcher = GTFSFetcher(runner: curl, directory: gtfs)
        let spec = GTFSFeedSpec(system: .ferry, name: "ferry_test", url: "https://example.test/ferry.zip", slot: "ferry")
        let archive = try #require(fetcher.archive)

        try fetcher.fetch(spec)
        #expect(try archive.records(feed: "ferry_test").map(\.key) == ["8ad53c97c828dd1_0"])
        try fetcher.fetch(spec)
        #expect(try archive.records(feed: "ferry_test").count == 1)
        try fetcher.fetch(spec)
        let records = try archive.records(feed: "ferry_test")
        #expect(records.map(\.key) == ["8ad53c97c828dd1_0", "second-2"])
        #expect(try Data(contentsOf: fetcher.archiveURL(for: spec)) == v2)
        #expect(try Data(contentsOf: archive.zipURL(feed: "ferry_test", key: "8ad53c97c828dd1_0")) == v1)
        #expect(records.map(\.calendarEnd) == ["20261011", "20261020"])
        #expect(records[0].publishedAt == "2026-08-10T13:03:08Z")
        try fetcher.fetch(spec)
        #expect(try archive.records(feed: "ferry_test").count == 2)
        #expect(curl.remaining == 0)
    }

    /// A 200 whose body cannot be archived (a malformed calendar, an HTML error page) is kept as the
    /// current zip with its own record, and never stops a later fetch from reaching the server.
    @Test func aVersionThatCannotBeArchivedDoesNotStopLaterFetches() throws {
        let scratch = try ScratchDirectory()
        let gtfs = scratch.url.appendingPathComponent("gtfs")
        let v1 = StoredZip.make(VersionedSources.feed(trip: "T1", from: "20261005", to: "20261011"))
        // Same size as v1, so a stale record's ETag + size would pass for it.
        let badCalendar = StoredZip.make(VersionedSources.feed(trip: "T1", from: "20261005", to: "2026101X"))
        #expect(badCalendar.count == v1.count && badCalendar != v1)
        let html = Data("<html><body>Service Unavailable</body></html>\n".utf8)
        let v2 = StoredZip.make(VersionedSources.feed(trip: "T2", from: "20261010", to: "20261020"))
        let curl = FakeCurlRunner(responses: [
            .ok(v1, etag: "\"one\"", lastModified: "Mon, 10 Aug 2026 13:03:08 GMT"),
            .ok(badCalendar, etag: "\"two\"", lastModified: "Tue, 11 Aug 2026 13:03:08 GMT"),
            .ok(html, etag: "\"three\"", lastModified: "Wed, 12 Aug 2026 13:03:08 GMT"),
            .ok(v2, etag: "\"four\"", lastModified: "Thu, 13 Aug 2026 13:03:08 GMT"),
        ])
        let fetcher = GTFSFetcher(runner: curl, directory: gtfs)
        let spec = GTFSFeedSpec(system: .ferry, name: "ferry_test", url: "https://example.test/ferry.zip", slot: "ferry")
        let archive = try #require(fetcher.archive)
        var warnings: [String] = []
        let collect: (String) -> Void = { warnings.append($0) }

        try fetcher.fetch(spec, warn: collect)
        #expect(warnings.isEmpty)
        // The malformed version: the fetch succeeds, the record names the new bytes, nothing is archived.
        try fetcher.fetch(spec, warn: collect)
        #expect(try Data(contentsOf: fetcher.archiveURL(for: spec)) == badCalendar)
        #expect(fetcher.record(for: spec)?.etag == "\"two\"")
        #expect(fetcher.sourceInfo(for: spec).publishedAt == "2026-08-11T13:03:08Z")
        #expect(try archive.records(feed: "ferry_test").map(\.key) == ["one"])
        #expect(warnings.count == 1 && warnings[0].hasPrefix("ferry_test: current zip not archived"))
        // Not a zip at all: the old current and the new one both fail to archive, with warnings.
        try fetcher.fetch(spec, warn: collect)
        #expect(fetcher.record(for: spec)?.etag == "\"three\"")
        #expect(warnings.count == 3)
        // The server is fixed: the next fetch reaches it and archives the good version.
        try fetcher.fetch(spec, warn: collect)
        #expect(curl.remaining == 0)
        #expect(try Data(contentsOf: fetcher.archiveURL(for: spec)) == v2)
        #expect(fetcher.record(for: spec)?.etag == "\"four\"")
        #expect(try archive.records(feed: "ferry_test").map(\.key) == ["four", "one"])
        #expect(warnings.count == 4)   // only the HTML page, once more, before the download
    }

    @Test func versionPredatingTheArchiveIsKeptWhenReplaced() throws {
        let scratch = try ScratchDirectory()
        let gtfs = scratch.url.appendingPathComponent("gtfs")
        let v1 = StoredZip.make(VersionedSources.feed(trip: "T1", from: "20261005", to: "20261011"))
        let v2 = StoredZip.make(VersionedSources.feed(trip: "T2", from: "20261010", to: "20261020"))
        // Downloaded before the archive existed.
        var fetcher = GTFSFetcher(runner: FakeCurlRunner(responses: [.ok(v1, etag: "\"one\"", lastModified: "Mon, 10 Aug 2026 13:03:08 GMT")]),
                                  directory: gtfs)
        fetcher.archive = nil
        let spec = GTFSFeedSpec(system: .ferry, name: "ferry_test", url: "https://example.test/ferry.zip", slot: "ferry")
        try fetcher.fetch(spec)
        #expect(!FileManager.default.fileExists(atPath: gtfs.appendingPathComponent("archive").path))

        let archiving = GTFSFetcher(runner: FakeCurlRunner(responses: [.ok(v2, etag: "\"two\"", lastModified: "Tue, 01 Sep 2026 10:00:00 GMT")]),
                                    directory: gtfs)
        try archiving.fetch(spec)
        let records = try #require(archiving.archive).records(feed: "ferry_test")
        #expect(records.map(\.key) == ["one", "two"])
        #expect(records.map(\.lastModified) == ["Mon, 10 Aug 2026 13:03:08 GMT", "Tue, 01 Sep 2026 10:00:00 GMT"])
    }
}

// MARK: - Support

/// A `sources/` tree with one ferry-like feed: the current `gtfs/ferry_test.zip` and archived versions.
struct VersionedSources {
    let root: URL
    var gtfs: URL { root.appendingPathComponent("gtfs") }
    var archiveStore: GTFSSourceArchive { GTFSSourceArchive(directory: gtfs.appendingPathComponent("archive"), runner: ProcessToolRunner()) }
    static let spec = GTFSFeedSpec(system: .ferry, name: "ferry_test", url: "https://example.test/ferry.zip", slot: "ferry")

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("gtfs"), withIntermediateDirectories: true)
    }

    /// A two-stop ferry with trips `<trip>` and `<trip>b`, running every day in the range.
    static func feed(trip: String, from: String, to: String) -> [String: String] {
        [
            "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\nDOT,NYC DOT,http://example.test,America/New_York\n",
            "routes.txt": "route_id,agency_id,route_short_name,route_type\nSIF,DOT,SIF,4\n",
            "stops.txt": "stop_id,stop_name,stop_lat,stop_lon\nWH,Whitehall,40.701,-74.013\nSG,St George,40.643,-74.073\n",
            "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nALL,1,1,1,1,1,1,1,\(from),\(to)\n",
            "trips.txt": "route_id,trip_id,service_id\nSIF,\(trip),ALL\nSIF,\(trip)b,ALL\n",
            "stop_times.txt": """
                trip_id,stop_id,arrival_time,departure_time,stop_sequence
                \(trip),WH,08:00:00,08:00:00,1
                \(trip),SG,08:25:00,08:25:00,2
                \(trip)b,WH,09:00:00,09:00:00,1
                \(trip)b,SG,09:25:00,09:25:00,2
                """,
        ]
    }

    func writeCurrent(_ files: [String: String], etag: String, lastModified: String) throws {
        try StoredZip.make(files).write(to: gtfs.appendingPathComponent("ferry_test.zip"))
        let record: [String: Any] = ["url": Self.spec.url, "etag": etag, "lastModified": lastModified, "checkedAt": "",
                                     "downloadedAt": "", "bytes": 0, "notModified": false]
        try JSONSerialization.data(withJSONObject: record).write(to: gtfs.appendingPathComponent("ferry_test.zip.json"))
    }

    @discardableResult
    func archive(_ files: [String: String], etag: String, lastModified: String, feed: String = "ferry_test",
                 now: Date = Date()) throws -> GTFSSourceArchive.Record {
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: staging) }
        try StoredZip.make(files).write(to: staging)
        return try archiveStore.add(zip: staging, feed: feed, url: Self.spec.url, etag: etag, lastModified: lastModified, now: now)
    }

    func archiveCurrentCopy(etag: String, lastModified: String) throws {
        try archiveStore.add(zip: gtfs.appendingPathComponent("ferry_test.zip"), feed: "ferry_test", url: Self.spec.url,
                             etag: etag, lastModified: lastModified)
    }

    /// Every path under the sources with its size and modification time.
    func listing() throws -> [String] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        var entries: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            entries.append("\(url.path) \(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        return entries.sorted()
    }

    /// Builds tt-ferry from these sources with build day 2026-10-06 (window from 10/05).
    func build(scratch: ScratchDirectory, output: String = "out", offline: Bool = true,
               runner: any ToolRunner = ProcessToolRunner(), feeds: [GTFSFeedSpec] = [Self.spec]) throws -> (Timetable, TimetableBuildReport, URL) {
        let out = scratch.url.appendingPathComponent(output)
        var build = TimetableBuild(sourcesDirectory: root, outputDirectory: out, reportURL: nil, systems: [.ferry],
                                   offline: offline, today: date("20261006"), compress: false, runner: runner)
        build.feeds = [.ferry: feeds]
        let report = try build.run()
        let file = out.appendingPathComponent("tt-ferry.bin")
        return (try Timetable(contentsOf: file), report, file)
    }
}

/// A zip with stored (uncompressed) members, enough for `unzip -Z1` and `unzip -p`; CI has no `zip`.
enum StoredZip {
    static func make(_ files: [String: String]) -> Data {
        var out = Data(), central = Data()
        func le16(_ value: Int, _ data: inout Data) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
        func le32(_ value: UInt32, _ data: inout Data) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let dosDate = 0x21   // 1980-01-01
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            let body = Data(text.utf8), nameBytes = Data(name.utf8), crc = crc32(body), offset = UInt32(out.count)
            le32(0x0403_4B50, &out); le16(20, &out); le16(0, &out); le16(0, &out); le16(0, &out); le16(dosDate, &out)
            le32(crc, &out); le32(UInt32(body.count), &out); le32(UInt32(body.count), &out); le16(nameBytes.count, &out); le16(0, &out)
            out += nameBytes
            out += body
            le32(0x0201_4B50, &central); le16(20, &central); le16(20, &central); le16(0, &central); le16(0, &central); le16(0, &central)
            le16(dosDate, &central); le32(crc, &central); le32(UInt32(body.count), &central); le32(UInt32(body.count), &central)
            le16(nameBytes.count, &central); le16(0, &central); le16(0, &central); le16(0, &central); le16(0, &central)
            le32(0, &central); le32(offset, &central)
            central += nameBytes
        }
        let centralOffset = UInt32(out.count)
        out += central
        le32(0x0605_4B50, &out); le16(0, &out); le16(0, &out); le16(files.count, &out); le16(files.count, &out)
        le32(UInt32(central.count), &out); le32(centralOffset, &out); le16(0, &out)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

/// Answers `curl` from a queue of canned responses, writing the files the fetcher's flags name;
/// every other tool runs for real.
final class FakeCurlRunner: ToolRunner, @unchecked Sendable {
    enum Response {
        case ok(Data, etag: String, lastModified: String)
        case notModified
        /// curl exiting as `--fail` does on a 5xx, having written nothing.
        case fail
    }

    private let real = ProcessToolRunner()
    private let lock = NSLock()
    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    var remaining: Int {
        lock.lock()
        defer { lock.unlock() }
        return responses.count
    }

    func locate(_ executable: String) -> String? { executable == "curl" ? "/usr/bin/curl" : real.locate(executable) }

    func run(executable: String, args: [String], stdin: Data?) throws -> Data {
        guard executable == "curl" else { return try real.run(executable: executable, args: args, stdin: stdin) }
        lock.lock()
        let response = responses.isEmpty ? nil : responses.removeFirst()
        lock.unlock()
        guard let response else { throw ToolError.notFound(executable: "curl (no canned response left)") }
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        switch response {
        case .ok(let body, let etag, let lastModified):
            try body.write(to: URL(fileURLWithPath: value(after: "-o")!))
            try Data("HTTP/1.1 200 OK\r\nETag: \(etag)\r\nLast-Modified: \(lastModified)\r\n\r\n".utf8)
                .write(to: URL(fileURLWithPath: value(after: "-D")!))
            try Data("\(etag)\n".utf8).write(to: URL(fileURLWithPath: value(after: "--etag-save")!))
            return Data("200".utf8)
        case .notModified:
            try Data("HTTP/1.1 304 Not Modified\r\n\r\n".utf8).write(to: URL(fileURLWithPath: value(after: "-D")!))
            return Data("304".utf8)
        case .fail:
            throw ToolError.failed(executable: "curl", status: 22, stderr: "curl: (22) The requested URL returned error: 503")
        }
    }

    func stream(executable: String, args: [String], stdinFile: URL?) throws -> ToolStream {
        try real.stream(executable: executable, args: args, stdinFile: stdinFile)
    }
}
