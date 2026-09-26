import BRBuild
import BRCore
import BRTimetable
import Foundation
import Testing

extension Fixture {
    /// Shaped like PANYNJ's feed: UTF-8 BOMs, unpadded hours, no times ≥ 24:00, `place_XXX`
    /// rows without `location_type` or children, two boarding stops per station (four at
    /// Journal Square), no `transfers.txt`, an express skip as pickup = drop-off = 1. Weekdays
    /// run 10/05–10/16, Saturdays 10/10–10/17, Sundays 10/11–10/18 with 10/11 removed.
    static let path: [String: String] = [
        "agency.txt": "\u{FEFF}" + """
            agency_id,agency_name,agency_url,agency_timezone,agency_lang
            151,PATH,http://www.panynj.gov/path/,America/New_York,en
            """,
        "routes.txt": "\u{FEFF}" + """
            route_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color
            RED,RED,NWK_WTC,Newark - World Trade Center,1,,D93A30,FFFFFF
            YEL,YEL,JSQ_33,Journal Square - 33rd Street,1,,FF9900,000000
            """,
        // 121 is spelled differently from its place, so it joins by distance alone.
        "stops.txt": "\u{FEFF}" + """
            stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,zone_id,location_type,parent_station
            100,,Newark,,40.734435,-74.164059,,,
            101,,Newark,,40.734435,-74.164059,,,
            110,,Journal Square,,40.73199,-74.062854,,,
            111,,Journal Square,,40.73199,-74.062854,,,
            112,,Journal Square,,40.73199,-74.062854,,,
            113,,Journal Square,,40.73199,-74.062854,,,
            120,,Grove Street,,40.719264,-74.04257,,,
            121,,Grove St.,,40.719300,-74.042600,,,
            130,,World Trade Center,,40.71224,-74.012522,,,
            131,,World Trade Center,,40.71224,-74.012522,,,
            place_GRV,,Grove Street,,40.719264,-74.04257,,,
            place_HAR,,Harrison,,40.739382,-74.15561,,,
            place_JSQ,,Journal Square,,40.73199,-74.062854,,,
            place_NWK,,Newark,,40.734435,-74.164059,,,
            place_WTC,,World Trade Center,,40.71224,-74.012522,,,
            """,
        "calendar.txt": "\u{FEFF}" + """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WKD,1,1,1,1,1,0,0,20261005,20261016
            SAT,0,0,0,0,0,1,0,20261010,20261017
            SUN,0,0,0,0,0,0,1,20261011,20261018
            """,
        "calendar_dates.txt": "\u{FEFF}" + """
            service_id,date,exception_type
            SUN,20261011,2
            """,
        // direction_id 0 is toward New York, 1 toward New Jersey.
        "trips.txt": "\u{FEFF}" + """
            route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
            RED,WKD,R1,World Trade Center,0,1,
            RED,WKD,R2,World Trade Center,0,2,
            RED,WKD,R3,Newark,1,1,
            YEL,WKD,Y1,33rd Street,0,3,
            YEL,WKD,Y2,Journal Square,1,3,
            RED,SAT,R4,World Trade Center,0,4,
            RED,SUN,R5,World Trade Center,0,5,
            RED,WKD,R6,World Trade Center,0,6,
            """,
        // R2 runs express past Grove Street; R4 is the Saturday 0:48 departure (no 24:48); R6
        // crosses midnight and restarts the clock at Journal Square.
        "stop_times.txt": "\u{FEFF}" + """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
            R1,7:05:00,7:05:00,100,1,0,0
            R1,7:20:00,7:20:30,110,2,0,0
            R1,7:25:00,7:25:00,120,3,0,0
            R1,7:35:00,7:35:00,130,4,0,0
            R2,7:15:00,7:15:00,100,1,0,0
            R2,7:30:00,7:30:00,110,2,0,0
            R2,7:34:30,7:34:30,120,3,1,1
            R2,7:42:00,7:42:00,130,4,0,0
            R3,8:00:00,8:00:00,131,1,0,0
            R3,8:10:00,8:10:00,121,2,0,0
            R3,8:15:00,8:15:00,111,3,0,0
            R3,8:30:00,8:30:00,101,4,0,0
            Y1,9:00:00,9:00:00,112,1,0,0
            Y1,9:06:00,9:06:00,120,2,0,0
            Y2,9:30:00,9:30:00,121,1,0,0
            Y2,9:36:00,9:36:00,113,2,0,0
            R4,0:48:00,0:48:00,100,1,0,0
            R4,0:52:00,0:52:00,110,2,0,0
            R4,0:59:00,0:59:00,130,3,0,0
            R5,10:00:00,10:00:00,100,1,0,0
            R5,10:15:00,10:15:00,110,2,0,0
            R6,23:50:00,23:50:00,100,1,0,0
            R6,23:59:40,0:00:10,110,2,0,0
            R6,0:03:00,0:03:00,120,3,0,0
            R6,0:10:00,0:10:00,130,4,0,0
            """,
    ]
}

@Suite struct PATHCompileTests {
    let scratch: ScratchDirectory
    let timetable: Timetable
    let stats: GTFSSystemStats

    init() throws {
        scratch = try ScratchDirectory()
        let (data, stats) = try compileFixture(.path, [("path", "path", 0, Fixture.path)], scratch: scratch)
        self.stats = stats
        timetable = try roundTrip(data, scratch: scratch)
    }

    func stop(_ id: String) throws -> Int { try #require(timetable.stop(gtfsID: id)) }

    @Test func synthesizesParentStationsFromPlaceRows() throws {
        #expect(timetable.system == .path && timetable.header.kind == .ttPath)
        let synthesis = try #require(stats.pathStations?["path"])
        #expect(synthesis.parentStations == 4)
        #expect(synthesis.platformsMappedByName == 9 && synthesis.platformsMappedByDistance == 1)
        #expect(synthesis.placesWithoutPlatforms == ["place_HAR"])
        #expect(!synthesis.keptFeedStations && !synthesis.keptFeedTransfers)
        #expect(stats.parentStations == 4)

        let jsq = try stop("place_JSQ")
        #expect(timetable.stopKind(jsq) == .station && timetable.stopParent(jsq) == nil)
        #expect(timetable.children(ofStop: jsq).map { timetable.stopGTFSID(Int($0)) } == ["110", "111", "112", "113"])
        let grove = try stop("place_GRV"), groveSt = try stop("121")
        #expect(timetable.stopParent(groveSt) == grove)
        #expect(timetable.stopKind(groveSt) == .stop)
        #expect(timetable.stopID(jsq) == StopID("P:place_JSQ"))
        // A place no train serves is not kept.
        #expect(timetable.stop(gtfsID: "place_HAR") == nil)
        #expect(timetable.stopCount == 10 + 4)
    }

    @Test func synthesizesPlatformTransfersPerStation() throws {
        // Every ordered pair of platforms: NWK 2, JSQ 12, GRV 2, WTC 2.
        #expect(timetable.transferCount == 18 && stats.transfers == 18 && stats.pathStations?["path"]?.transfers == 18)
        var seconds: [String: Int] = [:]
        for index in 0..<timetable.transferCount {
            let transfer = timetable.transfer(index)
            #expect(transfer.type == 2 && transfer.fromTrip == nil && transfer.toTrip == nil)
            #expect(transfer.fromStop != transfer.toStop)
            #expect(timetable.stopParent(transfer.fromStop) == timetable.stopParent(transfer.toStop))
            seconds["\(timetable.stopGTFSID(transfer.fromStop))>\(timetable.stopGTFSID(transfer.toStop))"] = transfer.minTransferSeconds
        }
        #expect(seconds["100>101"] == 60 && seconds["121>120"] == 60)   // cross-platform default
        #expect(seconds["110>113"] == 120 && seconds["130>131"] == 120) // JSQ and WTC levels
        #expect(seconds["100>110"] == nil)
    }

    @Test func parsesUnpaddedTimesAndKeepsAfterMidnightTripsOnTheirOwnDay() throws {
        let r1 = try #require(timetable.trip("R1"))
        #expect(timetable.departures(ofTrip: r1) == [hms(7, 5), hms(7, 20, 30), hms(7, 25), hms(7, 35)])
        #expect(timetable.arrival(trip: r1, position: 1) == hms(7, 20))
        let r4 = try #require(timetable.trip("R4"))
        #expect(timetable.departure(trip: r4, position: 0) == hms(0, 48))
        // The Saturday 0:48 belongs to Saturday, not to Friday night.
        #expect(timetable.isActive(trip: r4, on: date("20261010")))
        #expect(!timetable.isActive(trip: r4, on: date("20261009")))
        let r3 = try #require(timetable.trip("R3"))
        #expect(timetable.tripDirection(r1) == 0 && timetable.tripDirection(r3) == 1)
        // A trip whose clock restarts at midnight stays on its service day, past 24:00.
        let r6 = try #require(timetable.trip("R6"))
        #expect(timetable.departures(ofTrip: r6) == [hms(23, 50), hms(24, 0, 10), hms(24, 3), hms(24, 10)])
        #expect(timetable.arrival(trip: r6, position: 1) == hms(23, 59, 40))
        #expect(timetable.tripPattern(r6) == timetable.tripPattern(r1))
        #expect(stats.tripsUnwrappedPastMidnight == 1)
        #expect(stats.timesRepaired == 0 && stats.timesInterpolated == 0)
    }

    @Test func storesExpressSkipsAsPickupAndDropOffBits() throws {
        let r1 = try #require(timetable.trip("R1")), r2 = try #require(timetable.trip("R2"))
        #expect(timetable.tripPattern(r1) != timetable.tripPattern(r2))
        let express = timetable.tripPattern(r2)
        #expect(timetable.stopIDs(ofPattern: express) == ["100", "110", "120", "130"])
        #expect(Array(timetable.patternStopFlags(express)) == [3, 3, 0, 3])
        #expect(!timetable.canBoard(pattern: express, position: 2) && !timetable.canAlight(pattern: express, position: 2))
        #expect(Array(timetable.patternStopFlags(timetable.tripPattern(r1))) == [3, 3, 3, 3])
        #expect(stats.passThroughStopsDropped == 0)
    }

    @Test func keepsRouteColorsAndThePATHMode() throws {
        let red = timetable.route(timetable.tripRoute(try #require(timetable.trip("R1"))))
        #expect(red.gtfsID == "RED" && red.longName == "NWK_WTC" && red.agencyGTFSID == "151")
        #expect(red.color == 0xD93A30 && red.textColor == 0xFFFFFF && red.mode == .path && red.gtfsRouteType == 1)
        let yellow = timetable.route(timetable.tripRoute(try #require(timetable.trip("Y1"))))
        #expect(yellow.color == 0xFF9900 && yellow.textColor == 0x000000 && yellow.mode == .path)
        #expect(stats.routesByMode == ["path": 2])
        #expect(GTFSTimetableCompiler.mode(system: .path, routeID: "ATW") == .path)
    }

    @Test func coversTheCalendarAndHonorsRemovedSundays() throws {
        #expect(timetable.coveredDates.first == date("20261005") && timetable.coveredDates.last == date("20261018"))
        #expect(timetable.coveredDates.count == 14 && stats.coverage.days == 14)
        #expect(timetable.dayView(for: date("20261006")).activeTripCount == 6)
        #expect(timetable.dayView(for: date("20261010")).activeTripCount == 1)
        #expect(timetable.dayView(for: date("20261011")).activeTripCount == 0)  // removed Sunday
        #expect(timetable.covers(date("20261011")))
        #expect(timetable.dayView(for: date("20261018")).activeTripCount == 1)
        #expect(!timetable.covers(date("20261019")))
    }

    @Test func listsAStationsScheduledCallsForRealtimeMatching() throws {
        let weekday = timetable.dayView(for: date("20261006"))
        let jsq = try stop("place_JSQ")
        let red = timetable.tripRoute(try #require(timetable.trip("R1")))
        let towardNY = timetable.scheduledCalls(atStop: jsq, route: red, direction: 0, in: weekday)
        #expect(towardNY.map { timetable.tripGTFSID($0.trip) } == ["R1", "R2", "R6"])
        #expect(towardNY.map(\.departure) == [hms(7, 20, 30), hms(7, 30), hms(24, 0, 10)])
        #expect(towardNY.map(\.arrival) == [hms(7, 20), hms(7, 30), hms(23, 59, 40)])
        #expect(towardNY.allSatisfy { timetable.stopGTFSID($0.stop) == "110" })
        let all = timetable.scheduledCalls(atStop: jsq, in: weekday)
        #expect(all.map { timetable.tripGTFSID($0.trip) } == ["R1", "R2", "R3", "Y1", "Y2", "R6"])
        // The express call at Grove Street is not a boarding.
        let grove = try stop("place_GRV")
        #expect(timetable.scheduledCalls(atStop: grove, direction: 0, in: weekday).map { timetable.tripGTFSID($0.trip) } == ["R1", "R2", "Y1", "R6"])
        #expect(timetable.scheduledCalls(atStop: grove, direction: 0, boardingOnly: true, in: weekday)
            .map { timetable.tripGTFSID($0.trip) } == ["R1", "Y1", "R6"])
    }
}

@Suite struct PATHStationSynthesisTests {
    func feed(_ edit: (inout [String: String]) -> Void) throws -> (GTFSFeed, ScratchDirectory) {
        let scratch = try ScratchDirectory()
        var files = Fixture.path
        edit(&files)
        let feed = try GTFSFeed.parse(try scratch.feed("path", files), source: GTFSSourceInfo(name: "path", slot: "path"))
        return (feed, scratch)
    }

    @Test func failsLoudlyWhenABoardingStopHasNoPlace() throws {
        let (parsed, _) = try feed { files in
            files["stops.txt"]! += "\n999,,Hoboken,,40.735331,-74.029005,,,"
        }
        var copy = parsed
        #expect(throws: GTFSError.unmappedPlatforms(feed: "path", stops: ["999 Hoboken"])) {
            try copy.synthesizePATHStations()
        }
        #expect(throws: GTFSError.self) {
            try GTFSTimetableCompiler.compile(system: .path, feeds: [parsed], options: GTFSCompileOptions(windowStart: Fixture.windowStart))
        }
    }

    @Test func isDeterministicAndConfigurable() throws {
        let (parsed, _) = try feed { _ in }
        var options = PATHStationOptions()
        options.platformTransferSeconds = 45
        options.stationTransferSeconds = ["JSQ": 150]
        var a = parsed, b = parsed
        let first = try a.synthesizePATHStations(options)
        let second = try b.synthesizePATHStations(options)
        #expect(first == second)
        #expect(a.stops.map(\.parentID) == b.stops.map(\.parentID))
        #expect(a.transfers.map { "\($0.fromStop)>\($0.toStop)=\($0.minTransferSeconds ?? -1)" }
            == b.transfers.map { "\($0.fromStop)>\($0.toStop)=\($0.minTransferSeconds ?? -1)" })
        let wtc = a.transfers.first { $0.fromStop == "130" }
        let jsq = a.transfers.first { $0.fromStop == "110" }
        #expect(wtc?.minTransferSeconds == 45 && jsq?.minTransferSeconds == 150)
        // A second pass sees the synthesized stations and transfers and leaves them alone.
        let again = try a.synthesizePATHStations(options)
        #expect(again.keptFeedStations && again.keptFeedTransfers && a.transfers.count == first.transfers)
    }

    @Test func keepsAFeedThatAlreadyHasStationsAndTransfers() throws {
        let (parsed, _) = try feed { files in
            files["stops.txt"] = """
                stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
                JSQ,Journal Square,40.73199,-74.062854,1,
                110,Journal Square,40.73199,-74.062854,,JSQ
                111,Journal Square,40.73199,-74.062854,,JSQ
                112,Journal Square,40.73199,-74.062854,,JSQ
                113,Journal Square,40.73199,-74.062854,,JSQ
                100,Newark,40.734435,-74.164059,,
                101,Newark,40.734435,-74.164059,,
                120,Grove Street,40.719264,-74.04257,,
                121,Grove Street,40.719264,-74.04257,,
                130,World Trade Center,40.71224,-74.012522,,
                131,World Trade Center,40.71224,-74.012522,,
                """
            files["transfers.txt"] = """
                from_stop_id,to_stop_id,transfer_type,min_transfer_time
                JSQ,JSQ,2,90
                """
        }
        var copy = parsed
        let result = try copy.synthesizePATHStations()
        #expect(result.keptFeedStations && result.keptFeedTransfers && result.parentStations == 0)
        #expect(copy.transfers.count == 1)
    }
}
