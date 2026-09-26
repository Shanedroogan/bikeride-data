import BRBuild
import BRCore
import BRTimetable
import Foundation
import Testing

@Suite struct BusCompileTests {
    let scratch: ScratchDirectory
    let timetable: Timetable
    let stats: GTFSSystemStats

    init() throws {
        scratch = try ScratchDirectory()
        let (data, stats) = try compileFixture(.bus, [
            ("gtfs_bx", "gtfs_bx", 0, Fixture.busBronx),
            ("gtfs_busco", "gtfs_busco", 0, Fixture.busCompany),
        ], scratch: scratch)
        self.stats = stats
        timetable = try roundTrip(data, scratch: scratch)
    }

    @Test func mergesStopsByBareIDTakingCoordinatesFromTheBusiestFeed() throws {
        let sharedA = try #require(timetable.stop(gtfsID: "100014"))
        let sharedB = try #require(timetable.stop(gtfsID: "200001"))
        // 100014: 2 stop_times in gtfs_bx, 3 in gtfs_busco.
        #expect(timetable.stopName(sharedA) == "SHARED A (BC)")
        #expect(timetable.stopCoordinate(sharedA).lat == 40.8726)
        // 200001: 2 in gtfs_bx, 1 in gtfs_busco.
        #expect(timetable.stopName(sharedB) == "SHARED B (BX)")
        #expect(timetable.stopCoordinate(sharedB).lon == -73.9)
        #expect(stats.stopIDsInSeveralFeeds == 2)
        #expect(stats.stopCoordinatesFromLaterFeed == 1)
        // One stop serves routes from both feeds.
        let routes = Set(timetable.patterns(servingStop: sharedA).map { timetable.route(timetable.patternRoute($0.pattern)).gtfsID })
        #expect(routes == ["BX12+", "BXM1", "Q06"])
        #expect(timetable.stopID(sharedA) == StopID("B:100014"))
    }

    @Test func keepsBoardingOnlyAndAlightingOnlyStopsAndDropsPassThroughStops() throws {
        let express = try #require(timetable.trip("X27-1"))
        let pattern = timetable.tripPattern(express)
        #expect(timetable.stopIDs(ofPattern: pattern) == ["300001", "300002", "300003", "300004"])
        #expect(Array(timetable.patternStopFlags(pattern)) == [1, 1, 2, 2])
        #expect(timetable.canBoard(pattern: pattern, position: 0) && !timetable.canAlight(pattern: pattern, position: 0))
        #expect(!timetable.canBoard(pattern: pattern, position: 3) && timetable.canAlight(pattern: pattern, position: 3))
        #expect(timetable.stop(gtfsID: "399999") == nil)
        #expect(stats.passThroughStopsDropped == 1)
        #expect(stats.passThroughEventsDropped == 2)
        #expect(timetable.departures(ofTrip: express) == [25_200, 25_500, 27_600, 27_900])
    }

    @Test func parsesSingleDigitHoursWithBlanks() throws {
        let trip = try #require(timetable.trip("BX12-1"))
        #expect(timetable.departure(trip: trip, position: 0) == hms(5, 7))
    }

    @Test func classifiesRoutes() throws {
        func mode(of trip: String) throws -> RouteMode {
            timetable.route(timetable.tripRoute(try #require(timetable.trip(trip)))).mode
        }
        #expect(try mode(of: "BX12-1") == .sbs)
        #expect(try mode(of: "X27-1") == .expressBus)
        #expect(try mode(of: "BXM1-1") == .expressBus)
        #expect(try mode(of: "Q06-1") == .localBus)
        #expect(timetable.routeCount == 4)   // M15 has no trips
        let sbs = timetable.route(timetable.tripRoute(try #require(timetable.trip("BX12-1"))))
        #expect(sbs.shortName == "Bx12-SBS" && sbs.color == 0x00AEEF && sbs.agencyGTFSID == "MTA NYCT")
        #expect(sbs.longName == "Pelham Bay - Inwood")   // route_desc is PATH's long name only

        for id in ["X27", "X28", "BM1", "BXM10", "BxM2", "QM21", "SIM1C", "SIM4X"] {
            #expect(GTFSTimetableCompiler.mode(system: .bus, routeID: id) == .expressBus, "\(id)")
        }
        for id in ["M15+", "BX12+", "S79+", "Q52+", "M14A+"] {
            #expect(GTFSTimetableCompiler.mode(system: .bus, routeID: id) == .sbs, "\(id)")
        }
        for id in ["B44", "BX1", "Q06", "S40", "M15", "BX4A"] {
            #expect(GTFSTimetableCompiler.mode(system: .bus, routeID: id) == .localBus, "\(id)")
        }
        #expect(GTFSTimetableCompiler.mode(system: .subway, routeID: "FX") == .subway)
    }

    @Test func mapsBareTripIDsToAgencyAndTrip() throws {
        let matches = timetable.busTrips(bareTripID: "Q06-1")
        #expect(matches.count == 1)
        #expect(matches.first?.agencyGTFSID == "MTABC")
        #expect(matches.first.map { timetable.tripGTFSID($0.trip) } == "Q06-1")
        #expect(timetable.busTrips(bareTripID: "Q06-9").isEmpty)
        #expect(timetable.busTrips(bareTripID: "X27-2").first?.agencyGTFSID == "MTA NYCT")
    }

    @Test func eachZipIsItsOwnSlot() throws {
        #expect(timetable.sourceCount == 2)
        // gtfs_busco has no weekend service but still claims the dates in its calendar range.
        let saturday = date("20261010")
        #expect(timetable.covers(saturday))
        #expect(timetable.isSourceSelected(0, on: saturday) && timetable.isSourceSelected(1, on: saturday))
        #expect(timetable.dayView(for: saturday).activeTripCount == 4)
        #expect(timetable.dayView(for: date("20261012")).activeTripCount == 7)
    }

    @Test func coverageRequiresEveryZipAndExtrapolatesALapsedOne() throws {
        #expect(timetable.slotCount == 2)
        // gtfs_bx runs to 10/31, gtfs_busco to 10/30: the system is covered through 10/30 only.
        let lastBronx = date("20261031")
        #expect(timetable.dayCount == 27)
        #expect(timetable.coveredDates.last == date("20261030"))
        #expect(!timetable.covers(lastBronx))
        #expect(timetable.slotCovers(0, on: lastBronx) && !timetable.slotCovers(1, on: lastBronx))
        let partial = timetable.dayView(for: lastBronx, extrapolate: true)
        #expect(!partial.isCovered && !partial.isExtrapolated)   // Saturday: busco would not run anyway
        #expect(partial.activeTripCount == 4)
        // Monday 11/02 is past both zips: each extrapolates its own newest calendar.
        let monday = date("20261102")
        #expect(timetable.dayView(for: monday).activeTripCount == 0)
        let extrapolated = timetable.dayView(for: monday, extrapolate: true)
        #expect(extrapolated.isExtrapolated && extrapolated.activeTripCount == 7)
        // Up to 14 days past a rule's end date (busco ends 10/30), never more.
        #expect(timetable.dayView(for: date("20261113"), extrapolate: true).activeTripCount == 7)
        #expect(timetable.dayView(for: date("20261116"), extrapolate: true).activeTripCount == 0)
    }
}

@Suite struct LIRRCompileTests {
    let scratch: ScratchDirectory
    let timetable: Timetable
    let stats: GTFSSystemStats

    init() throws {
        scratch = try ScratchDirectory()
        let (data, stats) = try compileFixture(.lirr, [("gtfslirr", "lirr", 0, Fixture.lirr)], scratch: scratch)
        self.stats = stats
        timetable = try roundTrip(data, scratch: scratch)
    }

    @Test func handlesCalendarDatesOnlyFeeds() throws {
        #expect(timetable.coveredDates == [date("20261005"), date("20261006")])
        #expect(timetable.timeZone.identifier == "America/New_York")   // agency_timezone, not feed_timezone
        let go1 = try #require(timetable.trip("GO_1"))
        let go3 = try #require(timetable.trip("GO_3"))
        #expect(timetable.isActive(trip: go1, on: date("20261005")))
        #expect(!timetable.isActive(trip: go3, on: date("20261005")))
        #expect(timetable.isActive(trip: go3, on: date("20261006")))
        let rule = timetable.rule(timetable.tripRule(go1))
        #expect(rule.validRange == nil && rule.weekdayMask == 0)
        // calendar_dates-only rules never extrapolate.
        #expect(!timetable.isActiveExtrapolated(rule: timetable.tripRule(go1), on: date("20261007")))
        #expect(timetable.tripShortName(go1) == "1")
        #expect(timetable.stopCode(try #require(timetable.stop(gtfsID: "102"))) == "JAM")
    }

    @Test func keepsGuaranteedTripTransfers() throws {
        let go1 = try #require(timetable.trip("GO_1"))
        let go2 = try #require(timetable.trip("GO_2"))
        let guaranteed = timetable.guaranteedTransfers(fromTrip: go1)
        #expect(guaranteed.count == 1)
        #expect(guaranteed.first?.toTrip == go2)
        #expect(guaranteed.first.map { timetable.stopGTFSID($0.fromStop) } == "102")
        #expect(timetable.guaranteedTransfers(fromTrip: go2).isEmpty)
        #expect(timetable.transferCount == 2)
        #expect(stats.guaranteedTripTransfers == 1)
    }

    @Test func flagsPeakTrips() throws {
        // trips.txt peak_offpeak: GO_3 is 1, the others 0.
        let go1 = try #require(timetable.trip("GO_1")), go3 = try #require(timetable.trip("GO_3"))
        #expect(timetable.isPeak(trip: go3) && timetable.tripFlags(go3) == .peak)
        #expect(!timetable.isPeak(trip: go1) && timetable.tripFlags(go1) == [])
        #expect(timetable.raw.tripFlags.count == timetable.tripCount)
        #expect(stats.tripsPeak == 1)
    }

    @Test func dropsStationsNoTrainServes() throws {
        #expect(timetable.stop(gtfsID: "26") == nil)
        let go1 = try #require(timetable.trip("GO_1"))
        #expect(timetable.stopIDs(ofPattern: timetable.tripPattern(go1)) == ["237", "102", "27"])
        #expect(timetable.arrival(trip: go1, position: 1) == hms(8, 20))
        #expect(timetable.departure(trip: go1, position: 1) == hms(8, 21))
        #expect(timetable.route(0).mode == .lirr)
        #expect(timetable.route(0).agencyGTFSID == "LI")   // routes.txt omits agency_id
        #expect(timetable.lookupsExactTripIDs())
    }
}

extension Timetable {
    fileprivate func lookupsExactTripIDs() -> Bool {
        (0..<tripCount).allSatisfy { trips(gtfsID: tripGTFSID($0)) == [$0] }
    }
}

@Suite struct FrequenciesTests {
    @Test func failsOnFrequencyBasedTrips() throws {
        let scratch = try ScratchDirectory()
        // A header alone (siferry ships one) is fine.
        let empty = try scratch.feed("ferry-empty", Fixture.ferry)
        #expect(try GTFSFeed.parse(empty, source: GTFSSourceInfo(name: "siferry", slot: "siferry")).frequencyRows == 0)
        var files = Fixture.ferry
        files["frequencies.txt"]! += "weekdaystgeorge000000,06:00:00,09:00:00,900,1\nweekdaystgeorge000000,16:00:00,19:00:00,900,1\n"
        let feed = try scratch.feed("ferry-frequencies", files)
        #expect(throws: GTFSError.frequenciesNotSupported(feed: feed.location, rows: 2)) {
            try GTFSFeed.parse(feed, source: GTFSSourceInfo(name: "siferry", slot: "siferry"))
        }
    }

    @Test func ignoresFrequencyRowsThatNameNoTrip() throws {
        let scratch = try ScratchDirectory()
        // A trailing line of bare commas and a row for a trip the feed doesn't have mis-model nothing.
        var files = Fixture.ferry
        files["frequencies.txt"]! += ",,,,\nnosuchtrip,06:00:00,09:00:00,900,1\n"
        let parsed = try GTFSFeed.parse(try scratch.feed("ferry-blank-frequencies", files),
                                        source: GTFSSourceInfo(name: "siferry", slot: "siferry"))
        #expect(parsed.frequencyRows == 0)
        #expect(parsed.issues["frequencies.txt: row without a known trip_id (ignored)"] == 2)
        // One row naming a real trip among them still fails.
        files["frequencies.txt"]! += "weekdaywhitehall003000,16:00:00,19:00:00,900,1\n"
        let feed = try scratch.feed("ferry-mixed-frequencies", files)
        #expect(throws: GTFSError.frequenciesNotSupported(feed: feed.location, rows: 1)) {
            try GTFSFeed.parse(feed, source: GTFSSourceInfo(name: "siferry", slot: "siferry"))
        }
    }
}

@Suite struct StopKindSanitizingTests {
    @Test func treatsLocationTypesOutsideGTFSAsStops() throws {
        let scratch = try ScratchDirectory()
        // The writer and every reader refuse stop kinds past 4, so the parser maps them to 0 and
        // notes it rather than failing the whole build.
        var files = Fixture.ferry
        files["stops.txt"] = files["stops.txt"]!.replacingOccurrences(of: "-74.012666,0", with: "-74.012666,5")
        #expect(files["stops.txt"]!.hasSuffix(",5"))
        let feed = try GTFSFeed.parse(try scratch.feed("ferry-location-type", files), source: GTFSSourceInfo(name: "siferry", slot: "siferry"))
        #expect(feed.issues["stops.txt: location_type not 0–4 (treated as 0)"] == 1)
        let (data, _) = try GTFSTimetableCompiler.compile(system: .ferry, feeds: [feed], options: GTFSCompileOptions(windowStart: Fixture.windowStart))
        let timetable = try roundTrip(data, scratch: scratch)
        #expect(timetable.stopKind(try #require(timetable.stop(gtfsID: "whitehall"))) == .stop)
    }
}

@Suite struct ZippedFeedTests {
    @Test func readsAZipWhoseFilesSitInASubdirectory() throws {
        let runner = ProcessToolRunner()
        guard runner.locate("zip") != nil, runner.locate("unzip") != nil else {
            print("skipping: zip/unzip not installed")
            return
        }
        let scratch = try ScratchDirectory()
        _ = try scratch.feed("siferry-gtfs_2026.1", Fixture.ferry)
        let archive = scratch.url.appendingPathComponent("siferry.zip")
        _ = try runner.run(executable: "sh", args: ["-c", "cd \"$0\" && zip -qr siferry.zip siferry-gtfs_2026.1", scratch.url.path])
        let files = try ZipGTFSFeed(archive: archive, runner: runner)
        #expect(files.fileNames().contains("stop_times.txt"))
        let feed = try GTFSFeed.parse(files, source: GTFSSourceInfo(name: "siferry", slot: "siferry"))
        #expect(feed.tripCount == 3)
        #expect(feed.frequencyRows == 0)
        let (data, stats) = try GTFSTimetableCompiler.compile(system: .ferry, feeds: [feed], options: GTFSCompileOptions(windowStart: Fixture.windowStart))
        #expect(stats.tripsDroppedInactive == 1)   // threeboat never runs
        let timetable = try roundTrip(data, scratch: scratch)
        #expect(timetable.system == .ferry)
        #expect(timetable.header.kind == .ttFerry)
        #expect(timetable.route(0).mode == .ferry)
        #expect(timetable.tripCount == 2)
        #expect(timetable.dayView(for: date("20261006")).activeTripCount == 2)
        #expect(timetable.patternCount == 2)
    }
}
