import BRCore
import BRData
import Foundation

/// Every downloaded version of each GTFS feed, so the compiler can pick the newest version that
/// covers each service date (never merging two versions for one date).
///
/// Layout, under `sources/gtfs/archive/`: `<feed>/<key>.zip` plus `<feed>/<key>.json` (a
/// ``Record``). The flat `sources/gtfs/<feed>.zip` stays the current version, so a sources tree
/// without an `archive/` directory (the pinned Tier B fixtures) builds exactly as before. `<key>`
/// is the cleaned ETag (``key(etag:sha256:)``), which is also the R2 key `sources/<feed>/<key>.zip`
/// (M4 uploads this directory). Versions are deduplicated by the SHA-256 of the zip.
///
/// ``GTFSFetcher`` adds versions (the zip it is about to replace and the one it just downloaded);
/// ``TimetableBuild`` reads them through ``usefulVersions(current:archived:windowStart:horizonDays:)``
/// and, online only, deletes the versions that can no longer be selected on any date.
public struct GTFSSourceArchive: Sendable {
    /// What is known about one archived zip, stored as `<feed>/<key>.json`.
    public struct Record: Codable, Sendable, Equatable {
        public var feed: String
        public var key: String
        public var url: String
        public var etag: String
        public var lastModified: String
        public var sha256: String
        public var bytes: Int
        /// ISO 8601 time the version was added to the archive.
        public var archivedAt: String
        /// Service days the feed claims, merged and ascending: every `calendar.txt` range (its
        /// full span, whatever the weekdays) ∪ every `calendar_dates.txt` added date. The same
        /// rule the compiler uses to decide which versions cover a date.
        public var coverage: [DayRange]
        /// First and last day of ``coverage``, `YYYYMMDD` (nil for a feed with no calendar).
        public var calendarStart: String?
        public var calendarEnd: String?

        public init(feed: String, key: String, url: String, etag: String, lastModified: String, sha256: String, bytes: Int,
                    archivedAt: String, coverage: [DayRange]) {
            self.feed = feed
            self.key = key
            self.url = url
            self.etag = etag
            self.lastModified = lastModified
            self.sha256 = sha256
            self.bytes = bytes
            self.archivedAt = archivedAt
            self.coverage = coverage
            self.calendarStart = coverage.first?.first
            self.calendarEnd = coverage.last?.last
        }

        /// The sort stamp the compiler uses among versions of one feed: Last-Modified as ISO 8601,
        /// else the time it was archived.
        public var publishedAt: String {
            GTFSFetcher.httpDate(lastModified).map { ISO8601DateFormatter().string(from: $0) } ?? archivedAt
        }

        /// ``coverage`` as days since the epoch.
        public var coverageDays: [ClosedRange<Int32>] {
            coverage.compactMap { range in
                guard let first = ServiceDate(yyyymmdd: range.first), let last = ServiceDate(yyyymmdd: range.last) else { return nil }
                return Int32(first.daysSinceEpoch)...Int32(last.daysSinceEpoch)
            }
        }
    }

    /// An inclusive run of service days, `YYYYMMDD`.
    public struct DayRange: Codable, Sendable, Equatable {
        public var first: String
        public var last: String

        public init(first: String, last: String) {
            self.first = first
            self.last = last
        }

        public init(_ days: ClosedRange<Int32>) {
            first = ServiceDate(daysSinceEpoch: Int(days.lowerBound)).yyyymmdd
            last = ServiceDate(daysSinceEpoch: Int(days.upperBound)).yyyymmdd
        }
    }

    public let directory: URL
    public let runner: any ToolRunner

    public init(directory: URL, runner: any ToolRunner) {
        self.directory = directory
        self.runner = runner
    }

    public func feedDirectory(_ feed: String) -> URL { directory.appendingPathComponent(feed, isDirectory: true) }
    public func zipURL(feed: String, key: String) -> URL { feedDirectory(feed).appendingPathComponent("\(key).zip") }
    public func recordURL(feed: String, key: String) -> URL { feedDirectory(feed).appendingPathComponent("\(key).json") }

    /// The archived versions of `feed` whose zip is present, sorted by key. Reads only: a missing
    /// directory is an empty archive (nothing is created).
    public func records(feed: String) throws -> [Record] {
        let folder = feedDirectory(feed)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        var records: [Record] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() where name.hasSuffix(".json") {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
            guard record.feed == feed, "\(record.key).json" == name else {
                throw ArchiveError.inconsistentRecord(folder.appendingPathComponent(name).path)
            }
            guard FileManager.default.fileExists(atPath: zipURL(feed: feed, key: record.key).path) else { continue }
            records.append(record)
        }
        return records
    }

    /// Adds `zip` as a version of `feed` unless a version with the same SHA-256 is already
    /// archived; returns the record either way. `sha256` may be passed when already known.
    @discardableResult
    public func add(zip: URL, feed: String, url: String, etag: String, lastModified: String, sha256 knownSHA: String? = nil,
                    now: Date = Date()) throws -> Record {
        let sha = try knownSHA ?? ArtifactOutput.sha256(ofFileAt: zip, runner: runner)
        let existing = try records(feed: feed)
        if let same = existing.first(where: { $0.sha256 == sha }) { return same }
        var key = Self.key(etag: etag, sha256: sha)
        if existing.contains(where: { $0.key == key }) || FileManager.default.fileExists(atPath: recordURL(feed: feed, key: key).path) {
            key = "\(key)-\(sha.prefix(12))"   // the server reused an ETag for other bytes
        }
        let coverage = try Self.coverage(of: ZipGTFSFeed(archive: zip, runner: runner)).map(DayRange.init)
        let bytes = (try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        let record = Record(feed: feed, key: key, url: url, etag: etag, lastModified: lastModified, sha256: sha, bytes: bytes,
                            archivedAt: ISO8601DateFormatter().string(from: now), coverage: coverage)
        try FileManager.default.createDirectory(at: feedDirectory(feed), withIntermediateDirectories: true)
        let destination = zipURL(feed: feed, key: key)
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.copyItem(at: zip, to: partial)   // an APFS clone on the Mac
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: recordURL(feed: feed, key: key), options: .atomic)
        return record
    }

    /// Deletes one archived version (zip and record).
    public func remove(_ record: Record) throws {
        try? FileManager.default.removeItem(at: zipURL(feed: record.feed, key: record.key))
        try FileManager.default.removeItem(at: recordURL(feed: record.feed, key: record.key))
    }

    // MARK: Keys

    /// The archive key for a version: the ETag with `W/` and quotes dropped and every byte outside
    /// `[A-Za-z0-9._-]` mapped to `_` (`"8ad53c97c828dd1:0"` → `8ad53c97c828dd1_0`). A key that
    /// would be empty, start with a dot (`.`, `..`) or run past 96 characters is replaced or cut and
    /// suffixed from the zip's SHA-256, so every key is a plain, safe file name.
    public static func key(etag: String, sha256: String) -> String {
        var text = Substring(etag.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("W/") { text = text.dropFirst(2) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var key = String(text.filter { $0 != "\"" }.map { allowed.contains($0) ? $0 : "_" })
        if key.isEmpty || key.hasPrefix(".") { return "sha256-\(sha256.prefix(16))" }
        if key.count > 96 { key = "\(key.prefix(80))-\(sha256.prefix(12))" }
        return key
    }

    // MARK: Coverage

    /// The days a feed claims service, as the compiler counts them for source selection: each
    /// service's `calendar.txt` span (the last row per `service_id` wins) ∪ each date whose last
    /// `calendar_dates.txt` row for its service is `exception_type` 1. Merged and ascending.
    public static func coverage(of files: some GTFSFeedFiles) throws -> [ClosedRange<Int32>] {
        var spans: [String: ClosedRange<Int32>] = [:]
        try files.forEachRecord(in: "calendar.txt", required: false) { header, record, number in
            guard let id = header.index(of: "service_id"), let start = header.index(of: "start_date"), let end = header.index(of: "end_date") else {
                throw GTFSError.missingColumn(feed: files.location, file: "calendar.txt", column: "service_id/start_date/end_date")
            }
            guard let first = GTFSField.day(record[start].bytes), let last = GTFSField.day(record[end].bytes) else {
                throw GTFSError.invalidValue(feed: files.location, file: "calendar.txt", record: number, column: "start_date/end_date",
                                             value: GTFSField.string(record[start].bytes))
            }
            let service = GTFSField.string(record[id].bytes)
            if first <= last { spans[service] = first...last } else { spans[service] = nil }
        }
        var exceptions: [String: [Int32: Int]] = [:]
        try files.forEachRecord(in: "calendar_dates.txt", required: false) { header, record, number in
            guard let id = header.index(of: "service_id"), let date = header.index(of: "date"), let type = header.index(of: "exception_type") else {
                throw GTFSError.missingColumn(feed: files.location, file: "calendar_dates.txt", column: "service_id/date/exception_type")
            }
            guard let day = GTFSField.day(record[date].bytes), let value = GTFSField.int(record[type].bytes) else {
                throw GTFSError.invalidValue(feed: files.location, file: "calendar_dates.txt", record: number, column: "date/exception_type",
                                             value: GTFSField.string(record[date].bytes))
            }
            exceptions[GTFSField.string(record[id].bytes), default: [:]][day] = value
        }
        var ranges = Array(spans.values)
        for days in exceptions.values {
            for (day, type) in days where type == 1 { ranges.append(day...day) }
        }
        return merged(ranges)
    }

    /// Sorted, with overlapping or adjacent ranges joined.
    static func merged(_ ranges: [ClosedRange<Int32>]) -> [ClosedRange<Int32>] {
        var result: [ClosedRange<Int32>] = []
        for range in ranges.sorted(by: { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }) {
            if let last = result.last, range.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: Selection

    /// One version of a feed as the compiler will rank it.
    public struct Candidate: Sendable, Equatable {
        public var publishedAt: String
        public var coverage: [ClosedRange<Int32>]

        public init(publishedAt: String, coverage: [ClosedRange<Int32>]) {
            self.publishedAt = publishedAt
            self.coverage = coverage
        }
    }

    /// The indices of `archived` worth passing to the compiler, in the order to pass them (after
    /// the current version): those that cover some day in `[windowStart, windowStart + horizonDays)`
    /// that no version ranked before them covers.
    ///
    /// Ranking is the compiler's among versions of one feed (same slot and priority): newer
    /// `publishedAt` first, then the order passed, with the current version first. The compiler
    /// picks, per date, the first ranked version covering it, so a version every date of which is
    /// covered by a better-ranked one is never selected. Leaving it out changes nothing but the
    /// source table (no zero-date rows), and it stays dominated as the window moves on, so online
    /// builds delete it. This retention rule replaces "keep until the calendar ends": the
    /// supplemented subway feed is republished hourly with an end date a month out, and keeping
    /// every version until its end date would hold dozens of 19 MB zips that are never used.
    public static func usefulVersions(current: Candidate?, archived: [Candidate], windowStart: Int32,
                                      horizonDays: Int = 800) -> [Int] {
        let end = windowStart + Int32(horizonDays)   // exclusive
        let order = archived.indices.sorted { a, b in
            if archived[a].publishedAt != archived[b].publishedAt { return archived[a].publishedAt > archived[b].publishedAt }
            return a < b
        }
        // Versions newer than the current one rank before it; the rest after.
        var covered = Set<Int32>()
        func claims(_ candidate: Candidate) -> [Int32] {
            candidate.coverage.flatMap { range -> [Int32] in
                let from = max(range.lowerBound, windowStart), to = min(range.upperBound, end - 1)
                return from <= to ? Array(from...to) : []
            }
        }
        var useful: [Int] = []
        var currentPlaced = current == nil
        for index in order {
            if !currentPlaced, let current, !(archived[index].publishedAt > current.publishedAt) {
                covered.formUnion(claims(current))
                currentPlaced = true
            }
            let days = claims(archived[index])
            if days.contains(where: { !covered.contains($0) }) { useful.append(index) }
            covered.formUnion(days)
        }
        return useful
    }

    public enum ArchiveError: Error, Equatable, CustomStringConvertible {
        case inconsistentRecord(String)

        public var description: String {
            switch self {
            case .inconsistentRecord(let path): "\(path): archive record does not match its file name or feed"
            }
        }
    }
}

/// One version of a feed as the timetable build parses it: the current flat zip, or an archived one.
public struct GTFSSourceVersion: Sendable {
    public var spec: GTFSFeedSpec
    public var zip: URL
    public var source: GTFSSourceInfo
    /// The archive key, or nil for the current `sources/gtfs/<feed>.zip`.
    public var archiveKey: String?
}
