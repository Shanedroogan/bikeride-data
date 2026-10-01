import Foundation

/// Geofabrik's extracts, with the dated fallback for a failed `-latest` download.
///
/// Geofabrik publishes each region daily as `<region>-latest.osm.pbf` and keeps the same file
/// under its data date, `<region>-<YYMMDD>.osm.pbf`. When `-latest` cannot be fetched (it was in
/// a redirect loop on 2026-10-01 at about 04:06Z while the dated files served normally), the dated
/// file of the day before `now` is tried, then the day before that, in UTC (Geofabrik's dates). The
/// dated file is saved under the same local name, so the build reads it the same way; its source
/// record names the URL it came from.
public enum GeofabrikExtract {
    /// How many days back the fallback tries: yesterday, then the day before.
    public static let fallbackDays = 2

    /// `…/new-york-latest.osm.pbf` → `…/new-york-260930.osm.pbf` for 2026-09-30 (UTC); nil for a
    /// URL that does not end in `-latest.osm.pbf`.
    public static func datedURL(latest: String, day: Date) -> String? {
        let suffix = "-latest.osm.pbf"
        guard latest.hasSuffix(suffix) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let date = parts.day else { return nil }
        return String(latest.dropLast(suffix.count)) + String(format: "-%02d%02d%02d.osm.pbf", year % 100, month, date)
    }

    /// The dated URLs to try after `latest` fails, newest first: the days before `now`.
    public static func fallbackURLs(latest: String, now: Date) -> [String] {
        (1...fallbackDays).compactMap { datedURL(latest: latest, day: now.addingTimeInterval(-86_400 * Double($0))) }
    }

    /// Fetches `latest` into `file`, falling back to ``fallbackURLs(latest:now:)`` in order when
    /// it fails (not offline: offline there is nothing to try). A fallback that works adds a
    /// warning; when every one fails, the `-latest` error is thrown, unless `useCached` is set and
    /// `file` already holds an extract: that one is then used, with a warning and the status
    /// `cached`. `useCached` is the Mac fallback's `--cached-extracts` (a seeded `--sources`); CI
    /// leaves it off and restores the last published streets instead.
    ///
    /// A dated fetch is conditional like any other: against a cached file newer than the dated
    /// one the server may answer 304, and the cached file (at least as new) is kept.
    public static func fetch(_ latest: String, to file: URL, fetcher: SourceFetcher, now: Date, useCached: Bool = false,
                             warnings: inout [String], log: (String) -> Void) throws -> SourceRecord {
        do {
            return try fetcher.fetch(latest, to: file)
        } catch {
            guard !fetcher.offline else { throw error }
            log("  warning: \(latest) failed (\(error))")
            var tried: [String] = []
            for url in fallbackURLs(latest: latest, now: now) {
                log("fetching \(url) (dated fallback)")
                do {
                    let record = try fetcher.fetch(url, to: file)
                    warnings.append("\(latest) failed (\(error)); used the dated extract \(url)"
                        + (tried.isEmpty ? "" : " after \(tried.joined(separator: ", ")) failed"))
                    log("  warning: \(warnings.last!)")
                    return record
                } catch let fallbackError {
                    log("  warning: \(url) failed (\(fallbackError))")
                    tried.append(url)
                }
            }
            guard useCached, FileManager.default.fileExists(atPath: file.path) else { throw error }
            warnings.append("\(latest) failed (\(error)), and so did \(tried.joined(separator: ", ")); used the cached extract "
                + "\(file.lastPathComponent) (--cached-extracts)")
            log("  warning: \(warnings.last!)")
            var record = try SourceFetcher(runner: fetcher.runner, offline: true).fetch(latest, to: file)
            record.status = "cached"
            return record
        }
    }
}
