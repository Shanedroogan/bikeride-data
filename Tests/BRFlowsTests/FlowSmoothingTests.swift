@testable import BRBuild
import BRCore
import BRData
import BRFlows
import Foundation
import Testing

/// Three stations over one week (Mon 2026-06-01 … Sun 06-07: five weekdays, two weekend days):
/// A, and B 500 m north of it, ride; C, 5 km away, has no trips.
private enum Toy {
    static let window = FlowWindow(start: ServiceDate(year: 2026, month: 6, day: 1), dayCount: 7)
    static let latE6: [Int32] = [40_700_000, 40_704_500, 40_745_000]
    static let lonE6: [Int32] = [-74_000_000, -74_000_000, -74_000_000]
    static let parameters = FlowSmoothingParameters(kappaCellMilli: 4_000, kappaHourMilli: 8_000, kappaDispersionMilli: 6_000,
                                                    neighborCount: 8, neighborRadiusMeters: 1_000)

    static func counts() -> FlowCounts {
        var counts = [UInt16](repeating: 0, count: 3 * 7 * FlowsFormat.binsPerDay * FlowCounts.perBin)
        func add(_ key: Int, _ day: Int, _ bin: Int, _ type: FlowBikeType, _ direction: FlowDirection, _ n: UInt16) {
            counts[FlowCounts.index(key: key, day: day, bin: bin, type: Int(type.rawValue), direction: Int(direction.rawValue), dayCount: 7)] += n
        }
        for day in 0..<5 { add(0, day, 32, .classic, .departures, 2) }  // A: 2 each weekday at 08:00
        for day in 5..<7 { add(0, day, 40, .classic, .departures, 1) }  // A: 1 each weekend day at 10:00
        for (day, n) in [0, 10, 4, 4, 2].enumerated() { add(1, day, 33, .classic, .departures, UInt16(n)) } // B: 20 over the weekdays
        add(1, 0, 50, .classic, .arrivals, 1)                           // B is active from Monday
        for day in 5..<7 { add(1, day, 41, .classic, .departures, 2) }
        return FlowCounts(keyCount: 3, windows: FlowWindows(departures: window, arrivals: window), counts: counts, saturated: 0)
    }

    static let calendar = try! FlowCalendar(holidays: [FlowCalendar.Holiday(date: ServiceDate(year: 2026, month: 1, day: 1), name: "x", weekendProfile: true)])
}

@Suite struct FlowSmoothingTests {
    @Test func tallySumsByDayTypeAndSpansActiveDays() {
        let tallies = FlowTallies.tally(Toy.counts(), calendar: Toy.calendar)
        #expect(tallies.daysOfType == [[5, 2], [5, 2]])
        let a = FlowTallies.index(key: 0, dayType: 0, direction: 0, series: 0, bin: 32)
        #expect(tallies.sums[a] == 10 && tallies.squares[a] == 20)
        let b = FlowTallies.index(key: 1, dayType: 0, direction: 0, series: 0, bin: 33)
        #expect(tallies.sums[b] == 20 && tallies.squares[b] == 136)
        #expect(tallies.sums[FlowTallies.index(key: 1, dayType: 0, direction: 0, series: FlowTallies.anySeries, bin: 33)] == 20)
        #expect(Array(tallies.activeDays[0..<4]) == [5, 5, 2, 2] && Array(tallies.activeDays[4..<8]) == [5, 5, 2, 2])
        #expect(Array(tallies.activeDays[8..<12]) == [0, 0, 0, 0])
        #expect(tallies.tripEnds == [12, 25, 0])
        #expect(tallies.daily[0] == [2 + 0, 2 + 10, 2 + 4, 2 + 4, 2 + 2, 1 + 2, 1 + 2] && tallies.daily[1] == [1, 0, 0, 0, 0, 0, 0])
    }

    @Test func neighborsUseIntegerDistances() {
        let near = FlowSmoothing.neighbors(latE6: Toy.latE6, lonE6: Toy.lonE6, hasTrips: [true, true, false], count: 8, radiusMeters: 1_000)
        #expect(near == [[1], [0], []])
        // 1 km is 1,000 × 1024 × 10^6 / 111,195 = 9,209,047 1024ths of a microdegree: 8,993 microdegrees
        // north–south, 11,867 east–west (× 776).
        let lat: [Int32] = [0, 8_993, 8_994, 0, 0]
        let lon: [Int32] = [0, 0, 0, 11_867, 11_868]
        let ring = FlowSmoothing.neighbors(latE6: lat, lonE6: lon, hasTrips: [true, true, true, true, true], count: 8, radiusMeters: 1_000)
        #expect(ring[0] == [3, 1]) // 9,208,792 before 9,208,832: nearest first

        // Ties go to the lower key.
        let tie = FlowSmoothing.neighbors(latE6: [0, 100, -100], lonE6: [0, 0, 0], hasTrips: [true, true, true], count: 1, radiusMeters: 1_000)
        #expect(tie[0] == [1])
    }

    /// Every stored value against the formula worked by hand (docs/formats.md, "flows").
    @Test func smoothsToHandComputedValues() {
        let tallies = FlowTallies.tally(Toy.counts(), calendar: Toy.calendar)
        let (cells, flags, stats) = FlowSmoothing.smooth(tallies, latE6: Toy.latE6, lonE6: Toy.lonE6, parameters: Toy.parameters)
        func cell(_ row: Int, _ dayType: FlowDayType, _ slot: FlowSlot, _ bin: Int, _ direction: FlowDirection = .departures) -> UInt16 {
            cells[FlowsFormat.cellIndex(row: row, dayType: dayType, direction: direction, slot: slot, bin: bin)]
        }
        func half(_ value: Double) -> UInt16 { HalfFloat.bits(from: value) }

        // A, weekdays: S = 10 at bin 32 over n = 5. B's shape (all at bin 33) scaled to A's daily
        // total 2 puts a prior of 2 at bin 33. Hour 8: (10 + 8·2) / (4·(5 + 8)) = 0.5. Bin 32:
        // (10 + 4·0.5) / (5 + 4) = 12/9; bins 33–35: (0 + 4·0.5) / 9 = 2/9. No variance: Poisson.
        #expect(cell(0, .weekday, .meanClassic, 32) == half(12.0 / 9.0))
        #expect(cell(0, .weekday, .varianceClassic, 32) == half(12.0 / 9.0))
        for bin in 33...35 { #expect(cell(0, .weekday, .meanClassic, bin) == half(2.0 / 9.0)) }
        #expect(cell(0, .weekday, .meanClassic, 31) == 0 && cell(0, .weekday, .meanClassic, 36) == 0)
        #expect(cell(0, .weekday, .meanEbike, 32) == 0 && cell(0, .weekday, .varianceAny, 32) == half(12.0 / 9.0))
        // A, weekends: S = 2 at bin 40 over n = 2; the prior is 1 at bin 41. Hour 10:
        // (2 + 8·1) / (4·10) = 0.25; bin 40: (2 + 1) / 6 = 0.5; bins 41–43: 1/6.
        #expect(cell(0, .weekend, .meanClassic, 40) == half(0.5))
        for bin in 41...43 { #expect(cell(0, .weekend, .meanClassic, bin) == half(1.0 / 6.0)) }

        // B, weekdays: S = 20, Q = 136 at bin 33 (days 0, 10, 4, 4, 2): variance (5·136 − 400)/(5·4) = 14,
        // dispersion 14/4 = 3.5 for the cell and its hour. A's shape (bin 32) scaled to B's total 4
        // gives a prior of 4 at bin 32. Hour 8: (20 + 8·4) / 52 = 1. Bin 33: (20 + 4) / 9 = 24/9;
        // bin 32: 4/9, whose own mean is 0, so it takes the hour's dispersion.
        #expect(cell(1, .weekday, .meanClassic, 33) == half(24.0 / 9.0))
        #expect(cell(1, .weekday, .varianceClassic, 33) == half(24.0 / 9.0 * 3.5))
        #expect(cell(1, .weekday, .meanClassic, 32) == half(4.0 / 9.0))
        #expect(cell(1, .weekday, .varianceClassic, 32) == half(4.0 / 9.0 * 3.5))
        #expect(cell(1, .weekday, .varianceAny, 33) == half(24.0 / 9.0 * 3.5))
        // B's only arrival (Monday 12:30) has no neighbor arrivals to shape it: a flat prior at its
        // own rate, 1/5 per day ÷ 96 bins.
        let flat = 0.2 / 96
        let hour12 = (1 + 8 * 4 * flat) / (4 * 13)
        #expect(cell(1, .weekday, .meanClassic, 50, .arrivals) == half((1 + 4 * hour12) / 9))
        #expect(cell(1, .weekday, .meanClassic, 0, .arrivals) == half((0 + 4 * ((8 * 4 * flat) / 52)) / 9))

        // C: no trips and no neighbors with trips inside 1 km (A and B are 4.5 and 4.05 km away).
        #expect((0..<FlowsFormat.cellsPerKey).allSatisfy { cells[2 * FlowsFormat.cellsPerKey + $0] == 0 })
        #expect(flags[2] == [.inGBFS, .lowData, .neighborhoodDominated])
        #expect(flags[0] == [.inGBFS, .neighborhoodDominated]) // two weekend days < κc = 4
        #expect(flags[1] == [.inGBFS, .neighborhoodDominated])
        #expect(stats.keysWithTrips == 2 && stats.keysWithoutTrips == 1 && stats.neighborCountHistogram[1] == 2 && stats.neighborCountHistogram[0] == 1)
    }

    /// SHA-256 of the payload ``Golden`` smooths to. The builder promises the same bytes on every
    /// host (integer inputs, `+ − × ÷` on `Double` in a fixed order, no libm, binary16 by bit
    /// operations); this pins it where the hand-computed toy cannot, since those expectations run
    /// the same arithmetic as the code. CI (Linux x86_64) checks the value pinned on macOS arm64.
    static let smoothingGolden = "006a0b1b5ac4becc0df461e70861c62cbf6cbdcca8f68ac1058a58b3794c70c7"

    @Test func smoothingMatchesTheGoldenOnEveryHost() throws {
        let (payload, stats, cells) = try Golden.build()
        let digest = try sha256Hex(payload)
        // The paths it pins: silent keys, neighbors, bursty cells above the Poisson floor, and
        // any-type variances raised after rounding.
        var aboveFloor = 0
        for series in 0..<(48 * FlowsFormat.dayTypeCount * FlowsFormat.directionCount) {
            let base = series * FlowsFormat.slotCount * FlowsFormat.binsPerDay
            for bin in 0..<FlowsFormat.binsPerDay where cells[base + FlowsFormat.binsPerDay + bin] > cells[base + bin] { aboveFloor += 1 }
        }
        #expect(stats.keysWithTrips == 36 && stats.keysWithoutTrips == 12 && stats.neighborCountHistogram == [0, 0, 0, 0, 0, 0, 0, 1, 47])
        #expect(stats.neighborhoodDominated == 15 && stats.lowData == 12 && stats.varianceAnyBumped == 3_035 && stats.clamped == 0)
        #expect(aboveFloor == 5_551)
        #expect(digest == Self.smoothingGolden, "smoothing payload sha256 \(digest)")
    }

    @Test func storedCellsKeepEveryInvariant() throws {
        let tallies = FlowTallies.tally(Toy.counts(), calendar: Toy.calendar)
        let (cells, flags, _) = FlowSmoothing.smooth(tallies, latE6: Toy.latE6, lonE6: Toy.lonE6, parameters: Toy.parameters)
        let stations = (0..<3).map { row in
            FlowStation(key: ["A", "B", "C"][row], latE6: Toy.latE6[row], lonE6: Toy.lonE6[row], capacity: 10,
                        activeDays: Array(tallies.activeDays[row * 4..<row * 4 + 4]), flags: flags[row])
        }
        let data = FlowsData(departureWindow: Toy.window, arrivalWindow: Toy.window, smoothing: Toy.parameters, holidays: [],
                             stations: stations, cells: cells)
        let flows = try MappedFlows(artifact: MappedArtifact(fileBytes: try data.artifactBytes(dataVersion: "toy")))
        #expect(flows.count == 3 && flows.activeDays(0, .weekend, .arrivals) == 2)
    }
}

/// A deterministic pseudo-random month for the smoothing golden: 48 stations on a 6 × 8 grid
/// 300 m apart (so most have neighbors inside 1 km), a few silent or short-lived ones, bursty
/// counts (so the dispersion path runs), and the build's shorter departure window.
enum Golden {
    static let windows = FlowWindows.trips(from: ServiceDate(year: 2026, month: 2, day: 1), through: ServiceDate(year: 2026, month: 2, day: 28))

    static func payload() throws -> Data { try build().payload }

    static func build() throws -> (payload: Data, stats: FlowSmoothing.Stats, cells: [UInt16]) {
        let keys = 48, days = windows.span.dayCount
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 { // SplitMix64: integers only, the same everywhere
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let latE6 = (0..<keys).map { Int32(40_700_000 + ($0 / 8) * 2_700) }
        let lonE6 = (0..<keys).map { Int32(-74_000_000 + ($0 % 8) * 3_550) }
        var counts = [UInt16](repeating: 0, count: keys * days * FlowsFormat.binsPerDay * FlowCounts.perBin)
        for key in 0..<keys where key % 11 != 5 { // keys 5, 16, 27 and 38 never ride
            let rate = next() % 6 // 0 … 5: busier and quieter stations
            let first = key % 13 == 0 ? 10 : 0, last = key % 17 == 3 ? 12 : days // some open late or close early
            for day in first..<last {
                for bin in 0..<FlowsFormat.binsPerDay {
                    let peak: UInt64 = (28...40).contains(bin) || (64...76).contains(bin) ? 3 : 1
                    for type in 0..<FlowsFormat.bikeTypeCount {
                        for direction in 0..<FlowsFormat.directionCount {
                            if direction == 0, !windows.days(.departures).contains(day) { continue }
                            let roll = next() % 64
                            guard roll < rate * peak else { continue }
                            let burst = roll == 0 ? UInt16(next() % 7) : 1 // an occasional crowd
                            let index = FlowCounts.index(key: key, day: day, bin: bin, type: type, direction: direction, dayCount: days)
                            counts[index] += burst
                        }
                    }
                }
            }
        }
        let calendar = try FlowCalendar(holidays: [FlowCalendar.Holiday(date: ServiceDate(year: 2026, month: 2, day: 16), name: "x", weekendProfile: true)])
        let tallies = FlowTallies.tally(FlowCounts(keyCount: keys, windows: windows, counts: counts, saturated: 0), calendar: calendar)
        let parameters = Toy.parameters // spelled out, so tuning m1 later does not move the golden
        let (cells, flags, stats) = FlowSmoothing.smooth(tallies, latE6: latE6, lonE6: lonE6, parameters: parameters)
        let stations = (0..<keys).map { row in
            FlowStation(key: String(format: "G%02d", row), latE6: latE6[row], lonE6: lonE6[row], capacity: UInt16(row % 40),
                        activeDays: Array(tallies.activeDays[row * 4..<row * 4 + 4]), flags: flags[row])
        }
        let data = FlowsData(departureWindow: windows.departures, arrivalWindow: windows.arrivals, flags: [.customerTripsOnly],
                             smoothing: parameters, holidays: [ServiceDate(year: 2026, month: 2, day: 16)], stations: stations, cells: cells)
        _ = try MappedFlows(artifact: MappedArtifact(fileBytes: data.artifactBytes(dataVersion: "golden"))) // every invariant holds
        return (data.encodedSections(), stats, cells)
    }
}
