import BRConfig
import BRCore
import BRData
import BRStreetCore
import BRTimetable
import Foundation

/// Builds the `config` artifact: reads the reviewed sources in `Data/` strictly
/// (``ConfigSources``), checks the document (``ConfigValidation``), runs the cross-artifact
/// ``ReferenceChecks`` against the `tt-*` and `stations` artifacts present in the data directory
/// and the Citi Bike price drift warning against GBFS `system_pricing_plans`, then writes
/// `config.bin` and its `.xz` blob, re-opens it and reports.
///
/// Deterministic: equal sources give identical bytes (the `dataVersion` is the JSON's SHA-256;
/// `builtAgainst` is empty), so rebuilding on every pipeline run is harmless. A reference check
/// error writes no artifact (the report says why); a missing input skips its checks unless
/// ``Configuration/requireReferences`` is set. ``run(log:)`` first removes the `config.bin` and
/// `config.bin.xz` a previous run left in the output directory, so a failed run (or one with
/// ``Configuration/compress`` off) never leaves an older config beside the data it would
/// otherwise be taken for.
public struct ConfigCompiler: Sendable {
    public struct Configuration: Sendable {
        /// The `Data/` directory holding `config/` and `fares/`.
        public var sourcesDirectory: URL
        /// Where `tt-*.bin` and `stations.bin` are read from for the reference checks, or `nil`
        /// to skip them.
        public var dataDirectory: URL?
        /// Where `config.bin` (and `.xz`) are written.
        public var outputDirectory: URL
        /// Where GBFS downloads live (`system_pricing_plans.json` is fetched here), or `nil` to
        /// skip the price drift warning.
        public var gbfsDirectory: URL?
        /// Use the pricing plans already downloaded (skip the warning if there are none).
        public var offline = false
        public var compress = true
        /// Fail when an input artifact of a reference check is missing, instead of skipping it.
        public var requireReferences = false

        public init(sourcesDirectory: URL, dataDirectory: URL?, outputDirectory: URL, gbfsDirectory: URL? = nil) {
            self.sourcesDirectory = sourcesDirectory
            self.dataDirectory = dataDirectory
            self.outputDirectory = outputDirectory
            self.gbfsDirectory = gbfsDirectory
        }

        public var artifactFile: URL { outputDirectory.appendingPathComponent(MappedConfig.fileName) }
        public var compressedFile: URL { artifactFile.appendingPathExtension("xz") }
    }

    public struct Report: Codable, Sendable {
        public struct SourceFile: Codable, Sendable, Equatable {
            public var path: String
            public var bytes: Int
            public var sha256: String
        }

        public struct Input: Codable, Sendable, Equatable {
            public var path: String
            public var rawSha256: String
            public var dataVersion: String
        }

        public struct Summary: Codable, Sendable, Equatable {
            public var holidays: Int
            public var lirrOffPeakHolidays: Int
            public var lirrStations: Int
            public var lirrZones: [Int]
            public var lirrZoneFares: Int
            public var outOfSystemTransfers: Int
            public var inSystemTransfers: Int
            public var fixedTransfers: Int
            public var valetStations: Int
            public var pathKeywordRules: Int
            public var flags: Int
            public var unverifiedCitiBikePlans: [String]
        }

        public var generatedAt: String
        public var tool: String
        public var sourcesDirectory: String
        public var sources: [SourceFile]
        public var inputs: [String: Input]
        public var pricingPlans: SourceRecord?
        public var summary: Summary
        public var checks: [ReferenceCheck]
        /// Reference errors: when not empty, no artifact was written.
        public var errors: [String]
        public var warnings: [String]
        public var jsonBytes: Int
        public var jsonSha256: String
        public var payloadSha256: String
        public var artifact: BuiltArtifactInfo?
        public var readerOpenMilliseconds: Double?
        public var seconds: [String: Double]
    }

    public enum ConfigCompileError: Error, CustomStringConvertible {
        case roundTripMismatch(String)

        public var description: String {
            switch self {
            case .roundTripMismatch(let what): "config round trip failed: \(what)"
            }
        }
    }

    /// Citi Bike's pricing plans, when the discovery document can't be read.
    public static let defaultPricingPlansURL = "https://gbfs.lyft.com/gbfs/2.3/bkn/en/system_pricing_plans.json"
    public static let pricingPlansFileName = "system_pricing_plans.json"

    public let runner: any ToolRunner
    public let configuration: Configuration

    public init(runner: any ToolRunner, configuration: Configuration) {
        self.runner = runner
        self.configuration = configuration
    }

    /// The document and its canonical JSON, from the sources alone (no artifact is read or written).
    public func compile() throws -> (document: ConfigDocument, json: Data) {
        let document = try ConfigSources(root: configuration.sourcesDirectory).load()
        let json = try ConfigArtifactWriter.json(document)
        // What the app will read back must be what was built.
        guard try MappedConfig.decode(json) == document else { throw ConfigCompileError.roundTripMismatch("JSON decode") }
        return (document, json)
    }

    public func run(log: (String) -> Void = { _ in }) throws -> Report {
        let config = configuration
        var seconds: [String: Double] = [:]
        func timed<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            defer { seconds[phase, default: 0] += Date().timeIntervalSince(start) }
            return try body()
        }
        let started = Date()

        // 0. Nothing from an earlier run survives this one, whatever happens next.
        for file in [config.artifactFile, config.compressedFile] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
            log("removed the previous \(file.lastPathComponent)")
        }

        // 1. Sources → document.
        let (document, json) = try timed("compile") { try compile() }
        let sources = try timed("hash") {
            try ConfigSources(root: config.sourcesDirectory).files().map { file in
                let url = config.sourcesDirectory.appendingPathComponent(file)
                return Report.SourceFile(path: file, bytes: try Data(contentsOf: url).count,
                                         sha256: try ArtifactOutput.sha256(ofFileAt: url, runner: runner))
            }
        }
        let payload = ConfigArtifactWriter.payload(json: json)
        let jsonSha = try sha256(json), payloadSha = try sha256(payload)
        log("document: \(json.count) bytes of JSON, sha256 \(jsonSha.prefix(12))")

        // 2. Reference inputs.
        var inputs: [String: Report.Input] = [:]
        var missingRequired: [String] = []
        var timetables: [TransitSystem: Timetable] = [:]
        var stations: MappedStations?
        if let data = config.dataDirectory {
            let fixedSystems = document.transit.links.fixedTransfers.flatMap { [$0.from.system, $0.to.system] }.compactMap { $0 }
            let needed = Set([TransitSystem.subway, .lirr] + fixedSystems)
            for system in TransitSystem.allCases where needed.contains(system) {
                let url = data.appendingPathComponent(TimetableBuild.artifactFileName(system))
                guard FileManager.default.fileExists(atPath: url.path) else {
                    missingRequired.append(url.lastPathComponent)
                    continue
                }
                let timetable = try timed("load") { try Timetable(contentsOf: url) }
                timetables[system] = timetable
                inputs[ArtifactKind.timetable(for: system).name] = try timed("hash") {
                    Report.Input(path: url.path, rawSha256: try ArtifactOutput.sha256(ofFileAt: url, runner: runner),
                                 dataVersion: timetable.header.dataVersion)
                }
            }
            let stationsURL = data.appendingPathComponent(MappedStations.fileName)
            if FileManager.default.fileExists(atPath: stationsURL.path) {
                let loaded = try timed("load") { try MappedStations(contentsOf: stationsURL) }
                stations = loaded
                inputs[ArtifactKind.stations.name] = try timed("hash") {
                    Report.Input(path: stationsURL.path, rawSha256: try ArtifactOutput.sha256(ofFileAt: stationsURL, runner: runner),
                                 dataVersion: loaded.header.dataVersion)
                }
            } else {
                missingRequired.append(stationsURL.lastPathComponent)
            }
        } else {
            missingRequired.append("the data directory")
        }

        // 3. GBFS pricing plans (warning only; never fails the build).
        var warnings: [String] = []
        var pricingRecord: SourceRecord?
        var pricingPlans: Data?
        if let gbfs = config.gbfsDirectory {
            let file = gbfs.appendingPathComponent(Self.pricingPlansFileName)
            if config.offline {
                pricingPlans = try? Data(contentsOf: file)
            } else {
                do {
                    let url = Self.pricingPlansURL(discovery: gbfs.appendingPathComponent("gbfs.json"))
                    log("fetching \(url)")
                    pricingRecord = try timed("download") { try SourceFetcher(runner: runner, offline: false).fetch(url, to: file) }
                    pricingPlans = try Data(contentsOf: file)
                } catch {
                    warnings.append("system_pricing_plans not fetched (\(error)); the price drift check is skipped")
                }
            }
        }

        // 4. Reference checks.
        let checks = timed("checks") {
            ReferenceChecks.run(document, inputs: ReferenceChecks.Inputs(timetables: timetables, stations: stations, pricingPlans: pricingPlans))
        }
        var errors = checks.flatMap(\.errors)
        warnings += checks.flatMap(\.warnings)
        for check in checks {
            if let reason = check.skipped { warnings.append("\(check.name) skipped: \(reason)") }
            log("check \(check.name): \(check.skipped.map { "skipped (\($0))" } ?? (check.errors.isEmpty ? "passed" : "FAILED")), \(check.checked) checked, \(check.errors.count) errors, \(check.warnings.count) warnings")
        }
        if config.requireReferences, !missingRequired.isEmpty {
            errors.append("reference inputs missing: \(missingRequired.joined(separator: ", "))")
        }
        for warning in warnings { log("warning: \(warning)") }
        for error in errors { log("error: \(error)") }

        // 5. Write, compress, re-open (only when every check passed).
        var artifact: BuiltArtifactInfo?
        var openMilliseconds: Double?
        if errors.isEmpty {
            let dataVersion = ConfigArtifactWriter.dataVersion(jsonSha256: jsonSha)
            let bytes = ConfigArtifactWriter.artifact(json: json, dataVersion: dataVersion)
            artifact = try ArtifactOutput.write(
                bytes, to: config.artifactFile, compress: config.compress, runner: runner,
                formatVersion: ArtifactKind.config.currentFormatVersion, payloadRevision: ConfigFormat.payloadRevision,
                dataVersion: dataVersion, builtAgainst: [:], seconds: &seconds
            )
            let openStart = Date()
            let reopened = try MappedConfig(contentsOf: config.artifactFile)
            openMilliseconds = Date().timeIntervalSince(openStart) * 1000
            guard reopened.document == document, reopened.json == json else {
                throw ConfigCompileError.roundTripMismatch(config.artifactFile.path)
            }
        }
        seconds["total"] = Date().timeIntervalSince(started)

        let plans = document.fares.citiBike.plans
        return Report(
            generatedAt: SourceRecord.isoFormatter.string(from: Date()),
            tool: "bikeride-data \(BuildInfo.toolVersion) (Swift \(BuildInfo.swiftVersion))",
            sourcesDirectory: config.sourcesDirectory.path,
            sources: sources,
            inputs: inputs,
            pricingPlans: pricingRecord,
            summary: Report.Summary(
                holidays: document.calendar.holidays.count,
                lirrOffPeakHolidays: document.calendar.holidays.filter(\.lirrOffPeak).count,
                lirrStations: document.fares.lirr.stations.count,
                lirrZones: Set(document.fares.lirr.stations.map(\.zone)).sorted(),
                lirrZoneFares: document.fares.lirr.zoneFares.count,
                outOfSystemTransfers: document.fares.mta.outOfSystemTransfers.count,
                inSystemTransfers: document.fares.mta.inSystemTransfers.count,
                fixedTransfers: document.transit.links.fixedTransfers.count,
                valetStations: document.bikeShare.valet.count,
                pathKeywordRules: document.alerts.pathKeywords.count,
                flags: document.flags.count,
                unverifiedCitiBikePlans: [("nonMember", plans.nonMember), ("member", plans.member), ("dayPass", plans.dayPass),
                                          ("reducedFare", plans.reducedFare)].filter { !$0.1.verified }.map(\.0)
            ),
            checks: checks,
            errors: errors,
            warnings: warnings,
            jsonBytes: json.count,
            jsonSha256: jsonSha,
            payloadSha256: payloadSha,
            artifact: artifact,
            readerOpenMilliseconds: openMilliseconds,
            seconds: seconds
        )
    }

    /// The `system_pricing_plans` URL from a saved GBFS discovery document, or the default.
    public static func pricingPlansURL(discovery file: URL, language: String = "en") -> String {
        struct Discovery: Decodable {
            struct Language: Decodable { let feeds: [Feed] }
            struct Feed: Decodable { let name: String; let url: String }
            let data: [String: Language]
        }
        guard let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Discovery.self, from: data),
              let url = decoded.data[language]?.feeds.first(where: { $0.name == "system_pricing_plans" })?.url else {
            return defaultPricingPlansURL
        }
        return url
    }

    private func sha256(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        return CryptoKitHasher().sha256(of: data).hex
        #else
        return try ProcessHasher(runner: runner).sha256(of: data).hex
        #endif
    }
}
