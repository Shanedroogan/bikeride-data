import BRStreetCore

/// A directed graph in CSR form with precomputed edge costs, viewed in place.
///
/// Edges leaving `u` are `offsets[u] ..< offsets[u + 1]`; `costs[e]` is milliseconds, or
/// `UInt32.max` for an edge the search may not use. `lengths` (decimeters) is needed only for
/// searches that record distances.
struct CSRGraph {
    let offsets: UnsafeBufferPointer<UInt32>
    let targets: UnsafeBufferPointer<UInt32>
    let costs: UnsafeBufferPointer<UInt32>
    let lengths: UnsafeBufferPointer<UInt32>?

    var nodeCount: Int { offsets.count - 1 }
    var edgeCount: Int { targets.count }

    static let unusable = UInt32.max
}

/// One worker's reusable one-to-many search, for build-time batches of thousands of searches.
///
/// It matches ``BRStreetCore/Dijkstra`` exactly: a binary heap of `(cost << 32 | node)` keys, so
/// equal costs pop in node order, edges relaxed in CSR order, and a node improved only by a
/// strictly lower cost. Given the same edge costs and seeds it records the same costs and the same
/// path lengths. Memory is allocated once; each search resets only the nodes it touched.
final class ScratchDijkstra {
    let nodeCount: Int
    let recordsDistances: Bool
    /// Milliseconds per node; `UInt32.max` when not reached. Valid after ``run``.
    let cost: UnsafeMutablePointer<UInt32>
    /// Decimeters along each reached node's cheapest path (with ``recordsDistances``).
    let distance: UnsafeMutablePointer<UInt32>
    /// Nodes reached by the last search, in first-reached order.
    private(set) var touched: UnsafeMutablePointer<UInt32>
    private(set) var touchedCount = 0
    private var heap: UnsafeMutablePointer<UInt64>
    private var heapCapacity: Int
    private var heapCount = 0

    static let unreached = UInt32.max

    init(nodeCount: Int, edgeCount: Int, recordsDistances: Bool) {
        self.nodeCount = nodeCount
        self.recordsDistances = recordsDistances
        cost = .allocate(capacity: max(1, nodeCount))
        cost.initialize(repeating: Self.unreached, count: max(1, nodeCount))
        distance = .allocate(capacity: recordsDistances ? max(1, nodeCount) : 1)
        distance.initialize(repeating: .max, count: recordsDistances ? max(1, nodeCount) : 1)
        touched = .allocate(capacity: max(1, nodeCount))
        heapCapacity = max(16, min(edgeCount + 16, 1 << 16))
        heap = .allocate(capacity: heapCapacity)
    }

    deinit {
        cost.deallocate()
        distance.deallocate()
        touched.deallocate()
        heap.deallocate()
    }

    /// The nodes reached by the last search.
    var reached: UnsafeBufferPointer<UInt32> { UnsafeBufferPointer(start: touched, count: touchedCount) }

    /// Costs from `seeds` to every node within `bound` ms. Nodes numbered `expandBelow` or higher
    /// are reached and costed but not expanded (their edges are not relaxed).
    func run(_ graph: CSRGraph, seeds: [SearchSeed], bound: UInt32, expandBelow: Int = .max) {
        precondition(graph.nodeCount == nodeCount, "graph and scratch sizes differ")
        precondition(!recordsDistances || graph.lengths != nil, "distances need edge lengths")
        for i in 0..<touchedCount {
            let node = Int(touched[i])
            cost[node] = Self.unreached
            if recordsDistances { distance[node] = .max }
        }
        touchedCount = 0
        heapCount = 0

        for seed in seeds {
            let node = Int(seed.node)
            precondition(node < nodeCount, "seed out of range")
            guard seed.initialCostMs <= bound, seed.initialCostMs < cost[node] else { continue }
            if cost[node] == Self.unreached { touch(node) }
            cost[node] = seed.initialCostMs
            if recordsDistances { distance[node] = seed.initialDecimeters }
            push(UInt64(seed.initialCostMs) << 32 | UInt64(node))
        }

        let offsets = graph.offsets, targets = graph.targets, costs = graph.costs
        let lengths = graph.lengths ?? UnsafeBufferPointer(start: nil, count: 0)
        let recording = recordsDistances
        while heapCount > 0 {
            let top = pop()
            let key = UInt32(truncatingIfNeeded: top >> 32)
            let u = Int(UInt32(truncatingIfNeeded: top))
            guard key == cost[u], u < expandBelow else { continue }
            let du = recording ? distance[u] : 0
            for edge in Int(offsets[u])..<Int(offsets[u + 1]) {
                let edgeCost = costs[edge]
                guard edgeCost != CSRGraph.unusable else { continue }
                let (candidate, overflow) = key.addingReportingOverflow(edgeCost)
                guard !overflow, candidate <= bound else { continue }
                let v = Int(targets[edge])
                guard candidate < cost[v] else { continue }
                if cost[v] == Self.unreached { touch(v) }
                cost[v] = candidate
                if recording { distance[v] = du &+ lengths[edge] }
                push(UInt64(candidate) << 32 | UInt64(v))
            }
        }
    }

    @inline(__always)
    private func touch(_ node: Int) {
        touched[touchedCount] = UInt32(node)
        touchedCount += 1
    }

    @inline(__always)
    private func push(_ value: UInt64) {
        if heapCount == heapCapacity {
            let grown = UnsafeMutablePointer<UInt64>.allocate(capacity: heapCapacity * 2)
            grown.moveInitialize(from: heap, count: heapCount)
            heap.deallocate()
            heap = grown
            heapCapacity *= 2
        }
        var child = heapCount
        heapCount += 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard value < heap[parent] else { break }
            heap[child] = heap[parent]
            child = parent
        }
        heap[child] = value
    }

    @inline(__always)
    private func pop() -> UInt64 {
        let top = heap[0]
        heapCount -= 1
        guard heapCount > 0 else { return top }
        let last = heap[heapCount]
        var parent = 0
        while true {
            var child = 2 * parent + 1
            guard child < heapCount else { break }
            if child + 1 < heapCount && heap[child + 1] < heap[child] { child += 1 }
            guard heap[child] < last else { break }
            heap[parent] = heap[child]
            parent = child
        }
        heap[parent] = last
        return top
    }
}

/// The partial-edge helpers of ``BRStreetCore/SnappedPoint``, repeated here so build-time searches
/// round exactly as the app's searches do.
enum PartialEdge {
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
