import BRBuild
import BRCore
import BRData
import BRGeo
import BRStreetCore
import Foundation

/// A scratch directory removed when the value is no longer needed.
final class ScratchDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("brstations-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A synthetic street network written as OPL and compiled by the real streets builder, so
/// snapping, segment geometry and edge flags are exactly what the city build produces.
enum SyntheticCity {
    /// Lattice point (x, y): 40.70 + 0.0009·y, −74.0 + 0.0012·x (about 100 m apart).
    static func coordinate(_ x: Double, _ y: Double) -> Coordinate {
        Coordinate(lat: 40.70 + 0.0009 * y, lon: -74.0 + 0.0012 * x)
    }

    struct Way {
        var tags: [(String, String)]
        var points: [(Double, Double)]
    }

    static func nodeID(_ x: Double, _ y: Double) -> Int { 1_000_000 + Int((y * 10).rounded()) * 1000 + Int((x * 10).rounded()) }

    static func opl(_ ways: [Way]) -> String {
        ways.enumerated().map { index, way in
            let tags = way.tags.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
            let nodes = way.points.map { point in
                let c = coordinate(point.0, point.1)
                return "n\(nodeID(point.0, point.1))x\(String(format: "%.7f", c.lon))y\(String(format: "%.7f", c.lat))"
            }.joined(separator: ",")
            return "w\(index + 1) T\(tags) N\(nodes)"
        }.joined(separator: "\n") + "\n"
    }

    /// Two-way residential streets on a `columns` × `rows` lattice.
    static func grid(columns: Int, rows: Int, highway: String = "residential") -> [Way] {
        var ways: [Way] = []
        for y in 0..<rows {
            ways.append(Way(tags: [("highway", highway), ("name", "Street\(y)")], points: (0..<columns).map { (Double($0), Double(y)) }))
        }
        for x in 0..<columns {
            ways.append(Way(tags: [("highway", highway), ("name", "Avenue\(x)")], points: (0..<rows).map { (Double(x), Double($0)) }))
        }
        return ways
    }

    /// The region every test city lies in.
    static func region(columns: Double, rows: Double) -> StreetRegion {
        let a = coordinate(-2, -2), b = coordinate(columns + 2, rows + 2)
        let ring = [Coordinate(lat: a.lat, lon: a.lon), Coordinate(lat: a.lat, lon: b.lon), Coordinate(lat: b.lat, lon: b.lon),
                    Coordinate(lat: b.lat, lon: a.lon), Coordinate(lat: a.lat, lon: a.lon)]
        return StreetRegion(code: 1, name: "Manhattan", area: MultiPolygon([Polygon(exterior: ring)]))
    }

    struct Built {
        let graph: MappedStreetGraph
        let bytes: Data
        let url: URL
        let scratch: ScratchDirectory
    }

    /// Compiles `ways` into a streets artifact in a fresh scratch directory and maps it.
    static func build(_ ways: [Way], columns: Double = 10, rows: Double = 10, keepLargestComponents: Bool = false) throws -> Built {
        var options = StreetBuildOptions()
        options.keepLargestComponents = keepLargestComponents
        options.snapCellMeters = 50
        var builder = StreetNetworkBuilder(options: options)
        var reader = OPLReader(DataChunkSource(Data(opl(ways).utf8), chunkSize: 257))
        try reader.forEachWay { builder.add($0) }
        let compiled = builder.finish(regions: [region(columns: columns, rows: rows)])
        let bytes = StreetsArtifactWriter.artifact(compiled, dataVersion: "synthetic", snapCellMeters: 50)
        let scratch = try ScratchDirectory()
        let url = scratch.file(MappedStreetGraph.fileName)
        try bytes.write(to: url)
        return Built(graph: try MappedStreetGraph(contentsOf: url), bytes: bytes, url: url, scratch: scratch)
    }
}

/// A hand-built stations set: three synthetic stations with hand-set snaps and a hand-set matrix,
/// so the bytes change only when the writer or the format does (no snapping or routing runs, and
/// every stored float is exact). The payload golden and the committed v1 file are made from it.
/// The snap segment ids (0, 3, 6) are in range for the hand-built streets network in
/// BRStreetsTests (`HandBuiltStreets`), but the fractions and distances are arbitrary: nothing
/// here reads that network.
enum HandBuiltStations {
    /// The matrix profile, spelled out rather than `BikeProfile.eBike`, so tuning the routing
    /// defaults (speed, dismount pace, class multipliers) can't reach the golden. It equals
    /// `.eBike` as of the freeze.
    static let profile = BikeProfile(
        speedMetersPerSecond: 10 * 0.44704,
        multipliers: BikeClassMultipliers(protected: 0.8, painted: 0.9, shared: 1.0, arterial: 1.3),
        dismountSpeedMetersPerSecond: 3 * 0.44704
    )
    /// Stands in for the streets artifact's rawSha256.
    static let builtAgainst = ["streets": String(repeating: "0", count: 64)]

    static let stations: [CompiledStation] = [
        CompiledStation(
            id: "fixture-1", name: "Alpha & Beta", shortName: "1.01", regionID: "1", latE6: -850, lonE6: -600, capacity: 19,
            flags: [.charging, .bikeSnapped, .walkSnapped],
            bikeSnap: StoredSnap(segment: 0, fraction: 0.5, distanceDecimeters: 56),
            walkSnap: StoredSnap(segment: 0, fraction: 0.5, distanceDecimeters: 56)
        ),
        CompiledStation(
            id: "fixture-2", name: "Café Corner", shortName: "2.01", regionID: nil, latE6: 880, lonE6: -300, capacity: 31,
            flags: [.acceptedByArea, .bikeSnapped, .walkSnapped],
            bikeSnap: StoredSnap(segment: 3, fraction: 0.75, distanceDecimeters: 30),
            walkSnap: StoredSnap(segment: 3, fraction: 0.75, distanceDecimeters: 30)
        ),
        // Walk-snapped only: its matrix row and column are unreachable.
        CompiledStation(
            id: "fixture-0", name: "Gamma Plaza Dock", shortName: "3.01", regionID: "1", latE6: 450, lonE6: 1500, capacity: 12,
            flags: [.walkSnapped],
            walkSnap: StoredSnap(segment: 6, fraction: 0.25, distanceDecimeters: 334)
        ),
    ]

    /// Decameters, row-major in station order.
    static let matrix: [UInt16] = [
        0, 27, .max,
        31, 0, .max,
        .max, .max, 0,
    ]

    static func artifact(dataVersion: String = V1Fixtures.dataVersion) -> Data {
        StationsArtifactWriter.artifact(stations: stations, matrix: matrix, profile: profile, dataVersion: dataVersion, builtAgainst: builtAgainst)
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

/// GBFS documents shaped like Citi Bike's.
enum GBFSFixture {
    static func discovery(stationInformationURL: String = "https://example.test/gbfs/en/station_information.json") -> String {
        """
        {"last_updated":1790309897,"ttl":60,"version":"2.3","data":{
          "en":{"feeds":[{"name":"system_information","url":"https://example.test/gbfs/en/system_information.json"},
                         {"name":"station_information","url":"\(stationInformationURL)"}]},
          "fr":{"feeds":[{"name":"station_information","url":"https://example.test/gbfs/fr/station_information.json"}]}}}
        """
    }

    /// One station entry. `extra` is spliced in raw (e.g. `"region_id":"71",`).
    static func station(_ id: String, lat: Double, lon: Double, name: String? = nil, capacity: Int? = 20, extra: String = "") -> String {
        var fields = ["\"station_id\":\"\(id)\"", "\"name\":\"\(name ?? "Station \(id)")\"", "\"short_name\":\"\(id).01\"",
                      "\"lat\":\(lat)", "\"lon\":\(lon)"]
        if let capacity { fields.append("\"capacity\":\(capacity)") }
        return "{" + extra + fields.joined(separator: ",") + "}"
    }

    static func stationInformation(_ stations: [String], lastUpdated: Int = 1_790_309_897) -> String {
        "{\"last_updated\":\(lastUpdated),\"ttl\":60,\"version\":\"2.3\",\"data\":{\"stations\":[\(stations.joined(separator: ","))]}}"
    }
}

extension StoredSnap {
    /// The stored snap as the reference `SnappedPoint`, for comparisons with BRStreetCore searches.
    func point(in graph: MappedStreetGraph, query: Coordinate) -> SnappedPoint {
        graph.snappedPoint(self, query: query)!
    }
}

/// Byte offsets of the fields the corruption tests change in a `stations` payload, found by
/// reading each array's `u64` count at the next 8-aligned offset.
struct StationsPayloadLayout {
    var stringOffsets = 0
    var stringCount = 0
    var stringBytes = 0
    var stationCapacities = 0
    var stationFlags = 0
    /// Where the extension tail starts: the payload's fixed part is everything before it.
    var tail = 0

    init(_ payload: Data) {
        let bytes = Data(payload)
        var offset = 16 // magic, revision, u64 count
        // matrixProfile, stringOffsets, stringBytes, stationIDs … walkSnapDecimeters, matrixHigh, matrixLow
        let sizes = [8, 4, 1, 4, 4, 4, 4, 4, 4, 4, 2, 1, 4, 4, 2, 4, 4, 2, 1, 1]
        for (index, size) in sizes.enumerated() {
            offset = (offset + 7) / 8 * 8
            let count = Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) })
            switch index {
            case 1: (stringOffsets, stringCount) = (offset + 8, count - 1)
            case 2: stringBytes = offset + 8
            case 10: stationCapacities = offset + 8
            case 11: stationFlags = offset + 8
            default: break
            }
            offset += 8 + count * size
        }
        tail = offset
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
