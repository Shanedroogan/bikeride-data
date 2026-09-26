@testable import BRBuild
import BRCore
import BRGeo
import BRStreetCore
import Foundation
import Testing

@Suite struct StreetSnappingTests {
    let f: FixtureStreets

    init() throws {
        f = try FixtureStreets.build()
    }

    private func node(_ x: Double, _ y: Double) throws -> UInt32 {
        try #require(f.node(x, y), "no graph node at (\(x), \(y))")
    }

    private func name(_ point: SnappedPoint) -> String {
        f.graph.name(id: f.graph.nameID(ofSegment: point.segment))
    }

    /// The exact nearest usable segment, by projecting onto every stored polyline.
    private func bruteForceNearest(_ query: Coordinate, usable: (EdgeFlags) -> Bool) -> (segment: UInt32, distance: Double)? {
        let projection = LocalProjection(origin: query)
        var best: (segment: UInt32, distance: Double)?
        for s in 0..<UInt32(f.graph.segmentCount) {
            let (forward, backward) = f.graph.edges(ofSegment: s)
            guard [forward, backward].compactMap({ $0 }).contains(where: { usable(f.graph.flags(ofEdge: Int($0))) }) else { continue }
            let points = f.graph.shape(ofSegment: s).map(projection.project)
            let distance = zip(points, points.dropFirst())
                .map { PlanarPoint(x: 0, y: 0).projection(ontoSegmentFrom: $0.0, to: $0.1).distance }
                .min()!
            if distance < best?.distance ?? .infinity { best = (s, distance) }
        }
        return best
    }

    @Test func snapsToTheNearestSegmentWithFractionAndDistance() throws {
        // 4.4 m north of 1st Street, halfway between (0, 0) and (1, 0).
        let query = Coordinate(lat: 40.70004, lon: -73.9994)
        let hit = try #require(f.graph.snap(query))
        #expect(name(hit) == "1st Street")
        let (west, east) = (try node(0, 0), try node(1, 0))
        #expect(Set([hit.nodeA, hit.nodeB]) == [west, east])
        let fromWest = hit.nodeA == west ? hit.fraction : 1 - hit.fraction
        #expect(abs(fromWest - 0.5) < 0.005)
        #expect(abs(hit.distanceMeters - 4.448) < 0.01)
        #expect(abs(hit.coordinate.lat - 40.7) < 1e-7 && abs(hit.coordinate.lon - -73.9994) < 1e-7)
        #expect(hit.query == query)
        #expect(hit.forwardEdge != nil && hit.backwardEdge != nil)
        #expect(hit.edge == hit.forwardEdge)
        #expect(f.graph.segment(ofEdge: Int(hit.edge)).segment == hit.segment)
    }

    @Test func snapModesSkipSegmentsTheModeCannotUse() throws {
        // Right on the steps: walking snaps onto them, riding cannot.
        let query = StreetsFixtures.coordinate(2.15, 2.15)
        let walk = try #require(f.graph.snap(query, mode: .walk))
        #expect(name(walk) == "steps")
        #expect(walk.distanceMeters < 0.5)
        let bike = try #require(f.graph.snap(query, mode: .bike))
        #expect(name(bike) != "steps")
        #expect(bike.distanceMeters > 10)
        #expect(f.graph.snap(query, profile: BikeProfile.eBike)?.segment == bike.segment)
        #expect(f.graph.snap(query, profile: WalkProfile.standard)?.segment == walk.segment)
        #expect(f.graph.snap(query, mode: .any)?.segment == walk.segment)
        // Nothing usable in range.
        #expect(f.graph.snap(Coordinate(lat: 40.75, lon: -74)) == nil)
        #expect(f.graph.snap(query, mode: .bike, maxDistanceMeters: bike.distanceMeters - 0.1) == nil)
    }

    @Test func candidatesAreDistinctAndNearestFirst() {
        let query = StreetsFixtures.coordinate(0.4, 0.45)
        let candidates = f.graph.snapCandidates(query, mode: .any, limit: 5)
        #expect(candidates.count == 5)
        #expect(Set(candidates.map(\.segment)).count == 5)
        #expect(zip(candidates, candidates.dropFirst()).allSatisfy { $0.0.distanceMeters <= $0.1.distanceMeters })
        #expect(candidates.first?.segment == f.graph.snap(query, mode: .any)?.segment)
    }

    /// The grid search finds the true nearest segment, for points all over and around the fixture.
    @Test(arguments: [SnapMode.walk, .bike, .any])
    func gridSearchMatchesBruteForce(mode: SnapMode) {
        var rng = SplitMix64(seed: 42)
        let usable: (EdgeFlags) -> Bool = switch mode {
        case .walk: { $0.contains(.walk) }
        case .bike: { $0.contains(.bikeForward) }
        case .any: { _ in true }
        }
        for _ in 0..<400 {
            let query = StreetsFixtures.coordinate(-1.5 + rng.nextUnitDouble() * 7, -1.5 + rng.nextUnitDouble() * 6)
            let expected = bruteForceNearest(query, usable: usable)
            let found = f.graph.snap(query, mode: mode, maxDistanceMeters: 1000)
            #expect(found != nil)
            guard let found, let expected else { continue }
            #expect(abs(found.distanceMeters - expected.distance) < 1e-6, "query \(query)")
        }
    }

    @Test func searchSourcesSplitTheEdgeCostAtThePoint() throws {
        let profile = WalkProfile.standard
        let hit = try #require(f.graph.snap(Coordinate(lat: 40.70004, lon: -73.9996)))
        let forwardEdge = try #require(hit.forwardEdge), backwardEdge = try #require(hit.backwardEdge)
        let forwardCost = try #require(profile.costMs(ofEdge: Int(forwardEdge), inNetwork: f.graph))
        let backwardCost = try #require(profile.costMs(ofEdge: Int(backwardEdge), inNetwork: f.graph))
        func expectCost(_ actual: UInt32, _ cost: UInt32, _ share: Double) {
            #expect(actual == UInt32((Double(cost) * share).rounded()))
        }

        // From the point: along A→B to B, or along B→A to A.
        let out = hit.searchSources(in: f.graph, profile: profile, direction: .forward)
        #expect(out.map(\.node) == [hit.nodeB, hit.nodeA])
        expectCost(out[0].initialCostMs, forwardCost, 1 - hit.fraction)
        expectCost(out[1].initialCostMs, backwardCost, hit.fraction)

        // Toward the point: from A along A→B, or from B along B→A. Extra cost is added to each.
        let into = hit.searchSources(in: f.graph, profile: profile, direction: .reverse, extraCostMs: 1000)
        #expect(into.map(\.node) == [hit.nodeA, hit.nodeB])
        expectCost(into[0].initialCostMs - 1000, forwardCost, hit.fraction)
        expectCost(into[1].initialCostMs - 1000, backwardCost, 1 - hit.fraction)

        // A one-way leaves a bike only one way out: C Avenue runs south.
        let oneWay = try #require(f.graph.snap(StreetsFixtures.coordinate(2.02, 1.5), mode: .bike))
        #expect(name(oneWay) == "C Avenue")
        let sources = oneWay.searchSources(in: f.graph, profile: BikeProfile.eBike, direction: .forward)
        #expect(sources.count == 1)
        let junction = try node(2, 1)
        #expect(sources.first?.node == junction)
    }

    /// A tree from a coordinate equals the cheapest of its two seeded sources, node by node, and
    /// arrivals at a snapped point add the right partial edge and length.
    @Test(arguments: [SearchDirection.forward, .reverse])
    func treeFromACoordinateMatchesItsSeeds(direction: SearchDirection) throws {
        let profile = BikeProfile.classic
        let origin = StreetsFixtures.coordinate(0.3, 1.02) // on 2nd Street
        let (snapped, tree) = try #require(try f.graph.shortestPathTree(
            from: origin, profile: profile, direction: direction, options: [.recordDistances]
        ))
        #expect(name(snapped) == "2nd Street")
        let seeds = snapped.searchSources(in: f.graph, profile: profile, direction: direction)
        #expect(seeds.count == 2)
        let perSeed = try seeds.map { seed in
            try Dijkstra.oneToMany(in: f.graph, sources: [(seed.node, 0)], profile: profile, direction: direction)
        }
        for node in 0..<UInt32(f.graph.nodeCount) {
            let expected = zip(seeds, perSeed).compactMap { seed, t in t.cost(of: node).map { UInt64($0) + UInt64(seed.initialCostMs) } }.min()
            #expect(tree.cost(of: node).map(UInt64.init) == expected, "node \(node)")
        }

        // Arrival at a point on Café Street, which is not the origin's segment.
        let destination = try #require(f.graph.snap(StreetsFixtures.coordinate(1.25, 3.01), profile: profile))
        #expect(name(destination) == "Café Street")
        let arrival = try #require(tree.arrival(at: destination, in: f.graph, profile: profile))
        #expect(tree.cost(to: destination, in: f.graph, profile: profile) == arrival.costMs)
        let partial = destination.searchSources(in: f.graph, profile: profile, direction: direction == .forward ? .reverse : .forward)
        let best = partial.compactMap { p in tree.cost(of: p.node).map { $0 + p.initialCostMs } }.min()
        #expect(arrival.costMs == best)
        let length = try #require(arrival.lengthMeters)
        if direction == .forward {
            // The same trip as a point-to-point route.
            let route = try #require(try f.graph.route(from: snapped, to: destination, profile: profile))
            #expect(route.costMs == arrival.costMs)
            #expect(abs(route.lengthMeters - length) < 0.2)
        }
        #expect(length > snapped.coordinate.distance(to: destination.coordinate))
    }

    @Test func routesBetweenCoordinates() throws {
        let walk = WalkProfile.standard
        // From 1st Street up to the far end of the Overlook Path: the only way is the steps.
        let start = try #require(f.graph.snap(Coordinate(lat: 40.70004, lon: -73.9994), profile: walk))
        let end = try #require(f.graph.snap(StreetsFixtures.coordinate(2.6, 2.6), profile: walk))
        let route = try #require(try f.graph.route(from: start, to: end, profile: walk))
        let names = route.edges.map { f.graph.name(ofEdge: Int($0)) }
        #expect(names.first == "1st Street")
        #expect(names.contains("steps"))
        #expect(names.last == "Overlook Path")
        #expect(route.nodes.first == start.nodeB || route.nodes.first == start.nodeA)
        // Its geometry starts and ends at the snapped points and is as long as the route says.
        let shape = f.graph.shape(of: route)
        #expect(shape.first == start.coordinate)
        #expect(abs(shape.last!.lat - end.coordinate.lat) < 1e-7 && abs(shape.last!.lon - end.coordinate.lon) < 1e-7)
        let shapeMeters = zip(shape, shape.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        #expect(abs(shapeMeters - route.lengthMeters) < 0.5)

        // Two points on one segment: straight along it.
        let a = try #require(f.graph.snap(Coordinate(lat: 40.70002, lon: -73.9998), profile: walk))
        let b = try #require(f.graph.snap(Coordinate(lat: 40.70002, lon: -73.9991), profile: walk))
        #expect(a.segment == b.segment)
        let direct = try #require(try f.graph.route(from: a, to: b, profile: walk))
        #expect(direct.edges.count == 1 && direct.nodes.isEmpty)
        #expect(abs(direct.lengthMeters - a.coordinate.distance(to: b.coordinate)) < 0.1)
        #expect(f.graph.shape(of: direct).count == 2)

        // Riding north along one-way C Avenue is a detour; walking it is not.
        let south = StreetsFixtures.coordinate(2, 1.2), north = StreetsFixtures.coordinate(2, 1.8)
        let bike = BikeProfile.eBike
        let (rideFrom, rideTo) = (try #require(f.graph.snap(south, profile: bike)), try #require(f.graph.snap(north, profile: bike)))
        let (walkFrom, walkTo) = (try #require(f.graph.snap(south, profile: walk)), try #require(f.graph.snap(north, profile: walk)))
        let ride = try #require(try f.graph.route(from: rideFrom, to: rideTo, profile: bike))
        let stroll = try #require(try f.graph.route(from: walkFrom, to: walkTo, profile: walk))
        #expect(stroll.edges.count == 1 && abs(stroll.lengthMeters - 60) < 1)
        #expect(ride.lengthMeters > 250)
        #expect(ride.edges.allSatisfy { f.graph.flags(ofEdge: Int($0)).contains(.bikeForward) })

        // Bounded: nothing within 1 s.
        #expect(try f.graph.route(from: start, to: end, profile: walk, maxCostMs: 1000) == nil)
    }
}

extension SnapMode: CustomTestStringConvertible {
    public var testDescription: String {
        switch self {
        case .walk: "walk"
        case .bike: "bike"
        case .any: "any"
        }
    }
}
