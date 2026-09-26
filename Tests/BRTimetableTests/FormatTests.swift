@testable import BRBuild
import BRCore
import BRData
import BRGeo
@testable import BRTimetable
import Foundation
import Testing

@Suite struct TimetableFormatTests {
    /// A tiny hand-built timetable: two stops, one pattern, two trips.
    static func sample() -> TimetableData {
        var data = TimetableData(system: .ferry, windowStart: date("20261005"), dayCount: 3, timeZoneIdentifier: "America/New_York")
        let s = { (text: String) in data.strings.intern(text) }
        data.sourceName = [s("siferry")]
        data.sourceVersion = [s("18")]
        data.sourceETag = [s("\"e\"")]
        data.sourceSlot = [0]
        var days = DayBitset(dayCount: 3)
        days[0] = true
        days[1] = true
        data.sourceSelectedDays = [days]
        data.agencyGTFSID = [s("NYC DOT")]
        data.agencyName = [s("New York City DOT")]
        data.agencyTimezone = [s("America/New_York")]
        data.routeAgency = [0]
        data.routeGTFSID = [s("SIF")]
        data.routeShortName = [0]
        data.routeLongName = [s("Staten Island Ferry")]
        data.routeColor = [0xFF8330]
        data.routeTextColor = [TimetableFormat.none]
        data.routeMode = [RouteMode.ferry.rawValue]
        data.routeType = [4]
        data.stopGTFSID = [s("stgeorge"), s("whitehall")]
        data.stopName = [s("St. George"), s("Whitehall")]
        data.stopCode = [0, 0]
        data.stopLatE6 = [40_644_169, 40_701_360]
        data.stopLonE6 = [-74_072_201, -74_012_666]
        data.stopParent = [TimetableFormat.none, TimetableFormat.none]
        data.stopKind = [0, 0]
        data.stopAccess = [3, 3]
        data.stopEntranceType = [0, 0]
        data.ruleGTFSID = [s("weekday")]
        data.ruleSource = [0]
        data.ruleWeekdays = [UInt8(0x9F)]
        data.ruleStartDay = [Int32(date("20261001").daysSinceEpoch)]
        data.ruleEndDay = [Int32(date("20261031").daysSinceEpoch)]
        data.exceptionDay = [Int32(date("20261006").daysSinceEpoch)]
        data.exceptionType = [2]
        data.ruleExceptionStart = [0, 1]
        data.patternRoute = [0]
        data.patternStopStart = [0, 2]
        data.patternTripStart = [0, 2]
        data.patternFlags = [PatternFlags.arrivalEqualsDeparture.rawValue]
        data.patternDepartureStart = [0]
        data.patternArrivalStart = [TimetableFormat.none]
        data.patternShape = [0]
        data.patternBaseKey = [0]
        data.patternStopIndex = [0, 1]
        data.patternStopFlags = [3, 3]
        data.patternStopShapeVertex = [0, 1]
        data.departures = [0, 1500, 1800, 3300]
        data.tripPattern = [0, 0]
        data.tripRule = [0, 0]
        data.tripGTFSID = [s("a"), s("b")]
        data.tripHeadsign = [s("Whitehall"), s("Whitehall")]
        data.tripShortName = [0, 0]
        data.tripDirection = [0, 255]
        data.tripFlags = [TripFlags.peak.rawValue, 0]
        data.transferFromStop = [0]
        data.transferToStop = [1]
        data.transferFromTrip = [0]
        data.transferToTrip = [1]
        data.transferType = [1]
        data.transferMinSeconds = [TimetableFormat.none]
        data.shapeGTFSID = [s("line")]
        data.shapePointStart = [0, 2]
        data.shapeLatE6 = [40_644_169, 40_701_360]
        data.shapeLonE6 = [-74_072_201, -74_012_666]
        data.rebuildIndexes()
        return data
    }

    @Test func roundTripsThroughAMappedFile() throws {
        let scratch = try ScratchDirectory()
        let data = Self.sample()
        let timetable = try roundTrip(data, scratch: scratch)
        #expect(timetable.header.kind == .ttFerry)
        #expect(timetable.header.formatVersion == ArtifactKind.ttFerry.currentFormatVersion)
        #expect(timetable.header.dataVersion == "test")
        #expect(timetable.system == .ferry)
        #expect(timetable.windowStart == date("20261005") && timetable.dayCount == 3)
        #expect(timetable.coveredDates == [date("20261005"), date("20261006")])
        #expect(timetable.stopCount == 2 && timetable.tripCount == 2 && timetable.patternCount == 1)
        #expect(timetable.stopName(1) == "Whitehall")
        #expect(timetable.stopCoordinate(0).lat == 40.644169)
        #expect(timetable.route(0).color == 0xFF8330 && timetable.route(0).textColor == nil)
        #expect(timetable.route(0).longName == "Staten Island Ferry")
        let agency = timetable.agency(0)
        #expect(agency.gtfsID == "NYC DOT" && agency.name == "New York City DOT" && agency.timeZone == "America/New_York")
        #expect(Array(timetable.patternDepartures(0)) == [0, 1500, 1800, 3300])
        #expect(timetable.arrival(trip: 1, position: 1) == 3300)
        #expect(timetable.tripDirection(0) == 0 && timetable.tripDirection(1) == nil)
        #expect(timetable.isActive(trip: 0, on: date("20261005")))
        #expect(!timetable.isActive(trip: 0, on: date("20261006")))   // removed
        #expect(!timetable.isActive(trip: 0, on: date("20261007")))   // source not selected
        #expect(timetable.guaranteedTransfers(fromTrip: 0).map(\.toTrip) == [1])
        #expect(timetable.shapePoints(0).count == 2)
        #expect(timetable.stop(gtfsID: "whitehall") == 1)
        #expect(timetable.stop(gtfsID: "nowhere") == nil)
        #expect(timetable.trips(gtfsID: "b") == [1])
        #expect(Array(timetable.dayView(for: date("20261005")).activeTrips(inPattern: 0)) == [0, 1])
        #expect(timetable.dayView(for: date("20261005")).stopEventCount == 4)
        #expect(timetable.storedStopEventCount == 4)
        #expect(timetable.stopAccess(0) == [.entry, .exit] && timetable.stopEntranceType(0) == "")
        #expect(timetable.children(ofStop: 0).isEmpty)
        #expect(timetable.slotCount == 1 && timetable.slotCovers(0, on: date("20261006")))
        #expect(timetable.sectionByteCounts[.departures] == 16 && timetable.sectionByteCounts[.stopAccess] == 2)
        #expect(timetable.sectionByteCounts.count == TimetableSection.allCases.count)
        #expect(TimetableSection.allCases.count == 76)
        #expect(timetable.isPeak(trip: 0) && !timetable.isPeak(trip: 1))
        #expect(timetable.tripFlags(0) == .peak && timetable.tripFlags(1) == [])

        // Deterministic: the same data encodes to the same bytes.
        #expect(try data.artifactBytes(dataVersion: "x") == Self.sample().artifactBytes(dataVersion: "x"))
    }

    @Test func readsUnalignedInMemoryBytes() throws {
        let bytes = try Self.sample().artifactBytes(dataVersion: "test")
        var shifted = Data([0])
        shifted.append(bytes)
        let artifact = try MappedArtifact(fileBytes: shifted.dropFirst())
        let timetable = try Timetable(artifact: artifact)
        #expect(Array(timetable.patternDepartures(0)) == [0, 1500, 1800, 3300])
    }

    @Test func rejectsInconsistentData() {
        var data = Self.sample()
        data.patternStopIndex[1] = 7
        #expect(throws: TimetableData.ValidationError.self) { try data.encodedPayload() }
        data = Self.sample()
        data.departures.removeLast()
        #expect(throws: TimetableData.ValidationError.self) { try data.encodedPayload() }
    }

    @Test func rejectsCorruptPayloadsWithoutCrashing() throws {
        let good = try Self.sample().artifactBytes(dataVersion: "test")
        let (header, payload) = try ArtifactHeader.decode(from: good)
        func open(_ mutate: (inout [UInt8]) -> Void) throws {
            var bytes = [UInt8](payload)
            mutate(&bytes)
            let file = header.assemble(payload: Data(bytes))
            _ = try Timetable(artifact: MappedArtifact(fileBytes: file))
        }
        func sectionOffset(_ section: TimetableSection) -> Int {
            let bytes = [UInt8](payload)
            let count = Int(bytes[4]) + Int(bytes[5]) << 8
            for index in 0..<count {
                let entry = 8 + index * 24
                let id = UInt32(bytes[entry]) + UInt32(bytes[entry + 1]) << 8
                if id == section.rawValue {
                    var offset = 0
                    for byte in 0..<8 {
                        let value = Int(bytes[entry + 8 + byte])
                        offset |= value << (8 * byte)
                    }
                    return offset
                }
            }
            return -1
        }
        #expect(throws: TimetableFormatError.badMagic) { try open { $0[0] = 0x58 } }
        #expect(throws: TimetableFormatError.self) { try open { $0[4] = 0xFF; $0[5] = 0xFF } }   // section count
        let stops = sectionOffset(.patternStopIndex)
        #expect(throws: TimetableFormatError.self) { try open { $0[stops + 4] = 0x40 } }       // stop index 64
        let trips = sectionOffset(.tripPattern)
        #expect(throws: TimetableFormatError.self) { try open { $0[trips] = 3 } }              // trip outside its pattern
        let strings = sectionOffset(.stopName)
        #expect(throws: TimetableFormatError.self) { try open { $0[strings + 3] = 0x10 } }     // string id out of range
        let rules = sectionOffset(.ruleStartDay)
        #expect(throws: TimetableFormatError.self) { try open { $0[rules + 3] = 0x80 } }       // absurd date
        #expect(throws: TimetableFormatError.self) { try open { $0.removeLast(64) } }
        // Any revision but the current one (the draft before tripFlags was 1, the current draft 2).
        let info = sectionOffset(.info) + 8 * InfoField.payloadRevision.rawValue
        for revision in [TimetableFormat.payloadRevision - 1, TimetableFormat.payloadRevision + 1] {
            #expect(throws: TimetableFormatError.unsupportedPayloadRevision(revision)) { try open { $0[info] = UInt8(revision) } }
        }
        #expect(throws: (any Error).self) {
            // Right bytes, wrong artifact kind.
            let other = ArtifactHeader(kind: .streets, formatVersion: 0, dataVersion: "", builderSwiftVersion: "6.0")
            _ = try Timetable(artifact: MappedArtifact(fileBytes: other.assemble(payload: payload)))
        }
    }

    // MARK: - Compatibility and strictness

    typealias Section = (id: UInt32, elementSize: UInt32, count: UInt64, bytes: Data)

    /// The sample's payload split into its sections, in table order.
    static func samplePayload() throws -> (header: ArtifactHeader, sections: [Section]) {
        let (header, payload) = try ArtifactHeader.decode(from: try sample().artifactBytes(dataVersion: "test"))
        let bytes = [UInt8](payload)
        func load<T: FixedWidthInteger>(_ offset: Int, as _: T.Type) -> T {
            (0..<MemoryLayout<T>.size).reduce(T.zero) { $0 | T(bytes[offset + $1]) << (8 * $1) }
        }
        let sections = (0..<Int(load(4, as: UInt32.self))).map { index -> Section in
            let entry = 8 + index * 24
            let size = load(entry + 4, as: UInt32.self), offset = Int(load(entry + 8, as: UInt64.self))
            let count = load(entry + 16, as: UInt64.self)
            return (load(entry, as: UInt32.self), size, count, Data(bytes[offset..<offset + Int(size) * Int(count)]))
        }
        return (header, sections)
    }

    /// A file laid out like the writer's: table of contents, then each section 8-aligned and
    /// zero-padded, in the order given, optionally `leadingGap` zero bytes after the table.
    static func file(_ header: ArtifactHeader, _ sections: [Section], leadingGap: Int = 0) -> Data {
        var writer = BinaryWriter()
        writer.append(bytes: TimetableFormat.magic)
        writer.append(UInt32(sections.count))
        let toc = writer.count
        for _ in sections { writer.append(bytes: [UInt8](repeating: 0, count: 24)) }
        writer.append(bytes: [UInt8](repeating: 0, count: leadingGap))
        for (index, section) in sections.enumerated() {
            writer.pad(toMultipleOf: 8)
            writer.overwrite(section.id, at: toc + index * 24)
            writer.overwrite(section.elementSize, at: toc + index * 24 + 4)
            writer.overwrite(UInt64(writer.count), at: toc + index * 24 + 8)
            writer.overwrite(section.count, at: toc + index * 24 + 16)
            writer.append(bytes: section.bytes)
        }
        writer.pad(toMultipleOf: 8)
        return header.assemble(payload: writer.data)
    }

    /// Every section a reader knows, as bytes, by field name.
    static func contents(_ timetable: Timetable) -> [String: [UInt8]] {
        var result: [String: [UInt8]] = [:]
        for child in Mirror(reflecting: timetable.raw).children {
            let bytes: UnsafeRawBufferPointer
            switch child.value {
            case let buffer as UnsafeBufferPointer<UInt8>: bytes = UnsafeRawBufferPointer(buffer)
            case let buffer as UnsafeBufferPointer<UInt16>: bytes = UnsafeRawBufferPointer(buffer)
            case let buffer as UnsafeBufferPointer<UInt32>: bytes = UnsafeRawBufferPointer(buffer)
            case let buffer as UnsafeBufferPointer<Int32>: bytes = UnsafeRawBufferPointer(buffer)
            case let buffer as UnsafeBufferPointer<UInt64>: bytes = UnsafeRawBufferPointer(buffer)
            case let buffer as UnsafeBufferPointer<Int64>: bytes = UnsafeRawBufferPointer(buffer)
            default: Issue.record("unexpected buffer type for \(child.label ?? "?")"); continue
            }
            result[child.label!] = Array(bytes)
        }
        return result
    }

    @Test func ignoresUnknownSections() throws {
        let (header, sections) = try Self.samplePayload()
        let original = try Timetable(artifact: MappedArtifact(fileBytes: Self.file(header, sections)))
        // An extra section with an id no reader knows, at the end and in the middle of the table.
        let extra: Section = (9999, 1, 5, Data([1, 2, 3, 4, 5]))
        for position in [sections.count, 10] {
            var edited = sections
            edited.insert(extra, at: position)
            let timetable = try Timetable(artifact: MappedArtifact(fileBytes: Self.file(header, edited)))
            #expect(Self.contents(timetable) == Self.contents(original))
            #expect(timetable.sectionByteCounts == original.sectionByteCounts)
            #expect(timetable.sectionByteCounts.count == TimetableSection.allCases.count)
            #expect(Array(timetable.patternDepartures(0)) == [0, 1500, 1800, 3300] && timetable.isPeak(trip: 0))
        }
    }

    @Test func ignoresInfoEntriesPastTheKnownOnes() throws {
        let (header, sections) = try Self.samplePayload()
        let original = try Timetable(artifact: MappedArtifact(fileBytes: Self.file(header, sections)))
        var edited = sections
        let info = try #require(edited.firstIndex { $0.id == TimetableSection.info.rawValue })
        #expect(edited[info].count == UInt64(InfoField.allCases.count))
        var grown = edited[info].bytes
        for value in [Int64(-7), Int64.max] { withUnsafeBytes(of: value.littleEndian) { grown.append(contentsOf: $0) } }
        edited[info] = (edited[info].id, 8, edited[info].count + 2, grown)
        let timetable = try Timetable(artifact: MappedArtifact(fileBytes: Self.file(header, edited)))
        var expected = Self.contents(original), found = Self.contents(timetable)
        #expect(found["info"]?.count == 8 * (InfoField.allCases.count + 2))
        #expect(found["info"].map { Array($0.prefix(8 * InfoField.allCases.count)) } == expected["info"])
        expected["info"] = nil
        found["info"] = nil
        #expect(found == expected)
        #expect(timetable.windowStart == original.windowStart && timetable.timeZone == original.timeZone)
    }

    @Test func rejectsAFileWithoutTripFlags() throws {
        let (header, sections) = try Self.samplePayload()
        let edited = sections.filter { $0.id != TimetableSection.tripFlags.rawValue }
        #expect(edited.count == sections.count - 1)
        #expect(throws: TimetableFormatError.missingSection(.tripFlags)) {
            _ = try Timetable(artifact: MappedArtifact(fileBytes: Self.file(header, edited)))
        }
        // Laid out like the previous revision (draft 1: no tripFlags): rejected for its revision,
        // which is checked before any other section.
        var old = edited
        let info = try #require(old.firstIndex { $0.id == TimetableSection.info.rawValue })
        let previous = TimetableFormat.payloadRevision - 1
        old[info].bytes[old[info].bytes.startIndex + 8 * InfoField.payloadRevision.rawValue] = UInt8(previous)
        #expect(throws: TimetableFormatError.unsupportedPayloadRevision(previous)) {
            _ = try Timetable(artifact: MappedArtifact(fileBytes: Self.file(header, old)))
        }
        // A tripFlags section with the wrong count.
        var short = sections
        let flags = try #require(short.firstIndex { $0.id == TimetableSection.tripFlags.rawValue })
        short[flags] = (short[flags].id, 1, 1, Data([1]))
        #expect(throws: TimetableFormatError.inconsistent("trip arrays differ in length")) {
            _ = try Timetable(artifact: MappedArtifact(fileBytes: Self.file(header, short)))
        }
    }

    @Test func roundTripsTripFlagsAndIgnoresUndefinedBits() throws {
        let (header, sections) = try Self.samplePayload()
        var edited = sections
        let flags = try #require(edited.firstIndex { $0.id == TimetableSection.tripFlags.rawValue })
        #expect(edited[flags].bytes == Data([1, 0]))
        edited[flags].bytes = Data([0xFF, 0xFE])
        let timetable = try Timetable(artifact: MappedArtifact(fileBytes: Self.file(header, edited)))
        #expect(timetable.tripFlags(0) == .peak && timetable.isPeak(trip: 0))
        #expect(timetable.tripFlags(1) == [] && !timetable.isPeak(trip: 1))
        // Writers never set undefined bits; an empty array means no flags on any trip.
        var data = Self.sample()
        data.tripFlags[1] = 0x80
        #expect(throws: TimetableData.ValidationError.self) { try data.encodedPayload() }
        data.tripFlags = [1]
        #expect(throws: TimetableData.ValidationError.self) { try data.encodedPayload() }
        data.tripFlags = []
        let unflagged = try Timetable(artifact: MappedArtifact(fileBytes: try data.artifactBytes(dataVersion: "test")))
        #expect(unflagged.raw.tripFlags.count == 2 && !unflagged.isPeak(trip: 0) && !unflagged.isPeak(trip: 1))
    }

    @Test func rejectsUnknownEnumValues() throws {
        let (header, sections) = try Self.samplePayload()
        func open(_ section: TimetableSection, element: Int = 0, _ value: UInt8) throws {
            var edited = sections
            let index = try #require(edited.firstIndex { $0.id == section.rawValue })
            edited[index].bytes[edited[index].bytes.startIndex + element] = value
            _ = try Timetable(artifact: MappedArtifact(fileBytes: Self.file(header, edited)))
        }
        #expect(throws: TimetableFormatError.unknownValue(.routeMode, 9)) { try open(.routeMode, 9) }
        #expect(throws: TimetableFormatError.unknownValue(.stopKind, 5)) { try open(.stopKind, element: 1, 5) }
        #expect(throws: TimetableFormatError.unknownValue(.exceptionType, 3)) { try open(.exceptionType, 3) }
        #expect(throws: TimetableFormatError.unknownValue(.exceptionType, 0)) { try open(.exceptionType, 0) }
        #expect(throws: TimetableFormatError.unknownValue(.transferType, 6)) { try open(.transferType, 6) }
        #expect(throws: TimetableFormatError.unknownValue(.tripDirection, 2)) { try open(.tripDirection, 2) }
        // Every known value opens.
        try open(.routeMode, RouteMode.path.rawValue)
        try open(.stopKind, StopKind.boardingArea.rawValue)
        try open(.transferType, 5)
        try open(.exceptionType, 1)
        // The writer refuses the same values, naming the element.
        let edits: [(String, (inout TimetableData) -> Void)] = [
            ("routeMode[0] holds unknown value 9", { $0.routeMode[0] = 9 }),
            ("stopKind[1] holds unknown value 5", { $0.stopKind[1] = 5 }),
            ("exceptionType[0] holds unknown value 3", { $0.exceptionType[0] = 3 }),
            ("transferType[0] holds unknown value 6", { $0.transferType[0] = 6 }),
            ("tripDirection[0] holds unknown value 2", { $0.tripDirection[0] = 2 }),
        ]
        for (message, edit) in edits {
            var data = Self.sample()
            edit(&data)
            #expect(throws: TimetableData.ValidationError.inconsistent(message)) { try data.encodedPayload() }
        }
    }

    @Test func rejectsUnknownSubwayKeyDirections() throws {
        // The sample plus one subway key for trip 0 (no system restricts the key tables).
        var data = Self.sample()
        data.subwayKeyRoute = [data.strings.intern("1")]
        data.subwayKeyOrigin = [36_000]
        data.subwayKeyPath = [data.strings.intern("R01")]
        data.subwayKeyTrip = [0]
        let header = ArtifactHeader(kind: .ttFerry, formatVersion: ArtifactKind.ttFerry.currentFormatVersion, dataVersion: "test",
                                    builderSwiftVersion: BuildInfo.swiftVersion)
        func open(_ data: TimetableData) throws -> Timetable {
            try Timetable(artifact: MappedArtifact(fileBytes: header.assemble(payload: data.encodedSections())))
        }
        for direction in [UInt8(ascii: "N"), UInt8(ascii: "S")] {
            data.subwayKeyDirection = [direction]
            try data.validate()
            let found = try open(data).subwayTrips(route: "1", direction: direction, originHundredths: 36_000)
            #expect(found.map(\.trip) == [0] && found.map(\.path) == ["R01"])
        }
        for value in [UInt8(ascii: "X"), 0, UInt8(ascii: "n")] {
            data.subwayKeyDirection = [value]
            #expect(throws: TimetableData.ValidationError.inconsistent("subwayKeyDirection[0] holds unknown value \(value)")) {
                try data.validate()
            }
            #expect(throws: TimetableFormatError.unknownValue(.subwayKeyDirection, value)) { _ = try open(data) }
        }
    }

    @Test func rejectsPatternsWithFewerThanTwoStops() throws {
        var data = Self.sample()
        data.patternStopStart = [0, 1]
        data.patternStopIndex = [0]
        data.patternStopFlags = [3]
        data.patternStopShapeVertex = [0]
        data.departures = [0, 1800]
        data.rebuildIndexes()
        #expect(throws: TimetableData.ValidationError.inconsistent("pattern 0 has fewer than two stops")) { try data.validate() }
        let header = ArtifactHeader(kind: .ttFerry, formatVersion: ArtifactKind.ttFerry.currentFormatVersion, dataVersion: "test",
                                    builderSwiftVersion: BuildInfo.swiftVersion)
        #expect(throws: TimetableFormatError.inconsistent("pattern with fewer than two stops")) {
            _ = try Timetable(artifact: MappedArtifact(fileBytes: header.assemble(payload: data.encodedSections())))
        }
    }

    @Test func rejectsNonZeroPadding() throws {
        let (header, sections) = try Self.samplePayload()
        let good = Self.file(header, sections)
        let (_, payload) = try ArtifactHeader.decode(from: good)
        #expect(try Timetable(artifact: MappedArtifact(fileBytes: good)).stopCount == 2)
        // stopKind holds 2 bytes, then 6 bytes of padding (the gap after the table and the tail:
        // rejectsNonZeroBytesAroundTheSections).
        var offset = 8 + 24 * sections.count
        for section in sections {
            offset = (offset + 7) / 8 * 8
            if section.id == TimetableSection.stopKind.rawValue { break }
            offset += section.bytes.count
        }
        let afterStopKind = offset + 2
        for position in [afterStopKind, afterStopKind + 5] {
            var bytes = [UInt8](payload)
            #expect(bytes[position] == 0)
            bytes[position] = 1
            #expect(throws: TimetableFormatError.nonZeroPadding(offset: position)) {
                _ = try Timetable(artifact: MappedArtifact(fileBytes: header.assemble(payload: Data(bytes))))
            }
        }
    }

    @Test func rejectsNonZeroBytesAroundTheSections() throws {
        let (header, sections) = try Self.samplePayload()
        let tocEnd = 8 + 24 * sections.count
        func payload(_ file: Data) throws -> [UInt8] { [UInt8](try ArtifactHeader.decode(from: file).payload) }
        func open(_ payload: [UInt8]) throws {
            _ = try Timetable(artifact: MappedArtifact(fileBytes: header.assemble(payload: Data(payload))))
        }
        // Zero bytes between the table and the first section open; a set byte there doesn't.
        var gapped = try payload(Self.file(header, sections, leadingGap: 16))
        try open(gapped)
        gapped[tocEnd + 9] = 1
        #expect(throws: TimetableFormatError.nonZeroPadding(offset: tocEnd + 9)) { try open(gapped) }
        // The same after the last section, where the payload ends.
        var tail = try payload(Self.file(header, sections))
        let end = tail.count
        tail += [UInt8](repeating: 0, count: 8)
        try open(tail)
        tail[end + 3] = 1
        #expect(throws: TimetableFormatError.nonZeroPadding(offset: end + 3)) { try open(tail) }
    }

    @Test func rejectsOverlappingSections() throws {
        let (header, sections) = try Self.samplePayload()
        var bytes = [UInt8](try ArtifactHeader.decode(from: Self.file(header, sections)).payload)
        func offsetField(_ section: TimetableSection) throws -> Int {
            8 + 24 * (try #require(sections.firstIndex { $0.id == section.rawValue })) + 8
        }
        func offset(_ section: TimetableSection) throws -> Int {
            let field = try offsetField(section)
            return (0..<8).reduce(0) { $0 | Int(bytes[field + $1]) << (8 * $1) }
        }
        // tripFlags (2 bytes) moved 8-aligned into the middle of departures (16 bytes), its old
        // bytes zeroed so only the overlap is wrong.
        let flags = try offset(.tripFlags), departures = try offset(.departures)
        #expect(sections.first { $0.id == TimetableSection.departures.rawValue }?.bytes.count == 16)
        bytes[flags] = 0
        let field = try offsetField(.tripFlags)
        for byte in 0..<8 { bytes[field + byte] = UInt8(truncatingIfNeeded: (departures + 8) >> (8 * byte)) }
        #expect(throws: TimetableFormatError.inconsistent("section \(TimetableSection.tripFlags.rawValue) overlaps another")) {
            _ = try Timetable(artifact: MappedArtifact(fileBytes: header.assemble(payload: Data(bytes))))
        }
    }
}

@Suite struct TimetableReportTests {
    @Test func keepsEntriesWrittenBeforeStatsKeysWereAdded() throws {
        let scratch = try ScratchDirectory()
        let feed = try GTFSFeed.parse(try scratch.feed("siferry", Fixture.ferry), source: GTFSSourceInfo(name: "siferry", slot: "siferry"))
        var (_, stats) = try GTFSTimetableCompiler.compile(system: .ferry, feeds: [feed], options: GTFSCompileOptions(windowStart: Fixture.windowStart))
        stats.tripsPeak = 3
        var report = TimetableBuildReport()
        report.systems["tt-ferry"] = TimetableSystemReport(stats: stats, artifact: .init(file: "tt-ferry.bin", rawBytes: 1, rawSha256: "x"))
        let current = try JSONEncoder().encode(report)
        #expect(try TimetableBuildReport.decodePrevious(current).systems["tt-ferry"]?.stats.tripsPeak == 3)

        // The same entry as a tool from before tripFlags and reversed shapes wrote it.
        var root = try #require(try JSONSerialization.jsonObject(with: current) as? [String: Any])
        var systems = try #require(root["systems"] as? [String: Any])
        var entry = try #require(systems["tt-ferry"] as? [String: Any])
        var oldStats = try #require(entry["stats"] as? [String: Any])
        for key in ["tripsPeak", "patternsWithReversedShape", "shapesReversed", "patternsWithShapeTooFar", "maxStopToShapeVertexMeters"] {
            #expect(oldStats.removeValue(forKey: key) != nil, "\(key)")
        }
        entry["stats"] = oldStats
        systems["tt-ferry"] = entry
        root["systems"] = systems
        let old = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TimetableBuildReport.self, from: old) }
        let kept = try #require(try TimetableBuildReport.decodePrevious(old).systems["tt-ferry"])
        #expect(kept.stats.trips == stats.trips && kept.stats.tripsPeak == 0 && kept.stats.maxStopToShapeVertexMeters == 0)
        #expect(kept.artifact.file == "tt-ferry.bin")
        // Not a report at all: an error the build logs, not a crash.
        #expect(throws: (any Error).self) { try TimetableBuildReport.decodePrevious(Data("[1]".utf8)) }
    }
}

@Suite struct CalendarTests {
    @Test func evaluatesCalendarRowsAndExceptions() {
        let monday = Int32(date("20261005").daysSinceEpoch)
        let weekdays: UInt8 = 0x80 | 0x1F
        let days: [Int32] = [monday + 1, monday + 5]
        let types: [UInt8] = [2, 1]
        func runs(_ day: Int32, _ mask: UInt8 = weekdays) -> Bool {
            ServiceCalendar.ruleRuns(weekdays: mask, startDay: monday, endDay: monday + 6,
                                     exceptionDays: days, exceptionTypes: types, day: day)
        }
        #expect(runs(monday))
        #expect(!runs(monday + 1))       // removed Tuesday
        #expect(runs(monday + 4))        // Friday
        #expect(runs(monday + 5))        // added Saturday
        #expect(!runs(monday + 6))       // Sunday
        #expect(!runs(monday + 7))       // after end_date, never extended
        #expect(!runs(monday, 0x1F))     // no calendar row: only exceptions count
        #expect(runs(monday + 5, 0))
        #expect(ServiceCalendar.weekdayBit(ofDay: date("20261005").daysSinceEpoch) == 0)
        #expect(ServiceCalendar.weekdayBit(ofDay: date("20261011").daysSinceEpoch) == 6)
        #expect(ServiceCalendar.weekdayBit(ofDay: date("19691231").daysSinceEpoch) == 2)
    }

    @Test func dayBitsets() {
        var a = DayBitset(dayCount: 130)
        a[0] = true
        a[64] = true
        a[129] = true
        #expect(a.days == [0, 64, 129] && a.count == 3 && !a[130] && !a[-1])
        var b = DayBitset(dayCount: 130)
        b[65] = true
        #expect(!a.intersects(b))
        b[129] = true
        #expect(a.intersects(b))
        a.formUnion(b)
        #expect(a.days == [0, 64, 65, 129])
        a.subtract(b)
        #expect(a.days == [0, 64])
    }
}

@Suite struct InternerTests {
    @Test func internsBytesDensely() {
        var interner = ByteInterner(capacity: 2)
        let ids = (0..<1000).map { interner.intern("stop-\($0)") }
        #expect(ids == (0..<1000).map(UInt32.init))
        #expect(interner.intern("stop-7") == 7)
        #expect(interner.lookup("stop-999") == 999)
        #expect(interner.lookup("stop-1000") == nil)
        #expect(interner.string(42) == "stop-42")
        #expect(interner.intern("") == 1000)
        #expect(interner.lookup("") == 1000)
        #expect(interner.length(1000) == 0)
    }
}

@Suite struct FieldParsingTests {
    func time(_ text: String) -> UInt32? { GTFSField.time(Array(text.utf8)[...]) }

    @Test func parsesGTFSTimes() {
        #expect(time("05:07:09") == hms(5, 7, 9))
        #expect(time(" 5:07:00") == hms(5, 7))
        #expect(time("25:10:00") == hms(25, 10))
        #expect(time("28:00:00") == hms(28, 0))
        #expect(time("100:00:00") == 360_000)
        #expect(time("") == nil)
        #expect(time("12:60:00") == nil)
        #expect(time("12:00") == nil)
        #expect(time("1a:00:00") == nil)
    }

    @Test func parsesCoordinatesToMicrodegrees() {
        #expect(GTFSField.microdegrees(Array("  40.872562".utf8)[...]) == 40_872_562)
        #expect(GTFSField.microdegrees(Array(" -73.888156".utf8)[...]) == -73_888_156)
        #expect(GTFSField.microdegrees(Array("40.77206317".utf8)[...]) == 40_772_063)
        #expect(GTFSField.microdegrees(Array("-73.80852987".utf8)[...]) == -73_808_530)
        #expect(GTFSField.microdegrees(Array("40.7".utf8)[...]) == 40_700_000)
        #expect(GTFSField.microdegrees(Array("-74".utf8)[...]) == -74_000_000)
        #expect(GTFSField.microdegrees(Array("".utf8)[...]) == nil)
        #expect(GTFSField.microdegrees(Array("40..7".utf8)[...]) == nil)
    }

    @Test func parsesColorsAndIntegers() {
        #expect(GTFSField.color(Array("D82233".utf8)[...]) == 0xD82233)
        #expect(GTFSField.color(Array("#00aeef".utf8)[...]) == 0x00AEEF)
        #expect(GTFSField.color(Array("".utf8)[...]) == nil)
        #expect(GTFSField.color(Array("FFF".utf8)[...]) == nil)
        #expect(GTFSField.int(Array(" 12 ".utf8)[...]) == 12)
        #expect(GTFSField.int(Array("-1".utf8)[...]) == nil)
        #expect(GTFSField.day(Array("20261005".utf8)[...]) == Int32(date("20261005").daysSinceEpoch))
    }

    @Test func simplifiesAndMatchesShapes() {
        let points = (0...10).map { PlanarPoint(x: Double($0) * 100, y: $0 == 5 ? 3 : 0) }
        var keep = [Bool](repeating: false, count: points.count)
        #expect(ShapeGeometry.simplify(points, keep: keep, tolerance: 5) == [0, 10])
        keep[7] = true
        #expect(ShapeGeometry.simplify(points, keep: keep, tolerance: 5) == [0, 7, 10])
        #expect(ShapeGeometry.simplify(points, keep: keep, tolerance: 2) == [0, 4, 5, 7, 10])
        // A loop passing the first stop again later still matches its first pass.
        let loop = [PlanarPoint(x: 0, y: 0), PlanarPoint(x: 500, y: 0), PlanarPoint(x: 500, y: 500),
                    PlanarPoint(x: 0, y: 10), PlanarPoint(x: -500, y: 0)]
        #expect(ShapeGeometry.stopVertices(stops: [PlanarPoint(x: 0, y: 5), PlanarPoint(x: -400, y: 0)], line: loop) == [0, 4])
    }
}
