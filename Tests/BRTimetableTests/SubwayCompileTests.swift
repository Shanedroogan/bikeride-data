import BRBuild
import BRCore
import BRTimetable
import Foundation
import Testing

@Suite struct SubwayCompileTests {
    let scratch: ScratchDirectory
    let timetable: Timetable
    let stats: GTFSSystemStats

    init() throws {
        scratch = try ScratchDirectory()
        // The regular feed is listed first; priority, not order, must decide.
        let (data, stats) = try compileFixture(.subway, [
            ("gtfs_subway", "subway", 1, Fixture.subwayRegular),
            ("gtfs_supplemented", "subway", 0, Fixture.subwaySupplemented),
        ], scratch: scratch)
        self.stats = stats
        timetable = try roundTrip(data, scratch: scratch)
    }

    @Test func picksExactlyOneSourcePerDateAndNeverExtendsCalendars() throws {
        #expect(timetable.windowStart == date("20261005"))
        #expect(timetable.dayCount == 12)
        #expect(timetable.coveredDates.first == date("20261005"))
        #expect(timetable.coveredDates.last == date("20261016"))
        #expect(!timetable.covers(date("20261017")))

        let supplemented = try #require((0..<timetable.sourceCount).first { timetable.source($0).name == "gtfs_supplemented" })
        let regular = try #require((0..<timetable.sourceCount).first { timetable.source($0).name == "gtfs_subway" })
        #expect(timetable.source(supplemented).version == "SUPP-1")
        #expect(timetable.source(supplemented).etag == "\"gtfs_supplemented-etag\"")
        #expect(timetable.source(supplemented).selectedDates == (5...11).map { date("202610\(String(format: "%02d", $0))") })
        #expect(timetable.source(regular).selectedDates == (12...16).map { date("202610\($0)") })
        for day in timetable.coveredDates {
            let chosen = (0..<timetable.sourceCount).filter { timetable.isSourceSelected($0, on: day) }
            #expect(chosen.count == 1)
        }

        let regularTrip = try #require(timetable.trip("REG-Weekday-00_066000_1..S03R"))
        let supplementedTrip = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_060000_1..S03R"))
        // Both feeds claim Tuesday the 6th; only the supplemented one runs it.
        #expect(timetable.isActive(trip: supplementedTrip, on: date("20261006")))
        #expect(!timetable.isActive(trip: regularTrip, on: date("20261006")))
        #expect(timetable.isActive(trip: regularTrip, on: date("20261013")))
        #expect(!timetable.isActive(trip: supplementedTrip, on: date("20261013")))
        #expect(!timetable.isActive(trip: regularTrip, on: date("20261019")))
        #expect(stats.sources.map(\.name) == ["gtfs_supplemented", "gtfs_subway"])
    }

    @Test func appliesCalendarDateExceptions() throws {
        let weekday = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_060000_1..S03R"))
        let saturday = try #require(timetable.trip("ASP26GEN-1038-Saturday-00_060200_1..S03R"))
        #expect(timetable.isActive(trip: weekday, on: date("20261006")))
        #expect(!timetable.isActive(trip: weekday, on: date("20261007")))   // removed
        #expect(timetable.isActive(trip: saturday, on: date("20261007")))   // added
        #expect(timetable.isActive(trip: saturday, on: date("20261010")))
        #expect(!timetable.isActive(trip: saturday, on: date("20261011")))  // Sunday

        let rule = timetable.rule(timetable.tripRule(weekday))
        #expect(rule.gtfsID == "WKD")
        #expect(rule.weekdayMask == 0b001_1111)
        #expect(rule.validRange == date("20261005")...date("20261011"))
        #expect(rule.exceptions.count == 1)
        #expect(rule.exceptions[0].0 == date("20261007") && rule.exceptions[0].1 == false)
    }

    @Test func splitsPatternsOnlyWhereCoActiveTripsOvertake() throws {
        #expect(stats.patternsBeforeFIFO == 3)   // route 1 supplemented, route 1 regular, GS
        #expect(stats.patternsAfterFIFO == 4)
        let slow = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_060000_1..S03R"))
        let fast = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_060500_1..S03R"))
        let saturday = try #require(timetable.trip("ASP26GEN-1038-Saturday-00_060200_1..S03R"))
        let night = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_151000_1..S03R"))
        #expect(timetable.tripPattern(slow) != timetable.tripPattern(fast))
        #expect(timetable.patternBaseKey(timetable.tripPattern(slow)) == timetable.patternBaseKey(timetable.tripPattern(fast)))
        // The Saturday trip overtakes the slow one but never shares a day with it.
        #expect(timetable.tripPattern(saturday) == timetable.tripPattern(slow))
        #expect(timetable.tripPattern(night) == timetable.tripPattern(slow))
        // Trips are sorted by first departure within the pattern.
        #expect(Array(timetable.patternTrips(timetable.tripPattern(slow))) == [slow, saturday, night])

        // Every day view is FIFO at every stop.
        for day in timetable.coveredDates {
            let view = timetable.dayView(for: day)
            for pattern in 0..<timetable.patternCount {
                let trips = view.activeTrips(inPattern: pattern)
                for position in 0..<timetable.patternStopCount(pattern) {
                    let times = trips.map { timetable.departure(trip: Int($0), position: position) }
                    #expect(times == times.sorted())
                    let arrivals = trips.map { timetable.arrival(trip: Int($0), position: position) }
                    #expect(arrivals == arrivals.sorted())
                }
            }
        }
    }

    @Test func storesTimesPastMidnightAndFindsThemFromTheNextDay() throws {
        let night = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_151000_1..S03R"))
        #expect(timetable.departures(ofTrip: night) == [hms(25, 10), hms(25, 12), hms(25, 14)])
        // A query at 00:30 on Tuesday the 6th scans Monday's view (D−1).
        let monday = timetable.dayView(for: date("20261005"))
        let pattern = timetable.tripPattern(night)
        #expect(monday.activeTrips(inPattern: pattern).contains(UInt32(night)))
        let offset = ServiceDayTime.offsetSeconds(from: date("20261006"), to: date("20261005"), in: timetable.timeZone)
        #expect(Int32(timetable.departure(trip: night, position: 0)) + offset == 3600 + 600)   // 01:10 Tuesday
        #expect(timetable.dayView(for: date("20261005")) === monday)   // cached
    }

    @Test func keepsArrivalsOnlyWhereTheyDiffer() throws {
        let slow = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_060000_1..S03R"))
        let pattern = timetable.tripPattern(slow)
        #expect(!timetable.patternFlags(pattern).contains(.arrivalEqualsDeparture))
        #expect(timetable.arrival(trip: slow, position: 1) == hms(10, 10))
        #expect(timetable.departure(trip: slow, position: 1) == hms(10, 10, 30))
        let fast = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_060500_1..S03R"))
        #expect(timetable.patternFlags(timetable.tripPattern(fast)).contains(.arrivalEqualsDeparture))
        #expect(timetable.patternArrivals(timetable.tripPattern(fast)).baseAddress
            == timetable.patternDepartures(timetable.tripPattern(fast)).baseAddress)
    }

    @Test func modelsStopsWithParentsAndNamespacedIDs() throws {
        let platform = try #require(timetable.stop(gtfsID: "101S"))
        let station = try #require(timetable.stopParent(platform))
        #expect(timetable.stopGTFSID(station) == "101")
        #expect(timetable.stopKind(station) == .station)
        #expect(timetable.stopKind(platform) == .stop)
        #expect(timetable.stopID(platform) == StopID("S:101S"))
        #expect(timetable.stop(id: StopID("S:101S")) == platform)
        #expect(timetable.stop(id: StopID("B:101S")) == nil)
        #expect(timetable.stopName(platform) == "Van Cortlandt Park-242 St")
        let coordinate = timetable.stopCoordinate(platform)
        #expect(abs(coordinate.lat - 40.889248) < 1e-9 && abs(coordinate.lon + 73.898583) < 1e-9)
        // Stops no trip calls at are dropped, unless they are a called stop's parent.
        #expect(timetable.stop(gtfsID: "999S") == nil)
        #expect(timetable.stop(gtfsID: "999") == nil)
        #expect(timetable.stopCount == 10)

        // stop → patterns index
        let refs = timetable.patterns(servingStop: platform)
        #expect(refs.count == 3)
        for ref in refs {
            #expect(Int(timetable.patternStops(ref.pattern)[ref.position]) == platform)
        }
    }

    @Test func keepsParentLevelTransfersAndDropsDanglingOnes() throws {
        #expect(timetable.transferCount == 2)
        #expect(stats.transfersDropped == 1)
        let rows = (0..<timetable.transferCount).map(timetable.transfer)
        let gct = try #require(rows.first { timetable.stopGTFSID($0.fromStop) == "901" })
        #expect(timetable.stopGTFSID(gct.toStop) == "902")
        #expect(gct.type == 2 && gct.minTransferSeconds == 300 && gct.fromTrip == nil)
    }

    @Test func buildsRealtimeKeysFromStaticTripIDs() throws {
        let slow = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_060000_1..S03R"))
        let matches = timetable.subwayTrips(route: "1", direction: UInt8(ascii: "S"), originHundredths: 60000)
        #expect(matches.map(\.trip) == [slow])
        #expect(matches.first?.path == "03R")
        let key = try #require(SubwayTripKey(realtimeTripID: "086750_GS.S04R"))
        let shuttle = try #require(timetable.trip("BFA26GEN-GS049-Weekday-00_086750_GS.S04R"))
        #expect(timetable.subwayTrips(matching: key) == [shuttle])
        #expect(timetable.subwayTrips(route: "1", direction: UInt8(ascii: "N"), originHundredths: 60000).isEmpty)
        #expect(stats.subwayKeys == 6 && stats.subwayKeyParseFailures == 0)
    }

    @Test func simplifiesShapesKeepingStopVertices() throws {
        let slow = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_060000_1..S03R"))
        let pattern = timetable.tripPattern(slow)
        let shape = try #require(timetable.patternShape(pattern))
        #expect(timetable.shapeGTFSID(shape) == "1..S03R")
        #expect(timetable.shapePoints(shape).count == 3)
        #expect(Array(timetable.patternShapeVertices(pattern)) == [UInt32]([0, 1, 2]))
        // The shuttle has no shape: one is drawn through its stops.
        let shuttle = try #require(timetable.trip("BFA26GEN-GS049-Weekday-00_086750_GS.S04R"))
        let shuttlePattern = timetable.tripPattern(shuttle)
        #expect(timetable.patternFlags(shuttlePattern).contains(.synthesizedShape))
        #expect(timetable.shapePoints(try #require(timetable.patternShape(shuttlePattern))).count == 2)
    }

    @Test func describesRoutes() throws {
        let slow = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_060000_1..S03R"))
        let route = timetable.route(timetable.tripRoute(slow))
        #expect(route.id == RouteID("S:1"))
        #expect(route.agencyGTFSID == "MTA NYCT")
        #expect(route.shortName == "1")
        #expect(route.color == 0xD82233 && route.textColor == 0xFFFFFF)
        #expect(route.mode == .subway)
        #expect(timetable.routeCount == 2)   // route 1 from both feeds is one route
        #expect(timetable.tripHeadsign(slow) == "South Ferry")
        #expect(timetable.tripDirection(slow) == 1)
        #expect(timetable.tripID(slow) == TripID("S:ASP26GEN-1038-Weekday-00_060000_1..S03R"))
    }

    @Test func extrapolatesOnlyTheNewestCalendarPastCoverage() throws {
        let regular = try #require(timetable.trip("REG-Weekday-00_066000_1..S03R"))
        let supplemented = try #require(timetable.trip("ASP26GEN-1038-Weekday-00_060000_1..S03R"))
        let regularRule = timetable.tripRule(regular)
        #expect(!timetable.isActiveExtrapolated(rule: regularRule, on: date("20261014")))   // covered: not extrapolation
        #expect(timetable.isActiveExtrapolated(rule: regularRule, on: date("20261020")))    // Tuesday, end + 4
        #expect(!timetable.isActiveExtrapolated(rule: regularRule, on: date("20261024")))   // Saturday
        #expect(timetable.isActiveExtrapolated(rule: regularRule, on: date("20261030")))    // end + 14
        #expect(!timetable.isActiveExtrapolated(rule: regularRule, on: date("20261102")))   // end + 17
        #expect(!timetable.isActiveExtrapolated(rule: timetable.tripRule(supplemented), on: date("20261020")))
        let view = timetable.dayView(for: date("20261020"), extrapolate: true)
        #expect(view.isExtrapolated && !view.isCovered)
        #expect(view.activeTripCount == 1)
        #expect(timetable.dayView(for: date("20261020")).activeTripCount == 0)
    }
}
