/// GTFS service-day evaluation shared by the compiler and the reader.
///
/// Days are integers: days since 1970-01-01 (``BRCore/ServiceDate/daysSinceEpoch``).
public enum ServiceCalendar {
    /// Bit index of a day in a `calendar.txt` weekday mask: 0 = Monday … 6 = Sunday.
    @inline(__always)
    public static func weekdayBit(ofDay day: Int) -> Int {
        // 1970-01-01 was a Thursday (index 3).
        ((day + 3) % 7 + 7) % 7
    }

    /// Whether one rule runs on `day` by the GTFS rules alone (ignoring source selection):
    /// an exception on that day wins; otherwise the `calendar.txt` row applies if there is one.
    ///
    /// - Parameters:
    ///   - weekdays: bit 0 = Monday … bit 6 = Sunday; bit 7 set when a `calendar.txt` row exists.
    ///   - exceptionDays: the rule's exception days, ascending.
    ///   - exceptionTypes: `1` added, `2` removed, parallel to `exceptionDays`.
    public static func ruleRuns<Days: RandomAccessCollection, Types: RandomAccessCollection>(
        weekdays: UInt8, startDay: Int32, endDay: Int32,
        exceptionDays: Days, exceptionTypes: Types, day: Int32
    ) -> Bool where Days.Element == Int32, Types.Element == UInt8, Days.Index == Int, Types.Index == Int {
        var low = exceptionDays.startIndex, high = exceptionDays.endIndex
        while low < high {
            let mid = (low + high) / 2
            if exceptionDays[mid] < day { low = mid + 1 } else { high = mid }
        }
        if low < exceptionDays.endIndex, exceptionDays[low] == day {
            let offset = low - exceptionDays.startIndex
            return exceptionTypes[exceptionTypes.startIndex + offset] == 1
        }
        guard weekdays & ruleHasCalendarBit != 0, day >= startDay, day <= endDay else { return false }
        return weekdays & (1 << UInt8(weekdayBit(ofDay: Int(day)))) != 0
    }

    /// Days on which every slot has a selected source: the system's schedule coverage. A date
    /// where one bus zip has lapsed is not covered, so callers extrapolate that zip (coverage
    /// policy step 2) instead of silently losing its routes.
    public static func completeCoverage(slotCoverage: [DayBitset], dayCount: Int) -> DayBitset {
        guard var all = slotCoverage.first else { return DayBitset(dayCount: dayCount) }
        for bits in slotCoverage.dropFirst() { all.formIntersection(bits) }
        return all
    }
}

/// A fixed-length set of window days, stored as `u64` words (bit `d % 64` of word `d / 64`).
public struct DayBitset: Hashable, Sendable {
    public private(set) var words: [UInt64]
    public let dayCount: Int

    public init(dayCount: Int) {
        precondition(dayCount >= 0, "dayCount must not be negative")
        self.dayCount = dayCount
        words = [UInt64](repeating: 0, count: Self.wordCount(forDays: dayCount))
    }

    public init(words: [UInt64], dayCount: Int) {
        precondition(words.count == Self.wordCount(forDays: dayCount), "word count does not match dayCount")
        self.words = words
        self.dayCount = dayCount
    }

    public static func wordCount(forDays days: Int) -> Int { (days + 63) / 64 }

    public subscript(day: Int) -> Bool {
        get {
            guard day >= 0, day < dayCount else { return false }
            return words[day >> 6] & (1 << UInt64(day & 63)) != 0
        }
        set {
            precondition(day >= 0 && day < dayCount, "day out of range")
            if newValue {
                words[day >> 6] |= 1 << UInt64(day & 63)
            } else {
                words[day >> 6] &= ~(1 << UInt64(day & 63))
            }
        }
    }

    public var isEmpty: Bool { words.allSatisfy { $0 == 0 } }
    public var count: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    public func intersects(_ other: DayBitset) -> Bool {
        zip(words, other.words).contains { $0 & $1 != 0 }
    }

    public mutating func formUnion(_ other: DayBitset) {
        for index in words.indices { words[index] |= other.words[index] }
    }

    public mutating func formIntersection(_ other: DayBitset) {
        for index in words.indices { words[index] &= other.words[index] }
    }

    /// The day of the last set bit, or `nil` when empty.
    public var lastDay: Int? {
        for index in words.indices.reversed() where words[index] != 0 {
            return index * 64 + 63 - words[index].leadingZeroBitCount
        }
        return nil
    }

    public mutating func subtract(_ other: DayBitset) {
        for index in words.indices { words[index] &= ~other.words[index] }
    }

    /// Set days in ascending order.
    public var days: [Int] { (0..<dayCount).filter { self[$0] } }
}
