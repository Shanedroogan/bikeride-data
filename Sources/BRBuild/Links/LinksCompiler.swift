import BRCore
import BRData
import BRGeo
import BRStreetCore
import BRTimetable
import Foundation

/// Builds the `links` artifact from the `streets`, `stations` and `tt-*` artifacts in a data
/// directory: access points, transitively closed footpaths, stop↔station walk links, and (with
/// stations) the rail bike hops (``HopBuilder``: parent station A → the 2 best pickups near A ×
/// the 2 best docks near parent station B, rides of 5–25 min, dropped when a one-seat ride beats
/// the bike); then writes the raw artifact and its `.xz` blob, re-opens it, checks the footpath
/// invariants and reports.
public struct LinksCompiler: Sendable {
    public struct Configuration: Sendable {
        /// Where `streets.bin`, `stations.bin` and `tt-*.bin` are read from.
        public var dataDirectory: URL
        /// Where `links.bin` (and `.xz`) are written.
        public var outputDirectory: URL
        public var compress = true
        public var options = LinksOptions()
        /// Run ``FootpathCheck`` over the result (a few seconds on the city).
        public var checkFootpaths = true

        public init(dataDirectory: URL, outputDirectory: URL? = nil) {
            self.dataDirectory = dataDirectory
            self.outputDirectory = outputDirectory ?? dataDirectory
        }

        public var artifactFile: URL { outputDirectory.appendingPathComponent(MappedLinks.fileName) }
    }

    public struct Report: Codable, Sendable {
        public struct Input: Codable, Sendable, Equatable {
            public var path: String
            public var rawSha256: String
            public var dataVersion: String
        }

        public var generatedAt: String
        public var tool: String
        public var inputs: [String: Input]
        public var warnings: [String]
        public var parameters: [String: Double]
        public var network: LinkNetworkStats
        public var footpaths: FootpathStats
        public var footpathCheck: FootpathCheck?
        public var stationLinks: StationLinkStats
        /// The rail bike hops; `nil` when none were built (no stations, or disabled).
        public var hops: HopStats?
        /// Walkable segments whose two directions differ (station links assume symmetric walking).
        public var asymmetricWalkSegments: Int
        public var artifact: BuiltArtifactInfo
        public var readerOpenMilliseconds: Double
        public var seconds: [String: Double]
        public var peakRSSBytes: Int
    }

    public enum LinksError: Error, CustomStringConvertible {
        case missingInput(String)
        /// A stored hop pickup (dock) some platform of its station has no exit (enter) link to.
        case hopWithoutPlatformLink(missing: Int, examples: [String])

        public var description: String {
            switch self {
            case .missingInput(let path): "\(path) is missing; build it first"
            case .hopWithoutPlatformLink(let missing, let examples):
                "\(missing) hop (platform, station) pairs lack a station link, e.g. \(examples.prefix(3))"
            }
        }
    }

    public let runner: any ToolRunner
    public let configuration: Configuration

    public init(runner: any ToolRunner, configuration: Configuration) {
        self.runner = runner
        self.configuration = configuration
    }

    public func run(log: (String) -> Void = { _ in }) throws -> Report {
        let config = configuration
        let options = config.options
        var seconds: [String: Double] = [:]
        func timed<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            defer { seconds[phase, default: 0] += Date().timeIntervalSince(start) }
            return try body()
        }
        let started = Date()
        let fileManager = FileManager.default
        var inputs: [String: Report.Input] = [:]
        var warnings: [String] = []
        func input(_ kind: ArtifactKind, _ url: URL, _ header: ArtifactHeader) throws {
            inputs[kind.name] = Report.Input(path: url.path, rawSha256: try ArtifactOutput.sha256(ofFileAt: url, runner: runner),
                                             dataVersion: header.dataVersion)
        }

        // 1. Inputs.
        let streetsURL = config.dataDirectory.appendingPathComponent(MappedStreetGraph.fileName)
        guard fileManager.fileExists(atPath: streetsURL.path) else { throw LinksError.missingInput(streetsURL.path) }
        let graph = try timed("load") { try MappedStreetGraph(contentsOf: streetsURL, validate: true) }
        try timed("hash") { try input(.streets, streetsURL, graph.header) }
        var timetables: [TransitSystem: Timetable] = [:]
        for system in LinksFormat.systems {
            let url = config.dataDirectory.appendingPathComponent(TimetableBuild.artifactFileName(system))
            guard fileManager.fileExists(atPath: url.path) else {
                warnings.append("\(url.lastPathComponent) missing; \(system.linkReportName) stops are not linked")
                continue
            }
            let timetable = try timed("load") { try Timetable(contentsOf: url) }
            timetables[system] = timetable
            try timed("hash") { try input(ArtifactKind.timetable(for: system), url, timetable.header) }
        }
        let stationsURL = config.dataDirectory.appendingPathComponent(MappedStations.fileName)
        var stations: MappedStations?
        if fileManager.fileExists(atPath: stationsURL.path) {
            let loaded = try timed("load") { try MappedStations(contentsOf: stationsURL) }
            stations = loaded
            try timed("hash") { try input(.stations, stationsURL, loaded.header) }
            if let against = loaded.header.builtAgainst[ArtifactKind.streets.name], against != inputs[ArtifactKind.streets.name]?.rawSha256 {
                warnings.append("stations.bin was built against another streets.bin (\(against.prefix(12))); its snaps may be stale")
            }
        } else {
            warnings.append("stations.bin missing; no station links")
        }
        for warning in warnings { log("warning: \(warning)") }

        // 2. Network, footpaths, station links.
        let (network, networkStats) = timed("network") { LinkNetwork.make(timetables: timetables, graph: graph, options: options) }
        log("network: \(network.stopCount) stops, \(network.routable.filter { $0 }.count) routable, \(network.accessPoints.count) access points, \(network.transfers.count) transfer pairs")
        for unresolved in networkStats.fixedTransfersUnresolved where timetables.count == LinksFormat.systems.count {
            warnings.append("fixed transfer \(unresolved) not applied: stop not found or not routable")
            log("warning: \(warnings.last!)")
        }
        let anchors: [LinkAnchor?] = stations.map { stations in
            (0..<stations.count).map { index in
                stations.walkSnap(index).flatMap { graph.snappedPoint($0, query: stations.coordinate(index)) }.map(LinkAnchor.init)
            }
        } ?? []
        var compiled = timed("search") { LinksBuilder.build(network: network, stationAnchors: anchors, graph: graph, options: options) }
        log("footpaths: \(compiled.footpaths.count); station links: \(compiled.stationLinks.count)")
        var hopStats: HopStats?
        if let stations, options.hops.enabled {
            let parents = RailParents.make(timetables: timetables, network: network)
            let oneSeat = timed("oneSeat") { OneSeatTable.build(timetables: timetables, network: network, parents: parents, options: options.hops) }
            let inputs = HopBuilder.Inputs(systemStopCounts: network.systemStopCounts, parents: parents, stationLinks: compiled.stationLinks,
                                           stationCount: stations.count, distances: stations, oneSeat: oneSeat)
            var (hops, stats) = timed("hops") { HopBuilder.build(inputs, options: options.hops, threads: options.threads) }
            HopBuilder.checkPlatformLinks(hops, parents: parents, stationLinks: compiled.stationLinks, stats: &stats)
            log("hops: \(hops.count) over \(stats.origins) origins (\(stats.candidatePairs) candidates; dropped \(stats.droppedBelowWindow) short, "
                + "\(stats.droppedAboveWindow) long, \(stats.droppedByOneSeat) by a one-seat ride)")
            let missing = stats.platformPickupLinksMissing + stats.platformDockLinksMissing
            guard missing == 0 else { throw LinksError.hopWithoutPlatformLink(missing: missing, examples: stats.missingLinkExamples) }
            compiled.hops = hops
            hopStats = stats
        }
        let check = config.checkFootpaths
            ? timed("check") {
                FootpathCheck.run(compiled.footpaths, walkSeconds: Int(options.maxFootpathWalkSeconds),
                                  stopAccessSeconds: LinksBuilder.stopAccessSeconds(network, options))
            } : nil
        if let check { log("footpath check: \(check.triplesChecked) triples, \(check.passed ? "passed" : "FAILED \(check.examples)")") }
        let asymmetric = timed("symmetry") { Self.asymmetricWalkSegments(graph, walk: options.walk) }

        // 3. Write, compress, re-open.
        let builtAgainst = inputs.mapValues(\.rawSha256)
        let dataVersion = inputs.keys.sorted().map { "\($0)=\(inputs[$0]!.rawSha256.prefix(12))" }.joined(separator: ";")
        let bytes = timed("encode") { LinksArtifactWriter.artifact(compiled, dataVersion: dataVersion, builtAgainst: builtAgainst) }
        let artifact = try ArtifactOutput.write(
            bytes, to: config.artifactFile, compress: config.compress, runner: runner,
            formatVersion: ArtifactKind.links.currentFormatVersion, payloadRevision: LinksFormat.payloadRevision,
            dataVersion: dataVersion, builtAgainst: builtAgainst, seconds: &seconds
        )
        let openStart = Date()
        let reopened = try MappedLinks(contentsOf: config.artifactFile)
        let openMilliseconds = Date().timeIntervalSince(openStart) * 1000
        hopStats?.blockBytes = reopened.extensions[LinksFormat.hopsExtensionID]?.count ?? 0
        seconds["total"] = Date().timeIntervalSince(started)

        return Report(
            generatedAt: SourceRecord.isoFormatter.string(from: Date()),
            tool: "bikeride-data \(BuildInfo.toolVersion) (Swift \(BuildInfo.swiftVersion))",
            inputs: inputs,
            warnings: warnings,
            parameters: [
                "maxFootpathWalkSeconds": Double(options.maxFootpathWalkSeconds),
                "minTransferSeconds": Double(options.minTransferSeconds),
                "stationLinkMaxWalkMeters": options.stationLinkMaxWalkMeters,
                "walkSpeedMetersPerSecond": options.walk.speedMetersPerSecond,
                "stairsMultiplier": options.walk.stairsMultiplier,
                "threads": Double(options.threads),
            ].merging(options.accessSeconds.map { ("accessSeconds.\($0.key.linkReportName)", Double($0.value)) }) { a, _ in a }
                .merging(options.maxSnapMeters.map { ("maxSnapMeters.\($0.key.linkReportName)", $0.value) }) { a, _ in a }
                .merging(Self.hopParameters(options.hops)) { a, _ in a },
            network: networkStats,
            footpaths: compiled.footpathStats,
            footpathCheck: check,
            stationLinks: compiled.stationLinkStats,
            hops: hopStats,
            asymmetricWalkSegments: asymmetric,
            artifact: artifact,
            readerOpenMilliseconds: openMilliseconds,
            seconds: seconds,
            peakRSSBytes: TimetableBuild.peakRSSBytes()
        )
    }

    /// The hop tunables as report parameters (`hops.…`).
    static func hopParameters(_ options: HopOptions) -> [String: Double] {
        let p = options.parameters
        let values: [(String, Int)] = [
            ("minRideSeconds", p.minRideSeconds), ("maxRideSeconds", p.maxRideSeconds),
            ("minSpeedMmPerSecond", p.minSpeedMmPerSecond), ("maxSpeedMmPerSecond", p.maxSpeedMmPerSecond),
            ("rankSpeedMmPerSecond", p.rankSpeedMmPerSecond), ("unlockSeconds", p.unlockSeconds), ("dockSeconds", p.dockSeconds),
            ("pickupsPerHop", p.pickupsPerHop), ("docksPerHop", p.docksPerHop), ("oneSeatFilter", options.oneSeatFilter ? 1 : 0),
            ("middayStartSeconds", options.middayStartSeconds), ("middayEndSeconds", options.middayEndSeconds),
            ("afterBikeMinSeconds", options.afterBikeMinSeconds), ("afterBikeRidePermille", options.afterBikeRidePermille),
        ]
        return Dictionary(uniqueKeysWithValues: values.map { ("hops.\($0.0)", Double($0.1)) })
    }

    /// Segments walkable one way only, or at different costs each way.
    static func asymmetricWalkSegments(_ graph: MappedStreetGraph, walk: WalkProfile) -> Int {
        graph.withView { view in
            var count = 0
            for segment in 0..<UInt32(graph.segmentCount) {
                let (forward, backward) = graph.edges(ofSegment: segment)
                let a = forward.flatMap { walk.costMs(ofEdge: Int($0), in: view) }
                let b = backward.flatMap { walk.costMs(ofEdge: Int($0), in: view) }
                if a != b { count += 1 }
            }
            return count
        }
    }
}
