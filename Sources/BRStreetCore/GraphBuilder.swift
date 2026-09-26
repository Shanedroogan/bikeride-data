import BRGeo

/// Accumulates nodes and edges in any order and produces a ``StreetGraph``.
public struct GraphBuilder: Sendable {
    /// Which directions of a street bikes may ride.
    public enum BikeAccess: Sendable {
        case none
        case both
        /// Only from the first node to the second (a one-way).
        case forwardOnly
        /// Only from the second node to the first.
        case backwardOnly
    }

    private struct PendingEdge: Sendable {
        var source: UInt32
        var target: UInt32
        var lengthDecimeters: UInt32
        var flags: EdgeFlags
        var bikeClass: BikeClass
        var nameID: UInt32
    }

    private var coordinates: [Coordinate] = []
    private var edges: [PendingEdge] = []

    public init() {}

    public var nodeCount: Int { coordinates.count }
    public var edgeCount: Int { edges.count }

    @discardableResult
    public mutating func addNode(at coordinate: Coordinate) -> UInt32 {
        precondition(coordinates.count < Int(UInt32.max), "too many nodes")
        coordinates.append(coordinate)
        return UInt32(coordinates.count - 1)
    }

    /// Adds one directed edge exactly as given.
    public mutating func addEdge(
        from source: UInt32,
        to target: UInt32,
        lengthDecimeters: UInt32,
        flags: EdgeFlags,
        bikeClass: BikeClass = .shared,
        nameID: UInt32 = 0
    ) {
        precondition(Int(source) < coordinates.count && Int(target) < coordinates.count, "unknown node")
        edges.append(PendingEdge(
            source: source, target: target, lengthDecimeters: lengthDecimeters,
            flags: flags, bikeClass: bikeClass, nameID: nameID
        ))
    }

    /// Adds a street between `a` and `b` as up to two directed edges. Walkable streets are
    /// walkable both ways; `bike` sets ``EdgeFlags/bikeForward`` per direction. `attributes`
    /// (stairs, bridge, park) apply to both. A direction nobody may use is not stored.
    public mutating func addStreet(
        between a: UInt32,
        and b: UInt32,
        lengthDecimeters: UInt32,
        walkable: Bool = true,
        bike: BikeAccess = .both,
        bikeClass: BikeClass = .shared,
        attributes: EdgeFlags = [],
        nameID: UInt32 = 0
    ) {
        var base = attributes.subtracting([.walk, .bikeForward])
        if walkable { base.insert(.walk) }
        var forward = base, backward = base
        if bike == .both || bike == .forwardOnly { forward.insert(.bikeForward) }
        if bike == .both || bike == .backwardOnly { backward.insert(.bikeForward) }
        let usable: EdgeFlags = [.walk, .bikeForward]
        if !forward.isDisjoint(with: usable) {
            addEdge(from: a, to: b, lengthDecimeters: lengthDecimeters, flags: forward, bikeClass: bikeClass, nameID: nameID)
        }
        if !backward.isDisjoint(with: usable) {
            addEdge(from: b, to: a, lengthDecimeters: lengthDecimeters, flags: backward, bikeClass: bikeClass, nameID: nameID)
        }
    }

    /// Sorts edges by source node (stable, so parallel edges keep insertion order).
    public func build() -> StreetGraph {
        let nodeCount = coordinates.count
        precondition(edges.count < Int(UInt32.max), "too many edges")
        var offsets = [UInt32](repeating: 0, count: nodeCount + 1)
        for edge in edges { offsets[Int(edge.source) + 1] += 1 }
        for node in 0..<nodeCount { offsets[node + 1] += offsets[node] }

        var order = [Int](repeating: 0, count: edges.count)
        var cursor = offsets
        for (index, edge) in edges.enumerated() {
            order[Int(cursor[Int(edge.source)])] = index
            cursor[Int(edge.source)] += 1
        }
        return StreetGraph(
            uncheckedNodeCoordinates: coordinates,
            forwardOffsets: offsets,
            edgeTargets: order.map { edges[$0].target },
            edgeLengthDecimeters: order.map { edges[$0].lengthDecimeters },
            edgeFlags: order.map { edges[$0].flags },
            edgeBikeClasses: order.map { edges[$0].bikeClass },
            edgeNameIDs: order.map { edges[$0].nameID }
        )
    }
}
