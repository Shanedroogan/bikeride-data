import BRGeo
import BRStreetCore
import Foundation

/// Tunables of the streets compiler. Defaults are the plan of record (`docs/osm-derivation.md`).
public struct StreetBuildOptions: Sendable {
    /// Douglas–Peucker tolerance for stored shape points. Lengths and bearings always use the
    /// full-resolution OSM geometry.
    public var shapeToleranceMeters = 1.0
    /// How far along an edge its entry and exit bearings are measured.
    public var bearingLookaheadMeters = 10.0
    /// Snap-grid cell size.
    public var snapCellMeters = 100.0
    /// The longest sidewalk walk a synthesized connector may stand for.
    public var connectorMaxMeters = 300.0
    /// The same limit for island connectors (step 2 of the connectors). Longer, because some
    /// islands are reached on foot only along a separately mapped bridge sidewalk: the Roosevelt
    /// Island Bridge carriageway is `foot=no`, and the island's connector along its sidewalk is
    /// 431 m.
    public var islandConnectorMaxMeters = 2000.0
    /// Drop small disconnected pieces: keep only connected components (walk ∪ bike) holding at
    /// least ``minimumComponentShare`` of the largest one's length (or, with
    /// ``keepLargestComponentPerRegion``, the largest inside some region), then restrict walking
    /// to walking components and riding to strongly connected riding components that pass the
    /// same test. Staten Island is its own component (the ferry is transit, not street), and so
    /// is New Jersey unless a bridge path joins it to the city (PATH and ferries are transit).
    public var keepLargestComponents = true
    public var minimumComponentShare = 0.05
    /// Also keep, for every region passed to ``StreetNetworkBuilder/finish(regions:)``, the
    /// component with the most length inside it, however small against the largest overall: each
    /// part of the service area keeps its own street network even when no street joins it to the
    /// rest (New Jersey reaches New York only by PATH and ferry). In New York this is the
    /// city-wide component for the four joined boroughs and Staten Island's own, which the share
    /// test keeps anyway.
    public var keepLargestComponentPerRegion = true

    public init() {}
}

/// Counts reported by a build, for `build/reports/streets.json` and the validation gate.
public struct StreetBuildStats: Sendable, Codable, Equatable {
    public var waysRead = 0
    public var waysKept = 0
    public var waysDropped: [String: Int] = [:]
    public var sidewalkNetworkWays = 0
    public var nodesWithoutLocation = 0
    /// Connectors synthesized along the dropped sidewalk network, and their total length.
    public var connectorsAdded = 0
    public var connectorMeters = 0.0
    /// Of ``connectorsAdded``, those that join an otherwise-too-small walkable component.
    public var islandConnectorsAdded = 0
    public var piecesBeforeMerge = 0
    public var segmentsAfterMerge = 0
    public var vertices = 0
    public var segments = 0
    public var directedEdges = 0
    public var walkEdges = 0
    public var bikeEdges = 0
    public var shapePoints = 0
    public var names = 0
    public var totalMeters = 0.0
    public var components = 0
    /// Length of each kept component, largest first.
    public var keptComponentMeters: [Double] = []
    /// Share of street length (before any component filtering) in the largest component, and in
    /// all kept components.
    public var largestComponentLengthShare = 1.0
    public var keptComponentsLengthShare = 1.0
    public var droppedComponentVertices = 0
    public var droppedComponentSegments = 0
    public var droppedComponentMeters = 0.0
    /// Walkable length whose walk access was removed because it is cut off from the largest
    /// walking component, and its share of all walkable length.
    public var walkIslandMeters = 0.0
    public var walkIslandShare = 0.0
    /// Rideable directed length whose bike access was removed because it lies outside the largest
    /// strongly connected riding component, and its share.
    public var bikeIslandMeters = 0.0
    public var bikeIslandShare = 0.0

    public init() {}
}

/// Streets compiled from OSM, ready to serialize (``StreetsArtifactWriter``).
///
/// Coordinates are interleaved latitude/longitude microdegrees. Per-direction arrays describe
/// the edge from A to B (`forward…`) and from B to A (`backward…`); flags without ``EdgeFlags/walk``
/// and ``EdgeFlags/bikeForward`` mean that edge is not stored.
public struct CompiledStreets: Sendable, Equatable {
    public var nodeCoordinates: [Int32] = []
    public var segmentNodes: [UInt32] = []
    public var segmentLengthDecimeters: [UInt32] = []
    public var forwardFlags: [UInt16] = []
    public var backwardFlags: [UInt16] = []
    public var forwardClasses: [UInt8] = []
    public var backwardClasses: [UInt8] = []
    public var segmentNameIDs: [UInt32] = []
    /// Two per segment: the bearing leaving A and the bearing arriving at B.
    public var segmentBearings: [UInt8] = []
    public var segmentShapeOffsets: [UInt32] = [0]
    public var shapePoints: [Int32] = []
    public var names: [String] = []
    public var nameKinds: [StreetNameKind] = []
    public var regions: [StreetRegion] = []

    public init() {}

    public var nodeCount: Int { nodeCoordinates.count / 2 }
    public var segmentCount: Int { segmentLengthDecimeters.count }
}

/// Builds the walk and bike street network from OSM ways (see `docs/osm-derivation.md`).
///
/// Feed every way with ``add(_:)`` in any order, then call ``finish(regions:)``. Memory is flat
/// arrays: one entry per kept way node plus per-way attributes, with names and rules interned.
public struct StreetNetworkBuilder {
    public let options: StreetBuildOptions
    private let mask: CityMask?
    private let parks: ParkIndex?
    private var tags = WayTags()
    public private(set) var stats = StreetBuildStats()

    // Kept ways.
    private var wayStart: [Int32] = [0]
    private var nodeIDs: [Int64] = []
    private var latE7: [Int32] = []
    private var lonE7: [Int32] = []
    private var wayRule: [UInt16] = []
    private var wayName: [Int32] = []
    private var rules: [WayRule] = []
    private var ruleIndex: [WayRule: UInt16] = [:]
    private var names: [NameKey] = []
    private var nameIndex: [NameKey: Int32] = [:]

    // The sidewalk network, used only to synthesize connectors.
    private var poolStart: [Int32] = [0]
    private var poolIDs: [Int64] = []
    private var poolLat: [Int32] = []
    private var poolLon: [Int32] = []

    struct NameKey: Hashable, Sendable {
        var text: String
        var kind: StreetNameKind
    }

    public init(options: StreetBuildOptions = StreetBuildOptions(), mask: CityMask? = nil, parks: ParkIndex? = nil) {
        self.options = options
        self.mask = mask
        self.parks = parks
    }

    // MARK: - Input

    public mutating func add(_ way: OPLWay) {
        stats.waysRead += 1
        tags.load(way)
        let verdict = StreetProfileRules.classify(tags, way)
        if case .drop(let reason) = verdict {
            drop(reason)
            return
        }
        guard way.nodeIDs.count >= 2 else {
            drop(.tooFewNodes)
            return
        }
        if let mask {
            let near = way.latE7.indices.contains { mask.contains(latE7: way.latE7[$0], lonE7: way.lonE7[$0]) }
            guard near else {
                drop(.outsideCity)
                return
            }
        }
        switch verdict {
        case .keep(let rule):
            let name = StreetProfileRules.name(tags, way).map { NameKey(text: $0.text, kind: $0.kind) }
            appendKept(ids: way.nodeIDs, lats: way.latE7, lons: way.lonE7, rule: rule, name: name)
        case .sidewalkNetwork:
            stats.sidewalkNetworkWays += 1
            poolIDs.append(contentsOf: way.nodeIDs)
            poolLat.append(contentsOf: way.latE7)
            poolLon.append(contentsOf: way.lonE7)
            poolStart.append(Int32(poolIDs.count))
        case .drop:
            break
        }
    }

    /// Records ways that had nodes without locations (reported by the OPL reader).
    public mutating func noteNodesWithoutLocation(_ count: Int) {
        stats.nodesWithoutLocation += count
    }

    private mutating func drop(_ reason: DropReason) {
        stats.waysDropped[reason.rawValue, default: 0] += 1
    }

    private mutating func appendKept<C: Collection>(
        ids: C, lats: some Collection<Int32>, lons: some Collection<Int32>, rule: WayRule, name: NameKey?
    ) where C.Element == Int64 {
        stats.waysKept += 1
        nodeIDs.append(contentsOf: ids)
        latE7.append(contentsOf: lats)
        lonE7.append(contentsOf: lons)
        wayStart.append(Int32(nodeIDs.count))
        wayRule.append(intern(rule))
        wayName.append(name.map { intern($0) } ?? -1)
    }

    private mutating func intern(_ rule: WayRule) -> UInt16 {
        if let index = ruleIndex[rule] { return index }
        let index = UInt16(rules.count)
        rules.append(rule)
        ruleIndex[rule] = index
        return index
    }

    private mutating func intern(_ name: NameKey) -> Int32 {
        if let index = nameIndex[name] { return index }
        let index = Int32(names.count)
        names.append(name)
        nameIndex[name] = index
        return index
    }

    // MARK: - Build

    public mutating func finish(regions: [StreetRegion]) -> CompiledStreets {
        let raster = options.keepLargestComponentPerRegion && !regions.isEmpty ? RegionRaster(regions: regions.map(\.area)) : nil
        addConnectors(regions: raster)
        var network = splitIntoPieces()
        network.mergeChains()
        stats.segmentsAfterMerge = network.pieceCount
        if options.keepLargestComponents {
            network.restrictToLargestComponents(minimumShare: options.minimumComponentShare, regions: raster, stats: &stats)
        }
        return network.compile(options: options, regions: regions, stats: &stats)
    }

    /// Synthesizes walking connectors along the dropped sidewalk network (sidewalks and
    /// crossings):
    ///
    /// 1. from every node where a path meets the sidewalk network but no street, to the nearest
    ///    street centerline node, so park and plaza paths that end at a sidewalk are reachable
    ///    (at most ``StreetBuildOptions/connectorMaxMeters``);
    /// 2. from every walkable component too small to survive the component filter that touches
    ///    the sidewalk network (a courtyard, a mews, a parking lot, an island whose bridge is
    ///    walkable only on its sidewalk), to the nearest node of a component large enough to
    ///    keep: one connector per such island (at most
    ///    ``StreetBuildOptions/islandConnectorMaxMeters``).
    private mutating func addConnectors(regions raster: RegionRaster?) {
        guard poolIDs.count > 0 else { return }
        // One index over every node of kept and sidewalk ways.
        var all = nodeIDs + poolIDs
        all.sort()
        var unique: [Int64] = []
        unique.reserveCapacity(all.count)
        for id in all where unique.last != id { unique.append(id) }
        all = []
        func index(_ id: Int64) -> Int32 {
            var low = 0, high = unique.count
            while low < high {
                let mid = (low + high) >> 1
                if unique[mid] < id { low = mid + 1 } else { high = mid }
            }
            return Int32(low)
        }

        // What each node touches: 1 = walkable street, 2 = walkable path, 4 = sidewalk network.
        var touches = [UInt8](repeating: 0, count: unique.count)
        var lat = [Int32](repeating: 0, count: unique.count), lon = lat
        // The unique index of every kept way node, in step with `nodeIDs`.
        var keptIndex = [Int32](repeating: 0, count: nodeIDs.count)
        for way in 0..<(wayStart.count - 1) {
            let rule = rules[Int(wayRule[way])]
            let bit: UInt8 = rule.walk ? (rule.pathLike ? 2 : 1) : 0
            for k in Int(wayStart[way])..<Int(wayStart[way + 1]) {
                let u = index(nodeIDs[k])
                keptIndex[k] = u
                touches[Int(u)] |= bit
                lat[Int(u)] = latE7[k]
                lon[Int(u)] = lonE7[k]
            }
        }
        var poolIndex = [Int32](repeating: 0, count: poolIDs.count)
        for k in poolIDs.indices {
            let u = index(poolIDs[k])
            poolIndex[k] = u
            touches[Int(u)] |= 4
            lat[Int(u)] = poolLat[k]
            lon[Int(u)] = poolLon[k]
        }

        // Undirected sidewalk graph over unique node indices.
        var degree = [Int32](repeating: 0, count: unique.count + 1)
        var links: [(Int32, Int32, Float)] = []
        for way in 0..<(poolStart.count - 1) {
            let first = Int(poolStart[way]), last = Int(poolStart[way + 1])
            guard last - first >= 2 else { continue }
            for k in (first + 1)..<last {
                let a = poolIndex[k - 1], b = poolIndex[k]
                guard a != b else { continue }
                let meters = Float(StreetGeometry.distanceMeters(latE7: lat[Int(a)], lonE7: lon[Int(a)], latE7: lat[Int(b)], lonE7: lon[Int(b)]))
                links.append((a, b, meters))
                degree[Int(a) + 1] += 1
                degree[Int(b) + 1] += 1
            }
        }
        for i in 0..<unique.count { degree[i + 1] += degree[i] }
        var cursor = degree
        var neighbor = [Int32](repeating: 0, count: links.count * 2)
        var weight = [Float](repeating: 0, count: links.count * 2)
        for (a, b, meters) in links {
            neighbor[Int(cursor[Int(a)])] = b; weight[Int(cursor[Int(a)])] = meters; cursor[Int(a)] += 1
            neighbor[Int(cursor[Int(b)])] = a; weight[Int(cursor[Int(b)])] = meters; cursor[Int(b)] += 1
        }
        links = []
        poolIDs = []; poolLat = []; poolLon = []; poolStart = [0]; poolIndex = []

        // Walkable, and bikes may be walked along it (as riders do between a path and the street).
        var connectorRule = WayRule()
        connectorRule.walk = true
        connectorRule.bikeForward = true
        connectorRule.bikeBackward = true
        connectorRule.classForward = .shared
        connectorRule.classBackward = .shared
        connectorRule.connector = true
        connectorRule.label = .sidewalk

        /// The shortest walk along the sidewalk graph from any of `starts` to a node passing
        /// `isTarget`, within `maxMeters`, as unique node indices from start to target.
        func sidewalkPath(from starts: [Int32], maxMeters: Float, isTarget: (Int32) -> Bool) -> (chain: [Int32], meters: Float)? {
            var distance: [Int32: Float] = [:]
            var parent: [Int32: Int32] = [:]
            var heap: [(Float, Int32)] = []
            for start in starts {
                distance[start] = 0
                Self.push(&heap, (0, start))
            }
            while let (d, u) = Self.popMin(&heap) {
                guard d == distance[u] else { continue }
                if isTarget(u) {
                    var chain = [u]
                    while let previous = parent[chain[chain.count - 1]] { chain.append(previous) }
                    return (chain.reversed(), d)
                }
                for slot in Int(degree[Int(u)])..<Int(degree[Int(u) + 1]) {
                    let v = neighbor[slot]
                    let candidate = d + weight[slot]
                    guard candidate <= maxMeters, candidate < distance[v] ?? .infinity else { continue }
                    distance[v] = candidate
                    parent[v] = u
                    Self.push(&heap, (candidate, v))
                }
            }
            return nil
        }
        func addConnector(_ chain: [Int32], meters: Float) {
            stats.connectorsAdded += 1
            stats.connectorMeters += Double(meters)
            appendKept(
                ids: chain.map { unique[Int($0)] },
                lats: chain.map { lat[Int($0)] },
                lons: chain.map { lon[Int($0)] },
                rule: connectorRule,
                name: nil
            )
            keptIndex.append(contentsOf: chain)
        }

        // 1. Paths that meet only sidewalks, to the nearest street node.
        for start in unique.indices where touches[start] & 4 != 0 && touches[start] & 2 != 0 && touches[start] & 1 == 0 {
            if let (chain, meters) = sidewalkPath(from: [Int32(start)], maxMeters: Float(options.connectorMaxMeters), isTarget: { touches[Int($0)] & 1 != 0 }) {
                addConnector(chain, meters: meters)
            }
        }

        // 2. Islands. Walkable components by length, connectors from step 1 included.
        var components = UnionFind(count: unique.count)
        let wayCount = wayStart.count - 1
        for way in 0..<wayCount where rules[Int(wayRule[way])].walk {
            for k in (Int(wayStart[way]) + 1)..<Int(wayStart[way + 1]) {
                components.union(Int(keptIndex[k - 1]), Int(keptIndex[k]))
            }
        }
        var componentMeters: [Int: Double] = [:]
        var regionMeters: [Int: [Int: Double]] = [:]
        for way in 0..<wayCount where rules[Int(wayRule[way])].walk {
            let first = Int(wayStart[way])
            var meters = 0.0
            for k in (first + 1)..<Int(wayStart[way + 1]) {
                meters += StreetGeometry.distanceMeters(latE7: latE7[k - 1], lonE7: lonE7[k - 1], latE7: latE7[k], lonE7: lonE7[k])
            }
            let root = components.find(Int(keptIndex[first]))
            componentMeters[root, default: 0] += meters
            if let region = raster?.region(latE7: latE7[first], lonE7: lonE7[first]) { regionMeters[region, default: [:]][root, default: 0] += meters }
        }
        guard !componentMeters.isEmpty else { return }
        let largeRoots = LargeComponents.keys(componentMeters, perRegion: regionMeters, minimumShare: options.minimumComponentShare)
        var large = [Bool](repeating: false, count: unique.count)
        var islands: [Int: [Int32]] = [:] // component root → its nodes on the sidewalk network
        for u in unique.indices where touches[u] & 3 != 0 {
            let root = components.find(u)
            large[u] = largeRoots.contains(root)
            if !large[u] && touches[u] & 4 != 0 { islands[root, default: []].append(Int32(u)) }
        }
        // In order of each island's first node, so builds are deterministic.
        for starts in islands.values.sorted(by: { $0[0] < $1[0] }) {
            if let (chain, meters) = sidewalkPath(from: starts, maxMeters: Float(options.islandConnectorMaxMeters), isTarget: { large[Int($0)] }) {
                addConnector(chain, meters: meters)
                stats.islandConnectorsAdded += 1
            }
        }
    }

    private static func push(_ heap: inout [(Float, Int32)], _ entry: (Float, Int32)) {
        heap.append(entry)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].0 < heap[parent].0 || (heap[child].0 == heap[parent].0 && heap[child].1 < heap[parent].1) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private static func popMin(_ heap: inout [(Float, Int32)]) -> (Float, Int32)? {
        guard !heap.isEmpty else { return nil }
        heap.swapAt(0, heap.count - 1)
        let top = heap.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1, right = left + 1
            var smallest = parent
            func less(_ a: Int, _ b: Int) -> Bool { heap[a].0 < heap[b].0 || (heap[a].0 == heap[b].0 && heap[a].1 < heap[b].1) }
            if left < heap.count && less(left, smallest) { smallest = left }
            if right < heap.count && less(right, smallest) { smallest = right }
            guard smallest != parent else { break }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }

    /// Cuts every kept way at its vertices: its end nodes and every node shared with another
    /// kept way (or repeated within it).
    private mutating func splitIntoPieces() -> PieceNetwork {
        // Unique kept nodes and how often ways reference them.
        var order = Array(0..<Int32(nodeIDs.count))
        order.sort { nodeIDs[Int($0)] < nodeIDs[Int($1)] || (nodeIDs[Int($0)] == nodeIDs[Int($1)] && $0 < $1) }
        var uniqueOf = [Int32](repeating: 0, count: nodeIDs.count)
        var uniqueIDs: [Int64] = []
        var uniqueLat: [Int32] = [], uniqueLon: [Int32] = []
        for k in order {
            let id = nodeIDs[Int(k)]
            if uniqueIDs.last != id {
                uniqueIDs.append(id)
                uniqueLat.append(latE7[Int(k)])
                uniqueLon.append(lonE7[Int(k)])
            }
            uniqueOf[Int(k)] = Int32(uniqueIDs.count - 1)
        }
        order = []
        var references = [UInt8](repeating: 0, count: uniqueIDs.count)
        var isVertex = [Bool](repeating: false, count: uniqueIDs.count)
        let wayCount = wayStart.count - 1
        for way in 0..<wayCount {
            let first = Int(wayStart[way]), last = Int(wayStart[way + 1])
            var previous: Int32 = -1
            for k in first..<last {
                let u = uniqueOf[k]
                if u == previous { continue } // a repeated reference is not a junction
                references[Int(u)] = references[Int(u)] &+ (references[Int(u)] < 255 ? 1 : 0)
                previous = u
            }
            isVertex[Int(uniqueOf[first])] = true
            isVertex[Int(uniqueOf[last - 1])] = true
        }
        for u in references.indices where references[u] >= 2 { isVertex[u] = true }

        var network = PieceNetwork(
            nodeIDs: uniqueIDs, latE7: uniqueLat, lonE7: uniqueLon, isVertex: isVertex,
            rules: rules, names: names, parks: parks
        )
        for way in 0..<wayCount {
            let first = Int(wayStart[way]), last = Int(wayStart[way + 1])
            var points: [Int32] = []
            for k in first..<last where points.last != uniqueOf[k] { points.append(uniqueOf[k]) }
            guard points.count >= 2 else { continue }
            var pieceStart = 0
            for i in 1..<points.count where isVertex[Int(points[i])] {
                network.addPiece(points: Array(points[pieceStart...i]), rule: Int(wayRule[way]), name: wayName[way])
                pieceStart = i
            }
        }
        stats.piecesBeforeMerge = network.pieceCount
        // Free the per-way input.
        nodeIDs = []; latE7 = []; lonE7 = []; wayStart = [0]; wayRule = []; wayName = []
        return network
    }
}

/// The component-keeping rule shared by the island connectors and the component filter.
enum LargeComponents {
    /// Keys whose length is at least `minimumShare` of the largest one's, plus each region's key
    /// with the most length inside that region (ties to the smaller key).
    static func keys<Key: Hashable & Comparable>(
        _ meters: [Key: Double], perRegion: [Int: [Key: Double]], minimumShare: Double
    ) -> Set<Key> {
        guard let biggest = meters.values.max() else { return [] }
        var kept = Set(meters.filter { $0.value >= biggest * minimumShare }.keys)
        for inside in perRegion.values {
            if let best = inside.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) { kept.insert(best.key) }
        }
        return kept
    }
}

// MARK: - Pieces, merging, components

/// The street network as undirected pieces between vertices, with full-resolution geometry.
struct PieceNetwork {
    let nodeIDs: [Int64]
    let latE7: [Int32]
    let lonE7: [Int32]
    var isVertex: [Bool]
    let rules: [WayRule]
    let names: [StreetNetworkBuilder.NameKey]
    let parks: ParkIndex?

    /// Oriented piece attributes: everything that must match for two pieces to merge.
    struct Attributes: Hashable {
        var walk: Bool
        var bikeForward: Bool
        var bikeBackward: Bool
        var classForward: BikeClass
        var classBackward: BikeClass
        var flags: EdgeFlags // stairs, bridge, park, connector
        var name: StreetBuilderName

        var reversed: Attributes {
            var r = self
            swap(&r.bikeForward, &r.bikeBackward)
            swap(&r.classForward, &r.classBackward)
            return r
        }

        var isUsable: Bool { walk || bikeForward || bikeBackward }
    }

    // Pieces (later segments): point lists into the unique node arrays.
    var pointStart: [Int32] = [0]
    var points: [Int32] = []
    var attributes: [Attributes] = []
    var lengths: [Double] = []

    var pieceCount: Int { attributes.count }

    init(nodeIDs: [Int64], latE7: [Int32], lonE7: [Int32], isVertex: [Bool], rules: [WayRule],
         names: [StreetNetworkBuilder.NameKey], parks: ParkIndex?) {
        self.nodeIDs = nodeIDs
        self.latE7 = latE7
        self.lonE7 = lonE7
        self.isVertex = isVertex
        self.rules = rules
        self.names = names
        self.parks = parks
    }

    mutating func addPiece(points piecePoints: [Int32], rule ruleIndex: Int, name: Int32) {
        let rule = rules[ruleIndex]
        var length = 0.0
        var cumulative = [0.0]
        for i in 1..<piecePoints.count {
            let a = Int(piecePoints[i - 1]), b = Int(piecePoints[i])
            length += StreetGeometry.distanceMeters(latE7: latE7[a], lonE7: lonE7[a], latE7: latE7[b], lonE7: lonE7[b])
            cumulative.append(length)
        }
        var inPark = false
        if rule.pathLike, let parks {
            // The point halfway along the piece.
            let half = length / 2
            var i = 1
            while i < piecePoints.count - 1 && cumulative[i] < half { i += 1 }
            let a = Int(piecePoints[i - 1]), b = Int(piecePoints[i])
            let span = cumulative[i] - cumulative[i - 1]
            let t = span > 0 ? (half - cumulative[i - 1]) / span : 0
            let lat = (Double(latE7[a]) + (Double(latE7[b]) - Double(latE7[a])) * t) * 1e-7
            let lon = (Double(lonE7[a]) + (Double(lonE7[b]) - Double(lonE7[a])) * t) * 1e-7
            inPark = parks.contains(Coordinate(lat: lat, lon: lon))
        }
        var flags: EdgeFlags = []
        if rule.stairs { flags.insert(.stairs) }
        if rule.bridge { flags.insert(.bridge) }
        if inPark { flags.insert(.park) }
        if rule.connector { flags.formUnion([.connector, .dismount]) }
        let label = inPark ? rule.label.inPark : rule.label
        let pieceName: StreetBuilderName = name >= 0
            ? .named(names[Int(name)].text, names[Int(name)].kind)
            : .derived(label)
        attributes.append(Attributes(
            walk: rule.walk, bikeForward: rule.bikeForward, bikeBackward: rule.bikeBackward,
            classForward: rule.classForward, classBackward: rule.classBackward, flags: flags, name: pieceName
        ))
        points.append(contentsOf: piecePoints)
        pointStart.append(Int32(points.count))
        lengths.append(length)
    }

    func first(_ piece: Int) -> Int32 { points[Int(pointStart[piece])] }
    func last(_ piece: Int) -> Int32 { points[Int(pointStart[piece + 1]) - 1] }

    /// Incidence lists: for each node, the (piece, end) pairs touching it; end 0 = start.
    func incidence() -> (offsets: [Int32], entries: [(piece: Int32, end: UInt8)]) {
        var offsets = [Int32](repeating: 0, count: nodeIDs.count + 1)
        for piece in 0..<pieceCount {
            offsets[Int(first(piece)) + 1] += 1
            offsets[Int(last(piece)) + 1] += 1
        }
        for i in 0..<nodeIDs.count { offsets[i + 1] += offsets[i] }
        var cursor = offsets
        var entries = [(piece: Int32, end: UInt8)](repeating: (0, 0), count: pieceCount * 2)
        for piece in 0..<pieceCount {
            let a = Int(first(piece)), b = Int(last(piece))
            entries[Int(cursor[a])] = (Int32(piece), 0); cursor[a] += 1
            entries[Int(cursor[b])] = (Int32(piece), 1); cursor[b] += 1
        }
        return (offsets, entries)
    }

    /// Joins chains of pieces through vertices that only continue one street with identical
    /// attributes (degree 2, same profile, flags and name), so each segment runs between
    /// junctions or attribute changes.
    mutating func mergeChains() {
        let (offsets, entries) = incidence()
        var mergeable = [Bool](repeating: false, count: nodeIDs.count)
        for v in 0..<nodeIDs.count where isVertex[v] && offsets[v + 1] - offsets[v] == 2 {
            let e1 = entries[Int(offsets[v])], e2 = entries[Int(offsets[v]) + 1]
            guard e1.piece != e2.piece else { continue }
            // Orient p1 to end at v and p2 to start at v.
            let a1 = e1.end == 1 ? attributes[Int(e1.piece)] : attributes[Int(e1.piece)].reversed
            let a2 = e2.end == 0 ? attributes[Int(e2.piece)] : attributes[Int(e2.piece)].reversed
            mergeable[v] = a1 == a2
        }

        var consumed = [Bool](repeating: false, count: pieceCount)
        var newStart: [Int32] = [0], newPoints: [Int32] = [], newAttributes: [Attributes] = [], newLengths: [Double] = []

        func appendChain(from piece: Int, reversed: Bool) {
            var chainPoints: [Int32] = []
            var length = 0.0
            let attrs = reversed ? attributes[piece].reversed : attributes[piece]
            var current = piece, currentReversed = reversed
            while true {
                consumed[current] = true
                let range = Int(pointStart[current])..<Int(pointStart[current + 1])
                let piecePoints = currentReversed ? Array(points[range].reversed()) : Array(points[range])
                chainPoints += chainPoints.isEmpty ? piecePoints : Array(piecePoints.dropFirst())
                length += lengths[current]
                let end = Int(piecePoints[piecePoints.count - 1])
                guard mergeable[end] else { break }
                // The other piece at `end`.
                let e1 = entries[Int(offsets[end])], e2 = entries[Int(offsets[end]) + 1]
                let next = Int(e1.piece) == current ? e2 : e1
                guard !consumed[Int(next.piece)] else { break }
                current = Int(next.piece)
                currentReversed = next.end == 1
            }
            newPoints += chainPoints
            newStart.append(Int32(newPoints.count))
            newAttributes.append(attrs)
            newLengths.append(length)
        }

        for v in 0..<nodeIDs.count where isVertex[v] && !mergeable[v] {
            for slot in Int(offsets[v])..<Int(offsets[v + 1]) {
                let (piece, end) = entries[slot]
                guard !consumed[Int(piece)] else { continue }
                appendChain(from: Int(piece), reversed: end == 1)
            }
        }
        // Whatever remains is a loop through mergeable vertices only: anchor it at its start.
        for piece in 0..<pieceCount where !consumed[piece] {
            mergeable[Int(first(piece))] = false
            appendChain(from: piece, reversed: false)
        }
        for v in 0..<nodeIDs.count where isVertex[v] && mergeable[v] { isVertex[v] = false }
        pointStart = newStart
        points = newPoints
        attributes = newAttributes
        lengths = newLengths
    }

    /// Keeps the large connected components, then removes walk access outside the large walking
    /// components and bike access outside the large strongly connected riding components. A
    /// component is large when it holds at least `minimumShare` of the biggest one's length, or
    /// (given `regions`) has the most length inside some region: see ``LargeComponents``.
    mutating func restrictToLargestComponents(minimumShare: Double, regions raster: RegionRaster?, stats: inout StreetBuildStats) {
        let totalMeters = lengths.reduce(0, +)
        // Each piece is counted in the region of its first node (−1: outside every region).
        let pieceRegion: [Int16] = (0..<pieceCount).map { piece in
            let u = Int(first(piece))
            return Int16(raster?.region(latE7: latE7[u], lonE7: lonE7[u]) ?? -1)
        }
        /// Sums piece lengths per key, overall and per region, for the pieces `key` assigns one.
        func measure<Key: Hashable & Comparable>(_ key: (Int) -> Key?) -> (meters: [Key: Double], perRegion: [Int: [Key: Double]]) {
            var meters: [Key: Double] = [:], perRegion: [Int: [Key: Double]] = [:]
            for piece in 0..<pieceCount {
                guard let k = key(piece) else { continue }
                meters[k, default: 0] += lengths[piece]
                if pieceRegion[piece] >= 0 { perRegion[Int(pieceRegion[piece]), default: [:]][k, default: 0] += lengths[piece] }
            }
            return (meters, perRegion)
        }
        func largeRoots<Key: Hashable & Comparable>(_ measured: (meters: [Key: Double], perRegion: [Int: [Key: Double]])) -> Set<Key> {
            LargeComponents.keys(measured.meters, perRegion: measured.perRegion, minimumShare: minimumShare)
        }

        // 1. Components over all usable pieces.
        var components = UnionFind(count: nodeIDs.count)
        for piece in 0..<pieceCount where attributes[piece].isUsable {
            components.union(Int(first(piece)), Int(last(piece)))
        }
        let measured = measure { attributes[$0].isUsable ? components.find(Int(first($0))) : nil }
        let componentMeters = measured.meters
        stats.components = componentMeters.count
        let keptRoots = largeRoots(measured)
        let kept = keptRoots.map { componentMeters[$0] ?? 0 }.sorted(by: >)
        stats.keptComponentMeters = kept
        stats.largestComponentLengthShare = totalMeters > 0 ? (kept.first ?? 0) / totalMeters : 1
        stats.keptComponentsLengthShare = totalMeters > 0 ? kept.reduce(0, +) / totalMeters : 1
        var keep = [Bool](repeating: false, count: pieceCount)
        for piece in 0..<pieceCount where attributes[piece].isUsable {
            keep[piece] = keptRoots.contains(components.find(Int(first(piece))))
            if !keep[piece] {
                stats.droppedComponentSegments += 1
                stats.droppedComponentMeters += lengths[piece]
            }
        }
        var droppedVertices = Set<Int32>()
        for piece in 0..<pieceCount where !keep[piece] && attributes[piece].isUsable {
            droppedVertices.insert(first(piece))
            droppedVertices.insert(last(piece))
        }
        stats.droppedComponentVertices = droppedVertices.count

        // 2. Walking: the large walking components.
        var walking = UnionFind(count: nodeIDs.count)
        for piece in 0..<pieceCount where keep[piece] && attributes[piece].walk {
            walking.union(Int(first(piece)), Int(last(piece)))
        }
        let walkMeasured = measure { keep[$0] && attributes[$0].walk ? walking.find(Int(first($0))) : nil }
        let allWalkMeters = walkMeasured.meters.values.reduce(0, +)
        let walkRoots = largeRoots(walkMeasured)
        for piece in 0..<pieceCount where keep[piece] && attributes[piece].walk
            && !walkRoots.contains(walking.find(Int(first(piece)))) {
            attributes[piece].walk = false
            stats.walkIslandMeters += lengths[piece]
        }
        stats.walkIslandShare = allWalkMeters > 0 ? stats.walkIslandMeters / allWalkMeters : 0

        // 3. Riding: the large strongly connected components of the directed bike graph.
        var arcs: [(Int32, Int32)] = []
        var allBikeMeters = 0.0
        for piece in 0..<pieceCount where keep[piece] {
            let a = first(piece), b = last(piece)
            if attributes[piece].bikeForward { arcs.append((a, b)); allBikeMeters += lengths[piece] }
            if attributes[piece].bikeBackward { arcs.append((b, a)); allBikeMeters += lengths[piece] }
        }
        let scc = StronglyConnected.components(nodeCount: nodeIDs.count, arcs: arcs)
        let bikeRoots = largeRoots(measure { piece -> Int32? in
            let a = Int(first(piece)), b = Int(last(piece))
            guard keep[piece], attributes[piece].bikeForward || attributes[piece].bikeBackward, scc[a] == scc[b], scc[a] >= 0 else { return nil }
            return scc[a]
        })
        for piece in 0..<pieceCount where keep[piece] {
            let a = Int(first(piece)), b = Int(last(piece))
            let inside = scc[a] == scc[b] && bikeRoots.contains(scc[a])
            if !inside {
                if attributes[piece].bikeForward { stats.bikeIslandMeters += lengths[piece] }
                if attributes[piece].bikeBackward { stats.bikeIslandMeters += lengths[piece] }
                attributes[piece].bikeForward = false
                attributes[piece].bikeBackward = false
            }
        }
        stats.bikeIslandShare = allBikeMeters > 0 ? stats.bikeIslandMeters / allBikeMeters : 0

        // Drop pieces that lost every mode.
        var newStart: [Int32] = [0], newPoints: [Int32] = [], newAttributes: [Attributes] = [], newLengths: [Double] = []
        for piece in 0..<pieceCount where keep[piece] && attributes[piece].isUsable {
            newPoints += points[Int(pointStart[piece])..<Int(pointStart[piece + 1])]
            newStart.append(Int32(newPoints.count))
            newAttributes.append(attributes[piece])
            newLengths.append(lengths[piece])
        }
        pointStart = newStart
        points = newPoints
        attributes = newAttributes
        lengths = newLengths
    }

    // MARK: - Output

    func compile(options: StreetBuildOptions, regions: [StreetRegion], stats: inout StreetBuildStats) -> CompiledStreets {
        // Graph nodes: segment ends, in Hilbert order for memory locality.
        var used = [Bool](repeating: false, count: nodeIDs.count)
        for piece in 0..<pieceCount {
            used[Int(first(piece))] = true
            used[Int(last(piece))] = true
        }
        var graphNodes = (0..<Int32(nodeIDs.count)).filter { used[Int($0)] }
        var minLat = Int32.max, maxLat = Int32.min, minLon = Int32.max, maxLon = Int32.min
        for u in graphNodes {
            minLat = min(minLat, latE7[Int(u)]); maxLat = max(maxLat, latE7[Int(u)])
            minLon = min(minLon, lonE7[Int(u)]); maxLon = max(maxLon, lonE7[Int(u)])
        }
        func scaled(_ value: Int32, _ low: Int32, _ high: Int32) -> UInt16 {
            guard high > low else { return 0 }
            return UInt16(Double(Int64(value) - Int64(low)) / Double(Int64(high) - Int64(low)) * 65535)
        }
        let hilbert = graphNodes.map {
            StreetGeometry.hilbertIndex(x: scaled(lonE7[Int($0)], minLon, maxLon), y: scaled(latE7[Int($0)], minLat, maxLat))
        }
        var nodeOrder = Array(graphNodes.indices)
        nodeOrder.sort { (hilbert[$0], nodeIDs[Int(graphNodes[$0])]) < (hilbert[$1], nodeIDs[Int(graphNodes[$1])]) }
        graphNodes = nodeOrder.map { graphNodes[$0] }
        var graphIndex = [UInt32](repeating: .max, count: nodeIDs.count)
        for (index, u) in graphNodes.enumerated() { graphIndex[Int(u)] = UInt32(index) }

        var out = CompiledStreets()
        out.regions = regions
        out.nodeCoordinates.reserveCapacity(graphNodes.count * 2)
        for u in graphNodes {
            out.nodeCoordinates.append(e6(latE7[Int(u)]))
            out.nodeCoordinates.append(e6(lonE7[Int(u)]))
        }

        // Names, sorted for determinism.
        var nameSet = Set<StreetBuilderName>()
        for attrs in attributes { nameSet.insert(attrs.name) }
        let sortedNames = nameSet.sorted { a, b in
            let (ta, tb) = (Array(a.text.utf8), Array(b.text.utf8))
            return ta != tb ? ta.lexicographicallyPrecedes(tb) : a.kind.rawValue < b.kind.rawValue
        }
        var nameID: [StreetBuilderName: UInt32] = [:]
        for (index, name) in sortedNames.enumerated() {
            nameID[name] = UInt32(index)
            out.names.append(name.text)
            out.nameKinds.append(name.kind)
        }

        // Segments ordered by their (renumbered) end nodes.
        var segmentOrder = Array(0..<pieceCount)
        let ends = (0..<pieceCount).map { (graphIndex[Int(first($0))], graphIndex[Int(last($0))]) }
        segmentOrder.sort { (ends[$0].0, ends[$0].1, $0) < (ends[$1].0, ends[$1].1, $1) }

        for piece in segmentOrder {
            let attrs = attributes[piece]
            let range = Int(pointStart[piece])..<Int(pointStart[piece + 1])
            let piecePoints = Array(points[range])
            out.segmentNodes.append(ends[piece].0)
            out.segmentNodes.append(ends[piece].1)
            out.segmentLengthDecimeters.append(UInt32(min((lengths[piece] * 10).rounded(), Double(UInt32.max - 1))))
            var shared = attrs.flags
            shared.remove([.walk, .bikeForward])
            var forward = shared, backward = shared
            if attrs.walk { forward.insert(.walk); backward.insert(.walk) }
            if attrs.bikeForward { forward.insert(.bikeForward) }
            if attrs.bikeBackward { backward.insert(.bikeForward) }
            let usable: EdgeFlags = [.walk, .bikeForward]
            out.forwardFlags.append(forward.isDisjoint(with: usable) ? 0 : forward.rawValue)
            out.backwardFlags.append(backward.isDisjoint(with: usable) ? 0 : backward.rawValue)
            out.forwardClasses.append(attrs.classForward.rawValue)
            out.backwardClasses.append(attrs.classBackward.rawValue)
            out.segmentNameIDs.append(nameID[attrs.name]!)

            // Bearings from the full-resolution geometry.
            let coordinates = piecePoints.map { Coordinate(lat: Double(latE7[Int($0)]) * 1e-7, lon: Double(lonE7[Int($0)]) * 1e-7) }
            let (entry, exit) = Self.bearings(coordinates, lookahead: options.bearingLookaheadMeters)
            out.segmentBearings.append(StreetsFormat.bearingCode(degrees: entry))
            out.segmentBearings.append(StreetsFormat.bearingCode(degrees: exit))

            // Simplified interior shape points.
            if coordinates.count > 2 {
                let projection = LocalProjection(origin: coordinates[0])
                let kept = StreetGeometry.douglasPeucker(coordinates.map(projection.project), toleranceMeters: options.shapeToleranceMeters)
                for index in kept.dropFirst().dropLast() {
                    out.shapePoints.append(e6(latE7[Int(piecePoints[index])]))
                    out.shapePoints.append(e6(lonE7[Int(piecePoints[index])]))
                }
            }
            out.segmentShapeOffsets.append(UInt32(out.shapePoints.count / 2))
        }

        stats.vertices = out.nodeCount
        stats.segments = out.segmentCount
        stats.shapePoints = out.shapePoints.count / 2
        stats.names = out.names.count
        stats.totalMeters = lengths.reduce(0, +)
        stats.directedEdges = zip(out.forwardFlags, out.backwardFlags).reduce(0) { $0 + ($1.0 != 0 ? 1 : 0) + ($1.1 != 0 ? 1 : 0) }
        stats.walkEdges = (out.forwardFlags + out.backwardFlags).filter { EdgeFlags(rawValue: $0).contains(.walk) }.count
        stats.bikeEdges = (out.forwardFlags + out.backwardFlags).filter { EdgeFlags(rawValue: $0).contains(.bikeForward) }.count
        return out
    }

    private func e6(_ e7: Int32) -> Int32 {
        Int32((Double(e7) / 10).rounded())
    }

    /// Bearings leaving the first point and arriving at the last, each measured to the point
    /// `lookahead` meters along (or the far end of a shorter line).
    static func bearings(_ points: [Coordinate], lookahead: Double) -> (entry: Double, exit: Double) {
        guard points.count >= 2 else { return (0, 0) }
        func pointAlong(_ line: [Coordinate]) -> Coordinate {
            var travelled = 0.0
            for i in 1..<line.count {
                let step = line[i - 1].distance(to: line[i])
                if travelled + step >= lookahead, step > 0 {
                    let t = (lookahead - travelled) / step
                    return Coordinate(lat: line[i - 1].lat + (line[i].lat - line[i - 1].lat) * t,
                                      lon: line[i - 1].lon + (line[i].lon - line[i - 1].lon) * t)
                }
                travelled += step
            }
            return line[line.count - 1]
        }
        let ahead = pointAlong(points)
        let behind = pointAlong(points.reversed())
        let entry = points[0] == ahead ? 0 : points[0].initialBearing(to: ahead)
        let last = points[points.count - 1]
        let exit = behind == last ? entry : behind.initialBearing(to: last)
        return (entry, exit)
    }
}

/// A segment's name: a tagged name or ref, or a derived label.
enum StreetBuilderName: Hashable, Sendable {
    case named(String, StreetNameKind)
    case derived(DerivedLabel)

    var text: String {
        switch self {
        case .named(let text, _): text
        case .derived(let label): label.text
        }
    }

    var kind: StreetNameKind {
        switch self {
        case .named(_, let kind): kind
        case .derived: .derived
        }
    }
}

struct UnionFind {
    private var parent: [Int32]
    private var rank: [UInt8]

    init(count: Int) {
        parent = (0..<Int32(count)).map { $0 }
        rank = [UInt8](repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while Int(parent[root]) != root { root = Int(parent[root]) }
        var node = x
        while Int(parent[node]) != root {
            let next = Int(parent[node])
            parent[node] = Int32(root)
            node = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if rank[ra] < rank[rb] {
            parent[ra] = Int32(rb)
        } else if rank[ra] > rank[rb] {
            parent[rb] = Int32(ra)
        } else {
            parent[rb] = Int32(ra)
            rank[ra] += 1
        }
    }
}

enum StronglyConnected {
    /// Tarjan's algorithm, iterative. Returns each node's component id, or -1 for nodes no arc
    /// touches.
    static func components(nodeCount: Int, arcs: [(Int32, Int32)]) -> [Int32] {
        var offsets = [Int32](repeating: 0, count: nodeCount + 1)
        for (a, _) in arcs { offsets[Int(a) + 1] += 1 }
        for i in 0..<nodeCount { offsets[i + 1] += offsets[i] }
        var cursor = offsets
        var targets = [Int32](repeating: 0, count: arcs.count)
        var touched = [Bool](repeating: false, count: nodeCount)
        for (a, b) in arcs {
            targets[Int(cursor[Int(a)])] = b
            cursor[Int(a)] += 1
            touched[Int(a)] = true
            touched[Int(b)] = true
        }
        var index = [Int32](repeating: -1, count: nodeCount)
        var low = [Int32](repeating: 0, count: nodeCount)
        var onStack = [Bool](repeating: false, count: nodeCount)
        var component = [Int32](repeating: -1, count: nodeCount)
        var stack: [Int32] = []
        var callStack: [(node: Int32, next: Int32)] = []
        var counter: Int32 = 0
        var componentCount: Int32 = 0

        for root in 0..<nodeCount where touched[root] && index[root] < 0 {
            callStack.append((Int32(root), offsets[root]))
            index[root] = counter; low[root] = counter; counter += 1
            stack.append(Int32(root)); onStack[root] = true
            while let (node, next) = callStack.last {
                let u = Int(node)
                if next < offsets[u + 1] {
                    callStack[callStack.count - 1].next = next + 1
                    let v = Int(targets[Int(next)])
                    if index[v] < 0 {
                        index[v] = counter; low[v] = counter; counter += 1
                        stack.append(Int32(v)); onStack[v] = true
                        callStack.append((Int32(v), offsets[v]))
                    } else if onStack[v] {
                        low[u] = min(low[u], index[v])
                    }
                } else {
                    callStack.removeLast()
                    if let parent = callStack.last { low[Int(parent.node)] = min(low[Int(parent.node)], low[u]) }
                    if low[u] == index[u] {
                        while let w = stack.popLast() {
                            onStack[Int(w)] = false
                            component[Int(w)] = componentCount
                            if Int(w) == u { break }
                        }
                        componentCount += 1
                    }
                }
            }
        }
        return component
    }
}
