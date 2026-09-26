import BRGeo

/// Per-edge attribute bits.
public struct EdgeFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Pedestrians may use the edge. Walking ignores one-ways, so a walkable street is stored as
    /// a walkable edge in each direction.
    public static let walk = EdgeFlags(rawValue: 1 << 0)
    /// Bikes may ride the edge from its source to its target ("bikeFwd"). One-ways set this on
    /// one direction only.
    public static let bikeForward = EdgeFlags(rawValue: 1 << 1)
    public static let stairs = EdgeFlags(rawValue: 1 << 2)
    public static let bridge = EdgeFlags(rawValue: 1 << 3)
    /// A path or plaza inside a park.
    public static let park = EdgeFlags(rawValue: 1 << 4)
    /// A short walking link synthesized from dropped sidewalks and crossings, joining a path
    /// that touched only sidewalks to the street centerline network. Instructions absorb it.
    public static let connector = EdgeFlags(rawValue: 1 << 5)
    /// Bikes may be walked here but not ridden (e.g. a connector along a sidewalk); bike
    /// profiles charge walking pace. Always set together with ``bikeForward``.
    public static let dismount = EdgeFlags(rawValue: 1 << 6)
}

/// Bike infrastructure on an edge, which scales its bike cost. Raw values are stored in artifacts.
public enum BikeClass: UInt8, CaseIterable, Sendable {
    /// Protected lane or off-street path.
    case protected = 0
    /// Painted lane.
    case painted = 1
    /// Shared lane or residential street.
    case shared = 2
    /// Arterial with no bike infrastructure.
    case arterial = 3
}

/// A directed street graph in compressed sparse row form, with a reverse index for searches
/// toward a destination.
///
/// The outgoing edges of node `u` are `forwardOffsets[u]..<forwardOffsets[u + 1]`, indexing the
/// parallel `edge…` arrays. The reverse index lists, for each node, the edges that end there:
/// `reverseOffsets[v]..<reverseOffsets[v + 1]` indexes `reverseSources` (the edge's source node)
/// and `reverseEdges` (the forward edge index, whose attributes apply).
public struct StreetGraph: Sendable {
    public let nodeCoordinates: [Coordinate]
    public let forwardOffsets: [UInt32]
    public let edgeTargets: [UInt32]
    public let edgeLengthDecimeters: [UInt32]
    public let edgeFlags: [EdgeFlags]
    public let edgeBikeClasses: [BikeClass]
    public let edgeNameIDs: [UInt32]
    public let reverseOffsets: [UInt32]
    public let reverseSources: [UInt32]
    public let reverseEdges: [UInt32]
    /// ``edgeBikeClasses`` as raw values, for ``StreetGraphView``.
    private let edgeBikeClassCodes: [UInt8]

    public enum ValidationError: Error, Equatable, Sendable {
        case tooLarge
        case offsetCount(expected: Int, actual: Int)
        case offsetsNotMonotonic(node: Int)
        case offsetsDoNotCoverEdges
        case edgeArrayLengthMismatch
        case targetOutOfRange(edge: Int)
    }

    /// Creates a graph from forward CSR arrays, validating them, and derives the reverse index.
    public init(
        nodeCoordinates: [Coordinate],
        forwardOffsets: [UInt32],
        edgeTargets: [UInt32],
        edgeLengthDecimeters: [UInt32],
        edgeFlags: [EdgeFlags],
        edgeBikeClasses: [BikeClass],
        edgeNameIDs: [UInt32]
    ) throws(ValidationError) {
        let nodeCount = nodeCoordinates.count, edgeCount = edgeTargets.count
        guard nodeCount < Int(UInt32.max), edgeCount < Int(UInt32.max) else { throw .tooLarge }
        guard forwardOffsets.count == nodeCount + 1 else {
            throw .offsetCount(expected: nodeCount + 1, actual: forwardOffsets.count)
        }
        guard forwardOffsets[0] == 0, Int(forwardOffsets[nodeCount]) == edgeCount else { throw .offsetsDoNotCoverEdges }
        for node in 0..<nodeCount where forwardOffsets[node] > forwardOffsets[node + 1] {
            throw .offsetsNotMonotonic(node: node)
        }
        guard [edgeLengthDecimeters.count, edgeFlags.count, edgeBikeClasses.count, edgeNameIDs.count]
            .allSatisfy({ $0 == edgeCount })
        else { throw .edgeArrayLengthMismatch }
        if let bad = edgeTargets.firstIndex(where: { Int($0) >= nodeCount }) { throw .targetOutOfRange(edge: bad) }

        self.init(
            uncheckedNodeCoordinates: nodeCoordinates,
            forwardOffsets: forwardOffsets,
            edgeTargets: edgeTargets,
            edgeLengthDecimeters: edgeLengthDecimeters,
            edgeFlags: edgeFlags,
            edgeBikeClasses: edgeBikeClasses,
            edgeNameIDs: edgeNameIDs
        )
    }

    init(
        uncheckedNodeCoordinates nodeCoordinates: [Coordinate],
        forwardOffsets: [UInt32],
        edgeTargets: [UInt32],
        edgeLengthDecimeters: [UInt32],
        edgeFlags: [EdgeFlags],
        edgeBikeClasses: [BikeClass],
        edgeNameIDs: [UInt32]
    ) {
        self.nodeCoordinates = nodeCoordinates
        self.forwardOffsets = forwardOffsets
        self.edgeTargets = edgeTargets
        self.edgeLengthDecimeters = edgeLengthDecimeters
        self.edgeFlags = edgeFlags
        self.edgeBikeClasses = edgeBikeClasses
        self.edgeNameIDs = edgeNameIDs
        edgeBikeClassCodes = edgeBikeClasses.map(\.rawValue)

        let nodeCount = nodeCoordinates.count
        var offsets = [UInt32](repeating: 0, count: nodeCount + 1)
        for target in edgeTargets { offsets[Int(target) + 1] += 1 }
        for node in 0..<nodeCount { offsets[node + 1] += offsets[node] }
        var cursor = offsets
        var sources = [UInt32](repeating: 0, count: edgeTargets.count)
        var edges = [UInt32](repeating: 0, count: edgeTargets.count)
        for node in 0..<nodeCount {
            for edge in Int(forwardOffsets[node])..<Int(forwardOffsets[node + 1]) {
                let target = Int(edgeTargets[edge])
                let slot = Int(cursor[target])
                sources[slot] = UInt32(node)
                edges[slot] = UInt32(edge)
                cursor[target] += 1
            }
        }
        reverseOffsets = offsets
        reverseSources = sources
        reverseEdges = edges
    }

    public var nodeCount: Int { nodeCoordinates.count }
    public var edgeCount: Int { edgeTargets.count }

    /// Forward edge indices leaving `node`.
    public func outgoingEdges(of node: UInt32) -> Range<Int> {
        Int(forwardOffsets[Int(node)])..<Int(forwardOffsets[Int(node) + 1])
    }

    /// Indices into ``reverseSources`` and ``reverseEdges`` for the edges entering `node`.
    public func incomingEdges(of node: UInt32) -> Range<Int> {
        Int(reverseOffsets[Int(node)])..<Int(reverseOffsets[Int(node) + 1])
    }

    /// The node an edge leaves from, by binary search over ``forwardOffsets``.
    public func sourceNode(ofEdge edge: Int) -> UInt32 {
        precondition(edge >= 0 && edge < edgeCount, "edge out of range")
        // The last node whose first edge is <= edge.
        var low = 0, high = nodeCount
        while low < high {
            let mid = (low + high) / 2
            if Int(forwardOffsets[mid + 1]) <= edge { low = mid + 1 } else { high = mid }
        }
        return UInt32(low)
    }
}

extension StreetGraph: StreetNetwork {
    public func withView<R>(_ body: (StreetGraphView) -> R) -> R {
        nodeCoordinates.withUnsafeBufferPointer { coordinates in
            forwardOffsets.withUnsafeBufferPointer { forwardOffsets in
                edgeTargets.withUnsafeBufferPointer { targets in
                    edgeLengthDecimeters.withUnsafeBufferPointer { lengths in
                        edgeFlags.withUnsafeBufferPointer { flags in
                            flags.withMemoryRebound(to: UInt16.self) { flagBits in
                                edgeBikeClassCodes.withUnsafeBufferPointer { classes in
                                    reverseOffsets.withUnsafeBufferPointer { reverseOffsets in
                                        reverseSources.withUnsafeBufferPointer { reverseSources in
                                            reverseEdges.withUnsafeBufferPointer { reverseEdges in
                                                body(StreetGraphView(
                                                    nodeCoordinates: coordinates,
                                                    forwardOffsets: forwardOffsets,
                                                    edgeTargets: targets,
                                                    edgeLengthDecimeters: lengths,
                                                    edgeFlagBits: flagBits,
                                                    edgeBikeClassCodes: classes,
                                                    reverseOffsets: reverseOffsets,
                                                    reverseSources: reverseSources,
                                                    reverseEdges: reverseEdges
                                                ))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
