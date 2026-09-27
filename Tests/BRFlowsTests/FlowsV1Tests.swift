import BRCore
import BRData
import BRFlows
import Foundation
import Testing

/// Format 1 of `flows`, frozen 2026-09-27 (`docs/formats.md`, "Compatibility"): the payload golden
/// for ``HandBuiltFlows``, the committed v1 file, and the formatVersion and payloadRevision gates.
@Suite struct FlowsV1Tests {
    /// SHA-256 of the writer's payload for ``HandBuiltFlows`` (the header is left out: it embeds
    /// builderSwiftVersion). What may change it:
    /// - a change to the payload layout. That is a new formatVersion, because a v1 reader would
    ///   misread the bytes; never re-pin this digest for one.
    /// - a deliberate change to the hand-built input, or to what the writer puts in a v1 payload
    ///   (such as a new optional section or `info` entry). Review the new bytes, then pin the new
    ///   digest.
    /// Trip parsing, binning and smoothing changes don't reach it: every cell is hand-set. The
    /// format-0 draft (revision 1) froze unchanged, so this is the draft's digest.
    static let payloadGolden = "0e64b0013d3ee4b2f8c75380960cf6ae488169f440dd69ad38f96d3f240fd983"

    static let fixtureName = "flows.bin"

    func reader(_ file: Data) throws -> MappedFlows {
        try MappedFlows(artifact: MappedArtifact(fileBytes: file, expecting: .flows))
    }

    @Test func payloadMatchesTheGolden() throws {
        let data = HandBuiltFlows.data()
        let file = try HandBuiltFlows.artifact(data, dataVersion: V1Fixtures.dataVersion)
        let payload = Data(try ArtifactHeader.decode(from: file).payload)
        #expect(payload == (try data.encodedPayload()))
        #expect(try V1Fixtures.payloadSHA256(file) == Self.payloadGolden)
        #expect(try V1Fixtures.payloadSHA256(HandBuiltFlows.artifact(data, dataVersion: "other")) == Self.payloadGolden)
        #expect(payload.count == 16 + 10 * 24 + 8 * 15 + 8 + 16 + 16 + 24 + 16 + 8 + 24 + 8 + 3 * FlowsFormat.cellsPerKey * 2)
        // The hand-built set is a valid v1 file.
        let flows = try reader(file)
        #expect(flows.header.kind == .flows && flows.header.formatVersion == 1 && flows.header.builtAgainst.isEmpty)
        #expect(flows.payloadRevision == 1)
    }

    @Test func rejectsEveryOtherFormatVersionAndPayloadRevision() throws {
        let file = try HandBuiltFlows.artifact(dataVersion: V1Fixtures.dataVersion)
        _ = try reader(file)
        for version: UInt16 in [0, 2] {
            #expect(throws: FlowsFormatError.unsupportedFormatVersion(version)) { try reader(V1Fixtures.withFormatVersion(version, file)) }
        }
        let (header, payload) = try ArtifactHeader.decode(from: file)
        for revision: UInt32 in [0, 2] {
            #expect(throws: FlowsFormatError.unsupportedPayloadRevision(revision)) {
                try reader(header.assemble(payload: Data(payload).replacing(revision, at: 4)))
            }
        }
    }

    /// A reader of this build opens the committed v1 file (`MappedFlows` validates every cell) and
    /// reads what was written on the day the format froze. Every value is a literal: the file is
    /// frozen, not rebuilt.
    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func opensTheCommittedV1File() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        let flows = try reader(file)
        #expect(flows.header.kind == .flows && flows.header.formatVersion == 1)
        #expect(flows.header.dataVersion == "v1-fixture" && flows.header.builtAgainst.isEmpty)
        let payload = Data(try ArtifactHeader.decode(from: file).payload)
        #expect(payload.prefix(4) == Data("FLOW".utf8))
        #expect(payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) } == 1 && flows.payloadRevision == 1)
        // Ten sections, every one this reader knows.
        #expect(payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) } == 10)

        let june1 = try #require(ServiceDate(yyyymmdd: "20260601"))
        #expect(flows.departureWindow == FlowWindow(start: june1, dayCount: 92) && flows.arrivalWindow == FlowWindow(start: june1, dayCount: 92))
        #expect(flows.departureWindow.end == ServiceDate(yyyymmdd: "20260831"))
        #expect(flows.flags == [.customerTripsOnly])
        #expect(flows.smoothing == FlowSmoothingParameters(kappaCellMilli: 4_000, kappaHourMilli: 8_000, kappaDispersionMilli: 6_000,
                                                           neighborCount: 8, neighborRadiusMeters: 1_000))
        #expect(flows.holidays == [ServiceDate(yyyymmdd: "20260703")])

        #expect(flows.count == 3)
        #expect((0..<3).map(flows.key) == ["3576.1", "5329.08", "JC115"])
        #expect(flows.row(forKey: "JC115") == 2 && flows.row(forKey: "5329.8") == nil)
        #expect(flows.rowTable(forKeys: ["JC115", "none", "3576.1"]) == [2, 0xFFFF, 0])
        #expect((0..<3).map(flows.latE6) == [40_700_000, 40_701_000, 40_702_000])
        #expect((0..<3).map(flows.lonE6) == [-74_000_000, -74_002_000, -74_004_000])
        #expect((0..<3).map(flows.capacity) == [0, 10, 20])
        #expect((0..<3).map { flows.activeDays($0, .weekday, .departures) } == [60, 61, 62])
        #expect((0..<3).map { flows.activeDays($0, .weekday, .arrivals) } == [61, 62, 63])
        #expect((0..<3).map { flows.activeDays($0, .weekend, .departures) } == [20, 21, 22])
        #expect((0..<3).map { flows.activeDays($0, .weekend, .arrivals) } == [21, 22, 23])
        #expect((0..<3).map(flows.flags) == [[.inGBFS, .lowData], [.inGBFS], [.inGBFS]])

        // Cells, slot order meanClassic, varianceClassic, meanEbike, varianceEbike, varianceAny.
        func slots(_ row: Int, _ dayType: FlowDayType, _ direction: FlowDirection, bin: Int) -> [Float] {
            FlowSlot.allCases.map { flows.value(row, dayType, direction, $0, bin: bin) }
        }
        #expect(slots(0, .weekday, .departures, bin: 0) == [0, 0, 0, 0, 0.25])
        #expect(slots(0, .weekday, .departures, bin: 4) == [0.5, 0.75, 0.25, 0.5, 1.5])
        #expect(slots(1, .weekday, .arrivals, bin: 37) == [1.25, 1.875, 0.5, 1, 3.125])
        #expect(slots(1, .weekend, .departures, bin: 13) == [1.625, 2.4375, 0.5, 1, 3.6875])
        #expect(slots(2, .weekend, .arrivals, bin: 37) == [0.375, 0.5625, 0.75, 1.5, 2.3125])
        #expect(slots(2, .weekend, .departures, bin: 95) == [0, 0, 1, 2, 2.25])
        #expect(flows.meanAny(2, .weekend, .arrivals, bin: 37) == 1.125 && flows.varianceAny(2, .weekend, .arrivals, bin: 37) == 2.3125)
        #expect(flows.mean(1, .weekday, .arrivals, .ebike, bin: 37) == 0.5 && flows.variance(1, .weekday, .arrivals, .classic, bin: 37) == 1.875)
        flows.withSeries(1, .weekday, .departures, .meanClassic) { series in
            #expect(series.count == 96)
            #expect(series.prefix(8).map(HalfFloat.double(fromBits:)) == [0.875, 1, 1.125, 1.25, 1.375, 0.875, 1, 1.125])
        }
        // Every cell: dyadic values, so the sum is exact.
        var total = 0.0
        for row in 0..<3 {
            for dayType in FlowDayType.allCases {
                for direction in FlowDirection.allCases {
                    for slot in FlowSlot.allCases {
                        for bin in 0..<96 { total += Double(flows.value(row, dayType, direction, slot, bin: bin)) }
                    }
                }
            }
        }
        #expect(total == 7_052.5)
    }

    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func rejectsTheCommittedFileUnderAnyOtherFormatVersion() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        for version: UInt16 in [0, 2] {
            #expect(throws: FlowsFormatError.unsupportedFormatVersion(version)) { try reader(V1Fixtures.withFormatVersion(version, file)) }
        }
    }

    /// Rewrites `Tests/Fixtures/v1/flows.bin` from ``HandBuiltFlows``. Only with
    /// `BR_WRITE_V1_FIXTURES=1`; see ``V1Fixtures`` for when that is right.
    @Test(.enabled(if: V1Fixtures.regenerating, "set BR_WRITE_V1_FIXTURES=1 to rewrite the v1 fixtures"))
    func writeV1Fixture() throws {
        let file = try HandBuiltFlows.artifact(dataVersion: V1Fixtures.dataVersion)
        _ = try reader(file)
        try V1Fixtures.write(file, to: Self.fixtureName)
    }
}
