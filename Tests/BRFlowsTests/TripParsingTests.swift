@testable import BRBuild
import BRCore
import BRFlows
import Foundation
import Testing

/// Synthetic trip files shaped like Citi Bike's (2026 columns, NYC unquoted, JC fully quoted).
enum TripFixture {
    static let header = "ride_id,rideable_type,started_at,ended_at,start_station_name,start_station_id,end_station_name,end_station_id,start_lat,start_lng,end_lat,end_lng,member_casual"

    static func row(_ type: String, _ start: String, _ end: String, from: String, to: String,
                    startName: String = "", endName: String = "", quoted: Bool = false) -> String {
        let fields = ["R", type, start, end, startName, from, endName, to, "40.7", "-74.0", "40.7", "-74.0", "member"]
        return quoted ? fields.map { "\"\($0)\"" }.joined(separator: ",") : fields.joined(separator: ",")
    }

    /// GBFS stations: a two-decimal id whose trailing zero trips drop, a genuine one-decimal id,
    /// a capacity-0 station, Hoboken, a test-region station and one without a short name.
    static let gbfs: [GBFSStation] = [
        GBFSStation(stationID: "66dc0e99-0aca-11e7-82f6-3863bb44ef7c", name: "Allen St & Hester St", shortName: "5343.10",
                    lat: 40.716059, lon: -73.991908, regionID: "71", capacity: 30),
        GBFSStation(stationID: "1857832961524028596", name: "6 Ave & W 34 St", shortName: "6131.1",
                    lat: 40.749640, lon: -73.988050, regionID: "71", capacity: 20),
        GBFSStation(stationID: "abc-0", name: "W 22 St & 10 Ave", shortName: "6306.06", lat: 40.746920, lon: -74.004519,
                    regionID: "71", capacity: 0),
        GBFSStation(stationID: "hb-1", name: "Hoboken Terminal", shortName: "HB101", lat: 40.735938, lon: -74.030305,
                    regionID: "311", capacity: 25),
        GBFSStation(stationID: "test-1", name: "Lab", shortName: "9999.99", lat: 40.7, lon: -74.0, regionID: "189", capacity: 5),
        GBFSStation(stationID: "no-short", name: "Nameless", shortName: "", lat: 40.7, lon: -74.0, regionID: "71", capacity: 5),
    ]

    static let depots = DepotList(exact: ["1234.56"], prefixes: ["SYS", "Shop "])

    /// August 2026 for both directions (the fixture's checks predate the shorter departure window).
    static let august = FlowWindows(departures: FlowWindow(start: ServiceDate(year: 2026, month: 8, day: 1), dayCount: 31),
                                    arrivals: FlowWindow(start: ServiceDate(year: 2026, month: 8, day: 1), dayCount: 31))
}

@Suite struct TripParsingTests {
    @Test func decodesLocalTimesByteForByte() {
        func time(_ text: String) -> (day: Int, minute: Int)? { TripRowDecoder.localTime(Array(text.utf8)[...]) }
        let aug1 = ServiceDate(year: 2026, month: 8, day: 1).daysSinceEpoch
        #expect(time("2026-08-01 00:00:03.123").map { [$0.day, $0.minute] } == [aug1, 0])
        #expect(time("2026-08-01 23:59:59").map { [$0.day, $0.minute] } == [aug1, 1439])
        #expect(time("2026-08-01T08:15:00.5").map { [$0.day, $0.minute] } == [aug1, 495])
        #expect(time("2026-08-01 08:15").map { [$0.day, $0.minute] } == [aug1, 495])
        // The fall-back day's two 01:30s are one wall-clock time (no offset in the data).
        let nov1 = ServiceDate(year: 2026, month: 11, day: 1).daysSinceEpoch
        #expect(time("2026-11-01 01:30:00.000").map { [$0.day, $0.minute] } == [nov1, 90])
        for bad in ["", "2026-08-01", "2026-02-30 10:00:00", "2026-08-01 24:00:00", "2026-08-01 10:60:00", "2026/08/01 10:00:00",
                    "2026-08-01 10:00:00.", "2026-08-01 10:00:0x", "2026-08-01 10:00:00.12a", "20a6-08-01 10:00:00"] {
            #expect(time(bad) == nil, "\(bad)")
        }
        #expect(TripRowDecoder.bikeType(CSVField(bytes: Array("electric_bike".utf8)[...])) == .ebike)
        #expect(TripRowDecoder.bikeType(CSVField(bytes: Array("classic_bike".utf8)[...])) == .classic)
        #expect(TripRowDecoder.bikeType(CSVField(bytes: Array("docked_bike".utf8)[...])) == .classic)
        #expect(TripRowDecoder.bikeType(CSVField(bytes: Array("scooter".utf8)[...])) == nil)
    }

    @Test func universeIsTheWholeFeedKeyedByShortName() throws {
        let universe = try FlowUniverse(gbfs: TripFixture.gbfs)
        #expect(universe.stations.map(\.key) == ["5343.10", "6131.1", "6306.06", "HB101"])
        #expect(universe.capacityZero == 1 && universe.droppedTestRegion == 1 && universe.droppedNoShortName == 1)
        #expect(universe.stations[0].latE6 == 40_716_059 && universe.stations[0].lonE6 == -73_991_908)
        #expect(universe.stations[2].capacity == 0)
        // X and X0 both present: the repair would be ambiguous.
        let ambiguous = TripFixture.gbfs + [GBFSStation(stationID: "x", name: "X", shortName: "6131.10", lat: 40.7, lon: -74, regionID: "71", capacity: 1)]
        #expect(throws: FlowsInputError.ambiguousPadZero(["6131.1"])) { try FlowUniverse(gbfs: ambiguous) }
        let duplicate = TripFixture.gbfs + [GBFSStation(stationID: "y", name: "Y", shortName: "HB101", lat: 40.7, lon: -74, regionID: "311", capacity: 1)]
        #expect(throws: FlowsInputError.duplicateShortName("HB101")) { try FlowUniverse(gbfs: duplicate) }
    }

    @Test func resolvesExactThenPadZeroThenDocklessThenDepot() throws {
        let universe = try FlowUniverse(gbfs: TripFixture.gbfs)
        let resolver = StationResolver(keys: universe.stations.map(\.key), depots: TripFixture.depots)
        func resolve(_ id: String) -> StationResolution { resolver.resolve(Array(id.utf8)) }
        #expect(resolve("5343.10") == .exact(0))
        #expect(resolve("5343.1") == .repaired(0))
        #expect(resolve("6131.1") == .exact(1)) // a genuine one-decimal id is never "repaired"
        #expect(resolve("6306.06") == .exact(2))
        #expect(resolve("") == .dockless)
        #expect(resolve("1234.56") == .depot && resolve("SYS038") == .depot && resolve("Shop Morgan ") == .depot)
        #expect(resolve("Shop") == .unmatched && resolve("9999.99") == .unmatched && resolve("5343.100") == .unmatched)
        #expect(resolve("5343.1 ") == .unmatched && resolve("hb101") == .unmatched && resolve("6332.1") == .unmatched)
        var cache = ResolutionCache(resolver: resolver)
        #expect(cache.resolve(Array("5343.1".utf8)[...]) == .repaired(0) && cache.resolve(Array("5343.1".utf8)[...]) == .repaired(0))
        let long = "an-id-longer-than-sixteen-bytes"
        #expect(cache.resolve(Array(long.utf8)[...]) == .unmatched)
        #expect(StationResolver.isOneDecimal(Array("12.3".utf8)[...]) && !StationResolver.isOneDecimal(Array(".3".utf8)[...]))
        #expect(!StationResolver.isOneDecimal(Array("1a.3".utf8)[...]) && !StationResolver.isOneDecimal(Array("12.34".utf8)[...]))
        let parsed = try DepotList(csv: Data("id,match,name,note\n1234.56,exact,a,b\nSYS,prefix,c,d\n\"Shop \",prefix,e,f\n".utf8))
        #expect(parsed == TripFixture.depots)
        #expect(throws: FlowsInputError.self) { try DepotList(csv: Data("id,match\nX,fuzzy\n".utf8)) }
    }

    /// NYC-style entries (unquoted, `_N` and `-partN`, each with its own header, and a
    /// `__MACOSX` shadow that must never be read) and a quoted JC-style file, by archive and path.
    func fixtureEntries() -> (nyc: [(name: String, text: String)], jc: [(name: String, text: String)]) {
        let rows1 = [
            TripFixture.row("classic_bike", "2026-08-03 08:05:00.000", "2026-08-03 08:20:00.000", from: "5343.10", to: "5343.1",
                            startName: "Allen St & Hester St", endName: "Allen St & Hester St"),
            TripFixture.row("electric_bike", "2026-08-03 08:10:00.000", "2026-08-03 09:00:00.000", from: "6131.1", to: ""),
            TripFixture.row("electric_bike", "2026-08-03 12:00:00.000", "2026-08-03 12:30:00.000", from: "SYS038", to: "6306.06"),
            // Started in July, ended in August: in the August file, arrival counted, departure outside.
            TripFixture.row("classic_bike", "2026-07-31 23:50:00.000", "2026-08-01 00:10:00.000", from: "6306.06", to: "5343.10"),
        ]
        let rows2 = [
            TripFixture.row("scooter", "2026-08-04 10:00:00.000", "2026-08-04 10:05:00.000", from: "5343.10", to: "6131.1"),
            TripFixture.row("classic_bike", "2026-08-04 10:00:00.000", "2026-08-04 10:05:00.000", from: "9999.99", to: "66dc0e99-0aca-11e7-82f6-3863bb44ef7c"),
            TripFixture.row("classic_bike", "2026-08-04 17:00:00.000", "not a time", from: "Shop Morgan ", to: "5343.1", endName: "Other name"),
        ]
        let jcHeader = TripFixture.header.split(separator: ",").map { "\"\($0)\"" }.joined(separator: ",")
        return (
            [("202608-citibike-tripdata_1.csv", ([TripFixture.header] + rows1).joined(separator: "\n") + "\n"),
             ("202608-citibike-tripdata-part2.csv", ([TripFixture.header] + rows2).joined(separator: "\r\n")),
             ("__MACOSX/._202608-citibike-tripdata_1.csv", "\u{0}\u{5}\u{16}\u{7}garbage")],
            [("JC-202608-citibike-tripdata.csv", [
                jcHeader,
                TripFixture.row("electric_bike", "2026-08-08 09:00:00.000", "2026-08-08 09:14:59.999", from: "HB101", to: "HB101", quoted: true),
                TripFixture.row("classic_bike", "2026-08-08 09:30:00.000", "2026-08-08 09:40:00.000", from: "HB101", to: "5343.10", quoted: true),
             ].joined(separator: "\n") + "\n"),
             ("__MACOSX/._JC-202608-citibike-tripdata.csv", "garbage")]
        )
    }

    func writeFixtureArchives(_ scratch: ScratchDirectory) throws -> (nyc: URL, jc: URL) {
        let (nyc, jc) = fixtureEntries()
        for entry in nyc { try scratch.write("nyc/\(entry.name)", entry.text) }
        for entry in jc { try scratch.write("jc/\(entry.name)", entry.text) }
        return (scratch.file("nyc"), scratch.file("jc"))
    }

    func checkCounts(_ result: FlowBinner.Result) throws {
        let (nyc, jc) = (result.files[0], result.files[1])
        #expect(nyc.entries == ["202608-citibike-tripdata-part2.csv", "202608-citibike-tripdata_1.csv"])
        #expect(nyc.rows == 7 && nyc.classicRows == 4 && nyc.ebikeRows == 2 && nyc.unknownRideableTypes == ["scooter": 1])
        #expect(nyc.start.exact == 4 && nyc.start.depot == 2 && nyc.start.unmatched == 1 && nyc.start.repaired == 0)
        #expect(nyc.end.exact == 3 && nyc.end.repaired == 2 && nyc.end.dockless == 1 && nyc.end.unmatched == 1)
        #expect(nyc.end.repairedNameAgrees == 1 && nyc.end.repairedNameDiffers == 1)
        #expect(nyc.end.stationIDStyle == 1 && nyc.start.stationIDStyle == 0)
        #expect(nyc.unmatchedStartIDs == ["9999.99": 1] && nyc.unmatchedEndIDs == ["66dc0e99-0aca-11e7-82f6-3863bb44ef7c": 1])
        #expect(nyc.start.outsideWindow == 1 && nyc.end.badTimestamp == 1)
        #expect(nyc.start.unknownRideableType == 1 && nyc.end.unknownRideableType == 1)
        #expect(nyc.start.counted == 2 && nyc.end.counted == 3)
        #expect(nyc.end.joinable == 6 && abs(nyc.end.unmatchedShare - 1.0 / 6.0) < 1e-12)
        #expect(jc.rows == 2 && jc.start.exact == 2 && jc.end.exact == 2 && jc.start.counted == 2 && jc.end.counted == 2)

        let counts = result.counts
        #expect(counts.saturated == 0 && counts.window.dayCount == 31)
        // 5343.10 (row 0): departure Aug 3 08:05 (day 2, bin 32); arrivals Aug 3 08:20 (repaired), Aug 1 00:10
        // (the July-start trip, bin 0) and Aug 8 09:40 from Hoboken (bin 38).
        #expect(counts.count(key: 0, day: 2, bin: 32, type: .classic, direction: .departures) == 1)
        #expect(counts.count(key: 0, day: 2, bin: 33, type: .classic, direction: .arrivals) == 1)
        #expect(counts.count(key: 0, day: 0, bin: 0, type: .classic, direction: .arrivals) == 1)
        #expect(counts.count(key: 0, day: 7, bin: 38, type: .classic, direction: .arrivals) == 1)
        // 6131.1: an e-bike departure at 08:10; 6306.06 (capacity 0): an e-bike arrival at 12:30.
        #expect(counts.count(key: 1, day: 2, bin: 32, type: .ebike, direction: .departures) == 1)
        #expect(counts.count(key: 2, day: 2, bin: 50, type: .ebike, direction: .arrivals) == 1)
        // HB101: 09:14:59.999 is still bin 36.
        #expect(counts.count(key: 3, day: 7, bin: 36, type: .ebike, direction: .arrivals) == 1)
        #expect(counts.counts.reduce(0) { $0 + Int($1) } == 9)
    }

    @Test func countsDirectoryArchives() throws {
        let scratch = try ScratchDirectory()
        let (nyc, jc) = try writeFixtureArchives(scratch)
        let august = TripMonth(year: 2026, month: 8)
        let inputs = [TripInput(system: .nyc, month: august, archive: DirectoryTripArchive(directory: nyc)),
                      TripInput(system: .jc, month: august, archive: DirectoryTripArchive(directory: jc))]
        let window = FlowWindow(start: august.firstDay, dayCount: 31)
        let universe = try FlowUniverse(gbfs: TripFixture.gbfs)
        for threads in [1, 4] {
            try checkCounts(FlowBinner.count(inputs, universe: universe, depots: TripFixture.depots,
                                             windows: FlowWindows(departures: window, arrivals: window), threads: threads))
        }
    }

    @Test(.enabled(if: StoredZip.unzipInstalled)) func countsZipArchives() throws {
        let runner = ProcessToolRunner()
        let scratch = try ScratchDirectory()
        let (nyc, jc) = fixtureEntries()
        for (name, entries) in [("nyc.zip", nyc), ("jc.zip", jc)] {
            try StoredZip.write(entries.map { ($0.name, Data($0.text.utf8)) }, to: scratch.file(name))
        }
        let august = TripMonth(year: 2026, month: 8)
        let nycZip = ZipTripArchive(archive: scratch.file("nyc.zip"), runner: runner)
        // The writer's CRC-32 (the standard check value) and archives `unzip -t` accepts.
        #expect(StoredZip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        _ = try runner.run(executable: "unzip", args: ["-tq", scratch.file("nyc.zip").path])
        // Every member is listed (the __MACOSX shadow too); only the trip CSVs are read.
        let members = String(decoding: try runner.run(executable: "unzip", args: ["-Z1", scratch.file("nyc.zip").path]), as: UTF8.self)
        #expect(members.split(separator: "\n").contains("__MACOSX/._202608-citibike-tripdata_1.csv"))
        #expect(try nycZip.csvEntries() == ["202608-citibike-tripdata-part2.csv", "202608-citibike-tripdata_1.csv"])
        let inputs = [TripInput(system: .nyc, month: august, archive: nycZip),
                      TripInput(system: .jc, month: august, archive: ZipTripArchive(archive: scratch.file("jc.zip"), runner: runner))]
        let result = try FlowBinner.count(inputs, universe: try FlowUniverse(gbfs: TripFixture.gbfs), depots: TripFixture.depots,
                                          windows: TripFixture.august, threads: 3)
        try checkCounts(result)
    }

    /// Through the binner: the fall-back day's two 01:30s share bin 6 (the data has no UTC offset),
    /// and with the build's windows a departure on the last day is left out on purpose, never
    /// counted as a dropped trip end; each direction's active days stay inside its window.
    @Test func binsTheFallBackHourAndLeavesOutLastDayDepartures() throws {
        let scratch = try ScratchDirectory()
        try scratch.write("nov/202611-citibike-tripdata_1.csv", ([TripFixture.header] + [
            // 2026-11-01 01:30 EDT, then 01:30 EST an hour later: one wall-clock time.
            TripFixture.row("classic_bike", "2026-11-01 01:30:00.000", "2026-11-01 01:40:00.000", from: "5343.10", to: "6131.1"),
            TripFixture.row("classic_bike", "2026-11-01 01:30:00.000", "2026-11-01 01:40:00.000", from: "5343.10", to: "6131.1"),
            TripFixture.row("classic_bike", "2026-11-01 00:55:00.000", "2026-11-01 01:05:00.000", from: "5343.10", to: "6131.1"),
            // The last day (a Monday): the arrival counts, the departure is outside the departure window.
            TripFixture.row("electric_bike", "2026-11-30 10:00:00.000", "2026-11-30 10:20:00.000", from: "6131.1", to: "HB101"),
        ]).joined(separator: "\n") + "\n")
        let november = TripMonth(year: 2026, month: 11)
        let windows = FlowWindows.trips(from: november.firstDay, through: november.lastDay)
        #expect(windows.departures.dayCount == 29 && windows.arrivals.dayCount == 30 && windows.span == windows.arrivals)
        #expect(windows.days(.departures) == 0..<29 && windows.days(.arrivals) == 0..<30)
        let result = try FlowBinner.count([TripInput(system: .nyc, month: november, archive: DirectoryTripArchive(directory: scratch.file("nov")))],
                                          universe: try FlowUniverse(gbfs: TripFixture.gbfs), depots: TripFixture.depots, windows: windows, threads: 1)
        let counts = result.counts
        #expect(counts.count(key: 0, day: 0, bin: 6, type: .classic, direction: .departures) == 2)
        #expect(counts.count(key: 1, day: 0, bin: 6, type: .classic, direction: .arrivals) == 2)
        #expect(counts.count(key: 0, day: 0, bin: 3, type: .classic, direction: .departures) == 1)
        #expect(counts.count(key: 1, day: 0, bin: 4, type: .classic, direction: .arrivals) == 1)
        #expect(counts.count(key: 3, day: 29, bin: 41, type: .ebike, direction: .arrivals) == 1)
        #expect(counts.counts.reduce(0) { $0 + Int($1) } == 7)
        let file = result.files[0]
        #expect(file.start.outsideDirectionWindow == 1 && file.start.dropped == 0 && file.start.counted == 3 && file.end.counted == 4)

        let calendar = try FlowCalendar(csv: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Data/config/calendar/holidays.csv")))
        let tallies = FlowTallies.tally(counts, calendar: calendar)
        // Weekends plus Thanksgiving and the day after: 11 weekend days; Nov 30 (a weekday) has arrivals only.
        #expect(tallies.daysOfType == [[18, 11], [19, 11]])
        #expect(tallies.daily[0][29] == 0 && tallies.daily[1][29] == 1)
        // HB101's only trip end is the last day's arrival: one weekday of arrivals, no departure days.
        #expect(Array(tallies.activeDays[12..<16]) == [0, 1, 0, 0])
        // 6131.1's last-day departure was not counted, so it is active on Nov 1 (a Sunday) alone.
        #expect(Array(tallies.activeDays[4..<8]) == [0, 0, 1, 1])
    }

    @Test func missingColumnsFailTheFile() throws {
        let scratch = try ScratchDirectory()
        try scratch.write("bad/x.csv", "ride_id,rideable_type,started_at\nR,classic_bike,2026-08-01 10:00:00\n")
        let august = TripMonth(year: 2026, month: 8)
        #expect(throws: FlowsBuildError.self) {
            try FlowBinner.count([TripInput(system: .nyc, month: august, archive: DirectoryTripArchive(directory: scratch.file("bad")))],
                                 universe: try FlowUniverse(gbfs: TripFixture.gbfs), depots: TripFixture.depots,
                                 windows: TripFixture.august, threads: 2)
        }
    }

    @Test func holidayCalendarFromTheSharedFile() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Data/config/calendar/holidays.csv")
        let calendar = try FlowCalendar(csv: Data(contentsOf: file))
        #expect(calendar.coverage == ServiceDate(year: 2026, month: 1, day: 1)...ServiceDate(year: 2027, month: 12, day: 31))
        #expect(calendar.dayType(of: ServiceDate(year: 2026, month: 7, day: 3)) == .weekend)   // Independence Day (observed)
        #expect(calendar.dayType(of: ServiceDate(year: 2026, month: 6, day: 19)) == .weekday)  // Juneteenth: weekday profile
        #expect(calendar.dayType(of: ServiceDate(year: 2026, month: 7, day: 4)) == .weekend)   // a Saturday
        #expect(calendar.dayType(of: ServiceDate(year: 2026, month: 7, day: 6)) == .weekday)
        #expect(calendar.weekendHolidays(from: ServiceDate(year: 2026, month: 6, day: 1), through: ServiceDate(year: 2026, month: 8, day: 31))
            == [ServiceDate(year: 2026, month: 7, day: 3)])
        try calendar.requireCoverage(from: ServiceDate(year: 2027, month: 10, day: 1), through: ServiceDate(year: 2027, month: 12, day: 31))
        #expect(throws: FlowsInputError.self) {
            try calendar.requireCoverage(from: ServiceDate(year: 2027, month: 11, day: 1), through: ServiceDate(year: 2028, month: 1, day: 31))
        }
        #expect(throws: FlowsInputError.self) { try FlowCalendar(csv: Data("date,name,profile\n20260704,Sat,weekend\n".utf8)) }
        #expect(throws: FlowsInputError.self) { try FlowCalendar(csv: Data("date,name,profile\n20260703,A,weekend\n20260703,B,weekend\n".utf8)) }
        #expect(throws: FlowsInputError.self) { try FlowCalendar(csv: Data("date,name,profile\n20260703,A,holiday\n".utf8)) }
    }
}
