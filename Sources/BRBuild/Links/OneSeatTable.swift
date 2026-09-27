import BRCore
import BRTimetable
import Foundation

/// The rail stations riders can go between without changing trains, for the bike-hop one-seat
/// filter (`docs/formats.md`, "links: rail bike hops"): a hop A → B is dropped when a train
/// already rides A → B about as fast as the bike.
///
/// - **Existence** is calendar-independent: some pattern with at least one trip lets riders board
///   at a platform of A and later alight at a platform of B.
/// - **Midday** figures come from one reference day per system (``referenceDate(_:excluding:)``): the trips
///   boarding at A between ``HopOptions/middayStartSeconds`` and ``HopOptions/middayEndSeconds``
///   that later alight at B, counted once each, and the least in-vehicle time among them.
public struct OneSeatTable: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// Trips of the reference day boarding at A in the midday window and alighting at B.
        public var middayTrips = 0
        /// The least in-vehicle seconds (alighting arrival − boarding departure) of those trips.
        public var middayMinInVehicleSeconds = Int.max
        /// The least in-vehicle seconds of any trip of the reference day, at any hour (reported
        /// only, as an alternative rule).
        public var dayMinInVehicleSeconds = Int.max

        public init(middayTrips: Int = 0, middayMinInVehicleSeconds: Int = .max, dayMinInVehicleSeconds: Int = .max) {
            self.middayTrips = middayTrips
            self.middayMinInVehicleSeconds = middayMinInVehicleSeconds
            self.dayMinInVehicleSeconds = dayMinInVehicleSeconds
        }
    }

    /// Keyed by `A << 32 | B` (global stop indices of the two parents).
    public var pairs: [UInt64: Entry]
    /// The day the midday figures come from, per rail system (none for a system with no covered
    /// date).
    public var referenceDates: [TransitSystem: ServiceDate]

    public init(pairs: [UInt64: Entry] = [:], referenceDates: [TransitSystem: ServiceDate] = [:]) {
        self.pairs = pairs
        self.referenceDates = referenceDates
    }

    public static func key(_ origin: Int, _ destination: Int) -> UInt64 { UInt64(origin) << 32 | UInt64(destination) }

    public func entry(from origin: Int, to destination: Int) -> Entry? { pairs[Self.key(origin, destination)] }

    /// A typical weekday from the timetable's own coverage, so the result depends only on the
    /// artifact and `holidays` (never on the build machine's clock): the first covered Tuesday,
    /// Wednesday or Thursday that is not a holiday; else the first covered weekday that is not
    /// one; else the first covered date.
    public static func referenceDate(_ timetable: Timetable, excluding holidays: Set<ServiceDate> = []) -> ServiceDate? {
        let dates = timetable.coveredDates
        let workdays = dates.filter { !holidays.contains($0) }
        return workdays.first { [.tuesday, .wednesday, .thursday].contains($0.weekday) }
            ?? workdays.first { $0.weekday.rawValue <= Weekday.friday.rawValue }
            ?? dates.first
    }

    public static func build(timetables: [TransitSystem: Timetable], network: LinkNetwork, parents: RailParents,
                             options: HopOptions) -> OneSeatTable {
        var parentOf = [Int32](repeating: -1, count: network.stopCount)
        for (index, platforms) in parents.platforms.enumerated() {
            for platform in platforms { parentOf[platform] = Int32(parents.parents[index]) }
        }
        var table = OneSeatTable()
        // Entries in a flat array while building: one dictionary lookup per pattern and pair,
        // not per trip.
        var entryOf: [UInt64: Int] = [:], keysInOrder: [UInt64] = [], entries: [Entry] = []
        for system in LinksFormat.hopSystems {
            guard let timetable = timetables[system] else { continue }
            let base = network.stopBase(system)
            let reference = referenceDate(timetable, excluding: options.holidays)
            if let reference { table.referenceDates[system] = reference }
            let view = reference.map { timetable.dayView(for: $0) }
            for pattern in 0..<timetable.patternCount where timetable.patternTripCount(pattern) > 0 {
                let stops = timetable.patternStops(pattern), n = stops.count
                let parent = stops.map { Int(parentOf[base + Int($0)]) }
                // The pattern's (board, alight) position pairs between two different parents,
                // grouped by parent pair (a loop can give one pair twice).
                var keys: [Int] = [], keyIndex: [UInt64: Int] = [:] // pattern-local index → entry
                var combos: [(key: Int, board: Int, alight: Int)] = []
                for i in 0..<n where parent[i] >= 0 && timetable.canBoard(pattern: pattern, position: i) {
                    for k in (i + 1)..<n where parent[k] >= 0 && parent[k] != parent[i] && timetable.canAlight(pattern: pattern, position: k) {
                        let key = Self.key(parent[i], parent[k])
                        let index: Int
                        if let known = keyIndex[key] {
                            index = known
                        } else {
                            index = keys.count
                            keyIndex[key] = index
                            if let entry = entryOf[key] {
                                keys.append(entry)
                            } else {
                                entryOf[key] = entries.count
                                keys.append(entries.count)
                                keysInOrder.append(key)
                                entries.append(Entry())
                            }
                        }
                        combos.append((index, i, k))
                    }
                }
                guard !combos.isEmpty, let view else { continue }
                let active = view.activeTrips(inPattern: pattern)
                guard !active.isEmpty else { continue }
                let departures = timetable.patternDepartures(pattern), arrivals = timetable.patternArrivals(pattern)
                let first = timetable.patternTrips(pattern).lowerBound
                var midday = [Int](repeating: .max, count: keys.count), day = midday
                for trip in active {
                    let row = (Int(trip) - first) * n
                    for index in midday.indices {
                        midday[index] = .max
                        day[index] = .max
                    }
                    for combo in combos {
                        let departure = Int(departures[row + combo.board])
                        let ride = Int(arrivals[row + combo.alight]) - departure
                        day[combo.key] = min(day[combo.key], ride)
                        if departure >= options.middayStartSeconds && departure < options.middayEndSeconds {
                            midday[combo.key] = min(midday[combo.key], ride)
                        }
                    }
                    for (index, entry) in keys.enumerated() {
                        entries[entry].dayMinInVehicleSeconds = min(entries[entry].dayMinInVehicleSeconds, day[index])
                        if midday[index] != .max {
                            entries[entry].middayTrips += 1
                            entries[entry].middayMinInVehicleSeconds = min(entries[entry].middayMinInVehicleSeconds, midday[index])
                        }
                    }
                }
            }
        }
        table.pairs = Dictionary(uniqueKeysWithValues: zip(keysInOrder, entries))
        return table
    }
}
