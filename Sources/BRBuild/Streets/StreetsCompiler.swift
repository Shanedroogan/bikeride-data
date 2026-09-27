import BRCore
import BRData
import BRGeo
import BRStreetCore
import Foundation

/// Builds the `streets` artifact from the Geofabrik New York and New Jersey extracts and the NYC
/// borough boundaries: download (conditional), Jersey City's and Hoboken's boundaries, osmium
/// clip/merge/filter/locate, OPL → graph, write, xz. The exact commands are published in
/// `docs/osm-derivation.md`.
public struct StreetsCompiler: Sendable {
    public static let osmURL = "https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf"
    public static let njOSMURL = "https://download.geofabrik.de/north-america/us/new-jersey-latest.osm.pbf"
    /// NYC Open Data "Borough Boundaries (water areas included)", DCP.
    public static let boroughsURL = "https://data.cityofnewyork.us/resource/wh2p-dxnf.geojson"

    public struct Configuration: Sendable {
        public var sourcesDirectory: URL
        public var outputDirectory: URL
        /// Intermediate `.osm.pbf` files.
        public var workDirectory: URL
        public var offline = false
        /// West, south, east, north: the five boroughs' extent plus about 1 km.
        public var bbox = (west: -74.2710, south: 40.4680, east: -73.6880, north: 40.9270)
        /// Ways with no node within this distance of a service-area region are dropped.
        public var bufferMeters = 1000.0
        /// The New Jersey extract is clipped to the regions' convex hull grown by this much (more
        /// than ``bufferMeters``, so the city mask, not the clip, decides what is kept).
        public var njClipBufferMeters = 1500.0
        /// Douglas–Peucker tolerance for the stored borough polygons.
        public var boroughToleranceMeters = 10.0
        public var options = StreetBuildOptions()
        public var compress = true

        public init(sourcesDirectory: URL, outputDirectory: URL, workDirectory: URL? = nil) {
            self.sourcesDirectory = sourcesDirectory
            self.outputDirectory = outputDirectory
            self.workDirectory = workDirectory
                ?? outputDirectory.deletingLastPathComponent().appendingPathComponent("work/streets")
        }

        public var osmFile: URL { sourcesDirectory.appendingPathComponent("osm/new-york-latest.osm.pbf") }
        public var njOSMFile: URL { sourcesDirectory.appendingPathComponent("osm/new-jersey-latest.osm.pbf") }
        public var boroughsFile: URL { sourcesDirectory.appendingPathComponent("nyc/borough-boundaries-water-included.geojson") }
    }

    public struct Report: Codable, Sendable {
        public struct Artifact: Codable, Sendable {
            public var path: String
            public var rawBytes: Int
            public var rawSha256: String
            public var xzPath: String?
            public var xzBytes: Int?
            public var xzStreams: Int?
            public var xzBlocks: Int?
            public var formatVersion: Int
            public var payloadRevision: Int
            public var dataVersion: String
        }

        public var generatedAt: String
        public var sources: [SourceRecord]
        public var commands: [String]
        public var stats: StreetBuildStats
        public var parkPolygons: Int
        public var regions: [String]
        public var snapGridCells: Int
        public var snapGridEntries: Int
        public var artifact: Artifact
        /// Seconds per phase.
        public var seconds: [String: Double]
    }

    public let runner: any ToolRunner
    public let configuration: Configuration

    public init(runner: any ToolRunner, configuration: Configuration) {
        self.runner = runner
        self.configuration = configuration
    }

    public func run(log: (String) -> Void = { _ in }) throws -> Report {
        let config = configuration
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: config.workDirectory, withIntermediateDirectories: true)
        var seconds: [String: Double] = [:]
        var commands: [String] = []
        func timed<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            defer { seconds[phase, default: 0] += Date().timeIntervalSince(start) }
            return try body()
        }
        func osmium(_ args: [String]) throws {
            commands.append((["osmium"] + args).joined(separator: " "))
            _ = try runner.run(executable: "osmium", args: args)
        }

        // 1. Sources.
        let fetcher = SourceFetcher(runner: runner, offline: config.offline)
        let (osm, njOSM, boroughs) = try timed("download") {
            log("fetching \(Self.osmURL)")
            let osm = try fetcher.fetch(Self.osmURL, to: config.osmFile)
            log("  \(osm.status), \(osm.bytes) bytes")
            log("fetching \(Self.njOSMURL)")
            let njOSM = try fetcher.fetch(Self.njOSMURL, to: config.njOSMFile)
            log("  \(njOSM.status), \(njOSM.bytes) bytes")
            log("fetching \(Self.boroughsURL)")
            let boroughs = try fetcher.fetch(Self.boroughsURL, to: config.boroughsFile)
            log("  \(boroughs.status), \(boroughs.bytes) bytes")
            return (osm, njOSM, boroughs)
        }

        // 2. Service-area regions (borough polygons, Jersey City, Hoboken) and the city mask.
        let work = config.workDirectory
        let boundaryPBF = work.appendingPathComponent("nj-municipal-boundaries.osm.pbf")
        let boroughRegions = try timed("boroughs") {
            try GeoJSONAreas.boroughs(from: Data(contentsOf: config.boroughsFile), simplifyToleranceMeters: config.boroughToleranceMeters)
        }
        let njRegions = try timed("municipalities") { () throws -> [StreetRegion] in
            try osmium(["tags-filter", config.njOSMFile.path, ServiceArea.municipalitiesFilter,
                        "--overwrite", "--no-progress", "-o", boundaryPBF.path])
            let args = ["export", boundaryPBF.path, "-f", "geojsonseq", "--geometry-types=polygon", "--no-progress"]
            commands.append((["osmium"] + args).joined(separator: " "))
            return try ServiceArea.municipalities(
                fromGeoJSONSequence: runner.run(executable: "osmium", args: args),
                simplifyToleranceMeters: config.boroughToleranceMeters
            )
        }
        let regions = (boroughRegions + njRegions).sorted { $0.code < $1.code }
        let mask = timed("mask") { CityMask(regions: regions.map(\.area), bufferMeters: config.bufferMeters) }

        // 3. Clip New York to the city's bounding box and New Jersey to its regions' grown hull,
        //    merge them (one version per object), then pull out parks and highways.
        let clipped = work.appendingPathComponent("nyc-bbox.osm.pbf")
        let njPolygon = work.appendingPathComponent("nj-clip.geojson")
        let njClipped = work.appendingPathComponent("nj-clip.osm.pbf")
        let merged = work.appendingPathComponent("merged.osm.pbf")
        let combined = work.appendingPathComponent("service-area.osm.pbf")
        let parksPBF = work.appendingPathComponent("service-area-parks.osm.pbf")
        let highways = work.appendingPathComponent("service-area-highways.osm.pbf")
        let located = work.appendingPathComponent("service-area-highways-located.osm.pbf")
        let b = config.bbox
        try timed("osmium") {
            log("osmium: clip, merge, filter, add locations")
            try osmium(["extract", "--bbox=\(b.west),\(b.south),\(b.east),\(b.north)", "--strategy=complete_ways",
                        "--overwrite", "--no-progress", "-o", clipped.path, config.osmFile.path])
            try ServiceArea.geoJSONPolygonFeature(ServiceArea.bufferedHull(of: njRegions, bufferMeters: config.njClipBufferMeters))
                .write(to: njPolygon, options: .atomic)
            try osmium(["extract", "--polygon=\(njPolygon.path)", "--strategy=complete_ways",
                        "--overwrite", "--no-progress", "-o", njClipped.path, config.njOSMFile.path])
            try osmium(["merge", clipped.path, njClipped.path, "--overwrite", "--no-progress", "-o", merged.path])
            // The two extracts may hold different versions of a border object; keep the newest.
            try osmium(["time-filter", merged.path, "--overwrite", "--no-progress", "-o", combined.path])
            try osmium(["tags-filter", combined.path, "a/leisure=park,garden,nature_reserve", "a/landuse=recreation_ground",
                        "--overwrite", "--no-progress", "-o", parksPBF.path])
            try osmium(["tags-filter", combined.path, "w/highway", "--overwrite", "--no-progress", "-o", highways.path])
            try osmium(["add-locations-to-ways", highways.path, "--overwrite", "--no-progress", "-o", located.path])
        }
        let parkPolygons = try timed("parks") { () throws -> [Polygon] in
            let args = ["export", parksPBF.path, "-f", "geojsonseq", "--geometry-types=polygon", "--no-progress"]
            commands.append((["osmium"] + args).joined(separator: " "))
            return try GeoJSONAreas.parks(fromGeoJSONSequence: runner.run(executable: "osmium", args: args))
        }
        log("parks: \(parkPolygons.count) polygons")

        // 4. Stream the ways as OPL into the builder.
        var builder = StreetNetworkBuilder(options: config.options, mask: mask, parks: ParkIndex(polygons: parkPolygons))
        try timed("parse") {
            let args = ["cat", located.path, "-t", "way", "-f", "opl,add_metadata=false,locations_on_ways=true"]
            commands.append((["osmium"] + args).joined(separator: " "))
            let stream = try runner.stream(executable: "osmium", args: args)
            var reader = OPLReader(FileHandleChunkSource(stream.output, chunkSize: 4 << 20))
            do {
                try reader.forEachWay { builder.add($0) }
            } catch {
                stream.terminate()
                throw error
            }
            try stream.waitUntilExit()
            builder.noteNodesWithoutLocation(reader.nodesWithoutLocation)
        }
        log("ways: \(builder.stats.waysRead) read, \(builder.stats.waysKept) kept")
        let compiled = timed("build") { builder.finish(regions: regions) }
        var stats = builder.stats
        log("graph: \(stats.vertices) nodes, \(stats.directedEdges) edges, \(stats.segments) segments")

        // 5. Write, compress, verify.
        let dataVersion = "osm=\(osm.versionTag);njosm=\(njOSM.versionTag);boroughs=\(boroughs.versionTag)"
        let bytes = timed("write") { StreetsArtifactWriter.artifact(compiled, dataVersion: dataVersion, snapCellMeters: config.options.snapCellMeters) }
        let artifactURL = config.outputDirectory.appendingPathComponent(MappedStreetGraph.fileName)
        try timed("write") { try bytes.write(to: artifactURL, options: .atomic) }
        let graph = try timed("verify") { try MappedStreetGraph(contentsOf: artifactURL, validate: true) }
        stats.directedEdges = graph.edgeCount
        let sha = try timed("hash") { try Self.hasher(runner: runner).sha256(ofFileAt: artifactURL).hex }

        var artifact = Report.Artifact(
            path: artifactURL.path, rawBytes: bytes.count, rawSha256: sha,
            formatVersion: Int(ArtifactKind.streets.currentFormatVersion),
            payloadRevision: Int(StreetsFormat.payloadRevision), dataVersion: dataVersion
        )
        if config.compress {
            try timed("xz") {
                let xzURL = URL(fileURLWithPath: artifactURL.path + ".xz")
                log("xz -6 -T1 --check=crc32")
                _ = try runner.run(executable: "xz", args: ["-6", "-T1", "--check=crc32", "--keep", "--force", artifactURL.path])
                let listing = try XZCheck.verify(xzURL, runner: runner)
                artifact.xzPath = xzURL.path
                artifact.xzBytes = ((try? fileManager.attributesOfItem(atPath: xzURL.path))?[.size] as? NSNumber)?.intValue
                artifact.xzStreams = listing.streams
                artifact.xzBlocks = listing.blocks
            }
        }

        return Report(
            generatedAt: SourceRecord.isoFormatter.string(from: Date()),
            sources: [osm, njOSM, boroughs],
            commands: commands,
            stats: stats,
            parkPolygons: parkPolygons.count,
            regions: regions.map(\.name),
            snapGridCells: graph.grid.cellCount,
            snapGridEntries: graph.gridEntryCount,
            artifact: artifact,
            seconds: seconds
        )
    }

    static func hasher(runner: any ToolRunner) throws -> any Hasher256 {
        #if canImport(CryptoKit)
        return CryptoKitHasher()
        #else
        return try ProcessHasher(runner: runner)
        #endif
    }
}
