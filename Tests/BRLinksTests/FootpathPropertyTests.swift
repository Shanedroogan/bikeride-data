import BRBuild
import BRCore
import BRStreetCore
import BRTimetable
import Foundation
import Testing

@Suite struct FootpathPropertyTests {
    static let seeds: [UInt64] = Array(1...40)

    @Test(arguments: seeds)
    func footpathsEqualTheirDefinition(seed: UInt64) {
        let world = RandomLinkWorld(seed: seed)
        let (table, stats) = LinksBuilder.footpaths(network: world.network, graph: world.graph, options: world.options)
        let expected = LinksReference(network: world.network, graph: world.graph, options: world.options).footpaths()
        let actual = table.rows(world.network.stopCount)
        for stop in 0..<world.network.stopCount {
            #expect(actual[stop].map(\.stop) == expected[stop].map(\.stop), "seed \(seed) stop \(stop)")
            #expect(actual[stop].map(\.seconds) == expected[stop].map(\.seconds), "seed \(seed) stop \(stop)")
        }
        #expect(stats.footpaths == table.count && stats.sources == world.network.routable.filter { $0 }.count)
    }

    /// The property the planner relies on: footpaths are a metric within their bounds, so RAPTOR
    /// never needs to chain two of them.
    @Test(arguments: seeds)
    func footpathsObeyTheTriangleInequalityAndAreClosed(seed: UInt64) {
        let world = RandomLinkWorld(seed: seed)
        let (table, _) = LinksBuilder.footpaths(network: world.network, graph: world.graph, options: world.options)
        let access = LinksBuilder.stopAccessSeconds(world.network, world.options)
        let check = FootpathCheck.run(table, walkSeconds: Int(world.options.maxFootpathWalkSeconds), stopAccessSeconds: access)
        #expect(check.passed, "seed \(seed): \(check.examples)")

        // The same, spelled out over every triple.
        let rows = table.rows(world.network.stopCount)
        for p in rows.indices {
            let direct = Dictionary(uniqueKeysWithValues: rows[p].map { ($0.stop, $0.seconds) })
            for (q, pq) in rows[p] {
                #expect(q != p)
                for (r, qr) in rows[q] where r != p {
                    if let pr = direct[r] {
                        #expect(pr <= pq + qr, "seed \(seed): \(p)→\(r) \(pr) > \(p)→\(q)→\(r) \(pq + qr)")
                    } else {
                        let bound = Int(world.options.maxFootpathWalkSeconds + access[p] + access[r])
                        #expect(pq + qr > bound, "seed \(seed): \(p)→\(q)→\(r) fits \(bound) s but \(p)→\(r) is missing")
                    }
                }
            }
        }
    }

    @Test(arguments: [UInt64(3), 11, 29])
    func resultsDoNotDependOnThreads(seed: UInt64) {
        let world = RandomLinkWorld(seed: seed)
        var one = world.options, many = world.options
        one.threads = 1
        many.threads = 6
        let a = LinksBuilder.build(network: world.network, stationAnchors: world.stations, graph: world.graph, options: one)
        let b = LinksBuilder.build(network: world.network, stationAnchors: world.stations, graph: world.graph, options: many)
        #expect(a.footpaths == b.footpaths)
        #expect(a.stationLinks == b.stationLinks)
    }

    @Test(arguments: seeds)
    func stationLinksEqualTheirDefinition(seed: UInt64) {
        let world = RandomLinkWorld(seed: seed)
        let compiled = LinksBuilder.build(network: world.network, stationAnchors: world.stations, graph: world.graph, options: world.options)
        let expected = LinksReference(network: world.network, graph: world.graph, options: world.options).stationLinks(world.stations)
        let table = compiled.stationLinks
        func seconds(_ value: UInt16) -> Int? { value == LinksFormat.noSeconds ? nil : Int(value) }
        for station in world.stations.indices {
            let range = Int(table.stationStart[station])..<Int(table.stationStart[station + 1])
            var actual: [Int: (enter: Int?, exit: Int?)] = [:]
            for slot in range { actual[Int(table.stationStop[slot])] = (seconds(table.stationEnter[slot]), seconds(table.stationExit[slot])) }
            #expect(Set(actual.keys) == Set(expected[station].keys), "seed \(seed) station \(station)")
            for (stop, value) in expected[station] {
                #expect(actual[stop]?.enter == value.enter && actual[stop]?.exit == value.exit, "seed \(seed) station \(station) stop \(stop)")
            }
            // Sorted by (enter, stop), with enter-less links last.
            let keys = range.map { (table.stationEnter[$0], table.stationStop[$0]) }
            #expect(zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 })
        }
        // The stop → station index lists the same links.
        var forward = Set<[Int]>(), backward = Set<[Int]>()
        for station in world.stations.indices {
            for slot in Int(table.stationStart[station])..<Int(table.stationStart[station + 1]) {
                forward.insert([station, Int(table.stationStop[slot]), Int(table.stationEnter[slot]), Int(table.stationExit[slot])])
            }
        }
        for stop in 0..<world.network.stopCount {
            let range = Int(table.stopStart[stop])..<Int(table.stopStart[stop + 1])
            for slot in range {
                backward.insert([Int(table.stopStation[slot]), stop, Int(table.stopEnter[slot]), Int(table.stopExit[slot])])
            }
            let keys = range.map { (table.stopExit[$0], table.stopStation[$0]) }
            #expect(zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 })
        }
        #expect(forward == backward)
    }

    @Test func checkerCatchesBrokenTables() {
        // 0→1 30 s, 1→2 30 s, 0→2 90 s: the triangle inequality fails; 2→0 then 0→1 fits but 2→1 is missing.
        let table = FootpathTable(start: [0, 2, 3, 4], target: [1, 2, 2, 0], seconds: [30, 90, 30, 10])
        let check = FootpathCheck.run(table, walkSeconds: 100, stopAccessSeconds: [0, 0, 0])
        #expect(check.triangleViolations == 1 && check.closureViolations >= 1 && !check.passed)
        let unsorted = FootpathTable(start: [0, 2, 2], target: [1, 1], seconds: [5, 5])
        #expect(FootpathCheck.run(unsorted, walkSeconds: 100, stopAccessSeconds: [0, 0]).unsortedRows == 1)
        let loop = FootpathTable(start: [0, 1], target: [0], seconds: [1])
        #expect(FootpathCheck.run(loop, walkSeconds: 100, stopAccessSeconds: [0]).selfLoops == 1)
        let over = FootpathTable(start: [0, 1, 1], target: [1], seconds: [200])
        #expect(FootpathCheck.run(over, walkSeconds: 100, stopAccessSeconds: [50, 49]).overBound == 1)
    }
}

@Suite struct RandomWorldCoverageTests {
    /// The random worlds must exercise what the property tests claim to cover.
    @Test func randomWorldsAreNotTrivial() {
        var footpaths = 0, stationLinks = 0, oneWayLinks = 0, viaTransfer = 0, sharedSegments = 0, unanchored = 0
        for seed in FootpathPropertyTests.seeds {
            let world = RandomLinkWorld(seed: seed)
            let compiled = LinksBuilder.build(network: world.network, stationAnchors: world.stations, graph: world.graph, options: world.options)
            footpaths += compiled.footpaths.count
            stationLinks += compiled.stationLinks.count
            oneWayLinks += compiled.stationLinkStats.enterOnly + compiled.stationLinkStats.exitOnly
            let rows = compiled.footpaths.rows(world.network.stopCount)
            viaTransfer += world.network.transfers.filter { t in rows[t.from].contains { $0.stop == t.to && $0.seconds == Int(t.seconds) } }.count
            let keys = world.network.accessPoints.compactMap { $0.anchor?.segmentKey }
            sharedSegments += keys.count - Set(keys).count
            unanchored += world.network.accessPoints.filter { $0.anchor == nil }.count
        }
        #expect(footpaths > 500)
        #expect(stationLinks > 50)
        #expect(oneWayLinks > 0)
        #expect(viaTransfer > 10)
        #expect(sharedSegments > 0)
        #expect(unanchored > 0)
    }
}
