import BRCore
import BRGeo
import Testing

@Suite struct GridIndexTests {
    let projection = LocalProjection(origin: Coordinate(lat: 40.73, lon: -73.99))

    private func randomPoints(seed: UInt64, count: Int) -> [Coordinate] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { _ in
            Coordinate(lat: 40.70 + rng.nextUnitDouble() * 0.06, lon: -74.02 + rng.nextUnitDouble() * 0.06)
        }
    }

    private func index(_ points: [Coordinate], cellSize: Double) -> GridIndex<Int> {
        var grid = GridIndex<Int>(cellSizeMeters: cellSize, projection: projection)
        for (id, point) in points.enumerated() { grid.insert(id, at: point) }
        return grid
    }

    /// Brute force with the same metric and tie-break (distance, then insertion order).
    private func bruteForce(_ points: [Coordinate], from query: Coordinate) -> [(id: Int, distance: Double)] {
        let q = projection.project(query)
        return points.enumerated()
            .map { (id: $0.offset, distance: projection.project($0.element).distance(to: q)) }
            .sorted { ($0.distance, $0.id) < ($1.distance, $1.id) }
    }

    @Test(arguments: [50.0, 250.0, 2000.0])
    func nearestMatchesBruteForce(cellSize: Double) {
        let points = randomPoints(seed: 7, count: 400)
        let grid = index(points, cellSize: cellSize)
        for query in randomPoints(seed: 8, count: 40) + [Coordinate(lat: 41.5, lon: -73.0)] {
            let expected = bruteForce(points, from: query)
            for k in [1, 3, 10, 50] {
                let hits = grid.nearest(to: query, k: k)
                #expect(hits.map(\.id) == expected.prefix(k).map(\.id))
                #expect(zip(hits, expected).allSatisfy { abs($0.distance - $1.distance) < 1e-9 })
            }
        }
    }

    @Test(arguments: [100.0, 400.0])
    func withinMatchesBruteForce(cellSize: Double) {
        let points = randomPoints(seed: 11, count: 400)
        let grid = index(points, cellSize: cellSize)
        for query in randomPoints(seed: 12, count: 40) {
            for radius in [0.0, 150.0, 350.0, 1200.0] {
                let expected = bruteForce(points, from: query).filter { $0.distance <= radius }
                #expect(grid.within(radiusMeters: radius, of: query).map(\.id) == expected.map(\.id))
            }
        }
    }

    @Test func edgeCases() {
        var grid = GridIndex<String>(cellSizeMeters: 100, projection: projection)
        let here = Coordinate(lat: 40.73, lon: -73.99)
        #expect(grid.nearest(to: here, k: 3).isEmpty)
        #expect(grid.within(radiusMeters: 1000, of: here).isEmpty)

        grid.insert("a", at: here)
        grid.insert("b", at: here)
        grid.insert("c", at: Coordinate(lat: 40.74, lon: -73.99))
        #expect(grid.count == 3)
        #expect(grid.nearest(to: here, k: 0).isEmpty)
        #expect(grid.nearest(to: here, k: 10).map(\.id) == ["a", "b", "c"])
        #expect(grid.within(radiusMeters: 0, of: here).map(\.id) == ["a", "b"])
        #expect(grid.nearest(to: Coordinate(lat: -33.87, lon: 151.21), k: 1).map(\.id) == ["a"])
    }

    @Test func farQueriesOnFineGridsSkipEmptyRings() {
        let points = randomPoints(seed: 5, count: 50)
        let grid = index(points, cellSize: 1) // query is ~19 million empty rings away
        let sydney = Coordinate(lat: -33.87, lon: 151.21)
        #expect(grid.nearest(to: sydney, k: 3).map(\.id) == bruteForce(points, from: sydney).prefix(3).map(\.id))
        #expect(grid.within(radiusMeters: 3e7, of: sydney).map(\.id) == bruteForce(points, from: sydney).map(\.id))
        let midtown = Coordinate(lat: 40.73, lon: -73.99)
        let expected = bruteForce(points, from: midtown).filter { $0.distance <= 2500 }.map(\.id)
        #expect(grid.within(radiusMeters: 2500, of: midtown).map(\.id) == expected)
    }
}
