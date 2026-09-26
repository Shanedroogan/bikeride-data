public enum SearchDirection: Sendable {
    /// Costs from the sources to every node.
    case forward
    /// Costs from every node to the sources, over incoming edges.
    case reverse
}

public struct SearchOptions: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Keep each node's tree edge, for ``ShortestPathTree/path(for:in:)``.
    public static let recordParents = SearchOptions(rawValue: 1 << 0)
    /// Accumulate the true length of each node's cheapest path, independent of its cost.
    public static let recordDistances = SearchOptions(rawValue: 1 << 1)
}

/// The result of a one-to-many search: a dense per-node cost array.
public struct ShortestPathTree: Sendable {
    /// Marks nodes the search did not reach within its bound.
    public static let unreached = StreetCost.unreached

    public let direction: SearchDirection
    /// Milliseconds, including the winning source's initial cost; ``unreached`` if not reached.
    public let costMs: [UInt32]
    /// The forward edge index by which each node was reached (forward) or leaves toward the
    /// sources (reverse); `UInt32.max` for sources and unreached nodes. Present with
    /// ``SearchOptions/recordParents``.
    public let parentEdges: [UInt32]?
    /// Decimeters along each reached node's cheapest path, starting from the winning seed's
    /// ``SearchSeed/initialDecimeters``; `UInt32.max` if unreached. Present with
    /// ``SearchOptions/recordDistances``.
    public let distanceDecimeters: [UInt32]?

    public func cost(of node: UInt32) -> UInt32? {
        let cost = costMs[Int(node)]
        return cost == Self.unreached ? nil : cost
    }

    /// The tree path for `node`, in travel order: from its source (forward) or to its source
    /// (reverse). `nil` if `node` was not reached. Requires ``SearchOptions/recordParents``.
    public func path<Graph: StreetNetwork>(for node: UInt32, in graph: Graph) -> StreetPath? {
        guard let parentEdges else { preconditionFailure("search did not record parents") }
        guard let cost = cost(of: node) else { return nil }
        return graph.withView { view in
            var nodes = [node]
            var edges: [UInt32] = []
            var current = node
            while parentEdges[Int(current)] != UInt32.max {
                let edge = parentEdges[Int(current)]
                edges.append(edge)
                current = direction == .forward ? view.sourceNode(ofEdge: Int(edge)) : view.edgeTargets[Int(edge)]
                nodes.append(current)
            }
            if direction == .forward {
                nodes.reverse()
                edges.reverse()
            }
            return StreetPath(nodes: nodes, edges: edges, costMs: cost, view: view)
        }
    }
}

/// A route over the street graph.
public struct StreetPath: Sendable, Equatable {
    /// Visited nodes in travel order; one more than ``edges``.
    public let nodes: [UInt32]
    /// Forward edge indices in travel order.
    public let edges: [UInt32]
    public let costMs: UInt32
    /// True length, summed from edge lengths (not derived from cost).
    public let lengthDecimeters: UInt32

    init(nodes: [UInt32], edges: [UInt32], costMs: UInt32, view: StreetGraphView) {
        self.nodes = nodes
        self.edges = edges
        self.costMs = costMs
        lengthDecimeters = edges.reduce(0) { $0 &+ view.edgeLengthDecimeters[Int($1)] }
    }

    public var lengthMeters: Double { Double(lengthDecimeters) / 10 }
}

/// Where a search starts (or, in reverse, ends): a node, the cost already spent reaching it, and
/// the length already covered, which ``SearchOptions/recordDistances`` counts in. A search from a
/// snapped point seeds each end of its segment with the partial edge (see
/// ``SnappedPoint/searchSeeds(in:profile:direction:extraCostMs:)``).
public struct SearchSeed: Sendable, Equatable {
    public var node: UInt32
    public var initialCostMs: UInt32
    public var initialDecimeters: UInt32

    public init(node: UInt32, initialCostMs: UInt32 = 0, initialDecimeters: UInt32 = 0) {
        self.node = node
        self.initialCostMs = initialCostMs
        self.initialDecimeters = initialDecimeters
    }
}

public enum Dijkstra {
    /// Heap pops between calls to a search's `isCancelled`.
    public static let cancellationCheckInterval = 10_000

    /// Costs from many sources to every node (or, in reverse, from every node to many targets).
    ///
    /// Each source starts at its initial cost; a node's cost is the cheapest over all sources.
    /// Nodes whose cost would exceed `maxCostMs` stay ``ShortestPathTree/unreached``.
    /// `isCancelled` is polled every ``cancellationCheckInterval`` pops.
    public static func oneToMany<Graph: StreetNetwork, Profile: CostProfile>(
        in graph: Graph,
        sources: [(node: UInt32, initialCostMs: UInt32)],
        profile: Profile,
        maxCostMs: UInt32 = StreetCost.maxFinite,
        direction: SearchDirection = .forward,
        options: SearchOptions = [],
        isCancelled: () -> Bool = { false }
    ) throws(CancellationError) -> ShortestPathTree {
        try oneToMany(
            in: graph, seeds: sources.map { SearchSeed(node: $0.node, initialCostMs: $0.initialCostMs) },
            profile: profile, maxCostMs: maxCostMs, direction: direction, options: options, isCancelled: isCancelled
        )
    }

    /// ``oneToMany(in:sources:profile:maxCostMs:direction:options:isCancelled:)`` from seeds that
    /// may carry a length already covered.
    public static func oneToMany<Graph: StreetNetwork, Profile: CostProfile>(
        in graph: Graph,
        seeds: [SearchSeed],
        profile: Profile,
        maxCostMs: UInt32 = StreetCost.maxFinite,
        direction: SearchDirection = .forward,
        options: SearchOptions = [],
        isCancelled: () -> Bool = { false }
    ) throws(CancellationError) -> ShortestPathTree {
        let result = graph.withView { view -> Result<ShortestPathTree, CancellationError> in
            do throws(CancellationError) {
                return .success(try search(
                    view, seeds: seeds, profile: profile, maxCostMs: maxCostMs,
                    direction: direction, options: options, isCancelled: isCancelled
                ))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    /// ``oneToMany(in:sources:profile:maxCostMs:direction:options:isCancelled:)`` over a view,
    /// for callers already inside ``StreetNetwork/withView(_:)``.
    public static func search<Profile: CostProfile>(
        _ view: StreetGraphView,
        sources: [(node: UInt32, initialCostMs: UInt32)],
        profile: Profile,
        maxCostMs: UInt32 = StreetCost.maxFinite,
        direction: SearchDirection = .forward,
        options: SearchOptions = [],
        isCancelled: () -> Bool = { false }
    ) throws(CancellationError) -> ShortestPathTree {
        try search(
            view, seeds: sources.map { SearchSeed(node: $0.node, initialCostMs: $0.initialCostMs) },
            profile: profile, maxCostMs: maxCostMs, direction: direction, options: options, isCancelled: isCancelled
        )
    }

    /// ``oneToMany(in:seeds:profile:maxCostMs:direction:options:isCancelled:)`` over a view.
    public static func search<Profile: CostProfile>(
        _ view: StreetGraphView,
        seeds: [SearchSeed],
        profile: Profile,
        maxCostMs: UInt32 = StreetCost.maxFinite,
        direction: SearchDirection = .forward,
        options: SearchOptions = [],
        isCancelled: () -> Bool = { false }
    ) throws(CancellationError) -> ShortestPathTree {
        let nodeCount = view.nodeCount
        let bound = min(maxCostMs, StreetCost.maxFinite)
        let recordParents = options.contains(.recordParents)
        let recordDistances = options.contains(.recordDistances)

        var cost = [UInt32](repeating: ShortestPathTree.unreached, count: nodeCount)
        var parents = recordParents ? [UInt32](repeating: .max, count: nodeCount) : []
        var distances = recordDistances ? [UInt32](repeating: .max, count: nodeCount) : []
        var heap = PackedMinHeap(reservingCapacity: min(nodeCount, 1 << 16))

        for seed in seeds {
            let node = seed.node, initial = seed.initialCostMs
            precondition(Int(node) < nodeCount, "source node out of range")
            guard initial <= bound, initial < cost[Int(node)] else { continue }
            cost[Int(node)] = initial
            if recordDistances { distances[Int(node)] = seed.initialDecimeters }
            heap.push(key: initial, node: node)
        }

        let forwardOffsets = view.forwardOffsets, reverseOffsets = view.reverseOffsets
        let targets = view.edgeTargets, reverseSources = view.reverseSources, reverseEdges = view.reverseEdges
        let lengths = view.edgeLengthDecimeters

        var untilCancellationCheck = cancellationCheckInterval
        while let (key, node) = heap.pop() {
            untilCancellationCheck -= 1
            if untilCancellationCheck == 0 {
                if isCancelled() { throw CancellationError() }
                untilCancellationCheck = cancellationCheckInterval
            }
            let u = Int(node)
            guard key == cost[u] else { continue } // stale entry

            @inline(__always) func relax(edge: Int, to v: Int) {
                guard let edgeCost = profile.costMs(ofEdge: edge, in: view) else { return }
                let (candidate, overflow) = key.addingReportingOverflow(edgeCost)
                guard !overflow, candidate <= bound, candidate < cost[v] else { return }
                cost[v] = candidate
                if recordParents { parents[v] = UInt32(edge) }
                if recordDistances { distances[v] = distances[u] &+ lengths[edge] }
                heap.push(key: candidate, node: UInt32(v))
            }

            switch direction {
            case .forward:
                for edge in Int(forwardOffsets[u])..<Int(forwardOffsets[u + 1]) {
                    relax(edge: edge, to: Int(targets[edge]))
                }
            case .reverse:
                for slot in Int(reverseOffsets[u])..<Int(reverseOffsets[u + 1]) {
                    relax(edge: Int(reverseEdges[slot]), to: Int(reverseSources[slot]))
                }
            }
        }

        return ShortestPathTree(
            direction: direction,
            costMs: cost,
            parentEdges: recordParents ? parents : nil,
            distanceDecimeters: recordDistances ? distances : nil
        )
    }
}
