import BRCore
import BRGeo
import BRStreetCore
import Testing

extension SearchDirection: CustomTestStringConvertible {
    public var testDescription: String { self == .forward ? "forward" : "reverse" }
}

@Suite struct DijkstraTests {
    static let seeds: [UInt64] = Array(1...12)

    /// Checks one search against Floyd–Warshall: exact costs everywhere, bound respected.
    private func verify<Profile: CostProfile>(
        _ graph: StreetGraph, _ profile: Profile, _ allPairs: [[UInt64]],
        sources: [(node: UInt32, initialCostMs: UInt32)], direction: SearchDirection, maxCostMs: UInt32 = StreetCost.maxFinite
    ) throws {
        let tree = try Dijkstra.oneToMany(
            in: graph, sources: sources, profile: profile, maxCostMs: maxCostMs, direction: direction,
            options: [.recordParents, .recordDistances]
        )
        for node in 0..<graph.nodeCount {
            let best = sources.map { source -> UInt64 in
                let leg = direction == .forward ? allPairs[Int(source.node)][node] : allPairs[node][Int(source.node)]
                return leg == .max ? .max : UInt64(source.initialCostMs) + leg
            }.min() ?? .max
            let expected = best <= UInt64(maxCostMs) ? UInt32(best) : ShortestPathTree.unreached
            #expect(tree.costMs[node] == expected, "node \(node)")

            guard let path = tree.path(for: UInt32(node), in: graph) else {
                #expect(expected == ShortestPathTree.unreached)
                continue
            }
            // The tree path is real, costs what the tree says, and its length was tracked.
            let edgeCosts = path.edges.map { UInt64(profile.costMs(ofEdge: Int($0), in: graph)!) }.reduce(0, +)
            let end = direction == .forward ? path.nodes.first! : path.nodes.last!
            let initial = sources.filter { $0.node == end }.map(\.initialCostMs).min()!
            #expect(UInt64(initial) + edgeCosts == UInt64(tree.costMs[node]))
            #expect(path.lengthDecimeters == tree.distanceDecimeters![node])
            for (i, edge) in path.edges.enumerated() {
                #expect(graph.sourceNode(ofEdge: Int(edge)) == path.nodes[i])
                #expect(graph.edgeTargets[Int(edge)] == path.nodes[i + 1])
            }
        }
    }

    @Test(arguments: seeds, [SearchDirection.forward, .reverse])
    func singleSourceMatchesFloydWarshall(seed: UInt64, direction: SearchDirection) throws {
        let graph = Fixtures.randomGraph(seed: seed)
        let walkPairs = Fixtures.allPairsCosts(graph, WalkProfile.standard)
        let bikePairs = Fixtures.allPairsCosts(graph, BikeProfile.eBike)
        for source in [UInt32(0), UInt32(graph.nodeCount / 2)] {
            try verify(graph, WalkProfile.standard, walkPairs, sources: [(source, 0)], direction: direction)
            try verify(graph, BikeProfile.eBike, bikePairs, sources: [(source, 0)], direction: direction)
        }
    }

    @Test(arguments: seeds, [SearchDirection.forward, .reverse])
    func multiSourceHonorsInitialCosts(seed: UInt64, direction: SearchDirection) throws {
        let graph = Fixtures.randomGraph(seed: seed)
        var rng = SplitMix64(seed: seed &+ 1000)
        let sources = (0..<4).map { _ in
            (node: UInt32(rng.nextInt(below: graph.nodeCount)), initialCostMs: UInt32(rng.nextInt(below: 600_000)))
        }
        let duplicated = sources + [(node: sources[0].node, initialCostMs: sources[0].initialCostMs / 2)]
        try verify(graph, WalkProfile.standard, Fixtures.allPairsCosts(graph, WalkProfile.standard), sources: duplicated, direction: direction)
        try verify(graph, BikeProfile.classic, Fixtures.allPairsCosts(graph, BikeProfile.classic), sources: duplicated, direction: direction)
    }

    @Test(arguments: seeds, [SearchDirection.forward, .reverse])
    func respectsMaxCost(seed: UInt64, direction: SearchDirection) throws {
        let graph = Fixtures.randomGraph(seed: seed)
        let pairs = Fixtures.allPairsCosts(graph, WalkProfile.standard)
        let finite = pairs[0].filter { $0 != .max }.sorted()
        let bound = UInt32(finite[finite.count / 2])
        try verify(graph, WalkProfile.standard, pairs, sources: [(0, 0)], direction: direction, maxCostMs: bound)
        try verify(graph, WalkProfile.standard, pairs, sources: [(0, 5_000), (1, 0)], direction: direction, maxCostMs: 4_000)
    }

    @Test func oneWayStreetsAreDirectional() throws {
        var builder = GraphBuilder()
        for i in 0..<2 { builder.addNode(at: Coordinate(lat: 40.7, lon: -74 + Double(i) * 0.001)) }
        builder.addStreet(between: 0, and: 1, lengthDecimeters: 1000, bike: .forwardOnly)
        let graph = builder.build()
        let forward = try Dijkstra.oneToMany(in: graph, sources: [(0, 0)], profile: BikeProfile.eBike)
        let back = try Dijkstra.oneToMany(in: graph, sources: [(1, 0)], profile: BikeProfile.eBike)
        let toOne = try Dijkstra.oneToMany(in: graph, sources: [(1, 0)], profile: BikeProfile.eBike, direction: .reverse)
        #expect(forward.cost(of: 1) == 22_369)
        #expect(back.cost(of: 0) == nil)
        #expect(toOne.cost(of: 0) == 22_369)
        #expect(try Dijkstra.oneToMany(in: graph, sources: [(1, 0)], profile: WalkProfile.standard).cost(of: 0) == 63_912)
    }

    @Test func checksForCancellationEvery10kPops() throws {
        let graph = Fixtures.grid(side: 120) // 14,400 nodes
        var calls = 0
        #expect(throws: CancellationError.self) {
            _ = try Dijkstra.oneToMany(in: graph, sources: [(0, 0)], profile: WalkProfile.standard) {
                calls += 1
                return true
            }
        }
        #expect(calls == 1)

        calls = 0
        let tree = try Dijkstra.oneToMany(in: graph, sources: [(0, 0)], profile: WalkProfile.standard) {
            calls += 1
            return false
        }
        #expect(tree.costMs.allSatisfy { $0 != ShortestPathTree.unreached })
        #expect(calls >= 1 && calls <= 2)
    }
}

@Suite struct AStarTests {
    @Test(arguments: DijkstraTests.seeds)
    func matchesDijkstra(seed: UInt64) throws {
        let graph = Fixtures.randomGraph(seed: seed, nodeCount: 40, streetCount: 100)
        var rng = SplitMix64(seed: seed)
        for _ in 0..<15 {
            let from = UInt32(rng.nextInt(below: graph.nodeCount)), to = UInt32(rng.nextInt(below: graph.nodeCount))
            try compare(graph, WalkProfile.standard, from, to)
            try compare(graph, BikeProfile.eBike, from, to)
        }
    }

    private func compare<Profile: CostProfile>(_ graph: StreetGraph, _ profile: Profile, _ from: UInt32, _ to: UInt32) throws {
        let tree = try Dijkstra.oneToMany(in: graph, sources: [(from, 0)], profile: profile)
        let path = try AStar.shortestPath(in: graph, from: from, to: to, profile: profile)
        guard let expected = tree.cost(of: to) else {
            #expect(path == nil)
            return
        }
        let found = try #require(path)
        #expect(found.costMs == expected)
        #expect(found.nodes.first == from && found.nodes.last == to)
        #expect(found.nodes.count == found.edges.count + 1)
        let edgeCosts = found.edges.map { profile.costMs(ofEdge: Int($0), in: graph)! }.reduce(0, +)
        let edgeLengths = found.edges.map { graph.edgeLengthDecimeters[Int($0)] }.reduce(0, +)
        #expect(edgeCosts == found.costMs)
        #expect(found.lengthDecimeters == edgeLengths)
        for (i, edge) in found.edges.enumerated() {
            #expect(graph.sourceNode(ofEdge: Int(edge)) == found.nodes[i] && graph.edgeTargets[Int(edge)] == found.nodes[i + 1])
        }
        // Bounded searches agree on whether the destination is in range.
        #expect(try AStar.shortestPath(in: graph, from: from, to: to, profile: profile, maxCostMs: expected)?.costMs == expected)
        if expected > 0 {
            #expect(try AStar.shortestPath(in: graph, from: from, to: to, profile: profile, maxCostMs: expected - 1) == nil)
        }
    }

    @Test func tracksTrueDistanceSeparatelyFromCost() throws {
        // Two routes 0 → 3: a short arterial (cheap in meters, pricey per meter) and a longer
        // protected lane that wins on cost.
        var builder = GraphBuilder()
        for (lat, lon) in [(40.70, -74.000), (40.70, -73.995), (40.703, -73.995), (40.70, -73.990)] {
            builder.addNode(at: Coordinate(lat: lat, lon: lon))
        }
        builder.addStreet(between: 0, and: 1, lengthDecimeters: 4300, bikeClass: .arterial)
        builder.addStreet(between: 1, and: 3, lengthDecimeters: 4300, bikeClass: .arterial)
        builder.addStreet(between: 0, and: 2, lengthDecimeters: 6000, bikeClass: .protected)
        builder.addStreet(between: 2, and: 3, lengthDecimeters: 6000, bikeClass: .protected)
        let graph = builder.build()
        let path = try #require(try AStar.shortestPath(in: graph, from: 0, to: 3, profile: BikeProfile.eBike))
        #expect(path.nodes == [0, 2, 3])
        #expect(path.lengthDecimeters == 12_000)
        #expect(path.lengthMeters == 1200)
        #expect(path.costMs == 2 * BikeProfile.eBike.costMs(lengthDecimeters: 6000, flags: .bikeForward, bikeClass: .protected)!)
    }

    @Test func trivialAndUnreachableQueries() throws {
        let graph = Fixtures.grid(side: 3)
        let same = try #require(try AStar.shortestPath(in: graph, from: 4, to: 4, profile: WalkProfile.standard))
        #expect(same.nodes == [4] && same.edges.isEmpty && same.costMs == 0)
        #expect(try AStar.shortestPath(in: graph, from: 0, to: 8, profile: BikeProfile.eBike)?.edges.count == 4)

        var builder = GraphBuilder()
        builder.addNode(at: Coordinate(lat: 40.7, lon: -74))
        builder.addNode(at: Coordinate(lat: 40.71, lon: -74))
        #expect(try AStar.shortestPath(in: builder.build(), from: 0, to: 1, profile: WalkProfile.standard) == nil)
    }

    @Test func honorsCancellation() {
        let graph = Fixtures.grid(side: 120)
        #expect(throws: CancellationError.self) {
            _ = try AStar.shortestPath(in: graph, from: 0, to: UInt32(graph.nodeCount - 1), profile: WalkProfile.standard,
                                       heuristicFactor: 0) { true }
        }
    }
}
