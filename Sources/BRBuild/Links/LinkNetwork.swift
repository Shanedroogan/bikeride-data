import BRCore
import BRGeo
import BRStreetCore
import BRTimetable
import Foundation

/// Tunables of the links compiler. Defaults are the plan of record (`docs/formats.md`, "links").
public struct LinksOptions: Sendable {
    public var walk = WalkProfile.standard
    /// A footpath p → q is listed when it takes at most this long plus the station access charged
    /// at its two ends (``accessSeconds`` of p's and of q's system), i.e. at most this much walking
    /// (8 min at 3.5 mph is about 750 m) between the two platforms' street access.
    public var maxFootpathWalkSeconds: UInt32 = 480
    /// In-station transfers (`transfers.txt`) quicker than this are raised to it, so changing
    /// platforms is never quicker than the same-stop subway change time. MTA lists 0 s for about
    /// 60 cross-platform and same-station rows.
    public var minTransferSeconds: UInt32 = 30
    /// Station links are listed when the walk between the station and a stop's access point
    /// (snap legs included, station access excluded) is at most this far at walking speed.
    public var stationLinkMaxWalkMeters = 350.0
    /// Station access charged once at every street↔platform transition.
    public var accessSeconds: [TransitSystem: UInt32] = [.subway: 120, .lirr: 240, .bus: 30, .ferry: 120, .path: 120]
    /// How far an access point may lie from the walk graph. LIRR stops with nothing within
    /// 150 m are ride-through only.
    public var maxSnapMeters: [TransitSystem: Double] = [.subway: 150, .bus: 150, .lirr: 150, .ferry: 250, .path: 150]
    /// Systems whose access points outside the service area (the streets graph's regions) get no
    /// street access, whatever lies nearby: PATH's Newark and Harrison stations are ride-through
    /// only (trains still run through them to Journal Square). Other systems' stops just past the
    /// city line (e.g. buses in Nassau or Yonkers) keep their access when a street is in reach.
    public var streetAccessOnlyInsideServiceArea: Set<TransitSystem> = [.path]
    /// Indoor or very short walks between stations of different systems, added as
    /// platform-to-platform transfers (no station access) between every routable platform of
    /// each end, both ways. The street walk still wins where it is quicker.
    public var fixedTransfers: [FixedTransfer] = FixedTransfer.pathSubway
    /// The rail bike hops, built when `stations.bin` is present.
    public var hops = HopOptions()
    public var threads = ProcessInfo.processInfo.activeProcessorCount

    public init() {}

    func access(_ system: TransitSystem) -> UInt32 { accessSeconds[system] ?? 0 }
    func snapLimit(_ system: TransitSystem) -> Double { maxSnapMeters[system] ?? 150 }
}

/// Where an access point joins the walk graph: partway along one street segment.
public struct LinkAnchor: Sendable, Equatable {
    public var nodeA: UInt32
    public var nodeB: UInt32
    /// The segment's walkable edge A→B, if any.
    public var forwardEdge: UInt32?
    /// The segment's walkable edge B→A, if any.
    public var backwardEdge: UInt32?
    /// Position along the segment by length: 0 at A, 1 at B.
    public var fraction: Double
    /// Straight-line meters from the access point to the segment, walked at walking speed.
    public var snapMeters: Double
    /// Equal for anchors on the same segment.
    public var segmentKey: UInt64

    public init(nodeA: UInt32, nodeB: UInt32, forwardEdge: UInt32?, backwardEdge: UInt32?,
                fraction: Double, snapMeters: Double, segmentKey: UInt64) {
        self.nodeA = nodeA
        self.nodeB = nodeB
        self.forwardEdge = forwardEdge
        self.backwardEdge = backwardEdge
        self.fraction = fraction
        self.snapMeters = snapMeters
        self.segmentKey = segmentKey
    }

    public init(_ point: SnappedPoint) {
        self.init(nodeA: point.nodeA, nodeB: point.nodeB, forwardEdge: point.forwardEdge, backwardEdge: point.backwardEdge,
                  fraction: point.fraction, snapMeters: point.distanceMeters, segmentKey: UInt64(point.segment))
    }
}

/// One place where riders pass between the street and a stop's platforms.
public struct StreetAccessPoint: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// A subway street entrance (a `stopKind` 2 stop).
        case entrance
        /// A station with no known entrance; its own coordinate stands in for one.
        case station
        /// A bus, LIRR or ferry stop, reached at its own position.
        case stop
    }

    public var kind: Kind
    public var system: TransitSystem
    /// Global index of the stop whose position this is.
    public var sourceStop: Int
    public var coordinate: Coordinate
    public var entry: Bool
    public var exit: Bool
    /// Station access at this transition, in seconds.
    public var accessSeconds: UInt32
    /// The stored snap (what the artifact records), when the point snapped.
    public var snap: StoredSnap?
    /// The same position as graph nodes and edges, derived from ``snap``.
    public var anchor: LinkAnchor?

    public init(kind: Kind, system: TransitSystem, sourceStop: Int, coordinate: Coordinate, entry: Bool, exit: Bool,
                accessSeconds: UInt32, snap: StoredSnap? = nil, anchor: LinkAnchor? = nil) {
        self.kind = kind
        self.system = system
        self.sourceStop = sourceStop
        self.coordinate = coordinate
        self.entry = entry
        self.exit = exit
        self.accessSeconds = accessSeconds
        self.snap = snap
        self.anchor = anchor
    }
}

/// A configured walk between two stations (or stops) of any systems, e.g. PATH ↔ subway
/// through the Oculus. Both ends are qualified ids (`P:place_WTC`, `S:E01`).
public struct FixedTransfer: Sendable, Hashable, Codable {
    public var from: StopID
    public var to: StopID
    public var seconds: UInt32

    public init(from: StopID, to: StopID, seconds: UInt32) {
        self.from = from
        self.to = to
        self.seconds = seconds
    }

    /// The plan's PATH↔subway minimums: WTC → 1 (WTC Cortlandt) about 4 min and → E (World
    /// Trade Center) about 6 min via the Oculus; 14th and 23rd St → the F/M about 3 min each;
    /// 33rd St → 34 St-Herald Sq (B D F M and N Q R W) about 4 min.
    public static let pathSubway: [FixedTransfer] = [
        FixedTransfer(from: "P:place_WTC", to: "S:138", seconds: 240),
        FixedTransfer(from: "P:place_WTC", to: "S:E01", seconds: 360),
        FixedTransfer(from: "P:place_14S", to: "S:D19", seconds: 180),
        FixedTransfer(from: "P:place_23S", to: "S:D18", seconds: 180),
        FixedTransfer(from: "P:place_33S", to: "S:D17", seconds: 240),
        FixedTransfer(from: "P:place_33S", to: "S:R17", seconds: 240),
    ]
}

/// A platform-to-platform walk inside a station complex, from `transfers.txt`.
public struct LinkTransfer: Sendable, Hashable {
    public var from: Int
    public var to: Int
    public var seconds: UInt32

    public init(from: Int, to: Int, seconds: UInt32) {
        self.from = from
        self.to = to
        self.seconds = seconds
    }
}

/// Everything the footpath and station-link searches need, over the global stop index.
public struct LinkNetwork: Sendable {
    /// Stops per system in ``BRTimetable/LinksFormat/systems`` order (0 for a system not linked).
    public var systemStopCounts: [Int]
    /// Per global stop: some pattern calls there.
    public var routable: [Bool]
    /// Per global stop: indices into ``accessPoints`` (routable stops only).
    public var stopAccess: [[Int]]
    public var accessPoints: [StreetAccessPoint]
    /// Deduplicated, `from ≠ to`, both routable.
    public var transfers: [LinkTransfer]

    public init(systemStopCounts: [Int], routable: [Bool], stopAccess: [[Int]], accessPoints: [StreetAccessPoint], transfers: [LinkTransfer]) {
        precondition(systemStopCounts.count == LinksFormat.systems.count, "one count per system")
        precondition(routable.count == systemStopCounts.reduce(0, +) && stopAccess.count == routable.count, "per-stop arrays differ in length")
        self.systemStopCounts = systemStopCounts
        self.routable = routable
        self.stopAccess = stopAccess
        self.accessPoints = accessPoints
        self.transfers = transfers
    }

    public var stopCount: Int { routable.count }

    public func stopBase(_ system: TransitSystem) -> Int {
        let slot = LinksFormat.systems.firstIndex(of: system)!
        return systemStopCounts[..<slot].reduce(0, +)
    }

    /// Whether an anchored access point lets riders into the stop from the street (`entry`) or
    /// out to it (`exit`).
    public func streetAccess(of stop: Int) -> (entry: Bool, exit: Bool) {
        var entry = false, exit = false
        for index in stopAccess[stop] where accessPoints[index].anchor != nil {
            entry = entry || accessPoints[index].entry
            exit = exit || accessPoints[index].exit
        }
        return (entry, exit)
    }
}

public struct LinkNetworkStats: Codable, Sendable, Equatable {
    public struct System: Codable, Sendable, Equatable {
        public var stops = 0
        public var routableStops = 0
        /// Distinct access points by kind (`entrance`, `station`, `stop`).
        public var accessPoints: [String: Int] = [:]
        /// Access points inside the service area (or of a system not limited to it) with no walkable
        /// street in reach.
        public var unsnappedAccessPoints = 0
        /// Access points left unsnapped by rule: outside the service area, of a system in
        /// ``LinksOptions/streetAccessOnlyInsideServiceArea``.
        public var accessPointsOutsideServiceArea = 0
        /// Routable stops no access point lets riders into (or out of) from the street.
        public var routableWithoutStreetEntry = 0
        public var routableWithoutStreetExit = 0
        /// GTFS ids of stations with no entrance of their own (their coordinate stands in).
        public var stationsWithoutEntrances: [String] = []
        /// `id name` of routable stops with no street access at all (ride-through only); at most
        /// 100. Stops ride-through by the service-area rule are listed apart, below.
        public var rideThroughOnly: [String] = []
        /// `id name` of routable stops that are ride-through only because every access point lies
        /// outside the service area (``LinksOptions/streetAccessOnlyInsideServiceArea``).
        public var rideThroughOutsideServiceArea: [String] = []
        public var transferRows = 0
        public var transferPairs = 0
        /// Rows not turned into walks: trip-to-trip, not possible, same stop, no platforms.
        public var transferRowsSkipped: [String: Int] = [:]
        public var transferRowsWithoutTime = 0
        /// Rows whose time was raised to ``LinksOptions/minTransferSeconds``.
        public var transferRowsRaisedToMinimum = 0

        public init() {}
    }

    public var systems: [String: System] = [:]
    public var snapMeters = Distribution()
    /// ``LinksOptions/fixedTransfers`` turned into platform pairs, and those whose ends were not
    /// found (or have no routable platform), as `from→to`.
    public var fixedTransferPairs = 0
    public var fixedTransfersUnresolved: [String] = []

    public init() {}
}

extension LinkNetwork {
    /// Builds the network from the five timetables and the streets graph: global stop numbering,
    /// each routable stop's access points (its station's entrances, else the station, else the stop
    /// itself) snapped to the walk graph at stored precision, and `transfers.txt` rows (parent- or
    /// stop-level, no trips) expanded to routable platform pairs.
    public static func make(
        timetables: [TransitSystem: Timetable], graph: MappedStreetGraph, options: LinksOptions
    ) -> (network: LinkNetwork, stats: LinkNetworkStats) {
        let counts = LinksFormat.systems.map { timetables[$0]?.stopCount ?? 0 }
        let total = counts.reduce(0, +)
        var routable = [Bool](repeating: false, count: total)
        var stopAccess = [[Int]](repeating: [], count: total)
        var accessPoints: [StreetAccessPoint] = []
        var transfers: [UInt64: UInt32] = [:] // from << 32 | to → seconds
        var stats = LinkNetworkStats()
        var snapMeters: [Double] = []
        let serviceArea = graph.serviceArea
        var outsideServiceArea = Set<Int>() // access points left unsnapped by the service-area rule

        var base = 0
        for (slot, system) in LinksFormat.systems.enumerated() {
            defer { base += counts[slot] }
            guard let timetable = timetables[system] else { continue }
            var systemStats = LinkNetworkStats.System()
            systemStats.stops = timetable.stopCount
            for stop in 0..<timetable.stopCount where !timetable.patterns(servingStop: stop).isEmpty {
                routable[base + stop] = true
            }
            systemStats.routableStops = (0..<timetable.stopCount).filter { routable[base + $0] }.count

            var pointIndex: [Int: Int] = [:] // global source stop → access point
            let accessSeconds = options.access(system)
            let onlyInsideServiceArea = options.streetAccessOnlyInsideServiceArea.contains(system)
            func point(_ kind: StreetAccessPoint.Kind, source: Int, access: StopAccess) -> Int {
                if let existing = pointIndex[base + source] { return existing }
                let c = timetable.stopCoordinate(source)
                let coordinate = Coordinate(lat: StreetsFormat.degrees(StreetsFormat.microdegrees(c.lat)),
                                            lon: StreetsFormat.degrees(StreetsFormat.microdegrees(c.lon)))
                var ap = StreetAccessPoint(kind: kind, system: system, sourceStop: base + source, coordinate: coordinate,
                                           entry: access.contains(.entry), exit: access.contains(.exit), accessSeconds: accessSeconds)
                let outside = onlyInsideServiceArea && !serviceArea.contains(coordinate)
                if !outside, let snapped = graph.snap(coordinate, mode: .walk, maxDistanceMeters: options.snapLimit(system)) {
                    let stored = StoredSnap(snapped)
                    // Rebuild from the stored values so every cost matches what the app will compute.
                    if let point = graph.snappedPoint(stored, query: coordinate) {
                        ap.snap = stored
                        ap.anchor = LinkAnchor(point)
                        snapMeters.append(stored.distanceMeters)
                    }
                }
                if outside {
                    systemStats.accessPointsOutsideServiceArea += 1
                    outsideServiceArea.insert(accessPoints.count)
                } else if ap.anchor == nil {
                    systemStats.unsnappedAccessPoints += 1
                }
                systemStats.accessPoints[kind.rawValue, default: 0] += 1
                accessPoints.append(ap)
                pointIndex[base + source] = accessPoints.count - 1
                return accessPoints.count - 1
            }

            var stationsWithoutEntrances = Set<Int>()
            for stop in 0..<timetable.stopCount where routable[base + stop] {
                var points: [Int] = []
                if let parent = timetable.stopParent(stop) {
                    let entrances = timetable.entrances(ofStation: parent)
                    if entrances.isEmpty {
                        points = [point(.station, source: parent, access: [.entry, .exit])]
                        stationsWithoutEntrances.insert(parent)
                    } else {
                        points = entrances.map { point(.entrance, source: $0, access: timetable.stopAccess($0)) }
                    }
                } else {
                    points = [point(.stop, source: stop, access: [.entry, .exit])]
                }
                stopAccess[base + stop] = points
            }
            systemStats.stationsWithoutEntrances = stationsWithoutEntrances.sorted().map { timetable.stopGTFSID($0) }

            // transfers.txt → platform pairs.
            func platforms(_ stop: Int) -> [Int] {
                if routable[base + stop] { return [stop] }
                guard timetable.stopKind(stop) == .station else { return [] }
                return timetable.children(ofStop: stop).map(Int.init).filter { routable[base + $0] }
            }
            for row in 0..<timetable.transferCount {
                let transfer = timetable.transfer(row)
                systemStats.transferRows += 1
                guard transfer.fromTrip == nil, transfer.toTrip == nil else {
                    systemStats.transferRowsSkipped["trip-specific", default: 0] += 1
                    continue
                }
                guard transfer.type != 3 else {
                    systemStats.transferRowsSkipped["not possible", default: 0] += 1
                    continue
                }
                let from = platforms(transfer.fromStop), to = platforms(transfer.toStop)
                guard !from.isEmpty, !to.isEmpty else {
                    systemStats.transferRowsSkipped["no routable platform", default: 0] += 1
                    continue
                }
                if from == to && from.count == 1 {
                    systemStats.transferRowsSkipped["same stop", default: 0] += 1
                    continue
                }
                if transfer.minTransferSeconds == nil { systemStats.transferRowsWithoutTime += 1 }
                if let listed = transfer.minTransferSeconds, UInt32(listed) < options.minTransferSeconds {
                    systemStats.transferRowsRaisedToMinimum += 1
                }
                for a in from {
                    for b in to where a != b {
                        let seconds = max(options.minTransferSeconds, transfer.minTransferSeconds.map(UInt32.init) ?? UInt32((
                            timetable.stopCoordinate(a).distance(to: timetable.stopCoordinate(b)) / options.walk.speedMetersPerSecond
                        ).rounded(.up)))
                        let key = UInt64(base + a) << 32 | UInt64(base + b)
                        transfers[key] = min(transfers[key] ?? .max, seconds)
                    }
                }
            }

            for stop in 0..<timetable.stopCount where routable[base + stop] {
                var entry = false, exit = false
                for index in stopAccess[base + stop] where accessPoints[index].anchor != nil {
                    entry = entry || accessPoints[index].entry
                    exit = exit || accessPoints[index].exit
                }
                if !entry { systemStats.routableWithoutStreetEntry += 1 }
                if !exit { systemStats.routableWithoutStreetExit += 1 }
                if !entry && !exit {
                    let label = "\(timetable.stopGTFSID(stop)) \(timetable.stopName(stop))"
                    if !stopAccess[base + stop].isEmpty && stopAccess[base + stop].allSatisfy(outsideServiceArea.contains) {
                        systemStats.rideThroughOutsideServiceArea.append(label)
                    } else if systemStats.rideThroughOnly.count < 100 {
                        systemStats.rideThroughOnly.append(label)
                    }
                }
            }
            stats.systems[system.linkReportName] = systemStats
        }

        // Configured cross-system walks → platform pairs, both ways.
        func globalPlatforms(_ id: StopID) -> [Int] {
            guard let system = id.system, let timetable = timetables[system],
                  let slot = LinksFormat.systems.firstIndex(of: system),
                  let stop = timetable.stop(gtfsID: String(id.gtfsID)) else { return [] }
            let base = counts[..<slot].reduce(0, +)
            if routable[base + stop] { return [base + stop] }
            return timetable.children(ofStop: stop).map { base + Int($0) }.filter { routable[$0] }
        }
        for fixed in options.fixedTransfers {
            let from = globalPlatforms(fixed.from), to = globalPlatforms(fixed.to)
            guard !from.isEmpty, !to.isEmpty else {
                stats.fixedTransfersUnresolved.append("\(fixed.from)→\(fixed.to)")
                continue
            }
            for a in from {
                for b in to where a != b {
                    for key in [UInt64(a) << 32 | UInt64(b), UInt64(b) << 32 | UInt64(a)] {
                        transfers[key] = min(transfers[key] ?? .max, fixed.seconds)
                        stats.fixedTransferPairs += 1
                    }
                }
            }
        }

        let transferList = transfers.map { LinkTransfer(from: Int($0.key >> 32), to: Int($0.key & 0xFFFF_FFFF), seconds: $0.value) }
            .sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        for (slot, system) in LinksFormat.systems.enumerated() where timetables[system] != nil {
            let low = counts[..<slot].reduce(0, +), high = low + counts[slot]
            stats.systems[system.linkReportName]?.transferPairs = transferList.filter { (low..<high).contains($0.from) }.count
        }
        stats.snapMeters = Distribution(snapMeters)
        return (LinkNetwork(systemStopCounts: counts, routable: routable, stopAccess: stopAccess,
                            accessPoints: accessPoints, transfers: transferList), stats)
    }
}

extension TransitSystem {
    /// Lowercase name used in reports: `subway`, `bus`, `lirr`, `ferry`, `path`.
    var linkReportName: String {
        switch self {
        case .subway: "subway"
        case .bus: "bus"
        case .lirr: "lirr"
        case .ferry: "ferry"
        case .path: "path"
        }
    }
}
