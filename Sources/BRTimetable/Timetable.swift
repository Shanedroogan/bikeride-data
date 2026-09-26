import BRCore
import BRData
import BRGeo
import Foundation

/// A malformed or incompatible timetable payload.
public enum TimetableFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    case notATimetable(ArtifactKind)
    case unsupportedFormatVersion(UInt16)
    case unsupportedDraftRevision(Int64)
    case badMagic
    case truncated
    case missingSection(TimetableSection)
    case duplicateSection(UInt32)
    case elementSizeMismatch(TimetableSection, found: UInt32)
    case misalignedSection(TimetableSection)
    case sectionOutOfBounds(TimetableSection)
    case unknownSystem(Int64)
    case invalidTimeZone(String)
    case inconsistent(String)

    public var description: String {
        switch self {
        case .notATimetable(let kind): "artifact \(kind.name) is not a timetable"
        case .unsupportedFormatVersion(let version): "unsupported timetable format version \(version)"
        case .unsupportedDraftRevision(let revision): "unsupported timetable draft revision \(revision)"
        case .badMagic: "timetable payload does not start with BRTT"
        case .truncated: "timetable payload is truncated"
        case .missingSection(let section): "timetable section \(section) is missing"
        case .duplicateSection(let id): "timetable section \(id) appears twice"
        case .elementSizeMismatch(let section, let size): "timetable section \(section) has element size \(size)"
        case .misalignedSection(let section): "timetable section \(section) is not 8-aligned"
        case .sectionOutOfBounds(let section): "timetable section \(section) extends past the payload"
        case .unknownSystem(let code): "unknown transit system code \(code)"
        case .invalidTimeZone(let identifier): "unknown time zone \(identifier)"
        case .inconsistent(let message): "timetable is inconsistent: \(message)"
        }
    }
}

/// Every section of a timetable, viewed in place. Pointers are valid for the lifetime of the
/// ``Timetable`` that owns them; keep it alive (e.g. `withExtendedLifetime`) while using them.
/// Semantics per field: ``TimetableSection`` and `docs/formats.md`.
public struct TimetableBuffers {
    public let info: UnsafeBufferPointer<Int64>
    public let stringOffsets: UnsafeBufferPointer<UInt32>
    public let stringBytes: UnsafeBufferPointer<UInt8>
    public let sourceName: UnsafeBufferPointer<UInt32>
    public let sourceVersion: UnsafeBufferPointer<UInt32>
    public let sourceETag: UnsafeBufferPointer<UInt32>
    public let sourceSlot: UnsafeBufferPointer<UInt32>
    public let sourceSelectedDays: UnsafeBufferPointer<UInt64>
    public let agencyGTFSID: UnsafeBufferPointer<UInt32>
    public let agencyName: UnsafeBufferPointer<UInt32>
    public let agencyTimezone: UnsafeBufferPointer<UInt32>
    public let routeAgency: UnsafeBufferPointer<UInt32>
    public let routeGTFSID: UnsafeBufferPointer<UInt32>
    public let routeShortName: UnsafeBufferPointer<UInt32>
    public let routeLongName: UnsafeBufferPointer<UInt32>
    public let routeColor: UnsafeBufferPointer<UInt32>
    public let routeTextColor: UnsafeBufferPointer<UInt32>
    public let routeMode: UnsafeBufferPointer<UInt8>
    public let routeType: UnsafeBufferPointer<UInt16>
    public let stopGTFSID: UnsafeBufferPointer<UInt32>
    public let stopName: UnsafeBufferPointer<UInt32>
    public let stopCode: UnsafeBufferPointer<UInt32>
    public let stopLatE6: UnsafeBufferPointer<Int32>
    public let stopLonE6: UnsafeBufferPointer<Int32>
    public let stopParent: UnsafeBufferPointer<UInt32>
    public let stopKind: UnsafeBufferPointer<UInt8>
    public let stopAccess: UnsafeBufferPointer<UInt8>
    public let stopEntranceType: UnsafeBufferPointer<UInt32>
    public let ruleGTFSID: UnsafeBufferPointer<UInt32>
    public let ruleSource: UnsafeBufferPointer<UInt32>
    public let ruleWeekdays: UnsafeBufferPointer<UInt8>
    public let ruleStartDay: UnsafeBufferPointer<Int32>
    public let ruleEndDay: UnsafeBufferPointer<Int32>
    public let ruleExceptionStart: UnsafeBufferPointer<UInt32>
    public let exceptionDay: UnsafeBufferPointer<Int32>
    public let exceptionType: UnsafeBufferPointer<UInt8>
    public let patternRoute: UnsafeBufferPointer<UInt32>
    public let patternStopStart: UnsafeBufferPointer<UInt32>
    public let patternTripStart: UnsafeBufferPointer<UInt32>
    public let patternFlags: UnsafeBufferPointer<UInt8>
    public let patternDepartureStart: UnsafeBufferPointer<UInt32>
    public let patternArrivalStart: UnsafeBufferPointer<UInt32>
    public let patternShape: UnsafeBufferPointer<UInt32>
    public let patternBaseKey: UnsafeBufferPointer<UInt32>
    public let patternStopIndex: UnsafeBufferPointer<UInt32>
    public let patternStopFlags: UnsafeBufferPointer<UInt8>
    public let patternStopShapeVertex: UnsafeBufferPointer<UInt32>
    public let departures: UnsafeBufferPointer<UInt32>
    public let arrivals: UnsafeBufferPointer<UInt32>
    public let tripPattern: UnsafeBufferPointer<UInt32>
    public let tripRule: UnsafeBufferPointer<UInt32>
    public let tripGTFSID: UnsafeBufferPointer<UInt32>
    public let tripHeadsign: UnsafeBufferPointer<UInt32>
    public let tripShortName: UnsafeBufferPointer<UInt32>
    public let tripDirection: UnsafeBufferPointer<UInt8>
    public let stopPatternStart: UnsafeBufferPointer<UInt32>
    public let stopPatternRef: UnsafeBufferPointer<UInt32>
    public let stopPatternPosition: UnsafeBufferPointer<UInt32>
    public let transferFromStop: UnsafeBufferPointer<UInt32>
    public let transferToStop: UnsafeBufferPointer<UInt32>
    public let transferFromTrip: UnsafeBufferPointer<UInt32>
    public let transferToTrip: UnsafeBufferPointer<UInt32>
    public let transferType: UnsafeBufferPointer<UInt8>
    public let transferMinSeconds: UnsafeBufferPointer<UInt32>
    public let shapeGTFSID: UnsafeBufferPointer<UInt32>
    public let shapePointStart: UnsafeBufferPointer<UInt32>
    public let shapeLatE6: UnsafeBufferPointer<Int32>
    public let shapeLonE6: UnsafeBufferPointer<Int32>
    public let subwayKeyRoute: UnsafeBufferPointer<UInt32>
    public let subwayKeyDirection: UnsafeBufferPointer<UInt8>
    public let subwayKeyOrigin: UnsafeBufferPointer<Int32>
    public let subwayKeyPath: UnsafeBufferPointer<UInt32>
    public let subwayKeyTrip: UnsafeBufferPointer<UInt32>
    public let tripIDOrder: UnsafeBufferPointer<UInt32>
    public let stopIDOrder: UnsafeBufferPointer<UInt32>
}

/// A memory-mapped `tt-*` artifact: zero-copy views over one system's timetable.
///
/// ## Thread safety
/// `@unchecked Sendable` is sound because every stored property is immutable after `init`, the
/// bytes are a read-only mapping (or a private copy) that this object keeps alive and never
/// writes, and the only mutable state, the day-view cache, is guarded by a lock.
public final class Timetable: @unchecked Sendable {
    public let header: ArtifactHeader
    public let system: TransitSystem
    public let timeZone: TimeZone
    /// Window day 0. Every date the artifact knows about lies in `windowStart ..< windowStart + dayCount`.
    public let windowStart: ServiceDate
    public let dayCount: Int
    /// Zero-copy views of every section, for hot loops.
    public let raw: TimetableBuffers

    /// Bytes of each section's elements (excluding alignment padding), for size reports.
    public let sectionByteCounts: [TimetableSection: Int]

    private let storage: Data
    private let ownedCopy: UnsafeMutableRawBufferPointer?
    private let windowStartDay: Int
    private let wordsPerSource: Int
    /// Per slot: days on which some source of the slot is selected.
    private let slotCoverage: [DayBitset]
    /// Per slot: the last covered window day and the source selected on it (-1 when none).
    private let slotLastDay: [Int]
    private let slotLastSource: [Int]
    /// Per slot and weekday (0 = Monday): the window day whose service an extrapolated date of
    /// that weekday copies, or -1.
    private let slotReferenceDay: [[Int]]
    /// Days on which every slot is covered.
    private let coverage: DayBitset
    /// CSR of child stops (platforms, entrances) per parent stop.
    private let childStart: [UInt32]
    private let childStops: [UInt32]

    private let cacheLock = NSLock()
    private var dayViewCache: [Int: TimetableDayView] = [:]
    private var dayViewCacheOrder: [Int] = []
    /// Day views kept in memory (a query uses D−1, D and D+1).
    public static let dayViewCacheCapacity = 8

    public convenience init(contentsOf url: URL) throws {
        try self.init(artifact: MappedArtifact(contentsOf: url))
    }

    public init(artifact: MappedArtifact) throws {
        let kind = artifact.kind
        guard TransitSystem.allCases.map(ArtifactKind.timetable(for:)).contains(kind) else { throw TimetableFormatError.notATimetable(kind) }
        guard artifact.header.formatVersion == kind.currentFormatVersion else {
            throw TimetableFormatError.unsupportedFormatVersion(artifact.header.formatVersion)
        }
        header = artifact.header
        storage = artifact.payload

        // View the payload in place when it is 8-aligned (always, for mapped files); otherwise
        // work on an aligned private copy.
        let length = storage.count
        let inPlace: UnsafeRawPointer? = storage.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, Int(bitPattern: base) % 8 == 0, length > 64 else { return nil }
            return base
        }
        let base: UnsafeRawPointer
        var copy: UnsafeMutableRawBufferPointer?
        if let inPlace {
            base = inPlace
        } else {
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(length, 8), alignment: 8)
            storage.withUnsafeBytes { bytes in
                if let source = bytes.baseAddress, length > 0 {
                    buffer.baseAddress!.copyMemory(from: source, byteCount: length)
                }
            }
            copy = buffer
            base = UnsafeRawPointer(buffer.baseAddress!)
        }
        ownedCopy = copy
        let layout: Layout
        do {
            layout = try Layout(base: base, length: length, kind: kind)
        } catch {
            copy?.deallocate()
            throw error
        }
        raw = layout.raw
        system = layout.system
        timeZone = layout.timeZone
        windowStart = layout.windowStart
        windowStartDay = layout.windowStartDay
        dayCount = layout.dayCount
        wordsPerSource = layout.wordsPerSource
        slotCoverage = layout.slotCoverage
        slotLastDay = layout.slotLastDay
        slotLastSource = layout.slotLastSource
        slotReferenceDay = layout.slotReferenceDay
        coverage = layout.coverage
        sectionByteCounts = layout.sectionByteCounts

        var start = [UInt32](repeating: 0, count: raw.stopGTFSID.count + 1)
        for parent in raw.stopParent where parent != TimetableFormat.none { start[Int(parent) + 1] += 1 }
        for index in 1..<start.count { start[index] += start[index - 1] }
        var cursor = start
        var children = [UInt32](repeating: 0, count: Int(start.last ?? 0))
        for (stop, parent) in raw.stopParent.enumerated() where parent != TimetableFormat.none {
            children[Int(cursor[Int(parent)])] = UInt32(stop)
            cursor[Int(parent)] += 1
        }
        childStart = start
        childStops = children
    }

    /// Everything derived from the payload bytes at open time.
    private struct Layout {
        let raw: TimetableBuffers
        let system: TransitSystem
        let timeZone: TimeZone
        let windowStart: ServiceDate
        let windowStartDay: Int
        let dayCount: Int
        let wordsPerSource: Int
        let slotCoverage: [DayBitset]
        let slotLastDay: [Int]
        let slotLastSource: [Int]
        let slotReferenceDay: [[Int]]
        let coverage: DayBitset
        let sectionByteCounts: [TimetableSection: Int]

        init(base: UnsafeRawPointer, length: Int, kind: ArtifactKind) throws {
            let table = try SectionTable(base: base, length: length)
            let raw = try table.buffers()
            self.raw = raw
            var sizes: [TimetableSection: Int] = [:]
            for section in TimetableSection.allCases {
                if let entry = table.entries[section.rawValue] { sizes[section] = Int(entry.count) * section.elementSize }
            }
            sectionByteCounts = sizes
            let info = raw.info
            guard info.count >= InfoField.allCases.count else { throw TimetableFormatError.inconsistent("info section too short") }
            let revision = info[InfoField.draftRevision.rawValue]
            guard revision == TimetableFormat.draftRevision else { throw TimetableFormatError.unsupportedDraftRevision(revision) }
            let systemCode = info[InfoField.system.rawValue]
            guard (0...127).contains(systemCode),
                  let system = TransitSystem(rawValue: String(UnicodeScalar(UInt8(systemCode))))
            else { throw TimetableFormatError.unknownSystem(systemCode) }
            guard ArtifactKind.timetable(for: system) == kind else {
                throw TimetableFormatError.inconsistent("system \(system) does not match artifact kind \(kind.name)")
            }
            self.system = system
            let startDay = info[InfoField.windowStartDay.rawValue]
            let days = info[InfoField.dayCount.rawValue]
            guard Int64(Timetable.minimumDay)...Int64(Timetable.maximumDay - 100_000) ~= startDay, (0...100_000).contains(days) else {
                throw TimetableFormatError.inconsistent("window out of range")
            }
            let dayCount = Int(days)
            windowStartDay = Int(startDay)
            self.dayCount = dayCount
            windowStart = ServiceDate(daysSinceEpoch: Int(startDay))
            let wordsPerSource = DayBitset.wordCount(forDays: dayCount)
            self.wordsPerSource = wordsPerSource
            guard info[InfoField.wordsPerSource.rawValue] == Int64(wordsPerSource) else {
                throw TimetableFormatError.inconsistent("wordsPerSource does not match dayCount")
            }
            try Timetable.validate(raw, wordsPerSource: wordsPerSource)
            let zoneIndex = info[InfoField.timeZone.rawValue]
            guard zoneIndex >= 0, zoneIndex < Int64(raw.stringOffsets.count - 1) else {
                throw TimetableFormatError.inconsistent("time zone string out of range")
            }
            let zoneID = Timetable.string(raw, UInt32(zoneIndex))
            guard let zone = TimeZone(identifier: zoneID) else { throw TimetableFormatError.invalidTimeZone(zoneID) }
            timeZone = zone

            let sourceCount = raw.sourceName.count
            let slots = sourceCount > 0 ? Int(raw.sourceSlot.max() ?? 0) + 1 : 0
            var slotBits = [DayBitset](repeating: DayBitset(dayCount: dayCount), count: slots)
            var sourceBits: [DayBitset] = []
            for source in 0..<sourceCount {
                let words = Array(raw.sourceSelectedDays[source * wordsPerSource..<(source + 1) * wordsPerSource])
                let bits = DayBitset(words: words, dayCount: dayCount)
                sourceBits.append(bits)
                slotBits[Int(raw.sourceSlot[source])].formUnion(bits)
            }
            slotCoverage = slotBits
            coverage = ServiceCalendar.completeCoverage(slotCoverage: slotBits, dayCount: dayCount)
            var lastDay = [Int](repeating: -1, count: slots)
            var lastSource = [Int](repeating: -1, count: slots)
            for slot in 0..<slots {
                guard let day = slotBits[slot].lastDay else { continue }
                lastDay[slot] = day
                lastSource[slot] = (0..<sourceCount).first { Int(raw.sourceSlot[$0]) == slot && sourceBits[$0][day] } ?? -1
            }
            slotLastDay = lastDay
            slotLastSource = lastSource

            // Reference days: per weekday, among the last few covered dates of that weekday on
            // which the slot's newest source is selected, the one whose set of running rules is
            // most common (ties: the latest). Holidays and one-off planned work are outvoted.
            var rulesOfSource = [[Int]](repeating: [], count: sourceCount)
            for rule in 0..<raw.ruleGTFSID.count { rulesOfSource[Int(raw.ruleSource[rule])].append(rule) }
            var reference = [[Int]](repeating: [Int](repeating: -1, count: 7), count: slots)
            for slot in 0..<slots where lastSource[slot] >= 0 {
                let source = lastSource[slot]
                for weekday in 0..<7 {
                    var candidates: [(day: Int, running: [Int])] = []
                    var day = lastDay[slot]
                    while day >= 0, ServiceCalendar.weekdayBit(ofDay: windowStartDay + day) != weekday { day -= 1 }
                    while day >= 0, candidates.count < Timetable.referenceWeeks {
                        if sourceBits[source][day] {
                            let epochDay = Int32(windowStartDay + day)
                            candidates.append((day, rulesOfSource[source].filter { Timetable.ruleRuns(raw, $0, epochDay: epochDay) }))
                        }
                        day -= 7
                    }
                    var best = -1, bestCount = 0
                    for candidate in candidates {
                        let count = candidates.filter { $0.running == candidate.running }.count
                        if count > bestCount { best = candidate.day; bestCount = count }
                    }
                    reference[slot][weekday] = best
                }
            }
            slotReferenceDay = reference
        }
    }

    /// Covered dates of one weekday compared when choosing a reference day.
    public static let referenceWeeks = 5

    /// Day numbers `ServiceDate` can represent (years 1–9999).
    static let minimumDay = -719_162
    static let maximumDay = 2_932_896

    deinit {
        ownedCopy?.deallocate()
    }

    // MARK: - Counts

    public var stringCount: Int { raw.stringOffsets.count - 1 }
    public var sourceCount: Int { raw.sourceName.count }
    public var agencyCount: Int { raw.agencyGTFSID.count }
    public var routeCount: Int { raw.routeGTFSID.count }
    public var stopCount: Int { raw.stopGTFSID.count }
    public var ruleCount: Int { raw.ruleGTFSID.count }
    public var patternCount: Int { raw.patternRoute.count }
    public var tripCount: Int { raw.tripPattern.count }
    public var transferCount: Int { raw.transferFromStop.count }
    public var shapeCount: Int { raw.shapeGTFSID.count }
    /// Stop events stored (each trip × each stop of its pattern), over every service day.
    public var storedStopEventCount: Int {
        (0..<patternCount).reduce(0) { $0 + patternStopCount($1) * patternTripCount($1) }
    }

    // MARK: - Strings

    public func string(_ id: UInt32) -> String {
        Self.string(raw, id)
    }

    /// The bytes of string `id`, in place.
    public func stringBytes(_ id: UInt32) -> UnsafeBufferPointer<UInt8> {
        Self.bytes(raw, id)
    }

    private static func bytes(_ raw: TimetableBuffers, _ id: UInt32) -> UnsafeBufferPointer<UInt8> {
        guard Int(id) + 1 < raw.stringOffsets.count else { return UnsafeBufferPointer(start: nil, count: 0) }
        let start = Int(raw.stringOffsets[Int(id)]), end = Int(raw.stringOffsets[Int(id) + 1])
        return UnsafeBufferPointer(rebasing: raw.stringBytes[start..<end])
    }

    private static func string(_ raw: TimetableBuffers, _ id: UInt32) -> String {
        String(decoding: bytes(raw, id), as: UTF8.self)
    }

    // MARK: - Coverage and calendars

    /// The window day of `date`, or `nil` outside the window.
    public func windowDay(of date: ServiceDate) -> Int? {
        let day = date.daysSinceEpoch - windowStartDay
        return day >= 0 && day < dayCount ? day : nil
    }

    /// Whether the schedule covers `date`: every feed slot (each bus zip; the one subway, LIRR
    /// and ferry feed) has a selected source on it. This is the manifest's coverage.
    public func covers(_ date: ServiceDate) -> Bool {
        guard let day = windowDay(of: date) else { return false }
        return coverage[day]
    }

    /// Every covered service date, ascending.
    public var coveredDates: [ServiceDate] {
        coverage.days.map { windowStart.adding(days: $0) }
    }

    /// Feed slots: sources in one slot are alternative versions of one feed.
    public var slotCount: Int { slotCoverage.count }

    /// Whether one slot has a selected source on `date`.
    public func slotCovers(_ slot: Int, on date: ServiceDate) -> Bool {
        guard let day = windowDay(of: date) else { return false }
        return slotCoverage[slot][day]
    }

    /// Whether `source` is the version selected for its slot on `date`.
    public func isSourceSelected(_ source: Int, on date: ServiceDate) -> Bool {
        guard let day = windowDay(of: date) else { return false }
        return sourceSelected(source, windowDay: day)
    }

    @inline(__always)
    private func sourceSelected(_ source: Int, windowDay day: Int) -> Bool {
        raw.sourceSelectedDays[source * wordsPerSource + day >> 6] & (1 << UInt64(day & 63)) != 0
    }

    public func rule(_ index: Int) -> ServiceRule {
        let weekdays = raw.ruleWeekdays[index]
        let range = Int(raw.ruleExceptionStart[index])..<Int(raw.ruleExceptionStart[index + 1])
        let hasCalendar = weekdays & ruleHasCalendarBit != 0
        return ServiceRule(
            gtfsID: string(raw.ruleGTFSID[index]),
            source: Int(raw.ruleSource[index]),
            weekdayMask: weekdays & 0x7F,
            validRange: hasCalendar
                ? ServiceDate(daysSinceEpoch: Int(raw.ruleStartDay[index]))...ServiceDate(daysSinceEpoch: Int(raw.ruleEndDay[index]))
                : nil,
            exceptions: range.map { slot in
                (ServiceDate(daysSinceEpoch: Int(raw.exceptionDay[slot])), raw.exceptionType[slot] == 1)
            }
        )
    }

    /// Whether `rule` runs on `date`: its source is the version selected for that date, and by
    /// its calendar and exceptions it runs. Never extrapolates.
    public func isActive(rule: Int, on date: ServiceDate) -> Bool {
        guard let day = windowDay(of: date) else { return false }
        return ruleActive(rule, windowDay: day, epochDay: Int32(date.daysSinceEpoch))
    }

    @inline(__always)
    private func ruleActive(_ rule: Int, windowDay: Int, epochDay: Int32) -> Bool {
        guard sourceSelected(Int(raw.ruleSource[rule]), windowDay: windowDay) else { return false }
        return Self.ruleRuns(raw, rule, epochDay: epochDay)
    }

    /// The rule's own calendar and exceptions, ignoring source selection.
    @inline(__always)
    fileprivate static func ruleRuns(_ raw: TimetableBuffers, _ rule: Int, epochDay: Int32) -> Bool {
        let range = Int(raw.ruleExceptionStart[rule])..<Int(raw.ruleExceptionStart[rule + 1])
        return ServiceCalendar.ruleRuns(
            weekdays: raw.ruleWeekdays[rule], startDay: raw.ruleStartDay[rule], endDay: raw.ruleEndDay[rule],
            exceptionDays: UnsafeBufferPointer(rebasing: raw.exceptionDay[range]),
            exceptionTypes: UnsafeBufferPointer(rebasing: raw.exceptionType[range]),
            day: epochDay
        )
    }

    /// The coverage policy's step 2. After the last date its slot covers, `rule` is presumed to
    /// run on `date` when all of these hold:
    /// - it belongs to the slot's newest selected source;
    /// - it has a `calendar.txt` row, and `date` lies in its valid range extended by
    ///   ``TimetableFormat/extrapolationGraceDays`` (so rules with only `calendar_dates`, all of
    ///   LIRR, never extrapolate);
    /// - it ran on the slot's reference day for `date`'s weekday
    ///   (``extrapolationReferenceDate(slot:weekday:)``), exceptions included.
    ///
    /// Copying a real day, rather than applying weekday masks, keeps mutually exclusive variants
    /// (school-day and no-school weekday rules) from both running, and keeps day views FIFO.
    public func isActiveExtrapolated(rule: Int, on date: ServiceDate) -> Bool {
        let source = Int(raw.ruleSource[rule])
        let slot = Int(raw.sourceSlot[source])
        guard slotLastSource[slot] == source else { return false }
        let epochDay = date.daysSinceEpoch
        guard epochDay - windowStartDay > slotLastDay[slot], raw.ruleWeekdays[rule] & ruleHasCalendarBit != 0,
              epochDay >= Int(raw.ruleStartDay[rule]),
              epochDay <= Int(raw.ruleEndDay[rule]) + TimetableFormat.extrapolationGraceDays
        else { return false }
        let reference = slotReferenceDay[slot][ServiceCalendar.weekdayBit(ofDay: epochDay)]
        guard reference >= 0 else { return false }
        return Self.ruleRuns(raw, rule, epochDay: Int32(windowStartDay + reference))
    }

    /// The covered date whose service an extrapolated `weekday` in `slot` copies, or `nil` when
    /// the slot has no covered date of that weekday.
    public func extrapolationReferenceDate(slot: Int, weekday: Weekday) -> ServiceDate? {
        let day = slotReferenceDay[slot][weekday.rawValue - 1]
        return day >= 0 ? windowStart.adding(days: day) : nil
    }

    public func isActive(trip: Int, on date: ServiceDate) -> Bool {
        isActive(rule: Int(raw.tripRule[trip]), on: date)
    }

    // MARK: - Day views

    /// The trips running on `date`, per pattern, sorted by departure. Built on first use and
    /// cached (up to ``dayViewCacheCapacity`` dates). With `extrapolate`, a date outside a
    /// slot's coverage uses ``isActiveExtrapolated(rule:on:)`` for that slot's rules.
    public func dayView(for date: ServiceDate, extrapolate: Bool = false) -> TimetableDayView {
        let key = date.daysSinceEpoch * 2 + (extrapolate ? 1 : 0)
        cacheLock.lock()
        if let cached = dayViewCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let view = makeDayView(for: date, extrapolate: extrapolate)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let raced = dayViewCache[key] { return raced }
        dayViewCache[key] = view
        dayViewCacheOrder.append(key)
        if dayViewCacheOrder.count > Self.dayViewCacheCapacity {
            dayViewCache[dayViewCacheOrder.removeFirst()] = nil
        }
        return view
    }

    private func makeDayView(for date: ServiceDate, extrapolate: Bool) -> TimetableDayView {
        let epochDay = Int32(date.daysSinceEpoch)
        let windowDay = windowDay(of: date)
        var ruleOn = [Bool](repeating: false, count: ruleCount)
        var anyExtrapolated = false
        for rule in 0..<ruleCount {
            if let windowDay, ruleActive(rule, windowDay: windowDay, epochDay: epochDay) {
                ruleOn[rule] = true
            } else if extrapolate, isActiveExtrapolated(rule: rule, on: date) {
                ruleOn[rule] = true
                anyExtrapolated = true
            }
        }
        let offsets = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: patternCount + 1)
        var trips: [UInt32] = []
        var events = 0
        offsets[0] = 0
        for pattern in 0..<patternCount {
            let range = Int(raw.patternTripStart[pattern])..<Int(raw.patternTripStart[pattern + 1])
            let before = trips.count
            for trip in range where ruleOn[Int(raw.tripRule[trip])] {
                trips.append(UInt32(trip))
            }
            events += (trips.count - before) * patternStopCount(pattern)
            offsets[pattern + 1] = UInt32(trips.count)
        }
        let storage = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: max(trips.count, 1))
        _ = storage.initialize(from: trips)
        return TimetableDayView(
            date: date, isCovered: covers(date), isExtrapolated: anyExtrapolated,
            offsets: offsets, trips: storage, tripCount: trips.count, stopEventCount: events
        )
    }

    // MARK: - Sources and agencies

    public func source(_ index: Int) -> TimetableSource {
        let words = Array(raw.sourceSelectedDays[index * wordsPerSource..<(index + 1) * wordsPerSource])
        return TimetableSource(
            name: string(raw.sourceName[index]),
            version: string(raw.sourceVersion[index]),
            etag: string(raw.sourceETag[index]),
            slot: Int(raw.sourceSlot[index]),
            selectedDates: DayBitset(words: words, dayCount: dayCount).days.map { windowStart.adding(days: $0) }
        )
    }

    public func agency(_ index: Int) -> TimetableAgency {
        TimetableAgency(
            gtfsID: string(raw.agencyGTFSID[index]),
            name: string(raw.agencyName[index]),
            timeZone: string(raw.agencyTimezone[index])
        )
    }

    // MARK: - Routes

    public func route(_ index: Int) -> TimetableRoute {
        let agency = Int(raw.routeAgency[index])
        let gtfsID = string(raw.routeGTFSID[index])
        return TimetableRoute(
            id: RouteID(system: system, gtfsID: gtfsID),
            gtfsID: gtfsID,
            agency: agency,
            agencyGTFSID: string(raw.agencyGTFSID[agency]),
            shortName: string(raw.routeShortName[index]),
            longName: string(raw.routeLongName[index]),
            color: Self.color(raw.routeColor[index]),
            textColor: Self.color(raw.routeTextColor[index]),
            mode: RouteMode(rawValue: raw.routeMode[index]) ?? .localBus,
            gtfsRouteType: Int(raw.routeType[index])
        )
    }

    public func routeMode(_ index: Int) -> RouteMode {
        RouteMode(rawValue: raw.routeMode[index]) ?? .localBus
    }

    private static func color(_ value: UInt32) -> UInt32? {
        value == TimetableFormat.none ? nil : value
    }

    // MARK: - Stops

    public func stopGTFSID(_ stop: Int) -> String { string(raw.stopGTFSID[stop]) }
    /// The system-qualified id, e.g. `S:127N`.
    public func stopID(_ stop: Int) -> StopID { StopID(system: system, gtfsID: stopGTFSID(stop)) }
    public func stopName(_ stop: Int) -> String { string(raw.stopName[stop]) }
    public func stopCode(_ stop: Int) -> String { string(raw.stopCode[stop]) }
    public func stopKind(_ stop: Int) -> StopKind { StopKind(rawValue: raw.stopKind[stop]) ?? .stop }

    public func stopCoordinate(_ stop: Int) -> Coordinate {
        Coordinate(lat: Double(raw.stopLatE6[stop]) / 1e6, lon: Double(raw.stopLonE6[stop]) / 1e6)
    }

    public func stopParent(_ stop: Int) -> Int? {
        let parent = raw.stopParent[stop]
        return parent == TimetableFormat.none ? nil : Int(parent)
    }

    /// Whether riders may enter and/or leave here. Both for every GTFS stop; entrances may be
    /// entry-only or exit-only.
    public func stopAccess(_ stop: Int) -> StopAccess { StopAccess(rawValue: raw.stopAccess[stop]) }

    /// For a subway entrance (``StopKind/entrance``), its type from the data.ny.gov entrances
    /// dataset, e.g. `Stair`, `Elevator`, `Escalator`, `Easement - Street`. Empty otherwise.
    public func stopEntranceType(_ stop: Int) -> String { string(raw.stopEntranceType[stop]) }

    /// Stops whose parent is `stop`: a station's platforms and entrances, in stop order.
    public func children(ofStop stop: Int) -> ArraySlice<UInt32> {
        childStops[Int(childStart[stop])..<Int(childStart[stop + 1])]
    }

    /// A station's entrances.
    public func entrances(ofStation station: Int) -> [Int] {
        children(ofStop: station).map { Int($0) }.filter { raw.stopKind[$0] == StopKind.entrance.rawValue }
    }

    /// The stop with this bare GTFS `stop_id` (no system prefix).
    public func stop(gtfsID: String) -> Int? {
        let found = equalRange(raw.stopIDOrder, of: gtfsID) { raw.stopGTFSID[Int($0)] }
        return found.first.map { Int(raw.stopIDOrder[$0]) }
    }

    /// The stop with this system-qualified id; `nil` for another system's id.
    public func stop(id: StopID) -> Int? {
        guard id.system == system else { return nil }
        return stop(gtfsID: String(id.gtfsID))
    }

    /// The patterns that call at `stop`, with the stop's position in each.
    public func patterns(servingStop stop: Int) -> StopPatternRefs {
        let range = Int(raw.stopPatternStart[stop])..<Int(raw.stopPatternStart[stop + 1])
        return StopPatternRefs(
            patterns: UnsafeBufferPointer(rebasing: raw.stopPatternRef[range]),
            positions: UnsafeBufferPointer(rebasing: raw.stopPatternPosition[range])
        )
    }

    // MARK: - Patterns

    public func patternRoute(_ pattern: Int) -> Int { Int(raw.patternRoute[pattern]) }
    public func patternFlags(_ pattern: Int) -> PatternFlags { PatternFlags(rawValue: raw.patternFlags[pattern]) }
    /// Sub-patterns split from one (route, stops, pickup/drop-off) key for FIFO share this value.
    public func patternBaseKey(_ pattern: Int) -> Int { Int(raw.patternBaseKey[pattern]) }

    public func patternStopCount(_ pattern: Int) -> Int {
        Int(raw.patternStopStart[pattern + 1] - raw.patternStopStart[pattern])
    }

    public func patternTripCount(_ pattern: Int) -> Int {
        Int(raw.patternTripStart[pattern + 1] - raw.patternTripStart[pattern])
    }

    /// Stop indices in calling order.
    public func patternStops(_ pattern: Int) -> UnsafeBufferPointer<UInt32> {
        let range = Int(raw.patternStopStart[pattern])..<Int(raw.patternStopStart[pattern + 1])
        return UnsafeBufferPointer(rebasing: raw.patternStopIndex[range])
    }

    /// ``StopEventFlags`` raw values, parallel to ``patternStops(_:)``.
    public func patternStopFlags(_ pattern: Int) -> UnsafeBufferPointer<UInt8> {
        let range = Int(raw.patternStopStart[pattern])..<Int(raw.patternStopStart[pattern + 1])
        return UnsafeBufferPointer(rebasing: raw.patternStopFlags[range])
    }

    public func canBoard(pattern: Int, position: Int) -> Bool {
        raw.patternStopFlags[Int(raw.patternStopStart[pattern]) + position] & StopEventFlags.pickup.rawValue != 0
    }

    public func canAlight(pattern: Int, position: Int) -> Bool {
        raw.patternStopFlags[Int(raw.patternStopStart[pattern]) + position] & StopEventFlags.dropOff.rawValue != 0
    }

    /// The pattern's trips: contiguous trip indices, sorted by first departure.
    public func patternTrips(_ pattern: Int) -> Range<Int> {
        Int(raw.patternTripStart[pattern])..<Int(raw.patternTripStart[pattern + 1])
    }

    /// Departures as a trip-major matrix: trip `patternTrips.lowerBound + j` at position `i` is
    /// element `j * patternStopCount + i`.
    public func patternDepartures(_ pattern: Int) -> UnsafeBufferPointer<UInt32> {
        let start = Int(raw.patternDepartureStart[pattern])
        return UnsafeBufferPointer(rebasing: raw.departures[start..<start + patternStopCount(pattern) * patternTripCount(pattern)])
    }

    /// Arrivals in the same layout; the departure matrix itself when the pattern has
    /// ``PatternFlags/arrivalEqualsDeparture``.
    public func patternArrivals(_ pattern: Int) -> UnsafeBufferPointer<UInt32> {
        let start = raw.patternArrivalStart[pattern]
        guard start != TimetableFormat.none else { return patternDepartures(pattern) }
        return UnsafeBufferPointer(rebasing: raw.arrivals[Int(start)..<Int(start) + patternStopCount(pattern) * patternTripCount(pattern)])
    }

    public func patternShape(_ pattern: Int) -> Int? {
        let shape = raw.patternShape[pattern]
        return shape == TimetableFormat.none ? nil : Int(shape)
    }

    /// For each stop of the pattern, the index of its vertex in the pattern's shape, or
    /// ``TimetableFormat/none``. Non-decreasing along the pattern.
    public func patternShapeVertices(_ pattern: Int) -> UnsafeBufferPointer<UInt32> {
        let range = Int(raw.patternStopStart[pattern])..<Int(raw.patternStopStart[pattern + 1])
        return UnsafeBufferPointer(rebasing: raw.patternStopShapeVertex[range])
    }

    // MARK: - Trips and stop times

    public func tripPattern(_ trip: Int) -> Int { Int(raw.tripPattern[trip]) }
    public func tripRule(_ trip: Int) -> Int { Int(raw.tripRule[trip]) }
    public func tripGTFSID(_ trip: Int) -> String { string(raw.tripGTFSID[trip]) }
    public func tripID(_ trip: Int) -> TripID { TripID(system: system, gtfsID: tripGTFSID(trip)) }
    public func tripHeadsign(_ trip: Int) -> String { string(raw.tripHeadsign[trip]) }
    public func tripShortName(_ trip: Int) -> String { string(raw.tripShortName[trip]) }
    public func tripRoute(_ trip: Int) -> Int { patternRoute(tripPattern(trip)) }

    public func tripDirection(_ trip: Int) -> Int? {
        let direction = raw.tripDirection[trip]
        return direction == 255 ? nil : Int(direction)
    }

    /// Seconds from the service day's origin.
    public func departure(trip: Int, position: Int) -> UInt32 {
        let pattern = Int(raw.tripPattern[trip])
        let stops = patternStopCount(pattern)
        let local = trip - Int(raw.patternTripStart[pattern])
        return raw.departures[Int(raw.patternDepartureStart[pattern]) + local * stops + position]
    }

    /// Seconds from the service day's origin.
    public func arrival(trip: Int, position: Int) -> UInt32 {
        let pattern = Int(raw.tripPattern[trip])
        let start = raw.patternArrivalStart[pattern]
        guard start != TimetableFormat.none else { return departure(trip: trip, position: position) }
        let stops = patternStopCount(pattern)
        let local = trip - Int(raw.patternTripStart[pattern])
        return raw.arrivals[Int(start) + local * stops + position]
    }

    /// The scheduled calls at `stop` on `view`'s date, in departure order (ties: arrival, then
    /// trip). A station stands for itself and its platforms. Optional filters keep one route
    /// (route index), one `direction_id`, and only calls that allow boarding.
    ///
    /// This is the real-time match table for feeds without trip ids (PATH's `ridepath.json`
    /// gives per station and direction only line colors and seconds to arrival): the overlay
    /// matcher lists the station's calls for (route, direction) and pairs predictions with them
    /// in order. It costs one pass over the patterns serving the stop and their active trips.
    public func scheduledCalls(atStop stop: Int, route: Int? = nil, direction: Int? = nil, boardingOnly: Bool = false,
                               in view: TimetableDayView) -> [ScheduledCall] {
        var stops = [stop]
        stops.append(contentsOf: children(ofStop: stop).map(Int.init))
        var calls: [ScheduledCall] = []
        for member in stops {
            for (pattern, position) in patterns(servingStop: member) {
                if let route, patternRoute(pattern) != route { continue }
                if boardingOnly, !canBoard(pattern: pattern, position: position) { continue }
                for trip in view.activeTrips(inPattern: pattern) {
                    let trip = Int(trip)
                    if let direction, tripDirection(trip) != direction { continue }
                    calls.append(ScheduledCall(trip: trip, pattern: pattern, position: position, stop: member,
                                               arrival: arrival(trip: trip, position: position),
                                               departure: departure(trip: trip, position: position)))
                }
            }
        }
        calls.sort { ($0.departure, $0.arrival, $0.trip) < ($1.departure, $1.arrival, $1.trip) }
        return calls
    }

    /// Trips with this exact GTFS `trip_id` (LIRR real-time match; more than one only when two
    /// source versions share an id, told apart by service date).
    public func trips(gtfsID: String) -> [Int] {
        equalRange(raw.tripIDOrder, of: gtfsID) { raw.tripGTFSID[Int($0)] }.map { Int(raw.tripIDOrder[$0]) }
    }

    /// Bus real-time match: SIRI `DatedVehicleJourneyRef` without its `<agency>_` prefix → the
    /// agency and trip. Filter by ``isActive(trip:on:)`` with `DataFrameRef`.
    public func busTrips(bareTripID: String) -> [(agencyGTFSID: String, trip: Int)] {
        trips(gtfsID: bareTripID).map { trip in
            (string(raw.agencyGTFSID[Int(raw.routeAgency[tripRoute(trip)])]), trip)
        }
    }

    // MARK: - Subway real-time keys

    /// Static trips whose id parses to `route`, `direction` and `originHundredths`, with their
    /// path suffix, ordered by path. Callers filter by ``isActive(trip:on:)`` for the real-time
    /// `start_date`.
    public func subwayTrips(route: String, direction: UInt8, originHundredths: Int32) -> [(trip: Int, path: String)] {
        let count = raw.subwayKeyTrip.count
        var routeBytes = route
        return routeBytes.withUTF8 { routeKey in
            func compare(_ index: Int) -> Int {
                let byRoute = compareBytes(stringBytes(raw.subwayKeyRoute[index]), routeKey)
                if byRoute != 0 { return byRoute }
                if raw.subwayKeyDirection[index] != direction { return raw.subwayKeyDirection[index] < direction ? -1 : 1 }
                if raw.subwayKeyOrigin[index] != originHundredths { return raw.subwayKeyOrigin[index] < originHundredths ? -1 : 1 }
                return 0
            }
            var low = 0, high = count
            while low < high {
                let mid = (low + high) / 2
                if compare(mid) < 0 { low = mid + 1 } else { high = mid }
            }
            var result: [(trip: Int, path: String)] = []
            var index = low
            while index < count, compare(index) == 0 {
                result.append((Int(raw.subwayKeyTrip[index]), string(raw.subwayKeyPath[index])))
                index += 1
            }
            return result
        }
    }

    /// Static trips matching every field of `key`, including the path.
    public func subwayTrips(matching key: SubwayTripKey) -> [Int] {
        subwayTrips(route: key.route, direction: key.direction, originHundredths: key.originHundredths)
            .filter { $0.path == key.path }.map(\.trip)
    }

    // MARK: - Transfers

    public func transfer(_ index: Int) -> TimetableTransfer {
        func optional(_ value: UInt32) -> Int? { value == TimetableFormat.none ? nil : Int(value) }
        return TimetableTransfer(
            fromStop: Int(raw.transferFromStop[index]),
            toStop: Int(raw.transferToStop[index]),
            fromTrip: optional(raw.transferFromTrip[index]),
            toTrip: optional(raw.transferToTrip[index]),
            type: Int(raw.transferType[index]),
            minTransferSeconds: optional(raw.transferMinSeconds[index])
        )
    }

    /// Guaranteed (`transfer_type` 1) trip-to-trip transfers leaving `trip`.
    public func guaranteedTransfers(fromTrip trip: Int) -> [TimetableTransfer] {
        // Rows are sorted by fromTrip, with rows lacking a trip (none) last.
        let target = UInt32(trip)
        var low = 0, high = transferCount
        while low < high {
            let mid = (low + high) / 2
            if raw.transferFromTrip[mid] < target { low = mid + 1 } else { high = mid }
        }
        var result: [TimetableTransfer] = []
        while low < transferCount, raw.transferFromTrip[low] == target {
            if raw.transferType[low] == 1, raw.transferToTrip[low] != TimetableFormat.none { result.append(transfer(low)) }
            low += 1
        }
        return result
    }

    // MARK: - Shapes

    public func shapeGTFSID(_ shape: Int) -> String { string(raw.shapeGTFSID[shape]) }

    public func shapePoints(_ shape: Int) -> [Coordinate] {
        (Int(raw.shapePointStart[shape])..<Int(raw.shapePointStart[shape + 1])).map {
            Coordinate(lat: Double(raw.shapeLatE6[$0]) / 1e6, lon: Double(raw.shapeLonE6[$0]) / 1e6)
        }
    }

    // MARK: - Helpers

    /// Positions in `order` (indices sorted by string) whose string equals `key`.
    private func equalRange(_ order: UnsafeBufferPointer<UInt32>, of key: String, id: (UInt32) -> UInt32) -> Range<Int> {
        var key = key
        return key.withUTF8 { keyBytes in
            var low = 0, high = order.count
            while low < high {
                let mid = (low + high) / 2
                if compareBytes(stringBytes(id(order[mid])), keyBytes) < 0 { low = mid + 1 } else { high = mid }
            }
            var end = low
            while end < order.count, compareBytes(stringBytes(id(order[end])), keyBytes) == 0 { end += 1 }
            return low..<end
        }
    }
}

// MARK: - Value types

public struct TimetableSource: Sendable, Equatable {
    /// Feed name, e.g. `gtfs_supplemented`.
    public let name: String
    /// `feed_info.feed_version`, or empty.
    public let version: String
    public let etag: String
    /// Sources sharing a slot are alternative versions of one feed; exactly one is selected per date.
    public let slot: Int
    public let selectedDates: [ServiceDate]
}

public struct TimetableAgency: Sendable, Equatable {
    public let gtfsID: String
    public let name: String
    public let timeZone: String
}

public struct TimetableRoute: Sendable, Equatable {
    public let id: RouteID
    public let gtfsID: String
    public let agency: Int
    public let agencyGTFSID: String
    public let shortName: String
    public let longName: String
    /// `0xRRGGBB`, or `nil` when the feed gives none.
    public let color: UInt32?
    public let textColor: UInt32?
    public let mode: RouteMode
    public let gtfsRouteType: Int
}

public struct ServiceRule: Sendable, Equatable {
    public let gtfsID: String
    public let source: Int
    /// Bit 0 = Monday … bit 6 = Sunday. Zero when the rule has no `calendar.txt` row.
    public let weekdayMask: UInt8
    /// The `calendar.txt` range, or `nil` for a `calendar_dates`-only rule.
    public let validRange: ClosedRange<ServiceDate>?
    /// `(date, added)`: `true` for exception_type 1, `false` for 2. Ascending by date.
    public let exceptions: [(ServiceDate, Bool)]

    public static func == (a: ServiceRule, b: ServiceRule) -> Bool {
        a.gtfsID == b.gtfsID && a.source == b.source && a.weekdayMask == b.weekdayMask && a.validRange == b.validRange
            && a.exceptions.map(\.0) == b.exceptions.map(\.0) && a.exceptions.map(\.1) == b.exceptions.map(\.1)
    }
}

public struct TimetableTransfer: Sendable, Equatable {
    public let fromStop: Int
    public let toStop: Int
    public let fromTrip: Int?
    public let toTrip: Int?
    /// GTFS `transfer_type` (0 recommended, 1 timed/guaranteed, 2 minimum time, 3 not possible).
    public let type: Int
    public let minTransferSeconds: Int?
}

/// One trip's call at a stop on one service date (``Timetable/scheduledCalls(atStop:route:direction:boardingOnly:in:)``).
public struct ScheduledCall: Sendable, Equatable {
    public let trip: Int
    public let pattern: Int
    /// The stop's position in the pattern.
    public let position: Int
    /// The platform called at (a child when the query named a station).
    public let stop: Int
    /// Seconds from the service day's origin.
    public let arrival: UInt32
    public let departure: UInt32
}

/// The patterns calling at one stop, with the stop's position in each.
public struct StopPatternRefs: RandomAccessCollection {
    public let patterns: UnsafeBufferPointer<UInt32>
    public let positions: UnsafeBufferPointer<UInt32>

    public var startIndex: Int { 0 }
    public var endIndex: Int { patterns.count }

    public subscript(index: Int) -> (pattern: Int, position: Int) {
        (Int(patterns[index]), Int(positions[index]))
    }
}

/// One service date's active trips, per pattern, in departure order. Pointers are valid for the
/// lifetime of this object.
public final class TimetableDayView: @unchecked Sendable {
    public let date: ServiceDate
    /// The date lies inside the system's schedule coverage.
    public let isCovered: Bool
    /// At least one trip is included only by extrapolation (coverage policy step 2).
    public let isExtrapolated: Bool
    public let activeTripCount: Int
    /// Σ active trips × stops of their pattern.
    public let stopEventCount: Int
    private let offsets: UnsafeMutableBufferPointer<UInt32>
    private let trips: UnsafeMutableBufferPointer<UInt32>

    init(date: ServiceDate, isCovered: Bool, isExtrapolated: Bool, offsets: UnsafeMutableBufferPointer<UInt32>,
         trips: UnsafeMutableBufferPointer<UInt32>, tripCount: Int, stopEventCount: Int) {
        self.date = date
        self.isCovered = isCovered
        self.isExtrapolated = isExtrapolated
        self.offsets = offsets
        self.trips = trips
        self.activeTripCount = tripCount
        self.stopEventCount = stopEventCount
    }

    deinit {
        offsets.deallocate()
        trips.deallocate()
    }

    public var patternCount: Int { offsets.count - 1 }

    /// Global trip indices of the pattern's trips running on ``date``, sorted by departure at
    /// every stop (FIFO holds among trips of one day).
    public func activeTrips(inPattern pattern: Int) -> UnsafeBufferPointer<UInt32> {
        let start = Int(offsets[pattern]), end = Int(offsets[pattern + 1])
        return UnsafeBufferPointer(rebasing: UnsafeBufferPointer(trips)[start..<end])
    }

    public func activeTripCount(inPattern pattern: Int) -> Int {
        Int(offsets[pattern + 1] - offsets[pattern])
    }
}

// MARK: - Section table and validation

private struct SectionTable {
    let base: UnsafeRawPointer
    let length: Int
    var entries: [UInt32: (elementSize: UInt32, offset: UInt64, count: UInt64)] = [:]

    init(base: UnsafeRawPointer, length: Int) throws {
        self.base = base
        self.length = length
        guard length >= TimetableFormat.preambleSize else { throw TimetableFormatError.truncated }
        for (index, byte) in TimetableFormat.magic.enumerated() where base.load(fromByteOffset: index, as: UInt8.self) != byte {
            throw TimetableFormatError.badMagic
        }
        let count = Int(base.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        guard count <= 10_000, TimetableFormat.preambleSize + count * TimetableFormat.tocEntrySize <= length else {
            throw TimetableFormatError.truncated
        }
        for index in 0..<count {
            let entry = TimetableFormat.preambleSize + index * TimetableFormat.tocEntrySize
            let id = base.loadUnaligned(fromByteOffset: entry, as: UInt32.self)
            let size = base.loadUnaligned(fromByteOffset: entry + 4, as: UInt32.self)
            let offset = base.loadUnaligned(fromByteOffset: entry + 8, as: UInt64.self)
            let elements = base.loadUnaligned(fromByteOffset: entry + 16, as: UInt64.self)
            guard entries.updateValue((size, offset, elements), forKey: id) == nil else {
                throw TimetableFormatError.duplicateSection(id)
            }
        }
    }

    func view<T>(_ section: TimetableSection, as _: T.Type = T.self) throws -> UnsafeBufferPointer<T> {
        guard let entry = entries[section.rawValue] else { throw TimetableFormatError.missingSection(section) }
        let stride = MemoryLayout<T>.stride
        guard entry.elementSize == UInt32(section.elementSize), stride == section.elementSize else {
            throw TimetableFormatError.elementSizeMismatch(section, found: entry.elementSize)
        }
        guard entry.offset % 8 == 0 else { throw TimetableFormatError.misalignedSection(section) }
        let (bytes, overflow) = entry.count.multipliedReportingOverflow(by: UInt64(stride))
        guard !overflow, entry.offset <= UInt64(length), bytes <= UInt64(length) - entry.offset else {
            throw TimetableFormatError.sectionOutOfBounds(section)
        }
        let start = (base + Int(entry.offset)).assumingMemoryBound(to: T.self)
        return UnsafeBufferPointer(start: entry.count == 0 ? nil : start, count: Int(entry.count))
    }

    func buffers() throws -> TimetableBuffers {
        TimetableBuffers(
            info: try view(.info), stringOffsets: try view(.stringOffsets), stringBytes: try view(.stringBytes),
            sourceName: try view(.sourceName), sourceVersion: try view(.sourceVersion), sourceETag: try view(.sourceETag),
            sourceSlot: try view(.sourceSlot), sourceSelectedDays: try view(.sourceSelectedDays),
            agencyGTFSID: try view(.agencyGTFSID), agencyName: try view(.agencyName), agencyTimezone: try view(.agencyTimezone),
            routeAgency: try view(.routeAgency), routeGTFSID: try view(.routeGTFSID), routeShortName: try view(.routeShortName),
            routeLongName: try view(.routeLongName), routeColor: try view(.routeColor), routeTextColor: try view(.routeTextColor),
            routeMode: try view(.routeMode), routeType: try view(.routeType),
            stopGTFSID: try view(.stopGTFSID), stopName: try view(.stopName), stopCode: try view(.stopCode),
            stopLatE6: try view(.stopLatE6), stopLonE6: try view(.stopLonE6), stopParent: try view(.stopParent),
            stopKind: try view(.stopKind), stopAccess: try view(.stopAccess), stopEntranceType: try view(.stopEntranceType),
            ruleGTFSID: try view(.ruleGTFSID), ruleSource: try view(.ruleSource), ruleWeekdays: try view(.ruleWeekdays),
            ruleStartDay: try view(.ruleStartDay), ruleEndDay: try view(.ruleEndDay),
            ruleExceptionStart: try view(.ruleExceptionStart), exceptionDay: try view(.exceptionDay),
            exceptionType: try view(.exceptionType),
            patternRoute: try view(.patternRoute), patternStopStart: try view(.patternStopStart),
            patternTripStart: try view(.patternTripStart), patternFlags: try view(.patternFlags),
            patternDepartureStart: try view(.patternDepartureStart), patternArrivalStart: try view(.patternArrivalStart),
            patternShape: try view(.patternShape), patternBaseKey: try view(.patternBaseKey),
            patternStopIndex: try view(.patternStopIndex), patternStopFlags: try view(.patternStopFlags),
            patternStopShapeVertex: try view(.patternStopShapeVertex),
            departures: try view(.departures), arrivals: try view(.arrivals),
            tripPattern: try view(.tripPattern), tripRule: try view(.tripRule), tripGTFSID: try view(.tripGTFSID),
            tripHeadsign: try view(.tripHeadsign), tripShortName: try view(.tripShortName),
            tripDirection: try view(.tripDirection),
            stopPatternStart: try view(.stopPatternStart), stopPatternRef: try view(.stopPatternRef),
            stopPatternPosition: try view(.stopPatternPosition),
            transferFromStop: try view(.transferFromStop), transferToStop: try view(.transferToStop),
            transferFromTrip: try view(.transferFromTrip), transferToTrip: try view(.transferToTrip),
            transferType: try view(.transferType), transferMinSeconds: try view(.transferMinSeconds),
            shapeGTFSID: try view(.shapeGTFSID), shapePointStart: try view(.shapePointStart),
            shapeLatE6: try view(.shapeLatE6), shapeLonE6: try view(.shapeLonE6),
            subwayKeyRoute: try view(.subwayKeyRoute), subwayKeyDirection: try view(.subwayKeyDirection),
            subwayKeyOrigin: try view(.subwayKeyOrigin), subwayKeyPath: try view(.subwayKeyPath),
            subwayKeyTrip: try view(.subwayKeyTrip),
            tripIDOrder: try view(.tripIDOrder), stopIDOrder: try view(.stopIDOrder)
        )
    }
}

extension Timetable {
    /// Checks every length and cross-reference so that no accessor can read out of bounds.
    fileprivate static func validate(_ raw: TimetableBuffers, wordsPerSource: Int) throws {
        func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            if !condition { throw TimetableFormatError.inconsistent(message()) }
        }
        func offsets(_ values: UnsafeBufferPointer<UInt32>, count: Int, total: Int, _ name: String) throws {
            try check(values.count == count + 1, "\(name) length")
            try check(values[0] == 0 && Int(values[count]) == total, "\(name) span")
            var previous: UInt32 = 0
            for value in values {
                try check(value >= previous, "\(name) not monotone")
                previous = value
            }
        }
        func below(_ values: UnsafeBufferPointer<UInt32>, _ bound: Int, allowNone: Bool = false, _ name: String) throws {
            let limit = UInt32(clamping: bound)
            for value in values where value >= limit && !(allowNone && value == TimetableFormat.none) {
                throw TimetableFormatError.inconsistent("\(name) out of range")
            }
        }
        func same(_ counts: [Int], _ name: String) throws {
            try check(Set(counts).count <= 1, "\(name) arrays differ in length")
        }

        let strings = raw.stringOffsets.count - 1
        try check(strings >= 1, "string pool is empty")
        try offsets(raw.stringOffsets, count: strings, total: raw.stringBytes.count, "stringOffsets")
        for ids in [raw.sourceName, raw.sourceVersion, raw.sourceETag, raw.agencyGTFSID, raw.agencyName, raw.agencyTimezone,
                    raw.routeGTFSID, raw.routeShortName, raw.routeLongName, raw.stopGTFSID, raw.stopName, raw.stopCode,
                    raw.stopEntranceType,
                    raw.ruleGTFSID, raw.tripGTFSID, raw.tripHeadsign, raw.tripShortName, raw.shapeGTFSID,
                    raw.subwayKeyRoute, raw.subwayKeyPath] {
            try below(ids, strings, "string id")
        }

        let sources = raw.sourceName.count
        try same([sources, raw.sourceVersion.count, raw.sourceETag.count, raw.sourceSlot.count], "source")
        try check(raw.sourceSelectedDays.count == sources * wordsPerSource, "sourceSelectedDays length")
        try below(raw.sourceSlot, max(sources, 1), "sourceSlot")

        let agencies = raw.agencyGTFSID.count
        try same([agencies, raw.agencyName.count, raw.agencyTimezone.count], "agency")

        let routes = raw.routeGTFSID.count
        try same([routes, raw.routeAgency.count, raw.routeShortName.count, raw.routeLongName.count, raw.routeColor.count,
                  raw.routeTextColor.count, raw.routeMode.count, raw.routeType.count], "route")
        try below(raw.routeAgency, agencies, "routeAgency")

        let stops = raw.stopGTFSID.count
        try same([stops, raw.stopName.count, raw.stopCode.count, raw.stopLatE6.count, raw.stopLonE6.count,
                  raw.stopParent.count, raw.stopKind.count, raw.stopAccess.count, raw.stopEntranceType.count], "stop")
        try below(raw.stopParent, stops, allowNone: true, "stopParent")

        let rules = raw.ruleGTFSID.count
        try same([rules, raw.ruleSource.count, raw.ruleWeekdays.count, raw.ruleStartDay.count, raw.ruleEndDay.count], "rule")
        try below(raw.ruleSource, sources, "ruleSource")
        try offsets(raw.ruleExceptionStart, count: rules, total: raw.exceptionDay.count, "ruleExceptionStart")
        try check(raw.exceptionType.count == raw.exceptionDay.count, "exception arrays differ in length")
        let dayRange = Int32(minimumDay)...Int32(maximumDay - 1_000)
        for rule in 0..<rules where raw.ruleWeekdays[rule] & ruleHasCalendarBit != 0 {
            try check(dayRange.contains(raw.ruleStartDay[rule]) && dayRange.contains(raw.ruleEndDay[rule]), "rule date out of range")
        }
        try check(raw.exceptionDay.allSatisfy { dayRange.contains($0) }, "exception date out of range")

        let patterns = raw.patternRoute.count
        try same([patterns, raw.patternFlags.count, raw.patternDepartureStart.count, raw.patternArrivalStart.count,
                  raw.patternShape.count, raw.patternBaseKey.count], "pattern")
        try below(raw.patternRoute, routes, "patternRoute")
        try offsets(raw.patternStopStart, count: patterns, total: raw.patternStopIndex.count, "patternStopStart")
        let trips = raw.tripPattern.count
        try offsets(raw.patternTripStart, count: patterns, total: trips, "patternTripStart")
        try same([raw.patternStopIndex.count, raw.patternStopFlags.count, raw.patternStopShapeVertex.count], "pattern stop")
        try below(raw.patternStopIndex, stops, "patternStopIndex")
        let shapes = raw.shapeGTFSID.count
        try below(raw.patternShape, shapes, allowNone: true, "patternShape")
        try offsets(raw.shapePointStart, count: shapes, total: raw.shapeLatE6.count, "shapePointStart")
        try check(raw.shapeLonE6.count == raw.shapeLatE6.count, "shape point arrays differ in length")
        for pattern in 0..<patterns {
            let stopCount = Int(raw.patternStopStart[pattern + 1] - raw.patternStopStart[pattern])
            let tripCount = Int(raw.patternTripStart[pattern + 1] - raw.patternTripStart[pattern])
            try check(stopCount >= 1, "pattern without stops")
            let (events, overflow) = stopCount.multipliedReportingOverflow(by: tripCount)
            try check(!overflow, "pattern event count overflows")
            let departureStart = Int(raw.patternDepartureStart[pattern])
            try check(departureStart <= raw.departures.count && events <= raw.departures.count - departureStart,
                      "pattern departures out of range")
            let arrivalStart = raw.patternArrivalStart[pattern]
            if arrivalStart != TimetableFormat.none {
                try check(Int(arrivalStart) <= raw.arrivals.count && events <= raw.arrivals.count - Int(arrivalStart),
                          "pattern arrivals out of range")
            }
            if raw.patternShape[pattern] != TimetableFormat.none {
                let shape = Int(raw.patternShape[pattern])
                let points = raw.shapePointStart[shape + 1] - raw.shapePointStart[shape]
                for slot in Int(raw.patternStopStart[pattern])..<Int(raw.patternStopStart[pattern + 1]) {
                    let vertex = raw.patternStopShapeVertex[slot]
                    try check(vertex == TimetableFormat.none || vertex < points, "shape vertex out of range")
                }
            }
            for trip in Int(raw.patternTripStart[pattern])..<Int(raw.patternTripStart[pattern + 1]) {
                try check(raw.tripPattern[trip] == UInt32(pattern), "trip outside its pattern's range")
            }
        }

        try same([trips, raw.tripRule.count, raw.tripGTFSID.count, raw.tripHeadsign.count, raw.tripShortName.count,
                  raw.tripDirection.count, raw.tripIDOrder.count], "trip")
        try below(raw.tripRule, rules, "tripRule")
        try below(raw.tripIDOrder, trips, "tripIDOrder")
        try check(raw.stopIDOrder.count == stops, "stopIDOrder length")
        try below(raw.stopIDOrder, stops, "stopIDOrder")

        try offsets(raw.stopPatternStart, count: stops, total: raw.stopPatternRef.count, "stopPatternStart")
        try check(raw.stopPatternPosition.count == raw.stopPatternRef.count, "stop pattern arrays differ in length")
        for index in 0..<raw.stopPatternRef.count {
            let pattern = Int(raw.stopPatternRef[index])
            try check(pattern < patterns, "stopPatternRef out of range")
            try check(raw.stopPatternPosition[index] < raw.patternStopStart[pattern + 1] - raw.patternStopStart[pattern],
                      "stopPatternPosition out of range")
        }

        let transfers = raw.transferFromStop.count
        try same([transfers, raw.transferToStop.count, raw.transferFromTrip.count, raw.transferToTrip.count,
                  raw.transferType.count, raw.transferMinSeconds.count], "transfer")
        try below(raw.transferFromStop, stops, "transferFromStop")
        try below(raw.transferToStop, stops, "transferToStop")
        try below(raw.transferFromTrip, trips, allowNone: true, "transferFromTrip")
        try below(raw.transferToTrip, trips, allowNone: true, "transferToTrip")

        try same([raw.subwayKeyTrip.count, raw.subwayKeyRoute.count, raw.subwayKeyDirection.count,
                  raw.subwayKeyOrigin.count, raw.subwayKeyPath.count], "subway key")
        try below(raw.subwayKeyTrip, trips, "subwayKeyTrip")
    }
}
