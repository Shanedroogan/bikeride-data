import BRCore
import BRFlows
import Foundation

/// Day types for the flows build, from `Data/config/calendar/holidays.csv` (the pipeline's only
/// holiday list, read directly so `flows` keeps an empty `builtAgainst`; format in that folder's
/// `SOURCES.md`). Saturdays, Sundays and holidays with the `weekend` profile are weekend days.
public struct FlowCalendar: Sendable, Equatable {
    public struct Holiday: Sendable, Equatable, Codable {
        public var date: ServiceDate
        public var name: String
        /// The profile is `weekend`: the date counts as a weekend day.
        public var weekendProfile: Bool
    }

    public let holidays: [Holiday]
    /// January 1 of the first listed year through December 31 of the last: the days the file
    /// vouches for (a date outside is not known to be an ordinary day).
    public let coverage: ClosedRange<ServiceDate>
    private let weekendHolidays: Set<ServiceDate>

    public init(holidays: [Holiday]) throws {
        guard let first = holidays.first, let last = holidays.last else { throw FlowsInputError.malformedHolidays("no rows") }
        for (index, holiday) in holidays.enumerated() {
            guard holiday.date.weekday != .saturday, holiday.date.weekday != .sunday else {
                throw FlowsInputError.malformedHolidays("\(holiday.date) is a weekend day")
            }
            if index > 0, holidays[index - 1].date >= holiday.date {
                throw FlowsInputError.malformedHolidays("dates are not strictly ascending at \(holiday.date)")
            }
        }
        self.holidays = holidays
        coverage = ServiceDate(year: first.date.year, month: 1, day: 1)...ServiceDate(year: last.date.year, month: 12, day: 31)
        weekendHolidays = Set(holidays.filter(\.weekendProfile).map(\.date))
    }

    /// Parses `date,name,profile` with a header row.
    public init(csv: Data) throws {
        var reader = CSVReader(bytes: csv)
        guard let headerRecord = try reader.next() else { throw FlowsInputError.malformedHolidays("empty file") }
        let header = CSVHeader(headerRecord)
        guard let dateColumn = header.index(of: "date"), let nameColumn = header.index(of: "name"),
              let profileColumn = header.index(of: "profile") else {
            throw FlowsInputError.malformedHolidays("needs date, name and profile columns")
        }
        var holidays: [Holiday] = []
        while let record = try reader.next() {
            guard let date = ServiceDate(yyyymmddBytes: record[dateColumn].bytes) else {
                throw FlowsInputError.malformedHolidays("row \(reader.recordCount): bad date '\(record[dateColumn].string)'")
            }
            let profile = record[profileColumn].string
            guard profile == "weekend" || profile == "weekday" else {
                throw FlowsInputError.malformedHolidays("row \(reader.recordCount): profile '\(profile)' is not weekend or weekday")
            }
            holidays.append(Holiday(date: date, name: record[nameColumn].string, weekendProfile: profile == "weekend"))
        }
        try self.init(holidays: holidays)
    }

    public func dayType(of date: ServiceDate) -> FlowDayType {
        if date.weekday == .saturday || date.weekday == .sunday || weekendHolidays.contains(date) { return .weekend }
        return .weekday
    }

    /// The weekend-profile holidays in `first…last`: what the file's `holidays` section records.
    public func weekendHolidays(from first: ServiceDate, through last: ServiceDate) -> [ServiceDate] {
        holidays.filter { $0.weekendProfile && $0.date >= first && $0.date <= last }.map(\.date)
    }

    /// Throws unless the file covers every day of `first…last`.
    public func requireCoverage(from first: ServiceDate, through last: ServiceDate) throws {
        guard coverage.contains(first), coverage.contains(last) else {
            throw FlowsInputError.holidaysDoNotCover(first: first, last: last, covered: coverage)
        }
    }
}
