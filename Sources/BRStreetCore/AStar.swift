import BRGeo

public enum AStar {
    /// The best of a multi-source, multi-target search.
    public struct Result: Sendable, Equatable {
        /// Whole edges from the chosen source node to the chosen target node.
        public let path: StreetPath
        /// Source initial cost + ``path`` cost + the target's final cost.
        public let totalCostMs: UInt32
    }

    /// The cheapest path from `source` to `target`, or `nil` if none costs at most `maxCostMs`.
    ///
    /// The heuristic is `haversine(node, target) × heuristicFactor ÷ speed`. The result equals
    /// Dijkstra's whenever that never overestimates: edge lengths are at least the straight-line
    /// distance between their ends (true for real geometry) and `heuristicFactor` is at most the
    /// profile's cheapest cost per meter relative to cruising speed (0.8 covers walking and the
    /// default bike multipliers). `isCancelled` is polled every
    /// ``Dijkstra/cancellationCheckInterval`` pops.
    public static func shortestPath<Graph: StreetNetwork, Profile: CostProfile>(
        in graph: Graph,
        from source: UInt32,
        to target: UInt32,
        profile: Profile,
        heuristicFactor: Double = 0.8,
        maxCostMs: UInt32 = StreetCost.maxFinite,
        isCancelled: () -> Bool = { false }
    ) throws(CancellationError) -> StreetPath? {
        precondition(Int(source) < graph.nodeCount && Int(target) < graph.nodeCount, "node out of range")
        return try search(
            in: graph, sources: [(source, 0)], targets: [(target, 0)], goal: graph.coordinate(ofNode: target),
            profile: profile, heuristicFactor: heuristicFactor, maxCostMs: maxCostMs, isCancelled: isCancelled
        )?.path
    }

    /// The cheapest way from any source to any target, where each source starts at its initial
    /// cost and reaching a target adds its final cost; `nil` if nothing totals at most `maxCostMs`.
    ///
    /// Used to route between snapped points: the sources and targets are the ends of the snapped
    /// edges, weighted by the partial-edge costs, and `goal` is the destination coordinate. The
    /// result is optimal when `haversine(node, goal) × heuristicFactor ÷ speed` never exceeds the
    /// true remaining cost, which holds for the reasons given at
    /// ``shortestPath(in:from:to:profile:heuristicFactor:maxCostMs:isCancelled:)`` as long as each
    /// target's final cost is at least its straight-line share to `goal`.
    public static func search<Graph: StreetNetwork, Profile: CostProfile>(
        in graph: Graph,
        sources: [(node: UInt32, initialCostMs: UInt32)],
        targets: [(node: UInt32, finalCostMs: UInt32)],
        goal: Coordinate,
        profile: Profile,
        heuristicFactor: Double = 0.8,
        maxCostMs: UInt32 = StreetCost.maxFinite,
        isCancelled: () -> Bool = { false }
    ) throws(CancellationError) -> Result? {
        let outcome = graph.withView { view -> Swift.Result<Result?, CancellationError> in
            do throws(CancellationError) {
                return .success(try search(
                    view, sources: sources, targets: targets, goal: goal, profile: profile,
                    heuristicFactor: heuristicFactor, maxCostMs: maxCostMs, isCancelled: isCancelled
                ))
            } catch {
                return .failure(error)
            }
        }
        return try outcome.get()
    }

    private static func search<Profile: CostProfile>(
        _ view: StreetGraphView,
        sources: [(node: UInt32, initialCostMs: UInt32)],
        targets: [(node: UInt32, finalCostMs: UInt32)],
        goal: Coordinate,
        profile: Profile,
        heuristicFactor: Double,
        maxCostMs: UInt32,
        isCancelled: () -> Bool
    ) throws(CancellationError) -> Result? {
        precondition(heuristicFactor >= 0, "heuristicFactor must be non-negative")
        let nodeCount = view.nodeCount
        let bound = min(maxCostMs, StreetCost.maxFinite)
        let heuristicMsPerMeter = heuristicFactor * 1000 / profile.speedMetersPerSecond

        var finalCost: [UInt32: UInt32] = [:]
        for (node, cost) in targets {
            precondition(Int(node) < nodeCount, "target node out of range")
            finalCost[node] = min(finalCost[node] ?? .max, cost)
        }
        guard !finalCost.isEmpty else { return nil }

        var g = [UInt32](repeating: .max, count: nodeCount)
        var h = [UInt32](repeating: .max, count: nodeCount) // filled lazily
        var parentEdge = [UInt32](repeating: .max, count: nodeCount)
        var heap = PackedMinHeap()

        func heuristic(_ node: Int) -> UInt32 {
            if h[node] == .max {
                let meters = view.coordinate(ofNode: node).distance(to: goal)
                h[node] = min(UInt32((meters * heuristicMsPerMeter).rounded(.down)), StreetCost.maxFinite)
            }
            return h[node]
        }
        func priority(_ g: UInt32, _ h: UInt32) -> UInt64 { UInt64(g) + UInt64(h) }
        func key(_ priority: UInt64) -> UInt32 { UInt32(min(priority, UInt64(StreetCost.maxFinite))) }

        for (node, initial) in sources {
            precondition(Int(node) < nodeCount, "source node out of range")
            guard initial <= bound, initial < g[Int(node)] else { continue }
            g[Int(node)] = initial
            heap.push(key: key(priority(initial, heuristic(Int(node)))), node: node)
        }

        var best: (total: UInt64, node: UInt32)?
        let offsets = view.forwardOffsets, targetNodes = view.edgeTargets

        var untilCancellationCheck = Dijkstra.cancellationCheckInterval
        while let (popped, node) = heap.pop() {
            untilCancellationCheck -= 1
            if untilCancellationCheck == 0 {
                if isCancelled() { throw CancellationError() }
                untilCancellationCheck = Dijkstra.cancellationCheckInterval
            }
            let u = Int(node)
            let gu = g[u]
            guard popped == key(priority(gu, h[u])) else { continue } // stale entry
            if let best, UInt64(popped) >= best.total { break } // nothing left can do better
            if let final = finalCost[node] {
                let total = UInt64(gu) + UInt64(final)
                if total <= UInt64(bound), total < best?.total ?? .max { best = (total, node) }
            }
            for edge in Int(offsets[u])..<Int(offsets[u + 1]) {
                guard let edgeCost = profile.costMs(ofEdge: edge, in: view) else { continue }
                let v = Int(targetNodes[edge])
                let (candidate, overflow) = gu.addingReportingOverflow(edgeCost)
                guard !overflow, candidate < g[v] else { continue }
                let f = priority(candidate, heuristic(v))
                guard f <= UInt64(bound) else { continue } // cannot finish within the bound
                g[v] = candidate
                parentEdge[v] = UInt32(edge)
                heap.push(key: key(f), node: UInt32(v))
            }
        }
        guard let best else { return nil }

        var nodes = [best.node]
        var edges: [UInt32] = []
        var current = Int(best.node)
        while parentEdge[current] != .max {
            edges.append(parentEdge[current])
            current = Int(view.sourceNode(ofEdge: Int(parentEdge[current])))
            nodes.append(UInt32(current))
        }
        let path = StreetPath(nodes: nodes.reversed(), edges: edges.reversed(), costMs: g[Int(best.node)], view: view)
        return Result(path: path, totalCostMs: UInt32(best.total))
    }
}
