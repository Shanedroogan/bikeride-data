import BRBuild
import BRCore
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

/// The smallest hand-built street network: five nodes and seven segments written straight into
/// ``CompiledStreets``, with no OSM input and no builder rules, so its bytes change only when the
/// writer or the format does. The payload golden and the committed v1 file are made from it.
///
///     n2 (900, −1200) ─s3 Café─ n3 (900, 0) ═s4 bike path / s5 steps═ n4 (900, 1200) ⟲ s6 loop
///        │ s1 Beta                 │ s2 B1 (bridge)
///     n0 (−900, −1200) ─s0 Alpha─ n1 (−900, 0)
///
/// Coordinates are microdegrees (lat, lon). The network straddles the equator: the snap grid's
/// middle latitude is exactly 0, so the writer's `cos` is exactly 1 and the bytes are the same on
/// every platform. Between them the segments use every edge flag bit, bike class and name kind, a
/// one-way bike direction, a direction nobody may use (s4 B→A, not stored), two parallel segments
/// and a loop (A = B).
enum HandBuiltStreets {
    static let snapCellMeters = 100.0

    static func compiled() -> CompiledStreets {
        let walk: UInt16 = 1 << 0, bike: UInt16 = 1 << 1, stairs: UInt16 = 1 << 2, bridge: UInt16 = 1 << 3
        let park: UInt16 = 1 << 4, connector: UInt16 = 1 << 5, dismount: UInt16 = 1 << 6
        var c = CompiledStreets()
        c.nodeCoordinates = [-900, -1200, -900, 0, 900, -1200, 900, 0, 900, 1200]
        // Sorted by (A, B), as the builder writes them.
        c.segmentNodes = [0, 1, 0, 2, 1, 3, 2, 3, 3, 4, 3, 4, 4, 4]
        c.segmentLengthDecimeters = [1334, 2014, 2002, 1341, 1334, 1353, 3336]
        c.forwardFlags = [walk | bike, walk | bike, walk | bike | bridge, walk | bike | park, bike, walk | stairs, walk | bike | connector | dismount]
        c.backwardFlags = [walk | bike, walk, walk | bike | bridge, walk | bike | park, 0, walk | stairs, walk | bike | connector | dismount]
        c.forwardClasses = [1, 2, 3, 0, 0, 2, 2]  // painted, shared, arterial, protected, …
        c.backwardClasses = [2, 2, 3, 0, 0, 2, 2]
        c.names = ["Alpha Street", "B1", "Beta Avenue", "Café Street", "Gamma Plaza", "bike path", "steps"]  // by bytes
        c.nameKinds = [.tagged, .ref, .tagged, .tagged, .tagged, .derived, .derived]
        c.segmentNameIDs = [0, 2, 1, 3, 5, 6, 4]
        c.segmentBearings = [64, 64, 252, 4, 0, 0, 69, 59, 64, 64, 71, 57, 64, 0]
        c.segmentShapeOffsets = [0, 0, 1, 1, 3, 3, 4, 7]
        c.shapePoints = [0, -1300, 850, -800, 850, -400, 800, 600, 900, 1800, 0, 1800, 0, 1200]
        func ring(_ points: [(Int32, Int32)]) -> [Coordinate] {
            points.map { Coordinate(lat: StreetsFormat.degrees($0.0), lon: StreetsFormat.degrees($0.1)) }
        }
        let west = Polygon(
            exterior: ring([(-2000, -2000), (-2000, 0), (2000, 0), (2000, -2000), (-2000, -2000)]),
            holes: [ring([(-500, -1500), (-100, -1500), (-100, -1000), (-500, -1000), (-500, -1500)])]
        )
        let east = Polygon(exterior: ring([(-2000, 0), (-2000, 3000), (2000, 3000), (2000, 0), (-2000, 0)]))
        c.regions = [
            StreetRegion(code: 1, name: "Test West", area: MultiPolygon([west])),
            StreetRegion(code: 2, name: "Test East", area: MultiPolygon([east])),
        ]
        return c
    }

    /// The artifact file, with the header every v1 fixture uses.
    static func artifact(dataVersion: String = V1Fixtures.dataVersion) -> Data {
        StreetsArtifactWriter.artifact(compiled(), dataVersion: dataVersion, snapCellMeters: snapCellMeters)
    }
}

/// The committed v1 files in `Tests/Fixtures/v1`: artifacts written from the hand-typed inputs
/// (none compiled from OSM, GBFS or GTFS) when the formats froze (2026-09-26), which every later
/// reader must still open. They are
/// frozen, not regenerated when the writer changes: `BR_WRITE_V1_FIXTURES=1 swift test --filter
/// V1` rewrites them (and skips the tests that read them), for a deliberate reason only.
enum V1Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("v1")
    static let dataVersion = "v1-fixture"
    static let regenerating = ProcessInfo.processInfo.environment["BR_WRITE_V1_FIXTURES"] == "1"

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func write(_ bytes: Data, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// `file` with its header's formatVersion (the `u16` at byte 8) replaced.
    static func withFormatVersion(_ version: UInt16, _ file: Data) -> Data {
        var copy = Data(file)
        copy[copy.startIndex + 8] = UInt8(version & 0xFF)
        copy[copy.startIndex + 9] = UInt8(version >> 8)
        return copy
    }

    /// Lowercase-hex SHA-256 of the payload alone (the bytes from headerLength on): the header
    /// embeds builderSwiftVersion, so the file's own hash changes with every toolchain.
    static func payloadSHA256(_ file: Data) throws -> String {
        let payload = Data(try ArtifactHeader.decode(from: file).payload)
        #if canImport(CryptoKit)
        return CryptoKitHasher().sha256(of: payload).hex
        #else
        return try ProcessHasher(runner: ProcessToolRunner()).sha256(of: payload).hex
        #endif
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
