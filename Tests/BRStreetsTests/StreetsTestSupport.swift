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
    /// and the fixture Jersey City and Hoboken (west of the lattice), by code.
    static func regions() throws -> [StreetRegion] {
        let boroughs = try GeoJSONAreas.boroughs(from: data("boroughs-fixture.geojson"), simplifyToleranceMeters: 10)
        let municipalities = try ServiceArea.municipalities(
            fromGeoJSONSequence: data("nj-municipalities-fixture.geojsonseq"), simplifyToleranceMeters: 10
        )
        return (boroughs + municipalities).sorted { $0.code < $1.code }
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

/// Walks a payload's layout by reading each array's `u64` count at the next 8-aligned offset, so
/// tests can find a field without knowing the counts before it.
struct PayloadWalker {
    let payload: Data
    private(set) var offset: Int

    init(_ payload: Data, from offset: Int) {
        self.payload = Data(payload)
        self.offset = offset
    }

    func load<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }

    mutating func skip(_ bytes: Int) {
        offset += bytes
    }

    mutating func u32() -> UInt32 {
        defer { offset += 4 }
        return load(UInt32.self, at: offset)
    }

    /// Skips one array of `elementSize`-byte elements; returns where its elements start.
    @discardableResult
    mutating func array(elementSize: Int) -> (start: Int, count: Int) {
        offset = (offset + 7) / 8 * 8
        let count = Int(load(UInt64.self, at: offset))
        let start = offset + 8
        offset = start + count * elementSize
        return (start, count)
    }
}

/// Byte offsets of the fields the corruption tests change in a `streets` payload.
struct StreetsPayloadLayout {
    var edgeFlags = 0
    var edgeBikeClasses = 0
    var nameOffsets = 0
    var nameBytes = 0
    var nameKinds = 0
    var gridCellOffsets = 0
    var gridCellSegments = 0
    /// Where the regions start (`regionCount`); everything from here to the tail is regions.
    var regions = 0
    var regionCodes: [Int] = []
    var ringCount = 0
    /// Where the extension tail starts: the payload's fixed part is everything before it.
    var tail = 0

    init(_ payload: Data) {
        var walker = PayloadWalker(payload, from: 48) // magic, revision, five u64 counts
        let sizes = [4, 4, 4, 4, 2, 1, 4, 4, 4, 4, 4, 4, 1, 4, 4, 4, 1, 1] // nodeCoordinates … nameKinds
        for (index, size) in sizes.enumerated() {
            let start = walker.array(elementSize: size).start
            switch index {
            case 4: edgeFlags = start
            case 5: edgeBikeClasses = start
            case 15: nameOffsets = start
            case 16: nameBytes = start
            case 17: nameKinds = start
            default: break
            }
        }
        walker.skip(24) // grid origin, cell size, shape
        gridCellOffsets = walker.array(elementSize: 4).start
        gridCellSegments = walker.array(elementSize: 4).start
        regions = walker.offset
        for _ in 0..<Int(walker.u32()) {
            regionCodes.append(walker.offset)
            walker.skip(4)
            let nameLength = Int(walker.u32())
            walker.skip(nameLength)
        }
        walker.array(elementSize: 4) // regionPolygonOffsets
        walker.array(elementSize: 4) // polygonRingOffsets
        ringCount = walker.array(elementSize: 4).count - 1 // ringPointOffsets
        walker.array(elementSize: 4) // ringPoints
        tail = walker.offset
    }
}

extension Data {
    /// A copy with the little-endian `value` written at `offset`.
    func replacing<T: FixedWidthInteger>(_ value: T, at offset: Int) -> Data {
        var copy = Data(self)
        Swift.withUnsafeBytes(of: value.littleEndian) { copy.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
        return copy
    }

    /// `self` (a payload's fixed part) followed by an extension tail written by hand, so ids may
    /// be out of order. Returns the bytes and the payload offset of each entry's id.
    func withRawExtensionTail(_ entries: [(id: UInt32, bytes: [UInt8])]) -> (payload: Data, idOffsets: [Int]) {
        var writer = BinaryWriter()
        writer.append(bytes: self)
        writer.append(UInt32(entries.count))
        var offsets: [Int] = []
        for entry in entries {
            offsets.append(writer.count)
            writer.append(entry.id)
            writer.append(array: entry.bytes)
        }
        return (writer.data, offsets)
    }
}
