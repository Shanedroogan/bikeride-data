import BRCore
import BRFlows
import Foundation

/// The columns of a Citi Bike trip CSV the flows builder reads, found by name in each entry's
/// header row (NYC files are unquoted, JC files fully quoted; the CSV reader handles both).
public struct TripColumns: Sendable, Equatable {
    public static let required = ["rideable_type", "started_at", "ended_at", "start_station_id", "end_station_id"]

    public let rideableType: Int
    public let startedAt: Int
    public let endedAt: Int
    public let startStationID: Int
    public let endStationID: Int
    /// Station names, used only to check pad-0 repairs against GBFS names; absent is fine.
    public let startStationName: Int?
    public let endStationName: Int?

    public init(header: CSVRecord) throws {
        let columns = CSVHeader(header)
        rideableType = try columns.requireIndex(of: "rideable_type")
        startedAt = try columns.requireIndex(of: "started_at")
        endedAt = try columns.requireIndex(of: "ended_at")
        startStationID = try columns.requireIndex(of: "start_station_id")
        endStationID = try columns.requireIndex(of: "end_station_id")
        startStationName = columns.index(of: "start_station_name")
        endStationName = columns.index(of: "end_station_name")
    }

    public func stationID(_ direction: FlowDirection) -> Int { direction == .departures ? startStationID : endStationID }
    public func time(_ direction: FlowDirection) -> Int { direction == .departures ? startedAt : endedAt }
    public func stationName(_ direction: FlowDirection) -> Int? { direction == .departures ? startStationName : endStationName }
}

/// Byte-level decoding of the fields a trip row contributes.
public enum TripRowDecoder {
    /// `classic_bike` → classic, `electric_bike` → e-bike. Older files' `docked_bike` (a classic
    /// bike docked by a member) counts as classic. Anything else is unknown: the row is counted in
    /// the report and left out of the cells.
    public static func bikeType(_ field: CSVField) -> FlowBikeType? {
        if field == "electric_bike" { return .ebike }
        if field == "classic_bike" || field == "docked_bike" { return .classic }
        return nil
    }

    /// A local wall-clock time `YYYY-MM-DD HH:MM[:SS[.fff…]]` (a `T` separator is accepted too): days since
    /// 1970-01-01 of its calendar date, and minutes after midnight. The trip data carries no UTC
    /// offset; times are New York wall-clock times, so the fall-back hour's two 01:xx passes land
    /// in the same bins and the spring-forward day has no 02:xx trips. `nil` for anything else.
    public static func localTime<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> (day: Int, minute: Int)? where Bytes.Index == Int {
        guard bytes.count >= 16 else { return nil }
        let s = bytes.startIndex
        @inline(__always) func digit(_ offset: Int) -> Int? {
            let byte = bytes[s + offset]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            return Int(byte - UInt8(ascii: "0"))
        }
        @inline(__always) func number(_ offset: Int, _ width: Int) -> Int? {
            var value = 0
            for index in offset..<offset + width {
                guard let d = digit(index) else { return nil }
                value = value * 10 + d
            }
            return value
        }
        guard bytes[s + 4] == UInt8(ascii: "-"), bytes[s + 7] == UInt8(ascii: "-"),
              bytes[s + 10] == UInt8(ascii: " ") || bytes[s + 10] == UInt8(ascii: "T"), bytes[s + 13] == UInt8(ascii: ":"),
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2),
              hour < 24, minute < 60, ServiceDate.isValid(year: year, month: month, day: day)
        else { return nil }
        if bytes.count > 16 {
            // Seconds and fractions: `:SS` then optionally `.digits`. Checked, not used.
            guard bytes.count >= 19, bytes[s + 16] == UInt8(ascii: ":"), let seconds = number(17, 2), seconds < 61 else { return nil }
            if bytes.count > 19 {
                guard bytes[s + 19] == UInt8(ascii: "."), bytes.count > 20 else { return nil }
                for offset in 20..<bytes.count where digit(offset) == nil { return nil }
            }
        }
        return (ServiceDate(year: year, month: month, day: day).daysSinceEpoch, hour * 60 + minute)
    }
}
