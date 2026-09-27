import BRBuild
import BRConfig
import BRCore
import BRData
import BRStreetCore
import BRTimetable
import Foundation

/// A scratch directory removed when the value is no longer needed.
final class ScratchDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("brconfig-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// The repository's reviewed config sources (`Data/`).
enum RepositoryData {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Data")

    /// A copy of `Data/config` and `Data/fares` to edit.
    static func copy(into scratch: ScratchDirectory) throws -> URL {
        let target = scratch.url.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for folder in ["config", "fares"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(folder), to: target.appendingPathComponent(folder))
        }
        return target
    }
}

/// Tiny `tt-*` and `stations` artifacts, compiled by the real builders, for the reference checks.
enum ReferenceFixtures {
    static let windowStart = ServiceDate(year: 2026, month: 10, day: 5)

    static func compile(_ system: TransitSystem, _ files: [String: String], scratch: ScratchDirectory) throws -> (timetable: Timetable, bytes: Data) {
        let directory = scratch.url.appendingPathComponent("gtfs-\(system.rawValue)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: directory.appendingPathComponent(name)) }
        let feed = try GTFSFeed.parse(DirectoryGTFSFeed(directory: directory), source: GTFSSourceInfo(name: "fixture-\(system.rawValue)", slot: "main"))
        let (data, _) = try GTFSTimetableCompiler.compile(system: system, feeds: [feed], entrances: [], options: GTFSCompileOptions(windowStart: windowStart))
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

    /// Stations A, B, C (platforms AN, BN, CN; A↔B linked in transfers.txt), SIR stations S1 and
    /// S2 on route SI, and station Z whose platform no trip calls at.
    static func subway() -> [String: String] {
        [
            "agency.txt": agency("MTA NYCT"),
            "routes.txt": "route_id,agency_id,route_short_name,route_type\n1,MTA NYCT,1,1\nSI,MTA NYCT,SIR,1\n",
            "stops.txt": """
                stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
                A,Alpha,40.7000,-74.0000,1,
                AN,Alpha,40.7000,-74.0000,0,A
                B,Bravo,40.7010,-74.0000,1,
                BN,Bravo,40.7010,-74.0000,0,B
                C,Charlie,40.7020,-74.0000,1,
                CN,Charlie,40.7020,-74.0000,0,C
                S1,St George,40.6400,-74.0700,1,
                S1N,St George,40.6400,-74.0700,0,S1
                S2,Tompkinsville,40.6360,-74.0740,1,
                S2N,Tompkinsville,40.6360,-74.0740,0,S2
                Z,Zulu,40.7100,-74.0000,1,
                ZN,Zulu,40.7100,-74.0000,0,Z
                """,
            "calendar.txt": calendar,
            "trips.txt": "route_id,trip_id,service_id\n1,T1,ALL\nSI,T2,ALL\n",
            "stop_times.txt": """
                trip_id,stop_id,arrival_time,departure_time,stop_sequence
                T1,AN,08:00:00,08:00:00,1
                T1,BN,08:02:00,08:02:00,2
                T1,CN,08:04:00,08:04:00,3
                T2,S1N,09:00:00,09:00:00,1
                T2,S2N,09:03:00,09:03:00,2
                """,
            "transfers.txt": "from_stop_id,to_stop_id,transfer_type,min_transfer_time\nA,B,2,180\nB,A,2,180\n",
        ]
    }

    /// L1 (terminal) and L2 served; LH a yard stop no rider can use (no pickup, no drop-off);
    /// L3 in stops.txt but never called at.
    static func lirr() -> [String: String] {
        [
            "agency.txt": agency("LI"),
            "routes.txt": "route_id,agency_id,route_short_name,route_type\nPW,LI,PW,2\n",
            "stops.txt": """
                stop_id,stop_name,stop_lat,stop_lon
                L1,Terminal,40.7500,-73.9900
                L2,Suburb,40.7000,-73.8000
                LH,Yard,40.7200,-73.9000
                L3,Closed,40.7100,-73.7000
                """,
            "calendar.txt": calendar,
            "trips.txt": "route_id,trip_id,service_id\nPW,P1,ALL\n",
            "stop_times.txt": """
                trip_id,stop_id,arrival_time,departure_time,stop_sequence,pickup_type,drop_off_type
                P1,L1,08:00:00,08:00:00,1,0,1
                P1,LH,08:10:00,08:10:00,2,1,1
                P1,L2,08:20:00,08:20:00,3,1,0
                """,
        ]
    }

    /// Two stations 100 m apart (40.75 N): `one` in region 71, `two` in region 70.
    static func stations() throws -> MappedStations {
        let list = [
            CompiledStation(id: "one", name: "One", shortName: "1000.01", regionID: "71", latE6: 40_750_000, lonE6: -73_990_000, capacity: 10),
            CompiledStation(id: "two", name: "Two", shortName: "2000.02", regionID: "70", latE6: 40_750_900, lonE6: -73_990_000, capacity: 10),
        ]
        let bytes = StationsArtifactWriter.artifact(stations: list, matrix: [0, 10, 10, 0], profile: .eBike, dataVersion: "fixture",
                                                    builtAgainst: [:])
        return try MappedStations(artifact: MappedArtifact(fileBytes: bytes))
    }

    struct World {
        let scratch: ScratchDirectory
        let subway: Timetable
        let lirr: Timetable
        let stations: MappedStations
        let bytes: [TransitSystem: Data]
    }

    static func world() throws -> World {
        let scratch = try ScratchDirectory()
        let subway = try compile(.subway, subway(), scratch: scratch)
        let lirr = try compile(.lirr, lirr(), scratch: scratch)
        return World(scratch: scratch, subway: subway.timetable, lirr: lirr.timetable, stations: try stations(),
                     bytes: [.subway: subway.bytes, .lirr: lirr.bytes])
    }

    /// A document whose ids all resolve in ``world()``.
    static var document: ConfigDocument {
        var document = HandBuiltConfig.document
        document.fares.mta.outOfSystemTransfers = [ConfigStationPair("S:A", "S:C")]
        document.fares.mta.inSystemTransfers = [ConfigStationPair("S:B", "S:C")]
        document.fares.mta.statenIslandRailway = ConfigStatenIslandRailway(routes: ["S:SI"], fareStations: ["S:S1", "S:S2"])
        document.fares.lirr.stations = [
            ConfigLIRRStation(stop: "L:L1", zone: 1, cityFare: .cityTicket),
            ConfigLIRRStation(stop: "L:L2", zone: 4, cityFare: .farRockaway),
        ]
        document.fares.lirr.zoneFares = HandBuiltConfig.document.fares.lirr.zoneFares.filter { $0.fromZone != 3 && $0.toZone != 3 }
        document.fares.lirr.nycTerminals = ["L:L1"]
        document.transit.links.fixedTransfers = [ConfigFixedTransfer(from: "L:L1", to: "S:A", seconds: 240)]
        document.bikeShare.regions = ConfigBikeShareRegions(nyc: ["71"], newJersey: ["70"])
        document.bikeShare.valet = [ConfigValetStation(stationID: "one", latE6: 40_750_100, lonE6: -73_990_000)]
        return document
    }

    /// Citi Bike's live `system_pricing_plans` as fetched on 2026-09-27 (price as a string).
    static let pricingPlans = """
        {"data":{"plans":[{"plan_id":"EBIKE_SINGLE_RIDE","name":"EBIKE SINGLE RIDE","currency":"USD","price":"4.99",
        "is_taxable":true,"description":"$4.99 unlock fee, $0.41 per minute.",
        "per_min_pricing":[{"start":0,"rate":0.41,"interval":1}]}]},"last_updated":1790481886,"ttl":60,"version":"2.3"}
        """
}
