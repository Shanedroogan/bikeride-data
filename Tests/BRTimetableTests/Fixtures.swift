import BRBuild
import BRCore
import BRData
import BRTimetable
import Foundation

/// A scratch directory removed when the value is no longer needed.
final class ScratchDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("brtimetable-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes one GTFS feed as a directory of CSV files and returns it.
    func feed(_ name: String, _ files: [String: String]) throws -> DirectoryGTFSFeed {
        let directory = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (file, text) in files {
            try Data(text.utf8).write(to: directory.appendingPathComponent(file))
        }
        return DirectoryGTFSFeed(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

func date(_ text: String) -> ServiceDate {
    ServiceDate(yyyymmdd: text)!
}

/// Seconds after the service day's origin.
func hms(_ hours: UInt32, _ minutes: UInt32, _ seconds: UInt32 = 0) -> UInt32 {
    hours * 3600 + minutes * 60 + seconds
}

/// Synthetic GTFS feeds shaped like the NYC ones. Dates are in October 2026: Monday the 5th
/// through Friday the 16th.
enum Fixture {
    static let windowStart = date("20261005")

    // MARK: Subway: a supplemented feed (10/05–10/11) preferred over a regular one (10/05–10/16)

    static let subwaySupplemented: [String: String] = [
        "agency.txt": """
            agency_id,agency_name,agency_url,agency_timezone
            MTA NYCT,MTA New York City Transit,http://www.mta.info,America/New_York
            """,
        "routes.txt": """
            agency_id,route_id,route_short_name,route_long_name,route_type,route_color,route_text_color
            MTA NYCT,1,1,Broadway - 7 Avenue Local,1,D82233,FFFFFF
            MTA NYCT,GS,S,42 St Shuttle,1,808183,FFFFFF
            """,
        "stops.txt": """
            stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
            101,Van Cortlandt Park-242 St,40.889248,-73.898583,1,
            101S,Van Cortlandt Park-242 St,40.889248,-73.898583,,101
            103,238 St,40.884667,-73.900870,1,
            103S,238 St,40.884667,-73.900870,,103
            104,231 St,40.878856,-73.904834,1,
            104S,231 St,40.878856,-73.904834,,104
            901,Grand Central-42 St,40.752769,-73.979189,1,
            901S,Grand Central-42 St,40.752769,-73.979189,,901
            902,Times Sq-42 St,40.755983,-73.986229,1,
            902S,Times Sq-42 St,40.755983,-73.986229,,902
            999,Unused,40.700000,-73.900000,1,
            999S,Unused,40.700000,-73.900000,,999
            """,
        "calendar.txt": """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WKD,1,1,1,1,1,0,0,20261005,20261011
            SAT,0,0,0,0,0,1,0,20261005,20261011
            """,
        // Wednesday the 7th runs the Saturday schedule instead of the weekday one.
        "calendar_dates.txt": """
            service_id,date,exception_type
            WKD,20261007,2
            SAT,20261007,1
            """,
        "trips.txt": """
            route_id,trip_id,service_id,trip_headsign,direction_id,shape_id
            1,ASP26GEN-1038-Weekday-00_060000_1..S03R,WKD,South Ferry,1,1..S03R
            1,ASP26GEN-1038-Weekday-00_060500_1..S03R,WKD,South Ferry,1,1..S03R
            1,ASP26GEN-1038-Saturday-00_060200_1..S03R,SAT,South Ferry,1,1..S03R
            1,ASP26GEN-1038-Weekday-00_151000_1..S03R,WKD,South Ferry,1,1..S03R
            GS,BFA26GEN-GS049-Weekday-00_086750_GS.S04R,WKD,Times Sq,1,
            """,
        // 10:00 is slow; 10:05 overtakes it on the same days (FIFO split); the Saturday 10:02
        // would overtake it too but never runs on the same day; 25:10 runs after midnight.
        "stop_times.txt": """
            trip_id,stop_id,arrival_time,departure_time,stop_sequence
            ASP26GEN-1038-Weekday-00_060000_1..S03R,101S,10:00:00,10:00:00,1
            ASP26GEN-1038-Weekday-00_060000_1..S03R,103S,10:10:00,10:10:30,2
            ASP26GEN-1038-Weekday-00_060000_1..S03R,104S,10:20:00,10:20:00,3
            ASP26GEN-1038-Weekday-00_060500_1..S03R,101S,10:05:00,10:05:00,1
            ASP26GEN-1038-Weekday-00_060500_1..S03R,103S,10:07:00,10:07:00,2
            ASP26GEN-1038-Weekday-00_060500_1..S03R,104S,10:09:00,10:09:00,3
            ASP26GEN-1038-Saturday-00_060200_1..S03R,104S,10:06:00,10:06:00,3
            ASP26GEN-1038-Saturday-00_060200_1..S03R,101S,10:02:00,10:02:00,1
            ASP26GEN-1038-Saturday-00_060200_1..S03R,103S,10:04:00,10:04:00,2
            ASP26GEN-1038-Weekday-00_151000_1..S03R,101S,25:10:00,25:10:00,1
            ASP26GEN-1038-Weekday-00_151000_1..S03R,103S,25:12:00,25:12:00,2
            ASP26GEN-1038-Weekday-00_151000_1..S03R,104S,25:14:00,25:14:00,3
            BFA26GEN-GS049-Weekday-00_086750_GS.S04R,902S,14:27:30,14:27:30,1
            BFA26GEN-GS049-Weekday-00_086750_GS.S04R,901S,14:29:00,14:29:00,2
            """,
        "transfers.txt": """
            from_stop_id,to_stop_id,transfer_type,min_transfer_time
            101,101,2,180
            901,902,2,300
            999,999,2,180
            """,
        // Points 1 and 3 lie on straight segments and are simplified away.
        "shapes.txt": """
            shape_id,shape_pt_sequence,shape_pt_lat,shape_pt_lon
            1..S03R,0,40.889248,-73.898583
            1..S03R,1,40.8869575,-73.8997265
            1..S03R,2,40.884667,-73.900870
            1..S03R,3,40.8817615,-73.902852
            1..S03R,4,40.878856,-73.904834
            """,
        "feed_info.txt": """
            feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date,feed_version
            MTA New York City Transit,https://www.mta.info/,EN,20261005,20261011,SUPP-1
            """,
    ]

    static let subwayRegular: [String: String] = [
        "agency.txt": subwaySupplemented["agency.txt"]!,
        "routes.txt": subwaySupplemented["routes.txt"]!,
        "stops.txt": """
            stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
            101,Van Cortlandt Park-242 St,40.889248,-73.898583,1,
            101S,Van Cortlandt Park-242 St,40.889248,-73.898583,,101
            103,238 St,40.884667,-73.900870,1,
            103S,238 St,40.884667,-73.900870,,103
            """,
        "calendar.txt": """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WKD,1,1,1,1,1,0,0,20261005,20261016
            """,
        "trips.txt": """
            route_id,trip_id,service_id,trip_headsign,direction_id,shape_id
            1,REG-Weekday-00_066000_1..S03R,WKD,South Ferry,1,
            """,
        "stop_times.txt": """
            trip_id,stop_id,arrival_time,departure_time,stop_sequence
            REG-Weekday-00_066000_1..S03R,101S,11:00:00,11:00:00,1
            REG-Weekday-00_066000_1..S03R,103S,11:03:00,11:03:00,2
            """,
        "transfers.txt": """
            from_stop_id,to_stop_id,transfer_type,min_transfer_time
            101,101,2,180
            """,
    ]

    // MARK: Bus: two zips sharing stop ids

    static let busBronx: [String: String] = [
        "agency.txt": """
            agency_id,agency_name,agency_url,agency_timezone,agency_lang,agency_phone
            MTA NYCT,MTA New York City Transit, http://www.mta.info,America/New_York,en,718-330-1234
            """,
        "routes.txt": """
            route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_color,route_text_color
            BX12+,MTA NYCT,Bx12-SBS,Pelham Bay - Inwood,via Fordham Rd,3,00AEEF,FFFFFF
            X27,MTA NYCT,X27,Bay Ridge - Manhattan,,3,6CBE45,FFFFFF
            M15,MTA NYCT,M15,East Side,,3,,
            """,
        "stops.txt": """
            stop_id,stop_name,stop_desc,stop_lat,stop_lon,zone_id,stop_url,location_type,parent_station
            100014,"SHARED A (BX)",,  40.872562, -73.888156,,,0,
            200001,"SHARED B (BX)",,  40.800000, -73.900000,,,0,
            300001,X27 STOP 1,,40.620000,-74.030000,,,0,
            300002,X27 STOP 2,,40.630000,-74.020000,,,0,
            399999,PASS THROUGH,,40.660000,-74.010000,,,0,
            300003,X27 STOP 3,,40.700000,-74.010000,,,0,
            300004,X27 STOP 4,,40.710000,-74.000000,,,0,
            """,
        "calendar.txt": """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WK,1,1,1,1,1,1,1,20261005,20261031
            """,
        "trips.txt": """
            route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
            BX12+,WK,BX12-1,INWOOD,0,1,
            BX12+,WK,BX12-2,PELHAM BAY,1,2,
            X27,WK,X27-1,MANHATTAN,1,3,
            X27,WK,X27-2,MANHATTAN,1,4,
            """,
        // Express trips board only at the first two stops, alight only at the last two, and
        // pass stop 399999 without serving it.
        "stop_times.txt": """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type,timepoint
            BX12-1, 5:07:00, 5:07:00,100014,1,0,0,1
            BX12-1,05:10:00,05:10:00,200001,2,0,0,1
            BX12-2,06:00:00,06:00:00,200001,1,0,0,1
            BX12-2,06:05:00,06:05:00,100014,2,0,0,1
            X27-1,07:00:00,07:00:00,300001,1,0,1,1
            X27-1,07:05:00,07:05:00,300002,2,0,1,0
            X27-1,07:20:00,07:20:00,399999,3,1,1,0
            X27-1,07:40:00,07:40:00,300003,4,1,0,0
            X27-1,07:45:00,07:45:00,300004,5,1,0,1
            X27-2,08:00:00,08:00:00,300001,1,0,1,1
            X27-2,08:05:00,08:05:00,300002,2,0,1,0
            X27-2,08:20:00,08:20:00,399999,3,1,1,0
            X27-2,08:40:00,08:40:00,300003,4,1,0,0
            X27-2,08:45:00,08:45:00,300004,5,1,0,1
            """,
    ]

    static let busCompany: [String: String] = [
        "agency.txt": """
            agency_id,agency_name,agency_url,agency_timezone,agency_lang
            MTABC,MTA Bus Company,http://www.mta.info,America/New_York,en
            """,
        "routes.txt": """
            route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color
            BXM1,MTABC,BxM1,"Riverdale - Midtown","Via Madison Av",3,,D11241,FFFFFF
            Q06,MTABC,Q6,"Jamaica - JFK","Via Sutphin Bl",3,,EE352E,FFFFFF
            """,
        "stops.txt": """
            stop_id,stop_name,stop_desc,stop_lat,stop_lon
            100014,"SHARED A (BC)","",  40.872600, -73.888200
            200001,"SHARED B (BC)","",  40.800100, -73.900100
            500001,"Q06 STOP","",  40.700000, -73.800000
            """,
        "calendar.txt": """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            BC,1,1,1,1,1,0,0,20261005,20261030
            """,
        "trips.txt": """
            route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
            BXM1,BC,BXM1-1,"MIDTOWN",1,9,
            Q06,BC,Q06-1,"JFK",0,10,
            Q06,BC,Q06-2,"JFK",0,11,
            """,
        "stop_times.txt": """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type,timepoint
            BXM1-1,09:00:00,09:00:00,100014,1,0,0,1
            BXM1-1,09:30:00,09:30:00,200001,2,0,0,1
            Q06-1,10:00:00,10:00:00,100014,1,0,0,1
            Q06-1,10:10:00,10:10:00,500001,2,0,0,1
            Q06-2,11:00:00,11:00:00,100014,1,0,0,1
            Q06-2,11:10:00,11:10:00,500001,2,0,0,1
            """,
    ]

    // MARK: LIRR: calendar_dates only, quoted CSV, guaranteed transfers, a pass-through station

    static let lirr: [String: String] = [
        "agency.txt": """
            "agency_id","agency_name","agency_url","agency_timezone","agency_lang","agency_phone"
            "LI","Long Island Rail Road","https://new.mta.info/agency/long-island-rail-road","America/New_York","en","718-217-5477"
            """,
        "feed_info.txt": """
            "feed_publisher_name","feed_publisher_url","feed_timezone","feed_lang","feed_version"
            "Long Island Rail Road","http://web.mta.info/lirr","America/New York","en","GO_TEST"
            """,
        "routes.txt": """
            "route_id","route_long_name","route_type","route_color","route_text_color"
            "1","Babylon Branch","2","00985F","FFFFFF"
            """,
        "stops.txt": """
            "stop_id","stop_code","stop_name","stop_lat","stop_lon","stop_url","wheelchair_boarding"
            "102","JAM","Jamaica","40.69960817","-73.80852987","","1"
            "27","BTA","Babylon","40.70068917","-73.32405154","","1"
            "26","XXX","Pass Station","40.70000000","-73.50000000","","1"
            "237","NYK","Penn Station","40.75058844","-73.99358392","","1"
            """,
        "calendar_dates.txt": """
            "service_id","date","exception_type"
            "S1","20261005","1"
            "S1","20261006","1"
            "S2","20261006","1"
            """,
        "trips.txt": """
            "route_id","service_id","trip_id","trip_headsign","trip_short_name","direction_id","shape_id","peak_offpeak"
            "1","S1","GO_1","Babylon","1","0","","0"
            "1","S1","GO_2","Babylon","2","0","","0"
            "1","S2","GO_3","Penn Station","3","1","","1"
            """,
        "stop_times.txt": """
            "trip_id","arrival_time","departure_time","stop_id","stop_sequence","pickup_type","drop_off_type"
            "GO_1","08:00:00","08:00:00","237","1","0","0"
            "GO_1","08:20:00","08:21:00","102","2","0","0"
            "GO_1","08:40:00","08:40:00","26","3","1","1"
            "GO_1","09:00:00","09:00:00","27","4","0","0"
            "GO_2","08:25:00","08:25:00","102","1","0","0"
            "GO_2","08:45:00","08:45:00","26","2","1","1"
            "GO_2","09:05:00","09:05:00","27","3","0","0"
            "GO_3","10:00:00","10:00:00","27","1","0","0"
            "GO_3","10:40:00","10:42:00","102","2","0","0"
            "GO_3","11:00:00","11:00:00","237","3","0","0"
            """,
        "transfers.txt": """
            "from_stop_id","to_stop_id","from_trip_id","to_trip_id","transfer_type","min_transfer_time"
            "102","102","","","2","300"
            "102","102","GO_1","GO_2","1",""
            """,
    ]

    // MARK: Ferry (zipped inside a subdirectory, like siferry-gtfs.zip)

    static let ferry: [String: String] = [
        "agency.txt": """
            \u{FEFF}agency_id,agency_name,agency_url,agency_timezone
            NYC DOT,New York City Department of Transportation,https://www.nyc.gov,America/New_York
            """,
        "routes.txt": """
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
            SIF,NYC DOT,,Staten Island Ferry,4,FF8330,000000
            """,
        "stops.txt": """
            stop_id,stop_name,stop_lat,stop_lon,location_type
            stgeorge,St. George Ferry Terminal,40.644169,-74.072201,0
            whitehall,Whitehall Ferry Terminal,40.70136,-74.012666,0
            """,
        "calendar.txt": """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            weekday,1,1,1,1,1,0,0,20261005,20261031
            threeboat,0,0,0,0,0,0,0,20261005,20261031
            """,
        "trips.txt": """
            route_id,service_id,trip_id,trip_headsign,direction_id,shape_id
            SIF,weekday,weekdaystgeorge000000,,,
            SIF,weekday,weekdaywhitehall003000,,,
            SIF,threeboat,threeboat1,,,
            """,
        "stop_times.txt": """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
            weekdaystgeorge000000,00:00:00,00:00:00,stgeorge,1,,
            weekdaystgeorge000000,00:25:00,00:25:00,whitehall,2,,
            weekdaywhitehall003000,00:30:00,00:30:00,whitehall,1,,
            weekdaywhitehall003000,00:55:00,00:55:00,stgeorge,2,,
            threeboat1,01:00:00,01:00:00,stgeorge,1,,
            threeboat1,01:25:00,01:25:00,whitehall,2,,
            """,
        "frequencies.txt": "trip_id,start_time,end_time,headway_secs,exact_times\n",
    ]
}

extension Fixture {
    // MARK: Subway entrances (data.ny.gov CSV export)

    /// Three entrances at 101 (one exit-only), one shared by the 901/902 complex, one at a
    /// station the feed lacks, and one without coordinates.
    static let entrancesCSV = """
        Division,Line,Borough,Stop Name,Complex ID,Constituent Station Name,Station ID,GTFS Stop ID,Daytime Routes,Entrance Type,Entry Allowed,Exit Allowed,Entrance Latitude,Entrance Longitude,entrance_georeference
        IRT,Broadway,Bx,Van Cortlandt Park-242 St,294,Van Cortlandt Park-242 St,294,101,1,Stair,YES,YES,40.8893,-73.8986,POINT (-73.8986 40.8893)
        IRT,Broadway,Bx,Van Cortlandt Park-242 St,294,Van Cortlandt Park-242 St,294,101,1,Elevator,YES,YES,40.8891,-73.8984,POINT (-73.8984 40.8891)
        IRT,Broadway,Bx,Van Cortlandt Park-242 St,294,Van Cortlandt Park-242 St,294,101,1,Stair,NO,YES,40.8890,-73.8990,POINT (-73.8990 40.8890)
        IRT,42 St,M,Grand Central-42 St,610,Grand Central-42 St,402,901; 902,S,Easement - Passage,YES,NO,40.7550,-73.9870,POINT (-73.9870 40.7550)
        IRT,Nowhere,M,Closed,999,Closed,999,Z99,S,Stair,YES,YES,40.7000,-73.9000,POINT (-73.9000 40.7000)
        IRT,Broadway,Bx,Van Cortlandt Park-242 St,294,Van Cortlandt Park-242 St,294,101,1,Stair,YES,YES,,,
        """

    // MARK: FIFO across extrapolated days

    /// Two Monday rules that never share a day inside the window (MONB's Mondays are removed and
    /// it runs one Tuesday instead) but both extrapolate to the Mondays after 10/16, where the
    /// fast trip overtakes the slow one.
    static let extrapolatedOvertake: [String: String] = [
        "agency.txt": """
            agency_id,agency_name,agency_url,agency_timezone
            A,Agency,http://example.com,America/New_York
            """,
        "routes.txt": """
            route_id,agency_id,route_short_name,route_long_name,route_type
            R,A,R,River,4
            """,
        "stops.txt": """
            stop_id,stop_name,stop_lat,stop_lon
            X,X,40.70,-74.01
            Y,Y,40.64,-74.07
            """,
        "calendar.txt": """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            MONA,1,0,0,0,0,0,0,20261005,20261016
            MONB,1,0,0,0,0,0,0,20261005,20261016
            """,
        "calendar_dates.txt": """
            service_id,date,exception_type
            MONB,20261005,2
            MONB,20261012,2
            MONB,20261013,1
            """,
        "trips.txt": """
            route_id,service_id,trip_id
            R,MONA,slow
            R,MONB,fast
            """,
        "stop_times.txt": """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            slow,10:00:00,10:00:00,X,1
            slow,10:30:00,10:30:00,Y,2
            fast,10:05:00,10:05:00,X,1
            fast,10:20:00,10:20:00,Y,2
            """,
    ]
}

/// Compiles fixture feeds for one system.
func compileFixture(
    _ system: TransitSystem, _ feeds: [(name: String, slot: String, priority: Int, files: [String: String])],
    entrances: [SubwayEntrance] = [],
    scratch: ScratchDirectory, windowStart: ServiceDate = Fixture.windowStart
) throws -> (data: TimetableData, stats: GTFSSystemStats) {
    let parsed = try feeds.map { feed in
        try GTFSFeed.parse(try scratch.feed(feed.name, feed.files),
                           source: GTFSSourceInfo(name: feed.name, slot: feed.slot, priority: feed.priority, etag: "\"\(feed.name)-etag\""))
    }
    return try GTFSTimetableCompiler.compile(system: system, feeds: parsed, entrances: entrances,
                                             options: GTFSCompileOptions(windowStart: windowStart))
}

/// Writes `data` as an artifact file and maps it back.
func roundTrip(_ data: TimetableData, scratch: ScratchDirectory, name: String = "tt.bin") throws -> Timetable {
    let url = scratch.url.appendingPathComponent(name)
    try data.artifactBytes(dataVersion: "test").write(to: url)
    return try Timetable(contentsOf: url)
}

extension Timetable {
    /// The trip with this GTFS id (tests use unique ids).
    func trip(_ gtfsID: String) -> Int? {
        trips(gtfsID: gtfsID).first
    }

    func departures(ofTrip trip: Int) -> [UInt32] {
        (0..<patternStopCount(tripPattern(trip))).map { departure(trip: trip, position: $0) }
    }

    func stopIDs(ofPattern pattern: Int) -> [String] {
        patternStops(pattern).map { stopGTFSID(Int($0)) }
    }
}
