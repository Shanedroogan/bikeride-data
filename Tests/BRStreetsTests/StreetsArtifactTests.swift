@testable import BRBuild
import BRData
import BRGeo
import BRStreetCore
import Foundation
import Testing

@Suite struct StreetsArtifactTests {
    @Test func roundTripsThroughTheMappedReader() throws {
        let f = try FixtureStreets.build()
        #expect(f.graph.header.kind == .streets)
        #expect(f.graph.header.formatVersion == ArtifactKind.streets.currentFormatVersion)
        #expect(f.graph.header.dataVersion == "fixture")
        #expect(f.graph.nodeCount == f.compiled.nodeCount)
        #expect(f.graph.segmentCount == f.compiled.segmentCount)
        #expect(f.graph.nameCount == f.compiled.names.count)
        #expect(f.graph.shapePointCount == f.compiled.shapePoints.count / 2)

        // The mapped graph is the graph the compiler described, built independently in memory.
        let expected = StreetsArtifactWriter.makeStreetGraph(f.compiled)
        let mapped = f.graph.makeStreetGraph()
        #expect(mapped.nodeCoordinates == expected.nodeCoordinates)
        #expect(mapped.forwardOffsets == expected.forwardOffsets)
        #expect(mapped.edgeTargets == expected.edgeTargets)
        #expect(mapped.edgeLengthDecimeters == expected.edgeLengthDecimeters)
        #expect(mapped.edgeFlags == expected.edgeFlags)
        #expect(mapped.edgeBikeClasses == expected.edgeBikeClasses)
        #expect(mapped.edgeNameIDs == expected.edgeNameIDs)
        #expect(mapped.reverseOffsets == expected.reverseOffsets)
        #expect(mapped.reverseSources == expected.reverseSources)
        #expect(mapped.reverseEdges == expected.reverseEdges)
        #expect(f.graph.edgeCount == expected.edgeCount)
        for node in 0..<UInt32(f.graph.nodeCount) {
            #expect(f.graph.coordinate(ofNode: node) == expected.nodeCoordinates[Int(node)])
            #expect(f.graph.outgoingEdges(of: node) == expected.outgoingEdges(of: node))
        }

        // Per segment: ends, geometry, name and bearings.
        let c = f.compiled
        func point(_ values: [Int32], _ i: Int) -> Coordinate {
            Coordinate(lat: StreetsFormat.degrees(values[2 * i]), lon: StreetsFormat.degrees(values[2 * i + 1]))
        }
        for s in 0..<f.graph.segmentCount {
            let (a, b) = f.graph.endpoints(ofSegment: UInt32(s))
            #expect(a == c.segmentNodes[2 * s] && b == c.segmentNodes[2 * s + 1])
            let interior = (Int(c.segmentShapeOffsets[s])..<Int(c.segmentShapeOffsets[s + 1])).map { point(c.shapePoints, $0) }
            #expect(f.graph.shape(ofSegment: UInt32(s)) == [point(c.nodeCoordinates, Int(a))] + interior + [point(c.nodeCoordinates, Int(b))])
            let nameID = f.graph.nameID(ofSegment: UInt32(s))
            #expect(nameID == c.segmentNameIDs[s])
            #expect(f.graph.name(id: nameID) == c.names[Int(nameID)])
            #expect(f.graph.nameKind(id: nameID) == c.nameKinds[Int(nameID)])

            let (forward, backward) = f.graph.edges(ofSegment: UInt32(s))
            #expect((forward != nil) == (c.forwardFlags[s] != 0))
            #expect((backward != nil) == (c.backwardFlags[s] != 0))
            if let forward {
                #expect(f.graph.flags(ofEdge: Int(forward)).rawValue == c.forwardFlags[s])
                #expect(f.graph.bikeClass(ofEdge: Int(forward)).rawValue == c.forwardClasses[s])
                #expect(f.graph.segment(ofEdge: Int(forward)).segment == UInt32(s) && !f.graph.segment(ofEdge: Int(forward)).reversed)
                let bearings = f.graph.bearings(ofEdge: Int(forward))
                #expect(bearings.entry == StreetsFormat.bearingDegrees(code: c.segmentBearings[2 * s]))
                #expect(bearings.exit == StreetsFormat.bearingDegrees(code: c.segmentBearings[2 * s + 1]))
                #expect(f.graph.shape(ofEdge: Int(forward)) == f.graph.shape(ofSegment: UInt32(s)))
            }
            if let backward {
                #expect(f.graph.flags(ofEdge: Int(backward)).rawValue == c.backwardFlags[s])
                #expect(f.graph.bikeClass(ofEdge: Int(backward)).rawValue == c.backwardClasses[s])
                #expect(f.graph.segment(ofEdge: Int(backward)).segment == UInt32(s) && f.graph.segment(ofEdge: Int(backward)).reversed)
                #expect(f.graph.shape(ofEdge: Int(backward)) == f.graph.shape(ofSegment: UInt32(s)).reversed())
                #expect(f.graph.lengthDecimeters(ofEdge: Int(backward)) == c.segmentLengthDecimeters[s])
            }
        }

        // Regions survive at microdegree precision.
        #expect(f.graph.regions.count == c.regions.count)
        for (read, written) in zip(f.graph.regions, c.regions) {
            #expect(read.code == written.code && read.name == written.name)
            #expect(read.area.polygons.count == written.area.polygons.count)
            for (p, q) in zip(read.area.polygons, written.area.polygons) {
                #expect(p.holes.count == q.holes.count)
                #expect(p.exterior.count == q.exterior.count)
                for (u, v) in zip(p.exterior, q.exterior) {
                    #expect(abs(u.lat - v.lat) <= 5e-7 && abs(u.lon - v.lon) <= 5e-7)
                }
            }
        }
    }

    @Test func buildsAreDeterministic() throws {
        let reference = try FixtureStreets.build(chunkSize: 1 << 20).bytes
        for chunkSize in [1, 13, 4096] {
            #expect(try FixtureStreets.build(chunkSize: chunkSize).bytes == reference)
        }
    }

    @Test func snapGridListsEverySegmentWhereItsGeometryRuns() throws {
        let f = try FixtureStreets.build()
        #expect(f.graph.gridEntryCount >= f.graph.segmentCount)
        // Every stored shape point and node of a segment lies in a cell that lists the segment.
        let (_, offsets, segments) = StreetsArtifactWriter.snapGrid(f.compiled, cellMeters: 50)
        let grid = f.graph.grid
        for s in 0..<UInt32(f.graph.segmentCount) {
            for p in f.graph.shape(ofSegment: s) {
                let (x, y) = grid.cell(latE6: Int64(StreetsFormat.microdegrees(p.lat)), lonE6: Int64(StreetsFormat.microdegrees(p.lon)))
                let cell = y * grid.columns + x
                #expect(segments[Int(offsets[cell])..<Int(offsets[cell + 1])].contains(s))
            }
        }
    }

    @Test func rejectsCorruptArtifacts() throws {
        let f = try FixtureStreets.build()
        let header = try ArtifactHeader.decode(from: f.bytes).header
        let payloadStart = f.bytes.count - Int(try ArtifactHeader.decode(from: f.bytes).payload.count)
        let (V, E) = (f.graph.nodeCount, f.graph.edgeCount)

        func mapped(_ bytes: Data, validate: Bool = true) throws -> MappedStreetGraph {
            try MappedStreetGraph(artifact: MappedArtifact(fileBytes: bytes, expecting: .streets), validate: validate)
        }
        func align8(_ n: Int) -> Int { (n + 7) / 8 * 8 }

        // A bad payload magic.
        var badMagic = f.bytes
        badMagic[payloadStart] = UInt8(ascii: "X")
        #expect(throws: StreetsFormatError.badPayloadMagic) { try mapped(badMagic) }

        // Another payload revision.
        var badRevision = f.bytes
        badRevision[payloadStart + 4] &+= 1
        #expect(throws: StreetsFormatError.unsupportedPayloadRevision(StreetsFormat.payloadRevision + 1)) { try mapped(badRevision) }

        // An edge target past the last node: caught by validation, which is on by default.
        // Layout: magic, revision, five u64 counts, then nodeCoordinates, forwardOffsets, edgeTargets.
        var offset = 48
        offset = align8(offset) + 8 + 2 * V * 4
        offset = align8(offset) + 8 + (V + 1) * 4
        let firstTarget = payloadStart + align8(offset) + 8
        var badTarget = f.bytes
        withUnsafeBytes(of: UInt32(V + 7).littleEndian) { badTarget.replaceSubrange(firstTarget..<firstTarget + 4, with: $0) }
        #expect(throws: StreetsFormatError.valueOutOfRange(section: "edgeTargets", index: 0)) { try mapped(badTarget) }
        #expect(throws: Never.self) { try mapped(badTarget, validate: false) }
        #expect(E > 0)

        // Truncation, and a header of another kind.
        #expect(throws: (any Error).self) { try mapped(f.bytes.prefix(f.bytes.count - 8)) }
        var other = header
        other.kind = .stations
        let payload = try ArtifactHeader.decode(from: f.bytes).payload
        #expect(throws: DataFormatError.kindMismatch(expected: .streets, found: .stations)) {
            try mapped(other.assemble(payload: payload))
        }
    }
}

/// The compatibility rules of `docs/formats.md`: the extension tail, the flag and enum policies,
/// the payload revision, and the region and content checks.
@Suite struct StreetsCompatibilityTests {
    let f: FixtureStreets
    let header: ArtifactHeader
    let payload: Data
    let layout: StreetsPayloadLayout

    init() throws {
        f = try FixtureStreets.build()
        let decoded = try ArtifactHeader.decode(from: f.bytes)
        header = decoded.header
        payload = Data(decoded.payload)
        layout = StreetsPayloadLayout(payload)
    }

    func mapped(_ payload: Data, validate: Bool = true) throws -> MappedStreetGraph {
        try MappedStreetGraph(artifact: MappedArtifact(fileBytes: header.assemble(payload: payload), expecting: .streets), validate: validate)
    }

    /// The fixed part of the payload followed by a tail from ``BinaryWriter/appendExtensions(_:)``.
    func withExtensions(_ extensions: [(id: UInt32, bytes: [UInt8])]) -> Data {
        var writer = BinaryWriter()
        writer.append(bytes: payload.prefix(layout.tail))
        writer.appendExtensions(extensions)
        return writer.data
    }

    /// Everything a reader exposes, compared array by array.
    func expectSameContents(_ a: MappedStreetGraph, _ b: MappedStreetGraph) {
        #expect(a.nodeCount == b.nodeCount && a.edgeCount == b.edgeCount && a.segmentCount == b.segmentCount)
        #expect(a.shapePointCount == b.shapePointCount && a.nameCount == b.nameCount)
        #expect(a.grid == b.grid && a.gridEntryCount == b.gridEntryCount && a.regions == b.regions)
        let (x, y) = (a.makeStreetGraph(), b.makeStreetGraph())
        #expect(x.nodeCoordinates == y.nodeCoordinates && x.forwardOffsets == y.forwardOffsets && x.edgeTargets == y.edgeTargets)
        #expect(x.edgeLengthDecimeters == y.edgeLengthDecimeters && x.edgeFlags == y.edgeFlags && x.edgeBikeClasses == y.edgeBikeClasses)
        #expect(x.edgeNameIDs == y.edgeNameIDs && x.reverseSources == y.reverseSources && x.reverseEdges == y.reverseEdges)
        for s in 0..<UInt32(a.segmentCount) {
            #expect(a.shape(ofSegment: s) == b.shape(ofSegment: s) && a.endpoints(ofSegment: s) == b.endpoints(ofSegment: s))
        }
        for n in 0..<UInt32(a.nameCount) {
            #expect(a.name(id: n) == b.name(id: n) && a.nameKind(id: n) == b.nameKind(id: n))
        }
    }

    @Test func writesAnEmptyExtensionTail() throws {
        #expect(f.graph.extensions == .empty)
        #expect(layout.tail == payload.count - 4)
        #expect(payload.suffix(4).allSatisfy { $0 == 0 })
        // The writer's own tail and one written through the helper are the same bytes.
        #expect(withExtensions([]) == payload)
    }

    @Test func skipsUnknownExtensionsAndReadsTheRestUnchanged() throws {
        let graph = try mapped(withExtensions([(id: 7, bytes: [1, 2, 3]), (id: 40, bytes: Array(0..<20))]))
        #expect(graph.extensions.ids == [7, 40])
        #expect(graph.extensions[7].map(Array.init) == [1, 2, 3])
        #expect(graph.extensions[40].map(Array.init) == Array(0..<20))
        expectSameContents(graph, f.graph)
    }

    @Test func rejectsAMalformedExtensionTail() throws {
        let fixed = payload.prefix(layout.tail)
        for ids: [UInt32] in [[9, 7], [7, 7]] {
            let (bytes, offsets) = fixed.withRawExtensionTail(ids.map { (id: $0, bytes: [1]) })
            #expect(throws: DataFormatError.extensionIDsNotAscending(offset: offsets[1])) { try mapped(bytes) }
        }
        // Nothing may follow the tail, whether it is empty or not.
        #expect(throws: DataFormatError.trailingBytes(1)) { try mapped(payload + [0]) }
        #expect(throws: DataFormatError.trailingBytes(8)) { try mapped(withExtensions([(id: 3, bytes: [5])]) + Data(count: 8)) }
        // A file without a tail (as revision 3 wrote them) is truncated.
        #expect(throws: DataFormatError.self) { try mapped(fixed) }
    }

    @Test func rejectsEveryOtherPayloadRevision() {
        // Format 1 is revision 1 only; 4 was the last format-0 draft's.
        for revision: UInt32 in [0, 2, 4] {
            #expect(throws: StreetsFormatError.unsupportedPayloadRevision(revision)) { try mapped(payload.replacing(revision, at: 4)) }
        }
    }

    @Test func ignoresUndefinedEdgeFlagBits() throws {
        // Bit 9 set on every edge: the file opens, validated, and routes exactly as before.
        var flagged = payload
        flagged.withUnsafeMutableBytes { raw in
            for edge in 0..<f.graph.edgeCount {
                let offset = layout.edgeFlags + 2 * edge
                raw.storeBytes(of: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self) | 1 << 9, toByteOffset: offset, as: UInt16.self)
            }
        }
        #expect(flagged != payload)
        let graph = try mapped(flagged)
        // Every accessor returns only the defined bits: the edge, the search view, the copy.
        for edge in 0..<graph.edgeCount {
            #expect(graph.flags(ofEdge: edge) == f.graph.flags(ofEdge: edge))
            #expect(graph.withView { $0.flags(ofEdge: edge) } == f.graph.flags(ofEdge: edge))
        }
        #expect(graph.makeStreetGraph().edgeFlags == f.graph.makeStreetGraph().edgeFlags)
        for source in 0..<UInt32(graph.nodeCount) {
            let walk = try Dijkstra.oneToMany(in: graph, sources: [(source, 0)], profile: WalkProfile.standard)
            #expect(walk.costMs == (try Dijkstra.oneToMany(in: f.graph, sources: [(source, 0)], profile: WalkProfile.standard)).costMs)
            let bike = try Dijkstra.oneToMany(in: graph, sources: [(source, 0)], profile: BikeProfile.eBike)
            #expect(bike.costMs == (try Dijkstra.oneToMany(in: f.graph, sources: [(source, 0)], profile: BikeProfile.eBike)).costMs)
        }
        let query = StreetsFixtures.coordinate(2.15, 2.15)
        #expect(graph.snap(query, mode: .bike) == f.graph.snap(query, mode: .bike))
    }

    @Test func rejectsUnknownEnumValuesEvenWithoutValidation() {
        for validate in [false, true] {
            #expect(throws: StreetsFormatError.valueOutOfRange(section: "edgeBikeClasses", index: 0)) {
                try mapped(payload.replacing(UInt8(7), at: layout.edgeBikeClasses), validate: validate)
            }
            #expect(throws: StreetsFormatError.valueOutOfRange(section: "nameKinds", index: 0)) {
                try mapped(payload.replacing(UInt8(3), at: layout.nameKinds), validate: validate)
            }
        }
    }

    @Test func rejectsRegionsOutOfOrderAndUnclosedRings() {
        let codes = layout.regionCodes
        #expect(codes.count == f.graph.regions.count && codes.count >= 2)
        #expect(throws: StreetsFormatError.regionsNotSorted(index: 1)) { try mapped(payload.replacing(UInt32.max, at: codes[0])) }
        let first = f.graph.regions[0].code
        #expect(throws: StreetsFormatError.regionsNotSorted(index: 1)) { try mapped(payload.replacing(first, at: codes[1])) }
        // The last ring's last point is the last fixed value before the tail.
        let lastLon = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: layout.tail - 4, as: Int32.self) }
        #expect(throws: StreetsFormatError.ringNotClosed(ring: layout.ringCount - 1)) {
            try mapped(payload.replacing(lastLon &+ 1, at: layout.tail - 4), validate: false)
        }
    }

    /// The payload with its regions replaced by one region (code 1) of these raw arrays, which
    /// the writer would refuse to produce.
    func withRegion(polygonOffsets: [UInt32], ringOffsets: [UInt32], pointOffsets: [UInt32], points: [Int32]) -> Data {
        var writer = BinaryWriter()
        writer.append(bytes: payload.prefix(layout.regions))
        writer.append(UInt32(1))
        writer.append(UInt32(1))
        writer.append(string: "Manhattan")
        writer.append(array: polygonOffsets)
        writer.append(array: ringOffsets)
        writer.append(array: pointOffsets)
        writer.append(array: points)
        writer.appendExtensions([])
        return writer.data
    }

    @Test func rejectsEmptyPolygonsAndDegenerateRings() throws {
        let (a, b, c) = ([Int32(40_700_000), -74_000_000], [Int32(40_700_000), -73_990_000], [Int32(40_710_000), -73_990_000])
        // The helper's own bytes open: one polygon, one closed 4-point ring.
        let square = try mapped(withRegion(polygonOffsets: [0, 1], ringOffsets: [0, 1], pointOffsets: [0, 4], points: a + b + c + a))
        #expect(square.regions.map(\.code) == [1] && square.regions[0].area.polygons.map(\.exterior.count) == [4])
        // A polygon with no rings (its range in polygonRingOffsets is empty) isn't dropped silently.
        #expect(throws: StreetsFormatError.emptyPolygon(polygon: 0)) {
            try mapped(withRegion(polygonOffsets: [0, 2], ringOffsets: [0, 0, 1], pointOffsets: [0, 4], points: a + b + c + a), validate: false)
        }
        // A ring that is closed but has only 3 points, and a ring with no points.
        #expect(throws: StreetsFormatError.ringNotClosed(ring: 0)) {
            try mapped(withRegion(polygonOffsets: [0, 1], ringOffsets: [0, 1], pointOffsets: [0, 3], points: a + b + a), validate: false)
        }
        #expect(throws: StreetsFormatError.ringNotClosed(ring: 0)) {
            try mapped(withRegion(polygonOffsets: [0, 1], ringOffsets: [0, 2], pointOffsets: [0, 0, 4], points: a + b + c + a), validate: false)
        }
    }

    @Test func theWriterSortsRegionsAndClosesRings() throws {
        // Regions given out of order, one with an open ring: stored by code, the ring closed.
        var compiled = f.compiled
        let open = [Coordinate(lat: 40.70, lon: -74.10), Coordinate(lat: 40.70, lon: -74.09), Coordinate(lat: 40.71, lon: -74.09)]
        compiled.regions = [StreetRegion(code: 900, name: "Open", area: MultiPolygon([Polygon(exterior: open)]))] + compiled.regions.reversed()
        let graph = try MappedStreetGraph(artifact: MappedArtifact(fileBytes: StreetsArtifactWriter.artifact(compiled, dataVersion: "x")))
        #expect(graph.regions.map(\.code) == compiled.regions.map(\.code).sorted())
        let stored = try #require(graph.regions.first { $0.code == 900 }?.area.polygons.first?.exterior)
        #expect(stored.count == 4 && stored.first == stored.last)
    }

    @Test func validationChecksEdgeAccessGridOrderAndNames() throws {
        // An edge nobody may use (bridge bit only) is caught by validation.
        let unusable = payload.replacing(UInt16(1 << 3), at: layout.edgeFlags)
        #expect(throws: StreetsFormatError.valueOutOfRange(section: "edgeFlags", index: 0)) { try mapped(unusable) }
        #expect(throws: Never.self) { try mapped(unusable, validate: false) }

        // Two segments of one cell listed out of order.
        let offsets = (0...f.graph.grid.cellCount).map { cell in
            Int(payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: layout.gridCellOffsets + 4 * cell, as: UInt32.self) })
        }
        let cell = try #require((0..<f.graph.grid.cellCount).first { offsets[$0 + 1] - offsets[$0] >= 2 })
        let slot = offsets[cell]
        func segment(_ slot: Int) -> UInt32 {
            payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: layout.gridCellSegments + 4 * slot, as: UInt32.self) }
        }
        let swapped = payload.replacing(segment(slot + 1), at: layout.gridCellSegments + 4 * slot)
            .replacing(segment(slot), at: layout.gridCellSegments + 4 * (slot + 1))
        #expect(throws: StreetsFormatError.notMonotonic(section: "gridCellSegments", index: slot + 1)) { try mapped(swapped) }

        // A byte that is not UTF-8: the error names the name holding it (the first byte belongs to
        // the first non-empty name), wherever it is in the pool.
        func nameStart(_ n: Int) -> Int {
            Int(payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: layout.nameOffsets + 4 * n, as: UInt32.self) })
        }
        let firstNamed = try #require((0..<f.graph.nameCount).first { nameStart($0 + 1) > 0 })
        #expect(f.graph.name(id: 0).isEmpty == (firstNamed > 0))
        #expect(throws: StreetsFormatError.invalidName(index: firstNamed)) {
            try mapped(payload.replacing(UInt8(0xFF), at: layout.nameBytes))
        }
        let middle = try #require((f.graph.nameCount / 2..<f.graph.nameCount).first { nameStart($0 + 1) > nameStart($0) })
        #expect(middle > firstNamed)
        #expect(throws: StreetsFormatError.invalidName(index: middle)) {
            try mapped(payload.replacing(UInt8(0xFF), at: layout.nameBytes + nameStart(middle + 1) - 1))
        }
        // A name boundary inside "é" (C3 A9).
        let cafe = try #require((0..<UInt32(f.graph.nameCount)).first { f.graph.name(id: $0) == "Café Street" })
        #expect(Int(cafe) + 1 < f.graph.nameCount)
        let start = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: layout.nameOffsets + 4 * Int(cafe), as: UInt32.self) }
        let split = payload.replacing(start + 4, at: layout.nameOffsets + 4 * (Int(cafe) + 1))
        #expect(throws: StreetsFormatError.invalidName(index: Int(cafe) + 1)) { try mapped(split) }
        #expect(throws: Never.self) { try mapped(split, validate: false) }
    }
}

@Suite struct MappedSearchTests {
    /// Dijkstra over the mapped artifact gives exactly what it gives over the same graph in memory:
    /// costs, tree edges and distances, from every node, both directions, every profile.
    @Test(arguments: [SearchDirection.forward, .reverse])
    func dijkstraOnTheMappedGraphMatchesInMemory(direction: SearchDirection) throws {
        let f = try FixtureStreets.build()
        let memory = StreetsArtifactWriter.makeStreetGraph(f.compiled)
        func compare<P: CostProfile>(_ profile: P, from source: UInt32) throws {
            let options: SearchOptions = [.recordParents, .recordDistances]
            let a = try Dijkstra.oneToMany(in: f.graph, sources: [(source, 0)], profile: profile, direction: direction, options: options)
            let b = try Dijkstra.oneToMany(in: memory, sources: [(source, 0)], profile: profile, direction: direction, options: options)
            #expect(a.costMs == b.costMs, "source \(source)")
            #expect(a.parentEdges == b.parentEdges)
            #expect(a.distanceDecimeters == b.distanceDecimeters)
            for node in 0..<UInt32(f.graph.nodeCount) {
                #expect(a.path(for: node, in: f.graph) == b.path(for: node, in: memory))
            }
        }
        for source in 0..<UInt32(f.graph.nodeCount) {
            try compare(WalkProfile.standard, from: source)
            try compare(BikeProfile.eBike, from: source)
            try compare(BikeProfile(speedMetersPerSecond: 3), from: source)
        }
    }

    @Test func aStarOnTheMappedGraphMatchesDijkstra() throws {
        let f = try FixtureStreets.build()
        for source in 0..<UInt32(f.graph.nodeCount) {
            let walk = try Dijkstra.oneToMany(in: f.graph, sources: [(source, 0)], profile: WalkProfile.standard)
            let bike = try Dijkstra.oneToMany(in: f.graph, sources: [(source, 0)], profile: BikeProfile.classic)
            for target in 0..<UInt32(f.graph.nodeCount) {
                let w = try AStar.shortestPath(in: f.graph, from: source, to: target, profile: WalkProfile.standard)
                #expect(w?.costMs == walk.cost(of: target))
                let b = try AStar.shortestPath(in: f.graph, from: source, to: target, profile: BikeProfile.classic)
                #expect(b?.costMs == bike.cost(of: target))
            }
        }
    }
}
