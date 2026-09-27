import BRCore
import Foundation

/// A GTFS feed the pipeline downloads.
public struct GTFSFeedSpec: Sendable, Equatable {
    public var system: TransitSystem
    /// File stem under `sources/gtfs/`, e.g. `gtfs_b` → `gtfs_b.zip`.
    public var name: String
    public var url: String
    public var slot: String
    public var priority: Int
    /// A documented fallback: fetched and parsed only when a non-fallback feed of the same slot
    /// fails to download (or has no local zip). Per-date source selection then uses it only on
    /// dates the primary does not cover.
    public var isFallback: Bool

    public init(system: TransitSystem, name: String, url: String, slot: String, priority: Int = 0, isFallback: Bool = false) {
        self.system = system
        self.name = name
        self.url = url
        self.slot = slot
        self.priority = priority
        self.isFallback = isFallback
    }
}

public enum NYCFeeds {
    static let mta = "https://rrgtfsfeeds.s3.amazonaws.com/"

    /// Every feed, in source-selection order within each system.
    public static let all: [GTFSFeedSpec] = [
        // Supplemented (hourly, with near-term planned work) is preferred over the regular feed
        // on every date both cover.
        GTFSFeedSpec(system: .subway, name: "gtfs_supplemented", url: mta + "gtfs_supplemented.zip", slot: "subway", priority: 0),
        GTFSFeedSpec(system: .subway, name: "gtfs_subway", url: mta + "gtfs_subway.zip", slot: "subway", priority: 1),
        GTFSFeedSpec(system: .bus, name: "gtfs_bx", url: mta + "gtfs_bx.zip", slot: "gtfs_bx"),
        GTFSFeedSpec(system: .bus, name: "gtfs_b", url: mta + "gtfs_b.zip", slot: "gtfs_b"),
        GTFSFeedSpec(system: .bus, name: "gtfs_m", url: mta + "gtfs_m.zip", slot: "gtfs_m"),
        GTFSFeedSpec(system: .bus, name: "gtfs_q", url: mta + "gtfs_q.zip", slot: "gtfs_q"),
        GTFSFeedSpec(system: .bus, name: "gtfs_si", url: mta + "gtfs_si.zip", slot: "gtfs_si"),
        GTFSFeedSpec(system: .bus, name: "gtfs_busco", url: mta + "gtfs_busco.zip", slot: "gtfs_busco"),
        GTFSFeedSpec(system: .lirr, name: "gtfslirr", url: mta + "gtfslirr.zip", slot: "lirr"),
        // nyc.gov rejects requests without a browser-like User-Agent (403); www1 redirects here.
        GTFSFeedSpec(system: .ferry, name: "siferry", url: "https://www.nyc.gov/html/dot/downloads/misc/siferry-gtfs.zip", slot: "siferry"),
        // PANYNJ's current pick, published through the National RTAP GTFS Builder.
        GTFSFeedSpec(system: .path, name: "path", url: "https://rapid.nationalrtap.org/GTFSFileManagement/UserUploadFiles/14843/PATHGTFS.zip",
                     slot: "path", priority: 0),
        // The well-known Trillium feed, stale since 2026-06-01: kept only as a fallback.
        GTFSFeedSpec(system: .path, name: "path_trillium", url: "http://data.trilliumtransit.com/gtfs/path-nj-us/path-nj-us.zip",
                     slot: "path", priority: 1, isFallback: true),
    ]

    public static func feeds(for system: TransitSystem) -> [GTFSFeedSpec] {
        all.filter { $0.system == system }
    }
}

/// What is known about a downloaded source zip, stored next to it as `<name>.zip.json`.
public struct GTFSDownloadRecord: Codable, Sendable, Equatable {
    public var url: String
    public var etag: String
    public var lastModified: String
    /// ISO 8601 time of the last request (whether or not the file changed).
    public var checkedAt: String
    /// ISO 8601 time the current bytes were downloaded.
    public var downloadedAt: String
    public var bytes: Int
    /// `true` when the last request returned 304 Not Modified.
    public var notModified: Bool
}

/// Downloads feeds with conditional GETs (ETag, then If-Modified-Since) through `curl`.
///
/// `<directory>/<feed>.zip` is the current version. With an ``archive`` (the default,
/// `<directory>/archive`), every version the fetcher has held is kept there too: the current zip
/// is added before a download replaces it and the new one right after, so an older version stays
/// available for the dates a newer one no longer covers (``GTFSSourceArchive``).
public struct GTFSFetcher: Sendable {
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 bikeride-data"

    public let runner: any ToolRunner
    public let directory: URL
    /// Where versions are kept; `nil` keeps only the current zip.
    public var archive: GTFSSourceArchive?

    public init(runner: any ToolRunner, directory: URL) {
        self.runner = runner
        self.directory = directory
        self.archive = GTFSSourceArchive(directory: directory.appendingPathComponent("archive", isDirectory: true), runner: runner)
    }

    public func archiveURL(for feed: GTFSFeedSpec) -> URL {
        directory.appendingPathComponent("\(feed.name).zip")
    }

    public func recordURL(for feed: GTFSFeedSpec) -> URL {
        directory.appendingPathComponent("\(feed.name).zip.json")
    }

    public func record(for feed: GTFSFeedSpec) -> GTFSDownloadRecord? {
        guard let data = try? Data(contentsOf: recordURL(for: feed)) else { return nil }
        return try? JSONDecoder().decode(GTFSDownloadRecord.self, from: data)
    }

    /// Refreshes one feed. Returns its record; the zip is replaced only on a 200 response.
    @discardableResult
    public func fetch(_ feed: GTFSFeedSpec, now: Date = Date()) throws -> GTFSDownloadRecord {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = archiveURL(for: feed)
        let partial = directory.appendingPathComponent("\(feed.name).zip.partial")
        let headers = directory.appendingPathComponent("\(feed.name).zip.headers")
        let etagFile = directory.appendingPathComponent("\(feed.name).zip.etag")
        let haveArchive = FileManager.default.fileExists(atPath: archive.path)
        let previous = self.record(for: feed)
        // The zip about to be replaced must already be in the archive (it is, unless it was
        // downloaded before the archive existed).
        if haveArchive { try archiveCurrent(feed, record: previous, now: now) }
        var args = ["-sS", "-L", "--fail", "-R", "-A", Self.userAgent, "--retry", "2",
                    "-o", partial.path, "-D", headers.path, "-w", "%{http_code}"]
        if haveArchive {
            // If-None-Match from the saved ETag and If-Modified-Since from the file's mtime
            // (set from Last-Modified by -R).
            if FileManager.default.fileExists(atPath: etagFile.path) {
                args += ["--etag-compare", etagFile.path]
            }
            args += ["-z", archive.path]
        }
        args += ["--etag-save", etagFile.path + ".new", feed.url]
        defer {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: headers)
        }
        let output = try runner.run(executable: "curl", args: args)
        let status = Int(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let responseHeaders = (try? String(contentsOf: headers, encoding: .utf8)) ?? ""
        let iso = ISO8601DateFormatter()
        var record = self.record(for: feed) ?? GTFSDownloadRecord(
            url: feed.url, etag: "", lastModified: "", checkedAt: "", downloadedAt: "", bytes: 0, notModified: false)
        record.url = feed.url
        record.checkedAt = iso.string(from: now)
        let newETag = directory.appendingPathComponent("\(feed.name).zip.etag.new")
        switch status {
        case 304 where haveArchive:
            record.notModified = true
            try? FileManager.default.removeItem(at: newETag)
            if let etag = Self.lastHeader("etag", in: responseHeaders) { record.etag = etag }
            if let modified = Self.lastHeader("last-modified", in: responseHeaders) { record.lastModified = modified }
            if record.bytes == 0 {
                record.bytes = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
            }
        case 200:
            if FileManager.default.fileExists(atPath: archive.path) {
                try FileManager.default.removeItem(at: archive)
            }
            try FileManager.default.moveItem(at: partial, to: archive)
            if FileManager.default.fileExists(atPath: newETag.path) {
                if FileManager.default.fileExists(atPath: etagFile.path) { try FileManager.default.removeItem(at: etagFile) }
                try FileManager.default.moveItem(at: newETag, to: etagFile)
            }
            record.etag = Self.lastHeader("etag", in: responseHeaders) ?? ""
            record.lastModified = Self.lastHeader("last-modified", in: responseHeaders) ?? ""
            record.downloadedAt = iso.string(from: now)
            record.bytes = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
            record.notModified = false
            try archiveCurrent(feed, record: record, now: now)
        default:
            try? FileManager.default.removeItem(at: newETag)
            throw GTFSFetchError.unexpectedStatus(feed: feed.name, status: status)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: recordURL(for: feed))
        return record
    }

    /// Adds the current `<feed>.zip` to ``archive`` unless a version with its ETag and size, or
    /// (after hashing) its SHA-256, is already there.
    func archiveCurrent(_ feed: GTFSFeedSpec, record: GTFSDownloadRecord?, now: Date) throws {
        guard let archive else { return }
        let zip = archiveURL(for: feed)
        guard FileManager.default.fileExists(atPath: zip.path) else { return }
        let bytes = (try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        let etag = record?.etag ?? ""
        if !etag.isEmpty, try archive.records(feed: feed.name).contains(where: { $0.etag == etag && $0.bytes == bytes }) { return }
        try archive.add(zip: zip, feed: feed.name, url: feed.url, etag: etag, lastModified: record?.lastModified ?? "", now: now)
    }

    /// The value of the last occurrence of `name` (after redirects) in a curl `-D` dump.
    static func lastHeader(_ name: String, in dump: String) -> String? {
        var value: String?
        for line in dump.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == name {
                value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }

    /// The source identity recorded in artifacts: ETag and publish stamp of the local zip.
    public func sourceInfo(for feed: GTFSFeedSpec) -> GTFSSourceInfo {
        let record = record(for: feed)
        var published = ""
        if let lastModified = record?.lastModified, let date = Self.httpDate(lastModified) {
            published = ISO8601DateFormatter().string(from: date)
        } else if let date = try? FileManager.default.attributesOfItem(atPath: archiveURL(for: feed).path)[.modificationDate] as? Date {
            published = ISO8601DateFormatter().string(from: date)
        }
        var etag = record?.etag ?? ""
        if etag.isEmpty, let saved = try? String(contentsOf: directory.appendingPathComponent("\(feed.name).zip.etag"), encoding: .utf8) {
            etag = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return GTFSSourceInfo(name: feed.name, slot: feed.slot, priority: feed.priority, publishedAt: published, etag: etag)
    }

    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

public enum GTFSFetchError: Error, Equatable, CustomStringConvertible {
    case unexpectedStatus(feed: String, status: Int)

    public var description: String {
        switch self {
        case .unexpectedStatus(let feed, let status): "\(feed): download returned HTTP \(status)"
        }
    }
}
