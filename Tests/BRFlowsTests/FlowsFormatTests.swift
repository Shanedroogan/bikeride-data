import BRCore
import BRData
@testable import BRFlows
import Foundation
import Testing

/// The `flows` writer and reader (docs/formats.md, "flows"). The payload golden, the committed v1
/// file and the format gates are in ``FlowsV1Tests``.
@Suite struct FlowsFormatTests {
    func reader(_ file: Data, validate: Bool = true) throws -> MappedFlows {
        try MappedFlows(artifact: MappedArtifact(fileBytes: file, expecting: .flows), validate: validate)
    }

    /// The payload bytes of `data` without validation, assembled into a file.
    func unchecked(_ data: FlowsData) -> Data {
        ArtifactHeader(kind: .flows, formatVersion: ArtifactKind.flows.currentFormatVersion, dataVersion: "x", builderSwiftVersion: "6.4")
            .assemble(payload: data.encodedSections())
    }

    @Test func roundTripsEveryValue() throws {
        let data = HandBuiltFlows.data()
        let flows = try reader(try HandBuiltFlows.artifact(data))
        #expect(flows.count == 3 && flows.payloadRevision == FlowsFormat.payloadRevision)
        #expect(flows.departureWindow == HandBuiltFlows.window && flows.arrivalWindow == HandBuiltFlows.window)
        #expect(flows.departureWindow.end == date("20260831"))
        #expect(flows.flags == [.customerTripsOnly] && flows.smoothing == HandBuiltFlows.smoothing)
        #expect(flows.holidays == [date("20260703")])
        #expect((0..<3).map(flows.key) == HandBuiltFlows.keys)
        #expect(flows.latE6(2) == 40_702_000 && flows.lonE6(2) == -74_004_000 && flows.capacity(1) == 10)
        #expect(flows.activeDays(1, .weekday, .departures) == 61 && flows.activeDays(1, .weekday, .arrivals) == 62)
        #expect(flows.activeDays(2, .weekend, .departures) == 22 && flows.activeDays(2, .weekend, .arrivals) == 23)
        #expect(flows.flags(0) == [.inGBFS, .lowData] && flows.flags(1) == [.inGBFS])
        for row in 0..<3 {
            for dayType in FlowDayType.allCases {
                for direction in FlowDirection.allCases {
                    for bin in [0, 1, 37, 95] {
                        for slot in FlowSlot.allCases {
                            #expect(Double(flows.value(row, dayType, direction, slot, bin: bin)) == HandBuiltFlows.value(row, dayType, direction, slot, bin))
                        }
                        #expect(flows.meanAny(row, dayType, direction, bin: bin)
                            == HandBuiltFlows.value(row, dayType, direction, .meanClassic, bin) + HandBuiltFlows.value(row, dayType, direction, .meanEbike, bin))
                        #expect(flows.variance(row, dayType, direction, .ebike, bin: bin) == Float(HandBuiltFlows.value(row, dayType, direction, .varianceEbike, bin)))
                    }
                    flows.withSeries(row, dayType, direction, .meanClassic) { series in
                        #expect(series.count == 96 && HalfFloat.double(fromBits: series[4]) == HandBuiltFlows.value(row, dayType, direction, .meanClassic, 4))
                    }
                }
            }
        }
        #expect(flows.dayType(of: date("20260703")) == .weekend && flows.dayType(of: date("20260704")) == .weekend)
        #expect(flows.dayType(of: date("20260702")) == .weekday)
    }

    @Test func joinsStationsByShortNameBytes() throws {
        let flows = try reader(try HandBuiltFlows.artifact())
        #expect(flows.row(forKey: "5329.08") == 1 && flows.row(forKey: "3576.1") == 0 && flows.row(forKey: "JC115") == 2)
        // Byte-exact: no pad-0 repair, no trimming, no case folding at read time.
        for missing in ["5329.8", "3576.10", "jc115", "JC115 ", "", "0", "ZZZ"] {
            #expect(flows.row(forKey: missing) == nil, "\(missing)")
        }
        #expect(flows.rowTable(forKeys: ["JC115", "nope", "3576.1", "5329.08", "5329.080"]) == [2, FlowsFormat.noRow, 0, 1, FlowsFormat.noRow])
        #expect(FlowsFormat.noRow == 0xFFFF)
    }

    @Test func writerRefusesAndReaderRejectsUnsortedOrDuplicateKeys() throws {
        let unsorted = HandBuiltFlows.data(keys: ["5329.08", "3576.1", "JC115"])
        #expect(throws: FlowsFormatError.keysNotSorted(row: 1)) { try unsorted.encodedPayload() }
        #expect(throws: FlowsFormatError.keysNotSorted(row: 1)) { try reader(unchecked(unsorted)) }
        let duplicate = HandBuiltFlows.data(keys: ["3576.1", "3576.1", "JC115"])
        #expect(throws: FlowsFormatError.keysNotSorted(row: 1)) { try reader(unchecked(duplicate)) }
        // Bytes, not String order: "Z" (0x5A) sorts before "a" (0x61), and "é" after both.
        _ = try reader(try HandBuiltFlows.artifact(HandBuiltFlows.data(keys: ["Z", "a", "é"])))
        #expect(throws: FlowsFormatError.invalidKey(row: 0)) { try reader(unchecked(HandBuiltFlows.data(keys: ["", "a", "b"]))) }
        // Structure only without validation: the unsorted file opens.
        #expect(try reader(unchecked(unsorted), validate: false).count == 3)
    }

    @Test func rejectsVarianceBelowMeanAndNonFiniteCells() throws {
        func mutated(_ slot: FlowSlot, bin: Int = 5, row: Int = 1, _ bits: UInt16) -> FlowsData {
            var data = HandBuiltFlows.data()
            data.cells[FlowsFormat.cellIndex(row: row, dayType: .weekend, direction: .arrivals, slot: slot, bin: bin)] = bits
            return data
        }
        let index = { (slot: FlowSlot) in FlowsFormat.cellIndex(row: 1, dayType: .weekend, direction: .arrivals, slot: slot, bin: 5) }
        let meanBits = HandBuiltFlows.data().cells[index(.meanClassic)]
        #expect(meanBits != 0)
        #expect(throws: FlowsFormatError.varianceBelowMean(index: index(.varianceClassic))) { try reader(unchecked(mutated(.varianceClassic, meanBits - 1))) }
        #expect(throws: FlowsFormatError.varianceBelowMean(index: index(.varianceClassic))) {
            try mutated(.varianceClassic, meanBits - 1).encodedPayload()
        }
        _ = try reader(unchecked(mutated(.varianceClassic, meanBits))) // equal is fine (Poisson)
        #expect(throws: FlowsFormatError.varianceBelowMean(index: index(.varianceEbike))) { try reader(unchecked(mutated(.varianceEbike, 0))) }
        // varianceAny must cover meanClassic + meanEbike, compared exactly.
        let data = HandBuiltFlows.data()
        let sum = HalfFloat.double(fromBits: data.cells[index(.meanClassic)]) + HalfFloat.double(fromBits: data.cells[index(.meanEbike)])
        let below = HalfFloat.bits(from: sum) - 1
        #expect(throws: FlowsFormatError.varianceBelowMean(index: index(.varianceAny))) { try reader(unchecked(mutated(.varianceAny, below))) }
        for bad: UInt16 in [0x7C00, 0x7E00, 0x7C01, 0xFC00, 0x8000, 0xBC00] {
            #expect(throws: FlowsFormatError.invalidCell(index: index(.meanEbike))) { try reader(unchecked(mutated(.meanEbike, bad))) }
        }
    }

    @Test func rejectsPlaneLengthMismatches() throws {
        var short = HandBuiltFlows.data()
        short.cells.removeLast()
        #expect(throws: FlowsFormatError.countMismatch(.cells, expected: 3 * FlowsFormat.cellsPerKey, actual: 3 * FlowsFormat.cellsPerKey - 1)) {
            try reader(unchecked(short))
        }
        #expect(throws: FlowsFormatError.countMismatch(.cells, expected: 3 * FlowsFormat.cellsPerKey, actual: 3 * FlowsFormat.cellsPerKey - 1)) {
            try short.encodedPayload()
        }
        var long = HandBuiltFlows.data()
        long.cells += [UInt16](repeating: 0, count: FlowsFormat.binsPerDay)
        #expect(throws: FlowsFormatError.countMismatch(.cells, expected: 3 * FlowsFormat.cellsPerKey, actual: 3 * FlowsFormat.cellsPerKey + 96)) {
            try reader(unchecked(long))
        }
        var days = HandBuiltFlows.data()
        days.stations[2].activeDays.removeLast()
        #expect(throws: FlowsFormatError.countMismatch(.stationActiveDays, expected: 12, actual: 11)) { try reader(unchecked(days)) }
    }

    @Test func rejectsBadWindowsHolidaysAndActiveDays() throws {
        var holidays = HandBuiltFlows.data()
        holidays.holidays = [date("20260703"), date("20260703")]
        #expect(throws: FlowsFormatError.holidaysNotSorted(index: 1)) { try reader(unchecked(holidays)) }
        holidays.holidays = [date("20260901")]
        #expect(throws: FlowsFormatError.holidayOutsideWindow(index: 0)) { try reader(unchecked(holidays)) }
        var days = HandBuiltFlows.data()
        // Jun–Aug 2026 has 65 weekdays once Jul 3 is a holiday, and 27 weekend days.
        days.stations[0].activeDays = [65, 65, 27, 27]
        _ = try reader(unchecked(days))
        days.stations[0].activeDays = [66, 65, 27, 27]
        #expect(throws: FlowsFormatError.activeDaysOutOfRange(row: 0)) { try reader(unchecked(days)) }
        days.stations[0].activeDays = [65, 65, 27, 28]
        #expect(throws: FlowsFormatError.activeDaysOutOfRange(row: 0)) { try reader(unchecked(days)) }
        var window = HandBuiltFlows.data()
        window.arrivalWindow.dayCount = 0
        #expect(throws: FlowsFormatError.invalidInfo(.arrivalWindowDayCount, 0)) { try reader(unchecked(window)) }
        var kappa = HandBuiltFlows.data()
        kappa.smoothing.kappaHourMilli = -1
        #expect(throws: FlowsFormatError.invalidInfo(.kappaHourMilli, -1)) { try reader(unchecked(kappa)) }
    }

    @Test func rejectsHeaderAndPreambleMismatches() throws {
        let file = try HandBuiltFlows.artifact()
        let (header, payload) = try ArtifactHeader.decode(from: file)
        let payloadData = Data(payload)
        for version: UInt16 in [0, 2] {
            var copy = file
            copy[copy.startIndex + 8] = UInt8(version)
            #expect(throws: FlowsFormatError.unsupportedFormatVersion(version)) { try reader(copy) }
        }
        for revision: UInt32 in [0, FlowsFormat.payloadRevision + 1] {
            #expect(throws: FlowsFormatError.unsupportedPayloadRevision(revision)) {
                try reader(header.assemble(payload: payloadData.replacing(revision, at: 4)))
            }
        }
        #expect(throws: FlowsFormatError.badMagic) { try reader(header.assemble(payload: payloadData.replacing(UInt8(ascii: "X"), at: 0))) }
        #expect(throws: FlowsFormatError.nonZeroPadding(offset: 12)) { try reader(header.assemble(payload: payloadData.replacing(UInt32(1), at: 12))) }
        #expect(throws: FlowsFormatError.truncated) { try reader(header.assemble(payload: payloadData.replacing(UInt32(5_000), at: 8))) }
        // A binMinutes other than 15 is a different layout.
        let infoOffset = Int(payloadData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16 + 8, as: UInt64.self) })
        #expect(throws: FlowsFormatError.invalidInfo(.binMinutes, 30)) {
            try reader(header.assemble(payload: payloadData.replacing(Int64(30), at: infoOffset + 8 * FlowsInfoField.binMinutes.rawValue)))
        }
        // Non-zero bytes between sections.
        let keyBytesEntry = 16 + 3 * 24
        let keyBytesOffset = Int(payloadData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: keyBytesEntry + 8, as: UInt64.self) })
        let keyBytesCount = Int(payloadData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: keyBytesEntry + 16, as: UInt64.self) })
        #expect(throws: FlowsFormatError.nonZeroPadding(offset: keyBytesOffset + keyBytesCount)) {
            try reader(header.assemble(payload: payloadData.replacing(UInt8(7), at: keyBytesOffset + keyBytesCount)))
        }
        let stations = ArtifactHeader(kind: .stations, formatVersion: 1, dataVersion: "x", builderSwiftVersion: "6.4").assemble(payload: payloadData)
        #expect(throws: FlowsFormatError.notFlows(found: 2)) { try MappedFlows(artifact: MappedArtifact(fileBytes: stations)) }
    }

    /// Table-of-contents damage, one patch each, chosen so the error named is the first one met
    /// (the padding and overlap pass runs before any section is viewed).
    @Test func rejectsMalformedSectionTables() throws {
        let (header, payload) = try ArtifactHeader.decode(from: HandBuiltFlows.artifact())
        let base = Data(payload)
        func load<T: FixedWidthInteger>(_ offset: Int, as type: T.Type) -> T { base.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) } }
        func entry(_ section: FlowsSection) -> Int {
            let at = (0..<Int(load(8, as: UInt32.self))).map { FlowsFormat.preambleSize + $0 * FlowsFormat.tocEntrySize }
            return at.first { load($0, as: UInt32.self) == section.rawValue }!
        }
        func offset(_ section: FlowsSection) -> UInt64 { load(entry(section) + 8, as: UInt64.self) }
        func count(_ section: FlowsSection) -> UInt64 { load(entry(section) + 16, as: UInt64.self) }
        func open(_ payload: Data) throws { _ = try reader(header.assemble(payload: payload)) }
        try open(base)

        // Repeated: a second `info`.
        #expect(throws: FlowsFormatError.duplicateSection(FlowsSection.info.rawValue)) {
            try open(base.replacing(FlowsSection.info.rawValue, at: entry(.holidays)))
        }
        // Missing: `holidays` renamed to an id no reader knows.
        #expect(throws: FlowsFormatError.missingSection(.holidays)) { try open(base.replacing(UInt32(99), at: entry(.holidays))) }
        // Misaligned: `keyOffsets` one byte early (the byte it takes and the byte it frees are both 0).
        #expect(throws: FlowsFormatError.misalignedSection(.keyOffsets)) {
            try open(base.replacing(offset(.keyOffsets) - 1, at: entry(.keyOffsets) + 8))
        }
        // Overlapping: `keyBytes` moved onto `keyOffsets`.
        #expect(throws: FlowsFormatError.sectionsOverlap(FlowsSection.keyBytes.rawValue)) {
            try open(base.replacing(offset(.keyOffsets), at: entry(.keyBytes) + 8))
        }
        // The wrong element size: `stationCapacity` as bytes over the same extent.
        #expect(throws: FlowsFormatError.elementSizeMismatch(.stationCapacity, found: 1)) {
            try open(base.replacing(UInt32(1), at: entry(.stationCapacity) + 4).replacing(count(.stationCapacity) * 2, at: entry(.stationCapacity) + 16))
        }
        // Out of bounds: one element past the end, a byte count that overflows, an offset past the end.
        let cells = FlowsSection.cells.rawValue
        #expect(throws: FlowsFormatError.sectionOutOfBounds(cells)) { try open(base.replacing(count(.cells) + 1, at: entry(.cells) + 16)) }
        #expect(throws: FlowsFormatError.sectionOutOfBounds(cells)) { try open(base.replacing(UInt64.max / 2 + 1, at: entry(.cells) + 16)) }
        #expect(throws: FlowsFormatError.sectionOutOfBounds(cells)) { try open(base.replacing(UInt64(base.count + 8), at: entry(.cells) + 8)) }
    }

    /// A row outside `0 ..< count` (``FlowsFormat/noRow`` from the stations join) stops the process
    /// instead of reading past a buffer, in release builds too.
    @Test func rowAccessorsStopOnARowOutOfRange() async {
        await #expect(processExitsWith: .failure) {
            // Exit 0 if the file does not open, so only the precondition can pass this test.
            guard let flows = try? MappedFlows(artifact: MappedArtifact(fileBytes: HandBuiltFlows.artifact(), expecting: .flows)) else { exit(0) }
            _ = flows.key(Int(FlowsFormat.noRow))
        }
        await #expect(processExitsWith: .failure) {
            guard let flows = try? MappedFlows(artifact: MappedArtifact(fileBytes: HandBuiltFlows.artifact(), expecting: .flows)) else { exit(0) }
            _ = flows.mean(flows.count, .weekday, .departures, .classic, bin: 0)
        }
        await #expect(processExitsWith: .failure) {
            guard let flows = try? MappedFlows(artifact: MappedArtifact(fileBytes: HandBuiltFlows.artifact(), expecting: .flows)) else { exit(0) }
            _ = flows.capacity(-1)
        }
    }

    @Test func skipsSectionsItDoesNotKnowAndInfoEntriesPastItsOwn() throws {
        let data = HandBuiltFlows.data()
        var sections = FlowsSectionWriter()
        var info = [Int64](repeating: 0, count: FlowsInfoField.allCases.count)
        let reference = data.encodedSections()
        let base = try reader(ArtifactHeader(kind: .flows, formatVersion: 1, dataVersion: "x", builderSwiftVersion: "6.4").assemble(payload: reference))
        info[FlowsInfoField.departureWindowStartDay.rawValue] = Int64(data.departureWindow.start.daysSinceEpoch)
        info[FlowsInfoField.departureWindowDayCount.rawValue] = 92
        info[FlowsInfoField.arrivalWindowStartDay.rawValue] = Int64(data.arrivalWindow.start.daysSinceEpoch)
        info[FlowsInfoField.arrivalWindowDayCount.rawValue] = 92
        info[FlowsInfoField.binMinutes.rawValue] = 15
        info[FlowsInfoField.binsPerDay.rawValue] = 96
        info[FlowsInfoField.dayTypes.rawValue] = 2
        info[FlowsInfoField.bikeTypes.rawValue] = 2
        info[FlowsInfoField.slotsPerSeries.rawValue] = 5
        info[FlowsInfoField.flags.rawValue] = 1 | 1 << 40 // an undefined bit: ignored
        info += [123, 456] // entries a later writer might add
        sections.add(.info, info)
        sections.add(id: 99, elementSize: 4, [UInt32](repeating: 7, count: 5)) // an unknown section
        var keyOffsets: [UInt32] = [0]
        var keyBytes: [UInt8] = []
        for station in data.stations {
            keyBytes += Array(station.key.utf8)
            keyOffsets.append(UInt32(keyBytes.count))
        }
        sections.add(.holidays, data.holidays.map { Int32($0.daysSinceEpoch) })
        sections.add(.keyOffsets, keyOffsets)
        sections.add(.keyBytes, keyBytes)
        sections.add(.stationLatE6, data.stations.map(\.latE6))
        sections.add(.stationLonE6, data.stations.map(\.lonE6))
        sections.add(.stationCapacity, data.stations.map(\.capacity))
        sections.add(.stationActiveDays, data.stations.flatMap(\.activeDays))
        sections.add(.stationFlags, data.stations.map { $0.flags.rawValue | 0x80 }) // undefined bit 7
        sections.add(.cells, data.cells)
        let flows = try reader(ArtifactHeader(kind: .flows, formatVersion: 1, dataVersion: "x", builderSwiftVersion: "6.4").assemble(payload: sections.payload()))
        #expect(flows.count == base.count && flows.flags == [.customerTripsOnly] && flows.flags(1) == [.inGBFS])
        #expect(flows.value(2, .weekend, .arrivals, .varianceAny, bin: 17) == base.value(2, .weekend, .arrivals, .varianceAny, bin: 17))
    }

    @Test func opensFromAFileMapping() throws {
        let scratch = try ScratchDirectory()
        let url = scratch.file(MappedFlows.fileName)
        try HandBuiltFlows.artifact().write(to: url)
        let flows = try MappedFlows.load(fromDataDirectory: scratch.url)
        #expect(flows.count == 3 && flows.key(1) == "5329.08")
    }
}
