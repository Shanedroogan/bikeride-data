import BRGeo

/// A directed street graph that searches can run over: the in-memory ``StreetGraph`` or the
/// memory-mapped ``MappedStreetGraph``.
///
/// Both expose the same compressed-sparse-row arrays through ``withView(_:)``, so ``Dijkstra``
/// and ``AStar`` have one concrete implementation over ``StreetGraphView`` whatever the storage.
public protocol StreetNetwork: Sendable {
    var nodeCount: Int { get }
    var edgeCount: Int { get }

    /// Calls `body` with the graph's arrays viewed in place. The view's pointers are valid only
    /// inside `body` and must not escape it.
    func withView<R>(_ body: (StreetGraphView) -> R) -> R
}

extension StreetNetwork {
    public func coordinate(ofNode node: UInt32) -> Coordinate {
        withView { $0.coordinate(ofNode: Int(node)) }
    }

    /// The node an edge leaves from.
    public func sourceNode(ofEdge edge: Int) -> UInt32 {
        withView { $0.sourceNode(ofEdge: edge) }
    }
}

/// The arrays of a ``StreetNetwork``, viewed in place for the duration of one closure.
///
/// Edge `e` of node `u` is any `e` in `forwardOffsets[u]..<forwardOffsets[u + 1]`; its
/// attributes are `edgeTargets[e]`, `edgeLengthDecimeters[e]`, `edgeFlagBits[e]` (an
/// ``EdgeFlags`` raw value) and `edgeBikeClassCodes[e]` (a ``BikeClass`` raw value). The reverse
/// index lists the edges entering `v` at `reverseOffsets[v]..<reverseOffsets[v + 1]`, as their
/// source node (`reverseSources`) and forward edge index (`reverseEdges`).
///
/// A view trusts its arrays and checks nothing: offsets must be in range and never decrease,
/// targets and sources below the node count, and every class code a ``BikeClass`` raw value
/// (``bikeClass(ofEdge:)`` traps on any other). ``StreetGraph`` guarantees this by construction,
/// and ``MappedStreetGraph`` by its checks at open (the index checks only with `validate`).
public struct StreetGraphView {
    public let nodeCount: Int
    public let edgeCount: Int
    public let forwardOffsets: UnsafeBufferPointer<UInt32>
    public let edgeTargets: UnsafeBufferPointer<UInt32>
    public let edgeLengthDecimeters: UnsafeBufferPointer<UInt32>
    public let edgeFlagBits: UnsafeBufferPointer<UInt16>
    public let edgeBikeClassCodes: UnsafeBufferPointer<UInt8>
    public let reverseOffsets: UnsafeBufferPointer<UInt32>
    public let reverseSources: UnsafeBufferPointer<UInt32>
    public let reverseEdges: UnsafeBufferPointer<UInt32>

    private enum Coordinates {
        case degrees(UnsafeBufferPointer<Coordinate>)
        /// Latitude and longitude of each node, interleaved, in millionths of a degree.
        case microdegrees(UnsafeBufferPointer<Int32>)
    }

    private let coordinates: Coordinates

    /// A view whose node positions are ``Coordinate`` values.
    public init(
        nodeCoordinates: UnsafeBufferPointer<Coordinate>,
        forwardOffsets: UnsafeBufferPointer<UInt32>,
        edgeTargets: UnsafeBufferPointer<UInt32>,
        edgeLengthDecimeters: UnsafeBufferPointer<UInt32>,
        edgeFlagBits: UnsafeBufferPointer<UInt16>,
        edgeBikeClassCodes: UnsafeBufferPointer<UInt8>,
        reverseOffsets: UnsafeBufferPointer<UInt32>,
        reverseSources: UnsafeBufferPointer<UInt32>,
        reverseEdges: UnsafeBufferPointer<UInt32>
    ) {
        nodeCount = nodeCoordinates.count
        edgeCount = edgeTargets.count
        coordinates = .degrees(nodeCoordinates)
        self.forwardOffsets = forwardOffsets
        self.edgeTargets = edgeTargets
        self.edgeLengthDecimeters = edgeLengthDecimeters
        self.edgeFlagBits = edgeFlagBits
        self.edgeBikeClassCodes = edgeBikeClassCodes
        self.reverseOffsets = reverseOffsets
        self.reverseSources = reverseSources
        self.reverseEdges = reverseEdges
    }

    /// A view whose node positions are interleaved latitude/longitude microdegrees.
    public init(
        nodeMicrodegrees: UnsafeBufferPointer<Int32>,
        forwardOffsets: UnsafeBufferPointer<UInt32>,
        edgeTargets: UnsafeBufferPointer<UInt32>,
        edgeLengthDecimeters: UnsafeBufferPointer<UInt32>,
        edgeFlagBits: UnsafeBufferPointer<UInt16>,
        edgeBikeClassCodes: UnsafeBufferPointer<UInt8>,
        reverseOffsets: UnsafeBufferPointer<UInt32>,
        reverseSources: UnsafeBufferPointer<UInt32>,
        reverseEdges: UnsafeBufferPointer<UInt32>
    ) {
        nodeCount = nodeMicrodegrees.count / 2
        edgeCount = edgeTargets.count
        coordinates = .microdegrees(nodeMicrodegrees)
        self.forwardOffsets = forwardOffsets
        self.edgeTargets = edgeTargets
        self.edgeLengthDecimeters = edgeLengthDecimeters
        self.edgeFlagBits = edgeFlagBits
        self.edgeBikeClassCodes = edgeBikeClassCodes
        self.reverseOffsets = reverseOffsets
        self.reverseSources = reverseSources
        self.reverseEdges = reverseEdges
    }

    @inline(__always)
    public func coordinate(ofNode node: Int) -> Coordinate {
        switch coordinates {
        case .degrees(let degrees):
            return degrees[node]
        case .microdegrees(let micro):
            return Coordinate(lat: Double(micro[2 * node]) * 1e-6, lon: Double(micro[2 * node + 1]) * 1e-6)
        }
    }

    /// The edge's defined flags; undefined bits are ignored (``EdgeFlags/known``).
    @inline(__always)
    public func flags(ofEdge edge: Int) -> EdgeFlags {
        EdgeFlags(rawValue: edgeFlagBits[edge]).intersection(.known)
    }

    /// The edge's class. Traps on a code that isn't a ``BikeClass`` raw value (see the type's
    /// requirements).
    @inline(__always)
    public func bikeClass(ofEdge edge: Int) -> BikeClass {
        BikeClass(rawValue: edgeBikeClassCodes[edge])!
    }

    /// Forward edge indices leaving `node`.
    @inline(__always)
    public func outgoingEdges(of node: Int) -> Range<Int> {
        Int(forwardOffsets[node])..<Int(forwardOffsets[node + 1])
    }

    /// Indices into ``reverseSources`` and ``reverseEdges`` for the edges entering `node`.
    @inline(__always)
    public func incomingEdges(of node: Int) -> Range<Int> {
        Int(reverseOffsets[node])..<Int(reverseOffsets[node + 1])
    }

    /// The node an edge leaves from, by binary search over ``forwardOffsets``.
    public func sourceNode(ofEdge edge: Int) -> UInt32 {
        precondition(edge >= 0 && edge < edgeCount, "edge out of range")
        var low = 0, high = nodeCount
        while low < high {
            let mid = (low + high) / 2
            if Int(forwardOffsets[mid + 1]) <= edge { low = mid + 1 } else { high = mid }
        }
        return UInt32(low)
    }
}
