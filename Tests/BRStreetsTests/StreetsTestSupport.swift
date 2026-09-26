import BRBuild
import BRData
import BRGeo
import BRStreetCore
import Foundation

/// Paths to the shared synthetic fixtures under `Tests/Fixtures/osm`.
enum StreetsFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("osm")

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// The fixture's service area, as ``StreetsCompiler`` assembles it: the two fixture boroughs,
    /// the Newark Penn disc and the fixture Hudson County (west of the lattice), by code.
    static func regions() throws -> [StreetRegion] {
        let boroughs = try GeoJSONAreas.boroughs(from: data("boroughs-fixture.geojson"), simplifyToleranceMeters: 10)
        let hudson = try ServiceArea.hudsonCounty(fromGeoJSONSequence: data("hudson-county-fixture.geojsonseq"), simplifyToleranceMeters: 10)
        return (boroughs + [ServiceArea.newarkPennArea(), hudson]).sorted { $0.code < $1.code }
    }

    /// The fixture's lattice: node `(x, y)` sits at 40.7 + 0.0009·y, −74 + 0.0012·x (about 100 m).
    static func coordinate(_ x: Double, _ y: Double) -> Coordinate {
        Coordinate(lat: 40.7 + y * 0.0009, lon: -74.0 + x * 0.0012)
    }
}

/// A scratch directory removed when the value is no longer needed.
final class ScratchDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("brstreets-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The fixture compiled, written to disk and mapped back.
struct FixtureStreets {
    let compiled: CompiledStreets
    let stats: StreetBuildStats
    let graph: MappedStreetGraph
    let bytes: Data
    let scratch: ScratchDirectory

    static func build(
        chunkSize: Int = 97, options: StreetBuildOptions = StreetBuildOptions(), extraRegions: [StreetRegion] = []
    ) throws -> FixtureStreets {
        let parks = try GeoJSONAreas.parks(fromGeoJSONSequence: StreetsFixtures.data("parks-fixture.geojsonseq"))
        let regions = try StreetsFixtures.regions() + extraRegions
        var builder = StreetNetworkBuilder(options: options, parks: ParkIndex(polygons: parks))
        var reader = OPLReader(DataChunkSource(try StreetsFixtures.data("streets-fixture.opl"), chunkSize: chunkSize))
        try reader.forEachWay { builder.add($0) }
        let compiled = builder.finish(regions: regions)
        let bytes = StreetsArtifactWriter.artifact(compiled, dataVersion: "fixture", snapCellMeters: 50)
        let scratch = try ScratchDirectory()
        try bytes.write(to: scratch.file(MappedStreetGraph.fileName))
        let graph = try MappedStreetGraph.load(fromDataDirectory: scratch.url)
        return FixtureStreets(compiled: compiled, stats: builder.stats, graph: graph, bytes: bytes, scratch: scratch)
    }

    /// The graph node at lattice point `(x, y)`, if there is one.
    func node(_ x: Double, _ y: Double) -> UInt32? {
        let c = StreetsFixtures.coordinate(x, y)
        let lat = StreetsFormat.microdegrees(c.lat), lon = StreetsFormat.microdegrees(c.lon)
        return (0..<compiled.nodeCount).first {
            compiled.nodeCoordinates[2 * $0] == lat && compiled.nodeCoordinates[2 * $0 + 1] == lon
        }.map(UInt32.init)
    }

    /// Directed edges from `a` to `b`.
    func edges(from a: UInt32, to b: UInt32) -> [Int] {
        graph.outgoingEdges(of: a).filter { graph.target(ofEdge: $0) == b }
    }

    func edge(from a: UInt32, to b: UInt32) -> Int? {
        edges(from: a, to: b).first
    }

    /// Segments whose name is `name`.
    func segments(named name: String) -> [UInt32] {
        (0..<UInt32(graph.segmentCount)).filter { graph.name(id: graph.nameID(ofSegment: $0)) == name }
    }
}
