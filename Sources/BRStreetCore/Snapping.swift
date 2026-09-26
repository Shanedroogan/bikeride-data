import BRGeo
import Foundation

/// Which segments a point may snap to.
public enum SnapMode: Sendable, Equatable {
    /// Segments with a walkable edge in either direction.
    case walk
    /// Segments with a rideable edge in either direction.
    case bike
    /// Any segment.
    case any

    var requiredFlags: EdgeFlags {
        switch self {
        case .walk: .walk
        case .bike: .bikeForward
        case .any: [.walk, .bikeForward]
        }
    }
}

/// A coordinate projected onto the nearest usable street segment.
public struct SnappedPoint: Sendable, Hashable {
    /// The segment the point lies on.
    public let segment: UInt32
    /// The segment's start (A) and end (B) nodes.
    public let nodeA: UInt32
    public let nodeB: UInt32
    /// The directed edge A→B, if stored.
    public let forwardEdge: UInt32?
    /// The directed edge B→A, if stored.
    public let backwardEdge: UInt32?
    /// Position along the segment by length: 0 at A, 1 at B.
    public let fraction: Double
    /// Meters from the query to ``coordinate``.
    public let distanceMeters: Double
    /// The projected point on the segment.
    public let coordinate: Coordinate
    /// The coordinate that was snapped.
    public let query: Coordinate

    /// The directed edge the point lies on: A→B if stored, else B→A.
    public var edge: UInt32 {
        forwardEdge ?? backwardEdge ?? UInt32.max
    }

    /// Search seeds for a one-to-many search from (``SearchDirection/forward``) or toward
    /// (``SearchDirection/reverse``) this point: the segment's end nodes, each at the cost of the
    /// partial edge between it and the point. `extraCostMs` (e.g. walking the snap distance) is
    /// added to both.
    public func searchSources<Graph: StreetNetwork, Profile: CostProfile>(
        in graph: Graph, profile: Profile, direction: SearchDirection, extraCostMs: UInt32 = 0
    ) -> [(node: UInt32, initialCostMs: UInt32)] {
        searchSeeds(in: graph, profile: profile, direction: direction, extraCostMs: extraCostMs)
            .map { (node: $0.node, initialCostMs: $0.initialCostMs) }
    }

    /// ``searchSources(in:profile:direction:extraCostMs:)`` with the partial edge's length as
    /// each seed's ``SearchSeed/initialDecimeters``, so recorded distances include it.
    public func searchSeeds<Graph: StreetNetwork, Profile: CostProfile>(
        in graph: Graph, profile: Profile, direction: SearchDirection, extraCostMs: UInt32 = 0
    ) -> [SearchSeed] {
        graph.withView { view in
            var seeds: [SearchSeed] = []
            // Forward: leave the point toward B on A→B, or toward A on B→A.
            // Reverse: reach the point from A on A→B, or from B on B→A.
            func seed(_ edge: UInt32?, node: UInt32, share: Double) {
                guard let edge, let cost = profile.costMs(ofEdge: Int(edge), in: view) else { return }
                seeds.append(SearchSeed(
                    node: node,
                    initialCostMs: Self.add(Self.portion(cost, share), extraCostMs),
                    initialDecimeters: Self.portion(view.edgeLengthDecimeters[Int(edge)], share)
                ))
            }
            seed(forwardEdge, node: direction == .forward ? nodeB : nodeA, share: direction == .forward ? 1 - fraction : fraction)
            seed(backwardEdge, node: direction == .forward ? nodeA : nodeB, share: direction == .forward ? fraction : 1 - fraction)
            return seeds
        }
    }

    /// Costs for finishing a search at this point from the segment's end nodes (the mirror of
    /// ``searchSources(in:profile:direction:extraCostMs:)`` in the forward direction).
    public func searchTargets<Graph: StreetNetwork, Profile: CostProfile>(
        in graph: Graph, profile: Profile, extraCostMs: UInt32 = 0
    ) -> [(node: UInt32, finalCostMs: UInt32)] {
        searchSources(in: graph, profile: profile, direction: .reverse, extraCostMs: extraCostMs)
            .map { (node: $0.node, finalCostMs: $0.initialCostMs) }
    }

    /// The cost of going straight along the shared segment to `other`, if both points lie on the
    /// same segment and the profile may travel it in the needed direction.
    public func directCostMs<Graph: StreetNetwork, Profile: CostProfile>(
        to other: SnappedPoint, in graph: Graph, profile: Profile
    ) -> UInt32? {
        guard other.segment == segment else { return nil }
        let delta = other.fraction - fraction
        guard let edge = delta >= 0 ? forwardEdge : backwardEdge else { return nil }
        return graph.withView { view in
            profile.costMs(ofEdge: Int(edge), in: view).map { Self.portion($0, abs(delta)) }
        }
    }

    @inline(__always)
    static func portion(_ cost: UInt32, _ share: Double) -> UInt32 {
        UInt32((Double(cost) * min(1, max(0, share))).rounded())
    }

    @inline(__always)
    static func add(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? StreetCost.maxFinite : min(sum, StreetCost.maxFinite)
    }
}

/// How a one-to-many search reaches a snapped point: through one end of the point's segment,
/// then partway along it.
public struct PointArrival: Sendable, Equatable {
    /// Tree cost at ``node`` plus the partial edge to (or from) the point.
    public let costMs: UInt32
    /// The segment end the cheapest way passes through.
    public let node: UInt32
    /// The directed edge the partial run uses: from ``node`` into the point (forward tree), or
    /// from the point out to ``node`` (reverse tree).
    public let edge: UInt32
    /// True length in meters: the recorded distance at ``node`` (which, for a search seeded from a
    /// snapped point, starts with its partial first edge) plus the partial edge to the point.
    /// Present when the search ran with ``SearchOptions/recordDistances``.
    public let lengthMeters: Double?
}

extension ShortestPathTree {
    /// The cost of reaching `point` (forward tree) or of leaving it for the sources (reverse
    /// tree), finishing or starting partway along its segment. Does not consider a direct run
    /// along the source's own segment; see ``SnappedPoint/directCostMs(to:in:profile:)``.
    public func cost<Graph: StreetNetwork, Profile: CostProfile>(
        to point: SnappedPoint, in graph: Graph, profile: Profile
    ) -> UInt32? {
        arrival(at: point, in: graph, profile: profile)?.costMs
    }

    /// The cheapest way to reach `point` (forward tree) or to leave it for the sources (reverse
    /// tree), with its true length when the search recorded distances; `nil` if neither end of
    /// the point's segment was reached or the profile cannot use the needed direction. Ties go to
    /// the edge A→B. Like ``cost(to:in:profile:)``, ignores a direct run along a source's own
    /// segment.
    public func arrival<Graph: StreetNetwork, Profile: CostProfile>(
        at point: SnappedPoint, in graph: Graph, profile: Profile
    ) -> PointArrival? {
        graph.withView { view in
            var best: PointArrival?
            // Forward tree: arrive from A along A→B (share = fraction) or from B along B→A.
            // Reverse tree: leave along A→B toward B (share = 1 − fraction) or along B→A toward A.
            let forwardTree = direction == .forward
            let candidates: [(edge: UInt32?, node: UInt32, share: Double)] = [
                (point.forwardEdge, forwardTree ? point.nodeA : point.nodeB, forwardTree ? point.fraction : 1 - point.fraction),
                (point.backwardEdge, forwardTree ? point.nodeB : point.nodeA, forwardTree ? 1 - point.fraction : point.fraction),
            ]
            for candidate in candidates {
                guard let edge = candidate.edge, let base = cost(of: candidate.node),
                      let edgeCost = profile.costMs(ofEdge: Int(edge), in: view)
                else { continue }
                let total = SnappedPoint.add(base, SnappedPoint.portion(edgeCost, candidate.share))
                guard total < best?.costMs ?? .max else { continue }
                var length: Double?
                if let distances = distanceDecimeters, distances[Int(candidate.node)] != .max {
                    let partial = Double(view.edgeLengthDecimeters[Int(edge)]) * min(1, max(0, candidate.share))
                    length = (Double(distances[Int(candidate.node)]) + partial) / 10
                }
                best = PointArrival(costMs: total, node: candidate.node, edge: edge, lengthMeters: length)
            }
            return best
        }
    }
}

extension Dijkstra {
    /// A one-to-many search from (or, in reverse, toward) a snapped point. `extraCostMs` is added
    /// to every source, e.g. to charge for walking the snap distance. Recorded distances include
    /// the partial first edge.
    public static func oneToMany<Graph: StreetNetwork, Profile: CostProfile>(
        in graph: Graph,
        from point: SnappedPoint,
        profile: Profile,
        extraCostMs: UInt32 = 0,
        maxCostMs: UInt32 = StreetCost.maxFinite,
        direction: SearchDirection = .forward,
        options: SearchOptions = [],
        isCancelled: () -> Bool = { false }
    ) throws(CancellationError) -> ShortestPathTree {
        try oneToMany(
            in: graph,
            seeds: point.searchSeeds(in: graph, profile: profile, direction: direction, extraCostMs: extraCostMs),
            profile: profile, maxCostMs: maxCostMs, direction: direction, options: options, isCancelled: isCancelled
        )
    }
}

/// A point-to-point route between two snapped points.
public struct StreetRoute: Sendable, Equatable {
    public let origin: SnappedPoint
    public let destination: SnappedPoint
    public let costMs: UInt32
    /// True length in meters, including the partial first and last edges.
    public let lengthMeters: Double
    /// The directed edges traveled, in order. The first is entered at `origin` and the last left
    /// at `destination`; when both lie on one segment it is the only edge.
    public let edges: [UInt32]
    /// Nodes passed through, in order (empty when the route stays on one segment).
    public let nodes: [UInt32]
}

extension MappedStreetGraph {
    /// The nearest segment usable in `mode` within `maxDistanceMeters`, or `nil`. Distances
    /// compare to the millimeter; segments equally close go to the lowest segment index.
    public func snap(_ coordinate: Coordinate, mode: SnapMode = .walk, maxDistanceMeters: Double = 250) -> SnappedPoint? {
        snapCandidates(coordinate, mode: mode, maxDistanceMeters: maxDistanceMeters, limit: 1).first
    }

    /// The nearest segment that `profile` can travel in at least one direction.
    public func snap<Profile: CostProfile>(_ coordinate: Coordinate, profile: Profile, maxDistanceMeters: Double = 250) -> SnappedPoint? {
        nearestSegments(to: coordinate, maxDistanceMeters: maxDistanceMeters, limit: 1) { b, edges in
            edges.contains { edge in
                profile.costMs(
                    lengthDecimeters: b.edgeLengths[Int(edge)],
                    flags: EdgeFlags(rawValue: b.edgeFlags[Int(edge)]).intersection(.known),
                    bikeClass: BikeClass(rawValue: b.edgeClasses[Int(edge)])!  // Checked at open.
                ) != nil
            }
        }.first
    }

    /// Up to `limit` distinct segments usable in `mode`, nearest first (by distance to the
    /// millimeter, then segment index).
    public func snapCandidates(_ coordinate: Coordinate, mode: SnapMode = .walk, maxDistanceMeters: Double = 250, limit: Int) -> [SnappedPoint] {
        let required = mode.requiredFlags
        return nearestSegments(to: coordinate, maxDistanceMeters: maxDistanceMeters, limit: limit) { b, edges in
            edges.contains { !EdgeFlags(rawValue: b.edgeFlags[Int($0)]).isDisjoint(with: required) }
        }
    }

    /// A one-to-many search from (or toward) the nearest point `profile` can use. Returns `nil`
    /// when nothing usable lies within `maxSnapDistanceMeters`.
    public func shortestPathTree<Profile: CostProfile>(
        from coordinate: Coordinate,
        profile: Profile,
        maxCostMs: UInt32 = StreetCost.maxFinite,
        direction: SearchDirection = .forward,
        options: SearchOptions = [],
        maxSnapDistanceMeters: Double = 250,
        isCancelled: () -> Bool = { false }
    ) throws(CancellationError) -> (origin: SnappedPoint, tree: ShortestPathTree)? {
        guard let origin = snap(coordinate, profile: profile, maxDistanceMeters: maxSnapDistanceMeters) else { return nil }
        let tree = try Dijkstra.oneToMany(
            in: self, from: origin, profile: profile, maxCostMs: maxCostMs, direction: direction,
            options: options, isCancelled: isCancelled
        )
        return (origin, tree)
    }

    /// The cheapest route between two snapped points (A* with a haversine heuristic), or `nil`
    /// if none costs at most `maxCostMs`.
    public func route<Profile: CostProfile>(
        from origin: SnappedPoint,
        to destination: SnappedPoint,
        profile: Profile,
        heuristicFactor: Double = 0.8,
        maxCostMs: UInt32 = StreetCost.maxFinite,
        isCancelled: () -> Bool = { false }
    ) throws(CancellationError) -> StreetRoute? {
        let direct = origin.directCostMs(to: destination, in: self, profile: profile)
        let found = try AStar.search(
            in: self,
            sources: origin.searchSources(in: self, profile: profile, direction: .forward),
            targets: destination.searchTargets(in: self, profile: profile),
            goal: destination.coordinate,
            profile: profile,
            heuristicFactor: heuristicFactor,
            maxCostMs: min(maxCostMs, direct ?? .max),
            isCancelled: isCancelled
        )
        if let direct, direct <= maxCostMs, direct <= found?.totalCostMs ?? .max,
           let edge = destination.fraction >= origin.fraction ? origin.forwardEdge : origin.backwardEdge {
            let meters = Double(lengthDecimeters(ofEdge: Int(edge))) / 10 * abs(destination.fraction - origin.fraction)
            return StreetRoute(origin: origin, destination: destination, costMs: direct, lengthMeters: meters, edges: [edge], nodes: [])
        }
        guard let found else { return nil }
        let path = found.path
        guard let first = path.nodes.first, let last = path.nodes.last else { return nil }
        // The partial edges: from the origin to the path's first node, and from its last node on.
        // A seed at B came from A→B and one at A from B→A (see `searchSources`).
        let leavesTowardB = first == origin.nodeB && origin.forwardEdge != nil
        guard let startEdge = leavesTowardB ? origin.forwardEdge : origin.backwardEdge else { return nil }
        let startShare = leavesTowardB ? 1 - origin.fraction : origin.fraction
        let arrivesFromA = last == destination.nodeA && destination.forwardEdge != nil
        guard let endEdge = arrivesFromA ? destination.forwardEdge : destination.backwardEdge else { return nil }
        let endShare = arrivesFromA ? destination.fraction : 1 - destination.fraction
        let meters = Double(path.lengthDecimeters) / 10
            + Double(lengthDecimeters(ofEdge: Int(startEdge))) / 10 * startShare
            + Double(lengthDecimeters(ofEdge: Int(endEdge))) / 10 * endShare
        return StreetRoute(
            origin: origin, destination: destination, costMs: found.totalCostMs, lengthMeters: meters,
            edges: [startEdge] + path.edges + [endEdge], nodes: path.nodes
        )
    }

    /// The route's geometry from the origin's projected point to the destination's.
    public func shape(of route: StreetRoute) -> [Coordinate] {
        var points: [Coordinate] = []
        for (index, edge) in route.edges.enumerated() {
            var edgePoints = shape(ofEdge: Int(edge))
            let reversed = segment(ofEdge: Int(edge)).reversed
            if index == 0 {
                let along = reversed ? 1 - route.origin.fraction : route.origin.fraction
                edgePoints = Self.trim(edgePoints, from: along, to: route.edges.count == 1
                    ? (reversed ? 1 - route.destination.fraction : route.destination.fraction) : 1)
            } else if index == route.edges.count - 1 {
                let along = reversed ? 1 - route.destination.fraction : route.destination.fraction
                edgePoints = Self.trim(edgePoints, from: 0, to: along)
            }
            if !points.isEmpty, let first = edgePoints.first, first == points.last { edgePoints.removeFirst() }
            points += edgePoints
        }
        return points
    }

    /// The part of a polyline between two fractions of its length.
    static func trim(_ points: [Coordinate], from start: Double, to end: Double) -> [Coordinate] {
        guard points.count >= 2, end > start else { return points.isEmpty ? [] : [points[0]] }
        let projection = LocalProjection(origin: points[0])
        let planar = points.map(projection.project)
        var cumulative = [0.0]
        for i in 1..<planar.count { cumulative.append(cumulative[i - 1] + planar[i - 1].distance(to: planar[i])) }
        let total = cumulative.last!
        guard total > 0 else { return [points[0]] }
        func point(at distance: Double) -> Coordinate {
            var i = 1
            while i < planar.count - 1 && cumulative[i] < distance { i += 1 }
            let span = cumulative[i] - cumulative[i - 1]
            let t = span > 0 ? (distance - cumulative[i - 1]) / span : 0
            let a = planar[i - 1], b = planar[i]
            return projection.unproject(PlanarPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        let from = start * total, to = end * total
        var result = [point(at: from)]
        for i in 1..<planar.count - 1 where cumulative[i] > from && cumulative[i] < to { result.append(points[i]) }
        result.append(point(at: to))
        return result
    }

    // MARK: - Grid search

    /// Distinct segments passing `accept`, nearest first, found by scanning grid rings outward
    /// until no unscanned cell can hold anything closer.
    private func nearestSegments(
        to coordinate: Coordinate,
        maxDistanceMeters: Double,
        limit: Int,
        accept: (Buffers, [UInt32]) -> Bool
    ) -> [SnappedPoint] {
        guard limit > 0, segmentCount > 0, maxDistanceMeters >= 0 else { return [] }
        let grid = self.grid
        let (cellNS, cellEW) = grid.cellSizeMeters(atLatitude: coordinate.lat)
        let ringMeters = min(cellNS, cellEW)
        let maxRing = Int(min((maxDistanceMeters / ringMeters).rounded(.up) + 1, Double(max(grid.columns, grid.rows))))
        let center = grid.cell(containing: coordinate)
        let projection = LocalProjection(origin: coordinate)

        return withBuffers { b in
            var seen = Set<UInt32>()
            var found: [SnappedPoint] = []

            func consider(cellX x: Int, y: Int) {
                guard x >= 0, y >= 0, x < grid.columns, y < grid.rows else { return }
                let cell = y * grid.columns + x
                for slot in Int(b.cellOffsets[cell])..<Int(b.cellOffsets[cell + 1]) {
                    let s = b.cellSegments[slot]
                    guard seen.insert(s).inserted else { continue }
                    let (forward, backward) = b.edges(ofSegment: Int(s))
                    let edges = [forward, backward].compactMap { $0 }
                    guard accept(b, edges) else { continue }
                    guard let hit = project(segment: Int(s), buffers: b, projection: projection, maxDistance: maxDistanceMeters)
                    else { continue }
                    found.append(SnappedPoint(
                        segment: s,
                        nodeA: b.segmentNodes[2 * Int(s)],
                        nodeB: b.segmentNodes[2 * Int(s) + 1],
                        forwardEdge: forward,
                        backwardEdge: backward,
                        fraction: hit.fraction,
                        distanceMeters: hit.distance,
                        coordinate: hit.coordinate,
                        query: coordinate
                    ))
                }
            }

            for ring in 0...max(0, maxRing) {
                if ring == 0 {
                    consider(cellX: center.x, y: center.y)
                } else {
                    for x in (center.x - ring)...(center.x + ring) {
                        consider(cellX: x, y: center.y - ring)
                        consider(cellX: x, y: center.y + ring)
                    }
                    for y in (center.y - ring + 1)...(center.y + ring - 1) {
                        consider(cellX: center.x - ring, y: y)
                        consider(cellX: center.x + ring, y: y)
                    }
                }
                // Anything in rings beyond this one is at least `ring` cells away. Stop only once
                // no such segment can even tie, so the result never depends on the scan order.
                if found.count >= limit {
                    found.sort { Self.snapOrder($0) < Self.snapOrder($1) }
                    if Self.snapOrder(found[limit - 1]).millimeters < Self.millimeters(Double(ring) * ringMeters) { break }
                }
            }
            found.sort { Self.snapOrder($0) < Self.snapOrder($1) }
            return Array(found.prefix(limit))
        }
    }

    /// Candidates order by distance in whole millimeters, then by segment. Comparing the exact
    /// distances would let floating-point noise from the projection pick among segments that are
    /// equally close, such as every segment at a node the point lies on, and that noise differs
    /// between platforms. Integer keys keep the order a strict weak ordering (no epsilon).
    @inline(__always)
    static func snapOrder(_ point: SnappedPoint) -> (millimeters: Int64, segment: UInt32) {
        (millimeters(point.distanceMeters), point.segment)
    }

    /// Meters as whole millimeters, rounded to nearest; saturates (non-finite distances sort last).
    @inline(__always)
    static func millimeters(_ meters: Double) -> Int64 {
        let value = (meters * 1000).rounded()
        return value.isFinite && value < 9e15 ? Int64(value) : Int64(9e15)
    }

    /// The closest point of segment `s` to the projection's origin, if within `maxDistance`.
    private func project(
        segment s: Int, buffers b: Buffers, projection: LocalProjection, maxDistance: Double
    ) -> (fraction: Double, distance: Double, coordinate: Coordinate)? {
        let points = b.segmentShape(s).map(projection.project)
        let query = PlanarPoint(x: 0, y: 0)
        var best = (distance: Double.infinity, along: 0.0, point: points[0])
        var travelled = 0.0
        for i in 1..<points.count {
            let hit = query.projection(ontoSegmentFrom: points[i - 1], to: points[i])
            let length = points[i - 1].distance(to: points[i])
            if hit.distance < best.distance {
                best = (hit.distance, travelled + hit.fraction * length, hit.point)
            }
            travelled += length
        }
        guard best.distance <= maxDistance else { return nil }
        let fraction = travelled > 0 ? min(1, max(0, best.along / travelled)) : 0
        return (fraction, best.distance, projection.unproject(best.point))
    }
}
