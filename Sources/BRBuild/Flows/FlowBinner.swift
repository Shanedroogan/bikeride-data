import BRCore
import BRFlows
import Foundation

/// One trip-data file to count.
public struct TripInput: Sendable {
    public var system: TripSystem
    public var month: TripMonth
    public var archive: any TripArchive

    public init(system: TripSystem, month: TripMonth, archive: any TripArchive) {
        self.system = system
        self.month = month
        self.archive = archive
    }
}

/// How one side's (start or end) station ids resolved, and what became of the trip ends at keys.
public struct TripEndStats: Codable, Sendable, Equatable {
    public var exact = 0
    /// Pad-0 repairs (`5343.1` → `5343.10`), and whether the trip's station name equals the GBFS
    /// name of the repaired key (reported only; a repair never depends on the name).
    public var repaired = 0
    public var repairedNameAgrees = 0
    public var repairedNameDiffers = 0
    public var dockless = 0
    public var depot = 0
    public var unmatched = 0
    /// Unmatched ids equal to a GBFS `station_id` (the trip data should only hold short names).
    public var stationIDStyle = 0
    /// Trip ends at keys counted into the cells.
    public var counted = 0
    /// Trip ends at keys dated outside the window (a file holds trips by `ended_at` month).
    public var outsideWindow = 0
    /// Trip ends at keys whose time does not parse.
    public var badTimestamp = 0
    /// Trip ends at keys of rows with an unknown `rideable_type`.
    public var unknownRideableType = 0

    public init() {}

    /// Trip ends the unmatched gate is about: non-empty ids that are not depots.
    public var joinable: Int { exact + repaired + unmatched }
    public var unmatchedShare: Double { joinable == 0 ? 0 : Double(unmatched) / Double(joinable) }
    public var repairedShare: Double { joinable == 0 ? 0 : Double(repaired) / Double(joinable) }

    mutating func add(_ other: TripEndStats) {
        exact += other.exact
        repaired += other.repaired
        repairedNameAgrees += other.repairedNameAgrees
        repairedNameDiffers += other.repairedNameDiffers
        dockless += other.dockless
        depot += other.depot
        unmatched += other.unmatched
        stationIDStyle += other.stationIDStyle
        counted += other.counted
        outsideWindow += other.outsideWindow
        badTimestamp += other.badTimestamp
        unknownRideableType += other.unknownRideableType
    }
}

/// What one trip-data file held.
public struct TripFileStats: Codable, Sendable, Equatable {
    public var system: TripSystem
    public var month: TripMonth
    public var location: String
    /// The CSV entries read, each with its own header row.
    public var entries: [String] = []
    /// Data rows (headers excluded).
    public var rows = 0
    public var classicRows = 0
    public var ebikeRows = 0
    /// Rows whose `rideable_type` is neither classic nor electric, by value (at most 16 values).
    public var unknownRideableTypes: [String: Int] = [:]
    public var start = TripEndStats()
    public var end = TripEndStats()
    /// Unmatched ids and their trip ends, per side.
    public var unmatchedStartIDs: [String: Int] = [:]
    public var unmatchedEndIDs: [String: Int] = [:]

    public init(system: TripSystem, month: TripMonth, location: String) {
        self.system = system
        self.month = month
        self.location = location
    }

    mutating func add(_ other: TripFileStats) {
        entries += other.entries
        rows += other.rows
        classicRows += other.classicRows
        ebikeRows += other.ebikeRows
        for (value, count) in other.unknownRideableTypes where unknownRideableTypes[value] != nil || unknownRideableTypes.count < 16 {
            unknownRideableTypes[value, default: 0] += count
        }
        start.add(other.start)
        end.add(other.end)
        for (id, count) in other.unmatchedStartIDs { unmatchedStartIDs[id, default: 0] += count }
        for (id, count) in other.unmatchedEndIDs { unmatchedEndIDs[id, default: 0] += count }
    }
}

/// Trip counts per (key, window day, bin, bike type, direction), `u16` each: the raw material of
/// the means and variances. Integer sums, so the order in which entries are merged never matters.
public struct FlowCounts: Sendable {
    public let keyCount: Int
    public let window: FlowWindow
    /// `[key][day][bin][bikeType][direction]`.
    public let counts: [UInt16]
    /// Increments dropped because a counter was at 65,535 (never on real data; the gate fails on it).
    public let saturated: Int

    static let perBin = FlowsFormat.bikeTypeCount * FlowsFormat.directionCount

    @inline(__always)
    static func index(key: Int, day: Int, bin: Int, type: Int, direction: Int, dayCount: Int) -> Int {
        ((key * dayCount + day) * FlowsFormat.binsPerDay + bin) * perBin + type * FlowsFormat.directionCount + direction
    }

    public func count(key: Int, day: Int, bin: Int, type: FlowBikeType, direction: FlowDirection) -> Int {
        Int(counts[Self.index(key: key, day: day, bin: bin, type: Int(type.rawValue), direction: Int(direction.rawValue), dayCount: window.dayCount)])
    }
}

/// Streams trip files into ``FlowCounts``: resolves both station ids of every row, bins each trip
/// end at a key by its local 15-minute bin (departures by `started_at`, arrivals by `ended_at`),
/// and keeps only dates inside the window. Entries are read in parallel, each by its own `unzip`;
/// counters merge under a lock (integer adds, so the result does not depend on scheduling).
public enum FlowBinner {
    public struct Result: Sendable {
        public var counts: FlowCounts
        /// Per input, in input order.
        public var files: [TripFileStats]
    }

    public static func count(
        _ inputs: [TripInput], universe: FlowUniverse, depots: DepotList, window: FlowWindow, threads: Int,
        log: (String) -> Void = { _ in }
    ) throws -> Result {
        let keyCount = universe.stations.count
        let resolver = StationResolver(keys: universe.stations.map(\.key), depots: depots)
        let names = universe.stations.map { Array($0.name.utf8) }
        let accumulator = CountAccumulator(count: keyCount * window.dayCount * FlowsFormat.binsPerDay * FlowCounts.perBin)

        var items: [(input: Int, entry: String)] = []
        for (index, input) in inputs.enumerated() {
            let entries = try input.archive.csvEntries()
            log("\(input.system.rawValue) \(input.month): \(entries.count) CSV entr\(entries.count == 1 ? "y" : "ies") in \(input.archive.location)")
            items += entries.map { (index, $0) }
        }
        let results = LockedCollector<(Int, TripFileStats)>()
        let failures = LockedCollector<(Int, String)>()
        let shared = UncheckedSendable(value: (inputs, items, resolver, names))
        ParallelWork.run(items: items.count, threads: threads, chunk: 1, makeScratch: { () }) { item, _ in
            let (inputs, items, resolver, names) = shared.value
            let (inputIndex, entry) = items[item]
            let input = inputs[inputIndex]
            do {
                let stats = try countEntry(entry, of: input, resolver: resolver, names: names, window: window, into: accumulator)
                results.append((item, stats))
            } catch {
                failures.append((item, "\(input.archive.location) \(entry): \(error)"))
            }
        }
        if let failure = failures.drain().min(by: { $0.0 < $1.0 }) { throw FlowsBuildError.tripFile(failure.1) }

        var files = inputs.map { TripFileStats(system: $0.system, month: $0.month, location: $0.archive.location) }
        for (item, stats) in results.drain().sorted(by: { $0.0 < $1.0 }) {
            files[items[item].input].add(stats)
        }
        for index in files.indices {
            files[index].start.stationIDStyle = files[index].unmatchedStartIDs.filter { universe.stationIDs.contains($0.key) }.values.reduce(0, +)
            files[index].end.stationIDStyle = files[index].unmatchedEndIDs.filter { universe.stationIDs.contains($0.key) }.values.reduce(0, +)
        }
        let (counts, saturated) = accumulator.finish()
        return Result(counts: FlowCounts(keyCount: keyCount, window: window, counts: counts, saturated: saturated), files: files)
    }

    /// Reads one CSV entry to the end.
    static func countEntry(
        _ entry: String, of input: TripInput, resolver: StationResolver, names: [[UInt8]], window: FlowWindow,
        into accumulator: CountAccumulator
    ) throws -> TripFileStats {
        var stats = TripFileStats(system: input.system, month: input.month, location: input.archive.location)
        stats.entries = [entry]
        let stream = try input.archive.open(entry)
        do {
            var reader = CSVReader(stream.source)
            guard let header = try reader.next() else {
                try stream.finish()
                return stats
            }
            let columns = try TripColumns(header: header)
            var cache = ResolutionCache(resolver: resolver)
            var ends = [TripEndStats(), TripEndStats()]
            var unmatched: [[[UInt8]: Int]] = [[:], [:]]
            var events: [UInt64] = []
            events.reserveCapacity(Self.flushThreshold + 2)
            let startDay = window.start.daysSinceEpoch, dayCount = window.dayCount
            while let record = try reader.next() {
                stats.rows += 1
                let typeField = record[columns.rideableType]
                let type = TripRowDecoder.bikeType(typeField)
                switch type {
                case .classic: stats.classicRows += 1
                case .ebike: stats.ebikeRows += 1
                case nil:
                    let value = typeField.string
                    if stats.unknownRideableTypes[value] != nil || stats.unknownRideableTypes.count < 16 {
                        stats.unknownRideableTypes[value, default: 0] += 1
                    }
                }
                for direction in FlowDirection.allCases {
                    let side = Int(direction.rawValue)
                    let id = record[columns.stationID(direction)].bytes
                    let row: Int
                    switch cache.resolve(id) {
                    case .exact(let key):
                        ends[side].exact += 1
                        row = key
                    case .repaired(let key):
                        ends[side].repaired += 1
                        if let nameColumn = columns.stationName(direction) {
                            if record[nameColumn].bytes.elementsEqual(names[key]) {
                                ends[side].repairedNameAgrees += 1
                            } else {
                                ends[side].repairedNameDiffers += 1
                            }
                        }
                        row = key
                    case .dockless:
                        ends[side].dockless += 1
                        continue
                    case .depot:
                        ends[side].depot += 1
                        continue
                    case .unmatched:
                        ends[side].unmatched += 1
                        unmatched[side][Array(id), default: 0] += 1
                        continue
                    }
                    guard let type else {
                        ends[side].unknownRideableType += 1
                        continue
                    }
                    guard let time = TripRowDecoder.localTime(record[columns.time(direction)].bytes) else {
                        ends[side].badTimestamp += 1
                        continue
                    }
                    let day = time.day - startDay
                    guard day >= 0, day < dayCount else {
                        ends[side].outsideWindow += 1
                        continue
                    }
                    ends[side].counted += 1
                    events.append(UInt64(row) << 32 | UInt64(day) << 16 | UInt64(time.minute / FlowsFormat.binMinutes) << 8
                        | UInt64(type.rawValue) << 1 | UInt64(direction.rawValue))
                }
                if events.count >= Self.flushThreshold {
                    accumulator.merge(events, dayCount: dayCount)
                    events.removeAll(keepingCapacity: true)
                }
            }
            accumulator.merge(events, dayCount: dayCount)
            try stream.finish()
            stats.start = ends[0]
            stats.end = ends[1]
            for (id, count) in unmatched[0] { stats.unmatchedStartIDs[String(decoding: id, as: UTF8.self), default: 0] += count }
            for (id, count) in unmatched[1] { stats.unmatchedEndIDs[String(decoding: id, as: UTF8.self), default: 0] += count }
            return stats
        } catch {
            stream.cancel()
            throw error
        }
    }

    static let flushThreshold = 1 << 16
}

/// The shared counters, merged into under a lock.
final class CountAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UInt16]
    private var saturated = 0

    init(count: Int) {
        counts = [UInt16](repeating: 0, count: count)
    }

    func merge(_ events: [UInt64], dayCount: Int) {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        counts.withUnsafeMutableBufferPointer { counts in
            for event in events {
                let key = Int(event >> 32), day = Int((event >> 16) & 0xFFFF), bin = Int((event >> 8) & 0xFF)
                let type = Int((event >> 1) & 1), direction = Int(event & 1)
                let index = FlowCounts.index(key: key, day: day, bin: bin, type: type, direction: direction, dayCount: dayCount)
                if counts[index] == .max { saturated += 1 } else { counts[index] += 1 }
            }
        }
    }

    func finish() -> (counts: [UInt16], saturated: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (counts, saturated)
    }
}

/// A flows build that stopped on bad input.
public enum FlowsBuildError: Error, Equatable, CustomStringConvertible {
    case tripFile(String)

    public var description: String {
        switch self {
        case .tripFile(let why): "trip data: \(why)"
        }
    }
}
