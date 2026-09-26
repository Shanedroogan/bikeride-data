import BRCore
import BRGeo
import BRStreetCore

enum Fixtures {
    /// A random street network around Union Square. Edge lengths are never shorter than the
    /// straight line between their ends, as with real geometry, so A* heuristics stay admissible.
    static func randomGraph(seed: UInt64, nodeCount: Int = 30, streetCount: Int = 70) -> StreetGraph {
        var rng = SplitMix64(seed: seed)
        var builder = GraphBuilder()
        let coordinates = (0..<nodeCount).map { _ in
            Coordinate(lat: 40.73 + rng.nextUnitDouble() * 0.02, lon: -73.99 + rng.nextUnitDouble() * 0.02)
        }
        for c in coordinates { builder.addNode(at: c) }
        let bikeAccess: [GraphBuilder.BikeAccess] = [.none, .both, .both, .forwardOnly, .backwardOnly]
        for _ in 0..<streetCount {
            let a = rng.nextInt(below: nodeCount)
            var b = rng.nextInt(below: nodeCount - 1)
            if b >= a { b += 1 }
            let straight = coordinates[a].distance(to: coordinates[b])
            let length = UInt32((straight * (1 + rng.nextUnitDouble() * 0.5) * 10).rounded(.up)) + 1
            builder.addStreet(
                between: UInt32(a),
                and: UInt32(b),
                lengthDecimeters: length,
                walkable: rng.nextInt(below: 10) != 0,
                bike: bikeAccess[rng.nextInt(below: bikeAccess.count)],
                bikeClass: BikeClass.allCases[rng.nextInt(below: BikeClass.allCases.count)],
                attributes: rng.nextInt(below: 10) == 0 ? .stairs : []
            )
        }
        return builder.build()
    }

    /// A `side` × `side` grid of two-way streets 100 m apart.
    static func grid(side: Int) -> StreetGraph {
        var builder = GraphBuilder()
        for row in 0..<side {
            for column in 0..<side {
                builder.addNode(at: Coordinate(lat: 40.7 + Double(row) * 0.0009, lon: -74.0 + Double(column) * 0.00119))
            }
        }
        for row in 0..<side {
            for column in 0..<side {
                let node = UInt32(row * side + column)
                if column + 1 < side { builder.addStreet(between: node, and: node + 1, lengthDecimeters: 1000) }
                if row + 1 < side { builder.addStreet(between: node, and: node + UInt32(side), lengthDecimeters: 1000) }
            }
        }
        return builder.build()
    }

    /// All-pairs costs by Floyd–Warshall; `UInt64.max` where unreachable.
    static func allPairsCosts<Profile: CostProfile>(_ graph: StreetGraph, _ profile: Profile) -> [[UInt64]] {
        let n = graph.nodeCount
        var d = [[UInt64]](repeating: [UInt64](repeating: .max, count: n), count: n)
        for i in 0..<n { d[i][i] = 0 }
        for u in 0..<n {
            for edge in graph.outgoingEdges(of: UInt32(u)) {
                guard let cost = profile.costMs(ofEdge: edge, in: graph) else { continue }
                let v = Int(graph.edgeTargets[edge])
                d[u][v] = min(d[u][v], UInt64(cost))
            }
        }
        for k in 0..<n {
            for i in 0..<n where d[i][k] != .max {
                for j in 0..<n where d[k][j] != .max {
                    d[i][j] = min(d[i][j], d[i][k] + d[k][j])
                }
            }
        }
        return d
    }
}
