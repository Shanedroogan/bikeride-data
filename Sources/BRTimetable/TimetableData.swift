import BRCore
import BRData
import Foundation

/// A timetable in memory, as the compiler produces it and the writer serializes it.
///
/// Every array corresponds one-to-one to a ``TimetableSection``; see `docs/formats.md` for the
/// meaning of each. String fields hold ids into ``strings``, whose id 0 is always the empty
/// string. Use ``validate()`` (called by ``encodedPayload()``) to check cross-references.
public struct TimetableData: Sendable {
    public var system: TransitSystem
    public var windowStart: ServiceDate
    public var dayCount: Int
    public var timeZoneIdentifier: String
    public var strings = ByteInterner()

    public var sourceName: [UInt32] = []
    public var sourceVersion: [UInt32] = []
    public var sourceETag: [UInt32] = []
    public var sourceSlot: [UInt32] = []
    /// One bitset per source, `DayBitset.wordCount(forDays: dayCount)` words each.
    public var sourceSelectedDays: [DayBitset] = []

    public var agencyGTFSID: [UInt32] = []
    public var agencyName: [UInt32] = []
    public var agencyTimezone: [UInt32] = []

    public var routeAgency: [UInt32] = []
    public var routeGTFSID: [UInt32] = []
    public var routeShortName: [UInt32] = []
    public var routeLongName: [UInt32] = []
    public var routeColor: [UInt32] = []
    public var routeTextColor: [UInt32] = []
    public var routeMode: [UInt8] = []
    public var routeType: [UInt16] = []

    public var stopGTFSID: [UInt32] = []
    public var stopName: [UInt32] = []
    public var stopCode: [UInt32] = []
    public var stopLatE6: [Int32] = []
    public var stopLonE6: [Int32] = []
    public var stopParent: [UInt32] = []
    public var stopKind: [UInt8] = []
    /// ``StopAccess`` raw values.
    public var stopAccess: [UInt8] = []
    public var stopEntranceType: [UInt32] = []

    public var ruleGTFSID: [UInt32] = []
    public var ruleSource: [UInt32] = []
    public var ruleWeekdays: [UInt8] = []
    public var ruleStartDay: [Int32] = []
    public var ruleEndDay: [Int32] = []
    public var ruleExceptionStart: [UInt32] = [0]
    public var exceptionDay: [Int32] = []
    public var exceptionType: [UInt8] = []

    public var patternRoute: [UInt32] = []
    public var patternStopStart: [UInt32] = [0]
    public var patternTripStart: [UInt32] = [0]
    public var patternFlags: [UInt8] = []
    public var patternDepartureStart: [UInt32] = []
    public var patternArrivalStart: [UInt32] = []
    public var patternShape: [UInt32] = []
    public var patternBaseKey: [UInt32] = []
    public var patternStopIndex: [UInt32] = []
    public var patternStopFlags: [UInt8] = []
    public var patternStopShapeVertex: [UInt32] = []

    public var departures: [UInt32] = []
    public var arrivals: [UInt32] = []

    public var tripPattern: [UInt32] = []
    public var tripRule: [UInt32] = []
    public var tripGTFSID: [UInt32] = []
    public var tripHeadsign: [UInt32] = []
    public var tripShortName: [UInt32] = []
    public var tripDirection: [UInt8] = []

    public var stopPatternStart: [UInt32] = [0]
    public var stopPatternRef: [UInt32] = []
    public var stopPatternPosition: [UInt32] = []

    public var transferFromStop: [UInt32] = []
    public var transferToStop: [UInt32] = []
    public var transferFromTrip: [UInt32] = []
    public var transferToTrip: [UInt32] = []
    public var transferType: [UInt8] = []
    public var transferMinSeconds: [UInt32] = []

    public var shapeGTFSID: [UInt32] = []
    public var shapePointStart: [UInt32] = [0]
    public var shapeLatE6: [Int32] = []
    public var shapeLonE6: [Int32] = []

    public var subwayKeyRoute: [UInt32] = []
    public var subwayKeyDirection: [UInt8] = []
    public var subwayKeyOrigin: [Int32] = []
    public var subwayKeyPath: [UInt32] = []
    public var subwayKeyTrip: [UInt32] = []
    public var tripIDOrder: [UInt32] = []
    public var stopIDOrder: [UInt32] = []

    public init(system: TransitSystem, windowStart: ServiceDate, dayCount: Int, timeZoneIdentifier: String) {
        self.system = system
        self.windowStart = windowStart
        self.dayCount = dayCount
        self.timeZoneIdentifier = timeZoneIdentifier
        strings.intern("")
    }

    public var stopCount: Int { stopGTFSID.count }
    public var patternCount: Int { patternRoute.count }
    public var tripCount: Int { tripPattern.count }

    // MARK: - Derived indexes

    /// Rebuilds ``stopPatternStart``/``stopPatternRef``/``stopPatternPosition`` from the patterns,
    /// and ``tripIDOrder``/``stopIDOrder`` from the id strings.
    public mutating func rebuildIndexes() {
        var counts = [UInt32](repeating: 0, count: stopCount + 1)
        for stop in patternStopIndex { counts[Int(stop) + 1] += 1 }
        for index in 1..<counts.count { counts[index] += counts[index - 1] }
        stopPatternStart = counts
        var cursor = counts
        stopPatternRef = [UInt32](repeating: 0, count: patternStopIndex.count)
        stopPatternPosition = [UInt32](repeating: 0, count: patternStopIndex.count)
        for pattern in 0..<patternCount {
            let start = Int(patternStopStart[pattern]), end = Int(patternStopStart[pattern + 1])
            for slot in start..<end {
                let stop = Int(patternStopIndex[slot])
                let at = Int(cursor[stop])
                stopPatternRef[at] = UInt32(pattern)
                stopPatternPosition[at] = UInt32(slot - start)
                cursor[stop] += 1
            }
        }
        tripIDOrder = sortedByString(tripGTFSID)
        stopIDOrder = sortedByString(stopGTFSID)
    }

    /// Indices of `ids` ordered by the bytes of the strings they name, ties by index.
    private func sortedByString(_ ids: [UInt32]) -> [UInt32] {
        let strings = self.strings
        return strings.arena.withUnsafeBufferPointer { arena in
            func bytes(_ id: UInt32) -> UnsafeBufferPointer<UInt8> {
                let start = Int(strings.starts[Int(id)]), end = Int(strings.starts[Int(id) + 1])
                return UnsafeBufferPointer(rebasing: arena[start..<end])
            }
            return (0..<UInt32(ids.count)).sorted { a, b in
                let order = compareBytes(bytes(ids[Int(a)]), bytes(ids[Int(b)]))
                return order != 0 ? order < 0 : a < b
            }
        }
    }

    // MARK: - Validation

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case inconsistent(String)

        public var description: String {
            switch self {
            case .inconsistent(let message): "timetable is inconsistent: \(message)"
            }
        }
    }

    /// Checks array lengths and every cross-reference. The reader repeats these checks on
    /// untrusted bytes; running them before writing catches compiler bugs early.
    public func validate() throws {
        func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            if !condition { throw ValidationError.inconsistent(message()) }
        }
        let stringCount = UInt32(self.strings.count)
        func checkStrings(_ ids: [UInt32], _ name: String) throws {
            try check(ids.allSatisfy { $0 < stringCount }, "\(name) names a missing string")
        }
        func indexes(_ ids: [UInt32], below bound: Int, allowNone: Bool = false, _ name: String) throws {
            try check(ids.allSatisfy { ($0 == TimetableFormat.none && allowNone) || Int($0) < bound },
                      "\(name) is out of range")
        }
        func offsets(_ values: [UInt32], count: Int, total: Int, _ name: String) throws {
            try check(values.count == count + 1, "\(name) has \(values.count) entries, expected \(count + 1)")
            try check(values.first == 0 && Int(values.last ?? 0) == total, "\(name) does not span its target")
            try check(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "\(name) is not monotone")
        }

        try check(dayCount >= 0, "negative dayCount")
        let sources = sourceName.count
        try check([sourceVersion.count, sourceETag.count, sourceSlot.count, sourceSelectedDays.count].allSatisfy { $0 == sources },
                  "source arrays differ in length")
        try check(sourceSelectedDays.allSatisfy { $0.dayCount == dayCount }, "source bitset length")
        try checkStrings(sourceName + sourceVersion + sourceETag, "source")

        let agencies = agencyGTFSID.count
        try check(agencyName.count == agencies && agencyTimezone.count == agencies, "agency arrays differ in length")
        try checkStrings(agencyGTFSID + agencyName + agencyTimezone, "agency")

        let routes = routeGTFSID.count
        try check([routeAgency.count, routeShortName.count, routeLongName.count, routeColor.count,
                   routeTextColor.count, routeMode.count, routeType.count].allSatisfy { $0 == routes },
                  "route arrays differ in length")
        try indexes(routeAgency, below: agencies, "routeAgency")
        try checkStrings(routeGTFSID + routeShortName + routeLongName, "route")
        try check(routeMode.allSatisfy { RouteMode(rawValue: $0) != nil }, "unknown route mode")

        let stops = stopGTFSID.count
        try check([stopName.count, stopCode.count, stopLatE6.count, stopLonE6.count, stopParent.count,
                   stopKind.count, stopAccess.count, stopEntranceType.count].allSatisfy { $0 == stops },
                  "stop arrays differ in length")
        try checkStrings(stopGTFSID + stopName + stopCode + stopEntranceType, "stop")
        try indexes(stopParent, below: stops, allowNone: true, "stopParent")

        let rules = ruleGTFSID.count
        try check([ruleSource.count, ruleWeekdays.count, ruleStartDay.count, ruleEndDay.count].allSatisfy { $0 == rules },
                  "rule arrays differ in length")
        try checkStrings(ruleGTFSID, "rule")
        try indexes(ruleSource, below: sources, "ruleSource")
        try offsets(ruleExceptionStart, count: rules, total: exceptionDay.count, "ruleExceptionStart")
        try check(exceptionType.count == exceptionDay.count, "exception arrays differ in length")
        for rule in 0..<rules {
            let days = exceptionDay[Int(ruleExceptionStart[rule])..<Int(ruleExceptionStart[rule + 1])]
            try check(zip(days, days.dropFirst()).allSatisfy { $0 < $1 }, "exceptions of rule \(rule) not ascending")
        }

        let patterns = patternRoute.count
        try check([patternFlags.count, patternDepartureStart.count, patternArrivalStart.count, patternShape.count,
                   patternBaseKey.count].allSatisfy { $0 == patterns }, "pattern arrays differ in length")
        try indexes(patternRoute, below: routes, "patternRoute")
        try offsets(patternStopStart, count: patterns, total: patternStopIndex.count, "patternStopStart")
        try offsets(patternTripStart, count: patterns, total: tripPattern.count, "patternTripStart")
        try check(patternStopFlags.count == patternStopIndex.count && patternStopShapeVertex.count == patternStopIndex.count,
                  "pattern stop arrays differ in length")
        try indexes(patternStopIndex, below: stops, "patternStopIndex")
        let shapes = shapeGTFSID.count
        try indexes(patternShape, below: shapes, allowNone: true, "patternShape")
        for pattern in 0..<patterns {
            let stopCount = Int(patternStopStart[pattern + 1] - patternStopStart[pattern])
            let tripCount = Int(patternTripStart[pattern + 1] - patternTripStart[pattern])
            try check(stopCount >= 2, "pattern \(pattern) has fewer than two stops")
            let events = stopCount * tripCount
            try check(Int(patternDepartureStart[pattern]) + events <= departures.count, "pattern \(pattern) departures")
            let sameTimes = PatternFlags(rawValue: patternFlags[pattern]).contains(.arrivalEqualsDeparture)
            if sameTimes {
                try check(patternArrivalStart[pattern] == TimetableFormat.none, "pattern \(pattern) arrivals")
            } else {
                try check(Int(patternArrivalStart[pattern]) + events <= arrivals.count, "pattern \(pattern) arrivals")
            }
            for trip in Int(patternTripStart[pattern])..<Int(patternTripStart[pattern + 1]) {
                try check(tripPattern[trip] == UInt32(pattern), "trip \(trip) is outside its pattern's range")
            }
            if patternShape[pattern] != TimetableFormat.none {
                let shape = Int(patternShape[pattern])
                let points = shapePointStart[shape + 1] - shapePointStart[shape]
                for slot in Int(patternStopStart[pattern])..<Int(patternStopStart[pattern + 1]) {
                    let vertex = patternStopShapeVertex[slot]
                    try check(vertex == TimetableFormat.none || vertex < points, "pattern \(pattern) shape vertex")
                }
            }
        }

        let trips = tripPattern.count
        try check([tripRule.count, tripGTFSID.count, tripHeadsign.count, tripShortName.count,
                   tripDirection.count].allSatisfy { $0 == trips }, "trip arrays differ in length")
        try indexes(tripRule, below: rules, "tripRule")
        try checkStrings(tripGTFSID + tripHeadsign + tripShortName, "trip")

        try offsets(stopPatternStart, count: stops, total: stopPatternRef.count, "stopPatternStart")
        try check(stopPatternPosition.count == stopPatternRef.count, "stop pattern arrays differ in length")
        for (pattern, position) in zip(stopPatternRef, stopPatternPosition) {
            try check(Int(pattern) < patterns, "stopPatternRef out of range")
            try check(position < patternStopStart[Int(pattern) + 1] - patternStopStart[Int(pattern)], "stopPatternPosition out of range")
        }

        let transfers = transferFromStop.count
        try check([transferToStop.count, transferFromTrip.count, transferToTrip.count, transferType.count,
                   transferMinSeconds.count].allSatisfy { $0 == transfers }, "transfer arrays differ in length")
        try indexes(transferFromStop + transferToStop, below: stops, "transfer stop")
        try indexes(transferFromTrip + transferToTrip, below: trips, allowNone: true, "transfer trip")

        try checkStrings(shapeGTFSID, "shape")
        try offsets(shapePointStart, count: shapes, total: shapeLatE6.count, "shapePointStart")
        try check(shapeLonE6.count == shapeLatE6.count, "shape point arrays differ in length")

        let keys = subwayKeyTrip.count
        try check([subwayKeyRoute.count, subwayKeyDirection.count, subwayKeyOrigin.count, subwayKeyPath.count].allSatisfy { $0 == keys },
                  "subway key arrays differ in length")
        try indexes(subwayKeyTrip, below: trips, "subwayKeyTrip")
        try checkStrings(subwayKeyRoute + subwayKeyPath, "subway key")
        try check(tripIDOrder.count == trips && Set(tripIDOrder).count == trips, "tripIDOrder is not a permutation")
        try check(stopIDOrder.count == stops && Set(stopIDOrder).count == stops, "stopIDOrder is not a permutation")
    }

    // MARK: - Encoding

    /// The payload bytes (without the artifact header), after ``validate()``.
    public func encodedPayload() throws -> Data {
        try validate()
        let wordsPerSource = DayBitset.wordCount(forDays: dayCount)
        var info = [Int64](repeating: 0, count: InfoField.allCases.count)
        var pool = strings
        let timeZoneID = pool.intern(timeZoneIdentifier)
        info[InfoField.system.rawValue] = Int64(system.rawValue.utf8.first ?? 0)
        info[InfoField.windowStartDay.rawValue] = Int64(windowStart.daysSinceEpoch)
        info[InfoField.dayCount.rawValue] = Int64(dayCount)
        info[InfoField.timeZone.rawValue] = Int64(timeZoneID)
        info[InfoField.wordsPerSource.rawValue] = Int64(wordsPerSource)
        info[InfoField.draftRevision.rawValue] = TimetableFormat.draftRevision

        var sections = SectionWriter()
        sections.add(.info, info)
        sections.add(.stringOffsets, pool.starts)
        sections.add(.stringBytes, pool.arena)
        sections.add(.sourceName, sourceName)
        sections.add(.sourceVersion, sourceVersion)
        sections.add(.sourceETag, sourceETag)
        sections.add(.sourceSlot, sourceSlot)
        sections.add(.sourceSelectedDays, sourceSelectedDays.flatMap(\.words))
        sections.add(.agencyGTFSID, agencyGTFSID)
        sections.add(.agencyName, agencyName)
        sections.add(.agencyTimezone, agencyTimezone)
        sections.add(.routeAgency, routeAgency)
        sections.add(.routeGTFSID, routeGTFSID)
        sections.add(.routeShortName, routeShortName)
        sections.add(.routeLongName, routeLongName)
        sections.add(.routeColor, routeColor)
        sections.add(.routeTextColor, routeTextColor)
        sections.add(.routeMode, routeMode)
        sections.add(.routeType, routeType)
        sections.add(.stopGTFSID, stopGTFSID)
        sections.add(.stopName, stopName)
        sections.add(.stopCode, stopCode)
        sections.add(.stopLatE6, stopLatE6)
        sections.add(.stopLonE6, stopLonE6)
        sections.add(.stopParent, stopParent)
        sections.add(.stopKind, stopKind)
        sections.add(.stopAccess, stopAccess)
        sections.add(.stopEntranceType, stopEntranceType)
        sections.add(.ruleGTFSID, ruleGTFSID)
        sections.add(.ruleSource, ruleSource)
        sections.add(.ruleWeekdays, ruleWeekdays)
        sections.add(.ruleStartDay, ruleStartDay)
        sections.add(.ruleEndDay, ruleEndDay)
        sections.add(.ruleExceptionStart, ruleExceptionStart)
        sections.add(.exceptionDay, exceptionDay)
        sections.add(.exceptionType, exceptionType)
        sections.add(.patternRoute, patternRoute)
        sections.add(.patternStopStart, patternStopStart)
        sections.add(.patternTripStart, patternTripStart)
        sections.add(.patternFlags, patternFlags)
        sections.add(.patternDepartureStart, patternDepartureStart)
        sections.add(.patternArrivalStart, patternArrivalStart)
        sections.add(.patternShape, patternShape)
        sections.add(.patternBaseKey, patternBaseKey)
        sections.add(.patternStopIndex, patternStopIndex)
        sections.add(.patternStopFlags, patternStopFlags)
        sections.add(.patternStopShapeVertex, patternStopShapeVertex)
        sections.add(.departures, departures)
        sections.add(.arrivals, arrivals)
        sections.add(.tripPattern, tripPattern)
        sections.add(.tripRule, tripRule)
        sections.add(.tripGTFSID, tripGTFSID)
        sections.add(.tripHeadsign, tripHeadsign)
        sections.add(.tripShortName, tripShortName)
        sections.add(.tripDirection, tripDirection)
        sections.add(.stopPatternStart, stopPatternStart)
        sections.add(.stopPatternRef, stopPatternRef)
        sections.add(.stopPatternPosition, stopPatternPosition)
        sections.add(.transferFromStop, transferFromStop)
        sections.add(.transferToStop, transferToStop)
        sections.add(.transferFromTrip, transferFromTrip)
        sections.add(.transferToTrip, transferToTrip)
        sections.add(.transferType, transferType)
        sections.add(.transferMinSeconds, transferMinSeconds)
        sections.add(.shapeGTFSID, shapeGTFSID)
        sections.add(.shapePointStart, shapePointStart)
        sections.add(.shapeLatE6, shapeLatE6)
        sections.add(.shapeLonE6, shapeLonE6)
        sections.add(.subwayKeyRoute, subwayKeyRoute)
        sections.add(.subwayKeyDirection, subwayKeyDirection)
        sections.add(.subwayKeyOrigin, subwayKeyOrigin)
        sections.add(.subwayKeyPath, subwayKeyPath)
        sections.add(.subwayKeyTrip, subwayKeyTrip)
        sections.add(.tripIDOrder, tripIDOrder)
        sections.add(.stopIDOrder, stopIDOrder)
        return sections.payload()
    }

    /// A complete artifact file: header (kind from ``system``, current format version) + payload.
    public func artifactBytes(dataVersion: String, builtAgainst: [String: String] = [:]) throws -> Data {
        let kind = ArtifactKind.timetable(for: system)
        let header = ArtifactHeader(
            kind: kind,
            formatVersion: kind.currentFormatVersion,
            dataVersion: dataVersion,
            builderSwiftVersion: BuildInfo.swiftVersion,
            builtAgainst: builtAgainst
        )
        return header.assemble(payload: try encodedPayload())
    }
}

/// Lays out sections behind a table of contents, each 8-aligned.
private struct SectionWriter {
    private struct Pending {
        let section: TimetableSection
        let count: Int
        let bytes: Data
    }

    private var pending: [Pending] = []

    mutating func add<T: BinaryScalar>(_ section: TimetableSection, _ values: [T]) {
        precondition(MemoryLayout<T>.stride == section.elementSize, "element size mismatch for \(section)")
        let bytes = values.withUnsafeBufferPointer { Data(buffer: $0) }
        pending.append(Pending(section: section, count: values.count, bytes: bytes))
    }

    func payload() -> Data {
        var writer = BinaryWriter(reservingCapacity: pending.reduce(0) { $0 + $1.bytes.count + 8 } + 4096)
        writer.append(bytes: TimetableFormat.magic)
        writer.append(UInt32(pending.count))
        let tocStart = writer.count
        for _ in pending {
            writer.append(UInt32(0)); writer.append(UInt32(0)); writer.append(UInt64(0)); writer.append(UInt64(0))
        }
        for (index, item) in pending.enumerated() {
            writer.pad(toMultipleOf: 8)
            let entry = tocStart + index * TimetableFormat.tocEntrySize
            writer.overwrite(item.section.rawValue, at: entry)
            writer.overwrite(UInt32(item.section.elementSize), at: entry + 4)
            writer.overwrite(UInt64(writer.count), at: entry + 8)
            writer.overwrite(UInt64(item.count), at: entry + 16)
            writer.append(bytes: item.bytes)
        }
        writer.pad(toMultipleOf: 8)
        return writer.data
    }
}
