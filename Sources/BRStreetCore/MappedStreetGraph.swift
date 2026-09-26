import BRData
import BRGeo
import Foundation

/// The `streets` artifact, memory-mapped and read in place: the walk and bike graph (forward and
/// reverse CSR), per-segment names, bearings and shape points, the snap grid, and the borough
/// polygons. Layout: `docs/formats.md`.
///
/// Arrays are never copied: every access reads the mapped bytes. A value is cheap to copy and
/// `Sendable`; it keeps the mapping alive through the `Data` it holds.
///
/// Terms: a **segment** is one undirected piece of street between two graph nodes, with its
/// geometry and name, oriented from its start node A to its end node B. It yields up to two
/// directed **edges**, A→B and B→A; a direction nobody may use is not stored.
public struct MappedStreetGraph: StreetNetwork {
    /// The raw artifact's file name inside a data directory such as `build/data`.
    public static let fileName = "streets.bin"

    public let header: ArtifactHeader
    public let nodeCount: Int
    public let edgeCount: Int
    public let segmentCount: Int
    public let shapePointCount: Int
    public let nameCount: Int
    public let grid: SnapGridGeometry
    /// Each borough, in code order.
    public let regions: [StreetRegion]

    private let payload: Data
    private let layout: Layout

    /// Byte offsets (from the payload start) of each array's first element.
    struct Layout: Sendable {
        var nodeCoordinates = 0
        var forwardOffsets = 0
        var edgeTargets = 0
        var edgeLengths = 0
        var edgeFlags = 0
        var edgeClasses = 0
        var edgeSegments = 0
        var reverseOffsets = 0
        var reverseSources = 0
        var reverseEdges = 0
        var segmentNodes = 0
        var segmentNameIDs = 0
        var segmentBearings = 0
        var segmentShapeOffsets = 0
        var shapePoints = 0
        var nameOffsets = 0
        var nameBytes = 0
        var nameByteCount = 0
        var nameKinds = 0
        var cellOffsets = 0
        var cellSegments = 0
        var cellSegmentCount = 0
    }

    /// Maps `streets.bin` from a data directory, e.g. `build/data`.
    public static func load(fromDataDirectory directory: URL, validate: Bool = true) throws -> MappedStreetGraph {
        try MappedStreetGraph(contentsOf: directory.appendingPathComponent(fileName), validate: validate)
    }

    /// Maps an artifact file. With `validate`, every index is range-checked once (a few ms for
    /// the city graph), so later reads can never go out of bounds.
    public init(contentsOf url: URL, validate: Bool = true) throws {
        try self.init(artifact: MappedArtifact(contentsOf: url, expecting: .streets), validate: validate)
    }

    public init(artifact: MappedArtifact, validate: Bool = true) throws {
        guard artifact.kind == .streets else {
            throw DataFormatError.kindMismatch(expected: .streets, found: artifact.kind)
        }
        guard artifact.header.formatVersion == ArtifactKind.streets.currentFormatVersion else {
            throw StreetsFormatError.unsupportedFormatVersion(artifact.header.formatVersion)
        }
        header = artifact.header
        // Arrays are viewed in place, which needs the payload 8-aligned in memory. Mapped files
        // always are; copy anything else (e.g. a slice of an in-memory buffer) into fresh storage.
        let aligned = artifact.payload.withUnsafeBytes { Int(bitPattern: $0.baseAddress) % 8 == 0 }
        payload = aligned ? artifact.payload : Data(artifact.payload)

        var reader = BinaryReader(payload)
        guard try reader.readBytes(count: 4).elementsEqual(StreetsFormat.payloadMagic) else {
            throw StreetsFormatError.badPayloadMagic
        }
        let revision = try reader.read(UInt32.self)
        guard revision == StreetsFormat.draftRevision else { throw StreetsFormatError.unsupportedDraftRevision(revision) }
        func count(_ section: String) throws -> Int {
            let value = try reader.read(UInt64.self)
            guard value < UInt64(UInt32.max) else { throw StreetsFormatError.valueOutOfRange(section: section, index: 0) }
            return Int(value)
        }
        nodeCount = try count("nodeCount")
        edgeCount = try count("edgeCount")
        segmentCount = try count("segmentCount")
        shapePointCount = try count("shapePointCount")
        nameCount = try count("nameCount")

        /// Reads an array header and returns the byte offset of its first element.
        func array<T: BinaryScalar>(_ type: T.Type, _ section: String, count expected: Int?) throws -> (offset: Int, count: Int) {
            let view = try reader.readArray(of: T.self)
            if let expected, view.count != expected {
                throw StreetsFormatError.countMismatch(section: section, expected: expected, actual: view.count)
            }
            return (reader.offset - view.count * MemoryLayout<T>.stride, view.count)
        }

        var layout = Layout()
        let (V, E, S) = (nodeCount, edgeCount, segmentCount)
        layout.nodeCoordinates = try array(Int32.self, "nodeCoordinates", count: 2 * V).offset
        layout.forwardOffsets = try array(UInt32.self, "forwardOffsets", count: V + 1).offset
        layout.edgeTargets = try array(UInt32.self, "edgeTargets", count: E).offset
        layout.edgeLengths = try array(UInt32.self, "edgeLengthDecimeters", count: E).offset
        layout.edgeFlags = try array(UInt16.self, "edgeFlags", count: E).offset
        layout.edgeClasses = try array(UInt8.self, "edgeBikeClasses", count: E).offset
        layout.edgeSegments = try array(UInt32.self, "edgeSegments", count: E).offset
        layout.reverseOffsets = try array(UInt32.self, "reverseOffsets", count: V + 1).offset
        layout.reverseSources = try array(UInt32.self, "reverseSources", count: E).offset
        layout.reverseEdges = try array(UInt32.self, "reverseEdges", count: E).offset
        layout.segmentNodes = try array(UInt32.self, "segmentNodes", count: 2 * S).offset
        layout.segmentNameIDs = try array(UInt32.self, "segmentNameIDs", count: S).offset
        layout.segmentBearings = try array(UInt8.self, "segmentBearings", count: 2 * S).offset
        layout.segmentShapeOffsets = try array(UInt32.self, "segmentShapeOffsets", count: S + 1).offset
        layout.shapePoints = try array(Int32.self, "shapePoints", count: 2 * shapePointCount).offset
        layout.nameOffsets = try array(UInt32.self, "nameOffsets", count: nameCount + 1).offset
        (layout.nameBytes, layout.nameByteCount) = try array(UInt8.self, "nameBytes", count: nil)
        layout.nameKinds = try array(UInt8.self, "nameKinds", count: nameCount).offset

        let originLat = try reader.read(Int32.self), originLon = try reader.read(Int32.self)
        let cellLat = try reader.read(Int32.self), cellLon = try reader.read(Int32.self)
        let columns = Int(try reader.read(UInt32.self)), rows = Int(try reader.read(UInt32.self))
        guard cellLat > 0, cellLon > 0, columns > 0, rows > 0, columns * rows < Int(UInt32.max) else {
            throw StreetsFormatError.invalidGrid
        }
        grid = SnapGridGeometry(
            originLatE6: originLat, originLonE6: originLon, cellLatE6: cellLat, cellLonE6: cellLon,
            columns: columns, rows: rows
        )
        layout.cellOffsets = try array(UInt32.self, "gridCellOffsets", count: columns * rows + 1).offset
        (layout.cellSegments, layout.cellSegmentCount) = try array(UInt32.self, "gridCellSegments", count: nil)

        regions = try Self.readRegions(&reader)
        guard reader.isAtEnd else { throw StreetsFormatError.trailingBytes(reader.remaining) }
        self.layout = layout

        // Cheap structural checks always; the full index scan on request.
        try withBuffers { b throws(StreetsFormatError) in
            guard b.forwardOffsets[0] == 0, Int(b.forwardOffsets[V]) == E,
                  b.reverseOffsets[0] == 0, Int(b.reverseOffsets[V]) == E,
                  b.shapeOffsets[0] == 0, Int(b.shapeOffsets[S]) == shapePointCount,
                  b.nameOffsets[0] == 0, Int(b.nameOffsets[nameCount]) == layout.nameByteCount,
                  b.cellOffsets[0] == 0, Int(b.cellOffsets[columns * rows]) == layout.cellSegmentCount
            else { throw StreetsFormatError.countMismatch(section: "offsets", expected: 0, actual: 1) }
        }
        if validate { try self.validate() }
    }

    // MARK: - Buffers

    /// Every array, bound in place. Valid only inside ``withBuffers(_:)``.
    struct Buffers {
        let nodeCoordinates: UnsafeBufferPointer<Int32>
        let forwardOffsets: UnsafeBufferPointer<UInt32>
        let edgeTargets: UnsafeBufferPointer<UInt32>
        let edgeLengths: UnsafeBufferPointer<UInt32>
        let edgeFlags: UnsafeBufferPointer<UInt16>
        let edgeClasses: UnsafeBufferPointer<UInt8>
        let edgeSegments: UnsafeBufferPointer<UInt32>
        let reverseOffsets: UnsafeBufferPointer<UInt32>
        let reverseSources: UnsafeBufferPointer<UInt32>
        let reverseEdges: UnsafeBufferPointer<UInt32>
        let segmentNodes: UnsafeBufferPointer<UInt32>
        let segmentNameIDs: UnsafeBufferPointer<UInt32>
        let segmentBearings: UnsafeBufferPointer<UInt8>
        let shapeOffsets: UnsafeBufferPointer<UInt32>
        let shapePoints: UnsafeBufferPointer<Int32>
        let nameOffsets: UnsafeBufferPointer<UInt32>
        let nameBytes: UnsafeBufferPointer<UInt8>
        let nameKinds: UnsafeBufferPointer<UInt8>
        let cellOffsets: UnsafeBufferPointer<UInt32>
        let cellSegments: UnsafeBufferPointer<UInt32>

        var view: StreetGraphView {
            StreetGraphView(
                nodeMicrodegrees: nodeCoordinates,
                forwardOffsets: forwardOffsets,
                edgeTargets: edgeTargets,
                edgeLengthDecimeters: edgeLengths,
                edgeFlagBits: edgeFlags,
                edgeBikeClassCodes: edgeClasses,
                reverseOffsets: reverseOffsets,
                reverseSources: reverseSources,
                reverseEdges: reverseEdges
            )
        }

        @inline(__always) func nodeCoordinate(_ node: Int) -> Coordinate {
            Coordinate(lat: StreetsFormat.degrees(nodeCoordinates[2 * node]), lon: StreetsFormat.degrees(nodeCoordinates[2 * node + 1]))
        }

        @inline(__always) func shapePoint(_ index: Int) -> Coordinate {
            Coordinate(lat: StreetsFormat.degrees(shapePoints[2 * index]), lon: StreetsFormat.degrees(shapePoints[2 * index + 1]))
        }

        /// Segment `s`'s geometry from A to B, including both end nodes.
        func segmentShape(_ s: Int) -> [Coordinate] {
            let a = Int(segmentNodes[2 * s]), b = Int(segmentNodes[2 * s + 1])
            let first = Int(shapeOffsets[s]), last = Int(shapeOffsets[s + 1])
            var points = [nodeCoordinate(a)]
            points.reserveCapacity(last - first + 2)
            for index in first..<last { points.append(shapePoint(index)) }
            points.append(nodeCoordinate(b))
            return points
        }

        /// The directed edges of segment `s`: A→B and B→A, if stored.
        func edges(ofSegment s: Int) -> (forward: UInt32?, backward: UInt32?) {
            let a = Int(segmentNodes[2 * s]), b = Int(segmentNodes[2 * s + 1])
            let code = UInt32(s), reversedCode = UInt32(s) | StreetsFormat.reversedSegmentBit
            var forward: UInt32?, backward: UInt32?
            for edge in Int(forwardOffsets[a])..<Int(forwardOffsets[a + 1]) where edgeSegments[edge] == code {
                forward = UInt32(edge)
                break
            }
            for edge in Int(forwardOffsets[b])..<Int(forwardOffsets[b + 1]) where edgeSegments[edge] == reversedCode {
                backward = UInt32(edge)
                break
            }
            return (forward, backward)
        }

        func name(_ id: Int) -> String {
            let start = Int(nameOffsets[id]), end = Int(nameOffsets[id + 1])
            return String(decoding: UnsafeBufferPointer(rebasing: nameBytes[start..<end]), as: UTF8.self)
        }
    }

    func withBuffers<R, E: Error>(_ body: (Buffers) throws(E) -> R) throws(E) -> R {
        let layout = self.layout
        let (V, E, S) = (nodeCount, edgeCount, segmentCount)
        let cells = grid.cellCount
        let result = payload.withUnsafeBytes { raw -> Result<R, E> in
            func bind<T>(_ offset: Int, _ count: Int, _: T.Type) -> UnsafeBufferPointer<T> {
                UnsafeRawBufferPointer(rebasing: raw[offset..<offset + count * MemoryLayout<T>.stride]).bindMemory(to: T.self)
            }
            let buffers = Buffers(
                nodeCoordinates: bind(layout.nodeCoordinates, 2 * V, Int32.self),
                forwardOffsets: bind(layout.forwardOffsets, V + 1, UInt32.self),
                edgeTargets: bind(layout.edgeTargets, E, UInt32.self),
                edgeLengths: bind(layout.edgeLengths, E, UInt32.self),
                edgeFlags: bind(layout.edgeFlags, E, UInt16.self),
                edgeClasses: bind(layout.edgeClasses, E, UInt8.self),
                edgeSegments: bind(layout.edgeSegments, E, UInt32.self),
                reverseOffsets: bind(layout.reverseOffsets, V + 1, UInt32.self),
                reverseSources: bind(layout.reverseSources, E, UInt32.self),
                reverseEdges: bind(layout.reverseEdges, E, UInt32.self),
                segmentNodes: bind(layout.segmentNodes, 2 * S, UInt32.self),
                segmentNameIDs: bind(layout.segmentNameIDs, S, UInt32.self),
                segmentBearings: bind(layout.segmentBearings, 2 * S, UInt8.self),
                shapeOffsets: bind(layout.segmentShapeOffsets, S + 1, UInt32.self),
                shapePoints: bind(layout.shapePoints, 2 * shapePointCount, Int32.self),
                nameOffsets: bind(layout.nameOffsets, nameCount + 1, UInt32.self),
                nameBytes: bind(layout.nameBytes, layout.nameByteCount, UInt8.self),
                nameKinds: bind(layout.nameKinds, nameCount, UInt8.self),
                cellOffsets: bind(layout.cellOffsets, cells + 1, UInt32.self),
                cellSegments: bind(layout.cellSegments, layout.cellSegmentCount, UInt32.self)
            )
            do throws(E) {
                return .success(try body(buffers))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    public func withView<R>(_ body: (StreetGraphView) -> R) -> R {
        withBuffers { body($0.view) }
    }

    /// Segment references in the snap grid (a segment is listed once per cell it crosses).
    public var gridEntryCount: Int { layout.cellSegmentCount }

    // MARK: - Nodes and edges

    public func coordinate(ofNode node: UInt32) -> Coordinate {
        precondition(Int(node) < nodeCount, "node out of range")
        return withBuffers { $0.nodeCoordinate(Int(node)) }
    }

    /// Forward edge indices leaving `node`.
    public func outgoingEdges(of node: UInt32) -> Range<Int> {
        precondition(Int(node) < nodeCount, "node out of range")
        return withBuffers { Int($0.forwardOffsets[Int(node)])..<Int($0.forwardOffsets[Int(node) + 1]) }
    }

    public func target(ofEdge edge: Int) -> UInt32 {
        withBuffers { $0.edgeTargets[edge] }
    }

    public func lengthDecimeters(ofEdge edge: Int) -> UInt32 {
        withBuffers { $0.edgeLengths[edge] }
    }

    public func flags(ofEdge edge: Int) -> EdgeFlags {
        withBuffers { EdgeFlags(rawValue: $0.edgeFlags[edge]) }
    }

    public func bikeClass(ofEdge edge: Int) -> BikeClass {
        withBuffers { BikeClass(rawValue: $0.edgeClasses[edge]) ?? .shared }
    }

    /// The segment an edge traverses, and whether it runs from the segment's end back to its start.
    public func segment(ofEdge edge: Int) -> (segment: UInt32, reversed: Bool) {
        let code = withBuffers { $0.edgeSegments[edge] }
        return (code & ~StreetsFormat.reversedSegmentBit, code & StreetsFormat.reversedSegmentBit != 0)
    }

    // MARK: - Segments

    /// A segment's start (A) and end (B) nodes.
    public func endpoints(ofSegment segment: UInt32) -> (a: UInt32, b: UInt32) {
        precondition(Int(segment) < segmentCount, "segment out of range")
        return withBuffers { ($0.segmentNodes[2 * Int(segment)], $0.segmentNodes[2 * Int(segment) + 1]) }
    }

    /// A segment's directed edges, A→B and B→A, if stored.
    public func edges(ofSegment segment: UInt32) -> (forward: UInt32?, backward: UInt32?) {
        precondition(Int(segment) < segmentCount, "segment out of range")
        return withBuffers { $0.edges(ofSegment: Int(segment)) }
    }

    /// A segment's geometry from A to B, including both end nodes.
    public func shape(ofSegment segment: UInt32) -> [Coordinate] {
        precondition(Int(segment) < segmentCount, "segment out of range")
        return withBuffers { $0.segmentShape(Int(segment)) }
    }

    /// An edge's geometry in travel order, including both end nodes.
    public func shape(ofEdge edge: Int) -> [Coordinate] {
        let (segment, reversed) = segment(ofEdge: edge)
        let points = shape(ofSegment: segment)
        return reversed ? points.reversed() : points
    }

    public func nameID(ofSegment segment: UInt32) -> UInt32 {
        withBuffers { $0.segmentNameIDs[Int(segment)] }
    }

    public func nameID(ofEdge edge: Int) -> UInt32 {
        nameID(ofSegment: segment(ofEdge: edge).segment)
    }

    public func name(ofEdge edge: Int) -> String {
        name(id: nameID(ofEdge: edge))
    }

    public func name(id: UInt32) -> String {
        precondition(Int(id) < nameCount, "name out of range")
        return withBuffers { $0.name(Int(id)) }
    }

    public func nameKind(id: UInt32) -> StreetNameKind {
        precondition(Int(id) < nameCount, "name out of range")
        return withBuffers { StreetNameKind(rawValue: $0.nameKinds[Int(id)]) ?? .derived }
    }

    /// Travel direction, in degrees clockwise from north, as an edge starts (`entry`) and as it
    /// ends (`exit`). Measured over about the first and last 10 m, so a turn at a node is
    /// `entry(next) − exit(previous)`.
    public func bearings(ofEdge edge: Int) -> (entry: Double, exit: Double) {
        let (segment, reversed) = segment(ofEdge: edge)
        let (start, end) = withBuffers { ($0.segmentBearings[2 * Int(segment)], $0.segmentBearings[2 * Int(segment) + 1]) }
        if reversed {
            return (StreetsFormat.bearingDegrees(code: end &+ 128), StreetsFormat.bearingDegrees(code: start &+ 128))
        }
        return (StreetsFormat.bearingDegrees(code: start), StreetsFormat.bearingDegrees(code: end))
    }

    // MARK: - Regions

    /// Manhattan, as stored (water areas included).
    public var manhattan: MultiPolygon {
        regions.first { $0.code == StreetRegion.manhattanCode }?.area ?? MultiPolygon([])
    }

    /// The five boroughs as one area.
    public var fiveBoroughs: MultiPolygon {
        MultiPolygon(regions.filter(\.isNYCBorough).flatMap(\.area.polygons))
    }

    /// The whole service area: the five boroughs, Jersey City and Hoboken (the union of every
    /// stored region).
    public var serviceArea: MultiPolygon {
        MultiPolygon(regions.flatMap(\.area.polygons))
    }

    public func region(containing coordinate: Coordinate) -> StreetRegion? {
        regions.first { $0.area.contains(coordinate) }
    }

    // MARK: - Conversion and validation

    /// An in-memory copy with the same node and edge numbering, e.g. for comparisons in tests.
    public func makeStreetGraph() -> StreetGraph {
        withBuffers { b in
            let coordinates = (0..<nodeCount).map(b.nodeCoordinate)
            let nameIDs = (0..<edgeCount).map { edge in
                b.segmentNameIDs[Int(b.edgeSegments[edge] & ~StreetsFormat.reversedSegmentBit)]
            }
            do {
                return try StreetGraph(
                    nodeCoordinates: coordinates,
                    forwardOffsets: Array(b.forwardOffsets),
                    edgeTargets: Array(b.edgeTargets),
                    edgeLengthDecimeters: Array(b.edgeLengths),
                    edgeFlags: b.edgeFlags.map(EdgeFlags.init(rawValue:)),
                    edgeBikeClasses: b.edgeClasses.map { BikeClass(rawValue: $0) ?? .shared },
                    edgeNameIDs: nameIDs
                )
            } catch {
                preconditionFailure("a validated artifact holds a valid graph: \(error)")
            }
        }
    }

    /// Range-checks every index and offset array.
    public func validate() throws {
        let (V, E, S) = (nodeCount, edgeCount, segmentCount)
        let cells = grid.cellCount
        try withBuffers { b throws(StreetsFormatError) in
            func monotonic(_ values: UnsafeBufferPointer<UInt32>, _ section: String) throws(StreetsFormatError) {
                for i in 1..<values.count where values[i] < values[i - 1] {
                    throw .notMonotonic(section: section, index: i)
                }
            }
            func bounded(_ values: UnsafeBufferPointer<UInt32>, below limit: Int, mask: UInt32 = .max, _ section: String) throws(StreetsFormatError) {
                for i in values.indices where Int(values[i] & mask) >= limit {
                    throw .valueOutOfRange(section: section, index: i)
                }
            }
            try monotonic(b.forwardOffsets, "forwardOffsets")
            try monotonic(b.reverseOffsets, "reverseOffsets")
            try monotonic(b.shapeOffsets, "segmentShapeOffsets")
            try monotonic(b.nameOffsets, "nameOffsets")
            try monotonic(b.cellOffsets, "gridCellOffsets")
            try bounded(b.edgeTargets, below: V, "edgeTargets")
            try bounded(b.reverseSources, below: V, "reverseSources")
            try bounded(b.reverseEdges, below: E, "reverseEdges")
            try bounded(b.edgeSegments, below: S, mask: ~StreetsFormat.reversedSegmentBit, "edgeSegments")
            try bounded(b.segmentNodes, below: V, "segmentNodes")
            try bounded(b.segmentNameIDs, below: nameCount, "segmentNameIDs")
            try bounded(b.cellSegments, below: S, "gridCellSegments")
            for i in b.edgeClasses.indices where Int(b.edgeClasses[i]) >= BikeClass.allCases.count {
                throw .valueOutOfRange(section: "edgeBikeClasses", index: i)
            }
            for i in b.nameKinds.indices where Int(b.nameKinds[i]) >= StreetNameKind.allCases.count {
                throw .valueOutOfRange(section: "nameKinds", index: i)
            }
            // Each edge's segment must join the edge's own ends, in the stated direction.
            for node in 0..<V {
                for edge in Int(b.forwardOffsets[node])..<Int(b.forwardOffsets[node + 1]) {
                    let code = b.edgeSegments[edge]
                    let s = Int(code & ~StreetsFormat.reversedSegmentBit)
                    let reversed = code & StreetsFormat.reversedSegmentBit != 0
                    let a = Int(b.segmentNodes[2 * s]), z = Int(b.segmentNodes[2 * s + 1])
                    let (from, to) = reversed ? (z, a) : (a, z)
                    guard from == node, to == Int(b.edgeTargets[edge]) else {
                        throw .valueOutOfRange(section: "edgeSegments", index: edge)
                    }
                }
            }
            // The reverse index lists each edge exactly once, at its target.
            for node in 0..<V {
                for slot in Int(b.reverseOffsets[node])..<Int(b.reverseOffsets[node + 1]) {
                    let edge = Int(b.reverseEdges[slot])
                    guard Int(b.edgeTargets[edge]) == node,
                          edge >= Int(b.forwardOffsets[Int(b.reverseSources[slot])]),
                          edge < Int(b.forwardOffsets[Int(b.reverseSources[slot]) + 1])
                    else { throw .valueOutOfRange(section: "reverseEdges", index: slot) }
                }
            }
            _ = cells
        }
    }

    private static func readRegions(_ reader: inout BinaryReader) throws -> [StreetRegion] {
        let count = Int(try reader.read(UInt32.self))
        guard count < 1024 else { throw StreetsFormatError.valueOutOfRange(section: "regionCount", index: 0) }
        var headers: [(code: UInt32, name: String)] = []
        for _ in 0..<count {
            let code = try reader.read(UInt32.self)
            headers.append((code, try reader.readString()))
        }
        let polygonOffsets = try reader.readArray(of: UInt32.self).toArray()
        let ringOffsets = try reader.readArray(of: UInt32.self).toArray()
        let pointOffsets = try reader.readArray(of: UInt32.self).toArray()
        let points = try reader.readArray(of: Int32.self).toArray()
        func check(_ offsets: [UInt32], count: Int, total: Int, _ section: String) throws {
            guard offsets.count == count + 1 else {
                throw StreetsFormatError.countMismatch(section: section, expected: count + 1, actual: offsets.count)
            }
            guard offsets.first == 0, Int(offsets.last ?? 0) == total else {
                throw StreetsFormatError.countMismatch(section: section, expected: total, actual: Int(offsets.last ?? 0))
            }
            for i in 1..<offsets.count where offsets[i] < offsets[i - 1] {
                throw StreetsFormatError.notMonotonic(section: section, index: i)
            }
        }
        try check(polygonOffsets, count: count, total: ringOffsets.count - 1, "regionPolygonOffsets")
        try check(ringOffsets, count: ringOffsets.count - 1, total: pointOffsets.count - 1, "polygonRingOffsets")
        try check(pointOffsets, count: pointOffsets.count - 1, total: points.count / 2, "ringPointOffsets")
        guard points.count % 2 == 0 else { throw StreetsFormatError.countMismatch(section: "ringPoints", expected: 0, actual: 1) }

        func ring(_ r: Int) -> [Coordinate] {
            (Int(pointOffsets[r])..<Int(pointOffsets[r + 1])).map {
                Coordinate(lat: StreetsFormat.degrees(points[2 * $0]), lon: StreetsFormat.degrees(points[2 * $0 + 1]))
            }
        }
        return headers.enumerated().map { index, header in
            let polygons = (Int(polygonOffsets[index])..<Int(polygonOffsets[index + 1])).compactMap { p -> Polygon? in
                let rings = Int(ringOffsets[p])..<Int(ringOffsets[p + 1])
                guard let first = rings.first else { return nil }
                return Polygon(exterior: ring(first), holes: rings.dropFirst().map(ring))
            }
            return StreetRegion(code: header.code, name: header.name, area: MultiPolygon(polygons))
        }
    }
}
