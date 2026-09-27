import BRBuild
import BRCore
import BRData
import BRGeo
import BRStreetCore
import BRTimetable
import Foundation

/// A scratch directory removed when the value is no longer needed.
final class ScratchDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("brlinks-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Synthetic streets

/// A lattice city written as OPL and compiled by the real streets builder.
enum SyntheticCity {
    /// Lattice point (x, y): 40.70 + 0.0009·y, −74.0 + 0.0012·x (about 100 m apart).
    static func coordinate(_ x: Double, _ y: Double) -> Coordinate {
        Coordinate(lat: 40.70 + 0.0009 * y, lon: -74.0 + 0.0012 * x)
    }

    static func opl(columns: Int, rows: Int) -> String {
        func node(_ x: Int, _ y: Int) -> String {
            let c = coordinate(Double(x), Double(y))
            return "n\(100_000 + y * 1000 + x)x\(String(format: "%.7f", c.lon))y\(String(format: "%.7f", c.lat))"
        }
        var lines: [String] = []
        for y in 0..<rows { lines.append("w\(lines.count + 1) Thighway=residential,name=Street\(y) N" + (0..<columns).map { node($0, y) }.joined(separator: ",")) }
        for x in 0..<columns { lines.append("w\(lines.count + 1) Thighway=residential,name=Avenue\(x) N" + (0..<rows).map { node(x, $0) }.joined(separator: ",")) }
        return lines.joined(separator: "\n") + "\n"
    }

    struct Built {
        let graph: MappedStreetGraph
        let bytes: Data
    }

    static func build(columns: Int = 10, rows: Int = 10) throws -> Built {
        var options = StreetBuildOptions()
        options.snapCellMeters = 50
        var builder = StreetNetworkBuilder(options: options)
        var reader = OPLReader(DataChunkSource(Data(opl(columns: columns, rows: rows).utf8), chunkSize: 311))
        try reader.forEachWay { builder.add($0) }
        let a = coordinate(-2, -2), b = coordinate(Double(columns) + 2, Double(rows) + 2)
        let ring = [a, Coordinate(lat: a.lat, lon: b.lon), b, Coordinate(lat: b.lat, lon: a.lon), a]
        let compiled = builder.finish(regions: [StreetRegion(code: 1, name: "Manhattan", area: MultiPolygon([Polygon(exterior: ring)]))])
        let bytes = StreetsArtifactWriter.artifact(compiled, dataVersion: "synthetic", snapCellMeters: 50)
        return Built(graph: try MappedStreetGraph(artifact: MappedArtifact(fileBytes: bytes)), bytes: bytes)
    }
}

// MARK: - Synthetic timetables

/// GTFS feeds placed on the synthetic lattice, compiled by the real timetable compiler.
enum TransitFixture {
    static let windowStart = ServiceDate(year: 2026, month: 10, day: 5)

    static func point(_ x: Double, _ y: Double) -> String {
        let c = SyntheticCity.coordinate(x, y)
        return String(format: "%.6f,%.6f", c.lat, c.lon)
    }

    /// Writes one feed and compiles it.
    static func compile(_ system: TransitSystem, _ files: [String: String], entrances: [SubwayEntrance] = [],
                        scratch: ScratchDirectory) throws -> (timetable: Timetable, bytes: Data) {
        let directory = scratch.url.appendingPathComponent("gtfs-\(system.rawValue)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: directory.appendingPathComponent(name)) }
        let feed = try GTFSFeed.parse(DirectoryGTFSFeed(directory: directory), source: GTFSSourceInfo(name: "fixture-\(system.rawValue)", slot: "main"))
        let (data, _) = try GTFSTimetableCompiler.compile(system: system, feeds: [feed], entrances: entrances, options: GTFSCompileOptions(windowStart: windowStart))
        let bytes = try data.artifactBytes(dataVersion: "fixture")
        return (try Timetable(artifact: MappedArtifact(fileBytes: bytes)), bytes)
    }

    static func agency(_ id: String) -> String {
        "agency_id,agency_name,agency_url,agency_timezone\n\(id),\(id),http://example.test,America/New_York\n"
    }

    static let calendar = """
        service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
        ALL,1,1,1,1,1,1,1,20261005,20261011
        """

    /// Four subway stations: S1 (entrances E1 both ways, E2 entry-only) in a complex with S2
    /// (one exit-only entrance; no trip calls at S2S, so the compiler drops it); S3 with no
    /// entrance; S4 with one.
    static func subway() -> [String: String] {
        [
            "agency.txt": agency("MTA NYCT"),
            "routes.txt": "route_id,agency_id,route_short_name,route_type\nA,MTA NYCT,A,1\nB,MTA NYCT,B,1\n",
            "stops.txt": """
                stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
                S1,One,\(point(2, 2)),1,
                S1N,One,\(point(2, 2)),0,S1
                S1S,One,\(point(2, 2)),0,S1
                S2,Two,\(point(2.4, 2)),1,
                S2N,Two,\(point(2.4, 2)),0,S2
                S2S,Two,\(point(2.4, 2)),0,S2
                S3,Three,\(point(6, 6)),1,
                S3N,Three,\(point(6, 6)),0,S3
                S3S,Three,\(point(6, 6)),0,S3
                S4,Four,\(point(8, 2)),1,
                S4N,Four,\(point(8, 2)),0,S4
                S4S,Four,\(point(8, 2)),0,S4
                """,
            "calendar.txt": calendar,
            "trips.txt": "route_id,trip_id,service_id\nA,A1,ALL\nA,A2,ALL\nB,B1,ALL\n",
            "stop_times.txt": """
                trip_id,stop_id,arrival_time,departure_time,stop_sequence
                A1,S1N,08:00:00,08:00:00,1
                A1,S3N,08:05:00,08:05:00,2
                A1,S4N,08:09:00,08:09:00,3
                A2,S4S,09:00:00,09:00:00,1
                A2,S3S,09:04:00,09:04:00,2
                A2,S1S,09:09:00,09:09:00,3
                B1,S2N,08:00:00,08:00:00,1
                B1,S4N,08:07:00,08:07:00,2
                """,
            "transfers.txt": """
                from_stop_id,to_stop_id,transfer_type,min_transfer_time
                S1,S1,2,0
                S1,S2,2,90
                S2,S1,2,90
                S4,S4,2,180
                S2,S4,3,
                S9,S9,2,60
                """,
        ]
    }

    static func subwayEntrances() -> [SubwayEntrance] {
        func entrance(_ station: String, _ x: Double, _ y: Double, entry: Bool = true, exit: Bool = true) -> SubwayEntrance {
            let c = SyntheticCity.coordinate(x, y)
            return SubwayEntrance(stationGTFSID: station, latE6: StreetsFormat.microdegrees(c.lat), lonE6: StreetsFormat.microdegrees(c.lon),
                                  entranceType: "Stair", entryAllowed: entry, exitAllowed: exit)
        }
        return [
            entrance("S1", 1.95, 2.02),
            entrance("S1", 2.1, 1.97, exit: false),
            entrance("S2", 2.45, 2.03, entry: false),
            entrance("S4", 8.0, 2.04),
        ]
    }

    /// B1 and B2 across Street3 from each other, B3 far east, B4 nowhere near a street.
    static func bus() -> [String: String] {
        [
            "agency.txt": agency("MTA NYCT"),
            "routes.txt": "route_id,agency_id,route_short_name,route_type\nM1,MTA NYCT,M1,3\n",
            "stops.txt": """
                stop_id,stop_name,stop_lat,stop_lon
                B1,Bus One,\(point(2.5, 2.96))
                B2,Bus Two,\(point(2.55, 3.04))
                B3,Bus Three,\(point(9, 9))
                B4,Bus Four,\(point(40, 40))
                """,
            "calendar.txt": calendar,
            "trips.txt": "route_id,trip_id,service_id\nM1,M1a,ALL\n",
            "stop_times.txt": """
                trip_id,stop_id,arrival_time,departure_time,stop_sequence
                M1a,B1,08:00:00,08:00:00,1
                M1a,B2,08:01:00,08:01:00,2
                M1a,B3,08:10:00,08:10:00,3
                M1a,B4,08:30:00,08:30:00,4
                """,
        ]
    }

    /// L1 on Street0; L2 far from every street (ride-through only).
    static func lirr() -> [String: String] {
        [
            "agency.txt": agency("LI"),
            "routes.txt": "route_id,agency_id,route_short_name,route_type\nPW,LI,PW,2\n",
            "stops.txt": "stop_id,stop_name,stop_lat,stop_lon\nL1,Rail One,\(point(5, 0.05))\nL2,Rail Two,\(point(60, 60))\n",
            "calendar_dates.txt": "service_id,date,exception_type\nD,20261006,1\n",
            "trips.txt": "route_id,trip_id,service_id\nPW,P1,D\n",
            "stop_times.txt": "trip_id,stop_id,arrival_time,departure_time,stop_sequence\nP1,L1,08:00:00,08:00:00,1\nP1,L2,08:40:00,08:40:00,2\n",
        ]
    }

    struct World {
        let city: SyntheticCity.Built
        let timetables: [TransitSystem: Timetable]
        let bytes: [TransitSystem: Data]
        let scratch: ScratchDirectory
    }

    static func world() throws -> World {
        let scratch = try ScratchDirectory()
        let city = try SyntheticCity.build()
        let subway = try compile(.subway, subway(), entrances: subwayEntrances(), scratch: scratch)
        let bus = try compile(.bus, bus(), scratch: scratch)
        let lirr = try compile(.lirr, lirr(), scratch: scratch)
        return World(city: city, timetables: [.subway: subway.timetable, .bus: bus.timetable, .lirr: lirr.timetable],
                     bytes: [.subway: subway.bytes, .bus: bus.bytes, .lirr: lirr.bytes], scratch: scratch)
    }
}

extension LinkNetwork {
    /// The global index of a stop by system and GTFS id.
    func global(_ system: TransitSystem, _ gtfsID: String, in timetables: [TransitSystem: Timetable]) -> Int {
        stopBase(system) + timetables[system]!.stop(gtfsID: gtfsID)!
    }
}

// MARK: - Reference

/// Footpaths and station links recomputed from their definition with Floyd–Warshall over an
/// explicitly assembled union graph: an implementation independent of `LinkUnionGraph` and the
/// scratch Dijkstra, sharing only the rounding rules of the spec.
struct LinksReference {
    let network: LinkNetwork
    let options: LinksOptions
    let streetNodes: Int
    /// Walk cost per street edge (nil if not walkable), and each edge's (source, target).
    let edges: [(from: Int, to: Int, cost: UInt32?)]

    init<Graph: StreetNetwork>(network: LinkNetwork, graph: Graph, options: LinksOptions) {
        self.network = network
        self.options = options
        streetNodes = graph.nodeCount
        edges = graph.withView { view in
            (0..<view.nodeCount).flatMap { u in
                view.outgoingEdges(of: u).map { e in (u, Int(view.edgeTargets[e]), options.walk.costMs(ofEdge: e, in: view)) }
            }
        }
    }

    func edgeCost(_ edge: UInt32?) -> UInt32? {
        guard let edge else { return nil }
        // `edges` is in CSR order, so the index is the edge number.
        return edges[Int(edge)].cost
    }

    static func portion(_ cost: UInt32, _ share: Double) -> UInt64 { UInt64((Double(cost) * min(1, max(0, share))).rounded()) }

    func snapWalk(_ meters: Double) -> UInt64 { UInt64((meters / options.walk.speedMetersPerSecond * 1000).rounded()) }

    /// All-pairs shortest paths over street nodes, then exit/entry points, then platforms.
    func allPairs() -> (distances: [[UInt64]], platform: [Int: Int], exitBase: Int, entryBase: Int) {
        let a = network.accessPoints.count
        let routable = (0..<network.stopCount).filter { network.routable[$0] }
        var platform: [Int: Int] = [:]
        let exitBase = streetNodes, entryBase = streetNodes + a, platformBase = streetNodes + 2 * a
        for (i, stop) in routable.enumerated() { platform[stop] = platformBase + i }
        let n = platformBase + routable.count
        let infinity = UInt64.max / 4
        var d = [[UInt64]](repeating: [UInt64](repeating: infinity, count: n), count: n)
        for i in 0..<n { d[i][i] = 0 }
        func link(_ u: Int, _ v: Int, _ c: UInt64) { if c < d[u][v] { d[u][v] = c } }
        for edge in edges { if let c = edge.cost { link(edge.from, edge.to, UInt64(c)) } }
        for (i, point) in network.accessPoints.enumerated() {
            guard let anchor = point.anchor else { continue }
            let f = anchor.fraction, fc = edgeCost(anchor.forwardEdge), bc = edgeCost(anchor.backwardEdge)
            if point.exit {
                if let fc { link(exitBase + i, Int(anchor.nodeB), Self.portion(fc, 1 - f)) }
                if let bc { link(exitBase + i, Int(anchor.nodeA), Self.portion(bc, f)) }
            }
            if point.entry {
                if let fc { link(Int(anchor.nodeA), entryBase + i, Self.portion(fc, f)) }
                if let bc { link(Int(anchor.nodeB), entryBase + i, Self.portion(bc, 1 - f)) }
            }
            for (j, other) in network.accessPoints.enumerated() where point.exit && other.entry {
                guard let second = other.anchor, second.segmentKey == anchor.segmentKey else { continue }
                if i == j { link(exitBase + i, entryBase + j, 0); continue }
                let delta = second.fraction - f
                if let c = delta >= 0 ? fc : bc { link(exitBase + i, entryBase + j, Self.portion(c, abs(delta))) }
            }
        }
        for stop in routable {
            for index in network.stopAccess[stop] {
                let point = network.accessPoints[index]
                guard let anchor = point.anchor else { continue }
                let cost = UInt64(point.accessSeconds) * 1000 + snapWalk(anchor.snapMeters)
                if point.exit { link(platform[stop]!, exitBase + index, cost) }
                if point.entry { link(entryBase + index, platform[stop]!, cost) }
            }
        }
        for transfer in network.transfers { link(platform[transfer.from]!, platform[transfer.to]!, UInt64(transfer.seconds) * 1000) }
        for k in 0..<n {
            for i in 0..<n where d[i][k] < infinity {
                for j in 0..<n where d[k][j] < infinity && d[i][k] + d[k][j] < d[i][j] { d[i][j] = d[i][k] + d[k][j] }
            }
        }
        return (d, platform, exitBase, entryBase)
    }

    /// Expected footpaths per global stop, sorted by (seconds, stop).
    func footpaths() -> [[(stop: Int, seconds: Int)]] {
        let (d, platform, _, _) = allPairs()
        let access = LinksBuilder.stopAccessSeconds(network, options)
        var result = [[(stop: Int, seconds: Int)]](repeating: [], count: network.stopCount)
        for (p, pNode) in platform {
            for (q, qNode) in platform where q != p {
                let bound = UInt64(options.maxFootpathWalkSeconds + access[p] + access[q]) * 1000
                if d[pNode][qNode] <= bound { result[p].append((q, Int((d[pNode][qNode] + 999) / 1000))) }
            }
            result[p].sort { ($0.seconds, $0.stop) < ($1.seconds, $1.stop) }
        }
        return result
    }

    /// Expected station links: (station, stop) → (enter, exit) seconds, `nil` for a missing direction.
    func stationLinks(_ stations: [LinkAnchor?]) -> [[Int: (enter: Int?, exit: Int?)]] {
        // Street-only distances: station links never pass through a platform.
        let street = self.street
        let maxWalk = UInt64((options.stationLinkMaxWalkMeters / options.walk.speedMetersPerSecond * 1000).rounded())
        let usedBy: [Int: [Int]] = {
            var map: [Int: [Int]] = [:]
            for stop in 0..<network.stopCount where network.routable[stop] {
                for index in network.stopAccess[stop] { map[index, default: []].append(stop) }
            }
            return map
        }()
        return stations.map { origin in
            guard let origin else { return [:] }
            let originWalk = snapWalk(origin.snapMeters)
            let ofc = edgeCost(origin.forwardEdge), obc = edgeCost(origin.backwardEdge)
            var seeds: [(Int, UInt64)] = []
            if let ofc { seeds.append((Int(origin.nodeB), Self.portion(ofc, 1 - origin.fraction) + originWalk)) }
            if let obc { seeds.append((Int(origin.nodeA), Self.portion(obc, origin.fraction) + originWalk)) }
            var best: [Int: (enter: Int?, exit: Int?)] = [:]
            for (index, point) in network.accessPoints.enumerated() {
                guard let anchor = point.anchor, let stops = usedBy[index] else { continue }
                var walk = UInt64.max
                for (node, start) in seeds {
                    if let fc = edgeCost(anchor.forwardEdge), street[node][Int(anchor.nodeA)] < UInt64.max / 4 {
                        walk = min(walk, start + street[node][Int(anchor.nodeA)] + Self.portion(fc, anchor.fraction))
                    }
                    if let bc = edgeCost(anchor.backwardEdge), street[node][Int(anchor.nodeB)] < UInt64.max / 4 {
                        walk = min(walk, start + street[node][Int(anchor.nodeB)] + Self.portion(bc, 1 - anchor.fraction))
                    }
                }
                if anchor.segmentKey == origin.segmentKey {
                    let delta = anchor.fraction - origin.fraction
                    if let c = delta >= 0 ? ofc : obc { walk = min(walk, originWalk + Self.portion(c, abs(delta))) }
                }
                guard walk != .max else { continue }
                let total = walk + snapWalk(anchor.snapMeters)
                guard total <= maxWalk else { continue }
                let seconds = Int((total + UInt64(point.accessSeconds) * 1000 + 999) / 1000)
                for stop in stops {
                    var entry = best[stop] ?? (nil, nil)
                    if point.entry { entry.enter = min(entry.enter ?? .max, seconds) }
                    if point.exit { entry.exit = min(entry.exit ?? .max, seconds) }
                    best[stop] = entry
                }
            }
            return best
        }
    }

    /// Street-only all-pairs walk costs.
    var street: [[UInt64]] {
        let n = streetNodes, infinity = UInt64.max / 4
        var d = [[UInt64]](repeating: [UInt64](repeating: infinity, count: n), count: n)
        for i in 0..<n { d[i][i] = 0 }
        for edge in edges { if let c = edge.cost, UInt64(c) < d[edge.from][edge.to] { d[edge.from][edge.to] = UInt64(c) } }
        for k in 0..<n {
            for i in 0..<n where d[i][k] < infinity {
                for j in 0..<n where d[k][j] < infinity && d[i][k] + d[k][j] < d[i][j] { d[i][j] = d[i][k] + d[k][j] }
            }
        }
        return d
    }
}

// MARK: - Random worlds

/// A random street graph with random access points, stops and transfers, for property tests.
struct RandomLinkWorld {
    let graph: StreetGraph
    let network: LinkNetwork
    let stations: [LinkAnchor?]
    let options: LinksOptions

    init(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let nodeCount = 18 + rng.nextInt(below: 10)
        var builder = GraphBuilder()
        let coordinates = (0..<nodeCount).map { _ in
            Coordinate(lat: 40.73 + rng.nextUnitDouble() * 0.006, lon: -73.99 + rng.nextUnitDouble() * 0.008)
        }
        for c in coordinates { builder.addNode(at: c) }
        var pairs = Set<[Int]>()
        // A spanning path keeps most of it connected; extra streets add cycles.
        for i in 1..<nodeCount where rng.nextInt(below: 10) != 0 { pairs.insert([i - 1, i]) }
        for _ in 0..<(nodeCount * 2) {
            let a = rng.nextInt(below: nodeCount), b = rng.nextInt(below: nodeCount)
            if a != b { pairs.insert([min(a, b), max(a, b)]) }
        }
        let streets = pairs.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
        for pair in streets {
            let straight = coordinates[pair[0]].distance(to: coordinates[pair[1]])
            builder.addStreet(between: UInt32(pair[0]), and: UInt32(pair[1]),
                              lengthDecimeters: UInt32((straight * (1 + rng.nextUnitDouble() * 0.3) * 10).rounded(.up)) + 1,
                              bike: .none, attributes: rng.nextInt(below: 8) == 0 ? .stairs : [])
        }
        let graph = builder.build()
        self.graph = graph

        func edge(_ from: Int, _ to: Int) -> UInt32? {
            graph.outgoingEdges(of: UInt32(from)).first { graph.edgeTargets[$0] == UInt32(to) }.map(UInt32.init)
        }
        func randomAnchor(_ rng: inout SplitMix64) -> LinkAnchor {
            // One orientation per segment (A = the lower node), as the streets artifact has.
            let pair = streets[rng.nextInt(below: streets.count)]
            let (a, b) = (pair[0], pair[1])
            let fraction = [0.0, 1.0, Double(Float(rng.nextUnitDouble()))][rng.nextInt(below: 3)]
            return LinkAnchor(nodeA: UInt32(a), nodeB: UInt32(b), forwardEdge: edge(a, b), backwardEdge: edge(b, a),
                              fraction: fraction, snapMeters: Double(rng.nextInt(below: 300)) / 10,
                              segmentKey: UInt64(pair[0]) << 32 | UInt64(pair[1]))
        }

        var options = LinksOptions.standard
        options.maxFootpathWalkSeconds = UInt32(150 + rng.nextInt(below: 250))
        options.stationLinkMaxWalkMeters = Double(150 + rng.nextInt(below: 300))
        options.accessSeconds = [.subway: 120, .bus: 30, .lirr: 240, .ferry: 60, .path: 90]
        options.threads = 1 + rng.nextInt(below: 4)
        self.options = options

        let counts = [3 + rng.nextInt(below: 4), 2 + rng.nextInt(below: 5), rng.nextInt(below: 3), rng.nextInt(below: 2), rng.nextInt(below: 3)]
        let total = counts.reduce(0, +)
        var points: [StreetAccessPoint] = []
        var routable = [Bool](repeating: false, count: total)
        var stopAccess = [[Int]](repeating: [], count: total)
        var base = 0
        for (slot, system) in LinksFormat.systems.enumerated() {
            // Each system has its own pool of points; its stops share them (like platforms sharing entrances).
            let pool = (0..<max(1, counts[slot])).map { _ -> Int in
                let entry = rng.nextInt(below: 5) != 0, exit = !entry || rng.nextInt(below: 5) != 0
                let anchor: LinkAnchor? = rng.nextInt(below: 12) == 0 ? nil : randomAnchor(&rng)
                points.append(StreetAccessPoint(kind: .entrance, system: system, sourceStop: base, coordinate: Coordinate(lat: 0, lon: 0),
                                                entry: entry, exit: exit, accessSeconds: options.accessSeconds[system]!, anchor: anchor))
                return points.count - 1
            }
            for local in 0..<counts[slot] {
                let stop = base + local
                routable[stop] = rng.nextInt(below: 6) != 0
                guard routable[stop] else { continue }
                stopAccess[stop] = Array(Set((0...rng.nextInt(below: 2)).map { _ in pool[rng.nextInt(below: pool.count)] })).sorted()
            }
            base += counts[slot]
        }
        var transfers: [LinkTransfer] = []
        let subway = (0..<counts[0]).filter { routable[$0] }
        for _ in 0..<(subway.count * 2) where subway.count >= 2 {
            let a = subway[rng.nextInt(below: subway.count)], b = subway[rng.nextInt(below: subway.count)]
            if a != b && !transfers.contains(where: { $0.from == a && $0.to == b }) {
                transfers.append(LinkTransfer(from: a, to: b, seconds: UInt32(30 + rng.nextInt(below: 270))))
            }
        }
        transfers.sort { ($0.from, $0.to) < ($1.from, $1.to) }
        network = LinkNetwork(systemStopCounts: counts, routable: routable, stopAccess: stopAccess, accessPoints: points, transfers: transfers)
        stations = (0..<(4 + rng.nextInt(below: 6))).map { _ in rng.nextInt(below: 8) == 0 ? nil : randomAnchor(&rng) }
    }
}

extension FootpathTable {
    func rows(_ stops: Int) -> [[(stop: Int, seconds: Int)]] { (0..<stops).map { footpaths(from: $0) } }
}
