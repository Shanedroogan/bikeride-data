import BRGeo
import BRStreetCore
import Foundation

/// A station as written to the `stations` artifact.
public struct CompiledStation: Sendable, Equatable {
    public var id: String
    public var name: String
    public var shortName: String
    public var regionID: String?
    public var latE6: Int32
    public var lonE6: Int32
    public var capacity: UInt16
    public var flags: StationFlags
    public var bikeSnap: StoredSnap?
    public var walkSnap: StoredSnap?

    public init(id: String, name: String, shortName: String, regionID: String?, latE6: Int32, lonE6: Int32,
                capacity: UInt16, flags: StationFlags = [], bikeSnap: StoredSnap? = nil, walkSnap: StoredSnap? = nil) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.regionID = regionID
        self.latE6 = latE6
        self.lonE6 = lonE6
        self.capacity = capacity
        self.flags = flags
        self.bikeSnap = bikeSnap
        self.walkSnap = walkSnap
    }

    /// The stored position (microdegrees), which is what snapping and the reader use.
    public var coordinate: Coordinate { Coordinate(lat: Double(latE6) / 1e6, lon: Double(lonE6) / 1e6) }
}

/// Which feed stations the artifact keeps.
public struct StationSelection: Sendable, Equatable {
    /// Citi Bike's New York City regions. A station with no `region_id` is kept when it lies
    /// inside the five boroughs.
    public var regionIDs: Set<String> = ["71", "185", "158"]

    public init() {}
}

public struct StationSelectionStats: Codable, Sendable, Equatable {
    public var feedStations = 0
    public var accepted = 0
    /// Accepted without a `region_id`, by the five-borough polygon.
    public var acceptedByArea = 0
    public var rejectedRegion = 0
    public var rejectedNoRegionOutsideArea = 0
    public var rejectedCapacity = 0
    /// Later entries repeating an accepted `station_id` (the first is kept).
    public var duplicateIDs = 0
    public var rejectedRegionIDs: [String: Int] = [:]

    public init() {}
}

public struct StationSnapStats: Codable, Sendable, Equatable {
    public var bikeSnapped = 0
    public var walkSnapped = 0
    /// `station_id: name` of stations with no rideable segment within the snap limit.
    public var bikeUnsnapped: [String] = []
    public var walkUnsnapped: [String] = []
    public var bikeSnapMeters = Distribution()
    public var walkSnapMeters = Distribution()

    public init() {}
}

/// Percentiles of a sample, for reports.
public struct Distribution: Codable, Sendable, Equatable {
    public var count = 0
    public var min = 0.0
    public var p50 = 0.0
    public var p90 = 0.0
    public var p99 = 0.0
    public var max = 0.0
    public var mean = 0.0

    public init() {}

    public init(_ values: [Double]) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[Swift.min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
        count = sorted.count
        min = sorted[0]
        p50 = at(0.5)
        p90 = at(0.9)
        p99 = at(0.99)
        max = sorted[sorted.count - 1]
        mean = sorted.reduce(0, +) / Double(sorted.count)
    }
}

public struct StationMatrixStats: Codable, Sendable, Equatable {
    public var stations = 0
    /// Ordered pairs i ≠ j.
    public var pairs = 0
    public var reachablePairs = 0
    public var unreachablePairs = 0
    /// Pairs whose best path runs straight along the shared segment.
    public var sameSegmentPairs = 0
    /// Rows (origins) that reach no other station.
    public var isolatedOrigins = 0
    public var maxDecameters = 0
    public var meanKilometers = 0.0
    public var threads = 0

    public init() {}
}

/// The steps of the stations compiler that do not touch the network or disk.
public enum StationsBuilder {
    /// The box station order is laid out in: the streets extract's bounding box.
    public static let orderBox = (west: -74.2710, south: 40.4680, east: -73.6880, north: 40.9270)

    /// Position along a Hilbert curve through ``orderBox`` (positions outside are clamped).
    /// Ordering stations by it puts neighbors next to each other, so matrix rows and columns
    /// of nearby stations are similar and the matrix compresses far better.
    public static func orderKey(latE6: Int32, lonE6: Int32) -> UInt32 {
        func scaled(_ value: Double, _ low: Double, _ high: Double) -> UInt16 {
            UInt16(max(0, min(65535, ((value - low) / (high - low) * 65535).rounded(.down))))
        }
        let box = orderBox
        return StreetGeometry.hilbertIndex(
            x: scaled(StreetsFormat.degrees(lonE6), box.west, box.east),
            y: scaled(StreetsFormat.degrees(latE6), box.south, box.north)
        )
    }

    /// Applies the region and capacity rules, drops repeated ids, and returns the kept stations
    /// in the artifact's order: by ``orderKey(latE6:lonE6:)``, then by the UTF-8 bytes of the id.
    public static func select(
        _ feed: [GBFSStation], area: MultiPolygon, rules: StationSelection = StationSelection()
    ) -> (stations: [CompiledStation], stats: StationSelectionStats) {
        var stats = StationSelectionStats()
        stats.feedStations = feed.count
        var seen = Set<String>()
        var kept: [CompiledStation] = []
        for station in feed {
            let latE6 = StreetsFormat.microdegrees(station.lat), lonE6 = StreetsFormat.microdegrees(station.lon)
            let coordinate = Coordinate(lat: StreetsFormat.degrees(latE6), lon: StreetsFormat.degrees(lonE6))
            let region = station.regionID.flatMap { $0.isEmpty ? nil : $0 }
            var flags: StationFlags = station.isCharging ? .charging : []
            if let region {
                guard rules.regionIDs.contains(region) else {
                    stats.rejectedRegion += 1
                    stats.rejectedRegionIDs[region, default: 0] += 1
                    continue
                }
            } else {
                guard area.contains(coordinate) else {
                    stats.rejectedNoRegionOutsideArea += 1
                    continue
                }
                flags.insert(.acceptedByArea)
            }
            guard let capacity = station.capacity, capacity > 0 else {
                stats.rejectedCapacity += 1
                continue
            }
            guard seen.insert(station.stationID).inserted else {
                stats.duplicateIDs += 1
                continue
            }
            if flags.contains(.acceptedByArea) { stats.acceptedByArea += 1 }
            kept.append(CompiledStation(
                id: station.stationID, name: station.name, shortName: station.shortName, regionID: region,
                latE6: latE6, lonE6: lonE6, capacity: UInt16(clamping: capacity), flags: flags
            ))
        }
        kept = kept.map { (orderKey(latE6: $0.latE6, lonE6: $0.lonE6), $0) }
            .sorted { a, b in a.0 != b.0 ? a.0 < b.0 : a.1.id.utf8.lexicographicallyPrecedes(b.1.id.utf8) }
            .map(\.1)
        stats.accepted = kept.count
        return (kept, stats)
    }

    /// Snaps every station to the nearest segment the bike profile can ride (for the matrix)
    /// and the nearest walkable one (for walk trees), at stored precision.
    public static func snap(
        _ stations: inout [CompiledStation], graph: MappedStreetGraph, bikeProfile: BikeProfile,
        walkProfile: WalkProfile = .standard, maxSnapMeters: Double = 250
    ) -> StationSnapStats {
        var stats = StationSnapStats()
        var bikeMeters: [Double] = [], walkMeters: [Double] = []
        for index in stations.indices {
            let coordinate = stations[index].coordinate
            stations[index].flags.subtract([.bikeSnapped, .walkSnapped])
            if let point = graph.snap(coordinate, profile: bikeProfile, maxDistanceMeters: maxSnapMeters) {
                let stored = StoredSnap(point)
                stations[index].bikeSnap = stored
                stations[index].flags.insert(.bikeSnapped)
                bikeMeters.append(stored.distanceMeters)
            } else {
                stations[index].bikeSnap = nil
                stats.bikeUnsnapped.append("\(stations[index].id): \(stations[index].name)")
            }
            if let point = graph.snap(coordinate, profile: walkProfile, maxDistanceMeters: maxSnapMeters) {
                let stored = StoredSnap(point)
                stations[index].walkSnap = stored
                stations[index].flags.insert(.walkSnapped)
                walkMeters.append(stored.distanceMeters)
            } else {
                stations[index].walkSnap = nil
                stats.walkUnsnapped.append("\(stations[index].id): \(stations[index].name)")
            }
        }
        stats.bikeSnapped = bikeMeters.count
        stats.walkSnapped = walkMeters.count
        stats.bikeSnapMeters = Distribution(bikeMeters)
        stats.walkSnapMeters = Distribution(walkMeters)
        return stats
    }

    /// The dense bike matrix: for every ordered pair, the true length (decameters) of the
    /// minimum-cost path under `profile`, from each station's stored bike snap, plus both snap
    /// legs. One full one-to-all search per origin, spread across `threads` workers.
    ///
    /// Each search is the same computation as ``BRStreetCore/Dijkstra`` seeded with
    /// ``BRStreetCore/SnappedPoint/searchSeeds(in:profile:direction:extraCostMs:)`` and read with
    /// ``BRStreetCore/ShortestPathTree/arrival(at:in:profile:)``, preferring a straight run along
    /// a shared segment when it costs no more (as ``BRStreetCore/MappedStreetGraph/route(from:to:profile:heuristicFactor:maxCostMs:isCancelled:)``
    /// does).
    public static func matrix(
        for stations: [CompiledStation], graph: MappedStreetGraph, profile: BikeProfile, threads: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> (matrix: [UInt16], stats: StationMatrixStats) {
        let n = stations.count
        let points: [SnappedPoint?] = stations.map { station in
            station.bikeSnap.flatMap { graph.snappedPoint($0, query: station.coordinate) }
        }
        let seeds: [[SearchSeed]] = points.map { $0?.searchSeeds(in: graph, profile: profile, direction: .forward) ?? [] }
        let output = SharedBuffer<UInt16>(count: n * n, repeating: StationsFormat.unreachable)
        let rowStats = LockedCollector<(reachable: Int, sameSegment: Int, maxDecameters: Int, sumMeters: Double)>()

        graph.withView { view in
            let costs = (0..<view.edgeCount).map { profile.costMs(ofEdge: $0, in: view) ?? CSRGraph.unusable }
            costs.withUnsafeBufferPointer { costs in
                let csr = CSRGraph(offsets: view.forwardOffsets, targets: view.edgeTargets, costs: costs, lengths: view.edgeLengthDecimeters)
                // Read-only inputs and disjoint output rows: safe to share across workers.
                let shared = UncheckedSendable(value: (csr: csr, costs: costs, lengths: view.edgeLengthDecimeters, out: output.pointer))
                let nodeCount = view.nodeCount, edgeCount = view.edgeCount
                ParallelWork.run(
                    items: n, threads: threads, chunk: 2,
                    makeScratch: { ScratchDijkstra(nodeCount: nodeCount, edgeCount: edgeCount, recordsDistances: true) }
                ) { i, scratch in
                    let (csr, costs, lengths, out) = shared.value
                    out[i * n + i] = 0
                    guard let origin = points[i] else { return }
                    scratch.run(csr, seeds: seeds[i], bound: StreetCost.maxFinite)
                    var reachable = 0, sameSegment = 0, maxDecameters = 0, sumMeters = 0.0
                    for j in 0..<n where j != i {
                        guard let target = points[j] else { continue }
                        var best: (cost: UInt32, decimeters: Double)?
                        // Arrive from A along A→B, or from B along B→A (ties to A→B).
                        if let edge = target.forwardEdge.map(Int.init), costs[edge] != CSRGraph.unusable {
                            let base = scratch.cost[Int(target.nodeA)]
                            if base != ScratchDijkstra.unreached {
                                let total = PartialEdge.add(base, PartialEdge.portion(costs[edge], target.fraction))
                                best = (total, Double(scratch.distance[Int(target.nodeA)]) + Double(lengths[edge]) * min(1, max(0, target.fraction)))
                            }
                        }
                        if let edge = target.backwardEdge.map(Int.init), costs[edge] != CSRGraph.unusable {
                            let base = scratch.cost[Int(target.nodeB)]
                            if base != ScratchDijkstra.unreached {
                                let share = 1 - target.fraction
                                let total = PartialEdge.add(base, PartialEdge.portion(costs[edge], share))
                                if total < best?.cost ?? .max {
                                    best = (total, Double(scratch.distance[Int(target.nodeB)]) + Double(lengths[edge]) * min(1, max(0, share)))
                                }
                            }
                        }
                        if origin.segment == target.segment {
                            let delta = target.fraction - origin.fraction
                            if let edge = (delta >= 0 ? origin.forwardEdge : origin.backwardEdge).map(Int.init),
                               costs[edge] != CSRGraph.unusable {
                                let direct = PartialEdge.portion(costs[edge], abs(delta))
                                if direct <= best?.cost ?? .max {
                                    best = (direct, Double(lengths[edge]) * min(1, abs(delta)))
                                    sameSegment += 1
                                }
                            }
                        }
                        guard let best else { continue }
                        let meters = origin.distanceMeters + best.decimeters / 10 + target.distanceMeters
                        let decameters = (meters / 10).rounded()
                        guard decameters <= Double(StationsFormat.maxDecameters) else { continue }
                        out[i * n + j] = UInt16(decameters)
                        reachable += 1
                        maxDecameters = max(maxDecameters, Int(decameters))
                        sumMeters += meters
                    }
                    rowStats.append((reachable, sameSegment, maxDecameters, sumMeters))
                }
            }
        }

        var stats = StationMatrixStats()
        stats.stations = n
        stats.pairs = n * max(0, n - 1)
        stats.threads = max(1, min(threads, n))
        var sumMeters = 0.0
        let rows = rowStats.drain()
        for row in rows {
            stats.reachablePairs += row.reachable
            stats.sameSegmentPairs += row.sameSegment
            stats.maxDecameters = max(stats.maxDecameters, row.maxDecameters)
            if row.reachable == 0 { stats.isolatedOrigins += 1 }
            sumMeters += row.sumMeters
        }
        stats.isolatedOrigins += points.filter { $0 == nil }.count
        stats.unreachablePairs = stats.pairs - stats.reachablePairs
        stats.meanKilometers = stats.reachablePairs > 0 ? sumMeters / Double(stats.reachablePairs) / 1000 : 0
        return (output.toArray(), stats)
    }
}
