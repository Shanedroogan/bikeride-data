import BRCore
import BRData
import BRGeo
import BRStreetCore
import Foundation

/// Builds the `stations` artifact: fetch Citi Bike's GBFS discovery and `station_information`
/// (conditional GET), keep service-area stations with docks, snap them to the `streets` graph, compute the
/// dense bike matrix in parallel, write the raw artifact and its `.xz` blob, and report.
public struct StationsCompiler: Sendable {
    public struct Configuration: Sendable {
        public var sourcesDirectory: URL
        public var outputDirectory: URL
        /// The streets artifact to snap and route on.
        public var streetsFile: URL
        public var offline = false
        public var compress = true
        public var threads = ProcessInfo.processInfo.activeProcessorCount
        public var selection = StationSelection()
        /// The profile whose costs pick each path. Its speed only matters for dismount edges,
        /// which cost walking pace relative to riding.
        public var profile = BikeProfile.eBike
        public var maxSnapMeters = 250.0
        /// Station pairs cross-checked against a point-to-point route for the report.
        public var spotChecks = 24

        public init(sourcesDirectory: URL, outputDirectory: URL, streetsFile: URL? = nil) {
            self.sourcesDirectory = sourcesDirectory
            self.outputDirectory = outputDirectory
            self.streetsFile = streetsFile ?? outputDirectory.appendingPathComponent(MappedStreetGraph.fileName)
        }

        public var gbfsDirectory: URL { sourcesDirectory.appendingPathComponent("gbfs") }
        public var discoveryFile: URL { gbfsDirectory.appendingPathComponent("gbfs.json") }
        public var stationInformationFile: URL { gbfsDirectory.appendingPathComponent("station_information.json") }
        public var artifactFile: URL { outputDirectory.appendingPathComponent(MappedStations.fileName) }
    }

    public struct Report: Codable, Sendable {
        /// A matrix entry next to a fresh A* route between the same two snapped stations.
        public struct SpotCheck: Codable, Sendable, Equatable {
            public var from: String
            public var to: String
            public var matrixMeters: Double?
            /// Route length plus both snap legs.
            public var routeMeters: Double?
            public var differenceMeters: Double?
        }

        public var generatedAt: String
        public var tool: String
        public var sources: [SourceRecord]
        public var stationInformationURL: String
        public var feedLastUpdated: Int64?
        public var feedEntriesDropped: Int
        public var selection: StationSelectionStats
        public var snapping: StationSnapStats
        public var matrix: StationMatrixStats
        public var profile: [String: Double]
        public var artifact: BuiltArtifactInfo
        public var readerOpenMilliseconds: Double
        public var spotChecks: [SpotCheck]
        public var seconds: [String: Double]
        public var peakRSSBytes: Int
    }

    public let runner: any ToolRunner
    public let configuration: Configuration

    public init(runner: any ToolRunner, configuration: Configuration) {
        self.runner = runner
        self.configuration = configuration
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

        // 1. Sources.
        let fetcher = SourceFetcher(runner: runner, offline: config.offline)
        let (discovery, information, informationURL) = try timed("download") { () throws -> (SourceRecord, SourceRecord, String) in
            log("fetching \(GBFSStations.discoveryURL)")
            let discovery = try fetcher.fetch(GBFSStations.discoveryURL, to: config.discoveryFile)
            let url = try GBFSStations.stationInformationURL(discovery: Data(contentsOf: config.discoveryFile))
            log("fetching \(url)")
            let information = try fetcher.fetch(url, to: config.stationInformationFile)
            log("  \(information.status), \(information.bytes) bytes")
            return (discovery, information, url)
        }
        let feed = try timed("parse") { try GBFSStations.parseStationInformation(Data(contentsOf: config.stationInformationFile)) }

        // 2. Streets, selection, snapping.
        let graph = try timed("streets") { try MappedStreetGraph(contentsOf: config.streetsFile, validate: true) }
        let streetsSha = try timed("hash") { try ArtifactOutput.sha256(ofFileAt: config.streetsFile, runner: runner) }
        var (stations, selection) = timed("select") { StationsBuilder.select(feed.stations, area: graph.serviceArea, rules: config.selection) }
        log("stations: \(feed.stations.count) in feed, \(stations.count) kept")
        let snapping = timed("snap") {
            StationsBuilder.snap(&stations, graph: graph, bikeProfile: config.profile, maxSnapMeters: config.maxSnapMeters)
        }
        log("snapped: \(snapping.bikeSnapped) to the bike graph, \(snapping.walkSnapped) to the walk graph")

        // 3. Matrix.
        log("matrix: \(stations.count) one-to-all searches on \(config.threads) threads")
        let (matrix, matrixStats) = timed("matrix") {
            StationsBuilder.matrix(for: stations, graph: graph, profile: config.profile, threads: config.threads)
        }
        log(String(format: "matrix: %d reachable pairs of %d in %.1f s", matrixStats.reachablePairs, matrixStats.pairs, seconds["matrix"] ?? 0))

        // 4. Write, compress, re-open.
        let updated = feed.lastUpdated.map { SourceRecord.isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
        let dataVersion = "gbfs=\(updated ?? information.versionTag);streets=\(streetsSha.prefix(12))"
        let builtAgainst = [ArtifactKind.streets.name: streetsSha]
        let bytes = timed("encode") {
            StationsArtifactWriter.artifact(stations: stations, matrix: matrix, profile: config.profile,
                                            dataVersion: dataVersion, builtAgainst: builtAgainst)
        }
        let artifact = try ArtifactOutput.write(
            bytes, to: config.artifactFile, compress: config.compress, runner: runner,
            formatVersion: ArtifactKind.stations.currentFormatVersion, payloadRevision: StationsFormat.payloadRevision,
            dataVersion: dataVersion, builtAgainst: builtAgainst, seconds: &seconds
        )
        let openStart = Date()
        let reader = try MappedStations(contentsOf: config.artifactFile)
        let openMilliseconds = Date().timeIntervalSince(openStart) * 1000
        let checks = timed("spotChecks") { spotCheck(reader, graph: graph, count: config.spotChecks) }
        seconds["total"] = Date().timeIntervalSince(started)

        let multipliers = config.profile.multipliers
        return Report(
            generatedAt: SourceRecord.isoFormatter.string(from: Date()),
            tool: "bikeride-data \(BuildInfo.toolVersion) (Swift \(BuildInfo.swiftVersion))",
            sources: [discovery, information],
            stationInformationURL: informationURL,
            feedLastUpdated: feed.lastUpdated,
            feedEntriesDropped: feed.dropped,
            selection: selection,
            snapping: snapping,
            matrix: matrixStats,
            profile: [
                "speedMetersPerSecond": config.profile.speedMetersPerSecond,
                "dismountSpeedMetersPerSecond": config.profile.dismountSpeedMetersPerSecond,
                "protected": multipliers.protected, "painted": multipliers.painted,
                "shared": multipliers.shared, "arterial": multipliers.arterial,
            ],
            artifact: artifact,
            readerOpenMilliseconds: openMilliseconds,
            spotChecks: checks,
            seconds: seconds,
            peakRSSBytes: TimetableBuild.peakRSSBytes()
        )
    }

    /// Seeded pseudo-random pairs: the stored matrix entry against `route(from:to:)` between the
    /// same stored snaps. Equal-cost paths may differ in length, so small differences can occur.
    func spotCheck(_ stations: MappedStations, graph: MappedStreetGraph, count: Int) -> [Report.SpotCheck] {
        guard stations.count >= 2 else { return [] }
        var rng = SplitMix64(seed: 0x5354_4E53)
        return (0..<count).map { _ in
            let i = rng.nextInt(below: stations.count)
            var j = rng.nextInt(below: stations.count - 1)
            if j >= i { j += 1 }
            var check = Report.SpotCheck(from: stations.stationID(i), to: stations.stationID(j),
                                         matrixMeters: stations.distanceMeters(from: i, to: j))
            if let a = stations.bikeSnap(i).flatMap({ graph.snappedPoint($0, query: stations.coordinate(i)) }),
               let b = stations.bikeSnap(j).flatMap({ graph.snappedPoint($0, query: stations.coordinate(j)) }),
               let route = try? graph.route(from: a, to: b, profile: stations.matrixProfile) {
                let meters = a.distanceMeters + route.lengthMeters + b.distanceMeters
                check.routeMeters = meters
                check.differenceMeters = check.matrixMeters.map { $0 - meters }
            }
            return check
        }
    }
}
