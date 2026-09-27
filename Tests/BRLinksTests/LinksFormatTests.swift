import BRBuild
import BRCore
import BRData
import BRTimetable
import Foundation
import Testing

/// The `links` reader's compatibility rules (extension tail, undefined flag bits) and one
/// single-byte mutation per open-time invariant (`docs/formats.md`, "links", Invariants).
@Suite struct LinksFormatTests {
    let fixture: LinksFixture
    let file: Data
    let header: ArtifactHeader
    let payload: Data
    let layout: LinksPayloadLayout

    init() throws {
        let fixture = try LinksFixture()
        let file = fixture.artifact()
        let decoded = try ArtifactHeader.decode(from: file)
        self.fixture = fixture
        self.file = file
        header = decoded.header
        payload = Data(decoded.payload)
        layout = LinksPayloadLayout(payload)
    }

    func reader(payload: Data, validate: Bool = true, builtAgainst: [String: String]? = nil) throws -> MappedLinks {
        var header = header
        if let builtAgainst {
            header = ArtifactHeader(kind: .links, formatVersion: header.formatVersion, dataVersion: header.dataVersion,
                                    builderSwiftVersion: header.builderSwiftVersion, builtAgainst: builtAgainst)
        }
        return try MappedLinks(artifact: MappedArtifact(fileBytes: header.assemble(payload: payload), expecting: .links), validate: validate)
    }

    var original: MappedLinks { get throws { try reader(payload: payload) } }

    func routable(_ stop: Int) -> Bool { payload[layout["stopFlags"].at(stop)] & 1 != 0 }

    func u32(_ field: String, _ index: Int) -> Int { Int(payload.value(UInt32.self, at: layout[field].at(index))) }
    func u16(_ field: String, _ index: Int) -> Int { Int(payload.value(UInt16.self, at: layout[field].at(index))) }

    /// Rows `[start[i], start[i + 1])` of an offsets field.
    func row(_ field: String, _ index: Int) -> Range<Int> { u32(field, index)..<u32(field, index + 1) }

    /// Expects `mutated` to fail the invariant `rule`, and to open with `validate: false` (the
    /// structure is intact).
    func expectViolation(_ rule: String, _ mutated: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: (any Error).self, sourceLocation: sourceLocation) { try reader(payload: mutated) }
        do {
            _ = try reader(payload: mutated)
        } catch let LinksFormatError.invariantViolated(found, _) {
            #expect(found == rule, sourceLocation: sourceLocation)
        } catch {
            Issue.record("expected \(rule), got \(error)", sourceLocation: sourceLocation)
        }
        #expect(throws: Never.self, sourceLocation: sourceLocation) { try reader(payload: mutated, validate: false) }
    }

    // MARK: - Compatibility

    @Test func writesAnEmptyExtensionTailAndNothingAfterIt() throws {
        #expect(layout.tail == payload.count - 4 && payload.value(UInt32.self, at: layout.tail) == 0)
        #expect(try original.extensions == .empty)
        #expect(payload.value(UInt32.self, at: 4) == LinksFormat.payloadRevision && LinksFormat.payloadRevision == 1)
    }

    @Test func ignoresUndefinedFlagBits() throws {
        let links = try original
        let stop = (0..<links.stopCount).first { links.stopFlags($0).contains(.streetEntry) }!
        let point = 0
        var mutated = payload
        mutated[layout["stopFlags"].at(stop)] |= 0x80
        mutated[layout["accessPointFlags"].at(point)] |= 0xF8
        let flagged = try reader(payload: mutated)
        #expect(flagged.raw.stopFlags[stop] & 0x80 != 0)
        for s in 0..<links.stopCount { #expect(flagged.stopFlags(s) == links.stopFlags(s)) }
        for p in 0..<links.accessPointCount { #expect(flagged.accessPoint(p) == links.accessPoint(p)) }
        #expect(flagged.footpathCount == links.footpathCount && flagged.stationLinkCount == links.stationLinkCount)
    }

    @Test func skipsUnknownExtensionIDs() throws {
        let fixed = payload.prefix(layout.tail)
        var writer = BinaryWriter()
        writer.append(bytes: fixed)
        writer.appendExtensions([(id: 7, bytes: [1, 2, 3]), (id: 1000, bytes: Array(0..<19))])
        let links = try reader(payload: writer.data)
        #expect(links.extensions.ids == [7, 1000])
        #expect(links.extensions[1000].map(Array.init) == Array(0..<19))
        let plain = try original
        for stop in 0..<plain.stopCount {
            #expect(Array(links.footpaths(from: stop)) == Array(plain.footpaths(from: stop)))
            #expect(Array(links.stations(nearStop: stop)) == Array(plain.stations(nearStop: stop)))
        }
        // The table outlives the reader, including when the reader viewed a private aligned copy.
        var shifted = Data([0])
        shifted.append(header.assemble(payload: writer.data))
        let extensions = try MappedLinks(artifact: MappedArtifact(fileBytes: shifted.dropFirst(), expecting: .links)).extensions
        #expect(extensions[7].map(Array.init) == [1, 2, 3])
    }

    @Test func rejectsAMalformedExtensionTail() throws {
        let fixed = payload.prefix(layout.tail)
        for ids: [UInt32] in [[9, 7], [7, 7]] {
            let (bytes, offsets) = fixed.withRawExtensionTail(ids.map { (id: $0, bytes: [1]) })
            #expect(throws: DataFormatError.extensionIDsNotAscending(offset: offsets[1])) { try reader(payload: bytes) }
        }
        #expect(throws: DataFormatError.trailingBytes(1)) { try reader(payload: payload + [0]) }
        #expect(throws: DataFormatError.trailingBytes(8)) { try reader(payload: fixed.withRawExtensionTail([(id: 3, bytes: [5])]).payload + Data(count: 8)) }
        #expect(throws: DataFormatError.self) { try reader(payload: fixed) }
    }

    // MARK: - Invariants

    @Test func requiresStationsInBuiltAgainstWhenThereAreStations() throws {
        #expect(try original.stationCount > 0)
        #expect(throws: LinksFormatError.invariantViolated(rule: "stationsInBuiltAgainst", index: 0)) {
            try reader(payload: payload, builtAgainst: ["streets": "x"])
        }
        _ = try reader(payload: payload, validate: false, builtAgainst: ["streets": "x"])
    }

    /// A non-routable stop q followed by a stop that has an entry in `field`'s rows: moving the
    /// boundary between them hands q that entry without breaking the offsets.
    func stealFirstEntry(_ field: String) throws -> Data {
        let t = try original.stopCount
        let q = try #require((0..<(t - 1)).first { !routable($0) && !row(field, $0 + 1).isEmpty })
        return payload.replacing(UInt32(u32(field, q + 1) + 1), at: layout[field].at(q + 1))
    }

    @Test func nonRoutableStopsHaveNoFootpathsAccessPointsOrStationLinks() throws {
        expectViolation("nonRoutableStopHasFootpaths", try stealFirstEntry("footpathStart"))
        expectViolation("nonRoutableStopHasAccessPoints", try stealFirstEntry("stopAccessStart"))
        expectViolation("nonRoutableStopHasStationLinks", try stealFirstEntry("stopStationStart"))
    }

    @Test func footpathsLeadOnlyToRoutableStops() throws {
        let t = try original.stopCount
        let nonRoutable = try #require((0..<t).first { !routable($0) })
        expectViolation("footpathToNonRoutableStop", payload.replacing(UInt32(nonRoutable), at: layout["footpathTarget"].at(0)))
    }

    @Test func accessPointsChargeTheirSystemsAccess() throws {
        let field = layout["accessPointAccessSeconds"]
        expectViolation("accessPointAccessSeconds", payload.replacing(UInt16(u16("accessPointAccessSeconds", 0) + 1), at: field.at(0)))
    }

    /// The first two slots of the first `start` row with at least two links, the first of which
    /// is walkable in the row's sort direction (`seconds` below 0xFFFE).
    func rowWithTwoLinks(_ start: String, seconds: String) throws -> (Int, Int) {
        let rows = layout[start].count - 1
        for index in 0..<rows {
            let slots = row(start, index)
            if slots.count >= 2, u16(seconds, slots.lowerBound) < 0xFFFE { return (slots.lowerBound, slots.lowerBound + 1) }
        }
        throw FixtureError.missing("a \(start) row with two links")
    }

    enum FixtureError: Error { case missing(String) }

    /// Swaps elements `a` and `b` of each named field.
    func swapping(_ a: Int, _ b: Int, in fields: [String]) -> Data {
        var copy = payload
        for name in fields {
            let field = layout[name]
            let x = copy.subdata(in: field.at(a)..<field.at(a) + field.size), y = copy.subdata(in: field.at(b)..<field.at(b) + field.size)
            copy.replaceSubrange(field.at(a)..<field.at(a) + field.size, with: y)
            copy.replaceSubrange(field.at(b)..<field.at(b) + field.size, with: x)
        }
        return copy
    }

    @Test func stationRowsAreSortedWithoutRepeats() throws {
        let (first, second) = try rowWithTwoLinks("stationStopStart", seconds: "stationStopEnter")
        expectViolation("stationRowOrder", swapping(first, second, in: ["stationStopStop", "stationStopEnter", "stationStopExit"]))
        // The second link names the first one's stop, one second later (so the row stays sorted).
        let repeated = payload.replacing(UInt32(u32("stationStopStop", first)), at: layout["stationStopStop"].at(second))
            .replacing(UInt16(u16("stationStopEnter", first) + 1), at: layout["stationStopEnter"].at(second))
        expectViolation("stationRowRepeatsStop", repeated)
    }

    @Test func stopRowsAreSortedWithoutRepeats() throws {
        let (first, second) = try rowWithTwoLinks("stopStationStart", seconds: "stopStationExit")
        expectViolation("stopRowOrder", swapping(first, second, in: ["stopStationStation", "stopStationEnter", "stopStationExit"]))
        let repeated = payload.replacing(UInt32(u32("stopStationStation", first)), at: layout["stopStationStation"].at(second))
            .replacing(UInt16(u16("stopStationExit", first) + 1), at: layout["stopStationExit"].at(second))
        expectViolation("stopRowRepeatsStation", repeated)
    }

    @Test func everyStationLinkIsWalkableAtLeastOneWay() throws {
        // The last link of a station row, made 0xFFFF both ways (still sorted: 0xFFFF sorts last).
        let s = try original.stationCount
        let slot = try #require((0..<s).map { row("stationStopStart", $0) }.first { !$0.isEmpty && u16("stationStopEnter", $0.upperBound - 1) != 0xFFFF }).upperBound - 1
        let mutated = payload.replacing(UInt16.max, at: layout["stationStopEnter"].at(slot)).replacing(UInt16.max, at: layout["stationStopExit"].at(slot))
        expectViolation("stationLinkWithoutDirection", mutated)
    }

    @Test func bothDirectionsListTheSameLinks() throws {
        let field = layout["stopStationEnter"]
        let slot = try #require((0..<field.count).first { u16("stopStationEnter", $0) < 0xFFFE })
        expectViolation("stationLinkDirectionsDiffer", payload.replacing(UInt16(u16("stopStationEnter", slot) + 1), at: field.at(slot)))
    }

    @Test func structuralDamageFailsEvenWithoutValidation() throws {
        // An offset past the end, and an index out of range: the views themselves would be unsafe.
        let start = layout["footpathStart"]
        #expect(throws: (any Error).self) {
            try reader(payload: payload.replacing(UInt32.max, at: start.at(start.count - 1)), validate: false)
        }
        #expect(throws: LinksFormatError.valueOutOfRange(section: "stopStationStation", index: 0)) {
            try reader(payload: payload.replacing(UInt32(1_000_000), at: layout["stopStationStation"].at(0)), validate: false)
        }
    }
}
