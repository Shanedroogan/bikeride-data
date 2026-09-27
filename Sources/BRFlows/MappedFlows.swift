import BRCore
import BRData
import Foundation

/// The `flows` artifact, memory-mapped: per Citi Bike station (keyed by GBFS `short_name`), 15-minute
/// bin, day type, direction and bike type, the smoothed mean and variance of trip counts. Layout
/// and the smoothing: `docs/formats.md` ("flows").
///
/// Rows are keys in ascending byte order, not `stations` indices: stations rebuild weekly and their
/// indices move. Join once per data set with ``rowTable(forKeys:)`` on `stations.bin`'s short names
/// (``FlowsFormat/noRow`` marks stations without flows).
///
/// ## Thread safety
/// `@unchecked Sendable` is sound because every stored property is immutable after `init`, and the
/// buffer pointers view bytes that this object keeps alive (the mapping, or a private aligned copy
/// it owns) and never writes.
public final class MappedFlows: @unchecked Sendable {
    /// The raw artifact's file name inside a data directory such as `build/data`.
    public static let fileName = "flows.bin"

    public let header: ArtifactHeader
    public let payloadRevision: UInt32
    public let departureWindow: FlowWindow
    public let arrivalWindow: FlowWindow
    public let flags: FlowsInfoFlags
    public let smoothing: FlowSmoothingParameters
    /// Weekdays inside the windows that the builder treated as weekend days (holidays with the
    /// `weekend` profile). Only covers the windows: classify other dates with the shared calendar.
    public let holidays: [ServiceDate]
    /// Number of keys (rows).
    public let count: Int

    private let storage: Data
    private let ownedCopy: UnsafeMutableRawBufferPointer?
    private let layout: FlowsLayout

    public static func load(fromDataDirectory directory: URL, validate: Bool = true) throws -> MappedFlows {
        try MappedFlows(contentsOf: directory.appendingPathComponent(fileName), validate: validate)
    }

    public convenience init(contentsOf url: URL, validate: Bool = true) throws {
        try self.init(artifact: MappedArtifact(contentsOf: url), validate: validate)
    }

    /// Checks the header, then every section length, key, window and cell (with `validate`; without
    /// it, only the structure an accessor relies on to stay in bounds).
    public init(artifact: MappedArtifact, validate: Bool = true) throws {
        guard artifact.kind == .flows else { throw FlowsFormatError.notFlows(found: artifact.kind.rawValue) }
        guard ArtifactKind.flows.supportedFormatVersions.contains(artifact.header.formatVersion) else {
            throw FlowsFormatError.unsupportedFormatVersion(artifact.header.formatVersion)
        }
        header = artifact.header
        storage = artifact.payload

        let length = storage.count
        let inPlace: UnsafeRawPointer? = storage.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, Int(bitPattern: base) % 8 == 0, length > 64 else { return nil }
            return base
        }
        var copy: UnsafeMutableRawBufferPointer?
        let base: UnsafeRawPointer
        if let inPlace {
            base = inPlace
        } else {
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(length, 8), alignment: 8)
            storage.withUnsafeBytes { bytes in
                if let source = bytes.baseAddress, length > 0 { buffer.baseAddress!.copyMemory(from: source, byteCount: length) }
            }
            copy = buffer
            base = UnsafeRawPointer(buffer.baseAddress!)
        }
        ownedCopy = copy
        do {
            layout = try FlowsLayout(base: base, length: length, validate: validate)
        } catch {
            copy?.deallocate()
            throw error
        }
        payloadRevision = layout.revision
        departureWindow = layout.departureWindow
        arrivalWindow = layout.arrivalWindow
        flags = layout.flags
        smoothing = layout.smoothing
        holidays = layout.holidays.map { ServiceDate(daysSinceEpoch: Int($0)) }
        count = layout.keyCount
    }

    deinit {
        ownedCopy?.deallocate()
    }

    // MARK: - Keys and the stations join

    /// The key (GBFS `short_name`) of `row`.
    public func key(_ row: Int) -> String {
        String(decoding: keyBytes(row), as: UTF8.self)
    }

    /// The row of a key, by binary search on the key bytes; `nil` when the file has no such key.
    public func row(forKey key: String) -> Int? {
        var key = key
        return key.withUTF8 { row(forKeyBytes: $0) }
    }

    public func row(forKeyBytes key: UnsafeBufferPointer<UInt8>) -> Int? {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            let candidate = keyBytes(mid)
            if candidate.elementsEqual(key) { return mid }
            if candidate.lexicographicallyPrecedes(key) { low = mid + 1 } else { high = mid }
        }
        return nil
    }

    /// Row per given key, or ``FlowsFormat/noRow``: pass `stations.bin`'s short names in station
    /// order to get the station index → flows row table (the only join; never store rows elsewhere).
    public func rowTable(forKeys keys: some Sequence<String>) -> [UInt16] {
        keys.map { key in row(forKey: key).map { UInt16($0) } ?? FlowsFormat.noRow }
    }

    // MARK: - Station metadata

    public func latE6(_ row: Int) -> Int32 { layout.latE6[row] }
    public func lonE6(_ row: Int) -> Int32 { layout.lonE6[row] }
    public func capacity(_ row: Int) -> UInt16 { layout.capacity[row] }

    /// Days of `dayType` on which the station counted for `direction`: the denominator of its means.
    public func activeDays(_ row: Int, _ dayType: FlowDayType, _ direction: FlowDirection) -> Int {
        Int(layout.activeDays[FlowsFormat.activeDaysIndex(row: row, dayType: dayType, direction: direction)])
    }

    /// The row's flags, with undefined bits masked off.
    public func flags(_ row: Int) -> FlowStationFlags {
        FlowStationFlags(rawValue: layout.stationFlags[row]).intersection(.known)
    }

    // MARK: - Cells

    /// One stored value (per 15-minute bin), exact.
    @inline(__always)
    public func value(_ row: Int, _ dayType: FlowDayType, _ direction: FlowDirection, _ slot: FlowSlot, bin: Int) -> Float {
        precondition(bin >= 0 && bin < FlowsFormat.binsPerDay, "bin out of range")
        return HalfFloat.float(fromBits: layout.cells[FlowsFormat.cellIndex(row: row, dayType: dayType, direction: direction, slot: slot, bin: bin)])
    }

    /// Mean trips of one bike type in one 15-minute bin.
    public func mean(_ row: Int, _ dayType: FlowDayType, _ direction: FlowDirection, _ bikeType: FlowBikeType, bin: Int) -> Float {
        value(row, dayType, direction, .mean(bikeType), bin: bin)
    }

    /// Variance of one bike type's count in one bin; never below the mean.
    public func variance(_ row: Int, _ dayType: FlowDayType, _ direction: FlowDirection, _ bikeType: FlowBikeType, bin: Int) -> Float {
        value(row, dayType, direction, .variance(bikeType), bin: bin)
    }

    /// Mean of the classic + e-bike count in one bin (the two means' sum).
    public func meanAny(_ row: Int, _ dayType: FlowDayType, _ direction: FlowDirection, bin: Int) -> Double {
        Double(mean(row, dayType, direction, .classic, bin: bin)) + Double(mean(row, dayType, direction, .ebike, bin: bin))
    }

    /// Variance of the classic + e-bike count in one bin; never below ``meanAny(_:_:_:bin:)``.
    public func varianceAny(_ row: Int, _ dayType: FlowDayType, _ direction: FlowDirection, bin: Int) -> Float {
        value(row, dayType, direction, .varianceAny, bin: bin)
    }

    /// The 96 binary16 bit patterns of one series, in place. The pointer must not escape `body`.
    public func withSeries<R>(
        _ row: Int, _ dayType: FlowDayType, _ direction: FlowDirection, _ slot: FlowSlot,
        _ body: (UnsafeBufferPointer<UInt16>) throws -> R
    ) rethrows -> R {
        let start = FlowsFormat.cellIndex(row: row, dayType: dayType, direction: direction, slot: slot, bin: 0)
        return try body(UnsafeBufferPointer(rebasing: layout.cells[start..<start + FlowsFormat.binsPerDay]))
    }

    /// Weekday or weekend for a date inside the windows (``holidays`` plus Saturdays and Sundays).
    /// Outside the windows the file cannot tell a holiday from an ordinary weekday.
    public func dayType(of date: ServiceDate) -> FlowDayType {
        if date.weekday == .saturday || date.weekday == .sunday { return .weekend }
        return holidays.contains(date) ? .weekend : .weekday
    }
}

// MARK: - Section table and validation

/// The sections of a `flows` payload viewed in place, checked once. Shared by ``MappedFlows`` and
/// the writer (``FlowsData/encodedPayload()``), so the writer can never produce a file the reader
/// refuses.
struct FlowsLayout {
    let revision: UInt32
    let departureWindow: FlowWindow
    let arrivalWindow: FlowWindow
    let flags: FlowsInfoFlags
    let smoothing: FlowSmoothingParameters
    let holidays: UnsafeBufferPointer<Int32>
    let keyOffsets: UnsafeBufferPointer<UInt32>
    let keyBytes: UnsafeBufferPointer<UInt8>
    let latE6: UnsafeBufferPointer<Int32>
    let lonE6: UnsafeBufferPointer<Int32>
    let capacity: UnsafeBufferPointer<UInt16>
    let activeDays: UnsafeBufferPointer<UInt16>
    let stationFlags: UnsafeBufferPointer<UInt8>
    let cells: UnsafeBufferPointer<UInt16>
    var keyCount: Int { capacity.count }

    init(base: UnsafeRawPointer, length: Int, validate: Bool) throws {
        let table = try FlowsSectionTable(base: base, length: length)
        revision = table.revision
        guard revision == FlowsFormat.payloadRevision else { throw FlowsFormatError.unsupportedPayloadRevision(revision) }
        try table.checkPaddingAndOverlap()

        let info: UnsafeBufferPointer<Int64> = try table.view(.info)
        guard info.count >= FlowsInfoField.allCases.count else {
            throw FlowsFormatError.countMismatch(.info, expected: FlowsInfoField.allCases.count, actual: info.count)
        }
        func field(_ field: FlowsInfoField) -> Int64 { info[field.rawValue] }
        func require(_ field: FlowsInfoField, _ condition: (Int64) -> Bool) throws {
            guard condition(info[field.rawValue]) else { throw FlowsFormatError.invalidInfo(field, info[field.rawValue]) }
        }
        try require(.binMinutes) { $0 == Int64(FlowsFormat.binMinutes) }
        try require(.binsPerDay) { $0 == Int64(FlowsFormat.binsPerDay) }
        try require(.dayTypes) { $0 == Int64(FlowsFormat.dayTypeCount) }
        try require(.bikeTypes) { $0 == Int64(FlowsFormat.bikeTypeCount) }
        try require(.slotsPerSeries) { $0 == Int64(FlowsFormat.slotCount) }
        // Days 0001-01-01 … 9999-12-31, windows of 1 to 400 days (the build uses about 92).
        let dayRange: ClosedRange<Int64> = -719_162...2_932_896
        for (start, count) in [(FlowsInfoField.departureWindowStartDay, FlowsInfoField.departureWindowDayCount),
                               (.arrivalWindowStartDay, .arrivalWindowDayCount)] {
            try require(start) { dayRange.contains($0) }
            try require(count) { (1...400).contains($0) && dayRange.contains(field(start) + $0 - 1) }
        }
        for kappa in [FlowsInfoField.kappaCellMilli, .kappaHourMilli, .kappaDispersionMilli, .neighborCount, .neighborRadiusMeters] {
            try require(kappa) { $0 >= 0 }
        }
        departureWindow = FlowWindow(start: ServiceDate(daysSinceEpoch: Int(field(.departureWindowStartDay))),
                                     dayCount: Int(field(.departureWindowDayCount)))
        arrivalWindow = FlowWindow(start: ServiceDate(daysSinceEpoch: Int(field(.arrivalWindowStartDay))),
                                   dayCount: Int(field(.arrivalWindowDayCount)))
        flags = FlowsInfoFlags(rawValue: field(.flags)).intersection(.known)
        smoothing = FlowSmoothingParameters(
            kappaCellMilli: field(.kappaCellMilli), kappaHourMilli: field(.kappaHourMilli),
            kappaDispersionMilli: field(.kappaDispersionMilli), neighborCount: field(.neighborCount),
            neighborRadiusMeters: field(.neighborRadiusMeters)
        )

        holidays = try table.view(.holidays)
        keyOffsets = try table.view(.keyOffsets)
        keyBytes = try table.view(.keyBytes)
        capacity = try table.view(.stationCapacity)
        let keys = capacity.count
        guard keys <= FlowsFormat.maxKeys else { throw FlowsFormatError.tooManyKeys(keys) }
        latE6 = try table.view(.stationLatE6, count: keys)
        lonE6 = try table.view(.stationLonE6, count: keys)
        activeDays = try table.view(.stationActiveDays, count: keys * FlowsFormat.dayTypeCount * FlowsFormat.directionCount)
        stationFlags = try table.view(.stationFlags, count: keys)
        cells = try table.view(.cells, count: keys * FlowsFormat.cellsPerKey)
        guard keyOffsets.count == keys + 1 else { throw FlowsFormatError.countMismatch(.keyOffsets, expected: keys + 1, actual: keyOffsets.count) }
        // Accessors slice keys by these offsets, so they are checked even without `validate`.
        guard keyOffsets[0] == 0, Int(keyOffsets[keys]) == keyBytes.count else { throw FlowsFormatError.invalidKeyOffsets }
        for row in 0..<keys where keyOffsets[row] > keyOffsets[row + 1] { throw FlowsFormatError.invalidKeyOffsets }

        guard validate else { return }
        try checkKeys()
        try checkHolidays()
        try checkActiveDays()
        try checkCells()
    }

    func keyBytes(_ row: Int) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: keyBytes[Int(keyOffsets[row])..<Int(keyOffsets[row + 1])])
    }

    private func checkKeys() throws {
        for row in 0..<keyCount {
            let key = keyBytes(row)
            guard !key.isEmpty, String(bytes: key, encoding: .utf8) != nil else { throw FlowsFormatError.invalidKey(row: row) }
            if row > 0, !keyBytes(row - 1).lexicographicallyPrecedes(key) { throw FlowsFormatError.keysNotSorted(row: row) }
        }
    }

    private func checkHolidays() throws {
        let first = min(departureWindow.start.daysSinceEpoch, arrivalWindow.start.daysSinceEpoch)
        let last = max(departureWindow.end.daysSinceEpoch, arrivalWindow.end.daysSinceEpoch)
        for (index, day) in holidays.enumerated() {
            if index > 0, holidays[index - 1] >= day { throw FlowsFormatError.holidaysNotSorted(index: index) }
            guard Int(day) >= first, Int(day) <= last else { throw FlowsFormatError.holidayOutsideWindow(index: index) }
        }
    }

    /// Days of each type per direction window: no station can be active on more.
    private func checkActiveDays() throws {
        let holidaySet = Set(holidays.map(Int.init))
        func days(_ window: FlowWindow) -> [Int] {
            var counts = [0, 0]
            for offset in 0..<window.dayCount {
                let date = window.start.adding(days: offset)
                let weekend = date.weekday == .saturday || date.weekday == .sunday || holidaySet.contains(date.daysSinceEpoch)
                counts[weekend ? 1 : 0] += 1
            }
            return counts
        }
        let limits = [days(departureWindow), days(arrivalWindow)] // [direction][dayType]
        for row in 0..<keyCount {
            for dayType in FlowDayType.allCases {
                for direction in FlowDirection.allCases {
                    let value = Int(activeDays[FlowsFormat.activeDaysIndex(row: row, dayType: dayType, direction: direction)])
                    guard value <= limits[direction.index][dayType.index] else { throw FlowsFormatError.activeDaysOutOfRange(row: row) }
                }
            }
        }
    }

    /// Every cell finite and non-negative; each variance at least its mean. For non-negative halves
    /// the bit patterns order like the values, so the typed checks compare bits; the any-type check
    /// compares exact decoded sums.
    private func checkCells() throws {
        let bins = FlowsFormat.binsPerDay
        let seriesCount = keyCount * FlowsFormat.dayTypeCount * FlowsFormat.directionCount
        for series in 0..<seriesCount {
            let base = series * FlowsFormat.slotCount * bins
            for bin in 0..<bins {
                let meanC = cells[base + FlowSlot.meanClassic.index * bins + bin]
                let varC = cells[base + FlowSlot.varianceClassic.index * bins + bin]
                let meanE = cells[base + FlowSlot.meanEbike.index * bins + bin]
                let varE = cells[base + FlowSlot.varianceEbike.index * bins + bin]
                let varA = cells[base + FlowSlot.varianceAny.index * bins + bin]
                for (slot, bits) in [(FlowSlot.meanClassic, meanC), (.varianceClassic, varC), (.meanEbike, meanE), (.varianceEbike, varE), (.varianceAny, varA)]
                where !HalfFloat.isFiniteNonNegative(bits) {
                    throw FlowsFormatError.invalidCell(index: base + slot.index * bins + bin)
                }
                if varC < meanC { throw FlowsFormatError.varianceBelowMean(index: base + FlowSlot.varianceClassic.index * bins + bin) }
                if varE < meanE { throw FlowsFormatError.varianceBelowMean(index: base + FlowSlot.varianceEbike.index * bins + bin) }
                if HalfFloat.double(fromBits: varA) < HalfFloat.double(fromBits: meanC) + HalfFloat.double(fromBits: meanE) {
                    throw FlowsFormatError.varianceBelowMean(index: base + FlowSlot.varianceAny.index * bins + bin)
                }
            }
        }
    }
}

/// The preamble and table of contents.
struct FlowsSectionTable {
    let base: UnsafeRawPointer
    let length: Int
    let revision: UInt32
    let tocEnd: Int
    private(set) var entries: [UInt32: (elementSize: UInt32, offset: UInt64, count: UInt64)] = [:]

    init(base: UnsafeRawPointer, length: Int) throws {
        self.base = base
        self.length = length
        guard length >= FlowsFormat.preambleSize else { throw FlowsFormatError.truncated }
        for (index, byte) in FlowsFormat.magic.enumerated() where base.load(fromByteOffset: index, as: UInt8.self) != byte {
            throw FlowsFormatError.badMagic
        }
        revision = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let count = Int(base.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        guard base.loadUnaligned(fromByteOffset: 12, as: UInt32.self) == 0 else { throw FlowsFormatError.nonZeroPadding(offset: 12) }
        guard count <= FlowsFormat.maxSections, FlowsFormat.preambleSize + count * FlowsFormat.tocEntrySize <= length else {
            throw FlowsFormatError.truncated
        }
        tocEnd = FlowsFormat.preambleSize + count * FlowsFormat.tocEntrySize
        for index in 0..<count {
            let entry = FlowsFormat.preambleSize + index * FlowsFormat.tocEntrySize
            let id = base.loadUnaligned(fromByteOffset: entry, as: UInt32.self)
            let size = base.loadUnaligned(fromByteOffset: entry + 4, as: UInt32.self)
            let offset = base.loadUnaligned(fromByteOffset: entry + 8, as: UInt64.self)
            let elements = base.loadUnaligned(fromByteOffset: entry + 16, as: UInt64.self)
            guard entries.updateValue((size, offset, elements), forKey: id) == nil else { throw FlowsFormatError.duplicateSection(id) }
        }
    }

    func view<T>(_ section: FlowsSection, count expected: Int? = nil) throws -> UnsafeBufferPointer<T> {
        guard let entry = entries[section.rawValue] else { throw FlowsFormatError.missingSection(section) }
        let stride = MemoryLayout<T>.stride
        guard entry.elementSize == UInt32(section.elementSize), stride == section.elementSize else {
            throw FlowsFormatError.elementSizeMismatch(section, found: entry.elementSize)
        }
        guard entry.offset % 8 == 0 else { throw FlowsFormatError.misalignedSection(section) }
        let (bytes, overflow) = entry.count.multipliedReportingOverflow(by: UInt64(stride))
        guard !overflow, entry.offset <= UInt64(length), bytes <= UInt64(length) - entry.offset else {
            throw FlowsFormatError.sectionOutOfBounds(section.rawValue)
        }
        if let expected, entry.count != UInt64(expected) {
            throw FlowsFormatError.countMismatch(section, expected: expected, actual: Int(entry.count))
        }
        let start = (base + Int(entry.offset)).assumingMemoryBound(to: T.self)
        return UnsafeBufferPointer(start: entry.count == 0 ? nil : start, count: Int(entry.count))
    }

    /// Every byte after the table of contents that lies in no section (known or not) is zero, and
    /// sections do not overlap.
    func checkPaddingAndOverlap() throws {
        var extents: [(start: Int, end: Int, id: UInt32)] = []
        for (id, entry) in entries {
            let (bytes, overflow) = entry.count.multipliedReportingOverflow(by: UInt64(entry.elementSize))
            guard !overflow, entry.offset <= UInt64(length), bytes <= UInt64(length) - entry.offset else {
                throw FlowsFormatError.sectionOutOfBounds(id)
            }
            extents.append((Int(entry.offset), Int(entry.offset + bytes), id))
        }
        extents.sort { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        func zero(_ range: Range<Int>) throws {
            for offset in range where base.load(fromByteOffset: offset, as: UInt8.self) != 0 {
                throw FlowsFormatError.nonZeroPadding(offset: offset)
            }
        }
        var cursor = tocEnd
        for extent in extents {
            guard extent.start >= cursor else { throw FlowsFormatError.sectionsOverlap(extent.id) }
            try zero(cursor..<extent.start)
            cursor = extent.end
        }
        try zero(cursor..<length)
    }
}

extension MappedFlows {
    fileprivate func keyBytes(_ row: Int) -> UnsafeBufferPointer<UInt8> {
        layout.keyBytes(row)
    }
}
