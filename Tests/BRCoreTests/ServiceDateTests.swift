import BRCore
import Foundation
import Testing

@Suite struct ServiceDateTests {
    @Test func parsesYYYYMMDD() throws {
        let date = try #require(ServiceDate(yyyymmdd: "20261101"))
        #expect((date.year, date.month, date.day) == (2026, 11, 1))
        #expect(date.yyyymmdd == "20261101")
        #expect(date.description == "2026-11-01")
        #expect(ServiceDate(yyyymmddBytes: Array("20240229".utf8)) == ServiceDate(year: 2024, month: 2, day: 29))
    }

    @Test(arguments: ["", "2026111", "202611011", "2026-1101", "20261301", "20260230", "20250229", "00001231", "2026110a"])
    func rejectsMalformedDates(text: String) {
        #expect(ServiceDate(yyyymmdd: text) == nil)
    }

    @Test func addsDaysAcrossMonthsYearsAndLeapDays() {
        let feb28 = ServiceDate(year: 2028, month: 2, day: 28)
        #expect(feb28.adding(days: 1) == ServiceDate(year: 2028, month: 2, day: 29))
        #expect(feb28.adding(days: 2) == ServiceDate(year: 2028, month: 3, day: 1))
        #expect(ServiceDate(year: 2026, month: 12, day: 31).adding(days: 1) == ServiceDate(year: 2027, month: 1, day: 1))
        #expect(ServiceDate(year: 2027, month: 1, day: 1).adding(days: -1) == ServiceDate(year: 2026, month: 12, day: 31))
        #expect(ServiceDate(year: 2026, month: 10, day: 31).adding(days: 63) == ServiceDate(year: 2027, month: 1, day: 2))
    }

    @Test func daysSinceEpochRoundTripsOverFourCenturies() {
        var date = ServiceDate(year: 1900, month: 1, day: 1)
        let end = ServiceDate(year: 2300, month: 1, day: 1)
        var expected = date.daysSinceEpoch
        while date < end {
            #expect(ServiceDate(daysSinceEpoch: date.daysSinceEpoch) == date)
            #expect(date.daysSinceEpoch == expected)
            date = date.adding(days: 1)
            expected += 1
        }
        #expect(ServiceDate(year: 1970, month: 1, day: 1).daysSinceEpoch == 0)
    }

    @Test func weekdays() {
        #expect(ServiceDate(year: 1970, month: 1, day: 1).weekday == .thursday)
        #expect(ServiceDate(year: 2026, month: 9, day: 24).weekday == .thursday)
        #expect(ServiceDate(year: 2026, month: 11, day: 1).weekday == .sunday)
        #expect(ServiceDate(year: 2027, month: 3, day: 15).weekday == .monday)
        #expect(ServiceDate(year: 1969, month: 12, day: 29).weekday == .monday)
    }

    @Test func ordersAndStrides() {
        let start = ServiceDate(year: 2026, month: 10, day: 30)
        let end = ServiceDate(year: 2026, month: 11, day: 2)
        #expect(start < end)
        #expect(start.distance(to: end) == 3)
        #expect(Array(start...end).map(\.day) == [30, 31, 1, 2])
    }

    @Test func codesAsGTFSString() throws {
        let dates = [ServiceDate(year: 2026, month: 11, day: 1)]
        let json = try JSONEncoder().encode(dates)
        #expect(String(decoding: json, as: UTF8.self) == #"["20261101"]"#)
        #expect(try JSONDecoder().decode([ServiceDate].self, from: json) == dates)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([ServiceDate].self, from: Data(#"["2026-11-01"]"#.utf8)) }
    }

    @Test func containingDateUsesTheGivenTimeZone() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-09-25T02:30:00Z"))
        #expect(ServiceDate(containing: instant, in: .nyc) == ServiceDate(year: 2026, month: 9, day: 24))
        #expect(ServiceDate(containing: instant, in: try #require(TimeZone(identifier: "Asia/Tokyo"))) == ServiceDate(year: 2026, month: 9, day: 25))
    }
}

@Suite struct ClockTests {
    @Test func fixedClockParsesOffsetTimestamps() throws {
        let clock = try #require(FixedClock(iso8601: "2026-11-01T01:30:00-05:00"))
        #expect(clock.now == Date(timeIntervalSince1970: 1_793_514_600))
        #expect(FixedClock(iso8601: "yesterday") == nil)
    }

    @Test func clocksAreUsableAsExistentials() {
        let clocks: [any Clock] = [SystemClock(), FixedClock(Date(timeIntervalSince1970: 0))]
        #expect(clocks[1].now == Date(timeIntervalSince1970: 0))
        #expect(abs(clocks[0].now.timeIntervalSinceNow) < 5)
    }
}
