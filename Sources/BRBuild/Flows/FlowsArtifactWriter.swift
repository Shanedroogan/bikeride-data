import BRCore
import BRFlows
import Foundation

/// Assembles the `flows` payload model from a build's pieces; ``FlowsData`` (BRFlows) lays it out.
public enum FlowsArtifactWriter {
    public static func data(
        universe: FlowUniverse, tallies: FlowTallies, cells: [UInt16], flags: [FlowStationFlags],
        calendar: FlowCalendar, parameters: FlowSmoothingParameters
    ) -> FlowsData {
        let window = tallies.window
        let stations = universe.stations.enumerated().map { row, station in
            FlowStation(
                key: station.key, latE6: station.latE6, lonE6: station.lonE6, capacity: station.capacity,
                activeDays: Array(tallies.activeDays[row * 4..<row * 4 + 4]), flags: flags[row]
            )
        }
        return FlowsData(
            departureWindow: window, arrivalWindow: window, flags: [.customerTripsOnly], smoothing: parameters,
            holidays: calendar.weekendHolidays(from: window.start, through: window.end), stations: stations, cells: cells
        )
    }

    /// `trips=<first>-<last> <pin> …;gbfs=<version>;holidays=<sha12>;depots=<sha12>`, the pins
    /// (``TripSourceFile/pin``: system, month, ETag, size) in month then system order.
    public static func dataVersion(months: [TripMonth], sources: [TripSourceFile], gbfs: String, holidaysSha: String, depotsSha: String) -> String {
        let range = "\(months.first?.yyyymm ?? "")-\(months.last?.yyyymm ?? "")"
        return (["trips=\(range)"] + sources.map(\.pin)).joined(separator: " ")
            + ";gbfs=\(gbfs);holidays=\(holidaysSha.prefix(12));depots=\(depotsSha.prefix(12))"
    }

    /// The trip pins of a `dataVersion` written by ``dataVersion(months:sources:gbfs:holidaysSha:depotsSha:)``.
    public static func tripPins(ofDataVersion dataVersion: String) -> [String]? {
        guard let trips = dataVersion.split(separator: ";").first, trips.hasPrefix("trips=") else { return nil }
        return trips.split(separator: " ").dropFirst().map(String.init)
    }
}
