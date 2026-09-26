import BRCore
import Foundation

/// The member files of one GTFS feed: a zip archive (streamed with `unzip -p`) or a directory.
public protocol GTFSFeedFiles: Sendable {
    /// Human-readable location, for errors.
    var location: String { get }
    /// Base names of the member files, e.g. `stop_times.txt`. Files in a subdirectory of a zip
    /// (as in the Staten Island Ferry feed) are listed by base name.
    func fileNames() throws -> Set<String>
    /// Streams the file with this base name, or returns `nil` if the feed lacks it.
    func open(_ fileName: String) throws -> GTFSFileStream?
}

/// One member file being read. Drain ``source`` to the end, then call ``finish()``.
public struct GTFSFileStream {
    public var source: FileHandleChunkSource
    private let onFinish: () throws -> Void
    private let onCancel: () -> Void

    public init(source: FileHandleChunkSource, finish: @escaping () throws -> Void, cancel: @escaping () -> Void) {
        self.source = source
        self.onFinish = finish
        self.onCancel = cancel
    }

    /// Waits for the producer (e.g. `unzip`) and surfaces its failure.
    public func finish() throws { try onFinish() }

    /// Abandons the stream early.
    public func cancel() { onCancel() }
}

/// A feed unpacked into a directory (test fixtures, or `unzip -d` output).
public struct DirectoryGTFSFeed: GTFSFeedFiles {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var location: String { directory.path }

    public func fileNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    public func open(_ fileName: String) throws -> GTFSFileStream? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        return GTFSFileStream(
            source: FileHandleChunkSource(handle),
            finish: { try handle.close() },
            cancel: { try? handle.close() }
        )
    }
}

/// A zipped feed, read member by member with `unzip -p` so nothing is extracted to disk.
public struct ZipGTFSFeed: GTFSFeedFiles {
    public let archive: URL
    public let runner: any ToolRunner
    /// Base name → member path inside the archive. The first member with a given base name wins.
    public let members: [String: String]

    /// Lists the archive's members once (`unzip -Z1`).
    public init(archive: URL, runner: any ToolRunner) throws {
        self.archive = archive
        self.runner = runner
        let listing = try runner.run(executable: "unzip", args: ["-Z1", archive.path])
        var members: [String: String] = [:]
        for line in String(decoding: listing, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let path = String(line)
            guard !path.hasSuffix("/"), !path.hasPrefix("__MACOSX/") else { continue }
            let base = path.split(separator: "/").last.map(String.init) ?? path
            if members[base] == nil { members[base] = path }
        }
        self.members = members
    }

    public var location: String { archive.path }

    public func fileNames() -> Set<String> {
        Set(members.keys)
    }

    public func open(_ fileName: String) throws -> GTFSFileStream? {
        guard let member = members[fileName] else { return nil }
        let stream = try runner.stream(executable: "unzip", args: ["-p", archive.path, member])
        return GTFSFileStream(
            source: FileHandleChunkSource(stream.output, chunkSize: 1 << 20),
            finish: { try stream.waitUntilExit() },
            cancel: { stream.terminate() }
        )
    }
}

public enum GTFSError: Error, Equatable, CustomStringConvertible {
    case missingFile(feed: String, file: String)
    case missingColumn(feed: String, file: String, column: String)
    case invalidValue(feed: String, file: String, record: Int, column: String, value: String)
    case mixedTimeZones([String])
    case noTimeZone(feed: String)
    /// Boarding stops that could not be given a synthesized parent station (PATH).
    case unmappedPlatforms(feed: String, stops: [String])

    public var description: String {
        switch self {
        case .missingFile(let feed, let file): "\(feed): missing \(file)"
        case .missingColumn(let feed, let file, let column): "\(feed): \(file) has no \(column) column"
        case .invalidValue(let feed, let file, let record, let column, let value):
            "\(feed): \(file) record \(record): invalid \(column) '\(value)'"
        case .mixedTimeZones(let zones): "agencies of one system use different time zones: \(zones.joined(separator: ", "))"
        case .noTimeZone(let feed): "\(feed): agency.txt gives no agency_timezone"
        case .unmappedPlatforms(let feed, let stops):
            "\(feed): no parent station for \(stops.count) boarding stop(s): \(stops.joined(separator: ", "))"
        }
    }
}

extension GTFSFeedFiles {
    /// Streams `fileName` record by record. `body` receives the header and each data record.
    /// Returns `false` (without calling `body`) if the file is absent and not `required`.
    @discardableResult
    func forEachRecord(
        in fileName: String,
        required: Bool,
        _ body: (_ header: CSVHeader, _ record: CSVRecord, _ recordNumber: Int) throws -> Void
    ) throws -> Bool {
        guard let stream = try open(fileName) else {
            if required { throw GTFSError.missingFile(feed: location, file: fileName) }
            return false
        }
        var reader = CSVReader(stream.source)
        do {
            guard let headerRecord = try reader.next() else {
                try stream.finish()
                return true
            }
            let header = CSVHeader(headerRecord)
            while let record = try reader.next() {
                try body(header, record, reader.recordCount)
            }
        } catch {
            stream.cancel()
            throw error
        }
        try stream.finish()
        return true
    }
}
