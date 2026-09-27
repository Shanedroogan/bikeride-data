import BRCore
import Foundation

/// What is known about one downloaded source file. Stored next to it as `<file>.source.json`.
public struct SourceRecord: Codable, Sendable, Equatable {
    public var url: String
    public var path: String
    public var bytes: Int
    public var etag: String?
    public var lastModified: String?
    /// `downloaded`, `not-modified` (conditional GET answered 304) or `offline` (not checked).
    public var status: String
    public var checkedAt: String

    /// A compact identifier of the file's version, for artifact `dataVersion` strings.
    public var versionTag: String {
        if let lastModified, let date = Self.httpDateFormatter.date(from: lastModified) {
            return Self.isoFormatter.string(from: date)
        }
        return etag ?? "bytes=\(bytes)"
    }

    static var httpDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }

    static var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

/// Downloads source files with `curl` through a ``ToolRunner``, re-downloading only when the
/// server reports a change (`If-None-Match` with the saved ETag, and `If-Modified-Since` from the
/// file's time stamp, which `curl -R` sets from `Last-Modified`).
public struct SourceFetcher: Sendable {
    public enum FetchError: Error, Equatable, CustomStringConvertible {
        case missingOffline(path: String)
        case unexpectedStatus(url: String, status: String)

        public var description: String {
            switch self {
            case .missingOffline(let path): "\(path) is missing and --offline forbids downloading it"
            case .unexpectedStatus(let url, let status): "\(url) answered HTTP \(status)"
            }
        }
    }

    public let runner: any ToolRunner
    public let offline: Bool

    public init(runner: any ToolRunner, offline: Bool) {
        self.runner = runner
        self.offline = offline
    }

    /// Ensures `file` holds the current `url`, returning its record.
    public func fetch(_ url: String, to file: URL) throws -> SourceRecord {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metaURL = URL(fileURLWithPath: file.path + ".source.json")
        let previous = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(SourceRecord.self, from: $0) }
        let now = SourceRecord.isoFormatter.string(from: Date())
        let exists = fileManager.fileExists(atPath: file.path)

        if offline {
            guard exists else { throw FetchError.missingOffline(path: file.path) }
            var record = previous ?? SourceRecord(url: url, path: file.path, bytes: 0, status: "offline", checkedAt: now)
            record.bytes = Self.size(of: file)
            record.status = "offline"
            return record
        }

        let partial = URL(fileURLWithPath: file.path + ".partial")
        let headers = URL(fileURLWithPath: file.path + ".headers")
        let etagFile = URL(fileURLWithPath: file.path + ".etag")
        try? fileManager.removeItem(at: partial)
        var args = [
            "--silent", "--show-error", "--fail", "--location", "--remote-time",
            "--retry", "3", "--connect-timeout", "30",
            "--dump-header", headers.path, "--output", partial.path, "--write-out", "%{http_code}",
        ]
        if exists {
            args += ["--time-cond", file.path]
            if fileManager.fileExists(atPath: etagFile.path) { args += ["--etag-compare", etagFile.path] }
        }
        args.append(url)
        let status = String(decoding: try runner.run(executable: "curl", args: args), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let responseHeaders = Self.lastResponseHeaders(at: headers)
        try? fileManager.removeItem(at: headers)

        var record = SourceRecord(
            url: url, path: file.path, bytes: 0,
            etag: responseHeaders["etag"] ?? previous?.etag,
            lastModified: responseHeaders["last-modified"] ?? previous?.lastModified,
            status: "downloaded", checkedAt: now
        )
        switch status {
        case "200":
            if fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
            try fileManager.moveItem(at: partial, to: file)
        case "304":
            try? fileManager.removeItem(at: partial)
            record.status = "not-modified"
        default:
            try? fileManager.removeItem(at: partial)
            throw FetchError.unexpectedStatus(url: url, status: status)
        }
        if let etag = record.etag { try? Data(etag.utf8).write(to: etagFile) }
        record.bytes = Self.size(of: file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: metaURL)
        return record
    }

    private static func size(of file: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Header fields (lowercased names) of the final response in a `--dump-header` file that may
    /// hold several (redirects).
    static func lastResponseHeaders(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        // Split on newline Characters, not "\n": Swift treats "\r\n" as one Character, and on Linux
        // `components(separatedBy: "\n")` then never splits curl's CRLF header dump (every ETag lost).
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("HTTP/") {
                fields = [:]
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name] = value
        }
        return fields
    }
}
