import BRCore
import BRFlows
import Foundation

/// Per (key, day type, direction, series, bin): the sum and the sum of squares of the daily trip
/// counts over the window's days of that type, plus each key's active days. The series are classic,
/// e-bike and any (their per-day sum). Everything here is an integer.
public struct FlowTallies: Sendable {
    public static let series = 3
    public static let anySeries = 2

    public let keyCount: Int
    public let window: FlowWindow
    /// `[key][dayType][direction]` (``FlowsFormat/activeDaysIndex(row:dayType:direction:)``).
    public var activeDays: [UInt16]
    /// `[key][dayType][direction][series][bin]` (``index(key:dayType:direction:series:bin:)``).
    public var sums: [Int64]
    public var squares: [Int64]
    /// Counted trip ends per key, both directions.
    public var tripEnds: [Int]
    /// Counted trip ends per window day, `[direction][day]`.
    public var daily: [[Int]]
    /// Window days per day type.
    public var daysOfType: [Int]

    @inline(__always)
    public static func index(key: Int, dayType: Int, direction: Int, series: Int, bin: Int) -> Int {
        (((key * FlowsFormat.dayTypeCount + dayType) * FlowsFormat.directionCount + direction) * Self.series + series) * FlowsFormat.binsPerDay + bin
    }

    public init(keyCount: Int, window: FlowWindow, activeDays: [UInt16], sums: [Int64], squares: [Int64], tripEnds: [Int], daily: [[Int]], daysOfType: [Int]) {
        self.keyCount = keyCount
        self.window = window
        self.activeDays = activeDays
        self.sums = sums
        self.squares = squares
        self.tripEnds = tripEnds
        self.daily = daily
        self.daysOfType = daysOfType
    }

    /// Sums the counts by day type. A key's active days are the days of each type from its first
    /// to its last day with a counted trip end (either direction, either bike type): a station that
    /// opened or closed inside the window is averaged over the days it existed. Both directions
    /// share the span today; the format keeps them apart so a later build can drop days a station
    /// could not serve one direction (empty or full) without a format change.
    public static func tally(_ counts: FlowCounts, calendar: FlowCalendar) -> FlowTallies {
        let keys = counts.keyCount, days = counts.window.dayCount, bins = FlowsFormat.binsPerDay
        let dayTypes = (0..<days).map { Int(calendar.dayType(of: counts.window.start.adding(days: $0)).rawValue) }
        var daysOfType = [0, 0]
        for type in dayTypes { daysOfType[type] += 1 }
        var sums = [Int64](repeating: 0, count: keys * FlowsFormat.dayTypeCount * FlowsFormat.directionCount * series * bins)
        var squares = sums
        var activeDays = [UInt16](repeating: 0, count: keys * FlowsFormat.dayTypeCount * FlowsFormat.directionCount)
        var tripEnds = [Int](repeating: 0, count: keys)
        var daily = [[Int]](repeating: [Int](repeating: 0, count: days), count: FlowsFormat.directionCount)
        counts.counts.withUnsafeBufferPointer { raw in
            for key in 0..<keys {
                var first = -1, last = -1, total = 0
                for day in 0..<days {
                    let dayType = dayTypes[day]
                    let base = FlowCounts.index(key: key, day: day, bin: 0, type: 0, direction: 0, dayCount: days)
                    var dayTotal = 0
                    for direction in 0..<FlowsFormat.directionCount {
                        var directionTotal = 0
                        let out = index(key: key, dayType: dayType, direction: direction, series: 0, bin: 0)
                        for bin in 0..<bins {
                            let classic = Int64(raw[base + bin * FlowCounts.perBin + direction])
                            let ebike = Int64(raw[base + bin * FlowCounts.perBin + FlowsFormat.directionCount + direction])
                            let any = classic + ebike
                            sums[out + bin] += classic
                            squares[out + bin] += classic * classic
                            sums[out + bins + bin] += ebike
                            squares[out + bins + bin] += ebike * ebike
                            sums[out + 2 * bins + bin] += any
                            squares[out + 2 * bins + bin] += any * any
                            directionTotal += Int(any)
                        }
                        daily[direction][day] += directionTotal
                        dayTotal += directionTotal
                    }
                    if dayTotal > 0 {
                        if first < 0 { first = day }
                        last = day
                        total += dayTotal
                    }
                }
                tripEnds[key] = total
                guard first >= 0 else { continue }
                var active = [0, 0]
                for day in first...last { active[dayTypes[day]] += 1 }
                for dayType in 0..<FlowsFormat.dayTypeCount {
                    for direction in 0..<FlowsFormat.directionCount {
                        activeDays[(key * FlowsFormat.dayTypeCount + dayType) * FlowsFormat.directionCount + direction] = UInt16(active[dayType])
                    }
                }
            }
        }
        return FlowTallies(keyCount: keys, window: counts.window, activeDays: activeDays, sums: sums, squares: squares,
                           tripEnds: tripEnds, daily: daily, daysOfType: daysOfType)
    }
}

/// Empirical-Bayes smoothing of the tallies into the stored cells, in pseudo-days (formula in
/// `docs/formats.md`, "flows"). Deterministic on every host by construction: integer inputs,
/// only `+ − × ÷` and comparisons on `Double` (no libm), a fixed evaluation order, integer
/// neighbor distances, and binary16 rounding by bit operations (``HalfFloat``).
public enum FlowSmoothing {
    /// `round(cos(40.73°) × 1024)`: east–west microdegrees are this many 1024ths of a north–south
    /// microdegree in length at New York's latitude (a constant, so no cosine is ever computed).
    public static let longitudeScale1024: Int64 = 776
    /// Meters per degree of latitude on the 6,371.0088 km mean sphere, rounded.
    public static let metersPerDegree: Int64 = 111_195

    public struct Stats: Codable, Sendable, Equatable {
        public var keys = 0
        public var keysWithTrips = 0
        /// Keys with no counted trip end: cells from their neighbors alone (or zero).
        public var keysWithoutTrips = 0
        /// Keys by number of neighbors found (index = neighbor count).
        public var neighborCountHistogram: [Int] = []
        public var neighborhoodDominated = 0
        public var lowData = 0
        /// `varianceAny` cells raised by one or more binary16 steps so the stored variance still
        /// covers the stored `meanClassic + meanEbike` after rounding.
        public var varianceAnyBumped = 0
        /// Cells that would round past 65,504 and were clamped (none on real data).
        public var clamped = 0
        public var maxMean: Double = 0
        public var maxVariance: Double = 0
        /// Share of stored (typed) cells whose variance equals the mean: the Poisson floor.
        public var poissonFloorShare: Double = 0
    }

    /// Each key's neighbors: up to `count` other keys with counted trips within `radiusMeters`,
    /// nearest first, ties by key order. Distances are integers (microdegrees, the longitude
    /// difference scaled by ``longitudeScale1024``), so the choice is identical everywhere.
    public static func neighbors(latE6: [Int32], lonE6: [Int32], hasTrips: [Bool], count: Int, radiusMeters: Int64) -> [[Int]] {
        let keys = latE6.count
        // The radius in 1024ths of a microdegree of latitude.
        let radius = radiusMeters * 1_024 * 1_000_000 / metersPerDegree
        let radiusSquared = radius * radius
        let latitudeBound = radius / 1_024 + 1
        let longitudeBound = radius / longitudeScale1024 + 1
        var result = [[Int]](repeating: [], count: keys)
        guard count > 0 else { return result }
        for key in 0..<keys {
            var candidates: [(distance: Int64, key: Int)] = []
            for other in 0..<keys where other != key && hasTrips[other] {
                let dLat = Int64(latE6[other]) - Int64(latE6[key]), dLon = Int64(lonE6[other]) - Int64(lonE6[key])
                guard abs(dLat) <= latitudeBound, abs(dLon) <= longitudeBound else { continue }
                let y = dLat * 1_024, x = dLon * longitudeScale1024
                let distance = y * y + x * x
                if distance <= radiusSquared { candidates.append((distance, other)) }
            }
            candidates.sort { ($0.distance, $0.key) < ($1.distance, $1.key) }
            result[key] = candidates.prefix(count).map(\.key)
        }
        return result
    }

    /// The stored cells (binary16 bit patterns, ``FlowsFormat/cellIndex(row:dayType:direction:slot:bin:)``
    /// order) and each key's flags.
    public static func smooth(
        _ tallies: FlowTallies, latE6: [Int32], lonE6: [Int32], parameters: FlowSmoothingParameters
    ) -> (cells: [UInt16], flags: [FlowStationFlags], stats: Stats) {
        let keys = tallies.keyCount, bins = FlowsFormat.binsPerDay
        let kappaCell = Double(parameters.kappaCellMilli) / 1_000
        let kappaHour = Double(parameters.kappaHourMilli) / 1_000
        let kappaDispersion = Double(parameters.kappaDispersionMilli) / 1_000
        let neighbors = neighbors(latE6: latE6, lonE6: lonE6, hasTrips: tallies.tripEnds.map { $0 > 0 },
                                  count: Int(parameters.neighborCount), radiusMeters: parameters.neighborRadiusMeters)
        var stats = Stats()
        stats.keys = keys
        stats.neighborCountHistogram = [Int](repeating: 0, count: Int(parameters.neighborCount) + 1)
        var cells = [UInt16](repeating: 0, count: keys * FlowsFormat.cellsPerKey)
        var flags = [FlowStationFlags](repeating: [.inGBFS], count: keys)
        var poissonCells = 0, typedCells = 0

        func days(_ key: Int, _ dayType: Int, _ direction: Int) -> Int {
            Int(tallies.activeDays[(key * FlowsFormat.dayTypeCount + dayType) * FlowsFormat.directionCount + direction])
        }

        var means = [[Double]](repeating: [Double](repeating: 0, count: bins), count: FlowTallies.series)
        var dispersions = means
        for key in 0..<keys {
            stats.neighborCountHistogram[neighbors[key].count] += 1
            if tallies.tripEnds[key] > 0 { stats.keysWithTrips += 1 } else { stats.keysWithoutTrips += 1 }
            var activeTotal = 0
            for dayType in 0..<FlowsFormat.dayTypeCount {
                let n = days(key, dayType, 0)
                activeTotal += n
                if Double(n) < kappaCell { flags[key].insert(.neighborhoodDominated) }
                for direction in 0..<FlowsFormat.directionCount {
                    for series in 0..<FlowTallies.series {
                        smoothSeries(
                            tallies, key: key, dayType: dayType, direction: direction, series: series,
                            neighbors: neighbors[key], days: days, kappaCell: kappaCell, kappaHour: kappaHour,
                            kappaDispersion: kappaDispersion, means: &means[series], dispersions: &dispersions[series]
                        )
                    }
                    // Store: typed means and variances, and the any-type variance around the sum of
                    // the typed means.
                    for bin in 0..<bins {
                        let meanC = means[0][bin], meanE = means[1][bin]
                        let bitsMeanC = encode(meanC, &stats), bitsMeanE = encode(meanE, &stats)
                        var bitsVarC = encode(meanC * dispersions[0][bin], &stats)
                        var bitsVarE = encode(meanE * dispersions[1][bin], &stats)
                        if bitsVarC < bitsMeanC { bitsVarC = bitsMeanC }
                        if bitsVarE < bitsMeanE { bitsVarE = bitsMeanE }
                        let sumMeans = HalfFloat.double(fromBits: bitsMeanC) + HalfFloat.double(fromBits: bitsMeanE)
                        var bitsVarA = encode((meanC + meanE) * dispersions[2][bin], &stats)
                        var bumped = false
                        while HalfFloat.double(fromBits: bitsVarA) < sumMeans, bitsVarA < HalfFloat.greatestFinite {
                            bitsVarA = HalfFloat.nextUp(bitsVarA)
                            bumped = true
                        }
                        if bumped { stats.varianceAnyBumped += 1 }
                        let dayTypeValue = FlowDayType(rawValue: UInt8(dayType))!, directionValue = FlowDirection(rawValue: UInt8(direction))!
                        func put(_ slot: FlowSlot, _ bits: UInt16) {
                            cells[FlowsFormat.cellIndex(row: key, dayType: dayTypeValue, direction: directionValue, slot: slot, bin: bin)] = bits
                        }
                        put(.meanClassic, bitsMeanC)
                        put(.varianceClassic, bitsVarC)
                        put(.meanEbike, bitsMeanE)
                        put(.varianceEbike, bitsVarE)
                        put(.varianceAny, bitsVarA)
                        typedCells += 2
                        if bitsVarC == bitsMeanC { poissonCells += 1 }
                        if bitsVarE == bitsMeanE { poissonCells += 1 }
                        stats.maxMean = max(stats.maxMean, HalfFloat.double(fromBits: bitsMeanC), HalfFloat.double(fromBits: bitsMeanE))
                        stats.maxVariance = max(stats.maxVariance, HalfFloat.double(fromBits: bitsVarA))
                    }
                }
            }
            if activeTotal == 0 || tallies.tripEnds[key] < activeTotal { flags[key].insert(.lowData) }
            if flags[key].contains(.lowData) { stats.lowData += 1 }
            if flags[key].contains(.neighborhoodDominated) { stats.neighborhoodDominated += 1 }
        }
        stats.poissonFloorShare = typedCells == 0 ? 0 : Double(poissonCells) / Double(typedCells)
        return (cells, flags, stats)
    }

    /// One series: the smoothed mean and the dispersion factor (variance ÷ mean, at least 1) per bin.
    static func smoothSeries(
        _ tallies: FlowTallies, key: Int, dayType: Int, direction: Int, series: Int, neighbors: [Int],
        days: (Int, Int, Int) -> Int, kappaCell: Double, kappaHour: Double, kappaDispersion: Double,
        means: inout [Double], dispersions: inout [Double]
    ) {
        let bins = FlowsFormat.binsPerDay
        let base = FlowTallies.index(key: key, dayType: dayType, direction: direction, series: series, bin: 0)
        let n = days(key, dayType, direction)
        let nDouble = Double(n)

        // Raw means and the station's daily total.
        var raw = [Double](repeating: 0, count: bins)
        var total = 0.0
        if n > 0 {
            for bin in 0..<bins {
                raw[bin] = Double(tallies.sums[base + bin]) / nDouble
                total += raw[bin]
            }
        }

        // Neighborhood prior: the neighbors' mean profile as a shape, scaled to the station's own
        // daily total (or to the neighbors' mean total when the station has no active days).
        var shape = [Double](repeating: 0, count: bins)
        var shapeTotal = 0.0
        var neighborsWithDays = 0
        for other in neighbors {
            let m = days(other, dayType, direction)
            guard m > 0 else { continue }
            neighborsWithDays += 1
            let otherBase = FlowTallies.index(key: other, dayType: dayType, direction: direction, series: series, bin: 0)
            for bin in 0..<bins { shape[bin] += Double(tallies.sums[otherBase + bin]) / Double(m) }
        }
        for bin in 0..<bins { shapeTotal += shape[bin] }
        var prior = [Double](repeating: 0, count: bins)
        if shapeTotal > 0 {
            let target = n > 0 ? total : shapeTotal / Double(neighborsWithDays)
            for bin in 0..<bins { prior[bin] = shape[bin] / shapeTotal * target }
        } else if n > 0 {
            for bin in 0..<bins { prior[bin] = total / Double(bins) } // flat at the station's own rate
        }

        // Station-hour, then cell means.
        for hour in 0..<(bins / 4) {
            var hourSum = 0.0, hourPrior = 0.0
            for bin in hour * 4..<hour * 4 + 4 {
                hourSum += Double(tallies.sums[base + bin])
                hourPrior += prior[bin]
            }
            let hourMean = (hourSum + kappaHour * hourPrior) / (4 * (nDouble + kappaHour))
            for bin in hour * 4..<hour * 4 + 4 {
                let denominator = nDouble + kappaCell
                means[bin] = denominator > 0 ? (Double(tallies.sums[base + bin]) + kappaCell * hourMean) / denominator : hourMean
            }
        }

        // Dispersion: the cell's own variance-to-mean ratio shrunk toward its hour's, floored at 1.
        guard n >= 2 else {
            for bin in 0..<bins { dispersions[bin] = 1 }
            return
        }
        var variance = [Double](repeating: 0, count: bins)
        for bin in 0..<bins {
            let s = tallies.sums[base + bin], q = tallies.squares[base + bin]
            let numerator = Int64(n) * q - s * s // n²·(sample variance)·(n−1)/n ≥ 0, exact
            variance[bin] = Double(max(0, numerator)) / (nDouble * (nDouble - 1))
        }
        for hour in 0..<(bins / 4) {
            var hourVariance = 0.0, hourMean = 0.0
            for bin in hour * 4..<hour * 4 + 4 {
                hourVariance += variance[bin]
                hourMean += raw[bin]
            }
            let hourDispersion = hourMean > 0 ? hourVariance / hourMean : 1
            for bin in hour * 4..<hour * 4 + 4 {
                let cellDispersion = raw[bin] > 0 ? variance[bin] / raw[bin] : hourDispersion
                dispersions[bin] = max(1, (nDouble * cellDispersion + kappaDispersion * hourDispersion) / (nDouble + kappaDispersion))
            }
        }
    }

    /// Binary16 of a finite non-negative value, clamped to the largest finite half.
    @inline(__always)
    static func encode(_ value: Double, _ stats: inout Stats) -> UInt16 {
        let bits = HalfFloat.bits(from: value)
        if bits > HalfFloat.greatestFinite {
            stats.clamped += 1
            return HalfFloat.greatestFinite
        }
        return bits
    }
}
