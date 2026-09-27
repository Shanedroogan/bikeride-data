import BRBuild
import BRCore
import BRFlows
import Foundation
import Testing

/// The August 2026 trip files against a real GBFS `station_information`. Trip data never enters a
/// repository, so this runs only with `BR_TRIPS_DIR` (the trip cache, e.g. `build/trips`) and
/// `BR_GBFS_STATION_INFORMATION` (a `station_information.json`, e.g. the static-20260926
/// fixture's) set:
///
///     BR_TRIPS_DIR=build/trips BR_GBFS_STATION_INFORMATION=build/fixtures/static-20260926/sources/gbfs/station_information.json \
///         swift test --filter RealTripDataTests
@Suite struct RealTripDataTests {
    static let trips = ProcessInfo.processInfo.environment["BR_TRIPS_DIR"].map { URL(fileURLWithPath: $0) }
    static let gbfs = ProcessInfo.processInfo.environment["BR_GBFS_STATION_INFORMATION"].map { URL(fileURLWithPath: $0) }

    @Test(.enabled(if: trips != nil && gbfs != nil)) func august2026JoinsAsTheAuditMeasured() throws {
        let runner = ProcessToolRunner()
        let feed = try GBFSStations.parseStationInformation(Data(contentsOf: Self.gbfs!))
        let universe = try FlowUniverse(gbfs: feed.stations)
        let depots = try DepotList(csv: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Data/flows/depots.csv")))
        let august = TripMonth(year: 2026, month: 8)
        var inputs = [TripInput(system: .jc, month: august,
                                archive: ZipTripArchive(archive: Self.trips!.appendingPathComponent("JC-202608-citibike-tripdata.csv.zip"), runner: runner))]
        let nycZip = Self.trips!.appendingPathComponent("202608-citibike-tripdata.zip")
        let hasNYC = FileManager.default.fileExists(atPath: nycZip.path)
        if hasNYC { inputs.append(TripInput(system: .nyc, month: august, archive: ZipTripArchive(archive: nycZip, runner: runner))) }
        let days = FlowWindow(start: august.firstDay, dayCount: 31)
        let result = try FlowBinner.count(inputs, universe: universe, depots: depots, windows: FlowWindows(departures: days, arrivals: days),
                                          threads: ProcessInfo.processInfo.activeProcessorCount)
        let jc = result.files[0]
        #expect(jc.rows == 111_227 && jc.entries == ["JC-202608-citibike-tripdata.csv"])
        #expect(jc.start.unmatchedShare < 0.001 && jc.end.unmatchedShare < 0.001)
        #expect(jc.start.stationIDStyle == 0 && jc.end.stationIDStyle == 0 && jc.unknownRideableTypes.isEmpty)
        guard hasNYC else { return }
        let nyc = result.files[1]
        #expect(nyc.rows == 5_246_236 && nyc.entries.count == 6)
        #expect(nyc.start.unmatchedShare < 0.001 && nyc.end.unmatchedShare < 0.001)
        #expect(nyc.end.repairedShare > 0.013 && nyc.end.repairedShare < 0.016 && nyc.end.repairedNameDiffers == 0)
        #expect(nyc.start.stationIDStyle == 0 && nyc.end.stationIDStyle == 0 && nyc.unknownRideableTypes.isEmpty)
        #expect(result.counts.saturated == 0)
    }
}
