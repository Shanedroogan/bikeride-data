import BRBuild
import BRCore
import BRGeo
import BRTimetable
import Foundation
import Testing

/// Checks built `tt-*.bin` files for what the compiler guarantees beyond what opening them
/// validates: FIFO on every day view (covered dates and two weeks of extrapolation) and stops
/// within 250 m of their shape vertex. Runs only with `BIKERIDE_TT_DIR` set to a directory of
/// built artifacts, e.g. `BIKERIDE_TT_DIR=build/data swift test --filter BuiltTimetableTests`.
@Suite struct BuiltTimetableTests {
    static let directory = ProcessInfo.processInfo.environment["BIKERIDE_TT_DIR"].map { URL(fileURLWithPath: $0) }

    @Test(.enabled(if: directory != nil)) func builtTimetablesKeepTheCompilerGuarantees() throws {
        var opened = 0
        for system in TransitSystem.allCases {
            let url = Self.directory!.appendingPathComponent(TimetableBuild.artifactFileName(system))
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let timetable = try Timetable(contentsOf: url)   // checks every section, enum and padding byte
            opened += 1

            var worst = 0.0, gtfsShaped = 0, synthesized = 0
            for pattern in 0..<timetable.patternCount {
                guard let shape = timetable.patternShape(pattern) else { continue }
                let points = timetable.shapePoints(shape)
                if timetable.patternFlags(pattern).contains(.synthesizedShape) { synthesized += 1 } else { gtfsShaped += 1 }
                for (stop, vertex) in zip(timetable.patternStops(pattern), timetable.patternShapeVertices(pattern))
                    where vertex != TimetableFormat.none {
                    worst = max(worst, timetable.stopCoordinate(Int(stop)).distance(to: points[Int(vertex)]))
                }
            }
            #expect(worst <= 250, "\(system): a stop lies \(worst) m from its shape vertex")

            var dates = timetable.coveredDates
            if let last = dates.last { dates += (1...14).map { last.adding(days: $0) } }
            var violations = 0
            for date in dates {
                let view = timetable.dayView(for: date, extrapolate: true)
                for pattern in 0..<timetable.patternCount {
                    let trips = view.activeTrips(inPattern: pattern)
                    guard trips.count > 1 else { continue }
                    let stops = timetable.patternStopCount(pattern), first = timetable.patternTrips(pattern).lowerBound
                    let departures = timetable.patternDepartures(pattern), arrivals = timetable.patternArrivals(pattern)
                    for (earlier, later) in zip(trips, trips.dropFirst()) {
                        let a = (Int(earlier) - first) * stops, b = (Int(later) - first) * stops
                        if (0..<stops).contains(where: { departures[a + $0] > departures[b + $0] || arrivals[a + $0] > arrivals[b + $0] }) {
                            violations += 1
                        }
                    }
                }
            }
            #expect(violations == 0, "\(system): \(violations) overtaking trip pairs")

            let peak = (0..<timetable.tripCount).filter { timetable.isPeak(trip: $0) }.count
            print("""
                \(system): \(timetable.tripCount) trips (\(peak) peak), \(timetable.patternCount) patterns, \
                \(gtfsShaped) on GTFS shapes and \(synthesized) synthesized, max stop-to-vertex \
                \(String(format: "%.1f", worst)) m, FIFO violations \(violations) over \(dates.count) day views
                """)
        }
        #expect(opened > 0, "no tt-*.bin in \(Self.directory!.path)")
    }
}
