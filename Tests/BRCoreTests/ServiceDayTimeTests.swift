import BRCore
import Foundation
import Testing

@Suite struct ServiceDayTimeTests {
    let tz = TimeZone.nyc

    private func instant(_ iso: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: iso) else { preconditionFailure("bad ISO \(iso)") }
        return date
    }

    private func dayLength(_ day: ServiceDate) -> TimeInterval {
        ServiceDayTime.origin(of: day.adding(days: 1), in: tz).timeIntervalSince(ServiceDayTime.origin(of: day, in: tz))
    }

    private func wallClock(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    @Test func originIsLocalNoonMinusTwelveHours() {
        // 2026-11-01 noon is EST (17:00Z); the origin lands on 01:00 EDT, before the repeat.
        #expect(ServiceDayTime.origin(of: ServiceDate(year: 2026, month: 11, day: 1), in: tz) == instant("2026-11-01T05:00:00Z"))
        // 2027-03-14 noon is EDT (16:00Z); the origin is 23:00 EST the evening before.
        #expect(ServiceDayTime.origin(of: ServiceDate(year: 2027, month: 3, day: 14), in: tz) == instant("2027-03-14T04:00:00Z"))
        #expect(ServiceDayTime.origin(of: ServiceDate(year: 2026, month: 9, day: 24), in: tz) == instant("2026-09-24T04:00:00Z"))
    }

    @Test func fallBackGivesA25HourGap() {
        let oct31 = ServiceDate(year: 2026, month: 10, day: 31)
        #expect(dayLength(oct31) == 25 * 3600)
        #expect(ServiceDayTime.offsetSeconds(from: oct31.adding(days: 1), to: oct31, in: tz) == -25 * 3600)
    }

    @Test func springForwardGivesA23HourGap() {
        let mar13 = ServiceDate(year: 2027, month: 3, day: 13)
        #expect(dayLength(mar13) == 23 * 3600)
        #expect(ServiceDayTime.offsetSeconds(from: mar13, to: mar13.adding(days: 1), in: tz) == 23 * 3600)
    }

    @Test(arguments: [
        ServiceDate(year: 2026, month: 9, day: 24),
        ServiceDate(year: 2026, month: 12, day: 31),
        ServiceDate(year: 2028, month: 2, day: 28),
    ])
    func normalDaysAre24Hours(day: ServiceDate) {
        #expect(dayLength(day) == 24 * 3600)
        #expect(ServiceDayTime.offsetSeconds(from: day, to: day.adding(days: -1), in: tz) == -86_400)
    }

    @Test(arguments: [
        ("2026-09-24T08:15:30-04:00", ServiceDate(year: 2026, month: 9, day: 24)),
        ("2026-09-24T00:30:00-04:00", ServiceDate(year: 2026, month: 9, day: 23)),
        ("2026-11-01T01:30:00-04:00", ServiceDate(year: 2026, month: 11, day: 1)),
        ("2026-11-01T01:30:00-05:00", ServiceDate(year: 2026, month: 10, day: 31)),
        ("2027-03-14T03:30:00-04:00", ServiceDate(year: 2027, month: 3, day: 14)),
        ("2027-03-13T23:59:59-05:00", ServiceDate(year: 2027, month: 3, day: 14)),
    ])
    func engineSecondsRoundTrip(iso: String, serviceDay: ServiceDate) {
        let date = instant(iso)
        let seconds = ServiceDayTime.engineSeconds(for: date, serviceDay: serviceDay, tz: tz)
        #expect(ServiceDayTime.date(engineSeconds: seconds, serviceDay: serviceDay, tz: tz) == date)
    }

    @Test func engineSecondsRoundDownFractionalSeconds() {
        let day = ServiceDate(year: 2026, month: 9, day: 24)
        let origin = ServiceDayTime.origin(of: day, in: tz)
        #expect(ServiceDayTime.engineSeconds(for: origin.addingTimeInterval(59.9), serviceDay: day, tz: tz) == 59)
        #expect(ServiceDayTime.engineSeconds(for: origin.addingTimeInterval(-0.5), serviceDay: day, tz: tz) == -1)
    }

    @Test func gtfsTimePast24HoursOnPreviousDayIsEarlyMorningToday() {
        let today = ServiceDate(year: 2026, month: 9, day: 24)
        let yesterday = today.adding(days: -1)
        let gtfs2510: Int32 = 25 * 3600 + 10 * 60

        let departure = ServiceDayTime.date(engineSeconds: gtfs2510, serviceDay: yesterday, tz: tz)
        let local = wallClock(departure)
        #expect((local.year, local.month, local.day, local.hour, local.minute) == (2026, 9, 24, 1, 10))

        // The same trip in today's engine time, as a 00:30 query would see it in the D−1 view.
        let inTodaysFrame = ServiceDayTime.offsetSeconds(from: today, to: yesterday, in: tz) + gtfs2510
        #expect(inTodaysFrame == 1 * 3600 + 10 * 60)
        #expect(ServiceDayTime.engineSeconds(for: departure, serviceDay: today, tz: tz) == inTodaysFrame)
        let query = instant("2026-09-24T00:30:00-04:00")
        #expect(ServiceDayTime.engineSeconds(for: query, serviceDay: today, tz: tz) < inTodaysFrame)
    }

    @Test func repeatedFallBackHourGetsDistinctEngineSeconds() {
        let day = ServiceDate(year: 2026, month: 11, day: 1)
        let firstPass = instant("2026-11-01T01:30:00-04:00")  // EDT
        let secondPass = instant("2026-11-01T01:30:00-05:00") // EST
        #expect(wallClock(firstPass).hour == 1 && wallClock(secondPass).hour == 1)
        let first = ServiceDayTime.engineSeconds(for: firstPass, serviceDay: day, tz: tz)
        let second = ServiceDayTime.engineSeconds(for: secondPass, serviceDay: day, tz: tz)
        #expect(first == 1800)
        #expect(second - first == 3600)
    }

    @Test func gtfsNoonIsLocalNoonEvenOnDaylightSavingDays() {
        for day in [ServiceDate(year: 2026, month: 11, day: 1), ServiceDate(year: 2027, month: 3, day: 14)] {
            let noon = wallClock(ServiceDayTime.date(engineSeconds: 12 * 3600, serviceDay: day, tz: tz))
            #expect((noon.hour, noon.minute) == (12, 0))
        }
    }
}
