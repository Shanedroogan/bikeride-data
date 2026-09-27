import BRCore
import BRData
import BRTimetable
import Foundation

/// The names a published set uses for the transit systems: the keys of manifest `coverage`,
/// `systems` and the trip-count sidecar, and of the relay's `/v1/health/data` report.
public enum SetSystems {
    public static func name(_ system: TransitSystem) -> String {
        switch system {
        case .subway: "subway"
        case .bus: "bus"
        case .lirr: "lirr"
        case .ferry: "ferry"
        case .path: "path"
        }
    }

    public static func system(named name: String) -> TransitSystem? {
        TransitSystem.allCases.first { self.name($0) == name }
    }

    /// `YYYY-MM-DD`, the manifest's date form. The relay walks these strings day by day.
    public static func isoDay(_ date: ServiceDate) -> String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }

    public static func serviceDate(isoDay text: String) -> ServiceDate? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return nil }
        return ServiceDate(yyyymmdd: parts.joined())
    }

    /// Consecutive covered days starting at `today`: what the relay reports as `coverageDays`.
    public static func coverageDays(_ dates: Set<ServiceDate>, from today: ServiceDate) -> Int {
        var days = 0
        var date = today
        while dates.contains(date) {
            days += 1
            date = date.adding(days: 1)
        }
        return days
    }
}

/// One artifact file of a built set: `<name>.bin`, its `.xz` blob if present, the header and the
/// raw hash, read from disk (never from a build report).
public struct SetArtifactFile: Sendable {
    public var kind: ArtifactKind
    public var rawURL: URL
    public var xzURL: URL?
    public var header: ArtifactHeader
    public var rawBytes: Int
    public var rawSha256: String
}

public enum SetArtifacts {
    /// Every `<name>.bin` in `directory` whose name is an artifact kind, with its header parsed
    /// (the kind must match the name) and its raw bytes hashed.
    public static func scan(_ directory: URL, runner: any ToolRunner) throws -> [ArtifactKind: SetArtifactFile] {
        var found: [ArtifactKind: SetArtifactFile] = [:]
        for kind in ArtifactKind.allCases {
            let raw = directory.appendingPathComponent("\(kind.name).bin")
            guard FileManager.default.fileExists(atPath: raw.path) else { continue }
            let bytes = try Data(contentsOf: raw, options: .alwaysMapped)
            let (header, _) = try ArtifactHeader.decode(from: bytes)
            guard header.kind == kind else { throw SetError.kindMismatch(file: raw.lastPathComponent, header: header.kind.name) }
            let xz = raw.appendingPathExtension("xz")
            found[kind] = SetArtifactFile(
                kind: kind, rawURL: raw, xzURL: FileManager.default.fileExists(atPath: xz.path) ? xz : nil, header: header,
                rawBytes: bytes.count, rawSha256: try sha256(of: raw, runner: runner))
        }
        return found
    }

    static func sha256(of url: URL, runner: any ToolRunner) throws -> String {
        try ArtifactOutput.sha256(ofFileAt: url, runner: runner)
    }

    static func sha256(of data: Data, runner: any ToolRunner) throws -> String {
        #if canImport(CryptoKit)
        return CryptoKitHasher().sha256(of: data).hex
        #else
        return try ProcessHasher(runner: runner).sha256(of: data).hex
        #endif
    }

    /// Active trips on every covered date, ascending.
    public static func tripCounts(_ timetable: Timetable) -> [(date: ServiceDate, trips: Int)] {
        timetable.coveredDates.map { ($0, timetable.dayView(for: $0).activeTripCount) }
    }

    /// Writes `value` as JSON atomically. Published documents (manifest, sidecar, heartbeat) are
    /// compact; reports are pretty-printed. Keys are always sorted.
    static func writeJSON<T: Encodable>(_ value: T, to url: URL, pretty: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data
    }

    static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public enum SetError: Error, Equatable, CustomStringConvertible {
        case kindMismatch(file: String, header: String)

        public var description: String {
            switch self {
            case .kindMismatch(let file, let header): "\(file): the header says it is a \(header) artifact"
            }
        }
    }
}
