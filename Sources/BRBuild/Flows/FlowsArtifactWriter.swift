import BRCore
import BRFlows
import Foundation

/// Assembles the `flows` payload model from a build's pieces; ``FlowsData`` (BRFlows) lays it out.
public enum FlowsArtifactWriter {
    public static func data(
        universe: FlowUniverse, tallies: FlowTallies, cells: [UInt16], flags: [FlowStationFlags],
        calendar: FlowCalendar, parameters: FlowSmoothingParameters
    ) -> FlowsData {
        let windows = tallies.windows
        let stations = universe.stations.enumerated().map { row, station in
            FlowStation(
                key: station.key, latE6: station.latE6, lonE6: station.lonE6, capacity: station.capacity,
                activeDays: Array(tallies.activeDays[row * 4..<row * 4 + 4]), flags: flags[row]
            )
        }
        return FlowsData(
            departureWindow: windows.departures, arrivalWindow: windows.arrivals, flags: [.customerTripsOnly], smoothing: parameters,
            holidays: calendar.weekendHolidays(from: windows.span.start, through: windows.span.end), stations: stations, cells: cells
        )
    }

    /// `trips=<first>-<last> <pin> …;gbfs=<version>;holidays=<sha12>;depots=<sha12>`, the pins
    /// (``TripSourceFile/pin``: system, month, ETag, size) in month then system order.
    public static func dataVersion(months: [TripMonth], sources: [TripSourceFile], gbfs: String, holidaysSha: String, depotsSha: String) -> String {
        let range = "\(months.first?.yyyymm ?? "")-\(months.last?.yyyymm ?? "")"
        return (["trips=\(range)"] + sources.map(\.pin)).joined(separator: " ")
            + ";gbfs=\(gbfs);" + buildInputs(holidaysSha: holidaysSha, depotsSha: depotsSha)
    }

    /// The trip pins of a `dataVersion` written by ``dataVersion(months:sources:gbfs:holidaysSha:depotsSha:)``.
    public static func tripPins(ofDataVersion dataVersion: String) -> [String]? {
        guard let trips = dataVersion.split(separator: ";").first, trips.hasPrefix("trips=") else { return nil }
        let pins = trips.split(separator: " ").dropFirst().map(String.init)
        return pins.isEmpty ? nil : pins
    }

    /// The build-only inputs' part of a `dataVersion`, `holidays=<sha12>;depots=<sha12>` (the GBFS
    /// version is left out: it changes every day and is not a reason to rebuild).
    public static func buildInputs(ofDataVersion dataVersion: String) -> String? {
        let fields = dataVersion.split(separator: ";").filter { $0.hasPrefix("holidays=") || $0.hasPrefix("depots=") }
        return fields.count == 2 ? fields.joined(separator: ";") : nil
    }

    public static func buildInputs(holidaysSha: String, depotsSha: String) -> String {
        "holidays=\(holidaysSha.prefix(12));depots=\(depotsSha.prefix(12))"
    }
}
