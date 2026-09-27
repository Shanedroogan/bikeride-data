import BRBuild
import BRCore
import BRData
import BRGeo
import BRStreetCore
import BRTimetable
import Foundation
import Testing

/// A `links` payload typed by hand: no OSM, GTFS or GBFS, no builder, every parameter spelled out
/// and every coordinate a whole number of microdegrees, so no platform-dependent floating point
/// reaches the bytes and the digest is the same on macOS and Linux. The stops, stations, snaps and
/// seconds are made up. The payload golden and the committed v1 file are made from it.
///
/// Global stops (T = 9): subway 0 (station A, not routable), 1 (A's platform), 2 (another
/// platform); bus 3 (routable), 4 (not); LIRR 5; ferry 6; PATH 7, 8. Stations 0–2.
enum HandBuiltLinks {
    static let options: LinksOptions = {
        var options = LinksOptions.standard
        options.walk = WalkProfile(speedMetersPerSecond: 1.5, stairsMultiplier: 2)
        options.maxFootpathWalkSeconds = 480
        options.minTransferSeconds = 30
        options.stationLinkMaxWalkMeters = 350
        options.accessSeconds = [.subway: 120, .bus: 30, .lirr: 240, .ferry: 120, .path: 90]
        options.streetAccessOnlyInsideServiceArea = []
        options.fixedTransfers = []
        options.threads = 1
        return options
    }()

    static let hopParameters = LinkHopParameters(minRideSeconds: 300, maxRideSeconds: 1500, minSpeedMmPerSecond: 3040, maxSpeedMmPerSecond: 5141,
                                                 rankSpeedMmPerSecond: 4470, unlockSeconds: 90, dockSeconds: 60, pickupsPerHop: 2, docksPerHop: 2)

    static let routable = [false, true, true, true, false, true, true, true, true]

    /// Microdegrees → degrees, exactly as the reader divides.
    static func coordinate(_ latE6: Int32, _ lonE6: Int32) -> Coordinate { Coordinate(lat: Double(latE6) / 1e6, lon: Double(lonE6) / 1e6) }

    static func point(_ kind: StreetAccessPoint.Kind, _ system: TransitSystem, source: Int, _ latE6: Int32, _ lonE6: Int32,
                      entry: Bool = true, exit: Bool = true, access: UInt32, snap: StoredSnap?) -> StreetAccessPoint {
        let anchor = snap.map { LinkAnchor(nodeA: $0.segment, nodeB: $0.segment + 1, forwardEdge: nil, backwardEdge: nil,
                                           fraction: Double($0.fraction), snapMeters: $0.distanceMeters, segmentKey: UInt64($0.segment)) }
        return StreetAccessPoint(kind: kind, system: system, sourceStop: source, coordinate: coordinate(latE6, lonE6), entry: entry, exit: exit,
                                 accessSeconds: access, snap: snap, anchor: anchor)
    }

    /// A synthetic point (station A's own coordinate), an entry-only entrance, one stop point per
    /// other system, and PATH stop 8's point that did not snap (not stored).
    static let accessPoints: [StreetAccessPoint] = [
        point(.station, .subway, source: 0, 40_700_000, -74_000_000, access: 120, snap: StoredSnap(segment: 5, fraction: 0.25, distanceDecimeters: 12)),
        point(.entrance, .subway, source: 2, 40_701_250, -73_998_500, exit: false, access: 120, snap: StoredSnap(segment: 7, fraction: 0.5, distanceDecimeters: 30)),
        point(.stop, .bus, source: 3, 40_702_000, -73_999_000, access: 30, snap: StoredSnap(segment: 11, fraction: 0.75, distanceDecimeters: 0)),
        point(.stop, .lirr, source: 5, 40_750_500, -73_993_500, access: 240, snap: StoredSnap(segment: 13, fraction: 0.125, distanceDecimeters: 55)),
        point(.stop, .ferry, source: 6, 40_701_000, -74_013_000, access: 120, snap: StoredSnap(segment: 17, fraction: 1, distanceDecimeters: 1000)),
        point(.station, .path, source: 7, 40_719_000, -74_043_000, access: 90, snap: StoredSnap(segment: 19, fraction: 0, distanceDecimeters: 5)),
        point(.stop, .path, source: 8, 40_735_000, -74_163_000, access: 90, snap: nil),
    ]

    static let network = LinkNetwork(
        systemStopCounts: [3, 2, 1, 1, 2], routable: routable,
        stopAccess: [[], [0], [1], [2], [], [3], [4], [5], [6]], accessPoints: accessPoints, transfers: []
    )

    /// Every routable stop to every other (so every system pair has one), sorted by (seconds, stop).
    static let footpaths: FootpathTable = {
        let stops = (0..<9).filter { routable[$0] }
        var start: [UInt32] = [0], target: [UInt32] = [], seconds: [UInt16] = []
        for p in 0..<9 {
            let row = routable[p] ? stops.filter { $0 != p }.map { q in (UInt16(40 + 11 * abs(p - q) + (p < q ? 0 : 3)), UInt32(q)) }.sorted { $0 < $1 } : []
            for (s, q) in row {
                target.append(q)
                seconds.append(s)
            }
            start.append(UInt32(target.count))
        }
        return FootpathTable(start: start, target: target, seconds: seconds)
    }()

    /// (station, stop, enter, exit); `nil` is `0xFFFF`. Stop 3 and stop 2 are enter-only from
    /// station 0 (stop 2's only point is entry-only), stop 7 exit-only to station 1.
    static let links: [(station: Int, stop: Int, enter: UInt16?, exit: UInt16?)] = [
        (0, 3, 60, nil), (0, 1, 100, 110), (0, 2, 150, nil),
        (1, 5, 300, 310), (1, 7, nil, 200),
        (2, 1, 90, 95),
    ]

    static let stationLinks: StationLinkTable = {
        func stored(_ value: UInt16?) -> UInt16 { value ?? LinksFormat.noSeconds }
        var table = StationLinkTable.empty(stops: 9, stations: 3)
        table.stationStart = [0]
        for station in 0..<3 {
            for link in links.filter({ $0.station == station }).sorted(by: { (stored($0.enter), $0.stop) < (stored($1.enter), $1.stop) }) {
                table.stationStop.append(UInt32(link.stop))
                table.stationEnter.append(stored(link.enter))
                table.stationExit.append(stored(link.exit))
            }
            table.stationStart.append(UInt32(table.stationStop.count))
        }
        table.stopStart = [0]
        for stop in 0..<9 {
            for link in links.filter({ $0.stop == stop }).sorted(by: { (stored($0.exit), $0.station) < (stored($1.exit), $1.station) }) {
                table.stopStation.append(UInt32(link.station))
                table.stopEnter.append(stored(link.enter))
                table.stopExit.append(stored(link.exit))
            }
            table.stopStart.append(UInt32(table.stopStation.count))
        }
        return table
    }()

    /// A (0) → the LIRR stop (5) with one dock (a padded slot); 5 → A, flagged one-seat.
    static let hops = CompiledHops(parameters: hopParameters, stops: 9, hops: [
        CompiledHop(origin: 0, target: 5, pickups: [2, 0], docks: [1], minDecameters: 130, minWalkSeconds: 395, flags: [],
                    bestDecameters: 130, bikeSeconds: 0, droppedByDayMinimum: false),
        CompiledHop(origin: 5, target: 0, pickups: [1], docks: [2, 0], minDecameters: 140, minWalkSeconds: 400, flags: .oneSeatRideExists,
                    bestDecameters: 140, bikeSeconds: 0, droppedByDayMinimum: false),
    ])

    static let compiled = CompiledLinks(network: network, footpaths: footpaths, stationLinks: stationLinks, stationCount: 3,
                                        options: options, hops: hops)

    static let builtAgainst = [
        "streets": String(repeating: "0", count: 64), "stations": String(repeating: "1", count: 64),
        "tt-subway": String(repeating: "2", count: 64),
    ]

    static func artifact(dataVersion: String = V1Fixtures.dataVersion) -> Data {
        LinksArtifactWriter.artifact(compiled, dataVersion: dataVersion, builtAgainst: builtAgainst)
    }
}

/// Format 1 of `links`, frozen 2026-09-27 (`docs/formats.md`, "Compatibility"): the payload golden
/// for ``HandBuiltLinks`` (hops included), the committed v1 file, and the formatVersion and
/// payloadRevision gates. The freeze moved the payload revision from the last draft's 3 to 1,
/// which re-pinned this digest once; the rest of the draft-3 bytes froze unchanged.
@Suite struct LinksV1Tests {
    /// SHA-256 of the writer's payload for ``HandBuiltLinks`` (the header is left out: it embeds
    /// builderSwiftVersion). What may change it:
    /// - a change to the payload layout. That is a new formatVersion (or, for the hops, a new
    ///   extension id), because a v1 reader would misread the bytes; never re-pin this digest for
    ///   one.
    /// - a deliberate change to the hand-built input, or to what the writer puts in a v1 payload
    ///   (such as a newly defined extension id). Review the new bytes, then pin the new digest.
    /// Builder changes (snapping, footpath search, station links, hop selection) don't reach it:
    /// every table is typed by hand.
    static let payloadGolden = "aa51814416aa3610cd62889ac3cd5a7191197b4a2ab95e8f81804b4715a8d4bf"

    static let fixtureName = "links.bin"

    func reader(_ file: Data) throws -> MappedLinks {
        try MappedLinks(artifact: MappedArtifact(fileBytes: file, expecting: .links))
    }

    @Test func payloadMatchesTheGolden() throws {
        let file = HandBuiltLinks.artifact()
        #expect(Data(try ArtifactHeader.decode(from: file).payload) == LinksArtifactWriter.payload(HandBuiltLinks.compiled))
        let digest = try linksPayloadSHA256(file)
        #expect(digest == Self.payloadGolden, "payload sha256 \(digest)")
        #expect(try linksPayloadSHA256(HandBuiltLinks.artifact(dataVersion: "other")) == digest)
    }

    /// The hand-built file is valid, and reads back as typed.
    @Test func readsTheHandBuiltValues() throws {
        let links = try reader(HandBuiltLinks.artifact())
        #expect(links.header.formatVersion == 1 && links.header.builtAgainst == HandBuiltLinks.builtAgainst)
        #expect(links.stopCount == 9 && links.stationCount == 3 && links.maxFootpathWalkSeconds == 480 && links.minTransferSeconds == 30)
        #expect(links.walkSpeedMetersPerSecond == 1.5 && links.stationLinkMaxWalkMeters == 350)
        #expect(LinksFormat.systems.map(links.accessSeconds(system:)) == [120, 30, 240, 120, 90])
        #expect(LinksFormat.systems.map(links.stopBase(system:)) == [0, 3, 5, 6, 7])
        #expect((0..<9).map { links.stopFlags($0).rawValue } == [0, 7, 3, 7, 0, 7, 7, 7, 1])
        #expect(links.footpathCount == 42 && links.footpaths(from: 1).first.map { [$0.stop, $0.seconds] } == [2, 51])
        #expect(links.footpathSeconds(from: 8, to: 1) == 40 + 77 + 3 && links.footpaths(from: 0).isEmpty)

        #expect(links.accessPointCount == 6 && Array(links.accessPoints(ofStop: 8)).isEmpty)
        let synthetic = links.accessPoint(0)
        #expect(synthetic.sourceStop == 0 && synthetic.flags == [.entry, .exit, .synthetic] && synthetic.accessSeconds == 120)
        #expect(synthetic.coordinate == HandBuiltLinks.coordinate(40_700_000, -74_000_000))
        #expect(synthetic.segment == 5 && synthetic.fraction == 0.25 && synthetic.snapDecimeters == 12)
        #expect(links.accessPoint(1).flags == [.entry] && Array(links.accessPoints(ofStop: 2)) == [1])
        #expect(links.accessPoint(4).snapDecimeters == 1000 && links.accessPoint(4).fraction == 1)

        #expect(links.stationLinkCount == 6)
        func rows(_ list: StationStopLinks) -> [[Int]] { list.map { [$0.index, $0.enterSeconds ?? -1, $0.exitSeconds ?? -1] } }
        #expect(rows(links.stops(nearStation: 0)) == [[3, 60, -1], [1, 100, 110], [2, 150, -1]])
        #expect(rows(links.stations(nearStop: 1)) == [[2, 90, 95], [0, 100, 110]])
        #expect(rows(links.stations(nearStop: 7)) == [[1, -1, 200]] && rows(links.stations(nearStop: 3)) == [[0, 60, -1]])

        #expect(links.extensions.ids == [LinksFormat.hopsExtensionID])
        let hops = try #require(links.hops)
        #expect(hops.parameters == HandBuiltLinks.hopParameters && hops.count == 2)
        let out = try #require(hops.hops(fromParent: 0).first), back = try #require(hops.hops(fromParent: 5).first)
        #expect(out.target == 5 && out.pickups == [2, 0] && out.docks == [1] && Array(out.dockSlots) == [1, LinksFormat.noStation])
        #expect(out.minDecameters == 130 && out.minWalkSeconds == 395 && out.flags == [])
        #expect(back.target == 0 && back.pickups == [1] && back.docks == [2, 0] && back.flags == .oneSeatRideExists && back.row == 1)
        #expect((1..<9).allSatisfy { $0 == 5 || hops.hops(fromParent: $0).isEmpty })
    }

    @Test func rejectsEveryOtherFormatVersionAndPayloadRevision() throws {
        let file = HandBuiltLinks.artifact()
        _ = try reader(file)
        for version: UInt16 in [0, 2] {
            #expect(throws: LinksFormatError.unsupportedFormatVersion(version)) { try reader(V1Fixtures.withFormatVersion(version, file)) }
        }
        // Format 1 is revision 1 only; 3 was the last format-0 draft's.
        let (header, payload) = try ArtifactHeader.decode(from: file)
        for revision: UInt32 in [0, 2, 3] {
            #expect(throws: LinksFormatError.unsupportedPayloadRevision(revision)) {
                try reader(header.assemble(payload: Data(payload).replacing(revision, at: 4)))
            }
        }
    }

    /// A reader of this build opens the committed v1 file (`MappedLinks` validates by default) and
    /// reads what was written on the day the format froze. Every value is a literal: the file is
    /// frozen, not rebuilt.
    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func opensTheCommittedV1File() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        let links = try reader(file)
        #expect(links.header.kind == .links && links.header.formatVersion == 1 && links.header.dataVersion == "v1-fixture")
        #expect(links.header.builtAgainst == [
            "streets": String(repeating: "0", count: 64), "stations": String(repeating: "1", count: 64),
            "tt-subway": String(repeating: "2", count: 64),
        ])
        let payload = Data(try ArtifactHeader.decode(from: file).payload)
        #expect(payload.prefix(4) == Data("LNKS".utf8))
        #expect(payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) } == 1)

        #expect(links.stopCount == 9 && links.stationCount == 3 && links.maxFootpathWalkSeconds == 480 && links.minTransferSeconds == 30)
        #expect(links.walkSpeedMetersPerSecond == 1.5 && links.stationLinkMaxWalkMeters == 350)
        #expect([TransitSystem.subway, .bus, .lirr, .ferry, .path].map(links.accessSeconds(system:)) == [120, 30, 240, 120, 90])
        #expect([TransitSystem.subway, .bus, .lirr, .ferry, .path].map(links.stopCount(system:)) == [3, 2, 1, 1, 2])
        #expect([TransitSystem.subway, .bus, .lirr, .ferry, .path].map(links.stopBase(system:)) == [0, 3, 5, 6, 7])
        #expect(links.system(ofGlobalStop: 6) == .ferry && links.localStop(ofGlobalStop: 8) == 1)
        #expect((0..<9).map { links.stopFlags($0).rawValue } == [0, 7, 3, 7, 0, 7, 7, 7, 1])
        #expect(links.stopFlags(1) == [.routable, .streetEntry, .streetExit] && links.stopFlags(2) == [.routable, .streetEntry])

        #expect(links.footpathCount == 42 && links.footpaths(from: 0).isEmpty && links.footpaths(from: 4).isEmpty)
        #expect(links.footpaths(from: 1).map { [$0.stop, $0.seconds] } == [[2, 51], [3, 62], [5, 84], [6, 95], [7, 106], [8, 117]])
        #expect(links.footpaths(from: 8).map { [$0.stop, $0.seconds] } == [[7, 54], [6, 65], [5, 76], [3, 98], [2, 109], [1, 120]])
        #expect(links.footpathSeconds(from: 8, to: 1) == 120 && links.footpathSeconds(from: 1, to: 8) == 117)
        #expect(links.footpathSeconds(from: 1, to: 4) == nil)

        #expect(links.accessPointCount == 6)
        #expect((0..<9).map { Array(links.accessPoints(ofStop: $0)) } == [[], [0], [1], [2], [], [3], [4], [5], []])
        let points = (0..<6).map(links.accessPoint)
        #expect(points.map(\.sourceStop) == [0, 2, 3, 5, 6, 7])
        #expect(points.map(\.flags) == [[.entry, .exit, .synthetic], [.entry], [.entry, .exit], [.entry, .exit], [.entry, .exit],
                                        [.entry, .exit, .synthetic]])
        #expect(points.map(\.accessSeconds) == [120, 120, 30, 240, 120, 90])
        #expect(points.map(\.coordinate) == [
            Coordinate(lat: 40.7, lon: -74), Coordinate(lat: 40.70125, lon: -73.9985), Coordinate(lat: 40.702, lon: -73.999),
            Coordinate(lat: 40.7505, lon: -73.9935), Coordinate(lat: 40.701, lon: -74.013), Coordinate(lat: 40.719, lon: -74.043),
        ])
        #expect(points.map(\.segment) == [5, 7, 11, 13, 17, 19])
        #expect(points.map(\.fraction) == [0.25, 0.5, 0.75, 0.125, 1, 0])
        #expect(points.map(\.snapDecimeters) == [12, 30, 0, 55, 1000, 5])

        #expect(links.stationLinkCount == 6)
        func rows(_ list: StationStopLinks) -> [[Int]] { list.map { [$0.index, $0.enterSeconds ?? -1, $0.exitSeconds ?? -1] } }
        #expect(rows(links.stops(nearStation: 0)) == [[3, 60, -1], [1, 100, 110], [2, 150, -1]])
        #expect(rows(links.stops(nearStation: 1)) == [[5, 300, 310], [7, -1, 200]])
        #expect(rows(links.stops(nearStation: 2)) == [[1, 90, 95]])
        #expect(rows(links.stations(nearStop: 1)) == [[2, 90, 95], [0, 100, 110]])
        #expect(rows(links.stations(nearStop: 7)) == [[1, -1, 200]] && rows(links.stations(nearStop: 3)) == [[0, 60, -1]])
        #expect(rows(links.stations(nearStop: 8)).isEmpty)

        #expect(links.extensions.ids == [1])
        let hops = try #require(links.hops)
        #expect(hops.parameters == LinkHopParameters(minRideSeconds: 300, maxRideSeconds: 1500, minSpeedMmPerSecond: 3040,
                                                     maxSpeedMmPerSecond: 5141, rankSpeedMmPerSecond: 4470, unlockSeconds: 90,
                                                     dockSeconds: 60, pickupsPerHop: 2, docksPerHop: 2))
        #expect(hops.count == 2)
        let out = try #require(hops.hops(fromParent: 0).first), back = try #require(hops.hops(fromParent: 5).first)
        #expect(hops.hops(fromParent: 0).count == 1 && hops.hops(fromParent: 5).count == 1)
        #expect(out.target == 5 && out.pickups == [2, 0] && out.docks == [1] && Array(out.dockSlots) == [1, 0xFFFF] && out.row == 0)
        #expect(out.minDecameters == 130 && out.minWalkSeconds == 395 && out.flags == [])
        #expect(back.target == 0 && back.pickups == [1] && Array(back.pickupSlots) == [1, 0xFFFF] && back.docks == [2, 0])
        #expect(back.minDecameters == 140 && back.minWalkSeconds == 400 && back.flags == .oneSeatRideExists && back.row == 1)
        #expect([1, 2, 3, 4, 6, 7, 8].allSatisfy { hops.hops(fromParent: $0).isEmpty })
    }

    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func rejectsTheCommittedFileUnderAnyOtherFormatVersion() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        for version: UInt16 in [0, 2] {
            #expect(throws: LinksFormatError.unsupportedFormatVersion(version)) { try reader(V1Fixtures.withFormatVersion(version, file)) }
        }
    }

    /// Rewrites `Tests/Fixtures/v1/links.bin` from ``HandBuiltLinks``. Only with
    /// `BR_WRITE_V1_FIXTURES=1`; see ``V1Fixtures`` for when that is right.
    @Test(.enabled(if: V1Fixtures.regenerating, "set BR_WRITE_V1_FIXTURES=1 to rewrite the v1 fixtures"))
    func writeV1Fixture() throws {
        let file = HandBuiltLinks.artifact()
        _ = try reader(file)
        try V1Fixtures.write(file, to: Self.fixtureName)
    }
}
