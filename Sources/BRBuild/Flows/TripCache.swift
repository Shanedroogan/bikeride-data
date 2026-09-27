import BRCore
import Foundation

/// The local cache of Citi Bike trip zips (default `build/trips`, never in a repository): the
/// bucket listing as `listing.json`, and each zip under its exact bucket key with the
/// ``SourceFetcher`` records beside it. A zip is fetched with a conditional GET, so a re-run gets
/// `304 Not Modified`; whatever is cached must match the listing's ETag and size.
public struct TripCache: Sendable {
    public enum CacheError: Error, Equatable, CustomStringConvertible {
        /// `--offline` and no saved listing: nothing to choose months from.
        case noListing(path: String)
        /// `--offline` and a zip the window needs is not cached.
        case notCached(key: String)
        /// The cached or downloaded file is not the object the listing describes.
        case mismatch(key: String, what: String)
        case unsafeKey(String)
        case listingPages(Int)

        public var description: String {
            switch self {
            case .noListing(let path): "no saved tripdata listing at \(path) (run once without --offline)"
            case .notCached(let key): "\(key) is not cached and --offline forbids downloading it"
            case .mismatch(let key, let what): "\(key): \(what)"
            case .unsafeKey(let key): "refusing bucket key '\(key)' as a file name"
            case .listingPages(let pages): "tripdata listing did not end after \(pages) pages"
            }
        }
    }

    /// What `listing.json` holds.
    public struct SavedListing: Codable, Sendable, Equatable {
        public var fetchedAt: String
        public var url: String
        public var objects: [TripListingObject]
    }

    public let directory: URL
    public let runner: any ToolRunner
    public let offline: Bool
    public static let listingURL = TripSources.bucketURL + "?list-type=2"
    static let maxListingPages = 100

    public init(directory: URL, runner: any ToolRunner, offline: Bool) {
        self.directory = directory
        self.runner = runner
        self.offline = offline
    }

    public var listingFile: URL { directory.appendingPathComponent("listing.json") }

    /// The bucket listing: every page, fetched now and saved (or, offline, the saved one).
    public func listing() throws -> SavedListing {
        if offline {
            guard let data = try? Data(contentsOf: listingFile) else { throw CacheError.noListing(path: listingFile.path) }
            return try JSONDecoder().decode(SavedListing.self, from: data)
        }
        var objects: [TripListingObject] = []
        var token: String?
        var pages = 0
        repeat {
            pages += 1
            guard pages <= Self.maxListingPages else { throw CacheError.listingPages(Self.maxListingPages) }
            var url = Self.listingURL
            if let token {
                url += "&continuation-token=" + (token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token)
            }
            let body = try runner.run(executable: "curl", args: [
                "--silent", "--show-error", "--fail", "--location", "--retry", "3", "--connect-timeout", "30", url,
            ])
            let page = try TripSources.parseListing(body)
            objects += page.objects
            token = page.nextContinuationToken
        } while token != nil
        let saved = SavedListing(fetchedAt: SourceRecord.isoFormatter.string(from: Date()), url: Self.listingURL, objects: objects)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(saved).write(to: listingFile, options: .atomic)
        return saved
    }

    public func file(for source: TripSourceFile) throws -> URL {
        let key = source.object.key
        guard !key.isEmpty, !key.contains("/"), !key.hasPrefix(".") else { throw CacheError.unsafeKey(key) }
        return directory.appendingPathComponent(key)
    }

    /// Ensures the zip for `source` is cached and is the listed object (same size, and the same
    /// ETag when the server or an earlier download reported one).
    public func fetch(_ source: TripSourceFile) throws -> SourceRecord {
        let url = try file(for: source)
        let record: SourceRecord
        do {
            record = try SourceFetcher(runner: runner, offline: offline).fetch(source.url, to: url)
        } catch SourceFetcher.FetchError.missingOffline {
            throw CacheError.notCached(key: source.object.key)
        }
        guard record.bytes == source.object.size else {
            throw CacheError.mismatch(key: source.object.key, what: "\(record.bytes) bytes cached, the listing says \(source.object.size)")
        }
        if let etag = record.etag.map(Self.unquoted), !source.object.etag.isEmpty, etag != source.object.etag {
            throw CacheError.mismatch(key: source.object.key, what: "ETag \(etag), the listing says \(source.object.etag)")
        }
        return record
    }

    static func unquoted(_ etag: String) -> String {
        var value = Substring(etag)
        if value.hasPrefix("W/") { value = value.dropFirst(2) }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = value.dropFirst().dropLast() }
        return String(value)
    }
}
