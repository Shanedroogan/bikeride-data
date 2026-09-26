@testable import BRBuild
import BRCore
import BRData
import BRGeo
import BRTimetable
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
        let info = sectionOffset(.info) + 8 * InfoField.draftRevision.rawValue
        #expect(throws: TimetableFormatError.unsupportedDraftRevision(2)) { try open { $0[info] = 2 } }
        #expect(throws: (any Error).self) {
            // Right bytes, wrong artifact kind.
            let other = ArtifactHeader(kind: .streets, formatVersion: 0, dataVersion: "", builderSwiftVersion: "6.0")
            _ = try Timetable(artifact: MappedArtifact(fileBytes: other.assemble(payload: payload)))
        }
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
