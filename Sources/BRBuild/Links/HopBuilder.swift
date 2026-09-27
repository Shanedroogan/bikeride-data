import BRCore
import BRStreetCore
import BRTimetable
import Foundation

/// Tunables of the rail bike hops (`docs/formats.md`, "links: rail bike hops"). The stored
/// ``parameters`` shape the artifact; the rest only decide which pairs are kept.
public struct HopOptions: Sendable, Equatable {
    /// Build the hop block (only when `stations.bin` is present).
    public var enabled = true
    /// A 5–25 min ride at some pace between 0.85 × 8 mph (3,040 mm/s, the slowest classic
    /// pace) and 1.15 × 10 mph (5,141 mm/s, the fastest e-bike pace): best-tuple rides of
    /// 912–7,711 m. Ranked at 10 mph (4,470 mm/s) with a 90 s unlock and a 60 s dock; 2 pickups
    /// × 2 docks per hop.
    public var parameters = LinkHopParameters(
        minRideSeconds: 300, maxRideSeconds: 1500, minSpeedMmPerSecond: 3040, maxSpeedMmPerSecond: 5141,
        rankSpeedMmPerSecond: 4470, unlockSeconds: 90, dockSeconds: 60, pickupsPerHop: 2, docksPerHop: 2
    )
    /// Drop a pair when a one-seat ride beats the bike at midday (``OneSeatTable``).
    public var oneSeatFilter = true
    /// The midday window, in seconds from the service day's origin: 10:00–16:00.
    public var middayStartSeconds = 36_000
    public var middayEndSeconds = 57_600
    /// The change after the bike that the door-to-door time includes: the larger of this and
    /// ``afterBikeRidePermille`` of the ride.
    public var afterBikeMinSeconds = 60
    public var afterBikeRidePermille = 100

    public init() {}
}

/// Where a bike matrix distance comes from: the `stations` artifact, or a table in tests.
public protocol HopDistances: Sendable {
    /// Decameters by bike, or `0xFFFF` for no path.
    func decameters(from origin: Int, to destination: Int) -> UInt16
}

extension MappedStations: HopDistances {
    public func decameters(from origin: Int, to destination: Int) -> UInt16 { distanceDecameters(from: origin, to: destination) }
}

/// A dense row-major matrix, e.g. for hand-built tests.
public struct DenseHopDistances: HopDistances {
    public let count: Int
    public let values: [UInt16]

    public init(count: Int, values: [UInt16]) {
        precondition(values.count == count * count, "one value per pair")
        self.count = count
        self.values = values
    }

    public func decameters(from origin: Int, to destination: Int) -> UInt16 { values[origin * count + destination] }
}

/// The rail parent stations: for every routable platform p of `tt-subway`, `tt-lirr` and
/// `tt-path`, its parent station, or p itself when it has none (a LIRR stop). Ferry and bus stops
/// have no hops.
public struct RailParents: Sendable, Equatable {
    /// Global stop index of each parent, ascending.
    public var parents: [Int]
    /// Each parent's routable platforms (global index), ascending.
    public var platforms: [[Int]]

    public init(parents: [Int], platforms: [[Int]]) {
        precondition(parents.count == platforms.count && zip(parents, parents.dropFirst()).allSatisfy { $0 < $1 }, "parents ascending, one platform list each")
        self.parents = parents
        self.platforms = platforms
    }

    public static func make(timetables: [TransitSystem: Timetable], network: LinkNetwork) -> RailParents {
        var byParent: [Int: [Int]] = [:]
        for system in LinksFormat.hopSystems {
            guard let timetable = timetables[system] else { continue }
            let base = network.stopBase(system)
            for local in 0..<timetable.stopCount where network.routable[base + local] {
                byParent[base + (timetable.stopParent(local) ?? local), default: []].append(base + local)
            }
        }
        let parents = byParent.keys.sorted()
        return RailParents(parents: parents, platforms: parents.map { byParent[$0]!.sorted() })
    }
}

/// A station with the walk to or from it, in whole seconds (station access included).
public struct StationWalk: Sendable, Hashable {
    public var station: Int
    public var seconds: Int

    public init(station: Int, seconds: Int) {
        self.station = station
        self.seconds = seconds
    }
}

/// One kept hop, before serialization.
public struct CompiledHop: Sendable, Equatable {
    public var origin: Int
    public var target: Int
    /// Station indices, best first (slot 0 of each is the best tuple); at most kP and kD.
    public var pickups: [Int]
    public var docks: [Int]
    public var minDecameters: Int
    public var minWalkSeconds: Int
    public var flags: LinkHopFlags
    /// The best tuple's matrix distance, and the bike's door-to-door seconds at the fastest pace
    /// (the one-seat comparison); report only.
    public var bestDecameters: Int
    public var bikeSeconds: Int
    /// The alternative rule (the day's fastest one-seat ride instead of midday's) would drop it.
    public var droppedByDayMinimum: Bool

    public init(origin: Int, target: Int, pickups: [Int], docks: [Int], minDecameters: Int, minWalkSeconds: Int, flags: LinkHopFlags,
                bestDecameters: Int, bikeSeconds: Int, droppedByDayMinimum: Bool) {
        self.origin = origin
        self.target = target
        self.pickups = pickups
        self.docks = docks
        self.minDecameters = minDecameters
        self.minWalkSeconds = minWalkSeconds
        self.flags = flags
        self.bestDecameters = bestDecameters
        self.bikeSeconds = bikeSeconds
        self.droppedByDayMinimum = droppedByDayMinimum
    }
}

/// Why a pair of rail parents does or does not get a hop.
public enum HopDecision: Sendable, Equatable {
    /// No pickup near A, no dock near B, or no bike path between any of them.
    case noTuple
    /// The best tuple's ride is under the window even at the slowest pace, or over it even at the
    /// fastest.
    case belowWindow(bestDecameters: Int)
    case aboveWindow(bestDecameters: Int)
    /// A midday one-seat ride (fastest in-vehicle time + half the midday headway) is no slower
    /// than the bike door-to-door at the fastest pace.
    case beatenByOneSeat(bikeSeconds: Int, oneSeatSeconds: Int)
    case kept(CompiledHop)
}

/// The hop block, before serialization: CSR over the global stop index.
public struct CompiledHops: Sendable, Equatable {
    public var parameters: LinkHopParameters
    /// Hops of origin A: `start[A] ..< start[A + 1]`.
    public var start: [UInt32]
    public var target: [UInt32]
    /// kP (kD) slots per hop, ``BRTimetable/LinksFormat/noStation`` in unused ones.
    public var pickups: [UInt16]
    public var docks: [UInt16]
    public var minDecameters: [UInt16]
    public var minWalkSeconds: [UInt16]
    public var flags: [UInt8]

    public init(parameters: LinkHopParameters, start: [UInt32], target: [UInt32], pickups: [UInt16], docks: [UInt16],
                minDecameters: [UInt16], minWalkSeconds: [UInt16], flags: [UInt8]) {
        let h = target.count
        precondition(Int(start.last ?? 0) == h && pickups.count == h * parameters.pickupsPerHop && docks.count == h * parameters.docksPerHop
            && minDecameters.count == h && minWalkSeconds.count == h && flags.count == h, "inconsistent hop table")
        self.parameters = parameters
        self.start = start
        self.target = target
        self.pickups = pickups
        self.docks = docks
        self.minDecameters = minDecameters
        self.minWalkSeconds = minWalkSeconds
        self.flags = flags
    }

    /// Hops over `stops` global stops, grouped by origin (any order in, ascending out).
    public init(parameters: LinkHopParameters, stops: Int, hops: [CompiledHop]) {
        let sorted = hops.sorted { ($0.origin, $0.target) < ($1.origin, $1.target) }
        var start = [UInt32](repeating: 0, count: stops + 1)
        for hop in sorted { start[hop.origin + 1] += 1 }
        for stop in 0..<stops { start[stop + 1] += start[stop] }
        func slots(_ stations: [Int], _ k: Int) -> [UInt16] {
            precondition(!stations.isEmpty && stations.count <= k, "1 to k stations per hop")
            return stations.map { UInt16($0) } + [UInt16](repeating: LinksFormat.noStation, count: k - stations.count)
        }
        self.init(
            parameters: parameters, start: start, target: sorted.map { UInt32($0.target) },
            pickups: sorted.flatMap { slots($0.pickups, parameters.pickupsPerHop) },
            docks: sorted.flatMap { slots($0.docks, parameters.docksPerHop) },
            minDecameters: sorted.map { UInt16($0.minDecameters) }, minWalkSeconds: sorted.map { UInt16(min($0.minWalkSeconds, 0xFFFE)) },
            flags: sorted.map(\.flags.rawValue)
        )
    }

    public var count: Int { target.count }
}

public struct HopStats: Codable, Sendable, Equatable {
    /// Rail parents by system, and their routable platforms.
    public var railParents: [String: Int] = [:]
    public var railPlatforms = 0
    public var parentsWithPickup = 0
    public var parentsWithDock = 0
    /// Ordered pairs A ≠ B with a pickup near A, a dock near B and a bike path between them.
    public var candidatePairs = 0
    public var droppedBelowWindow = 0
    public var droppedAboveWindow = 0
    public var droppedByOneSeat = 0
    public var hops = 0
    /// Kept although a one-seat ride exists (flag bit 0).
    public var hopsWithOneSeatRide = 0
    /// Kept hops with fewer than kP pickups, fewer than kD docks, or either.
    public var hopsWithFewerPickups = 0
    public var hopsWithFewerDocks = 0
    public var hopsWithFewerPickupsOrDocks = 0
    /// Kept hops by (origin system → destination system), e.g. `subway→lirr`.
    public var bySystemPair: [String: Int] = [:]
    public var origins = 0
    public var perOrigin = Distribution()
    public var bestMeters = Distribution()
    /// Kept hops the alternative one-seat rule (the reference day's fastest ride at any hour
    /// instead of midday's) would also drop.
    public var alsoDroppedByDayMinimum = 0
    /// Parent pairs with a one-seat ride on some trip, and with one at midday on the reference day.
    public var oneSeatPairs = 0
    public var oneSeatMiddayPairs = 0
    /// The reference day per system (YYYYMMDD).
    public var oneSeatReferenceDates: [String: String] = [:]
    /// (hop, platform, station) triples where a platform of A has no exit link to a stored pickup,
    /// or a platform of B no enter link from a stored dock. The compiler fails unless both are 0.
    public var platformPickupLinksMissing = 0
    public var platformDockLinksMissing = 0
    public var missingLinkExamples: [String] = []
    /// Bytes of the hop block (extension id 1), raw.
    public var blockBytes = 0

    public init() {}
}

public enum HopBuilder {
    /// Everything a hop decision reads, indexed by rail parent (``RailParents`` order).
    public struct Inputs: Sendable {
        /// Stops per system in ``BRTimetable/LinksFormat/systems`` order (the global index).
        public var systemStopCounts: [Int]
        public var parents: RailParents
        /// Stations with an exit link from some platform of the parent, with the least exit
        /// seconds; by station.
        public var pickups: [[StationWalk]]
        /// Stations with an enter link to some platform of the parent, with the least enter
        /// seconds; by station.
        public var docks: [[StationWalk]]
        public var stationCount: Int
        public var distances: any HopDistances
        /// `nil`: no one-seat filter and no flag.
        public var oneSeat: OneSeatTable?

        public init(systemStopCounts: [Int], parents: RailParents, pickups: [[StationWalk]], docks: [[StationWalk]], stationCount: Int,
                    distances: any HopDistances, oneSeat: OneSeatTable?) {
            precondition(systemStopCounts.count == LinksFormat.systems.count, "one count per system")
            precondition(pickups.count == parents.parents.count && docks.count == parents.parents.count, "one list per parent")
            precondition(stationCount < Int(LinksFormat.noStation), "station indices must fit a u16 slot")
            self.systemStopCounts = systemStopCounts
            self.parents = parents
            self.pickups = pickups
            self.docks = docks
            self.stationCount = stationCount
            self.distances = distances
            self.oneSeat = oneSeat
        }

        /// Pickups and docks from the stop-side station links of each parent's platforms.
        public init(systemStopCounts: [Int], parents: RailParents, stationLinks: StationLinkTable, stationCount: Int,
                    distances: any HopDistances, oneSeat: OneSeatTable?) {
            var pickups: [[StationWalk]] = [], docks: [[StationWalk]] = []
            for platforms in parents.platforms {
                var exit: [Int: Int] = [:], enter: [Int: Int] = [:]
                for platform in platforms {
                    for slot in Int(stationLinks.stopStart[platform])..<Int(stationLinks.stopStart[platform + 1]) {
                        let station = Int(stationLinks.stopStation[slot])
                        if stationLinks.stopExit[slot] != LinksFormat.noSeconds { exit[station] = min(exit[station] ?? .max, Int(stationLinks.stopExit[slot])) }
                        if stationLinks.stopEnter[slot] != LinksFormat.noSeconds { enter[station] = min(enter[station] ?? .max, Int(stationLinks.stopEnter[slot])) }
                    }
                }
                pickups.append(exit.keys.sorted().map { StationWalk(station: $0, seconds: exit[$0]!) })
                docks.append(enter.keys.sorted().map { StationWalk(station: $0, seconds: enter[$0]!) })
            }
            self.init(systemStopCounts: systemStopCounts, parents: parents, pickups: pickups, docks: docks, stationCount: stationCount,
                      distances: distances, oneSeat: oneSeat)
        }

        public var stopCount: Int { systemStopCounts.reduce(0, +) }

        /// The report name of a global stop's system.
        func systemName(ofStop stop: Int) -> String {
            var end = 0
            for (slot, system) in LinksFormat.systems.enumerated() {
                end += systemStopCounts[slot]
                if stop < end { return system.linkReportName }
            }
            preconditionFailure("stop \(stop) is past the global index")
        }
    }

    /// Whole seconds to ride `decameters` at `speed` mm/s, rounded up.
    static func rideSeconds(_ decameters: Int, _ speed: Int) -> Int { (decameters * 10_000 + speed - 1) / speed }

    /// The decision for parents `a` → `b` (indices into ``Inputs/parents``). Integer arithmetic only.
    public static func evaluate(_ a: Int, _ b: Int, inputs: Inputs, options: HopOptions) -> HopDecision {
        let pickups = inputs.pickups[a], docks = inputs.docks[b]
        guard a != b, !pickups.isEmpty, !docks.isEmpty else { return .noTuple }
        let p = options.parameters
        let fixed = p.unlockSeconds + p.dockSeconds
        // Every tuple with a path: pickups and docks scored by their best tuple, and the best
        // tuple overall by (total, pickup, dock).
        var pickupScore = [Int](repeating: .max, count: pickups.count), dockScore = [Int](repeating: .max, count: docks.count)
        var best: (total: Int, u: Int, d: Int, decameters: Int)?
        var distance = [Int](repeating: Int(StationsFormat.unreachable), count: pickups.count * docks.count)
        for (i, u) in pickups.enumerated() {
            for (j, d) in docks.enumerated() {
                let decameters = Int(inputs.distances.decameters(from: u.station, to: d.station))
                guard decameters != Int(StationsFormat.unreachable) else { continue }
                distance[i * docks.count + j] = decameters
                let total = u.seconds + fixed + rideSeconds(decameters, p.rankSpeedMmPerSecond) + d.seconds
                pickupScore[i] = min(pickupScore[i], total)
                dockScore[j] = min(dockScore[j], total)
                if best.map({ (total, u.station, d.station) < ($0.total, $0.u, $0.d) }) ?? true {
                    best = (total, u.station, d.station, decameters)
                }
            }
        }
        guard let best else { return .noTuple }
        let millimeters = best.decameters * 10_000
        if millimeters < p.minRideSeconds * p.minSpeedMmPerSecond { return .belowWindow(bestDecameters: best.decameters) }
        if millimeters > p.maxRideSeconds * p.maxSpeedMmPerSecond { return .aboveWindow(bestDecameters: best.decameters) }

        // Slot 0 is the best tuple's; then the rest by (score, station).
        func choose(_ walks: [StationWalk], _ scores: [Int], first: Int, _ k: Int) -> [Int] {
            let rest = walks.indices.filter { scores[$0] != .max && walks[$0].station != first }
                .sorted { (scores[$0], walks[$0].station) < (scores[$1], walks[$1].station) }
            return [walks.firstIndex { $0.station == first }!] + rest.prefix(k - 1)
        }
        let chosenPickups = choose(pickups, pickupScore, first: best.u, p.pickupsPerHop)
        let chosenDocks = choose(docks, dockScore, first: best.d, p.docksPerHop)
        var minDecameters = Int.max, minWalk = Int.max, bike = Int.max
        for i in chosenPickups {
            for j in chosenDocks {
                let decameters = distance[i * docks.count + j]
                guard decameters != Int(StationsFormat.unreachable) else { continue }
                let walk = pickups[i].seconds + docks[j].seconds
                let ride = rideSeconds(decameters, p.maxSpeedMmPerSecond)
                minDecameters = min(minDecameters, decameters)
                minWalk = min(minWalk, walk)
                bike = min(bike, walk + fixed + ride + max(options.afterBikeMinSeconds, ride * options.afterBikeRidePermille / 1000))
            }
        }

        var flags: LinkHopFlags = []
        var droppedByDayMinimum = false
        let origin = inputs.parents.parents[a], target = inputs.parents.parents[b]
        if let entry = inputs.oneSeat?.entry(from: origin, to: target) {
            flags.insert(.oneSeatRideExists)
            if entry.middayTrips > 0 {
                let halfHeadway = (options.middayEndSeconds - options.middayStartSeconds) / entry.middayTrips / 2
                let rival = entry.middayMinInVehicleSeconds + halfHeadway
                if options.oneSeatFilter && rival <= bike { return .beatenByOneSeat(bikeSeconds: bike, oneSeatSeconds: rival) }
                droppedByDayMinimum = entry.dayMinInVehicleSeconds + halfHeadway <= bike
            }
        }
        return .kept(CompiledHop(
            origin: origin, target: target, pickups: chosenPickups.map { pickups[$0].station }, docks: chosenDocks.map { docks[$0].station },
            minDecameters: minDecameters, minWalkSeconds: minWalk, flags: flags, bestDecameters: best.decameters, bikeSeconds: bike,
            droppedByDayMinimum: droppedByDayMinimum
        ))
    }

    /// Every ordered pair of rail parents, in parallel by origin; the result does not depend on
    /// `threads`.
    public static func build(_ inputs: Inputs, options: HopOptions, threads: Int) -> (hops: CompiledHops, stats: HopStats) {
        let n = inputs.parents.parents.count
        struct Partial {
            var hops: [CompiledHop] = []
            var candidates = 0, below = 0, above = 0, oneSeat = 0
        }
        let results = SharedBuffer<Partial>(count: n, repeating: Partial())
        let out = results.pointer
        let shared = UncheckedSendable(value: out)
        let destinations = (0..<n).filter { !inputs.docks[$0].isEmpty }
        ParallelWork.run(items: n, threads: threads, chunk: 4, makeScratch: { () }) { a, _ in
            guard !inputs.pickups[a].isEmpty else { return }
            var partial = Partial()
            for b in destinations where b != a {
                switch evaluate(a, b, inputs: inputs, options: options) {
                case .noTuple: continue
                case .belowWindow: partial.below += 1
                case .aboveWindow: partial.above += 1
                case .beatenByOneSeat: partial.oneSeat += 1
                case .kept(let hop): partial.hops.append(hop)
                }
                partial.candidates += 1
            }
            shared.value[a] = partial
        }
        let partials = results.toArray()

        var stats = HopStats()
        let systemOf = inputs.systemName(ofStop:)
        for (index, parent) in inputs.parents.parents.enumerated() {
            stats.railParents[systemOf(parent), default: 0] += 1
            stats.railPlatforms += inputs.parents.platforms[index].count
            if !inputs.pickups[index].isEmpty { stats.parentsWithPickup += 1 }
            if !inputs.docks[index].isEmpty { stats.parentsWithDock += 1 }
        }
        var all: [CompiledHop] = []
        var perOrigin: [Double] = []
        for partial in partials {
            stats.candidatePairs += partial.candidates
            stats.droppedBelowWindow += partial.below
            stats.droppedAboveWindow += partial.above
            stats.droppedByOneSeat += partial.oneSeat
            if !partial.hops.isEmpty { perOrigin.append(Double(partial.hops.count)) }
            all += partial.hops
        }
        let p = options.parameters
        for hop in all {
            if hop.flags.contains(.oneSeatRideExists) { stats.hopsWithOneSeatRide += 1 }
            if hop.pickups.count < p.pickupsPerHop { stats.hopsWithFewerPickups += 1 }
            if hop.docks.count < p.docksPerHop { stats.hopsWithFewerDocks += 1 }
            if hop.pickups.count < p.pickupsPerHop || hop.docks.count < p.docksPerHop { stats.hopsWithFewerPickupsOrDocks += 1 }
            if hop.droppedByDayMinimum { stats.alsoDroppedByDayMinimum += 1 }
            stats.bySystemPair["\(systemOf(hop.origin))→\(systemOf(hop.target))", default: 0] += 1
        }
        stats.hops = all.count
        stats.origins = perOrigin.count
        stats.perOrigin = Distribution(perOrigin)
        stats.bestMeters = Distribution(all.map { Double($0.bestDecameters * 10) })
        if let oneSeat = inputs.oneSeat {
            stats.oneSeatPairs = oneSeat.pairs.count
            stats.oneSeatMiddayPairs = oneSeat.pairs.values.filter { $0.middayTrips > 0 }.count
            stats.oneSeatReferenceDates = Dictionary(uniqueKeysWithValues: oneSeat.referenceDates.map { ($0.key.linkReportName, $0.value.yyyymmdd) })
        }
        return (CompiledHops(parameters: p, stops: inputs.stopCount, hops: all), stats)
    }

    /// Counts (hop, platform, station) triples where a routable platform of A has no exit link to
    /// a stored pickup, or a platform of B no enter link from a stored dock. Every platform of a
    /// parent shares its access points (``LinkNetwork/make(timetables:graph:options:)``), so both
    /// counts are 0 by construction; the compiler checks it stays that way.
    public static func checkPlatformLinks(_ hops: CompiledHops, parents: RailParents, stationLinks: StationLinkTable,
                                          stats: inout HopStats) {
        func link(_ platform: Int, _ station: Int) -> (enter: UInt16, exit: UInt16)? {
            for slot in Int(stationLinks.stopStart[platform])..<Int(stationLinks.stopStart[platform + 1])
            where Int(stationLinks.stopStation[slot]) == station {
                return (stationLinks.stopEnter[slot], stationLinks.stopExit[slot])
            }
            return nil
        }
        let index = Dictionary(uniqueKeysWithValues: parents.parents.enumerated().map { ($1, $0) })
        let kP = hops.parameters.pickupsPerHop, kD = hops.parameters.docksPerHop
        func note(_ text: String) { if stats.missingLinkExamples.count < 20 { stats.missingLinkExamples.append(text) } }
        for origin in 0..<(hops.start.count - 1) {
            for row in Int(hops.start[origin])..<Int(hops.start[origin + 1]) {
                let target = Int(hops.target[row])
                for platform in parents.platforms[index[origin]!] {
                    for u in hops.pickups[row * kP..<(row + 1) * kP] where u != LinksFormat.noStation {
                        if (link(platform, Int(u))?.exit ?? LinksFormat.noSeconds) == LinksFormat.noSeconds {
                            stats.platformPickupLinksMissing += 1
                            note("hop \(origin)→\(target): platform \(platform) has no exit link to station \(u)")
                        }
                    }
                }
                for platform in parents.platforms[index[target]!] {
                    for d in hops.docks[row * kD..<(row + 1) * kD] where d != LinksFormat.noStation {
                        if (link(platform, Int(d))?.enter ?? LinksFormat.noSeconds) == LinksFormat.noSeconds {
                            stats.platformDockLinksMissing += 1
                            note("hop \(origin)→\(target): platform \(platform) has no enter link from station \(d)")
                        }
                    }
                }
            }
        }
    }
}
