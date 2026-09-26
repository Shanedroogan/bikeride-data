import BRBuild
import BRData
import BRGeo
import BRStreetCore
import Foundation
import Testing

/// Format 1 of `stations`, frozen 2026-09-26 (`docs/formats.md`, "Compatibility"): the payload
/// golden for the hand-built set, the committed v1 file, and the formatVersion and
/// payloadRevision gates.
@Suite struct StationsV1Tests {
    /// SHA-256 of the writer's payload for ``HandBuiltStations`` (the header is left out: it
    /// embeds builderSwiftVersion). What may change it:
    /// - a change to the payload layout. That is a new formatVersion, because a v1 reader would
    ///   misread the bytes; never re-pin this digest for one.
    /// - a deliberate change to the hand-built input, or to what the writer puts in a v1 payload
    ///   (such as a newly defined extension id). Review the new bytes, then pin the new digest.
    /// Selection, snapping, matrix-routing and routing-default changes don't reach it: every
    /// value, the profile included, is hand-set.
    static let payloadGolden = "f1429f38b1f088733014eb8c71309415203d46df3eebd43e5e5a6571afdc3136"

    static let fixtureName = "stations.bin"

    func reader(_ file: Data) throws -> MappedStations {
        try MappedStations(artifact: MappedArtifact(fileBytes: file, expecting: .stations))
    }

    @Test func payloadMatchesTheGolden() throws {
        let file = HandBuiltStations.artifact()
        let payload = StationsArtifactWriter.payload(stations: HandBuiltStations.stations, matrix: HandBuiltStations.matrix,
                                                     profile: HandBuiltStations.profile)
        #expect(Data(try ArtifactHeader.decode(from: file).payload) == payload)
        #expect(try V1Fixtures.payloadSHA256(file) == Self.payloadGolden)
        #expect(try V1Fixtures.payloadSHA256(HandBuiltStations.artifact(dataVersion: "other")) == Self.payloadGolden)
        // The hand-built set is a valid v1 file, and its profile is the literal one (not whatever
        // the routing defaults are now).
        let stations = try reader(file)
        #expect(stations.header.formatVersion == 1 && stations.extensions == .empty)
        #expect(stations.matrixProfile.speedMetersPerSecond == 10 * 0.44704)
        #expect(stations.matrixProfile.dismountSpeedMetersPerSecond == 3 * 0.44704)
        #expect(stations.matrixProfile.multipliers == BikeClassMultipliers(protected: 0.8, painted: 0.9, shared: 1.0, arterial: 1.3))
    }

    @Test func rejectsEveryOtherFormatVersionAndPayloadRevision() throws {
        let file = HandBuiltStations.artifact()
        _ = try reader(file)
        for version: UInt16 in [0, 2] {
            #expect(throws: StationsFormatError.unsupportedFormatVersion(version)) { try reader(V1Fixtures.withFormatVersion(version, file)) }
        }
        let (header, payload) = try ArtifactHeader.decode(from: file)
        for revision: UInt32 in [0, 2] {
            #expect(throws: StationsFormatError.unsupportedPayloadRevision(revision)) {
                try reader(header.assemble(payload: Data(payload).replacing(revision, at: 4)))
            }
        }
    }

    /// A reader of this build opens the committed v1 file (`MappedStations` always validates) and
    /// reads what was written on the day the format froze. Every value is a literal: the file is
    /// frozen, not rebuilt.
    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func opensTheCommittedV1File() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        let stations = try reader(file)
        #expect(stations.header.kind == .stations && stations.header.formatVersion == 1)
        #expect(stations.header.dataVersion == "v1-fixture")
        #expect(stations.header.builtAgainst == ["streets": String(repeating: "0", count: 64)])
        let payload = Data(try ArtifactHeader.decode(from: file).payload)
        #expect(payload.prefix(4) == Data("STNS".utf8))
        #expect(payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) } == 1)

        #expect(stations.count == 3)
        #expect(stations.matrixProfile.speedMetersPerSecond == 10 * 0.44704)
        #expect(stations.matrixProfile.dismountSpeedMetersPerSecond == 3 * 0.44704)
        #expect(stations.matrixProfile.multipliers == BikeClassMultipliers(protected: 0.8, painted: 0.9, shared: 1.0, arterial: 1.3))
        #expect((0..<3).map(stations.stationID) == ["fixture-1", "fixture-2", "fixture-0"])
        #expect((0..<3).map(stations.name) == ["Alpha & Beta", "Café Corner", "Gamma Plaza Dock"])
        #expect((0..<3).map(stations.shortName) == ["1.01", "2.01", "3.01"])
        #expect((0..<3).map(stations.regionID) == ["1", nil, "1"])
        #expect((0..<3).map(stations.capacity) == [19, 31, 12])
        #expect((0..<3).map(stations.flags) == [[.charging, .bikeSnapped, .walkSnapped], [.acceptedByArea, .bikeSnapped, .walkSnapped], [.walkSnapped]])
        #expect(stations.index(ofStationID: "fixture-0") == 2 && stations.index(ofStationID: "fixture-2") == 1)
        #expect(stations.index(ofStationID: "fixture-3") == nil)
        #expect(stations.coordinate(1) == Coordinate(lat: 0.00088, lon: -0.0003))
        #expect(stations.bikeSnap(1) == StoredSnap(segment: 3, fraction: 0.75, distanceDecimeters: 30))
        #expect(stations.bikeSnap(2) == nil && stations.walkSnap(2) == StoredSnap(segment: 6, fraction: 0.25, distanceDecimeters: 334))
        #expect(stations.distanceDecameters(from: 0, to: 1) == 27 && stations.distanceDecameters(from: 1, to: 0) == 31)
        #expect(stations.distanceMeters(from: 1, to: 0) == 310 && stations.distanceMeters(from: 0, to: 2) == nil)
        #expect(Array(stations.row(from: 2)) == [StationsFormat.unreachable, StationsFormat.unreachable, 0])
        #expect(stations.extensions == .empty)
    }

    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func rejectsTheCommittedFileUnderAnyOtherFormatVersion() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        for version: UInt16 in [0, 2] {
            #expect(throws: StationsFormatError.unsupportedFormatVersion(version)) { try reader(V1Fixtures.withFormatVersion(version, file)) }
        }
    }

    /// Rewrites `Tests/Fixtures/v1/stations.bin` from ``HandBuiltStations``. Only with
    /// `BR_WRITE_V1_FIXTURES=1`; see ``V1Fixtures`` for when that is right.
    @Test(.enabled(if: V1Fixtures.regenerating, "set BR_WRITE_V1_FIXTURES=1 to rewrite the v1 fixtures"))
    func writeV1Fixture() throws {
        let file = HandBuiltStations.artifact()
        _ = try reader(file)
        try V1Fixtures.write(file, to: Self.fixtureName)
    }
}
