import Foundation

/// A GTFS service date: a calendar day with no time zone attached.
///
/// Day arithmetic is pure integer math on the proleptic Gregorian calendar, so it is identical
/// on every platform and in every process time zone.
public struct ServiceDate: Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Creates a date from components. Traps if the components do not form a real date;
    /// use ``init(yyyymmdd:)`` for untrusted input.
    public init(year: Int, month: Int, day: Int) {
        precondition(Self.isValid(year: year, month: month, day: day), "Invalid date \(year)-\(month)-\(day)")
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses the GTFS `YYYYMMDD` form.
    public init?(yyyymmdd: String) {
        self.init(yyyymmddBytes: yyyymmdd.utf8)
    }

    /// Parses the GTFS `YYYYMMDD` form from ASCII bytes, as found in a CSV field.
    public init?<Bytes: Collection>(yyyymmddBytes bytes: Bytes) where Bytes.Element == UInt8 {
        guard bytes.count == 8 else { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        let year = value / 10_000, month = value / 100 % 100, day = value % 100
        guard Self.isValid(year: year, month: month, day: day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The calendar date that contains `date` in `timeZone`.
    public init(containing date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            preconditionFailure("Gregorian calendar returned no date components")
        }
        self.init(year: year, month: month, day: day)
    }

    /// Days since 1970-01-01.
    public var daysSinceEpoch: Int {
        // Howard Hinnant's days_from_civil.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The date `daysSinceEpoch` days after 1970-01-01. Traps outside years 1–9999.
    public init(daysSinceEpoch: Int) {
        // Howard Hinnant's civil_from_days.
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        self.init(year: year, month: month, day: day)
    }

    public func adding(days: Int) -> ServiceDate {
        ServiceDate(daysSinceEpoch: daysSinceEpoch + days)
    }

    public var weekday: Weekday {
        // 1970-01-01 was a Thursday.
        let index = ((daysSinceEpoch + 3) % 7 + 7) % 7
        return Weekday.allCases[index]
    }

    /// The GTFS `YYYYMMDD` form.
    public var yyyymmdd: String {
        Self.padded(year, 4) + Self.padded(month, 2) + Self.padded(day, 2)
    }

    public static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1 else { return false }
        return day <= daysInMonth(year: year, month: month)
    }

    fileprivate static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}

extension ServiceDate: Comparable {
    public static func < (lhs: ServiceDate, rhs: ServiceDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension ServiceDate: Strideable {
    public func distance(to other: ServiceDate) -> Int {
        other.daysSinceEpoch - daysSinceEpoch
    }

    public func advanced(by days: Int) -> ServiceDate {
        adding(days: days)
    }
}

extension ServiceDate: CustomStringConvertible {
    /// ISO 8601 form, e.g. `2026-11-01`.
    public var description: String {
        "\(Self.padded(year, 4))-\(Self.padded(month, 2))-\(Self.padded(day, 2))"
    }
}

/// Encoded as the GTFS `YYYYMMDD` string.
extension ServiceDate: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = ServiceDate(yyyymmdd: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected YYYYMMDD, got \(string)")
        }
        self = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(yyyymmdd)
    }
}

/// ISO weekday, Monday first, matching the column order of GTFS `calendar.txt`.
public enum Weekday: Int, CaseIterable, Sendable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday
}
