import Foundation

extension TimeZone {
    /// `America/New_York`. The engine always passes this explicitly; it never relies on the
    /// process time zone.
    public static let nyc = TimeZone(identifier: "America/New_York")!
}

/// The engine's time model.
///
/// A service day D starts at `origin(D) = local noon(D) − 12 h`, which is how GTFS defines
/// times such as `25:10:00`. Engine times are signed `Int32` seconds from the query day's
/// origin. Days are not assumed to be 86,400 s long: a daylight-saving day is 23 h or 25 h,
/// so offsets between days are always computed from their origins.
public enum ServiceDayTime {
    public static func origin(of day: ServiceDate, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let noonComponents = DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)
        guard let noon = calendar.date(from: noonComponents) else {
            preconditionFailure("No local noon for \(day) in \(timeZone.identifier)")
        }
        return noon.addingTimeInterval(-12 * 3600)
    }

    /// Seconds from `origin(from)` to `origin(to)`: −86,400 for the day before on a normal day,
    /// −90,000 or −82,800 across a daylight-saving change.
    public static func offsetSeconds(from: ServiceDate, to: ServiceDate, in timeZone: TimeZone) -> Int32 {
        let interval = origin(of: to, in: timeZone).timeIntervalSince(origin(of: from, in: timeZone))
        return Int32(clamping: Int64(interval.rounded()))
    }

    /// The engine time of `date` relative to `serviceDay`'s origin, rounded down to a whole second.
    public static func engineSeconds(for date: Date, serviceDay: ServiceDate, tz: TimeZone) -> Int32 {
        let interval = date.timeIntervalSince(origin(of: serviceDay, in: tz))
        return Int32(clamping: Int64(interval.rounded(.down)))
    }

    public static func date(engineSeconds: Int32, serviceDay: ServiceDate, tz: TimeZone) -> Date {
        origin(of: serviceDay, in: tz).addingTimeInterval(TimeInterval(engineSeconds))
    }
}
