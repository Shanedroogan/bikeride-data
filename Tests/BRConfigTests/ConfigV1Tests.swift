import BRConfig
import BRCore
import BRData
import Foundation
import Testing

/// Format 1 of `config`, frozen 2026-09-27 (`docs/formats.md`, "Compatibility" and "config"): the
/// payload golden for ``HandBuiltConfig``, the committed v1 file, and the formatVersion and
/// payloadRevision gates.
@Suite struct ConfigV1Tests {
    /// SHA-256 of the writer's payload for ``HandBuiltConfig`` (the header is left out: it embeds
    /// builderSwiftVersion). Every test run is a fresh process with a fresh `Hasher` seed, so this
    /// golden passing run after run, on macOS and Linux, is the cross-process determinism check.
    /// What may change it:
    /// - a change to the envelope or to the meaning of a required key. That is a new
    ///   formatVersion, because a v1 reader would misread it; never re-pin this digest for one.
    /// - a deliberate change to the hand-built document, or to what the writer puts in a v1
    ///   payload (such as a newly defined optional key it fills). Review the new bytes, then pin
    ///   the new digest.
    /// Changes to the reviewed sources in `Data/` don't reach it: every value is hand-set. The
    /// format-0 draft (revision 1) froze unchanged, so this is the draft's digest.
    static let payloadGolden = "4bd407281fa1e40f6c091141f400a2b1ddddeb381989b48aa7f7a61a924b864f"

    static let fixtureName = "config.bin"

    func reader(_ file: Data) throws -> MappedConfig {
        try MappedConfig(artifact: MappedArtifact(fileBytes: file, expecting: .config))
    }

    @Test func payloadMatchesTheGolden() throws {
        let payload = try ConfigArtifactWriter.payload(HandBuiltConfig.document)
        let file = try HandBuiltConfig.artifact(dataVersion: V1Fixtures.dataVersion)
        #expect(Data(try ArtifactHeader.decode(from: file).payload) == payload)
        #expect(try V1Fixtures.payloadSHA256(file) == Self.payloadGolden)
        // The header's dataVersion does not reach the payload.
        #expect(try V1Fixtures.payloadSHA256(HandBuiltConfig.artifact(dataVersion: "other")) == Self.payloadGolden)
        // The hand-built document is a valid v1 file.
        let config = try reader(file)
        #expect(config.header.kind == .config && config.header.formatVersion == 1 && config.header.builtAgainst.isEmpty)
        #expect(config.document == HandBuiltConfig.document && config.extensions == .empty)
    }

    @Test func rejectsEveryOtherFormatVersionAndPayloadRevision() throws {
        let file = try HandBuiltConfig.artifact(dataVersion: V1Fixtures.dataVersion)
        _ = try reader(file)
        for version: UInt16 in [0, 2] {
            #expect(throws: ConfigFormatError.unsupportedFormatVersion(version)) { try reader(V1Fixtures.withFormatVersion(version, file)) }
        }
        let (header, payload) = try ArtifactHeader.decode(from: file)
        for revision: UInt32 in [0, 2] {
            var bytes = Data(payload)
            withUnsafeBytes(of: revision.littleEndian) { bytes.replaceSubrange(4..<8, with: $0) }
            #expect(throws: ConfigFormatError.unsupportedPayloadRevision(revision)) { try reader(header.assemble(payload: bytes)) }
        }
    }

    /// A reader of this build opens the committed v1 file (`MappedConfig` decodes the document and
    /// runs the intrinsic checks) and reads what was written on the day the format froze. Every
    /// value is a literal: the file is frozen, not rebuilt.
    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func opensTheCommittedV1File() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        let config = try reader(file)
        #expect(config.header.kind == .config && config.header.formatVersion == 1)
        #expect(config.header.dataVersion == "v1-fixture" && config.header.builtAgainst.isEmpty)
        let payload = Data(try ArtifactHeader.decode(from: file).payload)
        #expect(payload.prefix(4) == Data("CNFG".utf8))
        #expect(payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) } == 1)
        #expect(config.extensions == .empty)
        let text = try #require(String(data: config.json, encoding: .utf8))
        #expect(text.hasPrefix(#"{"alerts":{"pathKeywords":[{"keywords":["no service","suspend"],"severity":"suspended"}"#))

        let document = config.document
        #expect(document.minAppFormat == 1 && document.flags == ["alpha": true, "zeta": false])
        #expect(document.calendar.holidays == [
            ConfigHoliday(date: ServiceDate(year: 2026, month: 11, day: 26), name: "Thanksgiving Day", bikeShareDayType: .weekend, lirrOffPeak: true),
            ConfigHoliday(date: ServiceDate(year: 2026, month: 11, day: 27), name: "Day after Thanksgiving", bikeShareDayType: .weekend,
                          lirrOffPeak: false),
        ])

        let mta = document.fares.mta
        #expect(mta.baseFareCents == 300 && mta.expressBusFareCents == 725 && mta.expressBusStepUpCents == 425 && mta.transferWindowSeconds == 7200)
        #expect(mta.transferTable.subway == ConfigTransferRow(subway: .pay, localBus: .free, expressBus: .stepUp))
        #expect(mta.transferTable.localBus == ConfigTransferRow(subway: .free, localBus: .free, expressBus: .stepUp))
        #expect(mta.transferTable.expressBus == ConfigTransferRow(subway: .free, localBus: .free, expressBus: .free))
        #expect(mta.outOfSystemTransfers == [ConfigStationPair("S:A1", "S:B1")] && mta.inSystemTransfers == [ConfigStationPair("S:C1", "S:D1")])
        #expect(mta.statenIslandRailway == ConfigStatenIslandRailway(routes: ["S:SI"], fareStations: ["S:S1"]))
        #expect(document.fares.path == ConfigPATHFares(fareCents: 325))

        let lirr = document.fares.lirr
        #expect(lirr.stations == [
            ConfigLIRRStation(stop: "L:1", zone: 1, cityFare: .cityTicket), ConfigLIRRStation(stop: "L:2", zone: 3, cityFare: .cityTicket),
            ConfigLIRRStation(stop: "L:3", zone: 4, cityFare: .farRockaway),
        ])
        #expect(lirr.zoneFares.map { [$0.fromZone, $0.toZone, $0.peakCents, $0.offPeakCents] } == [
            [1, 1, 725, 525], [1, 3, 725, 525], [1, 4, 1350, 1000], [3, 3, 600, 450], [3, 4, 900, 675], [4, 4, 375, 375],
        ])
        #expect(lirr.cityTicket == ConfigPeakFare(peakCents: 725, offPeakCents: 525))
        #expect(lirr.farRockawayTicket == ConfigFarRockawayTicket(peakCents: 725, offPeakCents: 525, destinationZone: 1))
        #expect(lirr.peakRule == ConfigLIRRPeakRule(terminalArrivals: ConfigMinuteWindow(startMinute: 360, endMinute: 600),
                                                    terminalDepartures: ConfigMinuteWindow(startMinute: 960, endMinute: 1200)))
        #expect(lirr.nycTerminals == ["L:1"])

        let citiBike = document.fares.citiBike
        #expect(!citiBike.taxConfirmed)
        #expect(citiBike.plans.nonMember == ConfigCitiBikePlan(unlockFeeCents: 499, classicIncludedMinutes: 30, classicPerMinuteCents: 41,
                                                               ebikePerMinuteCents: 41, verified: true))
        #expect(citiBike.plans.member == ConfigCitiBikePlan(unlockFeeCents: 0, classicIncludedMinutes: 45, classicPerMinuteCents: 27,
                                                            ebikePerMinuteCents: 27, ebikeManhattanCap: ConfigManhattanCap(amountCents: 540, maxRideMinutes: 45),
                                                            planPriceCents: 23_900, verified: true))
        #expect(citiBike.plans.dayPass.planPriceCents == 2500 && citiBike.plans.dayPass.ebikeManhattanCap == nil && !citiBike.plans.dayPass.verified)
        #expect(citiBike.plans.reducedFare.planPriceCents == nil && citiBike.plans.reducedFare.classicIncludedMinutes == 45)

        let transit = document.transit
        #expect(transit.sameStopChangeSeconds == ConfigSystemValues(subway: 30, bus: 60, lirr: 180, ferry: 60, path: 30))
        #expect(transit.guaranteedTransferSeconds == 0 && transit.minimumPlatformChangeSeconds == 30)
        #expect(transit.accessSlack == ConfigAccessSlack(baseSeconds: 30, walkPercent: 5))
        #expect(transit.afterBikeChange == ConfigAfterBikeChange(minSeconds: 60, ridePercent: 10))
        #expect(transit.extraLeg == ConfigExtraLeg(pruneRound: 4, minSavingSeconds: 480))
        #expect(transit.maxJourneySeconds == 21_600 && transit.accessWalkLimitSeconds == 1200 && transit.directWalkLimitSeconds == 3600)
        #expect(transit.originSnapMeters == 250)
        let links = transit.links
        #expect(links.stationAccessSeconds == ConfigSystemValues(subway: 120, bus: 30, lirr: 240, ferry: 120, path: 120))
        #expect(links.maxSnapMeters == ConfigSystemValues(subway: 150, bus: 150, lirr: 150, ferry: 250, path: 150))
        #expect(links.maxFootpathWalkSeconds == 480 && links.minTransferSeconds == 30 && links.stationLinkMaxWalkMeters == 350)
        #expect(links.walkSpeedHundredthsMph == 350 && links.streetAccessOnlyInsideServiceArea == [.path])
        #expect(links.fixedTransfers == [ConfigFixedTransfer(from: "P:place_A", to: "S:A1", seconds: 240)])

        let bikeShare = document.bikeShare
        #expect(bikeShare.regions == ConfigBikeShareRegions(nyc: ["158", "71"], newJersey: ["70"]) && bikeShare.excludedRegions == ["189"])
        #expect(bikeShare.vehicleTypes == ConfigVehicleTypes(classic: ["1"], ebike: ["2"]) && bikeShare.maxStatusAgeSeconds == 600)
        #expect(bikeShare.valet == [ConfigValetStation(stationID: "abc-123", latE6: 40_750_000, lonE6: -73_990_000)])

        #expect(document.alerts.pathKeywords == [
            ConfigPathKeywordRule(keywords: ["no service", "suspend"], severity: .suspended),
            ConfigPathKeywordRule(keywords: ["delay"], severity: .delays),
        ])
    }

    @Test(.disabled(if: V1Fixtures.regenerating, "rewriting the v1 fixtures"))
    func rejectsTheCommittedFileUnderAnyOtherFormatVersion() throws {
        let file = try V1Fixtures.data(Self.fixtureName)
        for version: UInt16 in [0, 2] {
            #expect(throws: ConfigFormatError.unsupportedFormatVersion(version)) { try reader(V1Fixtures.withFormatVersion(version, file)) }
        }
    }

    /// Rewrites `Tests/Fixtures/v1/config.bin` from ``HandBuiltConfig``. Only with
    /// `BR_WRITE_V1_FIXTURES=1`; see ``V1Fixtures`` for when that is right.
    @Test(.enabled(if: V1Fixtures.regenerating, "set BR_WRITE_V1_FIXTURES=1 to rewrite the v1 fixtures"))
    func writeV1Fixture() throws {
        let file = try HandBuiltConfig.artifact(dataVersion: V1Fixtures.dataVersion)
        _ = try reader(file)
        try V1Fixtures.write(file, to: Self.fixtureName)
    }
}
