import BRCore
import BRStreetCore
import BRTimetable
import Foundation

/// The walk graph joined with every routable stop, as one directed graph with millisecond costs.
///
/// Nodes, in order: the street nodes; one *exit* node per access point (you are standing at the
/// point, having left the system); one *entry* node per access point (you are at the point, about
/// to enter); one *platform* node per routable stop. Edges:
///
/// - street → street: each walkable edge at walking cost;
/// - exit(a) → segment ends, and segment ends → entry(a): the partial edge between the point's
///   snapped position and each end, rounded exactly as `SnappedPoint.searchSeeds` and
///   `ShortestPathTree.arrival(at:)` round (so these costs match the app's walk trees);
/// - exit(a) → entry(b) for points on one segment: the straight run between them (0 when a = b);
/// - platform(p) → exit(a) for each exit-allowed point of p, and entry(a) → platform(q) for each
///   entry-allowed point of q: station access + the snap leg at walking speed. These are the only
///   street↔platform transitions, so station access is charged exactly once at each;
/// - platform(p) → platform(q): an in-station transfer (`transfers.txt`), in seconds × 1000.
///
/// Footpaths are shortest paths over this graph from one platform node to the others, so they
/// form a metric: the triangle inequality holds, and walking through a platform (entering and
/// leaving) is allowed but pays access twice.
///
/// `@unchecked Sendable`: every stored property is an immutable `let` set in `init`.
final class LinkUnionGraph: @unchecked Sendable {
    let streetNodes: Int
    let accessPointCount: Int
    /// Global stop of each platform node.
    let platformStops: [Int]
    /// Global stop → platform index, or -1.
    let platformOfStop: [Int32]
    let offsets: [UInt32]
    let targets: [UInt32]
    let costs: [UInt32]
    /// Walk cost of each street edge (by street edge index), or `CSRGraph.unusable`.
    let streetEdgeCost: [UInt32]

    // Per access point, for station-link searches.
    let anchors: [LinkAnchor?]
    let forwardCost: [UInt32]
    let backwardCost: [UInt32]
    let snapWalkMs: [UInt32]
    let accessMs: [UInt32]
    let entry: [Bool]
    let exit: [Bool]
    /// Street node → anchored access points at either end of their segment.
    let nodePointStart: [UInt32]
    let nodePoints: [UInt32]
    /// Segment key → anchored access points on that segment.
    let segmentPoints: [UInt64: [Int]]
    /// Access point → routable stops that use it.
    let pointStopStart: [UInt32]
    let pointStops: [UInt32]
    let walkSpeed: Double

    var nodeCount: Int { offsets.count - 1 }
    var edgeCount: Int { targets.count }
    var exitBase: Int { streetNodes }
    var entryBase: Int { streetNodes + accessPointCount }
    var platformBase: Int { streetNodes + 2 * accessPointCount }

    init<Graph: StreetNetwork>(network: LinkNetwork, graph: Graph, walk: WalkProfile) {
        walkSpeed = walk.speedMetersPerSecond
        let points = network.accessPoints
        let a = points.count
        accessPointCount = a
        var platformStops: [Int] = []
        var platformOfStop = [Int32](repeating: -1, count: network.stopCount)
        for stop in 0..<network.stopCount where network.routable[stop] {
            platformOfStop[stop] = Int32(platformStops.count)
            platformStops.append(stop)
        }
        self.platformStops = platformStops
        self.platformOfStop = platformOfStop
        anchors = points.map(\.anchor)
        entry = points.map(\.entry)
        exit = points.map(\.exit)
        accessMs = points.map { $0.accessSeconds &* 1000 }
        snapWalkMs = points.map { point in
            point.anchor.map { UInt32(($0.snapMeters / walk.speedMetersPerSecond * 1000).rounded()) } ?? 0
        }

        var built: (streetNodes: Int, offsets: [UInt32], targets: [UInt32], costs: [UInt32], streetCost: [UInt32],
                    forward: [UInt32], backward: [UInt32], nodePointStart: [UInt32], nodePoints: [UInt32]) =
            (0, [], [], [], [], [], [], [], [])
        let snapWalkMs = self.snapWalkMs, accessMs = self.accessMs, anchors = self.anchors
        graph.withView { view in
            let v = view.nodeCount
            let exitBase = v, entryBase = v + a, platformBase = v + 2 * a
            let nodeCount = platformBase + platformStops.count
            let streetCost = (0..<view.edgeCount).map { walk.costMs(ofEdge: $0, in: view) ?? CSRGraph.unusable }
            func edgeCost(_ edge: UInt32?) -> UInt32 { edge.map { streetCost[Int($0)] } ?? CSRGraph.unusable }
            let forward = anchors.map { edgeCost($0?.forwardEdge) }
            let backward = anchors.map { edgeCost($0?.backwardEdge) }

            var extraSource: [UInt32] = [], extraTarget: [UInt32] = [], extraCost: [UInt32] = []
            func add(_ from: Int, _ to: Int, _ cost: UInt32) {
                extraSource.append(UInt32(from))
                extraTarget.append(UInt32(to))
                extraCost.append(cost)
            }
            var groups: [UInt64: [Int]] = [:]
            for (index, anchor) in anchors.enumerated() {
                guard let anchor else { continue }
                groups[anchor.segmentKey, default: []].append(index)
                let f = anchor.fraction, fc = forward[index], bc = backward[index]
                if points[index].exit {
                    if fc != CSRGraph.unusable { add(exitBase + index, Int(anchor.nodeB), PartialEdge.portion(fc, 1 - f)) }
                    if bc != CSRGraph.unusable { add(exitBase + index, Int(anchor.nodeA), PartialEdge.portion(bc, f)) }
                }
                if points[index].entry {
                    if fc != CSRGraph.unusable { add(Int(anchor.nodeA), entryBase + index, PartialEdge.portion(fc, f)) }
                    if bc != CSRGraph.unusable { add(Int(anchor.nodeB), entryBase + index, PartialEdge.portion(bc, 1 - f)) }
                }
            }
            for key in groups.keys.sorted() {
                let members = groups[key]!
                for from in members where points[from].exit {
                    for to in members where points[to].entry {
                        let delta = anchors[to]!.fraction - anchors[from]!.fraction
                        let cost = delta >= 0 ? forward[from] : backward[from]
                        if from == to {
                            add(exitBase + from, entryBase + to, 0)
                        } else if cost != CSRGraph.unusable {
                            add(exitBase + from, entryBase + to, PartialEdge.portion(cost, abs(delta)))
                        }
                    }
                }
            }
            for (platform, stop) in platformStops.enumerated() {
                for index in network.stopAccess[stop] where anchors[index] != nil {
                    let cost = PartialEdge.add(accessMs[index], snapWalkMs[index])
                    if points[index].exit { add(platformBase + platform, exitBase + index, cost) }
                    if points[index].entry { add(entryBase + index, platformBase + platform, cost) }
                }
            }
            for transfer in network.transfers {
                let from = platformOfStop[transfer.from], to = platformOfStop[transfer.to]
                guard from >= 0, to >= 0, from != to else { continue }
                add(platformBase + Int(from), platformBase + Int(to), transfer.seconds &* 1000)
            }

            // CSR: each street node's walkable edges (in street order), then extras in insertion order.
            var offsets = [UInt32](repeating: 0, count: nodeCount + 1)
            for u in 0..<v {
                for edge in view.outgoingEdges(of: u) where streetCost[edge] != CSRGraph.unusable { offsets[u + 1] += 1 }
            }
            for source in extraSource { offsets[Int(source) + 1] += 1 }
            for node in 0..<nodeCount { offsets[node + 1] += offsets[node] }
            let total = Int(offsets[nodeCount])
            var targets = [UInt32](repeating: 0, count: total), costs = [UInt32](repeating: 0, count: total)
            var cursor = offsets
            for u in 0..<v {
                for edge in view.outgoingEdges(of: u) where streetCost[edge] != CSRGraph.unusable {
                    let slot = Int(cursor[u])
                    targets[slot] = view.edgeTargets[edge]
                    costs[slot] = streetCost[edge]
                    cursor[u] += 1
                }
            }
            for (i, source) in extraSource.enumerated() {
                let slot = Int(cursor[Int(source)])
                targets[slot] = extraTarget[i]
                costs[slot] = extraCost[i]
                cursor[Int(source)] += 1
            }

            // Street node → anchored points, for station links.
            var pointStart = [UInt32](repeating: 0, count: v + 1)
            for anchor in anchors.compactMap({ $0 }) {
                pointStart[Int(anchor.nodeA) + 1] += 1
                if anchor.nodeB != anchor.nodeA { pointStart[Int(anchor.nodeB) + 1] += 1 }
            }
            for node in 0..<v { pointStart[node + 1] += pointStart[node] }
            var pointCursor = pointStart
            var nodePoints = [UInt32](repeating: 0, count: Int(pointStart[v]))
            for (index, anchor) in anchors.enumerated() {
                guard let anchor else { continue }
                for node in anchor.nodeA == anchor.nodeB ? [anchor.nodeA] : [anchor.nodeA, anchor.nodeB] {
                    nodePoints[Int(pointCursor[Int(node)])] = UInt32(index)
                    pointCursor[Int(node)] += 1
                }
            }
            built = (v, offsets, targets, costs, streetCost, forward, backward, pointStart, nodePoints)
        }
        streetNodes = built.streetNodes
        offsets = built.offsets
        targets = built.targets
        costs = built.costs
        streetEdgeCost = built.streetCost
        forwardCost = built.forward
        backwardCost = built.backward
        nodePointStart = built.nodePointStart
        nodePoints = built.nodePoints
        var segments: [UInt64: [Int]] = [:]
        for (index, anchor) in anchors.enumerated() { if let anchor { segments[anchor.segmentKey, default: []].append(index) } }
        segmentPoints = segments

        var stopStart = [UInt32](repeating: 0, count: a + 1)
        for stop in platformStops { for index in network.stopAccess[stop] { stopStart[index + 1] += 1 } }
        for index in 0..<a { stopStart[index + 1] += stopStart[index] }
        var stopCursor = stopStart
        var stops = [UInt32](repeating: 0, count: Int(stopStart[a]))
        for stop in platformStops {
            for index in network.stopAccess[stop] {
                stops[Int(stopCursor[index])] = UInt32(stop)
                stopCursor[index] += 1
            }
        }
        pointStopStart = stopStart
        pointStops = stops
    }

    func withCSR<R>(_ body: (CSRGraph) -> R) -> R {
        offsets.withUnsafeBufferPointer { offsets in
            targets.withUnsafeBufferPointer { targets in
                costs.withUnsafeBufferPointer { costs in
                    body(CSRGraph(offsets: offsets, targets: targets, costs: costs, lengths: nil))
                }
            }
        }
    }
}

// MARK: - Results

/// Footpaths over the global stop index, CSR: stop s's walks are `start[s] ..< start[s + 1]`,
/// sorted by (seconds, target).
public struct FootpathTable: Sendable, Equatable {
    public var start: [UInt32]
    public var target: [UInt32]
    public var seconds: [UInt16]

    public init(start: [UInt32], target: [UInt32], seconds: [UInt16]) {
        precondition(target.count == seconds.count && Int(start.last ?? 0) == target.count, "inconsistent footpath table")
        self.start = start
        self.target = target
        self.seconds = seconds
    }

    public var count: Int { target.count }

    public func footpaths(from stop: Int) -> [(stop: Int, seconds: Int)] {
        (Int(start[stop])..<Int(start[stop + 1])).map { (Int(target[$0]), Int(seconds[$0])) }
    }
}

/// Stop↔station walk links, CSR both ways. A station's list is sorted by (enter, stop), a
/// stop's by (exit, station), with ``BRTimetable/LinksFormat/noSeconds`` last.
public struct StationLinkTable: Sendable, Equatable {
    public var stationStart: [UInt32]
    public var stationStop: [UInt32]
    public var stationEnter: [UInt16]
    public var stationExit: [UInt16]
    public var stopStart: [UInt32]
    public var stopStation: [UInt32]
    public var stopEnter: [UInt16]
    public var stopExit: [UInt16]

    public static func empty(stops: Int, stations: Int) -> StationLinkTable {
        StationLinkTable(stationStart: [UInt32](repeating: 0, count: stations + 1), stationStop: [], stationEnter: [], stationExit: [],
                         stopStart: [UInt32](repeating: 0, count: stops + 1), stopStation: [], stopEnter: [], stopExit: [])
    }

    public var count: Int { stationStop.count }
}

public struct FootpathStats: Codable, Sendable, Equatable {
    public var sources = 0
    public var footpaths = 0
    public var sourcesWithoutFootpaths = 0
    public var perStop = Distribution()
    /// Routable stops by footpath count: `0`, `1-5`, `6-10`, `11-20`, `21-50`, `51-100`, `101+`.
    public var perStopHistogram: [String: Int] = [:]
    /// Footpaths by whole minutes of duration: `0` is up to 60 s, `1` up to 120 s, and so on.
    public var minutesHistogram: [String: Int] = [:]
    public var seconds = Distribution()
    /// Footpaths by (origin system → destination system), e.g. `subway→bus`.
    public var bySystemPair: [String: Int] = [:]
    public var unionNodes = 0
    public var unionEdges = 0
    public var threads = 0

    public init() {}
}

public struct StationLinkStats: Codable, Sendable, Equatable {
    public var stations = 0
    public var stationsWithWalkSnap = 0
    public var links = 0
    public var stationsWithoutStops = 0
    public var perStation = Distribution()
    public var enterOnly = 0
    public var exitOnly = 0
    /// Links by the stop's system.
    public var bySystem: [String: Int] = [:]
    public var enterSeconds = Distribution()

    public init() {}
}

/// The links, before serialization.
public struct CompiledLinks: Sendable {
    public var network: LinkNetwork
    public var footpaths: FootpathTable
    public var stationLinks: StationLinkTable
    public var stationCount: Int
    public var options: LinksOptions
    public var footpathStats: FootpathStats
    public var stationLinkStats: StationLinkStats
    /// The rail bike hops (``HopBuilder``), written as extension id
    /// ``BRTimetable/LinksFormat/hopsExtensionID``; `nil` writes none (no stations).
    public var hops: CompiledHops?

    public init(network: LinkNetwork, footpaths: FootpathTable, stationLinks: StationLinkTable, stationCount: Int,
                options: LinksOptions, footpathStats: FootpathStats = FootpathStats(),
                stationLinkStats: StationLinkStats = StationLinkStats(), hops: CompiledHops? = nil) {
        self.network = network
        self.footpaths = footpaths
        self.stationLinks = stationLinks
        self.stationCount = stationCount
        self.options = options
        self.footpathStats = footpathStats
        self.stationLinkStats = stationLinkStats
        self.hops = hops
    }
}

// MARK: - Builders

public enum LinksBuilder {
    /// Footpaths from every routable stop and walk links from every station (`stationAnchors`,
    /// one per station in `stations` order; `nil` for a station without a walk snap).
    public static func build<Graph: StreetNetwork>(
        network: LinkNetwork, stationAnchors: [LinkAnchor?], graph: Graph, options: LinksOptions
    ) -> CompiledLinks {
        let union = LinkUnionGraph(network: network, graph: graph, walk: options.walk)
        let (footpaths, footpathStats) = footpathTable(union: union, network: network, options: options)
        let (stationLinks, stationStats) = stationLinkTable(union: union, network: network, stationAnchors: stationAnchors, options: options)
        return CompiledLinks(network: network, footpaths: footpaths, stationLinks: stationLinks, stationCount: stationAnchors.count,
                             options: options, footpathStats: footpathStats, stationLinkStats: stationStats)
    }

    /// Only the footpaths.
    public static func footpaths<Graph: StreetNetwork>(
        network: LinkNetwork, graph: Graph, options: LinksOptions
    ) -> (table: FootpathTable, stats: FootpathStats) {
        footpathTable(union: LinkUnionGraph(network: network, graph: graph, walk: options.walk), network: network, options: options)
    }

    static func footpathTable(union: LinkUnionGraph, network: LinkNetwork, options: LinksOptions) -> (FootpathTable, FootpathStats) {
        let sources = union.platformStops
        // p → q is kept when it costs at most walk bound + access(p) + access(q); a search from p
        // runs to walk bound + access(p) + the largest access of any stop.
        let access = stopAccessSeconds(network, options)
        let maxAccess = access.max() ?? 0
        let walkBound = options.maxFootpathWalkSeconds
        let results = SharedBuffer<[UInt64]>(count: sources.count, repeating: [])
        let out = results.pointer
        let platformBase = union.platformBase
        union.withCSR { csr in
            // Read-only graph and one output slot per item: safe to share across workers.
            let shared = UncheckedSendable(value: (csr: csr, out: out))
            ParallelWork.run(
                items: sources.count, threads: options.threads, chunk: 32,
                makeScratch: { ScratchDijkstra(nodeCount: union.nodeCount, edgeCount: union.edgeCount, recordsDistances: false) }
            ) { item, scratch in
                let (csr, out) = shared.value
                let origin = union.platformStops[item]
                let base = walkBound &+ access[origin]
                scratch.run(csr, seeds: [SearchSeed(node: UInt32(platformBase + item))], bound: (base &+ maxAccess) &* 1000)
                var found: [UInt64] = []
                for node in scratch.reached where Int(node) >= platformBase && Int(node) != platformBase + item {
                    let stop = union.platformStops[Int(node) - platformBase]
                    let cost = scratch.cost[Int(node)]
                    guard cost <= (base &+ access[stop]) &* 1000 else { continue }
                    found.append(((UInt64(cost) + 999) / 1000) << 32 | UInt64(stop))
                }
                found.sort()
                out[item] = found
            }
        }
        // Read back through the buffer object, which also keeps it alive until here.
        let rows = results.toArray()

        var start = [UInt32](repeating: 0, count: network.stopCount + 1)
        var target: [UInt32] = [], seconds: [UInt16] = []
        var stats = FootpathStats()
        stats.sources = sources.count
        stats.unionNodes = union.nodeCount
        stats.unionEdges = union.edgeCount
        stats.threads = max(1, min(options.threads, sources.count))
        var counts: [Double] = [], durations: [Double] = []
        let systemOf = systemLookup(network)
        for (item, stop) in sources.enumerated() {
            let found = rows[item]
            start[stop + 1] = UInt32(found.count)
            counts.append(Double(found.count))
            if found.isEmpty { stats.sourcesWithoutFootpaths += 1 }
            stats.perStopHistogram[bucket(found.count), default: 0] += 1
            for entry in found {
                let s = UInt16(entry >> 32), q = UInt32(truncatingIfNeeded: entry)
                target.append(q)
                seconds.append(s)
                durations.append(Double(s))
                stats.minutesHistogram[String(max(0, (Int(s) - 1) / 60)), default: 0] += 1
                stats.bySystemPair["\(systemOf(stop).linkReportName)→\(systemOf(Int(q)).linkReportName)", default: 0] += 1
            }
        }
        for stop in 0..<network.stopCount { start[stop + 1] += start[stop] }
        // `start` was filled per routable stop in index order, so the prefix sum lines up with the
        // concatenation order above.
        stats.footpaths = target.count
        stats.perStop = Distribution(counts)
        stats.seconds = Distribution(durations)
        return (FootpathTable(start: start, target: target, seconds: seconds), stats)
    }

    static func stationLinkTable(
        union: LinkUnionGraph, network: LinkNetwork, stationAnchors: [LinkAnchor?], options: LinksOptions
    ) -> (StationLinkTable, StationLinkStats) {
        let stations = stationAnchors.count
        var stats = StationLinkStats()
        stats.stations = stations
        stats.stationsWithWalkSnap = stationAnchors.compactMap { $0 }.count
        guard stations > 0 else { return (.empty(stops: network.stopCount, stations: 0), stats) }
        let maxWalkMs = UInt32((options.stationLinkMaxWalkMeters / options.walk.speedMetersPerSecond * 1000).rounded())
        let results = SharedBuffer<[(stop: UInt32, enter: UInt16, exit: UInt16)]>(count: stations, repeating: [])
        let out = results.pointer
        let v = union.streetNodes

        final class Scratch {
            let search: ScratchDijkstra
            var stamp: [Int32]
            init(union: LinkUnionGraph) {
                search = ScratchDijkstra(nodeCount: union.nodeCount, edgeCount: union.edgeCount, recordsDistances: false)
                stamp = [Int32](repeating: -1, count: union.accessPointCount)
            }
        }

        union.withCSR { csr in
            let shared = UncheckedSendable(value: (csr: csr, out: out))
            ParallelWork.run(items: stations, threads: options.threads, chunk: 8, makeScratch: { Scratch(union: union) }) { station, scratch in
                let (csr, out) = shared.value
                guard let origin = stationAnchors[station] else { return }
                let originWalk = UInt32((origin.snapMeters / options.walk.speedMetersPerSecond * 1000).rounded())
                func walkCost(_ edge: UInt32?) -> UInt32? {
                    guard let edge, union.streetEdgeCost[Int(edge)] != CSRGraph.unusable else { return nil }
                    return union.streetEdgeCost[Int(edge)]
                }
                // Leave the station's snapped point toward B on A→B, or toward A on B→A.
                var seeds: [SearchSeed] = []
                let originForward = walkCost(origin.forwardEdge), originBackward = walkCost(origin.backwardEdge)
                if let cost = originForward { seeds.append(SearchSeed(node: origin.nodeB, initialCostMs: PartialEdge.add(PartialEdge.portion(cost, 1 - origin.fraction), originWalk))) }
                if let cost = originBackward { seeds.append(SearchSeed(node: origin.nodeA, initialCostMs: PartialEdge.add(PartialEdge.portion(cost, origin.fraction), originWalk))) }
                scratch.search.run(csr, seeds: seeds, bound: maxWalkMs, expandBelow: v)

                var best: [UInt32: (enter: UInt32, exit: UInt32)] = [:]
                func consider(_ point: Int) {
                    guard scratch.stamp[point] != Int32(station), let anchor = union.anchors[point] else { return }
                    scratch.stamp[point] = Int32(station)
                    var walk = UInt32.max
                    let costA = scratch.search.cost[Int(anchor.nodeA)], costB = scratch.search.cost[Int(anchor.nodeB)]
                    if union.forwardCost[point] != CSRGraph.unusable, costA != ScratchDijkstra.unreached {
                        walk = min(walk, PartialEdge.add(costA, PartialEdge.portion(union.forwardCost[point], anchor.fraction)))
                    }
                    if union.backwardCost[point] != CSRGraph.unusable, costB != ScratchDijkstra.unreached {
                        walk = min(walk, PartialEdge.add(costB, PartialEdge.portion(union.backwardCost[point], 1 - anchor.fraction)))
                    }
                    if anchor.segmentKey == origin.segmentKey {
                        let delta = anchor.fraction - origin.fraction
                        if let cost = delta >= 0 ? originForward : originBackward {
                            walk = min(walk, PartialEdge.add(originWalk, PartialEdge.portion(cost, abs(delta))))
                        }
                    }
                    guard walk != .max else { return }
                    let total = PartialEdge.add(walk, union.snapWalkMs[point])
                    guard total <= maxWalkMs else { return }
                    let seconds = (PartialEdge.add(total, union.accessMs[point]) + 999) / 1000
                    for slot in Int(union.pointStopStart[point])..<Int(union.pointStopStart[point + 1]) {
                        let stop = union.pointStops[slot]
                        var entry = best[stop] ?? (.max, .max)
                        if union.entry[point] { entry.enter = min(entry.enter, seconds) }
                        if union.exit[point] { entry.exit = min(entry.exit, seconds) }
                        best[stop] = entry
                    }
                }
                for node in scratch.search.reached where Int(node) < v {
                    for slot in Int(union.nodePointStart[Int(node)])..<Int(union.nodePointStart[Int(node) + 1]) {
                        consider(Int(union.nodePoints[slot]))
                    }
                }
                for point in union.segmentPoints[origin.segmentKey] ?? [] { consider(point) }

                func stored(_ seconds: UInt32) -> UInt16 {
                    seconds == .max ? LinksFormat.noSeconds : UInt16(min(UInt32(LinksFormat.noSeconds - 1), seconds))
                }
                out[station] = best.map { (stop: $0.key, enter: stored($0.value.enter), exit: stored($0.value.exit)) }
                    .filter { $0.enter != LinksFormat.noSeconds || $0.exit != LinksFormat.noSeconds }
                    .sorted { ($0.enter, $0.stop) < ($1.enter, $1.stop) }
            }
        }

        let perStationLinks = results.toArray()

        // Station → stops, then the reverse index.
        var table = StationLinkTable.empty(stops: network.stopCount, stations: stations)
        var perStop = [[(station: UInt32, enter: UInt16, exit: UInt16)]](repeating: [], count: network.stopCount)
        let systemOf = systemLookup(network)
        var perStation: [Double] = [], enterSeconds: [Double] = []
        for station in 0..<stations {
            let links = perStationLinks[station]
            table.stationStart[station + 1] = table.stationStart[station] + UInt32(links.count)
            perStation.append(Double(links.count))
            if links.isEmpty { stats.stationsWithoutStops += 1 }
            for link in links {
                table.stationStop.append(link.stop)
                table.stationEnter.append(link.enter)
                table.stationExit.append(link.exit)
                perStop[Int(link.stop)].append((UInt32(station), link.enter, link.exit))
                if link.exit == LinksFormat.noSeconds { stats.enterOnly += 1 }
                if link.enter == LinksFormat.noSeconds { stats.exitOnly += 1 } else { enterSeconds.append(Double(link.enter)) }
                stats.bySystem[systemOf(Int(link.stop)).linkReportName, default: 0] += 1
            }
        }
        for stop in 0..<network.stopCount {
            let links = perStop[stop].sorted { ($0.exit, $0.station) < ($1.exit, $1.station) }
            table.stopStart[stop + 1] = table.stopStart[stop] + UInt32(links.count)
            for link in links {
                table.stopStation.append(link.station)
                table.stopEnter.append(link.enter)
                table.stopExit.append(link.exit)
            }
        }
        stats.links = table.count
        stats.perStation = Distribution(perStation)
        stats.enterSeconds = Distribution(enterSeconds)
        return (table, stats)
    }

    /// Station access of each global stop's system, in seconds.
    public static func stopAccessSeconds(_ network: LinkNetwork, _ options: LinksOptions) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(network.stopCount)
        for (slot, system) in LinksFormat.systems.enumerated() {
            result += repeatElement(options.access(system), count: network.systemStopCounts[slot])
        }
        return result
    }

    static func systemLookup(_ network: LinkNetwork) -> (Int) -> TransitSystem {
        var bounds: [(Int, TransitSystem)] = []
        var running = 0
        for (slot, system) in LinksFormat.systems.enumerated() {
            running += network.systemStopCounts[slot]
            bounds.append((running, system))
        }
        return { stop in
            guard let system = bounds.first(where: { stop < $0.0 })?.1 else { preconditionFailure("stop \(stop) is past the global index") }
            return system
        }
    }

    static func bucket(_ count: Int) -> String {
        switch count {
        case 0: "0"
        case 1...5: "1-5"
        case 6...10: "6-10"
        case 11...20: "11-20"
        case 21...50: "21-50"
        case 51...100: "51-100"
        default: "101+"
        }
    }
}
