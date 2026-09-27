import BRCore
import Foundation

/// The CSV entries of one trip-data file: a zip (streamed with `unzip -p`, nothing extracted) or,
/// in tests, a directory of CSVs.
public protocol TripArchive: Sendable {
    /// Human-readable location, for errors and reports.
    var location: String { get }
    /// The CSV entries in byte order of their names. Each holds its own header row.
    func csvEntries() throws -> [String]
    /// Streams one entry. Drain ``TripEntryStream/source`` to the end, then call `finish()`.
    func open(_ entry: String) throws -> TripEntryStream
}

/// One entry being read.
public struct TripEntryStream {
    public var source: TripChunkSource
    private let onFinish: () throws -> Void
    private let onCancel: () -> Void

    public init(source: TripChunkSource, finish: @escaping () throws -> Void, cancel: @escaping () -> Void) {
        self.source = source
        self.onFinish = finish
        self.onCancel = cancel
    }

    /// Waits for the producer (`unzip`) and surfaces its failure.
    public func finish() throws { try onFinish() }
    public func cancel() { onCancel() }
}

extension TripArchive {
    /// Whether an archive member is a trip CSV: a `.csv` file that is not macOS resource-fork
    /// litter (`__MACOSX/…`, `._name.csv`) and not a directory.
    static func isTripCSV(_ path: String) -> Bool {
        guard !path.hasSuffix("/"), !path.hasPrefix("__MACOSX/"), !path.contains("/__MACOSX/") else { return false }
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return !base.hasPrefix("._") && base.lowercased().hasSuffix(".csv")
    }
}

/// A trip-data zip. NYC months hold several entries (`…_1.csv`, `…-part1.csv`), stored or
/// deflated; JC months one, sometimes next to a `__MACOSX/` entry.
public struct ZipTripArchive: TripArchive {
    public let archive: URL
    public let runner: any ToolRunner

    public init(archive: URL, runner: any ToolRunner) {
        self.archive = archive
        self.runner = runner
    }

    public var location: String { archive.path }

    public func csvEntries() throws -> [String] {
        let listing = try runner.run(executable: "unzip", args: ["-Z1", archive.path])
        return String(decoding: listing, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            .filter(Self.isTripCSV)
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    public func open(_ entry: String) throws -> TripEntryStream {
        // `unzip` treats the member argument as a wildcard pattern; escape the metacharacters.
        let pattern = entry.reduce(into: "") { result, character in
            if "[]*?\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        let stream = try runner.stream(executable: "unzip", args: ["-p", archive.path, pattern])
        return TripEntryStream(
            source: TripChunkSource(stream.output),
            finish: { try stream.waitUntilExit() },
            cancel: { stream.terminate() }
        )
    }
}

/// A directory of trip CSVs (tests; also handy for an unzipped month).
public struct DirectoryTripArchive: TripArchive {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var location: String { directory.path }

    public func csvEntries() throws -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: directory.path) else { return [] }
        var entries: [String] = []
        while let path = walker.nextObject() as? String {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path, isDirectory: &isDirectory)
            if !isDirectory.boolValue, Self.isTripCSV(path) { entries.append(path) }
        }
        return entries.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    public func open(_ entry: String) throws -> TripEntryStream {
        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(entry))
        return TripEntryStream(source: TripChunkSource(handle), finish: { try handle.close() }, cancel: { try? handle.close() })
    }
}

/// Reads a file or pipe in 1 MB chunks. On Apple platforms each read runs in its own autorelease
/// pool: `FileHandle` hands back autoreleased buffers, and a worker thread that streams a 200 MB
/// entry would otherwise hold every chunk until the entry ends (about 1.5 GB across 8 workers).
public struct TripChunkSource: ByteChunkSource {
    public let handle: FileHandle
    public let chunkSize: Int

    public init(_ handle: FileHandle, chunkSize: Int = 1 << 20) {
        self.handle = handle
        self.chunkSize = chunkSize
    }

    public mutating func nextChunk() throws -> [UInt8]? {
        #if canImport(ObjectiveC)
        return try autoreleasepool { try read() }
        #else
        return try read()
        #endif
    }

    private func read() throws -> [UInt8]? {
        guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return nil }
        return [UInt8](data)
    }
}
