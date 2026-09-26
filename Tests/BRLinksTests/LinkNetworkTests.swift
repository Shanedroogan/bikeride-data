import BRBuild
import BRCore
import BRGeo
import BRStreetCore
import BRTimetable
import Foundation
import Testing

@Suite struct LinkNetworkTests {
    let world: TransitFixture.World
    let network: LinkNetwork
    let stats: LinkNetworkStats
    let options = LinksOptions()

    init() throws {
        world = try TransitFixture.world()
        (network, stats) = LinkNetwork.make(timetables: world.timetables, graph: world.city.graph, options: options)
    }

    func stop(_ system: TransitSystem, _ id: String) -> Int { network.global(system, id, in: world.timetables) }
    func points(_ system: TransitSystem, _ id: String) -> [StreetAccessPoint] { network.stopAccess[stop(system, id)].map { network.accessPoints[$0] } }

    @Test func numbersStopsAcrossTheTimetables() {
        let counts = [TransitSystem.subway, .bus, .lirr].map { world.timetables[$0]!.stopCount }
        #expect(network.systemStopCounts == counts + [0, 0])
        #expect(network.stopBase(.bus) == counts[0] && network.stopBase(.lirr) == counts[0] + counts[1])
        #expect(network.stopCount == counts.reduce(0, +))
        for id in ["S1N", "S1S", "S2N", "S3N", "S3S", "S4N", "S4S"] { #expect(network.routable[stop(.subway, id)], "\(id)") }
        for id in ["S1", "S2", "S3", "S4", "S1-E1"] { #expect(!network.routable[stop(.subway, id)], "\(id)") }
        for id in ["S1", "S1-E1"] { #expect(network.stopAccess[stop(.subway, id)].isEmpty) }
        // A platform no trip calls at is not in the timetable at all.
        #expect(world.timetables[.subway]!.stop(gtfsID: "S2S") == nil)
    }

    @Test func accessPointsAreEntrancesElseTheStationElseTheStop() {
        let s1 = points(.subway, "S1N")
        #expect(s1.map(\.kind) == [.entrance, .entrance])
        #expect(s1.allSatisfy { $0.anchor != nil && $0.snap != nil && $0.accessSeconds == 120 })
        #expect(Set(s1.map { [$0.entry, $0.exit] }) == [[true, true], [true, false]])
        #expect(network.stopAccess[stop(.subway, "S1N")] == network.stopAccess[stop(.subway, "S1S")]) // shared entrances
        let s2 = points(.subway, "S2N")
        #expect(s2.count == 1 && !s2[0].entry && s2[0].exit)
        let s3 = points(.subway, "S3N")
        #expect(s3.count == 1 && s3[0].kind == .station && s3[0].entry && s3[0].exit)
        #expect(s3[0].sourceStop == stop(.subway, "S3") && s3[0].coordinate.distance(to: SyntheticCity.coordinate(6, 6)) < 0.2)
        let b1 = points(.bus, "B1")
        #expect(b1.count == 1 && b1[0].kind == .stop && b1[0].accessSeconds == 30 && b1[0].anchor!.snapMeters < 5)
        #expect(points(.bus, "B4").allSatisfy { $0.anchor == nil })
        #expect(points(.lirr, "L1")[0].accessSeconds == 240 && points(.lirr, "L1")[0].anchor != nil)
        #expect(points(.lirr, "L2").allSatisfy { $0.anchor == nil })
        // Stored snaps rebuild the anchors exactly.
        for point in network.accessPoints where point.anchor != nil {
            let rebuilt = world.city.graph.snappedPoint(point.snap!, query: point.coordinate)!
            #expect(LinkAnchor(rebuilt) == point.anchor!)
        }

        #expect(stats.systems["subway"]?.stationsWithoutEntrances == ["S3"])
        #expect(stats.systems["subway"]?.accessPoints == ["entrance": 4, "station": 1])
        #expect(stats.systems["subway"]?.routableWithoutStreetEntry == 1) // S2N: its only entrance is exit-only
        #expect(stats.systems["bus"]?.unsnappedAccessPoints == 1 && stats.systems["bus"]?.rideThroughOnly == ["B4 Bus Four"])
        #expect(stats.systems["lirr"]?.rideThroughOnly == ["L2 Rail Two"])
        // By default only PATH is limited to the service area.
        #expect(options.streetAccessOnlyInsideServiceArea == [.path])
        #expect(stats.systems["bus"]?.accessPointsOutsideServiceArea == 0 && stats.systems["bus"]?.rideThroughOutsideServiceArea == [])
    }

    @Test func systemsLimitedToTheServiceAreaAreRideThroughOutsideIt() {
        // As PATH's Newark and Harrison stations are: B4 and L2 lie outside the fixture's region.
        var limited = LinksOptions()
        limited.streetAccessOnlyInsideServiceArea = [.bus, .lirr]
        let (network, stats) = LinkNetwork.make(timetables: world.timetables, graph: world.city.graph, options: limited)
        #expect(!world.city.graph.serviceArea.contains(world.timetables[.bus]!.stopCoordinate(world.timetables[.bus]!.stop(gtfsID: "B4")!)))
        let bus = stats.systems["bus"]!, lirr = stats.systems["lirr"]!
        #expect(bus.rideThroughOutsideServiceArea == ["B4 Bus Four"] && bus.rideThroughOnly.isEmpty)
        #expect(bus.accessPointsOutsideServiceArea == 1 && bus.unsnappedAccessPoints == 0)
        #expect(bus.routableWithoutStreetEntry == 1 && bus.routableWithoutStreetExit == 1)
        #expect(lirr.rideThroughOutsideServiceArea == ["L2 Rail Two"] && lirr.rideThroughOnly.isEmpty)
        // Stops inside the area are linked exactly as before.
        #expect(network.accessPoints.map(\.anchor) == self.network.accessPoints.map(\.anchor))
        #expect(network.transfers == self.network.transfers)
    }

    @Test func expandsParentLevelTransfersToPlatformPairs() {
        let pairs = Dictionary(uniqueKeysWithValues: network.transfers.map { ([$0.from, $0.to], $0.seconds) })
        let s1n = stop(.subway, "S1N"), s1s = stop(.subway, "S1S"), s2n = stop(.subway, "S2N")
        let s4n = stop(.subway, "S4N"), s4s = stop(.subway, "S4S")
        #expect(pairs[[s1n, s1s]] == 30 && pairs[[s1s, s1n]] == 30) // listed as 0 s, raised to the floor
        #expect(pairs[[s1n, s2n]] == 90 && pairs[[s1s, s2n]] == 90 && pairs[[s2n, s1n]] == 90 && pairs[[s2n, s1s]] == 90)
        #expect(pairs[[s4n, s4s]] == 180 && pairs[[s4s, s4n]] == 180)
        #expect(pairs.count == 8) // none for the "not possible" row or the unknown station
        #expect(pairs.keys.allSatisfy { $0[0] != $0[1] })
        let subway = stats.systems["subway"]!
        #expect(subway.transferRowsRaisedToMinimum == 1 && subway.transferRowsSkipped["not possible"] == 1)
        #expect(subway.transferPairs == 8)
    }

    @Test func addsConfiguredCrossSystemTransfersBothWays() {
        var custom = LinksOptions()
        custom.fixedTransfers = [
            FixedTransfer(from: "S:S1", to: "B:B2", seconds: 45),   // station → both platforms
            FixedTransfer(from: "S:S4N", to: "B:B2", seconds: 200),
            FixedTransfer(from: "S:S4N", to: "B:B2", seconds: 150), // the quicker listing wins
            FixedTransfer(from: "P:place_WTC", to: "S:S1", seconds: 60),
        ]
        let (withFixed, fixedStats) = LinkNetwork.make(timetables: world.timetables, graph: world.city.graph, options: custom)
        let pairs = Dictionary(uniqueKeysWithValues: withFixed.transfers.map { ([$0.from, $0.to], $0.seconds) })
        let b2 = stop(.bus, "B2"), s1n = stop(.subway, "S1N"), s1s = stop(.subway, "S1S"), s4n = stop(.subway, "S4N")
        #expect(pairs[[s1n, b2]] == 45 && pairs[[b2, s1n]] == 45 && pairs[[s1s, b2]] == 45 && pairs[[b2, s1s]] == 45)
        #expect(pairs[[s4n, b2]] == 150 && pairs[[b2, s4n]] == 150)
        #expect(pairs.count == 8 + 6)
        #expect(fixedStats.fixedTransferPairs == 8)
        #expect(fixedStats.fixedTransfersUnresolved == ["P:place_WTC→S:S1"])
        // The defaults name PATH↔subway stations, which this fixture lacks.
        #expect(stats.fixedTransfersUnresolved.count == FixedTransfer.pathSubway.count)
    }

    /// The reference cost of walking between two access points over the street graph alone, via
    /// BRStreetCore's own `Dijkstra` and snapped-point helpers (not the links code).
    func streetWalkMs(from a: StreetAccessPoint, to b: StreetAccessPoint) throws -> UInt32? {
        let graph = world.city.graph
        let pa = graph.snappedPoint(a.snap!, query: a.coordinate)!, pb = graph.snappedPoint(b.snap!, query: b.coordinate)!
        let tree = try Dijkstra.oneToMany(in: graph, from: pa, profile: options.walk)
        let viaTree = tree.cost(to: pb, in: graph, profile: options.walk)
        let direct = pa.directCostMs(to: pb, in: graph, profile: options.walk)
        return [viaTree, direct].compactMap { $0 }.min()
    }

    func snapMs(_ point: StreetAccessPoint) -> UInt32 { UInt32((point.anchor!.snapMeters / options.walk.speedMetersPerSecond * 1000).rounded()) }

    @Test func chargesStationAccessOnceAtEachStreetPlatformTransition() throws {
        let compiled = LinksBuilder.build(network: network, stationAnchors: [], graph: world.city.graph, options: options)
        let rows = compiled.footpaths.rows(network.stopCount)
        func seconds(_ from: Int, _ to: Int) -> Int? { rows[from].first { $0.stop == to }?.seconds }

        // Bus stop to bus stop across the street: 30 s out, the walk, 30 s in.
        let b1 = points(.bus, "B1")[0], b2 = points(.bus, "B2")[0]
        let busWalk = try #require(try streetWalkMs(from: b1, to: b2))
        let busExpected = Int((30_000 + snapMs(b1) + busWalk + snapMs(b2) + 30_000 + 999) / 1000)
        #expect(seconds(stop(.bus, "B1"), stop(.bus, "B2")) == busExpected)
        #expect(busExpected >= 60 && busExpected < 75)

        // Subway platform to bus stop: out through an exit-allowed entrance (not the entry-only
        // one) for 120 s, or through the complex (90 s to S2) and out of S2's exit.
        let exits = points(.subway, "S1N").filter(\.exit)
        #expect(exits.count == 1)
        var candidates: [UInt32] = []
        for exit in exits { candidates.append(120_000 + snapMs(exit) + (try streetWalkMs(from: exit, to: b1))! + snapMs(b1) + 30_000) }
        let s2exit = points(.subway, "S2N")[0]
        candidates.append(90_000 + 120_000 + snapMs(s2exit) + (try streetWalkMs(from: s2exit, to: b1))! + snapMs(b1) + 30_000)
        #expect(seconds(stop(.subway, "S1N"), stop(.bus, "B1")) == Int((candidates.min()! + 999) / 1000))

        // In-station transfers beat leaving and re-entering (120 + 120 s).
        #expect(seconds(stop(.subway, "S1N"), stop(.subway, "S1S")) == 30)
        #expect(seconds(stop(.subway, "S1N"), stop(.subway, "S2N")) == 90)
        #expect(seconds(stop(.subway, "S2N"), stop(.subway, "S1N")) == 90)
        // S2 cannot be entered from the street: every walk into S2N goes through S1.
        let intoS2 = (0..<network.stopCount).compactMap { p in seconds(p, stop(.subway, "S2N")).map { (p, $0) } }
        for (p, s) in intoS2 where p != stop(.subway, "S1N") && p != stop(.subway, "S1S") {
            let viaS1 = [seconds(p, stop(.subway, "S1N")), seconds(p, stop(.subway, "S1S"))].compactMap { $0 }.min()!
            #expect(s == viaS1 + 90)
        }
        // Ride-through and unsnapped stops have no footpaths.
        #expect(rows[stop(.lirr, "L2")].isEmpty && rows[stop(.bus, "B4")].isEmpty)
        #expect(!rows.contains { $0.contains { $0.stop == stop(.lirr, "L2") || $0.stop == stop(.bus, "B4") } })
        // LIRR access is 240 s at the L1 end.
        let l1 = points(.lirr, "L1")[0]
        if let s = seconds(stop(.lirr, "L1"), stop(.bus, "B1")) {
            let walk = try #require(try streetWalkMs(from: l1, to: b1))
            #expect(s == Int((240_000 + snapMs(l1) + walk + snapMs(b1) + 30_000 + 999) / 1000))
        }
    }

    @Test func footpathsMatchTheReferenceAndAreClosed() {
        let compiled = LinksBuilder.build(network: network, stationAnchors: [], graph: world.city.graph, options: options)
        let expected = LinksReference(network: network, graph: world.city.graph, options: options).footpaths()
        let actual = compiled.footpaths.rows(network.stopCount)
        for stop in 0..<network.stopCount {
            #expect(actual[stop].map(\.stop) == expected[stop].map(\.stop), "stop \(stop)")
            #expect(actual[stop].map(\.seconds) == expected[stop].map(\.seconds), "stop \(stop)")
        }
        let check = FootpathCheck.run(compiled.footpaths, walkSeconds: Int(options.maxFootpathWalkSeconds),
                                      stopAccessSeconds: LinksBuilder.stopAccessSeconds(network, options))
        #expect(check.passed && check.triplesChecked > 0)
        #expect(compiled.footpathStats.bySystemPair["subway→bus"]! > 0 && compiled.footpathStats.bySystemPair["bus→subway"]! > 0)
    }

    func anchor(_ x: Double, _ y: Double) -> LinkAnchor? {
        let c = SyntheticCity.coordinate(x, y)
        guard let point = world.city.graph.snap(c, profile: options.walk) else { return nil }
        return world.city.graph.snappedPoint(StoredSnap(point), query: c).map(LinkAnchor.init)
    }

    @Test func linksStationsToStopsWithinTheWalkBound() throws {
        let stations = [anchor(2.0, 2.3), anchor(9.8, 0.2), anchor(9, 8.9), nil]
        let compiled = LinksBuilder.build(network: network, stationAnchors: stations, graph: world.city.graph, options: options)
        let table = compiled.stationLinks
        func links(_ station: Int) -> [Int: (enter: Int?, exit: Int?)] {
            var result: [Int: (enter: Int?, exit: Int?)] = [:]
            for slot in Int(table.stationStart[station])..<Int(table.stationStart[station + 1]) {
                let enter = table.stationEnter[slot], exit = table.stationExit[slot]
                result[Int(table.stationStop[slot])] = (enter == LinksFormat.noSeconds ? nil : Int(enter), exit == LinksFormat.noSeconds ? nil : Int(exit))
            }
            return result
        }
        let near = links(0)
        #expect(near[stop(.subway, "S1N")]?.enter != nil && near[stop(.subway, "S1N")]?.exit != nil)
        #expect(near[stop(.subway, "S1N")]?.enter == near[stop(.subway, "S1S")]?.enter)
        #expect(near[stop(.subway, "S2N")]?.enter == nil && near[stop(.subway, "S2N")]?.exit != nil) // exit-only entrance
        #expect(near[stop(.bus, "B1")] != nil && near[stop(.bus, "B2")] != nil)
        #expect(links(1).isEmpty && links(3).isEmpty)
        #expect(Set(links(2).keys) == [stop(.bus, "B3")])

        // Enter = walk from the station's snapped point to the entrance's, both snap legs, then access.
        let station = stations[0]!
        let entrances = points(.subway, "S1N").filter(\.entry)
        let origin = StreetAccessPoint(kind: .stop, system: .bus, sourceStop: 0, coordinate: .init(lat: 0, lon: 0), entry: true, exit: true,
                                       accessSeconds: 0, snap: StoredSnap(segment: UInt32(station.segmentKey), fraction: Float(station.fraction),
                                                                         distanceDecimeters: UInt16((station.snapMeters * 10).rounded())),
                                       anchor: station)
        let expectedEnter = try entrances.map { entrance -> UInt32 in
            snapMs(origin) + (try streetWalkMs(from: origin, to: entrance))! + snapMs(entrance) + 120_000
        }.min()!
        #expect(near[stop(.subway, "S1N")]?.enter == Int((expectedEnter + 999) / 1000))

        // Everything agrees with the reference.
        let expected = LinksReference(network: network, graph: world.city.graph, options: options).stationLinks(stations)
        for index in stations.indices {
            let actual = links(index)
            #expect(Set(actual.keys) == Set(expected[index].keys))
            for (stop, value) in expected[index] { #expect(actual[stop]?.enter == value.enter && actual[stop]?.exit == value.exit) }
        }
        #expect(compiled.stationLinkStats.stations == 4 && compiled.stationLinkStats.stationsWithWalkSnap == 3)
        #expect(compiled.stationLinkStats.stationsWithoutStops == 2)
    }
}
