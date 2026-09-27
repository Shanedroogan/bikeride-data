@testable import BRBuild
import BRCore
import Foundation
import Testing

/// Canned S3 ListObjectsV2 pages shaped like the real `tripdata` bucket's (2026-09-26).
private enum Listing {
    static func contents(_ key: String, etag: String, size: Int, extra: String = "") -> String {
        "<Contents><Key>\(key)</Key><LastModified>2026-09-10T15:28:32.000Z</LastModified><ETag>&quot;\(etag)&quot;</ETag>\(extra)<Size>\(size)</Size><StorageClass>STANDARD</StorageClass></Contents>"
    }

    static let checksum = "<ChecksumAlgorithm>CRC64NVME</ChecksumAlgorithm><ChecksumType>FULL_OBJECT</ChecksumType>"

    static func page(_ contents: [String], truncated: Bool, token: String? = nil) -> Data {
        let tokenElement = token.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? ""
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>tripdata</Name><Prefix></Prefix>\
            <KeyCount>\(contents.count)</KeyCount><MaxKeys>1000</MaxKeys><IsTruncated>\(truncated)</IsTruncated>\(tokenElement)\
            \(contents.joined())</ListBucketResult>
            """.utf8)
    }

    static let first = page([
        contents("2013-citibike-tripdata.zip", etag: "2f86b47b991b0d9832e1013299b51ff5-20", size: 329_797_836),
        contents("202606-citibike-tripdata.zip", etag: "4b4c2bfa76263debb934be4e041151da-62", size: 1_051_241_498, extra: checksum),
        contents("202607-citibike-tripdata.zip", etag: "4fa3e242a9a52ef644a464a84dc93fb1-57", size: 974_302_094, extra: checksum),
        contents("202608-citibike-tripdata.zip", etag: "d5f2a3ec3831ad8ef2de3da12102e550-60", size: 1_024_034_405, extra: checksum),
        contents("JC-201708 citibike-tripdata.csv.zip", etag: "aa", size: 10),
        contents("JC-202207-citbike-tripdata.csv.zip", etag: "bb", size: 11),
    ], truncated: true, token: "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")

    static let second = page([
        contents("JC-202606-citibike-tripdata.csv.zip", etag: "fd4826276b99f206603a4107a379f320", size: 3_703_598, extra: checksum),
        contents("JC-202607-citibike-tripdata.csv.zip", etag: "b1ebf3e37db3975444306eb555ffca2a", size: 3_878_108, extra: checksum),
        contents("JC-202608-citibike-tripdata.zip", etag: "9a861581e94ae783d52f32de84163f25", size: 3_994_745, extra: checksum),
        contents("index.html", etag: "0a0a71d28229db9a3ddd27b9c9ca1f10", size: 6_430),
    ], truncated: false)
}

@Suite struct TripSourcesTests {
    @Test func parsesPagesWithExtraChildElementsAndEntities() throws {
        let page = try TripSources.parseListing(Listing.first)
        #expect(page.objects.count == 6)
        #expect(page.nextContinuationToken == "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
        let august = try #require(page.objects.first { $0.key == "202608-citibike-tripdata.zip" })
        #expect(august.etag == "d5f2a3ec3831ad8ef2de3da12102e550-60" && august.size == 1_024_034_405)
        #expect(august.lastModified == "2026-09-10T15:28:32.000Z")
        #expect(page.objects.contains { $0.key == "JC-201708 citibike-tripdata.csv.zip" })
        let last = try TripSources.parseListing(Listing.second)
        #expect(last.objects.count == 4 && last.nextContinuationToken == nil)
        // Children in any order, and entities in keys.
        let odd = Data("<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Size>5</Size><Owner><ID>x</ID></Owner><ETag>\"e\"</ETag><Key>a&amp;b&#x20;c&#39;.zip</Key></Contents></ListBucketResult>".utf8)
        #expect(try TripSources.parseListing(odd).objects == [TripListingObject(key: "a&b c'.zip", etag: "e", size: 5, lastModified: "")])
        #expect(throws: TripSources.ListingError.self) { try TripSources.parseListing(Data("<Error><Code>AccessDenied</Code></Error>".utf8)) }
        #expect(throws: TripSources.ListingError.self) {
            try TripSources.parseListing(Data("<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>".utf8))
        }
    }

    @Test func recognizesMonthlyNamesOnly() {
        let nyc = TripSources.recognize("202608-citibike-tripdata.zip")
        #expect(nyc?.system == .nyc && nyc?.month == TripMonth(year: 2026, month: 8))
        #expect(TripSources.recognize("202401-citibike-tripdata.csv.zip")?.system == .nyc)
        #expect(TripSources.recognize("JC-202608-citibike-tripdata.csv.zip")?.system == .jc)
        #expect(TripSources.recognize("JC-202604-citibike-tripdata.zip")?.month == TripMonth(year: 2026, month: 4))
        #expect(TripSources.recognize("JC-201708 citibike-tripdata.csv.zip")?.month == TripMonth(year: 2017, month: 8))
        #expect(TripSources.recognize("JC-202207-citbike-tripdata.csv.zip")?.month == TripMonth(year: 2022, month: 7))
        for other in ["2013-citibike-tripdata.zip", "index.html", "202613-citibike-tripdata.zip", "JC-2026-citibike-tripdata.zip",
                      "202608-citibike-tripdata.csv", "202608-citibike-tripdata.tar.zip", "XX-202608-citibike-tripdata.zip"] {
            #expect(TripSources.recognize(other) == nil, "\(other)")
        }
    }

    @Test func choosesTheNewestMonthsPublishedForBothSystems() throws {
        var objects = try TripSources.parseListing(Listing.first).objects + TripSources.parseListing(Listing.second).objects
        objects.append(TripListingObject(key: "202609-citibike-tripdata.zip", etag: "new", size: 1, lastModified: ""))
        let files = try TripSources.monthlyFiles(objects)
        let months = (6...8).map { TripMonth(year: 2026, month: $0) }
        // NYC has 202609, JC not yet: the window still ends with 202608.
        #expect(TripSources.choose(files) == .window(months))
        #expect(TripSources.files(of: months, in: files).map(\.object.key) == [
            "JC-202606-citibike-tripdata.csv.zip", "202606-citibike-tripdata.zip",
            "JC-202607-citibike-tripdata.csv.zip", "202607-citibike-tripdata.zip",
            "JC-202608-citibike-tripdata.zip", "202608-citibike-tripdata.zip",
        ])
        let pins = TripSources.pins(of: months, in: files)
        #expect(pins[5] == "NYC202608:d5f2a3ec3831ad8ef2de3da12102e550-60:1024034405")
        // Fail soft: the flows in place already ends with 202608 from the same inputs.
        let august = TripMonth(year: 2026, month: 8)
        #expect(TripSources.choose(files, previousEnd: august, previousPins: pins) == .nothingNew(newest: august))
        #expect(TripSources.choose(files, previousEnd: august) == .nothingNew(newest: august))
        #expect(TripSources.choose(files, previousEnd: TripMonth(year: 2026, month: 9)) == .nothingNew(newest: august))
        // A re-published month (new ETag) is new input.
        var republished = pins
        republished[1] = "NYC202606:other:1"
        #expect(TripSources.choose(files, previousEnd: august, previousPins: republished) == .window(months))
        #expect(TripSources.choose(files, previousEnd: TripMonth(year: 2026, month: 7)) == .window(months))
        // A hole in one system's series, and a system with nothing.
        let holey = try TripSources.monthlyFiles(objects.filter { $0.key != "JC-202607-citibike-tripdata.csv.zip" })
        #expect(TripSources.choose(holey) == .missing(["JC 202607"]))
        let nycOnly = try TripSources.monthlyFiles(objects.filter { !$0.key.hasPrefix("JC-") })
        #expect(TripSources.choose(nycOnly) == .noCommonMonth)
        // One month under two keys is for a human to sort out.
        #expect(throws: TripSources.ListingError.self) {
            try TripSources.monthlyFiles(objects + [TripListingObject(key: "JC-202608-citibike-tripdata.csv.zip", etag: "x", size: 1, lastModified: "")])
        }
    }

    @Test func percentEncodesKeysInDownloadURLs() throws {
        let files = try TripSources.monthlyFiles(try TripSources.parseListing(Listing.first).objects)
        let spaced = try #require(files[.jc]?[TripMonth(year: 2017, month: 8)])
        #expect(spaced.url == "https://s3.amazonaws.com/tripdata/JC-201708%20citibike-tripdata.csv.zip")
        #expect(files[.nyc]?[TripMonth(year: 2026, month: 8)]?.url == "https://s3.amazonaws.com/tripdata/202608-citibike-tripdata.zip")
    }

    @Test func monthArithmetic() throws {
        let january = try #require(TripMonth(yyyymm: "202601"))
        #expect(january.adding(-1) == TripMonth(year: 2025, month: 12) && january.adding(13) == TripMonth(year: 2027, month: 2))
        #expect(TripMonth(year: 2026, month: 2).lastDay == ServiceDate(year: 2026, month: 2, day: 28))
        #expect(TripMonth(year: 2028, month: 2).lastDay == ServiceDate(year: 2028, month: 2, day: 29))
        #expect(TripMonth(yyyymm: "202600") == nil && TripMonth(yyyymm: "2026") == nil && TripMonth(yyyymm: "20260a") == nil)
        #expect(try JSONDecoder().decode([TripMonth].self, from: JSONEncoder().encode([january])) == [january])
    }
}

#if os(macOS) || os(Linux)
/// Stands in for `curl`: serves canned bodies by URL (with an ETag header for `--dump-header`).
private final class FakeCurl: ToolRunner, @unchecked Sendable {
    let bodies: [String: Data]
    let etags: [String: String]
    private let lock = NSLock()
    private(set) var requested: [String] = []

    init(bodies: [String: Data], etags: [String: String] = [:]) {
        self.bodies = bodies
        self.etags = etags
    }

    func locate(_ executable: String) -> String? { executable }

    func run(executable: String, args: [String], stdin: Data?) throws -> Data {
        guard executable == "curl", let url = args.last else { throw ToolError.notFound(executable: executable) }
        lock.lock()
        requested.append(url)
        lock.unlock()
        guard let body = bodies[url] else { throw ToolError.failed(executable: "curl", status: 22, stderr: "404 \(url)") }
        guard let output = args.firstIndex(of: "--output").map({ args[$0 + 1] }) else { return body }
        try body.write(to: URL(fileURLWithPath: output))
        if let headers = args.firstIndex(of: "--dump-header").map({ args[$0 + 1] }) {
            try Data("HTTP/1.1 200 OK\r\nETag: \"\(etags[url] ?? "")\"\r\n\r\n".utf8).write(to: URL(fileURLWithPath: headers))
        }
        return Data("200".utf8)
    }

    func stream(executable: String, args: [String], stdinFile: URL?) throws -> ToolStream {
        throw ToolError.notFound(executable: executable)
    }
}

@Suite struct TripCacheTests {
    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("brtrips-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func followsContinuationTokensAndSavesTheListing() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = "1ueGcxLPRx1Tr%2FXYExHnhbYLgveDs2J%2Fwm36Hy4vbOwM%3D"
        let curl = FakeCurl(bodies: [
            TripCache.listingURL: Listing.first,
            TripCache.listingURL + "&continuation-token=" + token: Listing.second,
        ])
        let listing = try TripCache(directory: directory, runner: curl, offline: false).listing()
        #expect(listing.objects.count == 10 && curl.requested.count == 2)
        let saved = try TripCache(directory: directory, runner: FakeCurl(bodies: [:]), offline: true).listing()
        #expect(saved == listing)
        #expect(throws: TripCache.CacheError.noListing(path: directory.appendingPathComponent("none/listing.json").path)) {
            try TripCache(directory: directory.appendingPathComponent("none"), runner: curl, offline: true).listing()
        }
    }

    @Test func checksCachedFilesAgainstTheListing() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let object = TripListingObject(key: "JC-202608-citibike-tripdata.csv.zip", etag: "9a86", size: 5, lastModified: "")
        let source = TripSourceFile(system: .jc, month: TripMonth(year: 2026, month: 8), object: object)
        #expect(throws: TripCache.CacheError.notCached(key: object.key)) {
            try TripCache(directory: directory, runner: FakeCurl(bodies: [:]), offline: true).fetch(source)
        }
        let good = FakeCurl(bodies: [source.url: Data("12345".utf8)], etags: [source.url: "9a86"])
        let record = try TripCache(directory: directory, runner: good, offline: false).fetch(source)
        #expect(record.bytes == 5 && record.etag == "\"9a86\"" && record.path == directory.appendingPathComponent(object.key).path)
        #expect(try TripCache(directory: directory, runner: good, offline: true).fetch(source).status == "offline")
        let changed = FakeCurl(bodies: [source.url: Data("12345".utf8)], etags: [source.url: "other"])
        #expect(throws: TripCache.CacheError.self) { try TripCache(directory: directory, runner: changed, offline: false).fetch(source) }
        let short = FakeCurl(bodies: [source.url: Data("1234".utf8)], etags: [source.url: "9a86"])
        #expect(throws: TripCache.CacheError.self) { try TripCache(directory: directory, runner: short, offline: false).fetch(source) }
        var unsafe = source
        unsafe.object.key = "../x.zip"
        #expect(throws: TripCache.CacheError.unsafeKey("../x.zip")) { try TripCache(directory: directory, runner: good, offline: true).fetch(unsafe) }
    }
}
#endif
