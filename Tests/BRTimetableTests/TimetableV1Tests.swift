import BRCore
import BRData
import BRGeo
@testable import BRTimetable
import Foundation
import Testing

/// Format 1 of the `tt-*` kinds, frozen 2026-09-26 (`docs/formats.md`, "Compatibility"): the
/// payload golden for the hand-built sample (``TimetableFormatTests/sample()``), the committed v1
/// file, and the formatVersion and payloadRevision gates. The five kinds share one layout; the
/// sample is `tt-ferry`. It is typed by hand, not compiled from a GTFS feed: two trips between the
/// two Staten Island Ferry terminals, under their real names and coordinates.
@Suite struct TimetableV1Tests {
    /// SHA-256 of the writer's payload for ``TimetableFormatTests/sample()`` (the header is left
    /// out: it embeds builderSwiftVersion). What may change it:
    /// - a change to the payload layout. That is a new formatVersion, because a v1 reader would
    ///   misread the bytes; never re-pin this digest for one.
    /// - a deliberate change to the sample, or to what the writer puts in a v1 payload (such as a
    ///   new optional section or `info` entry). Review the new bytes, then pin the new digest.
    /// GTFS-compiler changes don't reach it: the sample is built by hand, not compiled.
    static let payloadGolden = "11f4ee0009c031602efaba1c4de49b6a5de204dc259c2456f132fa01e7ee36ae"

    static let fixtureName = "tt-sample.bin"

    func open(_ file: Data) throws -> Timetable {
        try Timetable(artifact: MappedArtifact(fileBytes: file))
    }

    /// The payload offset of `info.payloadRevision`, found through the table of contents.
    static func payloadRevisionOffset(_ payload: [UInt8]) throws -> Int {
        func load<T: FixedWidthInteger>(_ offset: Int, as _: T.Type) -> T {
            (0..<MemoryLayout<T>.size).reduce(T.zero) { $0 | T(payload[offset + $1]) << (8 * $1) }
        }
        let entry = try #require((0..<Int(load(4, as: UInt32.self))).map { 8 + 24 * $0 }.first {
            load($0, as: UInt32.self) == TimetableSection.info.rawValue
        })
        return Int(load(entry + 8, as: UInt64.self)) + 8 * InfoField.payloadRevision.rawValue
    }

    @Test func payloadMatchesTheGolden() throws {
        let data = TimetableFormatTests.sample()
        let file = try data.artifactBytes(dataVersion: V1Fixtures.dataVersion)
        #expect(Data(try ArtifactHeader.decode(from: file).payload) == (try data.encodedPayload()))
        #expect(try V1Fixtures.payloadSHA256(file) == Self.payloadGolden)
        #expect(try V1Fixtures.payloadSHA256(data.artifactBytes(dataVersion: "other")) == Self.payloadGolden)
        // The sample is a valid v1 file.
        #expect(try open(file).header.formatVersion == 1)
    }

    @Test func rejectsEveryOtherFormatVersionAndPayloadRevision() throws {
        let file = try TimetableFormatTests.sample().artifactBytes(dataVersion: V1Fixtures.dataVersion)
        _ = try open(file)
        for version: UInt16 in [0, 2] {
            #expect(throws: TimetableFormatError.unsupportedFormatVersion(version)) { try open(V1Fixtures.withFormatVersion(version, file)) }
        }
        let (header, payload) = try ArtifactHeader.decode(from: file)
        let offset = try Self.payloadRevisionOffset([UInt8](payload))
        for revision: Int64 in [0, 2] {
            var bytes = [UInt8](payload)
            withUnsafeBytes(of: revision.littleEndian) { bytes.replaceSubrange(offset..<offset + 8, with: $0) }
            #expect(throws: TimetableFormatError.unsupportedPayloadRevision(revision)) { try open(header.assemble(payload: Data(bytes))) }
        }
    }

    /// A reader of this build opens the committed v1 file (`Timetable` always checks every length
    /// and index) and reads what was written on the day the format froze. Every value is a
    /// literal: the file is frozen, not rebuilt.
    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func opensTheCommittedV1File() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        let timetable = try open(file)
        #expect(timetable.header.kind == .ttFerry && timetable.header.formatVersion == 1)
        #expect(timetable.header.dataVersion == "v1-fixture" && timetable.header.builtAgainst.isEmpty)
        let payload = [UInt8](try ArtifactHeader.decode(from: file).payload)
        #expect(Array(payload.prefix(4)) == Array("BRTT".utf8))
        let revision = try Self.payloadRevisionOffset(payload)
        #expect(payload[revision..<revision + 8].elementsEqual([1, 0, 0, 0, 0, 0, 0, 0]))
        // 76 sections, every one this reader knows. A later reader that knows more finds its new
        // optional sections absent and uses their documented defaults.
        #expect(payload[4..<8].elementsEqual([76, 0, 0, 0]) && timetable.sectionByteCounts.count == 76)
        #expect(timetable.sectionByteCounts[.departures] == 16 && timetable.sectionByteCounts[.tripFlags] == 2)

        #expect(timetable.system == .ferry && timetable.timeZone.identifier == "America/New_York")
        #expect(timetable.windowStart == date("20261005") && timetable.dayCount == 3)
        #expect(timetable.coveredDates == [date("20261005"), date("20261006")])
        #expect(timetable.sourceCount == 1 && timetable.agencyCount == 1 && timetable.routeCount == 1 && timetable.ruleCount == 1)
        #expect(timetable.stopCount == 2 && timetable.patternCount == 1 && timetable.tripCount == 2)
        #expect(timetable.transferCount == 1 && timetable.shapeCount == 1 && timetable.storedStopEventCount == 4)
        #expect(timetable.stopGTFSID(0) == "stgeorge" && timetable.stopName(1) == "Whitehall")
        #expect(timetable.stopCoordinate(0) == Coordinate(lat: 40.644169, lon: -74.072201))
        #expect(timetable.stop(gtfsID: "whitehall") == 1 && timetable.stop(gtfsID: "nowhere") == nil)
        let route = timetable.route(0)
        #expect(route.longName == "Staten Island Ferry" && route.color == 0xFF8330 && route.textColor == nil)
        #expect(timetable.routeMode(0) == .ferry)
        #expect(Array(timetable.patternDepartures(0)) == [0, 1500, 1800, 3300])
        #expect(timetable.departure(trip: 1, position: 0) == 1800 && timetable.arrival(trip: 1, position: 1) == 3300)
        #expect(timetable.tripGTFSID(0) == "a" && timetable.trips(gtfsID: "b") == [1] && timetable.tripHeadsign(1) == "Whitehall")
        #expect(timetable.tripDirection(0) == 0 && timetable.tripDirection(1) == nil)
        #expect(timetable.tripFlags(0) == .peak && timetable.tripFlags(1) == [])
        #expect(timetable.isActive(trip: 0, on: date("20261005")))
        #expect(!timetable.isActive(trip: 0, on: date("20261006")))   // removed by an exception
        #expect(!timetable.isActive(trip: 0, on: date("20261007")))   // source not selected
        #expect(timetable.guaranteedTransfers(fromTrip: 0).map(\.toTrip) == [1])
        #expect(timetable.shapePoints(0).count == 2)
    }

    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func rejectsTheCommittedFileUnderAnyOtherFormatVersion() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        for version: UInt16 in [0, 2] {
            #expect(throws: TimetableFormatError.unsupportedFormatVersion(version)) { try open(V1Fixtures.withFormatVersion(version, file)) }
        }
    }

    /// Rewrites `Tests/Fixtures/v1/tt-sample.bin` from ``TimetableFormatTests/sample()``. Only
    /// with `BR_WRITE_V1_FIXTURES=1`; see ``V1Fixtures`` for when that is right.
    @Test(.enabled(if: V1Fixtures.regenerating, "set BR_WRITE_V1_FIXTURES=1 to rewrite the v1 fixtures"))
    func writeV1Fixture() throws {
        let file = try TimetableFormatTests.sample().artifactBytes(dataVersion: V1Fixtures.dataVersion)
        _ = try open(file)
        try V1Fixtures.write(file, to: Self.fixtureName)
    }
}
