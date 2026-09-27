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
/// reaches the bytes and the digest is the same on macOS and Linux.
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

    static func artifact(dataVersion: String = "v1-fixture") -> Data {
        LinksArtifactWriter.artifact(compiled, dataVersion: dataVersion, builtAgainst: builtAgainst)
    }
}

/// The frozen-to-be `links` layout: the payload golden for ``HandBuiltLinks``, and the payload
/// revision gate. `links` is still format 0 (payload revision 3); the P2c freeze flips it to
/// format 1, revision 1, which changes the 4 revision bytes, so that step re-pins this digest once
/// and commits `Tests/Fixtures/v1/links.bin`. After that a layout change never re-pins it: it
/// needs a new formatVersion (or, for the hops, a new extension id).
@Suite struct LinksV1Tests {
    /// SHA-256 of the writer's payload for ``HandBuiltLinks`` (the header is left out: it embeds
    /// builderSwiftVersion). Review the new bytes before pinning a new digest, and only for a
    /// deliberate change to the hand-built input or to what the writer puts in the payload.
    static let payloadGolden = "ee177e5d8a842e5ca6c032c3a86291785e4186e83df51b487aa0a985380bea39"

    func reader(_ file: Data) throws -> MappedLinks {
        try MappedLinks(artifact: MappedArtifact(fileBytes: file, expecting: .links))
    }

    @Test func payloadMatchesTheGolden() throws {
        let file = HandBuiltLinks.artifact()
        #expect(Data(try ArtifactHeader.decode(from: file).payload) == LinksArtifactWriter.payload(HandBuiltLinks.compiled))
        let digest = try linksPayloadSHA256(file)
        #expect(digest == Self.payloadGolden)
        #expect(try linksPayloadSHA256(HandBuiltLinks.artifact(dataVersion: "other")) == digest)
    }

    /// The hand-built file is valid, and reads back as typed.
    @Test func readsTheHandBuiltValues() throws {
        let links = try reader(HandBuiltLinks.artifact())
        #expect(links.header.formatVersion == ArtifactKind.links.currentFormatVersion && links.header.builtAgainst == HandBuiltLinks.builtAgainst)
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

    @Test func rejectsEveryOtherPayloadRevision() throws {
        let file = HandBuiltLinks.artifact()
        let (header, payload) = try ArtifactHeader.decode(from: file)
        for revision: UInt32 in [0, 1, 2, 4] {
            #expect(throws: LinksFormatError.unsupportedPayloadRevision(revision)) {
                try reader(header.assemble(payload: Data(payload).replacing(revision, at: 4)))
            }
        }
    }
}
