import BRBuild
import BRCore
import BRTimetable
import Foundation

/// Hop decisions recomputed by enumerating and sorting every tuple: an implementation separate
/// from ``HopBuilder/evaluate(_:_:inputs:options:)`` that shares only the rules of
/// `docs/formats.md` ("links: rail bike hops").
enum HopReference {
    struct Tuple {
        let total: Int, u: Int, d: Int, decameters: Int, exit: Int, enter: Int
    }

    static func ceilDivide(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return q * b < a ? q + 1 : q
    }

    static func decide(_ a: Int, _ b: Int, inputs: HopBuilder.Inputs, options: HopOptions) -> HopDecision {
        guard a != b else { return .noTuple }
        let p = options.parameters
        var tuples: [Tuple] = []
        for u in inputs.pickups[a] {
            for d in inputs.docks[b] {
                let decameters = Int(inputs.distances.decameters(from: u.station, to: d.station))
                if decameters == 0xFFFF { continue }
                let ride = ceilDivide(decameters * 10 * 1000, p.rankSpeedMmPerSecond)
                tuples.append(Tuple(total: u.seconds + p.unlockSeconds + ride + p.dockSeconds + d.seconds,
                                    u: u.station, d: d.station, decameters: decameters, exit: u.seconds, enter: d.seconds))
            }
        }
        guard !tuples.isEmpty else { return .noTuple }
        let byPickup = tuples.sorted { ($0.total, $0.u, $0.d) < ($1.total, $1.u, $1.d) }
        let best = byPickup[0]
        if best.decameters * 10_000 < p.minRideSeconds * p.minSpeedMmPerSecond { return .belowWindow(bestDecameters: best.decameters) }
        if best.decameters * 10_000 > p.maxRideSeconds * p.maxSpeedMmPerSecond { return .aboveWindow(bestDecameters: best.decameters) }
        func firstAppearances(_ values: [Int]) -> [Int] {
            var seen = Set<Int>(), result: [Int] = []
            for value in values where seen.insert(value).inserted { result.append(value) }
            return result
        }
        let pickups = Array(firstAppearances(byPickup.map(\.u)).prefix(p.pickupsPerHop))
        let byDock = tuples.sorted { ($0.total, $0.d, $0.u) < ($1.total, $1.d, $1.u) }
        let docks = [best.d] + firstAppearances(byDock.map(\.d)).filter { $0 != best.d }.prefix(p.docksPerHop - 1)
        let stored = tuples.filter { pickups.contains($0.u) && docks.contains($0.d) }
        let bike = stored.map { t -> Int in
            let ride = ceilDivide(t.decameters * 10_000, p.maxSpeedMmPerSecond)
            return t.exit + p.unlockSeconds + ride + p.dockSeconds + t.enter + max(options.afterBikeMinSeconds, ride * options.afterBikeRidePermille / 1000)
        }.min()!
        let origin = inputs.parents.parents[a], target = inputs.parents.parents[b]
        var flags: LinkHopFlags = []
        var dayRule = false
        if let entry = inputs.oneSeat?.pairs[OneSeatTable.key(origin, target)] {
            flags = .oneSeatRideExists
            if entry.middayTrips > 0 {
                let headway = (options.middayEndSeconds - options.middayStartSeconds) / entry.middayTrips
                if options.oneSeatFilter && entry.middayMinInVehicleSeconds + headway / 2 <= bike {
                    return .beatenByOneSeat(bikeSeconds: bike, oneSeatSeconds: entry.middayMinInVehicleSeconds + headway / 2)
                }
                dayRule = entry.dayMinInVehicleSeconds + headway / 2 <= bike
            }
        }
        return .kept(CompiledHop(
            origin: origin, target: target, pickups: pickups, docks: docks,
            minDecameters: stored.map(\.decameters).min()!, minWalkSeconds: stored.map { $0.exit + $0.enter }.min()!,
            flags: flags, bestDecameters: best.decameters, bikeSeconds: bike, droppedByDayMinimum: dayRule
        ))
    }

    /// Every ordered pair's decision, and the kept hops.
    static func all(_ inputs: HopBuilder.Inputs, options: HopOptions) -> (decisions: [HopDecision], hops: [CompiledHop]) {
        var decisions: [HopDecision] = [], hops: [CompiledHop] = []
        let n = inputs.parents.parents.count
        for a in 0..<n {
            for b in 0..<n {
                let decision = decide(a, b, inputs: inputs, options: options)
                decisions.append(decision)
                if case .kept(let hop) = decision { hops.append(hop) }
            }
        }
        return (decisions, hops)
    }
}

/// A random rail world for hop property tests: parents with 1–2 platforms, random pickups and
/// docks, a random matrix with gaps, random one-seat rides and random tunables.
struct RandomHopWorld {
    let inputs: HopBuilder.Inputs
    let options: HopOptions
    let stationLinks: StationLinkTable

    init(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let counts = [8 + rng.nextInt(below: 8), 3, 2 + rng.nextInt(below: 3), 1, 2 + rng.nextInt(below: 2)]
        let t = counts.reduce(0, +)
        let stationCount = 6 + rng.nextInt(below: 10)
        // Rail stops: subway [0, c0), LIRR and PATH after bus. Parents take 1–2 consecutive stops.
        var railStops: [Int] = []
        var base = 0
        for (slot, system) in LinksFormat.systems.enumerated() {
            if LinksFormat.hopSystems.contains(system) { railStops += Array(base..<base + counts[slot]) }
            base += counts[slot]
        }
        var parents: [Int] = [], platforms: [[Int]] = []
        var index = 0
        while index < railStops.count {
            let take = min(1 + rng.nextInt(below: 2), railStops.count - index)
            let group = Array(railStops[index..<index + take])
            parents.append(group[0])
            platforms.append(group)
            index += take
        }
        func walks() -> [StationWalk] {
            let stations = (0..<stationCount).filter { _ in rng.nextInt(below: 4) == 0 }
            return stations.map { StationWalk(station: $0, seconds: 30 + rng.nextInt(below: 400)) }
        }
        let pickups = parents.map { _ in rng.nextInt(below: 6) == 0 ? [] : walks() }
        let docks = parents.map { _ in rng.nextInt(below: 6) == 0 ? [] : walks() }
        var matrix = [UInt16](repeating: 0, count: stationCount * stationCount)
        for i in 0..<stationCount {
            for j in 0..<stationCount where i != j {
                // Ties on purpose: a coarse grid of distances.
                matrix[i * stationCount + j] = rng.nextInt(below: 7) == 0 ? 0xFFFF : UInt16(30 + 40 * rng.nextInt(below: 22))
            }
        }
        var oneSeat = OneSeatTable()
        for a in parents {
            for b in parents where a != b && rng.nextInt(below: 3) == 0 {
                let trips = rng.nextInt(below: 4) == 0 ? 0 : 1 + rng.nextInt(below: 30)
                let midday = trips == 0 ? Int.max : 200 + rng.nextInt(below: 1800)
                oneSeat.pairs[OneSeatTable.key(a, b)] = OneSeatTable.Entry(
                    middayTrips: trips, middayMinInVehicleSeconds: midday,
                    dayMinInVehicleSeconds: midday == .max ? 200 + rng.nextInt(below: 1800) : midday - rng.nextInt(below: 200))
            }
        }
        var options = HopOptions()
        options.parameters = LinkHopParameters(
            minRideSeconds: 240 + rng.nextInt(below: 120), maxRideSeconds: 1200 + rng.nextInt(below: 600),
            minSpeedMmPerSecond: 2500 + rng.nextInt(below: 1000), maxSpeedMmPerSecond: 4500 + rng.nextInt(below: 1500),
            rankSpeedMmPerSecond: 3600 + rng.nextInt(below: 900), unlockSeconds: rng.nextInt(below: 120), dockSeconds: rng.nextInt(below: 90),
            pickupsPerHop: 1 + rng.nextInt(below: 3), docksPerHop: 1 + rng.nextInt(below: 3)
        )
        options.oneSeatFilter = rng.nextInt(below: 5) != 0

        // Station links consistent with the walks, the same on every platform of a parent.
        var perStop = [[(station: UInt32, enter: UInt16, exit: UInt16)]](repeating: [], count: t)
        for (index, group) in platforms.enumerated() {
            var links: [Int: (enter: UInt16, exit: UInt16)] = [:]
            for walk in pickups[index] { links[walk.station, default: (LinksFormat.noSeconds, LinksFormat.noSeconds)].exit = UInt16(walk.seconds) }
            for walk in docks[index] { links[walk.station, default: (LinksFormat.noSeconds, LinksFormat.noSeconds)].enter = UInt16(walk.seconds) }
            for platform in group {
                perStop[platform] = links.keys.sorted().map { (UInt32($0), links[$0]!.enter, links[$0]!.exit) }
            }
        }
        var table = StationLinkTable.empty(stops: t, stations: stationCount)
        table.stopStart = [0]
        for stop in 0..<t {
            for link in perStop[stop] {
                table.stopStation.append(link.station)
                table.stopEnter.append(link.enter)
                table.stopExit.append(link.exit)
            }
            table.stopStart.append(UInt32(table.stopStation.count))
        }
        stationLinks = table
        self.options = options
        inputs = HopBuilder.Inputs(systemStopCounts: counts, parents: RailParents(parents: parents, platforms: platforms),
                                   pickups: pickups, docks: docks, stationCount: stationCount,
                                   distances: DenseHopDistances(count: stationCount, values: matrix), oneSeat: oneSeat)
    }
}
