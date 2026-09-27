import BRBuild
import BRConfig
import BRCore
import BRTimetable
import Foundation
import Testing

/// The cross-artifact checks the config compiler and the gate share, on tiny compiled artifacts.
@Suite struct ReferenceChecksTests {
    let world: ReferenceFixtures.World

    init() throws {
        world = try ReferenceFixtures.world()
    }

    var inputs: ReferenceChecks.Inputs {
        ReferenceChecks.Inputs(timetables: [.subway: world.subway, .lirr: world.lirr], stations: world.stations,
                               pricingPlans: Data(ReferenceFixtures.pricingPlans.utf8), stationSelectionRegions: ["70", "71"])
    }

    @Test func theFixtureConfigPassesEveryCheck() throws {
        let checks = ReferenceChecks.run(ReferenceFixtures.document, inputs: inputs)
        #expect(checks.map(\.name) == ["mtaStationPairs", "statenIslandRailway", "lirrZones", "fixedTransfers", "valetStations",
                                       "stationRegions", "stationSelectionRegions", "citiBikePricing"])
        for check in checks {
            #expect(check.passed && check.errors.isEmpty && check.warnings.isEmpty, "\(check)")
            #expect(check.checked > 0, "\(check.name)")
        }
        #expect(ConfigValidation.canonicalIssues(ReferenceFixtures.document).isEmpty)
    }

    @Test func missingInputsSkipTheirChecks() {
        let checks = ReferenceChecks.run(ReferenceFixtures.document, inputs: ReferenceChecks.Inputs(stationSelectionRegions: nil))
        #expect(checks.allSatisfy { $0.skipped != nil && $0.errors.isEmpty }, "\(checks)")
        #expect(checks.first { $0.name == "fixedTransfers" }?.skipped == "tt-lirr.bin, tt-subway.bin missing")
    }

    @Test func mtaPairsMustBeStationsOfTheSubwayFeed() {
        var mta = ReferenceFixtures.document.fares.mta
        mta.outOfSystemTransfers = [ConfigStationPair("S:A", "S:NOPE"), ConfigStationPair("S:AN", "S:C")]
        let check = ReferenceChecks.mtaStationPairs(mta, subway: world.subway)
        #expect(check.errors == [
            "fares.mta.outOfSystemTransfers: S:NOPE is not in the subway feed",
            "fares.mta.outOfSystemTransfers: S:AN is a stop, not a station",
        ])
    }

    @Test func anInSystemPairAlreadyInTransfersTxtIsStale() {
        var mta = ReferenceFixtures.document.fares.mta
        mta.inSystemTransfers = [ConfigStationPair("S:B", "S:A")]
        #expect(ReferenceChecks.mtaStationPairs(mta, subway: world.subway).errors
            == ["fares.mta.inSystemTransfers: S:A–S:B is in transfers.txt now; drop it from Data/fares/mta.json"])
    }

    @Test func theSIRMustExist() {
        let bad = ConfigStatenIslandRailway(routes: ["S:SI", "S:SIX"], fareStations: ["S:S1", "S:S9", "S:S2N"])
        #expect(ReferenceChecks.statenIslandRailway(bad, subway: world.subway).errors == [
            "fares.mta.statenIslandRailway.routes: S:SIX is not a subway-feed route",
            "fares.mta.statenIslandRailway.fareStations: S:S9 is not in the subway feed",
            "fares.mta.statenIslandRailway.fareStations: S:S2N is a stop, not a station",
        ])
    }

    @Test func everyServedLIRRStopNeedsAZone() {
        var lirr = ReferenceFixtures.document.fares.lirr
        lirr.stations.removeAll { $0.stop == "L:L2" }
        lirr.stations.append(ConfigLIRRStation(stop: "L:L3", zone: 4, cityFare: .farRockaway))
        lirr.stations.append(ConfigLIRRStation(stop: "L:LH", zone: 4, cityFare: .none))
        let check = ReferenceChecks.lirrZones(lirr, lirr: world.lirr)
        // L2 has service (alighting only) but no zone. The yard stop LH (no pickup, no drop-off)
        // needs none. The timetable compiler drops stops riders can't use (LH, and L3, which no
        // trip calls at; Belmont Park and Hillside on real data), so zoning them is a warning.
        #expect(check.errors == ["fares.lirr.stations: L:L2 Suburb has service but no fare zone"])
        #expect(check.warnings == ["fares.lirr.stations: L:L3 is zoned but not in tt-lirr",
                                   "fares.lirr.stations: L:LH is zoned but not in tt-lirr"])
    }

    @Test func nycTerminalsMustBeServedStopsOfTheFeed() {
        var lirr = ReferenceFixtures.document.fares.lirr
        lirr.nycTerminals = ["L:L1", "L:L3", "L:LH"]
        #expect(ReferenceChecks.lirrZones(lirr, lirr: world.lirr).errors == [
            "fares.lirr.nycTerminals: L:L3 is not in tt-lirr",
            "fares.lirr.nycTerminals: L:LH is not in tt-lirr",
        ])
    }

    @Test func fixedTransfersMustResolveToRoutableStops() {
        let transfers = [
            ConfigFixedTransfer(from: "L:L1", to: "S:A", seconds: 240), // a station with a routable platform
            ConfigFixedTransfer(from: "L:L2", to: "S:CN", seconds: 60), // a platform itself
            ConfigFixedTransfer(from: "L:L1", to: "S:Z", seconds: 60), // no trip calls at ZN, so the compiler drops Z
            ConfigFixedTransfer(from: "L:NOPE", to: "S:B", seconds: 60),
        ]
        let check = ReferenceChecks.fixedTransfers(transfers, timetables: [.subway: world.subway, .lirr: world.lirr])
        #expect(check.checked == 4)
        #expect(check.errors == [
            "transit.links.fixedTransfers: S:Z (L:L1→S:Z) is not in its timetable",
            "transit.links.fixedTransfers: L:NOPE (L:NOPE→S:B) is not in its timetable",
        ])
    }

    @Test func valetStationsMustBeNearTheirStation() {
        let valet = [
            ConfigValetStation(stationID: "one", latE6: 40_750_400, lonE6: -73_990_000), // about 44 m
            ConfigValetStation(stationID: "two", latE6: 40_751_450, lonE6: -73_990_000), // about 61 m
            ConfigValetStation(stationID: "three", latE6: 40_750_000, lonE6: -73_990_000),
        ]
        let check = ReferenceChecks.valetStations(valet, stations: world.stations)
        #expect(check.errors == [
            "bikeShare.valet: two Two is 61 m from its listed coordinate (limit 50 m)",
            "bikeShare.valet: three is not in stations.bin",
        ])
    }

    @Test func stationsMustLieInTheConfiguredRegions() {
        var bikeShare = ReferenceFixtures.document.bikeShare
        bikeShare.regions.newJersey = ["311"]
        #expect(ReferenceChecks.stationRegions(bikeShare, stations: world.stations).errors
            == ["stations.bin: 1 station(s) in region 70, which bikeShare.regions doesn't list"])
        #expect(ReferenceChecks.stationSelectionRegions(bikeShare, selection: ["70", "71"]).warnings.count == 1)
        #expect(ReferenceChecks.stationSelectionRegions(ReferenceFixtures.document.bikeShare, selection: ["70", "71"]).warnings.isEmpty)
    }

    @Test func theRepositoryRegionsMatchTheStationsCompiler() throws {
        let document = try ConfigSources(root: RepositoryData.root).load()
        let check = ReferenceChecks.stationSelectionRegions(document.bikeShare, selection: StationSelection().regionIDs)
        #expect(check.warnings.isEmpty)
    }

    @Test func pricingDriftIsAWarning() throws {
        let fares = ReferenceFixtures.document.fares.citiBike
        let live = ReferenceChecks.citiBikePricing(fares, pricingPlans: Data(ReferenceFixtures.pricingPlans.utf8))
        #expect(live.checked == 1 && live.warnings.isEmpty && live.errors.isEmpty)

        // Numbers instead of strings parse too.
        let numeric = ReferenceFixtures.pricingPlans.replacingOccurrences(of: #""price":"4.99""#, with: #""price":4.99"#)
        #expect(ReferenceChecks.citiBikePricing(fares, pricingPlans: Data(numeric.utf8)).warnings.isEmpty)

        let raised = ReferenceFixtures.pricingPlans
            .replacingOccurrences(of: #""price":"4.99""#, with: #""price":"5.49""#)
            .replacingOccurrences(of: #""rate":0.41"#, with: #""rate":0.45"#)
        let drift = ReferenceChecks.citiBikePricing(fares, pricingPlans: Data(raised.utf8))
        #expect(drift.errors.isEmpty)
        #expect(drift.warnings == [
            "GBFS EBIKE_SINGLE_RIDE price 5.49 ≠ fares.citiBike.plans.nonMember.unlockFeeCents 499",
            "GBFS EBIKE_SINGLE_RIDE per-minute rate 0.45 ≠ fares.citiBike.plans.nonMember.ebikePerMinuteCents 41",
        ])

        let renamed = ReferenceFixtures.pricingPlans.replacingOccurrences(of: "EBIKE_SINGLE_RIDE", with: "EBIKE_DAY")
        #expect(ReferenceChecks.citiBikePricing(fares, pricingPlans: Data(renamed.utf8)).warnings == [
            "GBFS plan EBIKE_DAY (Synthetic e-bike plan) is not compared with any config plan",
            "GBFS system_pricing_plans lists no EBIKE_SINGLE_RIDE plan; nothing compared",
        ])
        let garbage = ReferenceChecks.citiBikePricing(fares, pricingPlans: Data("<html>".utf8))
        #expect(garbage.errors.isEmpty && garbage.warnings.count == 1)
    }
}
