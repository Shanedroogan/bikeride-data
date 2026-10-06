@testable import BRBuild
import BRGeo
import BRStreetCore
import Foundation
import Testing

/// The profile rules and graph construction, checked on `Tests/Fixtures/osm/streets-fixture.opl`.
/// Node positions are lattice points; see ``StreetsFixtures/coordinate(_:_:)``.
@Suite struct StreetsCompileTests {
    let f: FixtureStreets

    init() throws {
        f = try FixtureStreets.build()
    }

    private func node(_ x: Double, _ y: Double, sourceLocation: SourceLocation = #_sourceLocation) throws -> UInt32 {
        try #require(f.node(x, y), "no graph node at (\(x), \(y))", sourceLocation: sourceLocation)
    }

    private func edge(_ a: UInt32, _ b: UInt32, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        try #require(f.edge(from: a, to: b), "no edge \(a) → \(b)", sourceLocation: sourceLocation)
    }

    private func meters(_ points: [(Double, Double)]) -> Double {
        let coordinates = points.map { StreetsFixtures.coordinate($0.0, $0.1) }
        return zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    @Test func dropsSidewalksCrossingsAndUnroutableWays() throws {
        // The sidewalks (w8, w30), the marked crossing (w9) and the footway tagged only
        // crossing=* (w28) are set aside: walkers use the centerlines. Their own nodes never
        // become graph nodes unless a connector runs through them.
        #expect(f.stats.sidewalkNetworkWays == 4)
        #expect(f.node(2, -0.1) == nil) // sidewalk corner, n3003
        #expect(f.node(1, 0.1) == nil) // crossing end, n4001
        #expect(f.stats.waysDropped["sidewalk_or_crossing"] == nil) // walkable, so kept aside instead

        // Motorway, construction, private service road, service area, trunk with sidewalk=no.
        #expect(f.stats.waysDropped["not_routable_highway"] == 2)
        #expect(f.stats.waysDropped["no_access"] == 2)
        #expect(f.stats.waysDropped["area"] == 1)
        for (x, y) in [(3.0, 0.0), (2.5, 1.5), (-0.5, 1.0), (-0.5, -0.5), (3.0, 0.5)] {
            #expect(f.node(x, y) == nil, "(\(x), \(y)) belongs to a dropped way")
        }
        #expect(f.stats.waysRead == 30)
        #expect(f.segments(named: "Expressway").isEmpty && f.segments(named: "Trunk Road").isEmpty)
    }

    @Test func connectsSidewalkOnlyPathsToTheCenterline() throws {
        // The park path (w10) touches only the sidewalk, at n3001. A connector follows the dropped
        // sidewalk and crossing to 1st Street at n1001.
        #expect(f.stats.connectorsAdded == 2 && f.stats.islandConnectorsAdded == 1)
        let start = try node(0, -0.1), street = try node(1, 0)
        for (a, b) in [(start, street), (street, start)] {
            let e = try edge(a, b)
            #expect(f.graph.flags(ofEdge: e).isSuperset(of: [.walk, .bikeForward, .connector, .dismount]))
            #expect(f.graph.name(ofEdge: e) == "sidewalk")
            #expect(f.graph.shape(ofEdge: e).count == 3) // through the sidewalk corner n3002
        }
        let expected = meters([(0, -0.1), (1, -0.1), (1, 0)])
        #expect(abs(Double(f.graph.lengthDecimeters(ofEdge: try edge(start, street))) - expected * 10) <= 1)
        // Bikes may be walked along it, at walking pace.
        let flags = f.graph.flags(ofEdge: try edge(start, street))
        let length = f.graph.lengthDecimeters(ofEdge: try edge(start, street))
        let walked = try #require(BikeProfile.eBike.costMs(lengthDecimeters: length, flags: flags, bikeClass: .shared))
        #expect(walked > WalkProfile.standard.costMs(lengthDecimeters: length, flags: flags, bikeClass: .shared)!)
    }

    @Test func connectsIslandsReachableOnlyAlongSidewalks() throws {
        // Hidden Mews (w29) is a street, but joins the network only through a sidewalk (w30) that
        // ends at NY 9A. Without a connector it would be an islet and be dropped.
        let mews = try node(2.5, -1.5), ny9A = try node(2, -1)
        #expect(f.node(3, -1.5) != nil)
        #expect(f.node(2.25, -1.25) == nil) // the sidewalk's middle node is a shape point
        let e = try edge(mews, ny9A)
        #expect(f.graph.flags(ofEdge: e).isSuperset(of: [.walk, .connector]))
        #expect(f.graph.name(ofEdge: e) == "sidewalk")
        #expect(abs(Double(f.graph.lengthDecimeters(ofEdge: e)) - meters([(2.5, -1.5), (2.25, -1.25), (2, -1)]) * 10) <= 1)
        #expect(f.segments(named: "Hidden Mews").count == 1)

        // Only when the sidewalk is short enough. Island connectors have their own limit (a
        // bridge sidewalk can be the only way onto an island), so the path limit alone does not
        // cut the mews off.
        var options = StreetBuildOptions()
        options.connectorMaxMeters = 50
        let pathLimitOnly = try FixtureStreets.build(options: options)
        #expect(pathLimitOnly.stats.islandConnectorsAdded == 1)
        #expect(pathLimitOnly.segments(named: "Hidden Mews").count == 1)
        options.islandConnectorMaxMeters = 50
        let short = try FixtureStreets.build(options: options)
        #expect(short.stats.islandConnectorsAdded == 0)
        #expect(short.segments(named: "Hidden Mews").isEmpty)
        #expect(short.stats.droppedComponentSegments > f.stats.droppedComponentSegments)
    }

    @Test func bikesObeyOneWaysUnlessExemptOrContraflow() throws {
        // C Avenue: tertiary, one-way southbound, no exemption.
        let (c2, c1) = (try node(2, 2), try node(2, 1))
        #expect(f.graph.flags(ofEdge: try edge(c2, c1)).isSuperset(of: [.walk, .bikeForward]))
        #expect(f.graph.flags(ofEdge: try edge(c1, c2)) == [.walk]) // walkers ignore one-ways
        #expect(f.graph.bikeClass(ofEdge: try edge(c2, c1)) == .arterial)

        // B Avenue: secondary, one-way north, with a painted contraflow lane (cycleway:left, -1).
        let (b0, b1) = (try node(1, 0), try node(1, 1))
        let north = try edge(b0, b1), south = try edge(b1, b0)
        #expect(f.graph.flags(ofEdge: north).contains(.bikeForward) && f.graph.flags(ofEdge: south).contains(.bikeForward))
        #expect(f.graph.bikeClass(ofEdge: north) == .arterial)
        #expect(f.graph.bikeClass(ofEdge: south) == .painted)

        // D Street: one-way, oneway:bicycle=no.
        let (d0, d1) = (try node(1, 2), try node(1, 3))
        #expect(f.graph.flags(ofEdge: try edge(d0, d1)).contains(.bikeForward))
        #expect(f.graph.flags(ofEdge: try edge(d1, d0)).contains(.bikeForward))
        #expect(f.graph.bikeClass(ofEdge: try edge(d0, d1)) == .shared)

        // E Street: two-way, cycleway:right=track serves the way's direction only.
        let (e0, e1) = (try node(0, 3), try node(1, 3))
        #expect(f.graph.bikeClass(ofEdge: try edge(e0, e1)) == .protected)
        #expect(f.graph.bikeClass(ofEdge: try edge(e1, e0)) == .shared)

        // A search agrees: riding north on C Avenue means going around it.
        let tree = try Dijkstra.oneToMany(in: f.graph, sources: [(c1, 0)], profile: BikeProfile.eBike, options: .recordParents)
        let path = try #require(tree.path(for: c2, in: f.graph))
        #expect(path.edges.count > 1)
    }

    @Test func stepsAreWalkOnlyAndPenalized() throws {
        let (bottom, top) = (try node(2, 2), try node(2.3, 2.3))
        for e in [try edge(bottom, top), try edge(top, bottom)] {
            let flags = f.graph.flags(ofEdge: e)
            #expect(flags == [.walk, .stairs])
            #expect(f.graph.name(ofEdge: e) == "steps")
            #expect(f.graph.nameKind(id: f.graph.nameID(ofEdge: e)) == .derived)
            let length = f.graph.lengthDecimeters(ofEdge: e)
            let plain = WalkProfile.standard.costMs(lengthDecimeters: length, flags: .walk, bikeClass: .shared)!
            let stairs = try #require(WalkProfile.standard.costMs(ofEdge: e, inNetwork: f.graph))
            #expect(abs(Int(stairs) - 2 * Int(plain)) <= 1) // twice the time, rounded once
            #expect(BikeProfile.eBike.costMs(ofEdge: e, inNetwork: f.graph) == nil)
        }
    }

    @Test func compressesDegreeTwoChainsIntoSegmentsWithShapePoints() throws {
        // 2nd Street's two interior nodes are shape points, not graph nodes.
        #expect(f.node(0.33, 1.05) == nil && f.node(0.66, 1.05) == nil)
        let second = try edge(try node(0, 1), try node(1, 1))
        let shape = f.graph.shape(ofEdge: second)
        #expect(shape.count == 4)
        #expect(abs(shape[1].lat - 40.700945) < 1e-6 && abs(shape[1].lon - -73.999604) < 1e-6)
        let secondMeters = meters([(0, 1), (0.33, 1.05), (0.66, 1.05), (1, 1)])
        #expect(abs(Double(f.graph.lengthDecimeters(ofEdge: second)) - secondMeters * 10) <= 1)
        #expect(f.graph.name(ofEdge: second) == "2nd Street")

        // 3rd Street arrives as two OSM ways split at a node nothing else uses: one segment, and
        // the collinear split node is simplified away.
        #expect(f.node(0.5, 2) == nil)
        let third = try edge(try node(0, 2), try node(1, 2))
        #expect(f.graph.shape(ofEdge: third).count == 2)
        #expect(abs(Double(f.graph.lengthDecimeters(ofEdge: third)) - meters([(0, 2), (1, 2)]) * 10) <= 1)
        #expect(f.segments(named: "3rd Street").count == 2) // x 0→1 and 1→2
        #expect(f.stats.piecesBeforeMerge > f.stats.segmentsAfterMerge)

        // A node joining exactly two segments is kept only where something changes; in this
        // fixture that is always the street name.
        var incident: [UInt32: [UInt32]] = [:]
        for s in 0..<UInt32(f.graph.segmentCount) {
            let (a, b) = f.graph.endpoints(ofSegment: s)
            incident[a, default: []].append(s)
            if b != a { incident[b, default: []].append(s) }
        }
        let degreeTwo = incident.filter { $0.value.count == 2 }
        // n1000, n3001, n6001, n8001, n8002, n8005, n8007 (Café Street + Plaza), n9101
        #expect(degreeTwo.count == 8)
        for (v, segments) in degreeTwo {
            #expect(f.graph.nameID(ofSegment: segments[0]) != f.graph.nameID(ofSegment: segments[1]), "node \(v) could merge")
        }
    }

    @Test func namesFallBackFromNameToRefToADerivedLabel() throws {
        let expected: [(String, StreetNameKind)] = [
            ("Café Street", .tagged), // OPL escapes decoded
            ("Test Bridge", .tagged), // bridge:name on an unnamed bridge
            ("Plaza", .tagged),
            ("NY 9A / US 9", .ref), // ref, with ';' lists joined
            ("bike path", .derived), // unnamed cycleway
            ("park path", .derived), // unnamed footway inside a park
            ("steps", .derived),
            ("driveway", .derived),
            ("sidewalk", .derived), // the synthesized connector
        ]
        for (name, kind) in expected {
            let segments = f.segments(named: name)
            #expect(!segments.isEmpty, "no segment named \(name)")
            for s in segments { #expect(f.graph.nameKind(id: f.graph.nameID(ofSegment: s)) == kind, "\(name)") }
        }
        // Names are stored once each, sorted by UTF-8 bytes.
        let names = (0..<UInt32(f.graph.nameCount)).map { f.graph.name(id: $0) }
        #expect(names == names.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
    }

    @Test func flagsBridgesParksAreasAndTrunks() throws {
        // A footway bridge open to bikes: walk + ride both ways, off-street (protected).
        let bridge = try edge(try node(3, 1), try node(4, 1))
        #expect(f.graph.flags(ofEdge: bridge) == [.walk, .bikeForward, .bridge])
        #expect(f.graph.bikeClass(ofEdge: bridge) == .protected)

        // The unnamed footway inside the park polygon; the named path outside it is not a park path.
        let park = try edge(try node(0, -0.1), try node(1, -0.5))
        #expect(f.graph.flags(ofEdge: park) == [.walk, .park])
        let overlook = try edge(try node(2.3, 2.3), try node(2.6, 2.6))
        #expect(f.graph.flags(ofEdge: overlook) == [.walk])
        #expect(f.graph.name(ofEdge: overlook) == "Overlook Path")

        // The pedestrian area is walked along its outline: a loop at the node it shares with Café
        // Street, walk only.
        let plaza = try #require(f.segments(named: "Plaza").first)
        let (a, b) = f.graph.endpoints(ofSegment: plaza)
        let corner = try node(1.5, 3)
        #expect(a == b && a == corner)
        #expect(f.graph.shape(ofSegment: plaza).count == 5)
        let plazaEdge = try #require(f.graph.edges(ofSegment: plaza).forward)
        #expect(f.graph.flags(ofEdge: Int(plazaEdge)) == [.walk])

        // A trunk with bicycle=yes and separately mapped sidewalks: walkable and rideable.
        let trunk = try edge(try node(2, 1), try node(3, 1))
        #expect(f.graph.flags(ofEdge: trunk) == [.walk, .bikeForward])
        #expect(f.graph.bikeClass(ofEdge: trunk) == .arterial)
        #expect(f.graph.name(ofEdge: trunk) == "Bike Trunk")
    }

    @Test func keepsOnlyLargeConnectedComponents() throws {
        // The Island Loop footway touches nothing else and is far below 5% of the main network.
        #expect(f.node(5, 5) == nil)
        #expect(f.stats.components == 2)
        #expect(f.stats.droppedComponentSegments == 1 && f.stats.droppedComponentVertices == 1)
        #expect(f.stats.largestComponentLengthShare > 0.95 && f.stats.largestComponentLengthShare < 1)
        #expect(f.stats.keptComponentMeters.count == 1)
        #expect(f.stats.walkIslandShare == 0 && f.stats.bikeIslandShare == 0)

        // What is left is one walking component and one strongly connected riding component.
        let walk = try Dijkstra.oneToMany(in: f.graph, sources: [(0, 0)], profile: WalkProfile.standard)
        #expect(walk.costMs.allSatisfy { $0 != ShortestPathTree.unreached })
        var rideable = Set<UInt32>()
        for e in 0..<f.graph.edgeCount where f.graph.flags(ofEdge: e).contains(.bikeForward) {
            rideable.insert(f.graph.target(ofEdge: e))
            rideable.insert(f.graph.sourceNode(ofEdge: e))
        }
        let start = try #require(rideable.min())
        for direction in [SearchDirection.forward, .reverse] {
            let tree = try Dijkstra.oneToMany(in: f.graph, sources: [(start, 0)], profile: BikeProfile.eBike, direction: direction)
            #expect(rideable.allSatisfy { tree.cost(of: $0) != nil })
        }
    }

    @Test func dropsSmallComponentsOnlyWhenAsked() throws {
        var options = StreetBuildOptions()
        options.keepLargestComponents = false
        let all = try FixtureStreets.build(options: options)
        #expect(all.node(5, 5) != nil)
        #expect(all.compiled.nodeCount == f.compiled.nodeCount + 1)
    }

    @Test func storesBearingsPerDirection() throws {
        // 1st Street runs due east; B Avenue due north.
        let east = try edge(try node(0, 0), try node(1, 0))
        let (entry, exit) = f.graph.bearings(ofEdge: east)
        #expect(abs(entry - 90) < 1.5 && abs(exit - 90) < 1.5)
        let west = try edge(try node(1, 0), try node(0, 0))
        #expect(abs(f.graph.bearings(ofEdge: west).entry - 270) < 1.5)
        let north = try edge(try node(1, 0), try node(1, 1))
        #expect(f.graph.bearings(ofEdge: north).entry < 1.5 || f.graph.bearings(ofEdge: north).entry > 358.5)
        // The connector turns a corner: west→east along the sidewalk, then north up the crossing.
        let connector = try edge(try node(0, -0.1), try node(1, 0))
        #expect(abs(f.graph.bearings(ofEdge: connector).entry - 90) < 1.5)
        let connectorExit = f.graph.bearings(ofEdge: connector).exit
        #expect(connectorExit < 1.5 || connectorExit > 358.5)
    }

    @Test func storesServiceAreaPolygons() {
        #expect(f.graph.regions.map(\.code) == [1, 5, 3432250, 3436000])
        #expect(f.graph.regions.map(\.name) == ["Manhattan", "Staten Island", "Hoboken", "Jersey City"])
        #expect(f.graph.manhattan.contains(Coordinate(lat: 40.7, lon: -73.998)))
        #expect(!f.graph.manhattan.contains(Coordinate(lat: 40.7047, lon: -73.9915)))
        #expect(f.graph.region(containing: Coordinate(lat: 40.7047, lon: -73.9915))?.name == "Staten Island")
        #expect(f.graph.region(containing: Coordinate(lat: 40.8, lon: -73.9)) == nil)
        #expect(f.graph.fiveBoroughs.polygons.count == 2)
        #expect(!f.graph.fiveBoroughs.contains(Coordinate(lat: 40.71, lon: -74.035)))

        // New Jersey: Jersey City with its hole (New York's islands), and Hoboken; not Bayonne.
        #expect(f.graph.serviceArea.polygons.count == 4)
        #expect(f.graph.region(containing: Coordinate(lat: 40.71, lon: -74.035))?.code == StreetRegion.jerseyCityCode)
        #expect(f.graph.region(containing: Coordinate(lat: 40.72, lon: -74.03))?.code == StreetRegion.hobokenCode)
        #expect(f.graph.region(containing: Coordinate(lat: 40.704, lon: -74.03)) == nil)
        #expect(f.graph.serviceArea.contains(Coordinate(lat: 40.7, lon: -73.998)))
        #expect(!f.graph.serviceArea.contains(Coordinate(lat: 40.69, lon: -74.03))) // the fixture's Bayonne
        #expect(!f.graph.serviceArea.contains(Coordinate(lat: 40.7345, lon: -74.1644))) // Newark Penn
    }

    @Test func keepsTheLargestComponentOfEveryRegion() throws {
        // The Island Loop is far below 5% of the main network, but it is the largest network in
        // a region of its own (as New Jersey's is), so it stays, walkable.
        let square = MultiPolygon([Polygon(exterior: [
            Coordinate(lat: 40.7025, lon: -73.9960), Coordinate(lat: 40.7065, lon: -73.9960),
            Coordinate(lat: 40.7065, lon: -73.9910), Coordinate(lat: 40.7025, lon: -73.9910),
            Coordinate(lat: 40.7025, lon: -73.9960),
        ])])
        let island = try FixtureStreets.build(extraRegions: [StreetRegion(code: 900, name: "Island", area: square)])
        let loop = try #require(island.node(5, 5))
        #expect(island.graph.outgoingEdges(of: loop).contains { island.graph.flags(ofEdge: $0).contains(.walk) })
        #expect(island.stats.keptComponentMeters.count == 2)
        #expect(island.compiled.nodeCount == f.compiled.nodeCount + 1)

        var options = StreetBuildOptions()
        options.keepLargestComponentPerRegion = false
        let shareOnly = try FixtureStreets.build(options: options, extraRegions: [StreetRegion(code: 900, name: "Island", area: square)])
        #expect(shareOnly.node(5, 5) == nil)
    }

    /// walkIslandShare's denominator, the length of every walking component, is summed in key
    /// order, so it does not depend on the order a Dictionary hands the components out in (which
    /// changes from process to process). 1e16 is so large that adding 1 to it is lost while adding
    /// 2 is not, so the same five lengths summed as they come give more than one total; every order
    /// gives the key-order total, bit for bit.
    @Test func walkingComponentLengthsSumTheSameInAnyOrder() {
        let lengths: [(key: Int, value: Double)] = [(4, 1), (1, 1e16), (5, 3), (2, 1), (3, 1)]
        let keyOrder = lengths.sorted { $0.key < $1.key }.reduce(0.0) { $0 + $1.value }
        var asTheyCome = Set<UInt64>()
        for order in permutations(lengths) {
            asTheyCome.insert(order.reduce(0.0) { $0 + $1.value }.bitPattern)
            #expect(LargeComponents.totalMeters(order).bitPattern == keyOrder.bitPattern, "\(order.map(\.key))")
        }
        #expect(asTheyCome.count > 1)   // the lengths are ones whose order shows in the total
        #expect(LargeComponents.totalMeters(Dictionary(uniqueKeysWithValues: lengths.map { ($0.key, $0.value) })).bitPattern == keyOrder.bitPattern)
    }
}

/// The component filter itself, on a network built here rather than from the fixture.
@Suite struct ComponentFilterTests {
    /// walkIslandShare as the filter reports it, not only the helper it should sum with. One
    /// walking piece of 1e16 meters (nodes 0 and 1, so its component's key is the smallest) and
    /// 30 one-meter walking islands, each tied to node 0 by a bike-only piece so the first step
    /// keeps them. Summed in key order the ones are all lost (1e16 + 1 is 1e16), so the share is
    /// exactly 30 / 1e16; summed in the order a Dictionary hands them out, it is not whenever two
    /// ones come first. A Dictionary's order follows its storage address, so each run below comes
    /// after a new allocation of another size: an arrival-order sum fails with high probability.
    @Test func walkIslandShareIsTheKeyOrderSumOnEveryRun() {
        let islands = 30
        let nodes = 2 * (islands + 1)
        var walk = WayRule(), bike = WayRule()
        walk.walk = true
        bike.bikeForward = true
        bike.bikeBackward = true
        var network = PieceNetwork(
            nodeIDs: (0..<Int64(nodes)).map { $0 }, latE7: Array(repeating: 0, count: nodes),
            lonE7: Array(repeating: 0, count: nodes), isVertex: Array(repeating: true, count: nodes),
            rules: [walk, bike], names: [], parks: nil)
        network.addPiece(points: [0, 1], rule: 0, name: -1)
        for island in 1...islands {
            network.addPiece(points: [Int32(2 * island), Int32(2 * island + 1)], rule: 0, name: -1)
            network.addPiece(points: [0, Int32(2 * island)], rule: 1, name: -1)
        }
        network.lengths = [1e16] + Array(repeating: 1, count: network.pieceCount - 1)

        let keyOrder = Array(repeating: 1.0, count: islands).reduce(1e16, +)
        #expect(keyOrder == 1e16)
        #expect([1, 1, 1e16].reduce(0, +) != 1e16)   // the order of these lengths shows in a sum
        let expected = Double(islands) / keyOrder

        var keepAlive: [[Int]] = []
        for run in 0..<20 {
            var copy = network
            var stats = StreetBuildStats()
            copy.restrictToLargestComponents(minimumShare: 0.05, regions: nil, stats: &stats)
            #expect(stats.walkIslandMeters == Double(islands), "run \(run)")
            #expect(stats.walkIslandShare.bitPattern == expected.bitPattern, "run \(run): \(stats.walkIslandShare)")
            keepAlive.append(Array(repeating: run, count: 40 + run))
        }
        #expect(keepAlive.count == 20)
    }
}

/// Every order of `items` (n! of them).
private func permutations<T>(_ items: [T]) -> [[T]] {
    guard let first = items.first else { return [[]] }
    return permutations(Array(items.dropFirst())).flatMap { rest in
        (0...rest.count).map { index in
            var order = rest
            order.insert(first, at: index)
            return order
        }
    }
}
