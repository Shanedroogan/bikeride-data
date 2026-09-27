import BRCore
import BRData
import BRStreetCore
import BRTimetable
import Foundation

// MARK: - Configuration

/// The gate's pipeline-only inputs, from the repository's `Data/` directory: `gate/thresholds.json`,
/// `gate/snap-allowlist.csv` and the shared holiday list `config/calendar/holidays.csv`. None of it
/// ships in the `config` artifact.
public struct GateConfiguration: Sendable, Equatable {
    public struct Thresholds: Codable, Sendable, Equatable {
        public struct TripCounts: Codable, Sendable, Equatable {
            /// The schedules a holiday may run, when it is compared with a profile rather than the
            /// same date: its own weekday, Saturday or Sunday.
            public enum HolidayProfile: String, Codable, Sendable, CaseIterable {
                case weekday, saturday, sunday
            }

            /// A date whose active trips differ from the reference by more than this fails.
            public var maxChangePercent: Double
            /// A holiday without a same-date reference is compared with the nearest of these
            /// profiles of the previous build. `["sunday"]` alone fails Columbus Day and Veterans
            /// Day, which run weekday service (subway +51 %, bus +44 % and +57 %, PATH +86 % against
            /// the Sunday median in the 2026-09-26 build).
            public var holidayProfiles: [HolidayProfile]

            public init(maxChangePercent: Double, holidayProfiles: [HolidayProfile] = HolidayProfile.allCases) {
                self.maxChangePercent = maxChangePercent
                self.holidayProfiles = holidayProfiles
            }
        }

        public struct Coverage: Codable, Sendable, Equatable {
            /// Fewer consecutive covered days from the build day fails soft (`noSchedule`).
            public var minDays: Int

            public init(minDays: Int) { self.minDays = minDays }
        }

        public struct Snapping: Codable, Sendable, Equatable {
            public var maxSnapMeters: Double

            public init(maxSnapMeters: Double) { self.maxSnapMeters = maxSnapMeters }
        }

        public struct Streets: Codable, Sendable, Equatable {
            /// For a region without its own entry in ``regions``.
            public var minKeptSharePercent: Double
            /// Region name → minimum kept share, percent. Every region listed must be in the report.
            public var regions: [String: Double]

            public init(minKeptSharePercent: Double, regions: [String: Double]) {
                self.minKeptSharePercent = minKeptSharePercent
                self.regions = regions
            }
        }

        public var schema: Int
        public var tripCounts: TripCounts
        public var coverage: Coverage
        public var snapping: Snapping
        public var streets: Streets
        /// Free text for readers of the file (where the numbers come from).
        public var notes: [String]?

        public init(schema: Int = 1, tripCounts: TripCounts, coverage: Coverage, snapping: Snapping, streets: Streets, notes: [String]? = nil) {
            self.schema = schema
            self.tripCounts = tripCounts
            self.coverage = coverage
            self.snapping = snapping
            self.streets = streets
            self.notes = notes
        }
    }

    /// One accepted exception to the snapping rule, from `snap-allowlist.csv`.
    public struct SnapException: Sendable, Equatable {
        public enum Rule: String, Sendable, CaseIterable {
            /// Access points may snap farther than the limit, up to ``SnapException/maxMeters``.
            case snap
            /// The stop may lack street entry or exit.
            case noStreetAccess
        }

        public var stop: String
        public var rule: Rule
        public var maxMeters: Double?
        public var reason: String

        public init(stop: String, rule: Rule, maxMeters: Double?, reason: String) {
            self.stop = stop
            self.rule = rule
            self.maxMeters = maxMeters
            self.reason = reason
        }
    }

    public var thresholds: Thresholds
    public var snapExceptions: [SnapException]
    public var holidays: Set<ServiceDate>

    public static let thresholdsPath = "gate/thresholds.json"
    public static let allowlistPath = "gate/snap-allowlist.csv"
    public static let holidaysPath = "config/calendar/holidays.csv"

    public init(thresholds: Thresholds, snapExceptions: [SnapException], holidays: Set<ServiceDate>) {
        self.thresholds = thresholds
        self.snapExceptions = snapExceptions
        self.holidays = holidays
    }

    /// Reads the three files under `repoData` (the repository's `Data/`), strictly: an unknown
    /// key, column or rule is an error rather than a silently ignored typo.
    public static func load(repoData: URL) throws -> GateConfiguration {
        let thresholdsURL = repoData.appendingPathComponent(thresholdsPath)
        let json = try Data(contentsOf: thresholdsURL)
        let thresholds = try JSONDecoder().decode(Thresholds.self, from: json)
        let unknown = try GateStrictJSON.unknownKeys(in: json, comparedWith: JSONEncoder().encode(thresholds))
        guard unknown.isEmpty else { throw ConfigurationError.unknownKeys(file: thresholdsURL.path, keys: unknown) }
        guard thresholds.schema == 1 else { throw ConfigurationError.invalid(file: thresholdsURL.path, "schema \(thresholds.schema), expected 1") }
        return GateConfiguration(
            thresholds: thresholds,
            snapExceptions: try parseAllowlist(String(contentsOf: repoData.appendingPathComponent(allowlistPath), encoding: .utf8),
                                               file: allowlistPath),
            holidays: try parseHolidays(String(contentsOf: repoData.appendingPathComponent(holidaysPath), encoding: .utf8),
                                        file: holidaysPath))
    }

    /// `stop,rule,maxMeters,reason`; the reason is the rest of the line and may contain commas.
    /// Blank lines and lines starting with `#` are skipped.
    public static func parseAllowlist(_ text: String, file: String = allowlistPath) throws -> [SnapException] {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
        guard lines.first == "stop,rule,maxMeters,reason" else { throw ConfigurationError.invalid(file: file, "header must be stop,rule,maxMeters,reason") }
        lines.removeFirst()
        var result: [SnapException] = []
        for line in lines {
            let fields = line.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 4, !fields[0].isEmpty, !fields[3].isEmpty, let rule = SnapException.Rule(rawValue: fields[1]) else {
                throw ConfigurationError.invalid(file: file, "bad row '\(line)'")
            }
            let maxMeters = fields[2].isEmpty ? nil : Double(fields[2])
            guard (rule == .snap) == (maxMeters != nil), fields[2].isEmpty || maxMeters != nil else {
                throw ConfigurationError.invalid(file: file, "'\(line)': a snap row needs maxMeters, a noStreetAccess row none")
            }
            guard !result.contains(where: { $0.stop == fields[0] && $0.rule == rule }) else {
                throw ConfigurationError.invalid(file: file, "duplicate row for \(fields[0]) \(rule.rawValue)")
            }
            result.append(SnapException(stop: fields[0], rule: rule, maxMeters: maxMeters, reason: fields[3]))
        }
        return result
    }

    /// The dates of `holidays.csv` (`date,name,profile`). The gate uses every listed date
    /// whatever its profile; it asserts the file's documented invariants.
    public static func parseHolidays(_ text: String, file: String = holidaysPath) throws -> Set<ServiceDate> {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.first == "date,name,profile" else { throw ConfigurationError.invalid(file: file, "header must be date,name,profile") }
        lines.removeFirst()
        var dates: [ServiceDate] = []
        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let date = ServiceDate(yyyymmdd: fields[0]), ["weekend", "weekday"].contains(fields[2]),
                  date.weekday != .saturday, date.weekday != .sunday, dates.last.map({ $0 < date }) ?? true
            else { throw ConfigurationError.invalid(file: file, "bad or out-of-order row '\(line)'") }
            dates.append(date)
        }
        return Set(dates)
    }

    /// The repository's `Data/` directory: `./Data`, else `./Vendor/bikeride-data/Data` (the app
    /// repository's root, where the scripts run the CLI), else the source tree this binary was
    /// built from. The first that holds `gate/thresholds.json`.
    public static func defaultRepoData(currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> URL? {
        let sourceTree = URL(fileURLWithPath: #filePath)   // …/Sources/BRBuild/Publish/Gate.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Data")
        let candidates = [
            currentDirectory.appendingPathComponent("Data"),
            currentDirectory.appendingPathComponent("Vendor/bikeride-data/Data"),
            sourceTree,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(thresholdsPath).path) }
    }

    public enum ConfigurationError: Error, Equatable, CustomStringConvertible {
        case unknownKeys(file: String, keys: [String])
        case invalid(file: String, String)

        public var description: String {
            switch self {
            case .unknownKeys(let file, let keys): "\(file): unknown key(s) \(keys.joined(separator: ", "))"
            case .invalid(let file, let message): "\(file): \(message)"
            }
        }
    }
}

/// Unknown-key detection for JSON decoded with `Codable` (which ignores extra keys).
enum GateStrictJSON {
    /// Key paths present in `original` but not in `reencoded` (the decoded value encoded again).
    static func unknownKeys(in original: Data, comparedWith reencoded: Data) throws -> [String] {
        func walk(_ a: Any, _ b: Any, _ path: String, _ out: inout [String]) {
            if let a = a as? [String: Any] {
                let b = b as? [String: Any] ?? [:]
                for key in a.keys.sorted() {
                    let child = path.isEmpty ? key : "\(path).\(key)"
                    if let value = b[key] { walk(a[key]!, value, child, &out) } else { out.append(child) }
                }
            } else if let a = a as? [Any], let b = b as? [Any] {
                for (index, pair) in zip(a, b).enumerated() { walk(pair.0, pair.1, "\(path)[\(index)]", &out) }
            }
        }
        var out: [String] = []
        walk(try JSONSerialization.jsonObject(with: original), try JSONSerialization.jsonObject(with: reencoded), "", &out)
        return out
    }
}

// MARK: - Context and hooks

/// What a gate check sees: the set in the data directory (hashed, headers parsed), the previous
/// manifest and its trip counts, and the artifacts opened on demand with their readers.
public final class GateContext {
    public let dataDirectory: URL
    public let reportsDirectory: URL
    public let today: ServiceDate
    public let configuration: GateConfiguration
    public let runner: any ToolRunner
    /// The artifacts in the data directory.
    public let artifacts: [ArtifactKind: SetArtifactFile]
    public let previous: SetManifest?
    public let previousTripCounts: TripCountSidecar?
    /// Why the `--previous` manifest or its trip counts cannot be used; nil when they loaded (or
    /// no previous manifest was given). The gate fails on it.
    public internal(set) var previousProblem: String?

    private var timetables: [TransitSystem: Timetable] = [:]
    private var streetGraph: MappedStreetGraph?
    private var linksArtifact: MappedLinks?

    init(dataDirectory: URL, reportsDirectory: URL, today: ServiceDate, configuration: GateConfiguration, runner: any ToolRunner,
         artifacts: [ArtifactKind: SetArtifactFile], previous: SetManifest?, previousTripCounts: TripCountSidecar?) {
        self.dataDirectory = dataDirectory
        self.reportsDirectory = reportsDirectory
        self.today = today
        self.configuration = configuration
        self.runner = runner
        self.artifacts = artifacts
        self.previous = previous
        self.previousTripCounts = previousTripCounts
    }

    /// The set's rawSha256 for `kind`: the data directory's file, else the previous manifest's entry.
    public func setRawSha256(_ kind: ArtifactKind) -> String? {
        artifacts[kind]?.rawSha256 ?? previous?.artifacts[kind.name]?.rawSha256
    }

    /// Kinds the previous manifest supplies because the data directory lacks them.
    public var carriedForward: [ArtifactKind] {
        ArtifactKind.allCases.filter { artifacts[$0] == nil && previous?.artifacts[$0.name] != nil }
    }

    public func timetable(_ system: TransitSystem) throws -> Timetable? {
        if let cached = timetables[system] { return cached }
        guard let file = artifacts[ArtifactKind.timetable(for: system)] else { return nil }
        let timetable = try Timetable(contentsOf: file.rawURL)
        timetables[system] = timetable
        return timetable
    }

    public func streets() throws -> MappedStreetGraph? {
        if let streetGraph { return streetGraph }
        guard let file = artifacts[.streets] else { return nil }
        streetGraph = try MappedStreetGraph(contentsOf: file.rawURL, validate: true)
        return streetGraph
    }

    public func links() throws -> MappedLinks? {
        if let linksArtifact { return linksArtifact }
        guard let file = artifacts[.links] else { return nil }
        linksArtifact = try MappedLinks(contentsOf: file.rawURL)
        return linksArtifact
    }

    public func stations() throws -> MappedStations? {
        guard let file = artifacts[.stations] else { return nil }
        return try MappedStations(contentsOf: file.rawURL)
    }
}

/// A check added to the built-in ones: how the config reference checks (LIRR zones, valet) and the
/// flows statistics join the gate (wired in `all`, M1 step P2b). A thrown error fails the check.
public protocol GateCheck {
    var name: String { get }
    func run(_ context: GateContext) throws -> GateCheckResult
}

// MARK: - Gate

/// The validation gate (`bikeride-data gate`): invariants over a built set, never specific routes.
///
/// Checks, in order: `artifacts` (every required kind is in the set, each file opens with its
/// reader, every `builtAgainst` names the set's exact input), `xz`, `coverage` (fail soft),
/// `tripCounts`, `streets` (per-region kept share), `snapping`, then any ``extraChecks``. A set
/// may carry artifacts forward from the previous manifest (a job that did not rebuild them);
/// those are not re-checked, but everything built against them must match them.
public struct Gate {
    public var dataDirectory: URL
    public var reportsDirectory: URL
    public var previousManifest: URL?
    public var today: ServiceDate
    public var configuration: GateConfiguration
    public var requiredKinds: [ArtifactKind] = SetManifest.coreKinds
    public var extraChecks: [any GateCheck] = []
    public var runner: any ToolRunner
    public var now = Date()

    public init(dataDirectory: URL, reportsDirectory: URL, previousManifest: URL?, today: ServiceDate,
                configuration: GateConfiguration, runner: any ToolRunner) {
        self.dataDirectory = dataDirectory
        self.reportsDirectory = reportsDirectory
        self.previousManifest = previousManifest
        self.today = today
        self.configuration = configuration
        self.runner = runner
    }

    public var reportURL: URL { reportsDirectory.appendingPathComponent(GateReport.fileName) }

    /// Runs every check and writes `reports/gate.json`, whatever the verdict.
    @discardableResult
    public func run(log: (String) -> Void = { _ in }) throws -> GateReport {
        let artifacts = try SetArtifacts.scan(dataDirectory, runner: runner)
        let (previous, previousCounts, previousProblem) = Self.loadPrevious(previousManifest, runner: runner)
        let context = GateContext(dataDirectory: dataDirectory, reportsDirectory: reportsDirectory, today: today,
                                  configuration: configuration, runner: runner, artifacts: artifacts,
                                  previous: previous, previousTripCounts: previousCounts)
        context.previousProblem = previousProblem
        var systems: [String: GateSystem] = [:]
        var checks: [GateCheckResult] = []
        func timed(_ name: String, _ body: () throws -> GateCheckResult) {
            let started = Date()
            var result: GateCheckResult
            do {
                result = try body()
            } catch {
                result = GateCheckResult(name: name, status: .fail, summary: "check failed to run", failures: ["\(error)"])
            }
            result.seconds = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
            log("\(result.name): \(result.status.rawValue): \(result.summary) (\(String(format: "%.2f", result.seconds)) s)")
            for line in result.failures.prefix(20) { log("  FAIL \(line)") }
            for line in result.notes where line.hasPrefix("allowlisted") { log("  \(line)") }
            for line in result.warnings.prefix(10) { log("  warning: \(line)") }
            checks.append(result)
        }
        timed("artifacts") { try artifactsCheck(context) }
        timed("xz") { GateChecks.xz(Array(artifacts.values), runner: runner) }
        timed("coverage") {
            let (result, bySystem) = GateChecks.coverage(try coverage(context), today: today, minDays: configuration.thresholds.coverage.minDays)
            systems = bySystem
            return result
        }
        timed("tripCounts") {
            // A previous build was named but cannot be compared with: failing is the only safe
            // reading (a missing or altered sidecar must not switch the check off).
            if let problem = context.previousProblem {
                return GateCheckResult(name: "tripCounts", status: .fail, summary: "the previous build's trip counts cannot be used",
                                       failures: [problem])
            }
            return GateChecks.tripCounts(
                current: try currentTripCounts(context), previous: previousTripCounts(context), holidays: configuration.holidays,
                maxChangePercent: configuration.thresholds.tripCounts.maxChangePercent,
                holidayProfiles: configuration.thresholds.tripCounts.holidayProfiles)
        }
        timed("streets") { try streetsCheck(context) }
        timed("snapping") { try snappingCheck(context) }
        for check in extraChecks { timed(check.name) { try check.run(context) } }

        let status: GateStatus = checks.contains { $0.status == .fail } ? .fail : checks.contains { $0.status == .softFail } ? .softFail : .pass
        let report = GateReport(
            generatedAt: SetArtifacts.isoTimestamp(now), tool: "bikeride-data \(BuildInfo.toolVersion) (Swift \(BuildInfo.swiftVersion))",
            buildDay: today.yyyymmdd, status: status,
            artifacts: Dictionary(uniqueKeysWithValues: artifacts.values.map { ($0.kind.name, $0.rawSha256) }),
            blobs: SetArtifacts.blobHashes(artifacts),
            carriedForward: context.carriedForward.map(\.name), previousSetId: previous?.setId, systems: systems, checks: checks)
        _ = try SetArtifacts.writeJSON(report, to: reportURL, pretty: true)
        return report
    }

    /// The previous manifest and its trip-count sidecar, or why they cannot be used: a manifest
    /// that does not read, or a sidecar that is missing or does not match the manifest's record
    /// or set. The gate fails and `manifest` refuses on any such problem.
    static func loadPrevious(_ url: URL?, runner: any ToolRunner) -> (SetManifest?, TripCountSidecar?, problem: String?) {
        guard let url else { return (nil, nil, nil) }
        let manifest: SetManifest
        do {
            manifest = try SetManifest.load(url)
        } catch {
            return (nil, nil, "previous manifest \(url.path) unreadable (\(error))")
        }
        do {
            return (manifest, try manifest.loadTripCounts(nextTo: url, runner: runner), nil)
        } catch {
            return (manifest, nil, "previous trip counts unusable (\(error))")
        }
    }

    // MARK: Built-in checks

    func artifactsCheck(_ context: GateContext) throws -> GateCheckResult {
        var failures: [String] = [], notes: [String] = []
        if previousManifest != nil, context.previous == nil, let problem = context.previousProblem {
            failures.append(problem)   // nothing can be carried forward from it
        }
        for kind in requiredKinds where context.setRawSha256(kind) == nil {
            failures.append("\(kind.name): not in \(dataDirectory.path) and not in the previous manifest")
        }
        for file in context.artifacts.values.sorted(by: { $0.kind.name < $1.kind.name }) {
            do {
                switch file.kind {
                case .streets: _ = try context.streets()
                case .stations: _ = try context.stations()
                case .links: _ = try context.links()
                case .ttSubway, .ttBus, .ttLirr, .ttFerry, .ttPath:
                    _ = try context.timetable(TransitSystem.allCases.first { ArtifactKind.timetable(for: $0) == file.kind }!)
                case .flows, .config:
                    notes.append("\(file.kind.name): header checked; its reader is not wired into the gate yet")
                }
            } catch {
                failures.append("\(file.kind.name): does not open: \(error)")
            }
        }
        // Everything in the set, fresh or carried forward, must match what it was built against.
        var entries = context.artifacts.values.map { ($0.kind.name, $0.header.builtAgainst) }
        for kind in context.carriedForward {
            entries.append((kind.name, context.previous!.artifacts[kind.name]!.builtAgainst))
            notes.append("\(kind.name): carried forward from set \(context.previous!.setId)")
        }
        for (name, builtAgainst) in entries.sorted(by: { $0.0 < $1.0 }) {
            for (input, sha) in builtAgainst.sorted(by: { $0.key < $1.key }) {
                guard let kind = ArtifactKind(name: input) else {
                    failures.append("\(name): built against unknown artifact '\(input)'")
                    continue
                }
                guard let have = context.setRawSha256(kind) else {
                    failures.append("\(name): built against \(input) \(sha.prefix(12)), which is not in the set")
                    continue
                }
                if have != sha {
                    failures.append("\(name): built against \(input) \(sha.prefix(12)), but the set has \(have.prefix(12)); rebuild \(name)")
                }
            }
        }
        return .verdict("artifacts", checked: true, summary: failures.isEmpty
                            ? "\(context.artifacts.count) artifacts open, \(context.carriedForward.count) carried forward, builtAgainst consistent"
                            : "\(failures.count) problem(s) with the set's artifacts",
                        failures: failures, notes: notes, metrics: ["local": Double(context.artifacts.count), "carriedForward": Double(context.carriedForward.count)])
    }

    /// Covered dates per system: from the timetable in the data directory, else carried forward
    /// from the previous manifest.
    func coverage(_ context: GateContext) throws -> [String: [ServiceDate]] {
        var result: [String: [ServiceDate]] = [:]
        for system in TransitSystem.allCases {
            let name = SetSystems.name(system)
            if let timetable = try context.timetable(system) {
                result[name] = timetable.coveredDates
            } else if let dates = context.previous?.coverage[name] {
                result[name] = dates.compactMap(SetSystems.serviceDate(isoDay:))
            }
        }
        return result
    }

    func currentTripCounts(_ context: GateContext) throws -> [String: [ServiceDate: Int]] {
        var result: [String: [ServiceDate: Int]] = [:]
        for system in TransitSystem.allCases {
            guard let timetable = try context.timetable(system) else { continue }
            result[SetSystems.name(system)] = Dictionary(uniqueKeysWithValues: SetArtifacts.tripCounts(timetable).map { ($0.date, $0.trips) })
        }
        return result
    }

    func previousTripCounts(_ context: GateContext) -> [String: [ServiceDate: Int]]? {
        context.previousTripCounts?.systems.mapValues { counts in
            Dictionary(uniqueKeysWithValues: counts.compactMap { key, value in SetSystems.serviceDate(isoDay: key).map { ($0, value) } })
        }
    }

    /// The streets report must describe this `streets.bin` (by rawSha256); a streets artifact the
    /// previous manifest already had is skipped (it passed when it was built).
    func streetsCheck(_ context: GateContext) throws -> GateCheckResult {
        guard let streets = context.artifacts[.streets] else {
            return GateCheckResult(name: "streets", status: .skipped, summary: "streets carried forward; checked when it was built")
        }
        let unchanged = context.previous?.artifacts[ArtifactKind.streets.name]?.rawSha256 == streets.rawSha256
        let reportURL = reportsDirectory.appendingPathComponent("streets.json")
        let report = try? JSONDecoder().decode(StreetsReportRegions.self, from: Data(contentsOf: reportURL))
        guard let report, report.build.artifact.rawSha256 == streets.rawSha256, let regions = report.build.stats.regions else {
            let why = report == nil ? "no readable \(reportURL.path)"
                : report!.build.artifact.rawSha256 != streets.rawSha256 ? "\(reportURL.lastPathComponent) describes another streets.bin"
                : "\(reportURL.lastPathComponent) has no per-region stats (built before they were reported)"
            if unchanged {
                return GateCheckResult(name: "streets", status: .skipped, summary: "streets.bin unchanged since set \(context.previous!.setId); \(why)")
            }
            return GateCheckResult(name: "streets", status: .fail, summary: "cannot check street shares", failures: [why])
        }
        return GateChecks.streetRegions(regions, thresholds: configuration.thresholds.streets)
    }

    /// Skipped only when links is carried forward (it was checked when it was built). A links
    /// artifact in the data directory is always checked: without the streets it was built against
    /// the check fails, and a system whose timetable is carried forward is left out with a warning.
    func snappingCheck(_ context: GateContext) throws -> GateCheckResult {
        guard let links = try context.links() else {
            return GateCheckResult(name: "snapping", status: .skipped, summary: "links carried forward; checked when it was built")
        }
        guard let streets = try context.streets() else {
            return GateCheckResult(name: "snapping", status: .fail, summary: "cannot check snapping",
                                   failures: ["links.bin is in the data directory but streets.bin is not: the check needs the streets links was built against"])
        }
        let area = streets.serviceArea
        var stops: [GateChecks.SnapStop] = [], failures: [String] = [], unchecked: [String] = []
        for system in TransitSystem.allCases {
            guard let timetable = try context.timetable(system) else {
                unchecked.append("\(ArtifactKind.timetable(for: system).name) is carried forward: its \(links.stopCount(system: system)) stops' snapping not checked")
                continue
            }
            guard links.stopCount(system: system) == timetable.stopCount else {
                failures.append("\(SetSystems.name(system)): links has \(links.stopCount(system: system)) stops, the timetable \(timetable.stopCount)")
                continue
            }
            for local in 0..<timetable.stopCount {
                let global = links.globalStop(system: system, stop: local)
                let flags = links.stopFlags(global)
                guard flags.contains(.routable) else { continue }
                var farthest = 0.0
                for point in links.accessPoints(ofStop: global) { farthest = max(farthest, links.accessPoint(Int(point)).snapMeters) }
                stops.append(GateChecks.SnapStop(
                    id: timetable.stopID(local).rawValue, name: timetable.stopName(local),
                    inServiceArea: area.contains(timetable.stopCoordinate(local)),
                    streetEntry: flags.contains(.streetEntry), streetExit: flags.contains(.streetExit), maxSnapMeters: farthest))
            }
        }
        var result = GateChecks.snapping(stops, maxSnapMeters: configuration.thresholds.snapping.maxSnapMeters,
                                         exceptions: configuration.snapExceptions)
        result.warnings = unchecked + result.warnings
        if !failures.isEmpty {
            result.failures = failures + result.failures
            result.status = .fail
        }
        return result
    }
}

/// The part of `reports/streets.json` the gate reads.
struct StreetsReportRegions: Decodable {
    struct Build: Decodable {
        struct Artifact: Decodable { var rawSha256: String }
        struct Stats: Decodable { var regions: [String: StreetBuildStats.RegionLength]? }
        var artifact: Artifact
        var stats: Stats
    }

    var build: Build
}
