import BRBuild
import BRCore
import BRData
import BRTimetable
import Foundation
import Testing

/// Rail bike hops (`docs/formats.md`, "links: rail bike hops"): the builder against enumeration,
/// the window edges, the one-seat rule, ties, padding, the platform-link check, the one-seat table
/// from a compiled timetable, and the reader's hop invariants.
@Suite struct HopBuilderTests {
    // MARK: - A hand-built world

    /// Three rail parents at global stops 0, 2 and 5 (subway 0–3, bus 4, LIRR 5) and four stations.
    /// Parent 0 has platforms 0 and 1; station 0 and 1 are near it, 2 and 3 near parent 2.
    struct Tiny {
        var parameters = LinkHopParameters(minRideSeconds: 300, maxRideSeconds: 1500, minSpeedMmPerSecond: 3000, maxSpeedMmPerSecond: 5000,
                                           rankSpeedMmPerSecond: 4000, unlockSeconds: 90, dockSeconds: 60, pickupsPerHop: 2, docksPerHop: 2)
        var pickups: [[StationWalk]] = [
            [StationWalk(station: 0, seconds: 100), StationWalk(station: 1, seconds: 150)], [], [StationWalk(station: 3, seconds: 80)],
        ]
        var docks: [[StationWalk]] = [
            [StationWalk(station: 0, seconds: 100)], [], [StationWalk(station: 2, seconds: 120), StationWalk(station: 3, seconds: 90)],
        ]
        /// Decameters, 4 × 4.
        var matrix: [UInt16] = [
            0, 50, 400, 420,
            50, 0, 410, 400,
            400, 410, 0, 30,
            420, 400, 30, 0,
        ]
        var oneSeat = OneSeatTable()

        var options: HopOptions {
            var options = HopOptions()
            options.parameters = parameters
            return options
        }

        var inputs: HopBuilder.Inputs {
            HopBuilder.Inputs(systemStopCounts: [4, 1, 1, 0, 0], parents: RailParents(parents: [0, 2, 5], platforms: [[0, 1], [2, 3], [5]]),
                              pickups: pickups, docks: docks, stationCount: 4, distances: DenseHopDistances(count: 4, values: matrix),
                              oneSeat: oneSeat)
        }

        func decide(_ a: Int, _ b: Int) -> HopDecision { HopBuilder.evaluate(a, b, inputs: inputs, options: options) }
    }

    @Test func buildsTheBestTuplesAndBounds() throws {
        let tiny = Tiny()
        // Parent 0 → parent 2: tuples (u, d) with totals exit + 150 + ride(4 m/s) + enter.
        // (0,2) 100+150+1000+120 = 1370, (0,3) 100+150+1050+90 = 1390, (1,2) 150+150+1025+120 = 1445,
        // (1,3) 150+150+1000+90 = 1390. Best (0, 2); pickups 0 (1370), 1 (1390); docks 2 (1370), 3 (1390).
        guard case .kept(let hop) = tiny.decide(0, 2) else { Issue.record("expected a hop, got \(tiny.decide(0, 2))"); return }
        #expect(hop.origin == 0 && hop.target == 5 && hop.pickups == [0, 1] && hop.docks == [2, 3])
        #expect(hop.bestDecameters == 400 && hop.minDecameters == 400 && hop.minWalkSeconds == 190 && hop.flags == [])
        // At 5 m/s, plus max(60 s, 10% of the ride): (0,2) 100+150+800+120+80 = 1250, (0,3) 1264,
        // (1,2) 1322, (1,3) 1270.
        #expect(hop.bikeSeconds == 1250)
        #expect(tiny.decide(0, 1) == .noTuple && tiny.decide(1, 2) == .noTuple && tiny.decide(0, 0) == .noTuple)
        // Parent 2 → parent 0: station 3 → station 0, 420 dam, the only tuple.
        guard case .kept(let back) = tiny.decide(2, 0) else { Issue.record("expected a hop back"); return }
        #expect(back.pickups == [3] && back.docks == [0] && back.minWalkSeconds == 180)

        let (hops, stats) = HopBuilder.build(tiny.inputs, options: tiny.options, threads: 2)
        #expect(hops.start == [0, 1, 1, 1, 1, 1, 2] && hops.target == [5, 0])
        #expect(hops.pickups == [0, 1, 3, LinksFormat.noStation] && hops.docks == [2, 3, 0, LinksFormat.noStation])
        #expect(hops.minDecameters == [400, 420] && hops.minWalkSeconds == [190, 180] && hops.flags == [0, 0])
        #expect(stats.hops == 2 && stats.candidatePairs == 2 && stats.hopsWithFewerPickupsOrDocks == 1 && stats.parentsWithPickup == 2)
        #expect(stats.railParents == ["subway": 2, "lirr": 1] && stats.railPlatforms == 5 && stats.bySystemPair == ["subway→lirr": 1, "lirr→subway": 1])
    }

    @Test func windowEdgesAreInclusive() {
        // minRide × minSpeed = 300 × 3,000 mm = 90 dam; maxRide × maxSpeed = 1,500 × 5,000 mm = 750 dam.
        func decision(_ decameters: UInt16) -> HopDecision {
            var tiny = Tiny()
            tiny.pickups[0] = [StationWalk(station: 0, seconds: 60)]
            tiny.docks[2] = [StationWalk(station: 2, seconds: 60)]
            tiny.matrix[2] = decameters
            return tiny.decide(0, 2)
        }
        #expect(decision(89) == .belowWindow(bestDecameters: 89))
        #expect(decision(751) == .aboveWindow(bestDecameters: 751))
        for edge: UInt16 in [90, 750] {
            guard case .kept(let hop) = decision(edge) else { Issue.record("\(edge) dam should be kept"); continue }
            #expect(hop.bestDecameters == Int(edge))
        }
        // The window judges the best tuple, not the others: a 60 dam best tuple drops the pair
        // though its second tuple is 400 dam.
        var tiny = Tiny()
        tiny.matrix[0 * 4 + 3] = 60
        tiny.pickups[0] = [StationWalk(station: 0, seconds: 60)]
        #expect(tiny.decide(0, 2) == .belowWindow(bestDecameters: 60))
    }

    @Test func oneSeatRidesDropOrFlag() throws {
        var tiny = Tiny()
        let bike = 1250 // parent 0 → 2 at the fastest pace, from buildsTheBestTuplesAndBounds
        let window = 6 * 3600
        // 12 midday trips: headway 1,800 s, half 900 s. In-vehicle 350 s: 350 + 900 = 1,250 ≤ 1,250.
        tiny.oneSeat.pairs[OneSeatTable.key(0, 5)] = OneSeatTable.Entry(middayTrips: window / 1800, middayMinInVehicleSeconds: bike - 900,
                                                                         dayMinInVehicleSeconds: 200)
        #expect(tiny.decide(0, 2) == .beatenByOneSeat(bikeSeconds: bike, oneSeatSeconds: bike))
        // One second slower: kept, flagged, and the day's fastest ride (200 s) would have dropped it.
        tiny.oneSeat.pairs[OneSeatTable.key(0, 5)]!.middayMinInVehicleSeconds = bike - 899
        guard case .kept(let kept) = tiny.decide(0, 2) else { Issue.record("expected a hop"); return }
        #expect(kept.flags == .oneSeatRideExists && kept.droppedByDayMinimum)
        // A one-seat ride with no midday trip only flags the hop.
        tiny.oneSeat.pairs[OneSeatTable.key(0, 5)] = OneSeatTable.Entry(middayTrips: 0, middayMinInVehicleSeconds: .max, dayMinInVehicleSeconds: 60)
        guard case .kept(let flagged) = tiny.decide(0, 2) else { Issue.record("expected a hop"); return }
        #expect(flagged.flags == .oneSeatRideExists && !flagged.droppedByDayMinimum)
        // With the filter off the fast ride only flags it; with no table there is no flag.
        tiny.oneSeat.pairs[OneSeatTable.key(0, 5)] = OneSeatTable.Entry(middayTrips: 100, middayMinInVehicleSeconds: 60, dayMinInVehicleSeconds: 60)
        var options = tiny.options
        options.oneSeatFilter = false
        guard case .kept(let unfiltered) = HopBuilder.evaluate(0, 2, inputs: tiny.inputs, options: options) else { Issue.record("expected a hop"); return }
        #expect(unfiltered.flags == .oneSeatRideExists)
        var inputs = tiny.inputs
        inputs.oneSeat = nil
        guard case .kept(let plain) = HopBuilder.evaluate(0, 2, inputs: inputs, options: tiny.options) else { Issue.record("expected a hop"); return }
        #expect(plain.flags == [])
    }

    @Test func tiesGoToTheLowerStationIndex() throws {
        var tiny = Tiny()
        // Every tuple from parent 0 to parent 2 costs the same.
        tiny.pickups[0] = [StationWalk(station: 0, seconds: 100), StationWalk(station: 1, seconds: 100)]
        tiny.docks[2] = [StationWalk(station: 2, seconds: 100), StationWalk(station: 3, seconds: 100)]
        tiny.matrix = [0, 50, 400, 400, 50, 0, 400, 400, 400, 400, 0, 30, 400, 400, 30, 0]
        tiny.parameters.pickupsPerHop = 1
        tiny.parameters.docksPerHop = 1
        guard case .kept(let hop) = tiny.decide(0, 2) else { Issue.record("expected a hop"); return }
        #expect(hop.pickups == [0] && hop.docks == [2])
        // Listed in the other order, the result is the same.
        tiny.pickups[0].reverse()
        tiny.docks[2].reverse()
        guard case .kept(let reversed) = tiny.decide(0, 2) else { Issue.record("expected a hop"); return }
        #expect(reversed.pickups == [0] && reversed.docks == [2])
    }

    @Test func padsMissingSlots() {
        var tiny = Tiny()
        tiny.parameters.pickupsPerHop = 3
        tiny.parameters.docksPerHop = 3
        let (hops, _) = HopBuilder.build(tiny.inputs, options: tiny.options, threads: 1)
        #expect(hops.pickups == [0, 1, LinksFormat.noStation, 3, LinksFormat.noStation, LinksFormat.noStation])
        #expect(hops.docks == [2, 3, LinksFormat.noStation, 0, LinksFormat.noStation, LinksFormat.noStation])
    }

    // MARK: - Random worlds

    @Test(arguments: 0..<60) func equalsEnumeration(seed: UInt64) {
        let world = RandomHopWorld(seed: seed)
        let (hops, stats) = HopBuilder.build(world.inputs, options: world.options, threads: 3)
        let reference = HopReference.all(world.inputs, options: world.options)
        let n = world.inputs.parents.parents.count
        for a in 0..<n {
            for b in 0..<n {
                let expected = reference.decisions[a * n + b], found = HopBuilder.evaluate(a, b, inputs: world.inputs, options: world.options)
                #expect(found == expected, "seed \(seed): \(a) → \(b)")
            }
        }
        #expect(hops == CompiledHops(parameters: world.options.parameters, stops: world.inputs.stopCount, hops: reference.hops))
        #expect(stats.hops == reference.hops.count)
        var below = 0, above = 0, oneSeat = 0, candidates = 0
        for decision in reference.decisions {
            switch decision {
            case .noTuple: continue
            case .belowWindow: below += 1
            case .aboveWindow: above += 1
            case .beatenByOneSeat: oneSeat += 1
            case .kept: break
            }
            candidates += 1
        }
        #expect(stats.droppedBelowWindow == below && stats.droppedAboveWindow == above && stats.droppedByOneSeat == oneSeat && stats.candidatePairs == candidates)
        // Pickups and docks from the platforms' station links equal the lists they came from.
        let fromLinks = HopBuilder.Inputs(systemStopCounts: world.inputs.systemStopCounts, parents: world.inputs.parents,
                                          stationLinks: world.stationLinks, stationCount: world.inputs.stationCount,
                                          distances: world.inputs.distances, oneSeat: world.inputs.oneSeat)
        #expect(fromLinks.pickups == world.inputs.pickups.map { $0.sorted { $0.station < $1.station } })
        #expect(fromLinks.docks == world.inputs.docks.map { $0.sorted { $0.station < $1.station } })
        var check = HopStats()
        HopBuilder.checkPlatformLinks(hops, parents: world.inputs.parents, stationLinks: world.stationLinks, stats: &check)
        #expect(check.platformPickupLinksMissing == 0 && check.platformDockLinksMissing == 0)
    }

    @Test func randomWorldsAreNotTrivial() {
        var kept = 0, below = 0, above = 0, oneSeat = 0, padded = 0, flagged = 0
        for seed in 0..<60 as Range<UInt64> {
            let world = RandomHopWorld(seed: seed)
            for decision in HopReference.all(world.inputs, options: world.options).decisions {
                switch decision {
                case .kept(let hop):
                    kept += 1
                    if hop.pickups.count < world.options.parameters.pickupsPerHop { padded += 1 }
                    if hop.flags.contains(.oneSeatRideExists) { flagged += 1 }
                case .belowWindow: below += 1
                case .aboveWindow: above += 1
                case .beatenByOneSeat: oneSeat += 1
                case .noTuple: break
                }
            }
        }
        #expect(kept > 200 && below > 20 && above > 20 && oneSeat > 20 && padded > 20 && flagged > 20, "\([kept, below, above, oneSeat, padded, flagged])")
    }

    @Test func resultsDoNotDependOnThreads() {
        for seed in [3, 17, 42] as [UInt64] {
            let world = RandomHopWorld(seed: seed)
            let one = HopBuilder.build(world.inputs, options: world.options, threads: 1)
            for threads in [4, 8] {
                let many = HopBuilder.build(world.inputs, options: world.options, threads: threads)
                #expect(many.hops == one.hops && many.stats == one.stats)
            }
        }
    }

    /// With the default paces, a stored tuple that rides less far than the best never sets the
    /// one-seat comparison's bike time (`HopBuilder.evaluate`), so spare short tuples, even u = d,
    /// cannot keep a pair a one-seat ride beats.
    @Test func bikeTimeComesFromTheBestTupleOrALongerRide() {
        var options = HopOptions()
        options.oneSeatFilter = false
        let p = options.parameters
        var hops = 0, shorterTuples = 0, longerTupleSetsBike = 0
        for seed in 0..<40 as Range<UInt64> {
            let inputs = RandomHopWorld(seed: seed).inputs
            let n = inputs.parents.parents.count
            for a in 0..<n {
                for b in 0..<n {
                    guard case .kept(let hop) = HopBuilder.evaluate(a, b, inputs: inputs, options: options) else { continue }
                    hops += 1
                    let exit = Dictionary(uniqueKeysWithValues: inputs.pickups[a].map { ($0.station, $0.seconds) })
                    let enter = Dictionary(uniqueKeysWithValues: inputs.docks[b].map { ($0.station, $0.seconds) })
                    func bike(_ u: Int, _ d: Int) -> (seconds: Int, decameters: Int)? {
                        let decameters = Int(inputs.distances.decameters(from: u, to: d))
                        guard decameters != 0xFFFF else { return nil }
                        let ride = HopReference.ceilDivide(decameters * 10_000, p.maxSpeedMmPerSecond)
                        return (exit[u]! + p.unlockSeconds + ride + p.dockSeconds + enter[d]! + max(60, ride / 10), decameters)
                    }
                    let best = bike(hop.pickups[0], hop.docks[0])!
                    let stored = hop.pickups.flatMap { u in hop.docks.compactMap { d in bike(u, d) } }
                    #expect(hop.bikeSeconds == stored.map(\.seconds).min())
                    for tuple in stored where tuple.decameters < best.decameters {
                        shorterTuples += 1
                        #expect(tuple.seconds > best.seconds, "seed \(seed), \(a) → \(b)")
                    }
                    if hop.bikeSeconds < best.seconds { longerTupleSetsBike += 1 }
                }
            }
        }
        #expect(hops > 100 && shorterTuples > 100 && longerTupleSetsBike > 0, "\(hops) hops, \(shorterTuples) shorter tuples, \(longerTupleSetsBike)")
    }

    // MARK: - Platform links

    @Test func findsPlatformsWithoutALinkToAStoredStation() throws {
        // A world with a two-platform parent that has a hop.
        let (world, hops, index) = try #require((0..<50 as Range<UInt64>).lazy.compactMap { seed -> (RandomHopWorld, CompiledHops, Int)? in
            let world = RandomHopWorld(seed: seed)
            let hops = HopBuilder.build(world.inputs, options: world.options, threads: 1).hops
            let parents = world.inputs.parents
            return parents.parents.indices.first { parents.platforms[$0].count == 2 && hops.start[parents.parents[$0]] < hops.start[parents.parents[$0] + 1] }
                .map { (world, hops, $0) }
        }.first)
        // Remove the exit link to its first pickup from its second platform.
        let parents = world.inputs.parents
        let row = Int(hops.start[parents.parents[index]])
        let pickup = UInt32(hops.pickups[row * world.options.parameters.pickupsPerHop])
        let platform = parents.platforms[index][1]
        var links = world.stationLinks
        let slot = (Int(links.stopStart[platform])..<Int(links.stopStart[platform + 1])).first { links.stopStation[$0] == pickup }!
        links.stopExit[slot] = LinksFormat.noSeconds
        var stats = HopStats()
        HopBuilder.checkPlatformLinks(hops, parents: parents, stationLinks: links, stats: &stats)
        #expect(stats.platformPickupLinksMissing > 0 && stats.platformDockLinksMissing == 0 && !stats.missingLinkExamples.isEmpty)
    }

    // MARK: - One-seat table

    /// X, Y and Z in a row, plus W with no pickup on the loop trip. Trips: T1 X→Y→Z at 10:00 and T2
    /// at 11:00 (Z 10 min after X); T3 the express X→Z at 20:00 (5 min); T4 at 12:00 loops
    /// X→Y→X→Y and calls at W without pickup.
    static func railFeed() -> [String: String] {
        [
            "agency.txt": TransitFixture.agency("MTA NYCT"),
            "routes.txt": "route_id,agency_id,route_short_name,route_type\nL,MTA NYCT,L,1\nE,MTA NYCT,E,1\n",
            "stops.txt": """
                stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
                X,X,\(TransitFixture.point(1, 1)),1,
                XN,X,\(TransitFixture.point(1, 1)),0,X
                XS,X,\(TransitFixture.point(1, 1)),0,X
                Y,Y,\(TransitFixture.point(3, 1)),1,
                YN,Y,\(TransitFixture.point(3, 1)),0,Y
                Z,Z,\(TransitFixture.point(5, 1)),1,
                ZN,Z,\(TransitFixture.point(5, 1)),0,Z
                W,W,\(TransitFixture.point(7, 1)),1,
                WN,W,\(TransitFixture.point(7, 1)),0,W
                """,
            "calendar.txt": TransitFixture.calendar,
            "trips.txt": "route_id,trip_id,service_id\nL,T1,ALL\nL,T2,ALL\nE,T3,ALL\nL,T4,ALL\n",
            "stop_times.txt": """
                trip_id,stop_id,arrival_time,departure_time,stop_sequence,pickup_type,drop_off_type
                T1,XN,10:00:00,10:00:00,1,0,0
                T1,YN,10:04:00,10:04:00,2,0,0
                T1,ZN,10:10:00,10:10:00,3,0,0
                T2,XN,11:00:00,11:00:00,1,0,0
                T2,YN,11:04:00,11:04:00,2,0,0
                T2,ZN,11:10:00,11:10:00,3,0,0
                T3,XN,20:00:00,20:00:00,1,0,0
                T3,ZN,20:05:00,20:05:00,2,0,0
                T4,WN,11:50:00,11:50:00,1,1,0
                T4,XN,12:00:00,12:00:00,2,0,0
                T4,YN,12:03:00,12:03:00,3,0,0
                T4,XS,12:06:00,12:06:00,4,0,0
                T4,YN,12:09:00,12:09:00,5,0,0
                """,
        ]
    }

    @Test func oneSeatTableFromATimetable() throws {
        let scratch = try ScratchDirectory()
        let subway = try TransitFixture.compile(.subway, Self.railFeed(), scratch: scratch).timetable
        let city = try SyntheticCity.build()
        let timetables: [TransitSystem: Timetable] = [.subway: subway]
        let network = LinkNetwork.make(timetables: timetables, graph: city.graph, options: LinksOptions()).network
        let parents = RailParents.make(timetables: timetables, network: network)
        func parent(_ id: String) -> Int { network.global(.subway, id, in: timetables) }
        let x = parent("X"), y = parent("Y"), z = parent("Z"), w = parent("W")
        #expect(parents.parents == [w, x, y, z].sorted())
        #expect(parents.platforms[parents.parents.firstIndex(of: x)!] == [parent("XN"), parent("XS")].sorted())

        let table = OneSeatTable.build(timetables: timetables, network: network, parents: parents, options: HopOptions())
        // 2026-10-05 is a Monday; the first covered Tuesday is the 6th.
        #expect(table.referenceDates == [.subway: ServiceDate(year: 2026, month: 10, day: 6)])
        // Existence: every forward pair of every pattern; W only as a destination nowhere (no pickup, first stop).
        #expect(Set(table.pairs.keys) == Set([(x, y), (x, z), (y, z), (y, x)].map { OneSeatTable.key($0.0, $0.1) }))
        // Midday: T1 and T2 (and T4 X→Y, once though it rides X→Y twice).
        #expect(table.entry(from: x, to: z) == OneSeatTable.Entry(middayTrips: 2, middayMinInVehicleSeconds: 600, dayMinInVehicleSeconds: 300))
        #expect(table.entry(from: x, to: y) == OneSeatTable.Entry(middayTrips: 3, middayMinInVehicleSeconds: 180, dayMinInVehicleSeconds: 180))
        #expect(table.entry(from: y, to: x) == OneSeatTable.Entry(middayTrips: 1, middayMinInVehicleSeconds: 180, dayMinInVehicleSeconds: 180))
        #expect(table.entry(from: y, to: z) == OneSeatTable.Entry(middayTrips: 2, middayMinInVehicleSeconds: 360, dayMinInVehicleSeconds: 360))
        #expect(table.entry(from: z, to: x) == nil && table.entry(from: w, to: x) == nil)

        // A narrower window keeps only T1.
        var options = HopOptions()
        options.middayStartSeconds = 9 * 3600
        options.middayEndSeconds = 10 * 3600 + 1
        let narrow = OneSeatTable.build(timetables: timetables, network: network, parents: parents, options: options)
        #expect(narrow.entry(from: x, to: z)?.middayTrips == 1 && narrow.entry(from: y, to: z)?.middayTrips == 0)

        // Holidays are skipped: the Wednesday, then (all of Tue–Thu off) the Monday, then (every
        // weekday off) the first covered date.
        func day(_ d: Int) -> ServiceDate { ServiceDate(year: 2026, month: 10, day: d) }
        #expect(OneSeatTable.referenceDate(subway, excluding: [day(6)]) == day(7))
        #expect(OneSeatTable.referenceDate(subway, excluding: [day(6), day(7), day(8)]) == day(5))
        #expect(OneSeatTable.referenceDate(subway, excluding: Set((5...9).map(day))) == day(5))
        var holiday = HopOptions()
        holiday.holidays = [day(6)]
        #expect(OneSeatTable.build(timetables: timetables, network: network, parents: parents, options: holiday).referenceDates == [.subway: day(7)])
    }

    // MARK: - Reader

    /// The fixture's links with hand-set hops. Parents in the fixture: S1…S4 (subway), L1, L2
    /// (LIRR); stations 0…4.
    struct HopFile {
        let fixture: LinksFixture
        let s1: Int, s3: Int, s4: Int, l1: Int, bus: Int

        init() throws {
            fixture = try LinksFixture()
            let timetables = fixture.world.timetables
            s1 = fixture.network.global(.subway, "S1", in: timetables)
            s3 = fixture.network.global(.subway, "S3", in: timetables)
            s4 = fixture.network.global(.subway, "S4", in: timetables)
            l1 = fixture.network.global(.lirr, "L1", in: timetables)
            bus = fixture.network.global(.bus, "B1", in: timetables)
        }

        static let parameters = LinkHopParameters(minRideSeconds: 300, maxRideSeconds: 1500, minSpeedMmPerSecond: 3040, maxSpeedMmPerSecond: 5141,
                                                  rankSpeedMmPerSecond: 4470, unlockSeconds: 90, dockSeconds: 60, pickupsPerHop: 2, docksPerHop: 2)

        func hop(_ origin: Int, _ target: Int, pickups: [Int] = [0, 1], docks: [Int] = [2], flags: LinkHopFlags = []) -> CompiledHop {
            CompiledHop(origin: origin, target: target, pickups: pickups, docks: docks, minDecameters: 120, minWalkSeconds: 300,
                        flags: flags, bestDecameters: 120, bikeSeconds: 0, droppedByDayMinimum: false)
        }

        var hops: [CompiledHop] { [hop(s1, s3), hop(s1, s4, pickups: [1], flags: .oneSeatRideExists), hop(l1, s1, docks: [3, 4])] }

        func file(_ hops: CompiledHops) -> Data {
            var links = fixture.compiled
            links.hops = hops
            return fixture.artifact(links)
        }

        func file(_ hops: [CompiledHop]) -> Data { file(CompiledHops(parameters: Self.parameters, stops: fixture.network.stopCount, hops: hops)) }
    }

    func open(_ file: Data, validate: Bool = true) throws -> MappedLinks {
        try MappedLinks(artifact: MappedArtifact(fileBytes: file, expecting: .links), validate: validate)
    }

    @Test func readsHopsBack() throws {
        let f = try HopFile()
        let links = try open(f.file(f.hops))
        let hops = try #require(links.hops)
        #expect(hops.parameters == HopFile.parameters && hops.count == 3 && links.extensions.ids == [LinksFormat.hopsExtensionID])
        let fromS1 = hops.hops(fromParent: f.s1)
        #expect(fromS1.map(\.target) == [f.s3, f.s4].sorted() && fromS1.map(\.row) == [0, 1])
        let toS3 = try #require(fromS1.first { $0.target == f.s3 }), toS4 = try #require(fromS1.first { $0.target == f.s4 })
        #expect(toS3.pickups == [0, 1] && toS3.docks == [2] && Array(toS3.dockSlots) == [2, LinksFormat.noStation] && toS3.flags == [])
        #expect(toS4.pickups == [1] && toS4.flags == .oneSeatRideExists)
        #expect(toS3.minDecameters == 120 && toS3.minWalkSeconds == 300)
        #expect(hops.hops(fromParent: f.l1).map(\.docks) == [[3, 4]] && hops.hops(fromParent: f.s3).isEmpty)
        // No hops: no block, and the fixed part is unchanged.
        let plain = try open(f.fixture.artifact())
        #expect(plain.hops == nil && plain.extensions == .empty)
        let empty = try open(f.file([]))
        #expect(empty.hops?.count == 0 && empty.hops?.hops(fromParent: f.s1).isEmpty == true)
        let (_, withHops) = try ArtifactHeader.decode(from: f.file(f.hops))
        let (_, without) = try ArtifactHeader.decode(from: f.fixture.artifact())
        #expect(withHops.prefix(without.count - 4) == without.prefix(without.count - 4))
    }

    @Test func opensAHopBlockOverNoStops() throws {
        // Links built with stations but no timetable: no stops, and an empty hop block.
        let network = LinkNetwork(systemStopCounts: [0, 0, 0, 0, 0], routable: [], stopAccess: [], accessPoints: [], transfers: [])
        let empty = HopBuilder.Inputs(systemStopCounts: [0, 0, 0, 0, 0], parents: RailParents(parents: [], platforms: []), pickups: [], docks: [],
                                      stationCount: 2, distances: DenseHopDistances(count: 2, values: [0, 7, 7, 0]), oneSeat: OneSeatTable())
        let (hops, stats) = HopBuilder.build(empty, options: HopOptions(), threads: 4)
        #expect(hops.start == [0] && hops.count == 0 && stats.hops == 0 && stats.candidatePairs == 0)
        let links = CompiledLinks(network: network, footpaths: FootpathTable(start: [0], target: [], seconds: []),
                                  stationLinks: .empty(stops: 0, stations: 2), stationCount: 2, options: LinksOptions(), hops: hops)
        let file = LinksArtifactWriter.artifact(links, dataVersion: "empty", builtAgainst: ["stations": "s"])
        let opened = try open(file)
        #expect(opened.stopCount == 0 && opened.stationCount == 2 && opened.hops?.count == 0)
    }

    @Test func ignoresUndefinedHopFlagBits() throws {
        let f = try HopFile()
        var hops = f.hops
        hops[0].flags = LinkHopFlags(rawValue: 0xFE)
        let links = try open(f.file(hops))
        #expect(links.hops?.hop(0).flags == [] && links.hops?.hopFlags[0] == 0xFE)
    }

    /// Expects the invariant `rule`, and a structurally sound file (it opens with `validate: false`).
    func expectViolation(_ rule: String, _ file: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try open(file)
            Issue.record("expected \(rule)", sourceLocation: sourceLocation)
        } catch let LinksFormatError.invariantViolated(found, _) {
            #expect(found == rule, sourceLocation: sourceLocation)
        } catch {
            Issue.record("expected \(rule), got \(error)", sourceLocation: sourceLocation)
        }
        #expect(throws: Never.self, sourceLocation: sourceLocation) { try open(file, validate: false) }
    }

    @Test func rejectsEveryHopInvariant() throws {
        let f = try HopFile()
        expectViolation("hopFromNonRailStop", f.file([f.hop(f.bus, f.s1)]))
        expectViolation("hopToNonRailStop", f.file([f.hop(f.s1, f.bus)]))
        expectViolation("hopToItself", f.file([f.hop(f.s1, f.s1)]))
        expectViolation("hopPickupsRepeat", f.file([f.hop(f.s1, f.s3, pickups: [1, 1])]))
        expectViolation("hopDocksRepeat", f.file([f.hop(f.s1, f.s3, docks: [4, 4])]))

        // Rules CompiledHops can't express, set in the arrays.
        func mutated(_ change: (inout CompiledHops) -> Void) -> Data {
            var hops = CompiledHops(parameters: HopFile.parameters, stops: f.fixture.network.stopCount, hops: f.hops)
            change(&hops)
            return f.file(hops)
        }
        expectViolation("hopRowOrder", mutated { $0.target.swapAt(0, 1) })
        expectViolation("hopPickupsEmpty", mutated { $0.pickups[0] = LinksFormat.noStation; $0.pickups[1] = LinksFormat.noStation })
        // Three slots, the middle one unused: [0, -, 1].
        var three = HopFile.parameters
        three.pickupsPerHop = 3
        var gap = CompiledHops(parameters: three, stops: f.fixture.network.stopCount, hops: f.hops)
        gap.pickups.swapAt(1, 2)
        expectViolation("hopPickupsPaddingNotTrailing", f.file(gap))
        // The same for docks, on row 2 (L1 → S1, docks 3 and 4): [3, -, 4].
        var threeDocks = HopFile.parameters
        threeDocks.docksPerHop = 3
        var dockGap = CompiledHops(parameters: threeDocks, stops: f.fixture.network.stopCount, hops: f.hops)
        #expect(Array(dockGap.docks[6..<9]) == [3, 4, LinksFormat.noStation])
        dockGap.docks.swapAt(7, 8)
        expectViolation("hopDocksPaddingNotTrailing", f.file(dockGap))
        expectViolation("hopDocksEmpty", mutated { $0.docks[0] = LinksFormat.noStation })
        expectViolation("hopWithoutBound", mutated { $0.minDecameters[2] = 0xFFFF })
        expectViolation("hopWithoutBound", mutated { $0.minWalkSeconds[1] = LinksFormat.noSeconds })
    }

    @Test func rejectsABrokenHopBlockEvenWithoutValidation() throws {
        let f = try HopFile()
        let file = f.file(f.hops)
        let (header, payload) = try ArtifactHeader.decode(from: file)
        let fixed = Data(payload).prefix(LinksPayloadLayout(Data(payload)).tail)
        let block = LinksArtifactWriter.hopBlock(CompiledHops(parameters: HopFile.parameters, stops: f.fixture.network.stopCount, hops: f.hops),
                                                 stopCount: f.fixture.network.stopCount, stationCount: f.fixture.stations.count)
        func open(block: [UInt8]) throws -> MappedLinks {
            var writer = BinaryWriter()
            writer.append(bytes: fixed)
            writer.appendExtensions([(id: LinksFormat.hopsExtensionID, bytes: block)])
            return try MappedLinks(artifact: MappedArtifact(fileBytes: header.assemble(payload: writer.data), expecting: .links), validate: false)
        }
        _ = try open(block: block)
        #expect(throws: LinksFormatError.trailingBytes(3)) { try open(block: block + [0, 0, 0]) }
        #expect(throws: (any Error).self) { try open(block: Array(block.dropLast(1))) }
        // Parameters: kP = 0 (the 8th u32), then a minimum above its maximum.
        func withParameter(_ index: Int, _ value: UInt32) -> [UInt8] {
            var copy = block
            withUnsafeBytes(of: value.littleEndian) { copy.replaceSubrange(index * 4..<index * 4 + 4, with: $0) }
            return copy
        }
        #expect(throws: LinksFormatError.valueOutOfRange(section: "hopParameters", index: 0)) { try open(block: withParameter(7, 0)) }
        #expect(throws: LinksFormatError.valueOutOfRange(section: "hopParameters", index: 0)) { try open(block: withParameter(0, 1501)) }
        // Station and stop indices out of range.
        var badStation = CompiledHops(parameters: HopFile.parameters, stops: f.fixture.network.stopCount, hops: f.hops)
        badStation.pickups[0] = UInt16(f.fixture.stations.count)
        let unchecked = { (hops: CompiledHops) -> [UInt8] in
            // The writer refuses out-of-range stations, so assemble the block by hand.
            var writer = BinaryWriter()
            for value in hops.parameters.stored { writer.append(value) }
            writer.append(array: hops.start)
            writer.append(array: hops.target)
            writer.append(array: hops.pickups)
            writer.append(array: hops.docks)
            writer.append(array: hops.minDecameters)
            writer.append(array: hops.minWalkSeconds)
            writer.append(array: hops.flags)
            return Array(writer.data)
        }
        #expect(unchecked(CompiledHops(parameters: HopFile.parameters, stops: f.fixture.network.stopCount, hops: f.hops)) == block)
        #expect(throws: LinksFormatError.valueOutOfRange(section: "hopPickup", index: 0)) { try open(block: unchecked(badStation)) }
        var badTarget = CompiledHops(parameters: HopFile.parameters, stops: f.fixture.network.stopCount, hops: f.hops)
        badTarget.target[2] = UInt32(f.fixture.network.stopCount)
        #expect(throws: LinksFormatError.valueOutOfRange(section: "hopTarget", index: 2)) { try open(block: unchecked(badTarget)) }
        var badStart = CompiledHops(parameters: HopFile.parameters, stops: f.fixture.network.stopCount, hops: f.hops)
        badStart.start[f.s1 + 1] = 3
        #expect(throws: LinksFormatError.notMonotonic(section: "hopStart", index: f.s1 + 2)) { try open(block: unchecked(badStart)) }
    }
}
