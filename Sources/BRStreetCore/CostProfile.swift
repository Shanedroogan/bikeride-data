/// How one travel mode prices street edges.
public protocol CostProfile: Sendable {
    /// Cruising speed. Also scales the A* heuristic.
    var speedMetersPerSecond: Double { get }

    /// Milliseconds to traverse an edge with these attributes, or `nil` if the mode may not use it.
    func costMs(lengthDecimeters: UInt32, flags: EdgeFlags, bikeClass: BikeClass) -> UInt32?
}

extension CostProfile {
    @inline(__always)
    public func costMs(ofEdge edge: Int, in graph: StreetGraph) -> UInt32? {
        costMs(
            lengthDecimeters: graph.edgeLengthDecimeters[edge],
            flags: graph.edgeFlags[edge],
            bikeClass: graph.edgeBikeClasses[edge]
        )
    }

    @inline(__always)
    public func costMs(ofEdge edge: Int, in view: StreetGraphView) -> UInt32? {
        costMs(
            lengthDecimeters: view.edgeLengthDecimeters[edge],
            flags: view.flags(ofEdge: edge),
            bikeClass: view.bikeClass(ofEdge: edge)
        )
    }

    /// The cost of one edge of any ``StreetNetwork``. Searches use the view overload instead.
    public func costMs<Graph: StreetNetwork>(ofEdge edge: Int, inNetwork graph: Graph) -> UInt32? {
        graph.withView { costMs(ofEdge: edge, in: $0) }
    }
}

/// Cost sentinels, in milliseconds.
public enum StreetCost {
    /// Marks a node a search did not reach.
    public static let unreached = UInt32.max
    /// The largest finite cost; edge and path costs saturate here.
    public static let maxFinite = UInt32.max - 1
}

let metersPerSecondPerMph = 0.44704

@inline(__always)
func roundedMilliseconds(_ ms: Double) -> UInt32 {
    ms >= Double(StreetCost.maxFinite) ? StreetCost.maxFinite : UInt32(ms.rounded())
}

/// Walking: requires ``EdgeFlags/walk``; stairs cost `stairsMultiplier` times their length.
public struct WalkProfile: CostProfile {
    /// 3.5 mph, the fixed walking speed.
    public static let standard = WalkProfile()

    public let speedMetersPerSecond: Double
    public let stairsMultiplier: Double
    private let msPerDecimeter: Double

    public init(speedMetersPerSecond: Double = 3.5 * 0.44704, stairsMultiplier: Double = 2) {
        precondition(speedMetersPerSecond > 0 && stairsMultiplier >= 1, "invalid walk profile")
        self.speedMetersPerSecond = speedMetersPerSecond
        self.stairsMultiplier = stairsMultiplier
        msPerDecimeter = 100 / speedMetersPerSecond
    }

    public func costMs(lengthDecimeters: UInt32, flags: EdgeFlags, bikeClass: BikeClass) -> UInt32? {
        guard flags.contains(.walk) else { return nil }
        let ms = Double(lengthDecimeters) * msPerDecimeter
        return roundedMilliseconds(flags.contains(.stairs) ? ms * stairsMultiplier : ms)
    }
}

/// Riding: requires ``EdgeFlags/bikeForward``; cost scales with the edge's ``BikeClass``.
/// Edges marked ``EdgeFlags/dismount`` are walked at `dismountSpeedMetersPerSecond` instead.
public struct BikeProfile: CostProfile {
    /// 10 mph, the e-bike default before speeds are learned.
    public static let eBike = BikeProfile(speedMetersPerSecond: 10 * metersPerSecondPerMph)
    /// 8 mph, the classic-bike default before speeds are learned.
    public static let classic = BikeProfile(speedMetersPerSecond: 8 * metersPerSecondPerMph)

    public let speedMetersPerSecond: Double
    public let multipliers: BikeClassMultipliers
    /// Pace when walking the bike along a ``EdgeFlags/dismount`` edge.
    public let dismountSpeedMetersPerSecond: Double
    /// Indexed by `BikeClass.rawValue`.
    private let msPerDecimeter: [Double]
    private let dismountMsPerDecimeter: Double

    public init(
        speedMetersPerSecond: Double,
        multipliers: BikeClassMultipliers = BikeClassMultipliers(),
        dismountSpeedMetersPerSecond: Double = 3 * 0.44704
    ) {
        precondition(speedMetersPerSecond > 0 && dismountSpeedMetersPerSecond > 0, "invalid bike speed")
        self.speedMetersPerSecond = speedMetersPerSecond
        self.multipliers = multipliers
        self.dismountSpeedMetersPerSecond = dismountSpeedMetersPerSecond
        msPerDecimeter = BikeClass.allCases.map { multipliers[$0] * 100 / speedMetersPerSecond }
        dismountMsPerDecimeter = 100 / dismountSpeedMetersPerSecond
    }

    public func costMs(lengthDecimeters: UInt32, flags: EdgeFlags, bikeClass: BikeClass) -> UInt32? {
        guard flags.contains(.bikeForward) else { return nil }
        if flags.contains(.dismount) { return roundedMilliseconds(Double(lengthDecimeters) * dismountMsPerDecimeter) }
        return roundedMilliseconds(Double(lengthDecimeters) * msPerDecimeter[Int(bikeClass.rawValue)])
    }
}

/// Bike cost per meter relative to riding at cruising speed.
public struct BikeClassMultipliers: Sendable, Equatable {
    public var protected: Double
    public var painted: Double
    public var shared: Double
    public var arterial: Double

    public init(protected: Double = 0.8, painted: Double = 0.9, shared: Double = 1.0, arterial: Double = 1.3) {
        self.protected = protected
        self.painted = painted
        self.shared = shared
        self.arterial = arterial
    }

    public subscript(bikeClass: BikeClass) -> Double {
        switch bikeClass {
        case .protected: protected
        case .painted: painted
        case .shared: shared
        case .arterial: arterial
        }
    }
}
