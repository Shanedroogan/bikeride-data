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
        #expect(f.graph.header.formatVersion == 0)
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

        // Another draft revision.
        var badRevision = f.bytes
        badRevision[payloadStart + 4] &+= 1
        #expect(throws: StreetsFormatError.unsupportedDraftRevision(StreetsFormat.draftRevision + 1)) { try mapped(badRevision) }

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
