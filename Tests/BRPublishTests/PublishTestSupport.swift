import BRBuild
import BRConfig
import BRCore
import BRData
import BRGeo
import BRStreetCore
import BRTimetable
import Foundation

let publishRunner = ProcessToolRunner()
let publishToolsInstalled = ["xz", "unzip"].allSatisfy { publishRunner.locate($0) != nil }

/// A scratch directory removed when the value is no longer needed.
final class PublishScratch: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("brpublish-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

func day(_ text: String) -> ServiceDate { ServiceDate(yyyymmdd: text)! }

/// A complete small set built by the real compilers: a lattice city (region "Manhattan") with
/// streets, stations, all five timetables, config and links, each raw file with its `.xz` blob,
/// plus the streets report the gate reads. Build day 2026-10-06; every system covers 10/05–10/25.
struct SyntheticSet {
    static let today = day("20261006")
    static let windowStart = day("20261005")

    let scratch: PublishScratch
    var data: URL { scratch.url.appendingPathComponent("data") }
    var reports: URL { scratch.url.appendingPathComponent("reports") }
    var sources: URL { scratch.url.appendingPathComponent("sources") }

    /// Lattice point (x, y): 40.70 + 0.0009·y, −74.0 + 0.0012·x (about 100 m apart).
    static func coordinate(_ x: Double, _ y: Double) -> Coordinate {
        Coordinate(lat: 40.70 + 0.0009 * y, lon: -74.0 + 0.0012 * x)
    }

    static func point(_ x: Double, _ y: Double) -> String {
        let c = coordinate(x, y)
        return String(format: "%.6f,%.6f", c.lat, c.lon)
    }

    init() throws {
        scratch = try PublishScratch()
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try buildStreets()
        try buildStations()
        for system in TransitSystem.allCases { try buildTimetable(system) }
        try buildConfig()
        try buildLinks()
    }

    // MARK: Steps

    func buildStreets(columns: Int = 10, rows: Int = 10) throws {
        func node(_ x: Int, _ y: Int) -> String {
            let c = Self.coordinate(Double(x), Double(y))
            return "n\(100_000 + y * 1000 + x)x\(String(format: "%.7f", c.lon))y\(String(format: "%.7f", c.lat))"
        }
        var lines: [String] = []
        for y in 0..<rows { lines.append("w\(lines.count + 1) Thighway=residential,name=Street\(y) N" + (0..<columns).map { node($0, y) }.joined(separator: ",")) }
        for x in 0..<columns { lines.append("w\(lines.count + 1) Thighway=residential,name=Avenue\(x) N" + (0..<rows).map { node(x, $0) }.joined(separator: ",")) }
        // A detached stub, so the component filter drops something.
        lines.append("w\(lines.count + 1) Thighway=residential,name=Stub N\(node(30, 30)),\(node(31, 30))")
        var options = StreetBuildOptions()
        options.snapCellMeters = 50
        var builder = StreetNetworkBuilder(options: options)
        var reader = OPLReader(DataChunkSource(Data((lines.joined(separator: "\n") + "\n").utf8), chunkSize: 311))
        try reader.forEachWay { builder.add($0) }
        // The region reaches past the stub, so the stub counts in it (and is dropped from it).
        let a = Self.coordinate(-2, -2), far = Self.coordinate(40, 40)
        let ring = [a, Coordinate(lat: a.lat, lon: far.lon), far, Coordinate(lat: far.lat, lon: a.lon), a]
        let compiled = builder.finish(regions: [StreetRegion(code: 1, name: "Manhattan", area: MultiPolygon([Polygon(exterior: ring)]))])
        let bytes = StreetsArtifactWriter.artifact(compiled, dataVersion: "synthetic", snapCellMeters: 50)
        let raw = data.appendingPathComponent("streets.bin")
        try bytes.write(to: raw)
        try XZ.compress(raw, to: raw.appendingPathExtension("xz"), runner: publishRunner)
        try writeStreetsReport(rawSha256: sha256(raw), regions: builder.stats.regions)
    }

    /// The part of `reports/streets.json` the gate reads, shaped as `bikeride-data streets` writes it.
    func writeStreetsReport(rawSha256: String, regions: [String: StreetBuildStats.RegionLength]?) throws {
        struct Report: Encodable {
            struct Build: Encodable {
                struct Artifact: Encodable { var rawSha256: String }
                struct Stats: Encodable { var regions: [String: StreetBuildStats.RegionLength]? }
                var artifact: Artifact
                var stats: Stats
            }
            var build: Build
        }
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try JSONEncoder().encode(Report(build: .init(artifact: .init(rawSha256: rawSha256), stats: .init(regions: regions))))
            .write(to: reports.appendingPathComponent("streets.json"))
    }

    func buildStations() throws {
        let gbfs = sources.appendingPathComponent("gbfs")
        try FileManager.default.createDirectory(at: gbfs, withIntermediateDirectories: true)
        let discovery = """
            {"last_updated":1790309897,"ttl":60,"version":"2.3","data":{"en":{"feeds":[\
            {"name":"station_information","url":"https://example.test/gbfs/en/station_information.json"}]}}}
            """
        let stations = [(1.5, 1.5), (4.5, 2.5), (7.5, 6.5), (2.5, 8.5)].enumerated().map { index, xy in
            let c = Self.coordinate(xy.0, xy.1)
            return "{\"region_id\":\"71\",\"station_id\":\"st\(index)\",\"name\":\"Station \(index)\",\"short_name\":\"\(index).01\",\"lat\":\(c.lat),\"lon\":\(c.lon),\"capacity\":20}"
        }
        try Data(discovery.utf8).write(to: gbfs.appendingPathComponent("gbfs.json"))
        try Data("{\"last_updated\":1790309897,\"ttl\":60,\"version\":\"2.3\",\"data\":{\"stations\":[\(stations.joined(separator: ","))]}}".utf8)
            .write(to: gbfs.appendingPathComponent("station_information.json"))
        var configuration = StationsCompiler.Configuration(sourcesDirectory: sources, outputDirectory: data)
        configuration.offline = true
        configuration.threads = 2
        configuration.spotChecks = 0
        _ = try StationsCompiler(runner: publishRunner, configuration: configuration).run()
    }

    static func agency(_ id: String) -> String {
        "agency_id,agency_name,agency_url,agency_timezone\n\(id),\(id),http://example.test,America/New_York\n"
    }

    /// Two stops on the lattice and two trips a day, 10/05–10/25; `tripsPerDay` more on request,
    /// and with `thirdStop` a third call there (e.g. far from every street).
    static func feed(_ system: TransitSystem, tripsPerDay: Int = 2, lastDay: String = "20261025",
                     thirdStop: (Double, Double)? = nil) -> [String: String] {
        let (routeType, a, b): (Int, (Double, Double), (Double, Double)) = switch system {
        case .subway: (1, (2, 2), (6, 6))
        case .bus: (3, (2.5, 3.0), (8, 3))
        case .lirr: (2, (5, 0), (9, 0))
        case .ferry: (4, (0, 9), (9, 9))
        case .path: (1, (1, 5), (1, 8))
        }
        let prefix = system.rawValue
        var stops = "stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station\n"
        let ids: [String]
        if system == .subway || system == .path {
            stops += "\(prefix)A,Alpha,\(point(a.0, a.1)),1,\n\(prefix)AN,Alpha,\(point(a.0, a.1)),0,\(prefix)A\n"
            stops += "\(prefix)B,Beta,\(point(b.0, b.1)),1,\n\(prefix)BN,Beta,\(point(b.0, b.1)),0,\(prefix)B\n"
            ids = ["\(prefix)AN", "\(prefix)BN"]
        } else {
            stops += "\(prefix)A,Alpha,\(point(a.0, a.1)),0,\n\(prefix)B,Beta,\(point(b.0, b.1)),0,\n"
            ids = ["\(prefix)A", "\(prefix)B"]
        }
        if let c = thirdStop { stops += "\(prefix)C,Gamma,\(point(c.0, c.1)),0,\n" }
        var trips = "route_id,trip_id,service_id\n", times = "trip_id,stop_id,arrival_time,departure_time,stop_sequence\n"
        for trip in 0..<tripsPerDay {
            let hour = 6 + trip
            trips += "R,\(prefix)T\(trip),ALL\n"
            times += String(format: "%@T%d,%@,%02d:00:00,%02d:00:00,1\n%@T%d,%@,%02d:10:00,%02d:10:00,2\n",
                            prefix, trip, ids[0], hour, hour, prefix, trip, ids[1], hour, hour)
            if thirdStop != nil { times += String(format: "%@T%d,%@C,%02d:20:00,%02d:20:00,3\n", prefix, trip, prefix, hour, hour) }
        }
        return [
            "agency.txt": agency("A\(prefix)"),
            "routes.txt": "route_id,agency_id,route_short_name,route_type\nR,A\(prefix),R,\(routeType)\n",
            "stops.txt": stops,
            "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nALL,1,1,1,1,1,1,1,20261005,\(lastDay)\n",
            "trips.txt": trips,
            "stop_times.txt": times,
        ]
    }

    func buildTimetable(_ system: TransitSystem, tripsPerDay: Int = 2, lastDay: String = "20261025", thirdStop: (Double, Double)? = nil) throws {
        let directory = scratch.url.appendingPathComponent("gtfs-\(system.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in Self.feed(system, tripsPerDay: tripsPerDay, lastDay: lastDay, thirdStop: thirdStop) {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        let feed = try GTFSFeed.parse(DirectoryGTFSFeed(directory: directory), source: GTFSSourceInfo(name: "fixture_\(system.rawValue)", slot: "main", etag: "\"e\""))
        let (compiled, _) = try GTFSTimetableCompiler.compile(system: system, feeds: [feed], options: GTFSCompileOptions(windowStart: Self.windowStart))
        let raw = data.appendingPathComponent(TimetableBuild.artifactFileName(system))
        try compiled.artifactBytes(dataVersion: "fixture").write(to: raw)
        try XZ.compress(raw, to: raw.appendingPathExtension("xz"), runner: publishRunner)
    }

    /// The committed `Data/` config (what links is built from), without the reference checks.
    /// Its fixed transfers name real PATH stations, which the lattice's tt-path doesn't have, so
    /// they are cleared (links would fail on them).
    func buildConfig() throws {
        var document = try ConfigSources(root: Self.repoData).load()
        document.transit.links.fixedTransfers = []
        let raw = data.appendingPathComponent(MappedConfig.fileName)
        try ConfigArtifactWriter.artifact(json: try ConfigArtifactWriter.json(document), dataVersion: "fixture").write(to: raw)
        try XZ.compress(raw, to: raw.appendingPathExtension("xz"), runner: publishRunner)
    }

    func buildLinks() throws {
        var configuration = LinksCompiler.Configuration(dataDirectory: data)
        configuration.threads = 2
        _ = try LinksCompiler(runner: publishRunner, configuration: configuration).run()
    }

    // MARK: Gate and manifest

    /// Thresholds for the lattice: its one region, and the repository's holidays.
    static func configuration(minDays: Int = 3, maxSnapMeters: Double = 100, regionMinimum: Double = 50,
                              exceptions: [GateConfiguration.SnapException] = []) throws -> GateConfiguration {
        GateConfiguration(
            thresholds: .init(schema: 1, tripCounts: .init(maxChangePercent: 35), coverage: .init(minDays: minDays),
                              snapping: .init(maxSnapMeters: maxSnapMeters),
                              streets: .init(minKeptSharePercent: 90, regions: ["Manhattan": regionMinimum]), notes: nil),
            snapExceptions: exceptions,
            holidays: try GateConfiguration.parseHolidays(String(contentsOf: repoData.appendingPathComponent(GateConfiguration.holidaysPath), encoding: .utf8)))
    }

    static let repoData = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Data")

    func gate(previous: URL? = nil, configuration: GateConfiguration? = nil, now: Date = Date(timeIntervalSince1970: 1_791_300_000),
              extra: [any GateCheck] = []) throws -> GateReport {
        var gate = Gate(dataDirectory: data, reportsDirectory: reports, previousManifest: previous, today: Self.today,
                        configuration: try configuration ?? Self.configuration(), runner: publishRunner)
        gate.now = now
        gate.extraChecks = extra
        return try gate.run()
    }

    func manifestBuilder(previous: URL? = nil, now: Date = Date(timeIntervalSince1970: 1_791_300_000)) -> SetManifestBuilder {
        SetManifestBuilder(dataDirectory: data, reportsDirectory: reports, previousManifest: previous, today: Self.today, now: now, runner: publishRunner)
    }

    func sha256(_ url: URL) throws -> String {
        #if canImport(CryptoKit)
        return try CryptoKitHasher().sha256(ofFileAt: url).hex
        #else
        return try ProcessHasher(runner: publishRunner).sha256(ofFileAt: url).hex
        #endif
    }

    /// Copies the written manifest, sidecar and heartbeat into `name/`, as the next build's `--previous`.
    func keepAsPrevious(_ name: String) throws -> URL {
        let directory = scratch.url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in [SetManifest.fileName, TripCountSidecar.fileName, SetHeartbeat.fileName]
            where FileManager.default.fileExists(atPath: data.appendingPathComponent(file).path) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            try FileManager.default.copyItem(at: data.appendingPathComponent(file), to: directory.appendingPathComponent(file))
        }
        return directory.appendingPathComponent(SetManifest.fileName)
    }
}

/// Writes `manifest` and `sidecar` as a previous set in `directory`, the sidecar's hash recorded.
func writePrevious(_ manifest: SetManifest, sidecar: TripCountSidecar, to directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var manifest = manifest
    var sidecar = sidecar
    sidecar.setId = manifest.setId
    let sidecarBytes = try encoder.encode(sidecar)
    try sidecarBytes.write(to: directory.appendingPathComponent(TripCountSidecar.fileName))
    #if canImport(CryptoKit)
    manifest.tripCounts.sha256 = CryptoKitHasher().sha256(of: sidecarBytes).hex
    #else
    manifest.tripCounts.sha256 = try ProcessHasher(runner: publishRunner).sha256(of: sidecarBytes).hex
    #endif
    let url = directory.appendingPathComponent(SetManifest.fileName)
    try encoder.encode(manifest).write(to: url)
    return url
}
