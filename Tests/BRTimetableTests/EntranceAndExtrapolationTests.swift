import BRBuild
import BRCore
import BRTimetable
import Foundation
import Testing

@Suite struct SubwayEntranceTests {
    let scratch: ScratchDirectory
    let timetable: Timetable
    let stats: GTFSSystemStats
    let issues: [String: Int]

    init() throws {
        scratch = try ScratchDirectory()
        let csv = scratch.url.appendingPathComponent("subway-entrances.csv")
        try Data(Fixture.entrancesCSV.utf8).write(to: csv)
        let parsed = try SubwayEntrances.parse(fileAt: csv)
        issues = parsed.issues
        let (data, stats) = try compileFixture(.subway, [("gtfs_supplemented", "subway", 0, Fixture.subwaySupplemented)],
                                               entrances: parsed.entrances, scratch: scratch)
        self.stats = stats
        timetable = try roundTrip(data, scratch: scratch)
    }

    @Test func parsesTheDatasetExport() {
        #expect(issues == ["entrance without coordinates": 1, "entrance shared by several stations": 1])
        #expect(stats.entrances == 5)          // 3 at 101, 1 each at 901 and 902
        #expect(stats.entrancesUnmatched == 1) // Z99
    }

    @Test func addsEntrancesUnderTheirStation() throws {
        let station = try #require(timetable.stop(gtfsID: "101"))
        let entrances = timetable.entrances(ofStation: station)
        #expect(entrances.map(timetable.stopGTFSID) == ["101-E1", "101-E2", "101-E3"])
        // Numbered by (lat, lon): the exit-only stair is southernmost.
        let exitOnly = try #require(timetable.stop(gtfsID: "101-E1"))
        #expect(timetable.stopKind(exitOnly) == .entrance)
        #expect(timetable.stopParent(exitOnly) == station)
        #expect(timetable.stopAccess(exitOnly) == [.exit])
        #expect(timetable.stopEntranceType(exitOnly) == "Stair")
        #expect(timetable.stopName(exitOnly) == "Van Cortlandt Park-242 St")
        #expect(abs(timetable.stopCoordinate(exitOnly).lat - 40.889) < 1e-9)
        let elevator = try #require(timetable.stop(gtfsID: "101-E2"))
        #expect(timetable.stopEntranceType(elevator) == "Elevator" && timetable.stopAccess(elevator) == [.entry, .exit])
        #expect(timetable.patterns(servingStop: elevator).isEmpty)
        #expect(timetable.stopID(elevator) == StopID("S:101-E2"))
        // Platforms and entrances are both children of the station.
        let platform = try #require(timetable.stop(gtfsID: "101S"))
        #expect(timetable.children(ofStop: station).map { Int($0) } == [platform] + entrances)
        #expect(timetable.stopAccess(platform) == [.entry, .exit] && timetable.stopEntranceType(platform) == "")
        #expect(timetable.children(ofStop: platform).isEmpty)
    }

    @Test func splitsComplexEntrancesAcrossStations() throws {
        for id in ["901", "902"] {
            let station = try #require(timetable.stop(gtfsID: id))
            let entrances = timetable.entrances(ofStation: station)
            #expect(entrances.count == 1)
            #expect(entrances.first.map(timetable.stopAccess) == [.entry])
            #expect(entrances.first.map(timetable.stopEntranceType) == "Easement - Passage")
        }
        #expect(timetable.stopCount == 15)
    }
}

@Suite struct ExtrapolationTests {
    @Test func copiesAReferenceDayInsteadOfEveryMatchingWeekdayMask() throws {
        let scratch = try ScratchDirectory()
        let (data, stats) = try compileFixture(.ferry, [("feed", "feed", 0, Fixture.extrapolatedOvertake)], scratch: scratch)
        let timetable = try roundTrip(data, scratch: scratch)
        // The two trips never share a day, so the overtaking one needs no FIFO split.
        #expect(stats.patternsBeforeFIFO == 1 && stats.patternsAfterFIFO == 1)
        let slow = try #require(timetable.trip("slow"))
        let fast = try #require(timetable.trip("fast"))
        for day in timetable.coveredDates {
            #expect(!(timetable.isActive(trip: slow, on: day) && timetable.isActive(trip: fast, on: day)))
        }
        // Both rules have Monday masks, but only MONA ran on the covered Mondays (10/05, 10/12).
        #expect(timetable.extrapolationReferenceDate(slot: 0, weekday: .monday) == date("20261012"))
        #expect(timetable.extrapolationReferenceDate(slot: 0, weekday: .saturday) == date("20261010"))
        let view = timetable.dayView(for: date("20261019"), extrapolate: true)
        #expect(view.isExtrapolated && !view.isCovered)
        #expect(view.activeTripCount == 1)
        #expect(view.activeTrips(inPattern: timetable.tripPattern(slow)).map { Int($0) } == [slow])
        #expect(!timetable.isActiveExtrapolated(rule: timetable.tripRule(fast), on: date("20261019")))
        // Inside coverage nothing is extrapolated.
        #expect(!timetable.isActiveExtrapolated(rule: timetable.tripRule(slow), on: date("20261012")))
    }

    @Test func outvotesAHolidayOnTheLastCoveredWeekday() throws {
        // Weekday service Mon–Fri for three weeks; the last Friday (10/23) runs the holiday rule.
        var files = Fixture.extrapolatedOvertake
        files["calendar.txt"] = """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            MONA,1,1,1,1,1,0,0,20261005,20261023
            MONB,0,0,0,0,0,0,0,20261005,20261023
            """
        files["calendar_dates.txt"] = """
            service_id,date,exception_type
            MONA,20261023,2
            MONB,20261023,1
            """
        let scratch = try ScratchDirectory()
        let (data, _) = try compileFixture(.ferry, [("feed", "feed", 0, files)], scratch: scratch)
        let timetable = try roundTrip(data, scratch: scratch)
        #expect(timetable.extrapolationReferenceDate(slot: 0, weekday: .friday) == date("20261016"))
        let friday = timetable.dayView(for: date("20261030"), extrapolate: true)
        #expect(friday.activeTripCount == 1)
        let slow = try #require(timetable.trip("slow"))
        #expect(timetable.isActiveExtrapolated(rule: timetable.tripRule(slow), on: date("20261030")))
        // MONB ran only on the holiday, so it is outvoted.
        let fast = try #require(timetable.trip("fast"))
        #expect(!timetable.isActiveExtrapolated(rule: timetable.tripRule(fast), on: date("20261030")))
    }
}
