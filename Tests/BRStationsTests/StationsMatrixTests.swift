@testable import BRBuild
import BRCore
import BRGeo
import BRStreetCore
import Foundation
import Testing

/// A small city with an arterial street, a protected-track street beside it, a one-way street,
/// a disconnected island and a station nowhere near any street.
struct MatrixCity {
    let city: SyntheticCity.Built
    let stations: [CompiledStation]

    static let names = ["A", "B", "C", "D", "E", "F", "G", "H"]

    init() throws {
        var ways: [SyntheticCity.Way] = []
        let xs = (0...8).map(Double.init)
        ways.append(.init(tags: [("highway", "secondary"), ("name", "Arterial")], points: xs.map { ($0, 0) }))
        ways.append(.init(tags: [("highway", "residential"), ("name", "Track"), ("cycleway", "track")], points: xs.map { ($0, 1) }))
        ways.append(.init(tags: [("highway", "residential"), ("name", "OneWay"), ("oneway", "yes")], points: xs.map { ($0, 2) }))
        for x in xs {
            ways.append(.init(tags: [("highway", "residential"), ("name", "Avenue\(Int(x))")], points: [(x, 0), (x, 1), (x, 2)]))
        }
        ways.append(.init(tags: [("highway", "residential"), ("name", "Island")], points: [(20, 10), (21, 10)]))
        city = try SyntheticCity.build(ways, columns: 45, rows: 45)

        // A, B on the arterial; C, D, G, H on the one-way (G and H share a segment); E on the
        // island; F far from every street.
        let places: [(Double, Double)] = [(1, -0.05), (7, -0.05), (2, 2.05), (6, 2.05), (20.5, 10.05), (40, 40), (3.2, 2.05), (3.7, 2.05)]
        var stations = zip(Self.names, places).map { name, place -> CompiledStation in
            let c = SyntheticCity.coordinate(place.0, place.1)
            return CompiledStation(id: name, name: name, shortName: name, regionID: "71", latE6: StreetsFormat.microdegrees(c.lat),
                                   lonE6: StreetsFormat.microdegrees(c.lon), capacity: 10)
        }
        _ = StationsBuilder.snap(&stations, graph: city.graph, bikeProfile: .eBike)
        self.stations = stations
    }

    func index(_ name: String) -> Int { stations.firstIndex { $0.id == name }! }

    /// The matrix entry computed independently; see ``MatrixCityReference``.
    func reference(_ i: Int, _ j: Int, profile: BikeProfile = .eBike) throws -> UInt16 {
        try MatrixCityReference(graph: city.graph, stations: stations).value(i, j, profile: profile)
    }
}

@Suite struct StationsMatrixTests {
    let fixture: MatrixCity

    init() throws {
        fixture = try MatrixCity()
    }

    @Test func snapsToTheBikeAndWalkGraphs() {
        let s = fixture.stations
        for name in ["A", "B", "C", "D", "E", "G", "H"] {
            let station = s[fixture.index(name)]
            #expect(station.flags.contains(.bikeSnapped) && station.flags.contains(.walkSnapped), "\(name)")
            #expect(station.bikeSnap!.distanceMeters < 7, "\(name)")
        }
        let f = s[fixture.index("F")]
        #expect(f.bikeSnap == nil && f.walkSnap == nil && !f.flags.contains(.bikeSnapped))
        let g = s[fixture.index("G")].bikeSnap!, h = s[fixture.index("H")].bikeSnap!
        #expect(g.segment == h.segment)
    }

    @Test func matchesAnIndependentSearchForEveryPair() throws {
        let (matrix, stats) = StationsBuilder.matrix(for: fixture.stations, graph: fixture.city.graph, profile: .eBike, threads: 3)
        let n = fixture.stations.count
        for i in 0..<n {
            for j in 0..<n {
                let expected = try fixture.reference(i, j)
                #expect(matrix[i * n + j] == expected, "\(MatrixCity.names[i]) → \(MatrixCity.names[j])")
            }
        }
        #expect(stats.stations == n && stats.pairs == n * (n - 1))
        #expect(stats.reachablePairs == matrix.enumerated().filter { $0.offset % (n + 1) != 0 && $0.element != StationsFormat.unreachable }.count)
        #expect(stats.reachablePairs + stats.unreachablePairs == stats.pairs)
        #expect(stats.sameSegmentPairs >= 1)
    }

    @Test func storesTheTrueLengthOfTheCheapestPathNotTheShortest() {
        let (matrix, _) = StationsBuilder.matrix(for: fixture.stations, graph: fixture.city.graph, profile: .eBike, threads: 1)
        let n = fixture.stations.count, a = fixture.index("A"), b = fixture.index("B")
        // About 600 m straight along the arterial costs 1.3 × 607 = 789 m-equivalents; the 807 m
        // detour over the protected track costs 100 + 0.8 × 607 + 100 = 686, so the matrix holds
        // the detour's length (plus two 5 m snap legs), about 820 m.
        let meters = Double(matrix[a * n + b]) * 10
        #expect(meters >= 810 && meters <= 830)
        // With every class weighted alike the straight 600 m wins.
        let flat = BikeProfile(speedMetersPerSecond: BikeProfile.eBike.speedMetersPerSecond,
                               multipliers: BikeClassMultipliers(protected: 1, painted: 1, shared: 1, arterial: 1))
        let (plain, _) = StationsBuilder.matrix(for: fixture.stations, graph: fixture.city.graph, profile: flat, threads: 1)
        // Six 101 m edges plus two 5 m snap legs.
        #expect(Double(plain[a * n + b]) * 10 >= 610 && Double(plain[a * n + b]) * 10 <= 620)
    }

    @Test func followsOneWaysAndMarksUnreachablePairs() {
        let (matrix, stats) = StationsBuilder.matrix(for: fixture.stations, graph: fixture.city.graph, profile: .eBike, threads: 2)
        let n = fixture.stations.count
        func at(_ from: String, _ to: String) -> UInt16 { matrix[fixture.index(from) * n + fixture.index(to)] }
        #expect(at("C", "D") < at("D", "C"))          // east with the one-way; back around the block
        #expect(Double(at("C", "D")) * 10 > 395 && Double(at("C", "D")) * 10 < 415)
        #expect(at("G", "H") < 8 && at("H", "G") > 20) // 50 m along the shared one-way segment
        for other in ["A", "B", "C", "D", "G", "H"] {
            #expect(at("E", other) == StationsFormat.unreachable && at(other, "E") == StationsFormat.unreachable)
            #expect(at("F", other) == StationsFormat.unreachable && at(other, "F") == StationsFormat.unreachable)
        }
        #expect(at("E", "E") == 0 && at("F", "F") == 0)
        #expect(stats.isolatedOrigins == 2) // E reaches nothing else; F never snapped
    }

    @Test func isIdenticalOnAnyNumberOfThreads() {
        let one = StationsBuilder.matrix(for: fixture.stations, graph: fixture.city.graph, profile: .eBike, threads: 1)
        let many = StationsBuilder.matrix(for: fixture.stations, graph: fixture.city.graph, profile: .eBike, threads: 5)
        #expect(one.matrix == many.matrix)
        #expect(one.stats.reachablePairs == many.stats.reachablePairs)
        // The report's figures too, the mean to the last bit (only the thread count differs).
        var oneStats = one.stats
        oneStats.threads = many.stats.threads
        #expect(oneStats == many.stats)
        #expect(one.stats.meanKilometers.bitPattern == many.stats.meanKilometers.bitPattern)
    }

    /// The workers hand their rows in as they finish, in any order; the rows are added in row
    /// order, so meanKilometers is the same to the last bit whatever the order. 1e16 is so large
    /// that adding 1 to it is lost while adding 2 is not, so these row sums added as they come give
    /// more than one total.
    @Test func rowFiguresAddUpTheSameInAnyOrder() {
        let rows: [StationsBuilder.MatrixRow] = [
            (row: 0, reachable: 2, sameSegment: 0, maxDecameters: 40, sumMeters: 1),
            (row: 1, reachable: 3, sameSegment: 1, maxDecameters: 900, sumMeters: 1e16),
            (row: 2, reachable: 0, sameSegment: 0, maxDecameters: 0, sumMeters: 0),
            (row: 3, reachable: 1, sameSegment: 0, maxDecameters: 12, sumMeters: 1),
            (row: 4, reachable: 4, sameSegment: 2, maxDecameters: 75, sumMeters: 3),
            (row: 5, reachable: 2, sameSegment: 0, maxDecameters: 30, sumMeters: 1),
        ]
        var expected = StationMatrixStats()
        expected.reachablePairs = 12
        expected.sameSegmentPairs = 3
        expected.maxDecameters = 900
        expected.isolatedOrigins = 1
        expected.meanKilometers = rows.reduce(0.0) { $0 + $1.sumMeters } / 12 / 1000   // in row order

        var asTheyCome = Set<UInt64>()
        for order in permutations(rows) {
            asTheyCome.insert(order.reduce(0.0) { $0 + $1.sumMeters }.bitPattern)
            var stats = StationMatrixStats()
            StationsBuilder.add(order, to: &stats)
            #expect(stats == expected && stats.meanKilometers.bitPattern == expected.meanKilometers.bitPattern, "\(order.map(\.row))")
        }
        #expect(asTheyCome.count > 1)   // the row sums are ones whose order shows in the total
    }

    @Test func largerRandomCityAgreesWithTheReference() throws {
        // A 12 × 12 grid with a few one-ways and classes, and 30 stations at random offsets.
        var rng = SplitMix64(seed: 99)
        var ways: [SyntheticCity.Way] = []
        for y in 0..<12 {
            var tags: [(String, String)] = [("highway", y % 4 == 0 ? "secondary" : "residential"), ("name", "S\(y)")]
            if y % 3 == 1 { tags.append(("oneway", "yes")) }
            if y % 5 == 2 { tags.append(("cycleway", "lane")) }
            ways.append(.init(tags: tags, points: (0..<12).map { (Double($0), Double(y)) }))
        }
        for x in 0..<12 {
            var tags: [(String, String)] = [("highway", "residential"), ("name", "A\(x)")]
            if x % 4 == 3 { tags.append(("oneway", "-1")) }
            ways.append(.init(tags: tags, points: (0..<12).map { (Double(x), Double($0)) }))
        }
        let city = try SyntheticCity.build(ways, columns: 12, rows: 12)
        var stations = (0..<30).map { i -> CompiledStation in
            let c = SyntheticCity.coordinate(rng.nextUnitDouble() * 11, rng.nextUnitDouble() * 11)
            return CompiledStation(id: "s\(i)", name: "", shortName: "", regionID: "71",
                                   latE6: StreetsFormat.microdegrees(c.lat), lonE6: StreetsFormat.microdegrees(c.lon), capacity: 5)
        }
        _ = StationsBuilder.snap(&stations, graph: city.graph, bikeProfile: .classic)
        let (matrix, _) = StationsBuilder.matrix(for: stations, graph: city.graph, profile: .classic, threads: 4)
        let reference = MatrixCityReference(graph: city.graph, stations: stations)
        for i in 0..<30 {
            for j in 0..<30 {
                let expected = try reference.value(i, j, profile: .classic)
                #expect(matrix[i * 30 + j] == expected, "\(i) → \(j)")
            }
        }
    }
}

/// A matrix entry computed independently with BRStreetCore's own search: `Dijkstra` seeded from
/// the stored snap, `arrival(at:)`, and a direct run along a shared segment, plus both snap legs.
struct MatrixCityReference {
    let graph: MappedStreetGraph
    let stations: [CompiledStation]

    func value(_ i: Int, _ j: Int, profile: BikeProfile) throws -> UInt16 {
        if i == j { return 0 }
        guard let a = stations[i].bikeSnap?.point(in: graph, query: stations[i].coordinate),
              let b = stations[j].bikeSnap?.point(in: graph, query: stations[j].coordinate)
        else { return StationsFormat.unreachable }
        let tree = try Dijkstra.oneToMany(in: graph, from: a, profile: profile, options: [.recordDistances])
        var best: (cost: UInt32, meters: Double)? = tree.arrival(at: b, in: graph, profile: profile).map { ($0.costMs, $0.lengthMeters!) }
        if let direct = a.directCostMs(to: b, in: graph, profile: profile), direct <= best?.cost ?? .max {
            let edge = b.fraction >= a.fraction ? a.forwardEdge! : a.backwardEdge!
            best = (direct, Double(graph.lengthDecimeters(ofEdge: Int(edge))) / 10 * abs(b.fraction - a.fraction))
        }
        guard let best else { return StationsFormat.unreachable }
        return UInt16(((a.distanceMeters + best.meters + b.distanceMeters) / 10).rounded())
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
