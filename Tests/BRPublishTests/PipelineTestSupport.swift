@testable import BRBuild
import BRConfig
import BRCore
import BRData
import BRFlows
import BRGeo
import BRStreetCore
import BRTimetable
import Foundation

/// Every input of `bikeride-data all`, made up and tiny, under one scratch directory:
///
/// - `sources/osm/*.osm.pbf` (empty: ``PipelineOsmiumRunner`` stands in for osmium and streams an
///   OPL lattice), `sources/nyc/borough-boundaries-water-included.geojson` (one borough,
///   Manhattan, around the main lattice); the osmium stub's municipal boundaries put Jersey City
///   and Hoboken west of it, each with a small lattice of its own, so every region has streets.
/// - `sources/gtfs/`: one tiny feed per system (`synthetic_S` … `synthetic_P`), each with its
///   download record, and two versions of the ferry feed: the current zip (10/05–10/15) and an
///   older archived one (`archive/synthetic_F/`, 10/05–10/31) that fills the dates the newer
///   lacks.
/// - `sources/gbfs/`: GBFS discovery and `station_information` (Manhattan, Jersey City, Hoboken,
///   and a capacity-0 station that flows keeps and stations drops).
/// - `trips/`: a saved `tripdata` listing and zipped trip CSVs, June–August 2026, NYC and JC.
/// - `Data/`: the repository's config sources, with the station-level facts replaced by the
///   synthetic network's: LIRR zones and NYC terminal, MTA station pairs and SIR, the fixed PATH
///   transfer, the valet station.
///
/// Build day 2026-10-06 (window from 10/05). Stops sit on lattice nodes.
struct SyntheticSources {
    static let today = day("20261006")
    static let runner = ProcessToolRunner()

    let scratch: PublishScratch
    var root: URL { scratch.url }
    var sources: URL { root.appendingPathComponent("sources") }
    var gtfs: URL { sources.appendingPathComponent("gtfs") }
    var gbfs: URL { sources.appendingPathComponent("gbfs") }
    var trips: URL { root.appendingPathComponent("trips") }
    var configSources: URL { root.appendingPathComponent("Data") }
    var oplFile: URL { root.appendingPathComponent("lattice.opl") }

    init() throws {
        scratch = try PublishScratch()
        try writeStreetsSources()
        try writeOPL()
        for system in TransitSystem.allCases { try writeFeed(system) }
        try writeGBFS()
        try writeTrips()
        try writeConfigSources()
    }

    // MARK: Geography

    static func coordinate(_ x: Double, _ y: Double) -> Coordinate { SyntheticSet.coordinate(x, y) }

    /// A closed GeoJSON ring `[lon, lat]` for the lattice rectangle.
    static func ring(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [[Double]] {
        [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)].map { let c = coordinate($0.0, $0.1); return [c.lon, c.lat] }
    }

    static let manhattan = (x: -3.0...13.0, y: -3.0...13.0)
    static let jerseyCity = (x: -16.0 ... -9.0, y: -2.0...4.0)
    static let hoboken = (x: -16.0 ... -9.0, y: 5.0...11.0)

    func writeStreetsSources() throws {
        let osm = sources.appendingPathComponent("osm"), nyc = sources.appendingPathComponent("nyc")
        try FileManager.default.createDirectory(at: osm, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nyc, withIntermediateDirectories: true)
        try Data().write(to: osm.appendingPathComponent("new-york-latest.osm.pbf"))
        try Data().write(to: osm.appendingPathComponent("new-jersey-latest.osm.pbf"))
        let m = Self.manhattan
        let boroughs: [String: Any] = ["type": "FeatureCollection", "features": [[
            "type": "Feature", "properties": ["borocode": "1", "boroname": "Manhattan"],
            "geometry": ["type": "MultiPolygon", "coordinates": [[Self.ring(m.x.lowerBound, m.y.lowerBound, m.x.upperBound, m.y.upperBound)]]],
        ]]]
        try JSONSerialization.data(withJSONObject: boroughs, options: [.sortedKeys])
            .write(to: nyc.appendingPathComponent("borough-boundaries-water-included.geojson"))
    }

    /// What the osmium stub's `export` of the New Jersey boundaries returns: Jersey City and Hoboken.
    static func municipalities() throws -> Data {
        var lines: [String] = []
        for (name, wikidata, area) in [("Jersey City", "Q26339", jerseyCity), ("Hoboken", "Q138578", hoboken)] {
            let feature: [String: Any] = [
                "type": "Feature", "properties": ["admin_level": "8", "boundary": "administrative", "name": name, "wikidata": wikidata],
                "geometry": ["type": "MultiPolygon", "coordinates": [[ring(area.x.lowerBound, area.y.lowerBound, area.x.upperBound, area.y.upperBound)]]],
            ]
            lines.append(String(decoding: try JSONSerialization.data(withJSONObject: feature, options: [.sortedKeys]), as: UTF8.self))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// The street lattices as OPL: Manhattan 10 × 10 nodes (x, y 0…9) plus a detached stub at
    /// y −2 the component filter drops, Jersey City and Hoboken 4 × 4 each (x −14…−11). With
    /// `splitHoboken`, no two of Hoboken's streets and avenues share a node: eight pieces of
    /// about 300 m, each under 5 % of Manhattan's length, of which the component filter keeps
    /// only the region's largest (Hoboken keeps an eighth of its street length).
    static func opl(splitHoboken: Bool = false) -> String {
        var lines: [String] = []
        func node(_ x: Int, _ y: Int, piece: Int = 0) -> String {
            let c = coordinate(Double(x), Double(y))
            return "n\((piece + 1) * 1_000_000 + (y + 100) * 1000 + (x + 100))x\(String(format: "%.7f", c.lon))y\(String(format: "%.7f", c.lat))"
        }
        func way(_ name: String, _ nodes: [String]) {
            lines.append("w\(lines.count + 1) Thighway=residential,name=\(name) N" + nodes.joined(separator: ","))
        }
        func lattice(_ prefix: String, xs: ClosedRange<Int>, ys: ClosedRange<Int>, apart: Bool = false) {
            var piece = 0
            func next() -> Int {
                guard apart else { return 0 }
                piece += 1
                return piece
            }
            for y in ys {
                let p = next()
                way("\(prefix)Street\(y - ys.lowerBound)", xs.map { node($0, y, piece: p) })
            }
            for x in xs {
                let p = next()
                way("\(prefix)Avenue\(x - xs.lowerBound)", ys.map { node(x, $0, piece: p) })
            }
        }
        lattice("M", xs: 0...9, ys: 0...9)
        way("Stub", [node(-2, -2), node(-1, -2)])
        lattice("JC", xs: -14 ... -11, ys: 0...3)
        lattice("HB", xs: -14 ... -11, ys: 6...9, apart: splitHoboken)
        return lines.joined(separator: "\n") + "\n"
    }

    func writeOPL(splitHoboken: Bool = false) throws {
        try Data(Self.opl(splitHoboken: splitHoboken).utf8).write(to: oplFile)
    }

    // MARK: GTFS

    struct Stop {
        var id: String
        var name: String
        var x: Double
        var y: Double
    }

    /// Feed options per system; the mutations change one field.
    struct FeedOptions {
        var tripsPerDay = 2
        /// Subway: leave out station SC (named in the MTA station pairs).
        var dropSubwayStationC = false
        /// Bus: a third stop about 400 m from any street, inside the service area.
        var busStopFarFromStreets = false
        /// LIRR: a third stop with service and no fare zone.
        var unzonedLIRRStop = false
    }

    static func spec(_ system: TransitSystem) -> GTFSFeedSpec {
        let name = "synthetic_\(system.rawValue)"
        return GTFSFeedSpec(system: system, name: name, url: "https://example.test/\(name).zip", slot: name)
    }

    static var feedSpecs: [TransitSystem: [GTFSFeedSpec]] {
        Dictionary(uniqueKeysWithValues: TransitSystem.allCases.map { ($0, [spec($0)]) })
    }

    /// Stops in calling order, and whether they are stations with one platform each (`<id>N`).
    static func stops(_ system: TransitSystem, _ options: FeedOptions) -> (stops: [Stop], stations: Bool, routeType: Int) {
        switch system {
        case .subway:
            var stops = [Stop(id: "SA", name: "Alpha", x: 2, y: 2), Stop(id: "SB", name: "Beta", x: 6, y: 6)]
            if !options.dropSubwayStationC { stops.append(Stop(id: "SC", name: "Gamma", x: 4, y: 8)) }
            return (stops, true, 1)
        case .bus:
            var stops = [Stop(id: "BA", name: "Alpha", x: 3, y: 3), Stop(id: "BB", name: "Beta", x: 8, y: 3)]
            if options.busStopFarFromStreets { stops.append(Stop(id: "BC", name: "Gamma", x: 12.5, y: 12.5)) }
            return (stops, false, 3)
        case .lirr:
            var stops = [Stop(id: "LA", name: "Alpha", x: 5, y: 0), Stop(id: "LB", name: "Beta", x: 9, y: 0)]
            if options.unzonedLIRRStop { stops.append(Stop(id: "LC", name: "Gamma", x: 9, y: 2)) }
            return (stops, false, 2)
        case .ferry:
            return ([Stop(id: "FA", name: "Alpha", x: 0, y: 9), Stop(id: "FB", name: "Beta", x: 9, y: 9)], false, 4)
        case .path:
            return ([Stop(id: "PA", name: "Alpha", x: 1, y: 5), Stop(id: "PB", name: "Beta", x: 1, y: 8)], true, 1)
        }
    }

    static func feed(_ system: TransitSystem, _ options: FeedOptions, from: String, to: String, tripPrefix: String = "T") -> [String: String] {
        let (stops, stations, routeType) = stops(system, options)
        let prefix = system.rawValue
        var stopsTxt = "stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station\n"
        var calls: [String] = []
        for stop in stops {
            let point = String(format: "%.6f,%.6f", coordinate(stop.x, stop.y).lat, coordinate(stop.x, stop.y).lon)
            if stations {
                stopsTxt += "\(stop.id),\(stop.name),\(point),1,\n\(stop.id)N,\(stop.name),\(point),0,\(stop.id)\n"
                calls.append("\(stop.id)N")
            } else {
                stopsTxt += "\(stop.id),\(stop.name),\(point),0,\n"
                calls.append(stop.id)
            }
        }
        var trips = "route_id,trip_id,service_id\n", times = "trip_id,stop_id,arrival_time,departure_time,stop_sequence\n"
        for trip in 0..<options.tripsPerDay {
            let id = "\(prefix)\(tripPrefix)\(trip)"
            trips += "R,\(id),ALL\n"
            for (sequence, stop) in calls.enumerated() {
                let time = String(format: "%02d:%02d:00", 6 + trip, sequence * 10)
                times += "\(id),\(stop),\(time),\(time),\(sequence + 1)\n"
            }
        }
        return [
            "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\nA\(prefix),A\(prefix),http://example.test,America/New_York\n",
            "routes.txt": "route_id,agency_id,route_short_name,route_type\nR,A\(prefix),R,\(routeType)\n",
            "stops.txt": stopsTxt,
            "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nALL,1,1,1,1,1,1,1,\(from),\(to)\n",
            "trips.txt": trips,
            "stop_times.txt": times,
        ]
    }

    /// Writes the system's current zip and download record; the ferry also gets its archived version.
    func writeFeed(_ system: TransitSystem, _ options: FeedOptions = FeedOptions()) throws {
        try FileManager.default.createDirectory(at: gtfs, withIntermediateDirectories: true)
        let spec = Self.spec(system)
        let lastDay = system == .ferry ? "20261015" : "20261025"
        try StoredZip.make(Self.feed(system, options, from: "20261005", to: lastDay)).write(to: gtfs.appendingPathComponent("\(spec.name).zip"))
        // Last-Modified is recorded: without it publishedAt (in the payload) would be the zip's mtime.
        let record = GTFSDownloadRecord(url: spec.url, etag: "\"\(spec.name)-v2\"", lastModified: "Sun, 04 Oct 2026 12:00:00 GMT",
                                        checkedAt: "2026-10-06T07:00:00Z", downloadedAt: "2026-10-04T12:05:00Z", bytes: 0, notModified: false)
        try JSONEncoder().encode(record).write(to: gtfs.appendingPathComponent("\(spec.name).zip.json"))
        guard system == .ferry else { return }
        let archive = GTFSSourceArchive(directory: gtfs.appendingPathComponent("archive"), runner: Self.runner)
        guard try archive.records(feed: spec.name).isEmpty else { return }
        let staging = root.appendingPathComponent("staging-ferry-v1.zip")
        defer { try? FileManager.default.removeItem(at: staging) }
        try StoredZip.make(Self.feed(system, options, from: "20261005", to: "20261031", tripPrefix: "OLD")).write(to: staging)
        _ = try archive.add(zip: staging, feed: spec.name, url: spec.url, etag: "\"\(spec.name)-v1\"",
                            lastModified: "Thu, 01 Oct 2026 12:00:00 GMT", now: Date(timeIntervalSince1970: 1_790_900_000))
    }

    // MARK: GBFS

    struct Station {
        var id: String
        var shortName: String
        var x: Double
        var y: Double
        var region: String
        var capacity: Int
    }

    /// `st2` is the valet station. `moveValet` puts it about 100 m from where the config lists it.
    static func stations(moveValet: Bool = false) -> [Station] {
        [
            Station(id: "st0", shortName: "5001.01", x: 1.5, y: 1.5, region: "71", capacity: 20),
            Station(id: "st1", shortName: "5002.02", x: 4.5, y: 2.5, region: "71", capacity: 20),
            Station(id: "st2", shortName: "5003.03", x: moveValet ? 8.5 : 7.5, y: 6.5, region: "71", capacity: 20),
            Station(id: "st3", shortName: "5004.04", x: 2.5, y: 8.5, region: "71", capacity: 20),
            Station(id: "st4", shortName: "5005.05", x: 5.5, y: 5.5, region: "71", capacity: 0),
            Station(id: "jc0", shortName: "JC001", x: -12.5, y: 1.5, region: "70", capacity: 15),
            Station(id: "hb0", shortName: "HB001", x: -12.5, y: 7.5, region: "311", capacity: 15),
        ]
    }

    static let valet = stations()[2]

    func writeGBFS(moveValet: Bool = false) throws {
        try FileManager.default.createDirectory(at: gbfs, withIntermediateDirectories: true)
        let discovery = """
            {"last_updated":1790309897,"ttl":60,"version":"2.3","data":{"en":{"feeds":[\
            {"name":"station_information","url":"https://example.test/gbfs/en/station_information.json"}]}}}
            """
        try Data(discovery.utf8).write(to: gbfs.appendingPathComponent("gbfs.json"))
        let rows = Self.stations(moveValet: moveValet).map { station in
            let c = Self.coordinate(station.x, station.y)
            return String(format: "{\"station_id\":\"%@\",\"name\":\"Station %@\",\"short_name\":\"%@\",\"lat\":%.6f,\"lon\":%.6f,\"region_id\":\"%@\",\"capacity\":%d}",
                          station.id, station.id, station.shortName, c.lat, c.lon, station.region, station.capacity)
        }
        try Data("{\"last_updated\":1790309897,\"ttl\":60,\"version\":\"2.3\",\"data\":{\"stations\":[\(rows.joined(separator: ","))]}}".utf8)
            .write(to: gbfs.appendingPathComponent("station_information.json"))
    }

    // MARK: Trips

    static let tripMonths = (6...8).map { TripMonth(year: 2026, month: $0) }
    static let tripHeader = "ride_id,rideable_type,started_at,ended_at,start_station_name,start_station_id,end_station_name,end_station_id,start_lat,start_lng,end_lat,end_lng,member_casual"

    static func tripRow(_ type: String, _ start: String, _ end: String, from: String, to: String) -> String {
        ["R", type, start, end, "", from, "", to, "40.7", "-74.0", "40.7", "-74.0", "member"].joined(separator: ",")
    }

    /// Every day: two NYC trips between Manhattan stations and one JC trip, Jersey City to Hoboken.
    /// `unmatchedAugust` more NYC trips a day in August start at a station GBFS does not list.
    /// The listing's ETags carry `version`, so a rewrite is new data to the flows build.
    func writeTrips(unmatchedAugust: Int = 0, version: String = "v1") throws {
        try FileManager.default.createDirectory(at: trips, withIntermediateDirectories: true)
        var objects: [TripListingObject] = []
        for month in Self.tripMonths {
            var nyc = [Self.tripHeader], jc = [Self.tripHeader]
            var date = month.firstDay
            while date <= month.lastDay {
                let d = date.description
                nyc.append(Self.tripRow("classic_bike", "\(d) 08:05:00.000", "\(d) 08:20:00.000", from: "5001.01", to: "5002.02"))
                nyc.append(Self.tripRow("electric_bike", "\(d) 17:30:00.000", "\(d) 17:50:00.000", from: "5002.02", to: "5005.05"))
                if month.month == 8 {
                    for _ in 0..<unmatchedAugust {
                        nyc.append(Self.tripRow("classic_bike", "\(d) 12:00:00.000", "\(d) 12:10:00.000", from: "9999.01", to: "5001.01"))
                    }
                }
                jc.append(Self.tripRow("electric_bike", "\(d) 09:00:00.000", "\(d) 09:12:00.000", from: "JC001", to: "HB001"))
                date = date.adding(days: 1)
            }
            for key in ["\(month.yyyymm)-citibike-tripdata.zip", "JC-\(month.yyyymm)-citibike-tripdata.csv.zip"] {
                let rows = key.hasPrefix("JC-") ? jc : nyc
                let entry = key.replacingOccurrences(of: ".zip", with: "").replacingOccurrences(of: ".csv", with: "") + "_1.csv"
                let zip = trips.appendingPathComponent(key)
                try StoredZip.write([(entry, Data((rows.joined(separator: "\n") + "\n").utf8))], to: zip)
                let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as! Int
                objects.append(TripListingObject(key: key, etag: "etag-\(version)-\(key)", size: size, lastModified: ""))
            }
        }
        let listing = TripCache.SavedListing(fetchedAt: "2026-10-06T06:00:00Z", url: TripCache.listingURL, objects: objects)
        try JSONEncoder().encode(listing).write(to: trips.appendingPathComponent("listing.json"))
    }

    // MARK: Config sources

    /// The repository's `Data/config` and `Data/fares`, with the facts that name stations replaced
    /// by the synthetic network's.
    func writeConfigSources() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: configSources, withIntermediateDirectories: true)
        for folder in ["config", "fares"] {
            try fileManager.copyItem(at: SyntheticSet.repoData.appendingPathComponent(folder), to: configSources.appendingPathComponent(folder))
        }
        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: configSources.appendingPathComponent(path))
        }
        try write("config/fixed-transfers.csv", "from,to,seconds,note\nP:PA,S:SA,240,synthetic: PATH Alpha to subway Alpha\n")
        let valet = Self.valet, at = Self.coordinate(valet.x, valet.y)
        try write("config/bikeshare/valet.csv", "station_id,lat_e6,lon_e6,name,source_note\n"
            + "\(valet.id),\(Int((at.lat * 1e6).rounded())),\(Int((at.lon * 1e6).rounded())),Station \(valet.id),synthetic\n")
        try write("fares/lirr/lirr-stations-2026.csv", """
            stop_id,gtfs_name,zone,city_fare,source_note
            L:LA,Alpha,1,cityTicket,synthetic
            L:LB,Beta,4,farRockaway,synthetic

            """)
        try write("fares/lirr/lirr-zone-fares-2026.csv", "from_zone,to_zone,peak_cents,offpeak_cents\n1,1,725,525\n1,4,1350,1000\n4,4,375,375\n")
        var lirr = try JSONSerialization.jsonObject(with: Data(contentsOf: configSources.appendingPathComponent("fares/lirr/lirr.json"))) as! [String: Any]
        lirr["nycTerminals"] = [["stop": "L:LA", "note": "synthetic terminal"]]
        // The synthetic network has no Mets-Willets Point to exclude from the Far Rockaway Ticket.
        var ticket = lirr["farRockawayTicket"] as! [String: Any]
        ticket["excludedDestinations"] = nil
        lirr["farRockawayTicket"] = ticket
        try JSONSerialization.data(withJSONObject: lirr, options: [.prettyPrinted, .sortedKeys]).write(to: configSources.appendingPathComponent("fares/lirr/lirr.json"))
        var mta = try JSONSerialization.jsonObject(with: Data(contentsOf: configSources.appendingPathComponent("fares/mta.json"))) as! [String: Any]
        mta["outOfSystemTransfers"] = [["stations": ["S:SB", "S:SC"], "note": "synthetic: Beta and Gamma"]]
        mta["inSystemTransfers"] = [[String: Any]]()
        mta["statenIslandRailway"] = ["routes": ["S:R"], "fareStations": [["stop": "S:SA", "note": "synthetic"]]]
        try JSONSerialization.data(withJSONObject: mta, options: [.prettyPrinted, .sortedKeys]).write(to: configSources.appendingPathComponent("fares/mta.json"))
    }

    // MARK: Gate configuration

    /// The lattice's three regions, the repository's holidays.
    static func gateConfiguration() throws -> GateConfiguration {
        GateConfiguration(
            thresholds: .init(schema: 1, tripCounts: .init(maxChangePercent: 35), coverage: .init(minDays: 3), snapping: .init(maxSnapMeters: 100),
                              streets: .init(minKeptSharePercent: 80, regions: ["Manhattan": 90, "Jersey City": 80, "Hoboken": 80]), notes: nil),
            snapExceptions: [],
            holidays: try GateConfiguration.parseHolidays(String(contentsOf: SyntheticSet.repoData.appendingPathComponent(GateConfiguration.holidaysPath),
                                                                 encoding: .utf8)))
    }
}

/// Stands in for `osmium`: clip/merge/filter/locate do nothing, `export` returns the municipal
/// boundaries (or no parks), `cat` streams the lattice OPL. Every other tool runs for real.
struct PipelineOsmiumRunner: ToolRunner {
    let real = ProcessToolRunner()
    let opl: URL

    func locate(_ executable: String) -> String? {
        executable == "osmium" ? "osmium" : real.locate(executable)
    }

    func run(executable: String, args: [String], stdin: Data?) throws -> Data {
        guard executable == "osmium" else { return try real.run(executable: executable, args: args, stdin: stdin) }
        guard args.first == "export" else { return Data() }
        return args.count > 1 && args[1].hasSuffix("nj-municipal-boundaries.osm.pbf") ? try SyntheticSources.municipalities() : Data()
    }

    func stream(executable: String, args: [String], stdinFile: URL?) throws -> ToolStream {
        guard executable == "osmium", args.first == "cat" else {
            return try real.stream(executable: executable, args: args, stdinFile: stdinFile)
        }
        let handle = try FileHandle(forReadingFrom: opl)
        return ToolStream(output: handle, waitUntilExit: { try handle.close() }, terminate: { try? handle.close() })
    }
}

/// `bikeride-data all` over ``SyntheticSources``, step by step through the library: each step
/// body does what its CLI command does (the same compiler, configuration and report file) and
/// returns the command's exit status, and ``Pipeline/run(skip:requireFlows:log:_:)`` applies the
/// same policy as `all`, after ``Pipeline/retirePublished(in:previous:)`` as `all` does.
struct SyntheticPipeline {
    let sources: SyntheticSources
    /// Where this run's artifacts go; reports go beside it, as `<out>/../reports`.
    let out: URL
    var previous: URL?
    var requireFlows = false
    /// `all --job`: the heartbeat's job.
    var job = PublishJob.all
    var now = Date(timeIntervalSince1970: 1_791_300_000)   // 2026-10-06T15:20:00Z
    /// Errors thrown by the step bodies (exit 1), by step.
    private(set) var errors: [PipelineStep: String] = [:]
    /// What the last run moved out of the way before its first step, and the previous set it read.
    private(set) var retired: Pipeline.Retired?

    init(sources: SyntheticSources, out: String = "run/data") {
        self.sources = sources
        self.out = sources.root.appendingPathComponent(out)
    }

    var reports: URL { out.deletingLastPathComponent().appendingPathComponent("reports") }
    func report(_ step: String) -> URL { reports.appendingPathComponent("\(step).json") }
    var gateReport: GateReport? { try? GateReport.load(reports.appendingPathComponent(GateReport.fileName)) }
    var manifestURL: URL { out.appendingPathComponent(SetManifest.fileName) }
    var heartbeatURL: URL { out.appendingPathComponent(SetHeartbeat.fileName) }

    /// Every step not in `skip`, as `all` runs them (`all` also skips what `--no-xz` or a skipped
    /// manifest imply; these runs always compress).
    mutating func run(skip: Set<PipelineStep> = []) throws -> Pipeline.Outcome {
        errors = [:]
        let skip = Pipeline.effectiveSkips(skip, compress: true).skip
        let retired = PipelineStep.allCases.contains(where: { !skip.contains($0) })
            ? try Pipeline.retirePublished(in: out, previous: previous)
            : Pipeline.Retired(moved: [], directory: Pipeline.retiredDirectory(for: out), previous: previous, previousHeartbeat: nil)
        self.retired = retired
        var failures: [PipelineStep: String] = [:]
        let outcome = Pipeline.run(skip: skip, requireFlows: requireFlows) { step in
            do {
                return try body(step, timetablesSkipped: skip.contains(.timetables), retired: retired)
            } catch {
                failures[step] = "\(error)"
                return 1
            }
        }
        errors = failures
        return outcome
    }

    func body(_ step: PipelineStep, timetablesSkipped: Bool, retired: Pipeline.Retired) throws -> Int32 {
        let runner = SyntheticSources.runner
        let previous = retired.previous
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        switch step {
        case .streets:
            var configuration = StreetsCompiler.Configuration(sourcesDirectory: sources.sources, outputDirectory: out,
                                                              workDirectory: out.deletingLastPathComponent().appendingPathComponent("work/streets"))
            configuration.offline = true
            configuration.options.snapCellMeters = 50
            let report = try StreetsCompiler(runner: PipelineOsmiumRunner(opl: sources.oplFile), configuration: configuration).run()
            struct Full: Encodable { var build: StreetsCompiler.Report }   // the part of the CLI's report the gate reads
            try writeJSONReport(Full(build: report), to: self.report("streets"))
            return 0
        case .timetables:
            var build = TimetableBuild(sourcesDirectory: sources.sources, outputDirectory: out, reportURL: report("timetables"),
                                       offline: true, today: SyntheticSources.today, runner: runner)
            build.feeds = SyntheticSources.feedSpecs
            try build.run()
            return 0
        case .stations:
            var configuration = StationsCompiler.Configuration(sourcesDirectory: sources.sources, outputDirectory: out)
            configuration.offline = true
            configuration.threads = 2
            configuration.spotChecks = 0
            try writeJSONReport(try StationsCompiler(runner: runner, configuration: configuration).run(), to: report("stations"))
            return 0
        case .config:
            var configuration = ConfigCompiler.Configuration(sourcesDirectory: sources.configSources, dataDirectory: out, outputDirectory: out,
                                                             gbfsDirectory: sources.gbfs)
            configuration.offline = true
            configuration.requireReferences = true
            let report = try ConfigCompiler(runner: runner, configuration: configuration).run()
            try writeJSONReport(report, to: self.report("config"))
            return report.artifact == nil ? 3 : 0
        case .links:
            var configuration = LinksCompiler.Configuration(dataDirectory: out)
            configuration.threads = 2
            let report = try LinksCompiler(runner: runner, configuration: configuration).run()
            try writeJSONReport(report, to: self.report("links"))
            return report.footpathCheck.map(\.passed) == false ? 2 : 0
        case .flows:
            var configuration = FlowsCompiler.Configuration(
                sourcesDirectory: sources.sources, tripsDirectory: sources.trips, outputDirectory: out,
                holidaysFile: SyntheticSet.repoData.appendingPathComponent("config/calendar/holidays.csv"),
                depotsFile: SyntheticSet.repoData.appendingPathComponent("flows/depots.csv"))
            configuration.offline = true
            configuration.threads = 2
            let previousReport = (try? Data(contentsOf: report("flows"))).flatMap { try? JSONDecoder().decode(FlowsReport.Previous.self, from: $0) }
            let result = try FlowsCompiler(runner: runner, configuration: configuration).run(previous: previousReport)
            try result.record(at: report("flows"))
            switch result.outcome {
            case .built: return 0
            case .gateFailed: return 3
            case .keptPrevious: return 4
            }
        case .gate:
            try Gate.removeReport(in: reports)
            var gate = Gate(dataDirectory: out, reportsDirectory: reports, previousManifest: previous, today: SyntheticSources.today,
                            configuration: try SyntheticSources.gateConfiguration(), runner: runner)
            gate.now = now
            gate.requiredKinds = SetManifest.requiredKinds(requireFlows: requireFlows)
            gate.extraChecks = Gate.publishHooks
            return try gate.run().status == .fail ? 3 : 0
        case .manifest:
            var builder = SetManifestBuilder(dataDirectory: out, reportsDirectory: reports, previousManifest: previous,
                                             today: SyntheticSources.today, now: now, runner: runner)
            builder.requiredKinds = SetManifest.requiredKinds(requireFlows: requireFlows)
            do {
                try builder.write()
            } catch let error as SetManifest.ManifestError {
                switch error {
                case .noGateReport, .gateFailed, .gateStale: return 3
                default: throw error
                }
            }
            return 0
        case .heartbeat:
            try SetHeartbeat.write(for: SetManifest.load(manifestURL), data: out, previousHeartbeat: retired.previousHeartbeat, now: now,
                                   job: job.rawValue, notRun: timetablesSkipped, unchanged: false)
            return 0
        }
    }

    func writeJSONReport<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Copies the manifest, sidecar and heartbeat this run wrote into `name/`, as the next run's `--previous`.
    func keepAsPrevious(_ name: String) throws -> URL {
        let directory = sources.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in [SetManifest.fileName, TripCountSidecar.fileName, SetHeartbeat.fileName] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            try FileManager.default.copyItem(at: out.appendingPathComponent(file), to: directory.appendingPathComponent(file))
        }
        return directory.appendingPathComponent(SetManifest.fileName)
    }

    /// Whether any of manifest.json, trip-counts.json and heartbeat.json is in the data directory.
    var publishedFiles: [String] {
        Pipeline.publishedFileNames.filter { FileManager.default.fileExists(atPath: out.appendingPathComponent($0).path) }
    }

    /// Every file in the data directory with its bytes.
    func files() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: out.path) where !name.hasPrefix(".") {
            result[name] = try Data(contentsOf: out.appendingPathComponent(name))
        }
        return result
    }
}

/// Zips of stored (uncompressed) entries, so the tests need `unzip` but not `zip`.
enum StoredZip {
    static func make(_ files: [String: String]) -> Data {
        bytes(files.sorted { $0.key < $1.key }.map { ($0.key, Data($0.value.utf8)) })
    }

    static func write(_ entries: [(name: String, data: Data)], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes(entries).write(to: url)
    }

    static func bytes(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ value: Int, _ data: inout Data) { Swift.withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32, _ data: inout Data) { Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let dosTime = 0, dosDate = 1 << 5 | 1   // 1980-01-01 00:00
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data), size = UInt32(entry.data.count), offset = UInt32(out.count)
            u32(0x0403_4B50, &out)
            u16(20, &out); u16(0, &out); u16(0, &out); u16(dosTime, &out); u16(dosDate, &out)
            u32(crc, &out); u32(size, &out); u32(size, &out)
            u16(name.count, &out); u16(0, &out)
            out.append(name)
            out.append(entry.data)

            u32(0x0201_4B50, &central)
            u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central); u16(dosTime, &central); u16(dosDate, &central)
            u32(crc, &central); u32(size, &central); u32(size, &central)
            u16(name.count, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(0, &central)
            u32(offset, &central)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, &out)
        u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(centralOffset, &out)
        u16(0, &out)
        return out
    }

    /// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }
}
