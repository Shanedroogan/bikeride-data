import BRCore
import BRData
import BRTimetable
import Foundation

/// `data/manifest.json`: the published set. Fetched by the app (through the relay, every 60 s)
/// and read by the relay's `/v1/health/data`, which treats **every** key under `coverage` as a
/// system and walks its `YYYY-MM-DD` strings from today, so `coverage` holds exactly
/// `{subway, bus, lirr, ferry, path: [dates]}` and nothing else.
public struct SetManifest: Codable, Sendable, Equatable {
    public static let fileName = "manifest.json"
    public static let schemaVersion = 1
    /// The kinds every set must hold. `flows` and `config` join when their builders land (M1 P2b).
    public static let coreKinds: [ArtifactKind] = [.streets, .stations, .ttSubway, .ttBus, .ttLirr, .ttFerry, .ttPath, .links]

    public struct Artifact: Codable, Sendable, Equatable {
        /// SHA-256 of the `.xz` blob: its name under `data/blobs/`.
        public var sha: String
        /// Size of the `.xz` blob.
        public var bytes: Int
        public var rawBytes: Int
        public var rawSha256: String
        public var formatVersion: Int
        public var dataVersion: String
        /// Input artifact name → the rawSha256 it was built against (from the header).
        public var builtAgainst: [String: String]

        public init(sha: String, bytes: Int, rawBytes: Int, rawSha256: String, formatVersion: Int, dataVersion: String,
                    builtAgainst: [String: String]) {
            self.sha = sha
            self.bytes = bytes
            self.rawBytes = rawBytes
            self.rawSha256 = rawSha256
            self.formatVersion = formatVersion
            self.dataVersion = dataVersion
            self.builtAgainst = builtAgainst
        }
    }

    public struct System: Codable, Sendable, Equatable {
        /// The timetable artifact, e.g. `tt-subway`.
        public var artifact: String
        public var first: String?
        public var last: String?
        /// Covered dates in the set.
        public var dates: Int
        /// Consecutive covered days from the build day.
        public var days: Int
        public var status: SetSystemStatus

        public init(artifact: String, first: String?, last: String?, dates: Int, days: Int, status: SetSystemStatus) {
            self.artifact = artifact
            self.first = first
            self.last = last
            self.dates = dates
            self.days = days
            self.status = status
        }
    }

    /// One source version a timetable was compiled from, as its payload records it.
    public struct Source: Codable, Sendable, Equatable {
        /// `gtfs_subway`, or `gtfs_subway@<key8>` for an archived version.
        public var name: String
        /// The feed without the version suffix.
        public var feed: String
        public var etag: String
        /// `feed_info.txt` `feed_version` (empty when absent).
        public var feedVersion: String
        public var datesSelected: Int
        public var firstSelected: String?
        public var lastSelected: String?

        public init(name: String, feed: String, etag: String, feedVersion: String, datesSelected: Int, firstSelected: String?, lastSelected: String?) {
            self.name = name
            self.feed = feed
            self.etag = etag
            self.feedVersion = feedVersion
            self.datesSelected = datesSelected
            self.firstSelected = firstSelected
            self.lastSelected = lastSelected
        }
    }

    public struct Gate: Codable, Sendable, Equatable {
        public struct Check: Codable, Sendable, Equatable {
            public var name: String
            public var status: GateCheckStatus
        }

        public var status: GateStatus
        public var checks: [Check]
        public var warnings: [String]
    }

    public struct FileReference: Codable, Sendable, Equatable {
        /// Relative to the manifest.
        public var file: String
        public var sha256: String
    }

    public var schema: Int
    /// First 16 hex digits of the SHA-256 of `"<name>\t<sha>\n"` over every artifact, sorted by
    /// name: content-derived (never time-derived), so rebuilding the same bytes gives the same set.
    public var setId: String
    public var generatedAt: String
    public var tool: String
    /// `YYYYMMDD`.
    public var buildDay: String
    public var previousSetId: String?
    /// Artifacts copied from the previous manifest because this run did not rebuild them.
    public var carriedForward: [String]
    /// By artifact name (the key `TransitDataSet`'s `.known` rawSha256 lookup expects).
    public var artifacts: [String: Artifact]
    /// System → every covered service date, `YYYY-MM-DD`, ascending.
    public var coverage: [String: [String]]
    public var systems: [String: System]
    /// Timetable artifact → the source versions in its payload.
    public var sources: [String: [Source]]
    public var gate: Gate
    /// Per-date trip counts for the next build's gate; only the pipeline reads it.
    public var tripCounts: FileReference

    public static func setId(_ artifacts: [String: Artifact]) -> String {
        let lines = artifacts.keys.sorted().map { "\($0)\t\(artifacts[$0]!.sha)\n" }.joined()
        #if canImport(CryptoKit)
        return String(CryptoKitHasher().sha256(of: Data(lines.utf8)).hex.prefix(16))
        #else
        return String(((try? ProcessHasher(runner: ProcessToolRunner()).sha256(of: Data(lines.utf8)).hex) ?? "").prefix(16))
        #endif
    }

    public static func load(_ url: URL) throws -> SetManifest {
        let manifest = try JSONDecoder().decode(SetManifest.self, from: Data(contentsOf: url))
        guard manifest.schema == schemaVersion else { throw ManifestError.unsupportedSchema(manifest.schema) }
        return manifest
    }

    /// The trip-count sidecar this manifest references, looked up next to `manifestURL` and
    /// checked against the recorded SHA-256 and set.
    public func loadTripCounts(nextTo manifestURL: URL, runner: any ToolRunner) throws -> TripCountSidecar {
        let url = manifestURL.deletingLastPathComponent().appendingPathComponent(tripCounts.file)
        let data = try Data(contentsOf: url)
        let sha = try SetArtifacts.sha256(of: data, runner: runner)
        guard sha == tripCounts.sha256 else { throw ManifestError.sidecarMismatch(file: url.path, expected: tripCounts.sha256, actual: sha) }
        let sidecar = try JSONDecoder().decode(TripCountSidecar.self, from: data)
        guard sidecar.setId == setId else { throw ManifestError.sidecarMismatch(file: url.path, expected: setId, actual: sidecar.setId) }
        return sidecar
    }

    public enum ManifestError: Error, Equatable, CustomStringConvertible {
        case unsupportedSchema(Int)
        case sidecarMismatch(file: String, expected: String, actual: String)
        case noGateReport(String)
        case gateFailed(String)
        case gateStale(String)
        case missingBlob(String)
        case missingKind(String)
        case inconsistent(String)

        public var description: String {
            switch self {
            case .unsupportedSchema(let schema): "manifest schema \(schema) is not supported"
            case .sidecarMismatch(let file, let expected, let actual): "\(file): expected \(expected), found \(actual)"
            case .noGateReport(let path): "no gate report at \(path); run `bikeride-data gate` first"
            case .gateFailed(let path): "\(path): the gate failed; nothing is published"
            case .gateStale(let message): "the gate report does not describe this set: \(message); run the gate again"
            case .missingBlob(let name): "\(name).bin has no .xz blob"
            case .missingKind(let name): "\(name): not in the data directory and not in the previous manifest"
            case .inconsistent(let message): message
            }
        }
    }
}

/// `trip-counts.json`, next to the manifest: active trips per system and service date, the input
/// of the next build's trip-count check. Kept out of `manifest.json`, which the app fetches every
/// 60 s.
public struct TripCountSidecar: Codable, Sendable, Equatable {
    public static let fileName = "trip-counts.json"

    public var schema = 1
    public var setId: String
    public var buildDay: String
    /// System → `YYYY-MM-DD` → active trips.
    public var systems: [String: [String: Int]]
}

/// Writes `manifest.json` (and its sidecar) for the set in a data directory.
///
/// Every raw file and blob is re-hashed here; the build reports are not trusted (the timetable
/// report keeps entries for systems a run did not build). A gate report (`reports/gate.json`)
/// that passed, or failed only soft, on exactly these raw hashes is required. With a previous
/// manifest, kinds the data directory lacks are carried forward (entry, coverage, sources and trip
/// counts), and every artifact's `builtAgainst` must name the set's exact inputs.
public struct SetManifestBuilder {
    public var dataDirectory: URL
    public var reportsDirectory: URL
    public var previousManifest: URL?
    public var today: ServiceDate
    public var now: Date
    public var requiredKinds: [ArtifactKind] = SetManifest.coreKinds
    public var runner: any ToolRunner

    public init(dataDirectory: URL, reportsDirectory: URL, previousManifest: URL?, today: ServiceDate, now: Date = Date(),
                runner: any ToolRunner) {
        self.dataDirectory = dataDirectory
        self.reportsDirectory = reportsDirectory
        self.previousManifest = previousManifest
        self.today = today
        self.now = now
        self.runner = runner
    }

    public var manifestURL: URL { dataDirectory.appendingPathComponent(SetManifest.fileName) }
    public var tripCountsURL: URL { dataDirectory.appendingPathComponent(TripCountSidecar.fileName) }

    /// Builds the manifest and sidecar without writing them.
    public func build() throws -> (manifest: SetManifest, tripCounts: TripCountSidecar, tripCountsBytes: Data) {
        let local = try SetArtifacts.scan(dataDirectory, runner: runner)
        let gate = try verifiedGate(local)
        var warnings: [String] = []
        let (previous, previousCounts) = Gate.loadPrevious(previousManifest, runner: runner, warnings: &warnings)
        if let previousManifest, previous == nil { throw SetManifest.ManifestError.inconsistent(warnings.first ?? "\(previousManifest.path) unreadable") }
        guard gate.previousSetId == previous?.setId else {
            throw SetManifest.ManifestError.gateStale("the gate compared against set \(gate.previousSetId ?? "none"), this manifest against \(previous?.setId ?? "none")")
        }

        // Artifacts: the data directory's, then carried forward.
        var artifacts: [String: SetManifest.Artifact] = [:]
        for file in local.values {
            guard let xz = file.xzURL else { throw SetManifest.ManifestError.missingBlob(file.kind.name) }
            artifacts[file.kind.name] = SetManifest.Artifact(
                sha: try SetArtifacts.sha256(of: xz, runner: runner),
                bytes: (try FileManager.default.attributesOfItem(atPath: xz.path)[.size] as? Int) ?? 0,
                rawBytes: file.rawBytes, rawSha256: file.rawSha256, formatVersion: Int(file.header.formatVersion),
                dataVersion: file.header.dataVersion, builtAgainst: file.header.builtAgainst)
        }
        var carried: [String] = []
        for (name, entry) in previous?.artifacts ?? [:] where artifacts[name] == nil {
            artifacts[name] = entry
            carried.append(name)
        }
        for kind in requiredKinds where artifacts[kind.name] == nil { throw SetManifest.ManifestError.missingKind(kind.name) }
        for (name, entry) in artifacts.sorted(by: { $0.key < $1.key }) {
            for (input, sha) in entry.builtAgainst.sorted(by: { $0.key < $1.key }) where artifacts[input]?.rawSha256 != sha {
                throw SetManifest.ManifestError.inconsistent(
                    "\(name) was built against \(input) \(sha.prefix(12)), but the set has \(artifacts[input].map { String($0.rawSha256.prefix(12)) } ?? "none")")
            }
        }

        // Coverage, systems, sources and trip counts per system.
        var coverage: [String: [String]] = [:], systems: [String: SetManifest.System] = [:], sources: [String: [SetManifest.Source]] = [:]
        var counts: [String: [String: Int]] = [:]
        for system in TransitSystem.allCases {
            let name = SetSystems.name(system), kind = ArtifactKind.timetable(for: system)
            let dates: [ServiceDate]
            if let file = local[kind] {
                let timetable = try Timetable(contentsOf: file.rawURL)
                dates = timetable.coveredDates
                sources[kind.name] = (0..<timetable.sourceCount).map { index in
                    let source = timetable.source(index)
                    return SetManifest.Source(
                        name: source.name, feed: String(source.name.split(separator: "@", maxSplits: 1).first ?? ""), etag: source.etag,
                        feedVersion: source.version, datesSelected: source.selectedDates.count,
                        firstSelected: source.selectedDates.first.map(SetSystems.isoDay), lastSelected: source.selectedDates.last.map(SetSystems.isoDay))
                }
                counts[name] = Dictionary(uniqueKeysWithValues: SetArtifacts.tripCounts(timetable).map { (SetSystems.isoDay($0.date), $0.trips) })
            } else if let previous, previous.artifacts[kind.name] != nil {
                dates = (previous.coverage[name] ?? []).compactMap(SetSystems.serviceDate(isoDay:))
                sources[kind.name] = previous.sources[kind.name] ?? []
                if let before = previousCounts?.systems[name] { counts[name] = before }
            } else {
                continue
            }
            coverage[name] = dates.map(SetSystems.isoDay)
            let days = SetSystems.coverageDays(Set(dates), from: today)
            systems[name] = SetManifest.System(
                artifact: kind.name, first: dates.first.map(SetSystems.isoDay), last: dates.last.map(SetSystems.isoDay), dates: dates.count,
                days: days, status: gate.systems[name]?.status ?? .ok)
        }

        let setId = SetManifest.setId(artifacts)
        let sidecar = TripCountSidecar(setId: setId, buildDay: today.yyyymmdd, systems: counts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sidecarBytes = try encoder.encode(sidecar)
        let manifest = SetManifest(
            schema: SetManifest.schemaVersion, setId: setId, generatedAt: SetArtifacts.isoTimestamp(now),
            tool: "bikeride-data \(BuildInfo.toolVersion) (Swift \(BuildInfo.swiftVersion))", buildDay: today.yyyymmdd,
            previousSetId: previous?.setId, carriedForward: carried.sorted(), artifacts: artifacts, coverage: coverage, systems: systems,
            sources: sources,
            gate: SetManifest.Gate(status: gate.status, checks: gate.checks.map { .init(name: $0.name, status: $0.status) },
                                   warnings: gate.checks.flatMap { check in check.warnings.map { "\(check.name): \($0)" } }),
            tripCounts: SetManifest.FileReference(file: TripCountSidecar.fileName, sha256: try SetArtifacts.sha256(of: sidecarBytes, runner: runner)))
        return (manifest, sidecar, sidecarBytes)
    }

    /// Builds and writes the sidecar, then the manifest.
    @discardableResult
    public func write() throws -> SetManifest {
        let (manifest, _, sidecarBytes) = try build()
        try sidecarBytes.write(to: tripCountsURL, options: .atomic)
        _ = try SetArtifacts.writeJSON(manifest, to: manifestURL, pretty: false)
        return manifest
    }

    /// The gate report for exactly these files, or why there is none.
    func verifiedGate(_ local: [ArtifactKind: SetArtifactFile]) throws -> GateReport {
        let url = reportsDirectory.appendingPathComponent(GateReport.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SetManifest.ManifestError.noGateReport(url.path) }
        let gate = try GateReport.load(url)
        guard gate.status != .fail else { throw SetManifest.ManifestError.gateFailed(url.path) }
        let hashes = Dictionary(uniqueKeysWithValues: local.values.map { ($0.kind.name, $0.rawSha256) })
        guard gate.artifacts == hashes else {
            let changed = Set(gate.artifacts.keys).union(hashes.keys).filter { gate.artifacts[$0] != hashes[$0] }.sorted()
            throw SetManifest.ManifestError.gateStale("checked \(changed.joined(separator: ", ")) with other bytes (or not at all)")
        }
        guard gate.buildDay == today.yyyymmdd else {
            throw SetManifest.ManifestError.gateStale("the gate ran for build day \(gate.buildDay), not \(today.yyyymmdd)")
        }
        return gate
    }
}
