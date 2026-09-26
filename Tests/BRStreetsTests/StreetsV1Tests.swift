import BRBuild
import BRData
import BRGeo
import BRStreetCore
import Foundation
import Testing

/// Format 1 of `streets`, frozen 2026-09-26 (`docs/formats.md`, "Compatibility"): the payload
/// golden for the hand-built network, the committed v1 file, and the formatVersion and
/// payloadRevision gates.
@Suite struct StreetsV1Tests {
    /// SHA-256 of the writer's payload for ``HandBuiltStreets`` (the header is left out: it embeds
    /// builderSwiftVersion). What may change it:
    /// - a change to the payload layout. That is a new formatVersion, because a v1 reader would
    ///   misread the bytes; never re-pin this digest for one.
    /// - a deliberate change to the hand-built input, or to what the writer puts in a v1 payload
    ///   (such as a newly defined extension id). Review the new bytes, then pin the new digest.
    /// Builder, OSM-rule and snapping changes don't reach it: nothing here is compiled from OSM.
    static let payloadGolden = "54df49971bd10593d6a570f7917cdc5ac2293040254ba7c0225a5811b651e4ec"

    static let fixtureName = "streets.bin"

    func mapped(_ file: Data, validate: Bool = true) throws -> MappedStreetGraph {
        try MappedStreetGraph(artifact: MappedArtifact(fileBytes: file, expecting: .streets), validate: validate)
    }

    @Test func payloadMatchesTheGolden() throws {
        let file = HandBuiltStreets.artifact()
        let payload = StreetsArtifactWriter.payload(HandBuiltStreets.compiled(), snapCellMeters: HandBuiltStreets.snapCellMeters)
        #expect(Data(try ArtifactHeader.decode(from: file).payload) == payload)
        #expect(try V1Fixtures.payloadSHA256(file) == Self.payloadGolden)
        #expect(try V1Fixtures.payloadSHA256(HandBuiltStreets.artifact(dataVersion: "other")) == Self.payloadGolden)
        // The hand-built network is a valid v1 file.
        let graph = try mapped(file)
        #expect(graph.header.formatVersion == 1 && graph.extensions == .empty)
    }

    @Test func rejectsEveryOtherFormatVersionAndPayloadRevision() throws {
        let file = HandBuiltStreets.artifact()
        _ = try mapped(file)
        for version: UInt16 in [0, 2] {
            for validate in [false, true] {
                #expect(throws: StreetsFormatError.unsupportedFormatVersion(version)) {
                    try mapped(V1Fixtures.withFormatVersion(version, file), validate: validate)
                }
            }
        }
        let (header, payload) = try ArtifactHeader.decode(from: file)
        for revision: UInt32 in [0, 2] {
            #expect(throws: StreetsFormatError.unsupportedPayloadRevision(revision)) {
                try mapped(header.assemble(payload: Data(payload).replacing(revision, at: 4)))
            }
        }
    }

    /// A reader of this build opens the committed v1 file, validated, and reads what was written
    /// on the day the format froze. Every value is a literal: the file is frozen, not rebuilt.
    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func opensTheCommittedV1File() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        let graph = try mapped(file, validate: true)
        #expect(graph.header.kind == .streets && graph.header.formatVersion == 1)
        #expect(graph.header.dataVersion == "v1-fixture" && graph.header.builtAgainst.isEmpty)
        let payload = Data(try ArtifactHeader.decode(from: file).payload)
        #expect(payload.prefix(4) == Data("STRT".utf8))
        #expect(payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) } == 1)

        #expect(graph.nodeCount == 5 && graph.edgeCount == 13 && graph.segmentCount == 7)
        #expect(graph.shapePointCount == 7 && graph.nameCount == 7)
        #expect(graph.coordinate(ofNode: 0) == Coordinate(lat: -0.0009, lon: -0.0012))
        #expect(graph.coordinate(ofNode: 4) == Coordinate(lat: 0.0009, lon: 0.0012))
        #expect((0..<UInt32(7)).map(graph.name(id:)) == ["Alpha Street", "B1", "Beta Avenue", "Café Street", "Gamma Plaza", "bike path", "steps"])
        #expect((0..<UInt32(7)).map(graph.nameKind(id:)) == [.tagged, .ref, .tagged, .tagged, .tagged, .derived, .derived])

        // Beta Avenue (s1): a bike one-way, walkable both ways, bent through one shape point.
        #expect(graph.name(id: graph.nameID(ofSegment: 1)) == "Beta Avenue")
        let beta = graph.edges(ofSegment: 1)
        let betaForward = try #require(beta.forward), betaBackward = try #require(beta.backward)
        #expect(graph.flags(ofEdge: Int(betaForward)) == [.walk, .bikeForward] && graph.flags(ofEdge: Int(betaBackward)) == [.walk])
        #expect(graph.bikeClass(ofEdge: Int(betaForward)) == .shared && graph.lengthDecimeters(ofEdge: Int(betaForward)) == 2014)
        #expect(graph.shape(ofSegment: 1) == [Coordinate(lat: -0.0009, lon: -0.0012), Coordinate(lat: 0, lon: -0.0013), Coordinate(lat: 0.0009, lon: -0.0012)])
        #expect(graph.bearings(ofEdge: Int(betaForward)).entry == 354.375)
        // B1 (s2): the bridge, arterial; Café Street (s3) in the park, protected.
        let bridge = try #require(graph.edges(ofSegment: 2).forward)
        #expect(graph.flags(ofEdge: Int(bridge)) == [.walk, .bikeForward, .bridge] && graph.bikeClass(ofEdge: Int(bridge)) == .arterial)
        #expect(graph.segment(ofEdge: Int(bridge)) == (segment: 2, reversed: false))
        let cafe = try #require(graph.edges(ofSegment: 3).backward)
        #expect(graph.segment(ofEdge: Int(cafe)) == (segment: 3, reversed: true) && graph.target(ofEdge: Int(cafe)) == 2)
        #expect(graph.flags(ofEdge: Int(cafe)) == [.walk, .bikeForward, .park] && graph.bikeClass(ofEdge: Int(cafe)) == .protected)
        // The bike path (s4) rides one way only: its B→A direction is not stored. Beside it, the
        // steps (s5); at n4, the plaza loop (s6, A = B).
        let path = graph.edges(ofSegment: 4)
        let pathForward = try #require(path.forward)
        #expect(path.backward == nil && graph.flags(ofEdge: Int(pathForward)) == [.bikeForward])
        let steps = try #require(graph.edges(ofSegment: 5).forward)
        #expect(graph.flags(ofEdge: Int(steps)) == [.walk, .stairs])
        let loop = try #require(graph.edges(ofSegment: 6).forward)
        #expect(graph.endpoints(ofSegment: 6) == (a: 4, b: 4) && graph.shape(ofSegment: 6).count == 5)
        #expect(graph.flags(ofEdge: Int(loop)) == [.walk, .bikeForward, .connector, .dismount] && graph.target(ofEdge: Int(loop)) == 4)
        // Riding follows the one-way; walking does not.
        let ride = try Dijkstra.oneToMany(in: graph, sources: [(4, 0)], profile: BikeProfile.eBike)
        let walk = try Dijkstra.oneToMany(in: graph, sources: [(4, 0)], profile: WalkProfile.standard)
        #expect(ride.cost(of: 3) == nil && walk.cost(of: 3) != nil && walk.cost(of: 0) != nil)

        #expect(graph.grid == SnapGridGeometry(originLatE6: -900, originLonE6: -1300, cellLatE6: 899, cellLonE6: 899, columns: 4, rows: 3))
        #expect(graph.snap(Coordinate(lat: -0.00085, lon: -0.0006), mode: .bike)?.segment == 0)

        #expect(graph.regions.map(\.code) == [1, 2] && graph.regions.map(\.name) == ["Test West", "Test East"])
        #expect(graph.regions[0].area.polygons.map(\.holes.count) == [1] && graph.regions[0].area.polygons[0].exterior.count == 5)
        #expect(graph.region(containing: Coordinate(lat: 0, lon: 0.001))?.code == 2)
        #expect(graph.region(containing: Coordinate(lat: 0.001, lon: -0.001))?.code == 1)
        #expect(graph.region(containing: Coordinate(lat: -0.0003, lon: -0.0012)) == nil) // in region 1's hole
        #expect(graph.extensions == .empty)
    }

    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func rejectsTheCommittedFileUnderAnyOtherFormatVersion() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        for version: UInt16 in [0, 2] {
            #expect(throws: StreetsFormatError.unsupportedFormatVersion(version)) { try mapped(V1Fixtures.withFormatVersion(version, file)) }
        }
    }

    /// Rewrites `Tests/Fixtures/v1/streets.bin` from ``HandBuiltStreets``. Only with
    /// `BR_WRITE_V1_FIXTURES=1`; see ``V1Fixtures`` for when that is right.
    @Test(.enabled(if: V1Fixtures.regenerating, "set BR_WRITE_V1_FIXTURES=1 to rewrite the v1 fixtures"))
    func writeV1Fixture() throws {
        let file = HandBuiltStreets.artifact()
        _ = try mapped(file)
        try V1Fixtures.write(file, to: Self.fixtureName)
    }
}
