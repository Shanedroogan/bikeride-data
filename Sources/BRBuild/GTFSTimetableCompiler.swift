import BRCore
import BRGeo
import BRTimetable
import Foundation

public struct GTFSCompileOptions: Sendable {
    /// First service date kept: normally the day before the build day, so that day view D−1
    /// exists for early-morning queries. Earlier dates and trips that only run on them are dropped.
    public var windowStart: ServiceDate
    /// Upper bound on the window length, against feeds with far-future end dates.
    public var maxDays: Int
    /// Douglas–Peucker tolerance for shapes, in meters.
    public var shapeToleranceMeters: Double
    /// When a pattern's stops match vertices of its shape and some stop's vertex lies farther than
    /// this from it, the reversed polyline is tried as well and the closer match kept (PANYNJ uses
    /// one `shape_id` for both directions of a line).
    public var shapeReverseMeters: Double
    /// A pattern whose better match still leaves a stop farther than this from its vertex gets a
    /// line synthesized through its stops instead: the stored guarantee for GTFS shapes. Both
    /// limits are great-circle meters (`Coordinate.distance`).
    public var shapeMaxStopMeters: Double
    /// Parent stations and platform transfers synthesized for PATH (only used for `.path`).
    public var pathStations: PATHStationOptions

    public init(windowStart: ServiceDate, maxDays: Int = 800, shapeToleranceMeters: Double = 5,
                shapeReverseMeters: Double = 100, shapeMaxStopMeters: Double = 250,
                pathStations: PATHStationOptions = PATHStationOptions()) {
        self.windowStart = windowStart
        self.maxDays = maxDays
        self.shapeToleranceMeters = shapeToleranceMeters
        self.shapeReverseMeters = shapeReverseMeters
        self.shapeMaxStopMeters = shapeMaxStopMeters
        self.pathStations = pathStations
    }
}

/// Counts from one system's compile, for the build report.
public struct GTFSSystemStats: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public var name: String
        public var slot: String
        public var priority: Int
        public var etag: String
        public var feedVersion: String
        public var publishedAt: String
        public var coverageFirst: String?
        public var coverageLast: String?
        public var datesSelected: Int
        public var firstSelected: String?
        public var lastSelected: String?
        public var tripsInFeed: Int
        public var stopTimeRows: Int
        public var tripsKept: Int
        public var frequencyRows: Int
        public var issues: [String: Int]
        /// `cached` when the feed's download failed and it was built from its last good archived
        /// copy (``TimetableBuild``); nil for a feed built from its current zip.
        public var status: String?
        /// For a `cached` feed: when its copy was first archived (ISO 8601) and its archive key.
        public var archivedAt: String?
        public var archiveKey: String?
    }

    public struct Coverage: Codable, Sendable {
        public var first: String?
        public var last: String?
        public var days: Int
        /// Every covered date, `YYYYMMDD`.
        public var dates: [String]
    }

    public var system: String
    public var timeZone: String
    public var windowStart: String
    public var dayCount: Int
    public var sources: [Source] = []
    public var coverage = Coverage(first: nil, last: nil, days: 0, dates: [])
    public var agencies = 0
    public var routes = 0
    public var routesByMode: [String: Int] = [:]
    public var stops = 0
    public var parentStations = 0
    public var stopIDsInSeveralFeeds = 0
    public var stopCoordinatesFromLaterFeed = 0
    /// Subway entrances added as `.entrance` stops, and those whose station is not in the feed.
    public var entrances = 0
    public var entrancesUnmatched = 0
    public var serviceRules = 0
    public var serviceRulesDropped = 0
    public var trips = 0
    /// Trips with ``BRTimetable/TripFlags/peak`` (LIRR `peak_offpeak` = 1).
    public var tripsPeak = 0
    public var tripsDroppedInactive = 0
    public var tripsDroppedTooShort = 0
    public var tripsDroppedMissingEndTimes = 0
    public var passThroughStopsDropped = 0
    public var passThroughEventsDropped = 0
    public var timesInterpolated = 0
    public var timesRepaired = 0
    /// Trips whose clock restarted at midnight (times after it written as 0:xx), unwrapped.
    public var tripsUnwrappedPastMidnight = 0
    public var patternsBeforeFIFO = 0
    public var patternsAfterFIFO = 0
    public var patternsArrivalEqualsDeparture = 0
    public var storedStopEvents = 0
    public var storedArrivals = 0
    public var shapes = 0
    public var shapePointsInput = 0
    public var shapePointsKept = 0
    public var patternsWithBorrowedShape = 0
    /// Patterns matched to their shape's reversed polyline, and the reversed shape rows stored.
    public var patternsWithReversedShape = 0
    public var shapesReversed = 0
    /// Every pattern given a line through its stops, including ``patternsWithShapeTooFar``.
    public var patternsWithSynthesizedShape = 0
    /// Patterns whose GTFS shape left a stop more than `shapeMaxStopMeters` from its vertex both
    /// ways, so they got a line through their stops.
    public var patternsWithShapeTooFar = 0
    /// The largest distance from a pattern's stop to its shape vertex (the regression guard for
    /// route lines; 0 for synthesized shapes), and where it occurs.
    public var maxStopToShapeVertexMeters = 0.0
    public var maxStopToShapeVertexAt: String?
    public var transfers = 0
    public var guaranteedTripTransfers = 0
    public var transfersDropped = 0
    public var subwayKeys = 0
    public var subwayKeyParseFailures = 0
    public var duplicateTripIDs = 0
    /// PATH only: what was synthesized per source, keyed by source name.
    public var pathStations: [String: PATHStationSynthesis]?
}

/// Compiles the GTFS feeds of one system into a ``BRTimetable/TimetableData``.
///
/// The steps, in order: per-date source selection (exactly one version per slot and date, never
/// merging versions, never extending calendars); service rules clipped to the dates their source
/// is selected; stops merged by bare `stop_id`, coordinates from the feed with the most
/// `stop_times` at the stop; pass-through stops (every call `pickup_type` = `drop_off_type` = 1)
/// dropped; times interpolated and made monotone; route patterns keyed by route, stops and
/// pickup/drop-off bits, split so that FIFO holds among trips that share a service day; shapes
/// matched to the stops (reversed where one shape serves both directions) and simplified; transfers and real-time match tables. For the subway, `entrances` become
/// `.entrance` stops under their GTFS station. For PATH, parent stations and platform transfers
/// are first synthesized (``GTFSFeed/synthesizePATHStations(_:)``).
public enum GTFSTimetableCompiler {
    public static func compile(
        system: TransitSystem,
        feeds unorderedFeeds: [GTFSFeed],
        entrances: [SubwayEntrance] = [],
        options: GTFSCompileOptions
    ) throws -> (data: TimetableData, stats: GTFSSystemStats) {
        // Preference order within each slot; slots keep their order of first appearance.
        var slotOrder: [String] = []
        for feed in unorderedFeeds where !slotOrder.contains(feed.source.slot) { slotOrder.append(feed.source.slot) }
        var feeds = unorderedFeeds.enumerated().sorted { a, b in
            let slotA = slotOrder.firstIndex(of: a.element.source.slot)!, slotB = slotOrder.firstIndex(of: b.element.source.slot)!
            if slotA != slotB { return slotA < slotB }
            if a.element.source.priority != b.element.source.priority { return a.element.source.priority < b.element.source.priority }
            if a.element.source.publishedAt != b.element.source.publishedAt { return a.element.source.publishedAt > b.element.source.publishedAt }
            return a.offset < b.offset
        }.map(\.element)

        // PATH ships no parent stations and no transfers.txt; synthesize both before anything
        // reads stops or transfers.
        var pathStations: [String: PATHStationSynthesis]?
        if system == .path {
            var synthesized: [String: PATHStationSynthesis] = [:]
            for index in feeds.indices {
                synthesized[feeds[index].source.name] = try feeds[index].synthesizePATHStations(options.pathStations)
            }
            pathStations = synthesized
        }

        // MARK: Window and source selection
        let windowStartDay = Int32(options.windowStart.daysSinceEpoch)
        let lastDay = feeds.compactMap { $0.coverageDays()?.last }.max() ?? windowStartDay - 1
        let dayCount = max(0, min(options.maxDays, Int(lastDay) - Int(windowStartDay) + 1))
        let timeZone = try Self.timeZone(of: feeds)
        var stats = GTFSSystemStats(system: system.rawValue, timeZone: timeZone,
                                    windowStart: options.windowStart.yyyymmdd, dayCount: dayCount)
        stats.pathStations = pathStations

        var feedCoverage: [DayBitset] = []
        for feed in feeds {
            var bits = DayBitset(dayCount: dayCount)
            for service in feed.services {
                if service.hasCalendar {
                    let from = max(Int(service.startDay - windowStartDay), 0)
                    let to = min(Int(service.endDay - windowStartDay), dayCount - 1)
                    if from <= to { for day in from...to { bits[day] = true } }
                }
                for exception in service.exceptions where exception.type == 1 {
                    let day = Int(exception.day - windowStartDay)
                    if day >= 0, day < dayCount { bits[day] = true }
                }
            }
            feedCoverage.append(bits)
        }
        var selected = [DayBitset](repeating: DayBitset(dayCount: dayCount), count: feeds.count)
        var slotCoverage: [DayBitset] = []
        for slot in slotOrder {
            let members = feeds.indices.filter { feeds[$0].source.slot == slot }
            var covered = DayBitset(dayCount: dayCount)
            for day in 0..<dayCount {
                if let feed = members.first(where: { feedCoverage[$0][day] }) {
                    selected[feed][day] = true
                    covered[day] = true
                }
            }
            slotCoverage.append(covered)
        }

        // MARK: Service rules
        var ruleOf: [[Int32]] = []            // [feed][service] → rule or -1
        var ruleFeed: [Int] = [], ruleService: [Int] = [], ruleBits: [DayBitset] = []
        for (feedIndex, feed) in feeds.enumerated() {
            var map = [Int32](repeating: -1, count: feed.services.count)
            for (serviceIndex, service) in feed.services.enumerated() {
                var bits = DayBitset(dayCount: dayCount)
                let exceptionDays = service.exceptions.map(\.day), exceptionTypes = service.exceptions.map(\.type)
                for day in 0..<dayCount where selected[feedIndex][day] {
                    let epochDay = windowStartDay + Int32(day)
                    if ServiceCalendar.ruleRuns(weekdays: service.weekdays, startDay: service.startDay, endDay: service.endDay,
                                                exceptionDays: exceptionDays, exceptionTypes: exceptionTypes, day: epochDay) {
                        bits[day] = true
                    }
                }
                if bits.isEmpty {
                    stats.serviceRulesDropped += 1
                    continue
                }
                map[serviceIndex] = Int32(ruleBits.count)
                ruleFeed.append(feedIndex)
                ruleService.append(serviceIndex)
                ruleBits.append(bits)
            }
            ruleOf.append(map)
        }

        // MARK: Stops merged by bare stop_id
        var mergedIDs = ByteInterner(capacity: feeds.reduce(0) { $0 + $1.stops.count })
        var mergedBest: [(feed: Int, stop: Int, count: UInt32)] = []
        var mergedFeedCount: [UInt8] = []
        var mergedOf: [[UInt32]] = []          // [feed][local stop] → merged
        for (feedIndex, feed) in feeds.enumerated() {
            var map = [UInt32](repeating: 0, count: feed.stops.count)
            for (local, stop) in feed.stops.enumerated() {
                let before = mergedIDs.count
                let merged = mergedIDs.intern(stop.id)
                map[local] = merged
                let count = feed.stopEventCount[local]
                if Int(merged) == before {
                    mergedBest.append((feedIndex, local, count))
                    mergedFeedCount.append(1)
                } else {
                    mergedFeedCount[Int(merged)] &+= 1
                    if count > mergedBest[Int(merged)].count {
                        mergedBest[Int(merged)] = (feedIndex, local, count)
                    }
                }
            }
            mergedOf.append(map)
        }
        let mergedCount = mergedIDs.count
        stats.stopIDsInSeveralFeeds = mergedFeedCount.filter { $0 > 1 }.count
        stats.stopCoordinatesFromLaterFeed = (0..<mergedCount).filter { merged in
            mergedFeedCount[merged] > 1 && mergedBest[merged].feed != (0..<feeds.count).first { feeds[$0].stopIDs.lookup(mergedIDs.bytes(UInt32(merged))) != nil }
        }.count

        // MARK: Kept trips and pass-through stops
        var keptFeed: [Int32] = [], keptLocal: [Int32] = [], keptRule: [Int32] = []
        for (feedIndex, feed) in feeds.enumerated() {
            for trip in 0..<feed.tripCount {
                let rule = ruleOf[feedIndex][Int(feed.tripService[trip])]
                if rule < 0 {
                    stats.tripsDroppedInactive += 1
                    continue
                }
                keptFeed.append(Int32(feedIndex))
                keptLocal.append(Int32(trip))
                keptRule.append(rule)
            }
        }
        var referenced = [Bool](repeating: false, count: mergedCount)
        var served = [Bool](repeating: false, count: mergedCount)
        for kept in keptFeed.indices {
            let feed = feeds[Int(keptFeed[kept])], map = mergedOf[Int(keptFeed[kept])]
            let trip = Int(keptLocal[kept])
            for event in feed.events(ofTrip: trip) {
                let merged = Int(map[Int(feed.eventStop[event])])
                referenced[merged] = true
                let flags = feed.eventPickupDropOff[event]
                if flags & 0x0F != 1 || flags >> 4 != 1 { served[merged] = true }
            }
        }
        let passThrough = (0..<mergedCount).map { referenced[$0] && !served[$0] }
        stats.passThroughStopsDropped = passThrough.filter { $0 }.count

        // MARK: Trip events: drop pass-through calls, fill and repair times
        var tripEventStart: [UInt32] = [0]
        var tripStops: [UInt32] = [], tripFlags: [UInt8] = [], tripArrival: [UInt32] = [], tripDeparture: [UInt32] = []
        var tripSource: [Int32] = []          // index into keptFeed
        let none = TimetableFormat.none
        let keptEvents = keptFeed.indices.reduce(0) { $0 + Int(feeds[Int(keptFeed[$1])].eventCount[Int(keptLocal[$1])]) }
        tripStops.reserveCapacity(keptEvents)
        tripFlags.reserveCapacity(keptEvents)
        tripArrival.reserveCapacity(keptEvents)
        tripDeparture.reserveCapacity(keptEvents)
        tripEventStart.reserveCapacity(keptFeed.count + 1)
        tripSource.reserveCapacity(keptFeed.count)
        for kept in keptFeed.indices {
            let feed = feeds[Int(keptFeed[kept])], map = mergedOf[Int(keptFeed[kept])]
            let trip = Int(keptLocal[kept])
            let begin = tripStops.count
            for event in feed.events(ofTrip: trip) {
                let merged = map[Int(feed.eventStop[event])]
                if passThrough[Int(merged)] {
                    stats.passThroughEventsDropped += 1
                    continue
                }
                let raw = feed.eventPickupDropOff[event]
                var flags: StopEventFlags = []
                if raw & 0x0F != 1 { flags.insert(.pickup) }
                if raw >> 4 != 1 { flags.insert(.dropOff) }
                tripStops.append(merged)
                tripFlags.append(flags.rawValue)
                tripArrival.append(feed.eventArrival[event])
                tripDeparture.append(feed.eventDeparture[event])
            }
            let count = tripStops.count - begin
            func discard(_ reason: WritableKeyPath<GTFSSystemStats, Int>) {
                stats[keyPath: reason] += 1
                tripStops.removeSubrange(begin...)
                tripFlags.removeSubrange(begin...)
                tripArrival.removeSubrange(begin...)
                tripDeparture.removeSubrange(begin...)
            }
            guard count >= 2 else {
                discard(\.tripsDroppedTooShort)
                continue
            }
            guard tripDeparture[begin] != none, tripArrival[tripStops.count - 1] != none else {
                discard(\.tripsDroppedMissingEndTimes)
                continue
            }
            // Feeds that restart the clock at midnight instead of writing 24:00+ (PATH: 23:59:42
            // then 0:01:42) are unwrapped: a time more than 12 h before the previous one is taken
            // to be on the next day, so the trip stays on the service day it started on.
            var unwrapOffset: UInt32 = 0, lastTime: UInt32? = nil
            for index in begin..<tripStops.count {
                for isDeparture in [false, true] {
                    let raw = isDeparture ? tripDeparture[index] : tripArrival[index]
                    guard raw != none else { continue }
                    var value = raw + unwrapOffset
                    if let lastTime, value + 43_200 < lastTime {
                        unwrapOffset += 86_400
                        value += 86_400
                    }
                    if isDeparture { tripDeparture[index] = value } else { tripArrival[index] = value }
                    lastTime = value
                }
            }
            if unwrapOffset > 0 { stats.tripsUnwrappedPastMidnight += 1 }
            // Linear interpolation by position over calls without times.
            var index = begin + 1
            while index < tripStops.count {
                if tripArrival[index] == none {
                    var next = index
                    while tripArrival[next] == none { next += 1 }
                    let from = tripDeparture[index - 1], to = tripArrival[next]
                    let span = next - (index - 1)
                    for missing in index..<next {
                        let fraction = Double(missing - (index - 1)) / Double(span)
                        let value = UInt32(Double(from) + (Double(to) - Double(from)) * fraction)
                        tripArrival[missing] = value
                        tripDeparture[missing] = value
                        stats.timesInterpolated += 1
                    }
                    index = next
                }
                index += 1
            }
            // Monotone: departure ≥ arrival at a stop, arrival ≥ previous departure.
            for index in begin..<tripStops.count {
                if index > begin, tripArrival[index] < tripDeparture[index - 1] {
                    tripArrival[index] = tripDeparture[index - 1]
                    stats.timesRepaired += 1
                }
                if tripDeparture[index] < tripArrival[index] {
                    tripDeparture[index] = tripArrival[index]
                    stats.timesRepaired += 1
                }
            }
            tripEventStart.append(UInt32(tripStops.count))
            tripSource.append(Int32(kept))
        }
        let tripCount = tripSource.count

        // MARK: Routes and agencies
        var agencyKeys: [String] = []
        var agencyIndex: [String: Int] = [:]
        var agencyRecords: [GTFSFeed.Agency] = []
        var routeKeys: [String: Int] = [:]
        var routeRecords: [GTFSFeed.Route] = []
        var tripRoute = [UInt32](repeating: 0, count: tripCount)
        for trip in 0..<tripCount {
            let kept = Int(tripSource[trip])
            let feed = feeds[Int(keptFeed[kept])]
            let route = feed.routes[Int(feed.tripRoute[Int(keptLocal[kept])])]
            let key = route.agencyID + "\u{1F}" + route.id
            if let existing = routeKeys[key] {
                tripRoute[trip] = UInt32(existing)
                continue
            }
            if agencyIndex[route.agencyID] == nil {
                agencyIndex[route.agencyID] = agencyKeys.count
                agencyKeys.append(route.agencyID)
                let agency = feed.agencies.first { $0.id == route.agencyID } ?? feed.agencies.first
                    ?? GTFSFeed.Agency(id: route.agencyID, name: "", timezone: timeZone)
                agencyRecords.append(GTFSFeed.Agency(id: route.agencyID, name: agency.name, timezone: agency.timezone))
            }
            routeKeys[key] = routeRecords.count
            tripRoute[trip] = UInt32(routeRecords.count)
            routeRecords.append(route)
        }

        // MARK: Patterns and FIFO
        // Keyed by (slot, route, stops with pickup/drop-off bits). The slot keeps trips of different
        // feeds apart, so every pattern's trips on one date (extrapolated days included, which copy
        // a reference day of one slot) come from one real service day, on which FIFO is enforced.
        let slotNumber = Dictionary(uniqueKeysWithValues: slotOrder.enumerated().map { ($1, UInt32($0)) })
        let feedSlot = feeds.map { slotNumber[$0.source.slot]! }
        var baseKeys: [[UInt32]: Int] = [:]
        var baseTrips: [[Int]] = []
        for trip in 0..<tripCount {
            let range = Int(tripEventStart[trip])..<Int(tripEventStart[trip + 1])
            var key: [UInt32] = [feedSlot[Int(keptFeed[Int(tripSource[trip])])], tripRoute[trip]]
            key.reserveCapacity(2 + range.count)
            for event in range { key.append(tripStops[event] << 2 | UInt32(tripFlags[event])) }
            if let base = baseKeys[key] {
                baseTrips[base].append(trip)
            } else {
                baseKeys[key] = baseTrips.count
                baseTrips.append([trip])
            }
        }
        stats.patternsBeforeFIFO = baseTrips.count

        var classIndex: [DayBitset: Int] = [:]
        var ruleClass = [Int](repeating: 0, count: ruleBits.count)
        var classBits: [DayBitset] = []
        for (rule, bits) in ruleBits.enumerated() {
            if let existing = classIndex[bits] {
                ruleClass[rule] = existing
            } else {
                classIndex[bits] = classBits.count
                ruleClass[rule] = classBits.count
                classBits.append(bits)
            }
        }

        struct FinalPattern {
            var base: Int
            var trips: [Int]
        }
        var finalPatterns: [FinalPattern] = []
        for (base, members) in baseTrips.enumerated() {
            let stopCount = Int(tripEventStart[members[0] + 1] - tripEventStart[members[0]])
            let sorted = members.sorted { a, b in
                let ea = Int(tripEventStart[a]), eb = Int(tripEventStart[b])
                if tripDeparture[ea] != tripDeparture[eb] { return tripDeparture[ea] < tripDeparture[eb] }
                for offset in 1..<stopCount {
                    if tripArrival[ea + offset] != tripArrival[eb + offset] { return tripArrival[ea + offset] < tripArrival[eb + offset] }
                    if tripDeparture[ea + offset] != tripDeparture[eb + offset] {
                        return tripDeparture[ea + offset] < tripDeparture[eb + offset]
                    }
                }
                return a < b
            }
            func dominates(_ later: Int, _ earlier: Int) -> Bool {
                let el = Int(tripEventStart[later]), ee = Int(tripEventStart[earlier])
                for offset in 0..<stopCount {
                    if tripArrival[el + offset] < tripArrival[ee + offset] || tripDeparture[el + offset] < tripDeparture[ee + offset] {
                        return false
                    }
                }
                return true
            }
            // Co-activity between the few service classes of this pattern.
            var coactive: [Int: Bool] = [:]
            func sharesDays(_ a: Int, _ b: Int) -> Bool {
                if a == b { return true }
                let key = min(a, b) << 32 | max(a, b)
                if let known = coactive[key] { return known }
                let value = classBits[a].intersects(classBits[b])
                coactive[key] = value
                return value
            }
            // Greedy first fit: the last trip of each class in a sub-pattern dominates every
            // earlier trip of that class, so checking it suffices.
            var subs: [(trips: [Int], lastOfClass: [Int: Int])] = []
            for trip in sorted {
                let tripClass = ruleClass[Int(keptRule[Int(tripSource[trip])])]
                var placed = false
                for index in subs.indices {
                    let fits = subs[index].lastOfClass.allSatisfy { cls, last in
                        !sharesDays(cls, tripClass) || dominates(trip, last)
                    }
                    if fits {
                        subs[index].trips.append(trip)
                        subs[index].lastOfClass[tripClass] = trip
                        placed = true
                        break
                    }
                }
                if !placed { subs.append(([trip], [tripClass: trip])) }
            }
            for sub in subs { finalPatterns.append(FinalPattern(base: base, trips: sub.trips)) }
        }
        stats.patternsAfterFIFO = finalPatterns.count

        // MARK: Stops kept (called stops and their parents), in merged order
        var keepStop = [Bool](repeating: false, count: mergedCount)
        for stop in tripStops { keepStop[Int(stop)] = true }
        var mergedParent = [Int32](repeating: -1, count: mergedCount)
        for merged in 0..<mergedCount {
            let best = mergedBest[merged]
            let parentID = feeds[best.feed].stops[best.stop].parentID
            if !parentID.isEmpty, let parent = mergedIDs.lookup(parentID), Int(parent) != merged {
                mergedParent[merged] = Int32(parent)
            }
        }
        for merged in 0..<mergedCount where keepStop[merged] {
            var current = mergedParent[merged]
            var guardCount = 0
            while current >= 0, guardCount < 8 {
                keepStop[Int(current)] = true
                current = mergedParent[Int(current)]
                guardCount += 1
            }
        }
        var finalStop = [UInt32](repeating: none, count: mergedCount)
        var stopOrder: [Int] = []
        for merged in 0..<mergedCount where keepStop[merged] {
            finalStop[merged] = UInt32(stopOrder.count)
            stopOrder.append(merged)
        }

        // MARK: Assemble
        var data = TimetableData(system: system, windowStart: options.windowStart, dayCount: dayCount, timeZoneIdentifier: timeZone)
        for (feedIndex, feed) in feeds.enumerated() {
            data.sourceName.append(data.strings.intern(feed.source.name))
            data.sourceVersion.append(data.strings.intern(feed.feedVersion))
            data.sourceETag.append(data.strings.intern(feed.source.etag))
            data.sourceSlot.append(slotNumber[feed.source.slot]!)
            data.sourceSelectedDays.append(selected[feedIndex])
        }
        for agency in agencyRecords {
            data.agencyGTFSID.append(data.strings.intern(agency.id))
            data.agencyName.append(data.strings.intern(agency.name))
            data.agencyTimezone.append(data.strings.intern(agency.timezone))
        }
        for route in routeRecords {
            let mode = Self.mode(system: system, routeID: route.id)
            stats.routesByMode["\(mode)", default: 0] += 1
            data.routeAgency.append(UInt32(agencyIndex[route.agencyID]!))
            data.routeGTFSID.append(data.strings.intern(route.id))
            data.routeShortName.append(data.strings.intern(route.shortName))
            data.routeLongName.append(data.strings.intern(Self.longName(system: system, route: route)))
            data.routeColor.append(route.color ?? none)
            data.routeTextColor.append(route.textColor ?? none)
            data.routeMode.append(mode.rawValue)
            data.routeType.append(UInt16(clamping: route.type))
        }
        for merged in stopOrder {
            let best = mergedBest[merged]
            let stop = feeds[best.feed].stops[best.stop]
            data.stopGTFSID.append(data.strings.intern(stop.id))
            data.stopName.append(data.strings.intern(stop.name))
            data.stopCode.append(data.strings.intern(stop.code))
            data.stopLatE6.append(stop.latE6)
            data.stopLonE6.append(stop.lonE6)
            let parent = mergedParent[merged]
            data.stopParent.append(parent >= 0 ? finalStop[Int(parent)] : none)
            data.stopKind.append(stop.locationType)
            data.stopAccess.append(StopAccess([.entry, .exit]).rawValue)
            data.stopEntranceType.append(0)
            if stop.locationType == StopKind.station.rawValue { stats.parentStations += 1 }
        }
        Self.addEntrances(entrances, to: &data, stationOf: { id in
            guard let merged = mergedIDs.lookup(id) else { return nil }
            let final = finalStop[Int(merged)]
            return final == none ? nil : Int(final)
        }, isTaken: { mergedIDs.lookup($0) != nil }, stats: &stats)
        for rule in ruleBits.indices {
            let service = feeds[ruleFeed[rule]].services[ruleService[rule]]
            data.ruleGTFSID.append(data.strings.intern(service.id))
            data.ruleSource.append(UInt32(ruleFeed[rule]))
            data.ruleWeekdays.append(service.weekdays)
            data.ruleStartDay.append(service.hasCalendar ? service.startDay : 0)
            data.ruleEndDay.append(service.hasCalendar ? service.endDay : 0)
            for exception in service.exceptions {
                data.exceptionDay.append(exception.day)
                data.exceptionType.append(exception.type)
            }
            data.ruleExceptionStart.append(UInt32(data.exceptionDay.count))
        }

        // Patterns, trips and times.
        var finalTripOf = [UInt32](repeating: none, count: tripCount)
        for (patternIndex, pattern) in finalPatterns.enumerated() {
            let first = pattern.trips[0]
            let range = Int(tripEventStart[first])..<Int(tripEventStart[first + 1])
            let stopCount = range.count
            data.patternRoute.append(tripRoute[first])
            for event in range {
                data.patternStopIndex.append(finalStop[Int(tripStops[event])])
                data.patternStopFlags.append(tripFlags[event])
            }
            data.patternStopStart.append(UInt32(data.patternStopIndex.count))
            var sameTimes = true
            data.patternDepartureStart.append(UInt32(data.departures.count))
            for trip in pattern.trips {
                let start = Int(tripEventStart[trip])
                for offset in 0..<stopCount {
                    data.departures.append(tripDeparture[start + offset])
                    if tripArrival[start + offset] != tripDeparture[start + offset] { sameTimes = false }
                }
            }
            if sameTimes {
                data.patternArrivalStart.append(none)
                stats.patternsArrivalEqualsDeparture += 1
            } else {
                data.patternArrivalStart.append(UInt32(data.arrivals.count))
                for trip in pattern.trips {
                    let start = Int(tripEventStart[trip])
                    data.arrivals.append(contentsOf: tripArrival[start..<start + stopCount])
                }
            }
            data.patternFlags.append(sameTimes ? PatternFlags.arrivalEqualsDeparture.rawValue : 0)
            data.patternBaseKey.append(UInt32(pattern.base))
            for trip in pattern.trips {
                finalTripOf[trip] = UInt32(data.tripPattern.count)
                let kept = Int(tripSource[trip])
                let feed = feeds[Int(keptFeed[kept])]
                let local = Int(keptLocal[kept])
                data.tripPattern.append(UInt32(patternIndex))
                data.tripRule.append(UInt32(keptRule[kept]))
                data.tripGTFSID.append(data.strings.intern(feed.tripIDs.bytes(UInt32(local))))
                data.tripHeadsign.append(data.strings.intern(feed.texts.bytes(feed.tripHeadsign[local])))
                data.tripShortName.append(data.strings.intern(feed.texts.bytes(feed.tripShortName[local])))
                data.tripDirection.append(feed.tripDirection[local])
                data.tripFlags.append(feed.tripFlags[local])
            }
            data.patternTripStart.append(UInt32(data.tripPattern.count))
        }
        stats.trips = data.tripPattern.count
        stats.tripsPeak = data.tripFlags.filter { $0 & TripFlags.peak.rawValue != 0 }.count
        stats.storedStopEvents = data.departures.count
        stats.storedArrivals = data.arrivals.count

        // Shapes.
        Self.addShapes(to: &data, patterns: finalPatterns.map { ($0.base, $0.trips) }, feeds: feeds,
                       tripSource: tripSource, keptFeed: keptFeed, keptLocal: keptLocal,
                       options: options, stats: &stats)
        (stats.maxStopToShapeVertexMeters, stats.maxStopToShapeVertexAt) = Self.maxStopToShapeVertex(data)

        // Transfers.
        struct TransferRow: Hashable {
            var fromTrip: UInt32, toTrip: UInt32, fromStop: UInt32, toStop: UInt32, type: UInt8, minSeconds: UInt32
        }
        var keptTripOf: [[Int32]] = feeds.map { [Int32](repeating: -1, count: $0.tripCount) }
        for trip in 0..<tripCount {
            let kept = Int(tripSource[trip])
            keptTripOf[Int(keptFeed[kept])][Int(keptLocal[kept])] = Int32(finalTripOf[trip])
        }
        var rows = Set<TransferRow>()
        for (feedIndex, feed) in feeds.enumerated() where !selected[feedIndex].isEmpty {
            for transfer in feed.transfers {
                func stop(_ id: String) -> UInt32? {
                    guard let local = feed.stopIDs.lookup(id) else { return nil }
                    let final = finalStop[Int(mergedOf[feedIndex][Int(local)])]
                    return final == none ? nil : final
                }
                /// The final trip index, `none` for an empty id, or `nil` for a trip that was dropped.
                func trip(_ id: String) -> UInt32? {
                    if id.isEmpty { return TimetableFormat.none }
                    guard let local = feed.tripIDs.lookup(id) else { return nil }
                    let final = keptTripOf[feedIndex][Int(local)]
                    return final < 0 ? nil : UInt32(final)
                }
                // GTFS defines transfer_type 0–5; the format stores no other value.
                guard (0...5).contains(transfer.type),
                      let from = stop(transfer.fromStop), let to = stop(transfer.toStop),
                      let fromTrip = trip(transfer.fromTrip), let toTrip = trip(transfer.toTrip)
                else {
                    stats.transfersDropped += 1
                    continue
                }
                rows.insert(TransferRow(fromTrip: fromTrip, toTrip: toTrip, fromStop: from, toStop: to,
                                        type: UInt8(transfer.type),
                                        minSeconds: transfer.minTransferSeconds.map { UInt32(clamping: $0) } ?? none))
            }
        }
        let sortedRows = rows.sorted {
            ($0.fromTrip, $0.toTrip, $0.fromStop, $0.toStop, $0.type, $0.minSeconds)
                < ($1.fromTrip, $1.toTrip, $1.fromStop, $1.toStop, $1.type, $1.minSeconds)
        }
        for row in sortedRows {
            data.transferFromStop.append(row.fromStop)
            data.transferToStop.append(row.toStop)
            data.transferFromTrip.append(row.fromTrip)
            data.transferToTrip.append(row.toTrip)
            data.transferType.append(row.type)
            data.transferMinSeconds.append(row.minSeconds)
            if row.type == 1 && row.fromTrip != none && row.toTrip != none { stats.guaranteedTripTransfers += 1 }
        }
        stats.transfers = sortedRows.count

        // Real-time keys (subway) and id indexes.
        if system == .subway {
            var keys: [(route: UInt32, direction: UInt8, origin: Int32, path: UInt32, trip: UInt32)] = []
            for trip in 0..<data.tripCount {
                guard let key = SubwayTripKey(staticTripID: data.strings.bytes(data.tripGTFSID[trip])) else {
                    stats.subwayKeyParseFailures += 1
                    continue
                }
                keys.append((data.strings.intern(key.route), key.direction, key.originHundredths,
                             data.strings.intern(key.path), UInt32(trip)))
            }
            let strings = data.strings
            keys.sort { a, b in
                if a.route != b.route {
                    let order = strings.bytes(a.route).lexicographicallyPrecedes(strings.bytes(b.route))
                    if order { return true }
                    if strings.bytes(b.route).lexicographicallyPrecedes(strings.bytes(a.route)) { return false }
                }
                if a.direction != b.direction { return a.direction < b.direction }
                if a.origin != b.origin { return a.origin < b.origin }
                if a.path != b.path {
                    if strings.bytes(a.path).lexicographicallyPrecedes(strings.bytes(b.path)) { return true }
                    if strings.bytes(b.path).lexicographicallyPrecedes(strings.bytes(a.path)) { return false }
                }
                return a.trip < b.trip
            }
            for key in keys {
                data.subwayKeyRoute.append(key.route)
                data.subwayKeyDirection.append(key.direction)
                data.subwayKeyOrigin.append(key.origin)
                data.subwayKeyPath.append(key.path)
                data.subwayKeyTrip.append(key.trip)
            }
            stats.subwayKeys = keys.count
        }
        data.rebuildIndexes()
        var previous: UInt32? = nil
        for trip in data.tripIDOrder {
            let id = data.tripGTFSID[Int(trip)]
            if let previous, previous == id { stats.duplicateTripIDs += 1 }
            previous = id
        }

        // Stats.
        stats.agencies = data.agencyGTFSID.count
        stats.routes = data.routeGTFSID.count
        stats.stops = data.stopCount
        stats.serviceRules = data.ruleGTFSID.count
        let coveredDays = ServiceCalendar.completeCoverage(slotCoverage: slotCoverage, dayCount: dayCount).days
        stats.coverage = GTFSSystemStats.Coverage(
            first: coveredDays.first.map { options.windowStart.adding(days: $0).yyyymmdd },
            last: coveredDays.last.map { options.windowStart.adding(days: $0).yyyymmdd },
            days: coveredDays.count,
            dates: coveredDays.map { options.windowStart.adding(days: $0).yyyymmdd }
        )
        for (feedIndex, feed) in feeds.enumerated() {
            let days = selected[feedIndex].days
            let range = feed.coverageDays()
            stats.sources.append(GTFSSystemStats.Source(
                name: feed.source.name, slot: feed.source.slot, priority: feed.source.priority, etag: feed.source.etag,
                feedVersion: feed.feedVersion, publishedAt: feed.source.publishedAt,
                coverageFirst: range.map { ServiceDate(daysSinceEpoch: Int($0.first)).yyyymmdd },
                coverageLast: range.map { ServiceDate(daysSinceEpoch: Int($0.last)).yyyymmdd },
                datesSelected: days.count,
                firstSelected: days.first.map { options.windowStart.adding(days: $0).yyyymmdd },
                lastSelected: days.last.map { options.windowStart.adding(days: $0).yyyymmdd },
                tripsInFeed: feed.tripCount, stopTimeRows: feed.stopTimeRows,
                tripsKept: (0..<tripCount).filter { keptFeed[Int(tripSource[$0])] == Int32(feedIndex) }.count,
                frequencyRows: feed.frequencyRows, issues: feed.issues
            ))
        }
        return (data, stats)
    }

    /// The one IANA zone all agencies share (`agency_timezone`; LIRR's `feed_timezone` is invalid
    /// and ignored).
    static func timeZone(of feeds: [GTFSFeed]) throws -> String {
        var zones: [String] = []
        for feed in feeds {
            let feedZones = feed.agencies.map(\.timezone).filter { !$0.isEmpty }
            guard !feedZones.isEmpty else { throw GTFSError.noTimeZone(feed: feed.source.name) }
            for zone in feedZones where !zones.contains(zone) { zones.append(zone) }
        }
        guard zones.count <= 1 else { throw GTFSError.mixedTimeZones(zones) }
        return zones.first ?? "America/New_York"
    }

    /// Route presentation class. SBS routes end with `+`; express buses start with X, BM, BxM,
    /// QM or SIM (case-insensitive).
    public static func mode(system: TransitSystem, routeID: String) -> RouteMode {
        switch system {
        case .subway: return .subway
        case .lirr: return .lirr
        case .ferry: return .ferry
        case .path: return .path
        case .bus:
            if routeID.hasSuffix("+") { return .sbs }
            let upper = routeID.uppercased()
            for prefix in ["BXM", "SIM", "BM", "QM", "X"] where upper.hasPrefix(prefix) { return .expressBus }
            return .localBus
        }
    }

    /// The route's long name. PANYNJ writes codes such as `JSQ_HOB_33` in `route_long_name` and
    /// the readable name in `route_desc`, so PATH takes `route_desc` when it has one.
    static func longName(system: TransitSystem, route: GTFSFeed.Route) -> String {
        system == .path && !route.desc.isEmpty ? route.desc : route.longName
    }

    // MARK: - Entrances

    /// Appends one `.entrance` stop per entrance whose station is a kept stop. Ids are
    /// `<station>-E<n>`, numbered per station in (lat, lon, type) order so equal inputs give
    /// equal ids.
    static func addEntrances(
        _ entrances: [SubwayEntrance], to data: inout TimetableData,
        stationOf: (String) -> Int?, isTaken: (String) -> Bool, stats: inout GTFSSystemStats
    ) {
        var byStation: [Int: [SubwayEntrance]] = [:]
        for entrance in entrances {
            guard let station = stationOf(entrance.stationGTFSID) else {
                stats.entrancesUnmatched += 1
                continue
            }
            byStation[station, default: []].append(entrance)
        }
        for station in byStation.keys.sorted() {
            let sorted = byStation[station]!.sorted {
                ($0.latE6, $0.lonE6, $0.entranceType, $0.entryAllowed ? 1 : 0, $0.exitAllowed ? 1 : 0)
                    < ($1.latE6, $1.lonE6, $1.entranceType, $1.entryAllowed ? 1 : 0, $1.exitAllowed ? 1 : 0)
            }
            var number = 0
            for entrance in sorted {
                number += 1
                let id = "\(entrance.stationGTFSID)-E\(number)"
                guard !isTaken(id) else {
                    stats.entrancesUnmatched += 1
                    continue
                }
                var access: StopAccess = []
                if entrance.entryAllowed { access.insert(.entry) }
                if entrance.exitAllowed { access.insert(.exit) }
                data.stopGTFSID.append(data.strings.intern(id))
                data.stopName.append(data.stopName[station])
                data.stopCode.append(0)
                data.stopLatE6.append(entrance.latE6)
                data.stopLonE6.append(entrance.lonE6)
                data.stopParent.append(UInt32(station))
                data.stopKind.append(StopKind.entrance.rawValue)
                data.stopAccess.append(access.rawValue)
                data.stopEntranceType.append(data.strings.intern(entrance.entranceType))
                stats.entrances += 1
            }
        }
    }

    // MARK: - Shapes

    private static func addShapes(
        to data: inout TimetableData, patterns: [(base: Int, trips: [Int])], feeds: [GTFSFeed],
        tripSource: [Int32], keptFeed: [Int32], keptLocal: [Int32], options: GTFSCompileOptions,
        stats: inout GTFSSystemStats
    ) {
        let none = TimetableFormat.none
        // Choose each pattern's GTFS shape: the most common among its trips (ties: first seen).
        struct ShapeKey: Hashable { var feed: Int32; var shape: Int32 }
        var chosen: [ShapeKey?] = []
        for pattern in patterns {
            var counts: [ShapeKey: Int] = [:]
            var order: [ShapeKey] = []
            for trip in pattern.trips {
                let kept = Int(tripSource[trip])
                let feed = Int(keptFeed[kept])
                let shape = feeds[feed].tripShape[Int(keptLocal[kept])]
                guard shape >= 0 else { continue }
                let points = feeds[feed].shapePointStart[Int(shape) + 1] - feeds[feed].shapePointStart[Int(shape)]
                guard points >= 2 else { continue }
                let key = ShapeKey(feed: Int32(feed), shape: shape)
                if counts[key] == nil { order.append(key) }
                counts[key, default: 0] += 1
            }
            chosen.append(order.max { counts[$0]! < counts[$1]! || (counts[$0]! == counts[$1]! && order.firstIndex(of: $0)! > order.firstIndex(of: $1)!) })
        }

        // A pattern without a usable shape borrows one from a pattern of the same route whose
        // stops include its stops in order (e.g. supplemented subway trips with no shape_id).
        var shaped: [UInt32: [Int]] = [:]
        for (pattern, key) in chosen.enumerated() where key != nil {
            shaped[data.patternRoute[pattern], default: []].append(pattern)
        }
        func stops(_ pattern: Int) -> ArraySlice<UInt32> {
            data.patternStopIndex[Int(data.patternStopStart[pattern])..<Int(data.patternStopStart[pattern + 1])]
        }
        func isSubsequence(_ small: ArraySlice<UInt32>, of large: ArraySlice<UInt32>) -> Bool {
            var index = small.startIndex
            for stop in large where index < small.endIndex && stop == small[index] { index += 1 }
            return index == small.endIndex
        }
        for pattern in chosen.indices where chosen[pattern] == nil {
            let own = stops(pattern)
            let candidates = (shaped[data.patternRoute[pattern]] ?? []).filter { isSubsequence(own, of: stops($0)) }
            // The tightest fit: fewest extra stops, then first.
            if let donor = candidates.min(by: { stops($0).count < stops($1).count }) {
                chosen[pattern] = chosen[donor]
                stats.patternsWithBorrowedShape += 1
            }
        }

        // Stop coordinates of each pattern, in the local plane.
        func stopPoints(_ pattern: Int) -> [PlanarPoint] {
            let range = Int(data.patternStopStart[pattern])..<Int(data.patternStopStart[pattern + 1])
            return range.map { slot in
                let stop = Int(data.patternStopIndex[slot])
                return ShapeGeometry.planar(latE6: data.stopLatE6[stop], lonE6: data.stopLonE6[stop])
            }
        }

        data.patternShape = [UInt32](repeating: none, count: patterns.count)
        data.patternStopShapeVertex = [UInt32](repeating: none, count: data.patternStopIndex.count)

        // Match each pattern's stops to vertices of its shape: forward, and reversed too when a
        // stop lands farther than shapeReverseMeters from its vertex (PANYNJ draws both
        // directions of a line with one shape_id, so the forward scan pins every stop toward New
        // Jersey to the last vertex). The closer match wins; a pattern whose better match still
        // leaves a stop beyond shapeMaxStopMeters gets a line through its stops below.
        struct ShapeUse: Hashable { var key: ShapeKey; var reversed: Bool }
        var lines: [ShapeKey: [PlanarPoint]] = [:]
        func planarLine(_ key: ShapeKey) -> [PlanarPoint] {
            if let cached = lines[key] { return cached }
            let feed = feeds[Int(key.feed)]
            let range = Int(feed.shapePointStart[Int(key.shape)])..<Int(feed.shapePointStart[Int(key.shape) + 1])
            let points = range.map { ShapeGeometry.planar(latE6: feed.shapeLatE6[$0], lonE6: feed.shapeLonE6[$0]) }
            lines[key] = points
            return points
        }
        func coordinate(_ latE6: Int32, _ lonE6: Int32) -> Coordinate {
            Coordinate(lat: Double(latE6) / 1e6, lon: Double(lonE6) / 1e6)
        }
        var uses = [ShapeUse?](repeating: nil, count: patterns.count)
        var matches = [[Int]](repeating: [], count: patterns.count)
        for (pattern, key) in chosen.enumerated() {
            guard let key else { continue }
            let points = stopPoints(pattern)
            let forward = planarLine(key)
            // The farthest stop from its vertex in great-circle meters, the metric of the report
            // and formats.md; the planar points only drive the nearest-vertex search.
            let feed = feeds[Int(key.feed)], first = Int(feed.shapePointStart[Int(key.shape)])
            let stopCoordinates = data.patternStopIndex[Int(data.patternStopStart[pattern])..<Int(data.patternStopStart[pattern + 1])]
                .map { coordinate(data.stopLatE6[Int($0)], data.stopLonE6[Int($0)]) }
            func worst(_ vertices: [Int], reversed: Bool) -> Double {
                zip(stopCoordinates, vertices).reduce(0) { farthest, match in
                    let point = first + (reversed ? forward.count - 1 - match.1 : match.1)
                    return max(farthest, match.0.distance(to: coordinate(feed.shapeLatE6[point], feed.shapeLonE6[point])))
                }
            }
            var vertices = ShapeGeometry.stopVertices(stops: points, line: forward)
            var distance = worst(vertices, reversed: false)
            var reversed = false
            if distance > options.shapeReverseMeters {
                let backward = Array(forward.reversed())
                let backwardVertices = ShapeGeometry.stopVertices(stops: points, line: backward)
                let backwardDistance = worst(backwardVertices, reversed: true)
                if backwardDistance < distance {
                    (vertices, distance, reversed) = (backwardVertices, backwardDistance, true)
                }
            }
            guard distance <= options.shapeMaxStopMeters else {
                chosen[pattern] = nil
                stats.patternsWithShapeTooFar += 1
                continue
            }
            uses[pattern] = ShapeUse(key: key, reversed: reversed)
            matches[pattern] = vertices
            if reversed { stats.patternsWithReversedShape += 1 }
        }

        // One shape row per (GTFS shape, direction) in use, each simplified once while keeping
        // every vertex some stop maps to. A reversed row stores the points last to first.
        var users: [ShapeUse: [Int]] = [:]
        var shapeOrder: [ShapeUse] = []
        for (pattern, use) in uses.enumerated() {
            guard let use else { continue }
            if users[use] == nil { shapeOrder.append(use) }
            users[use, default: []].append(pattern)
        }
        for use in shapeOrder {
            let feed = feeds[Int(use.key.feed)]
            let range = Int(feed.shapePointStart[Int(use.key.shape)])..<Int(feed.shapePointStart[Int(use.key.shape) + 1])
            let line = use.reversed ? Array(planarLine(use.key).reversed()) : planarLine(use.key)
            var keep = [Bool](repeating: false, count: line.count)
            for pattern in users[use]! {
                for vertex in matches[pattern] { keep[vertex] = true }
            }
            let kept = ShapeGeometry.simplify(line, keep: keep, tolerance: options.shapeToleranceMeters)
            var newIndex = [UInt32](repeating: none, count: line.count)
            for (index, vertex) in kept.enumerated() { newIndex[vertex] = UInt32(index) }
            let shapeIndex = UInt32(data.shapeGTFSID.count)
            data.shapeGTFSID.append(data.strings.intern(feed.shapeIDs.bytes(UInt32(use.key.shape))))
            for vertex in kept {
                let point = range.lowerBound + (use.reversed ? line.count - 1 - vertex : vertex)
                data.shapeLatE6.append(feed.shapeLatE6[point])
                data.shapeLonE6.append(feed.shapeLonE6[point])
            }
            data.shapePointStart.append(UInt32(data.shapeLatE6.count))
            stats.shapePointsInput += line.count
            stats.shapePointsKept += kept.count
            if use.reversed { stats.shapesReversed += 1 }
            for pattern in users[use]! {
                data.patternShape[pattern] = shapeIndex
                let start = Int(data.patternStopStart[pattern])
                for (position, vertex) in matches[pattern].enumerated() {
                    data.patternStopShapeVertex[start + position] = newIndex[vertex]
                }
            }
        }

        // Patterns without a usable shape get a polyline through their stops, one per base key.
        var synthesized: [Int: UInt32] = [:]
        for (pattern, key) in chosen.enumerated() where key == nil {
            let base = patterns[pattern].base
            let shapeIndex: UInt32
            if let existing = synthesized[base] {
                shapeIndex = existing
            } else {
                shapeIndex = UInt32(data.shapeGTFSID.count)
                synthesized[base] = shapeIndex
                data.shapeGTFSID.append(0)
                for slot in Int(data.patternStopStart[pattern])..<Int(data.patternStopStart[pattern + 1]) {
                    let stop = Int(data.patternStopIndex[slot])
                    data.shapeLatE6.append(data.stopLatE6[stop])
                    data.shapeLonE6.append(data.stopLonE6[stop])
                }
                data.shapePointStart.append(UInt32(data.shapeLatE6.count))
            }
            data.patternShape[pattern] = shapeIndex
            data.patternFlags[pattern] |= PatternFlags.synthesizedShape.rawValue
            let start = Int(data.patternStopStart[pattern])
            for position in 0..<(Int(data.patternStopStart[pattern + 1]) - start) {
                data.patternStopShapeVertex[start + position] = UInt32(position)
            }
            stats.patternsWithSynthesizedShape += 1
        }
        stats.shapes = data.shapeGTFSID.count
    }

    /// The largest distance from a pattern's stop to its stored shape vertex, in meters (rounded
    /// to 0.1), and the route and stop where it occurs.
    static func maxStopToShapeVertex(_ data: TimetableData) -> (meters: Double, at: String?) {
        var worst = 0.0
        var at: (pattern: Int, stop: Int)?
        for pattern in 0..<data.patternCount where data.patternShape[pattern] != TimetableFormat.none {
            let first = Int(data.shapePointStart[Int(data.patternShape[pattern])])
            for slot in Int(data.patternStopStart[pattern])..<Int(data.patternStopStart[pattern + 1]) {
                let vertex = data.patternStopShapeVertex[slot]
                guard vertex != TimetableFormat.none else { continue }
                let stop = Int(data.patternStopIndex[slot]), point = first + Int(vertex)
                let distance = Coordinate(lat: Double(data.stopLatE6[stop]) / 1e6, lon: Double(data.stopLonE6[stop]) / 1e6)
                    .distance(to: Coordinate(lat: Double(data.shapeLatE6[point]) / 1e6, lon: Double(data.shapeLonE6[point]) / 1e6))
                if distance > worst { (worst, at) = (distance, (pattern, stop)) }
            }
        }
        return ((worst * 10).rounded() / 10, at.map { at in
            "route \(data.strings.string(data.routeGTFSID[Int(data.patternRoute[at.pattern])])), stop \(data.strings.string(data.stopGTFSID[at.stop]))"
        })
    }
}
