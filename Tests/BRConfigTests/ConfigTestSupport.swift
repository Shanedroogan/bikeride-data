import BRConfig
import BRCore
import BRData
import Foundation

/// A small config document with every key spelled out (no value comes from `Data/`), so the
/// payload golden doesn't move when the reviewed sources do.
enum HandBuiltConfig {
    static let document = ConfigDocument(
        minAppFormat: 1,
        flags: ["zeta": false, "alpha": true],
        calendar: ConfigCalendar(holidays: [
            ConfigHoliday(date: ServiceDate(year: 2026, month: 11, day: 26), name: "Thanksgiving Day", bikeShareDayType: .weekend,
                          lirrOffPeak: true),
            ConfigHoliday(date: ServiceDate(year: 2026, month: 11, day: 27), name: "Day after Thanksgiving", bikeShareDayType: .weekend,
                          lirrOffPeak: false),
        ]),
        fares: ConfigFares(
            mta: ConfigMTAFares(
                baseFareCents: 300, expressBusFareCents: 725, expressBusStepUpCents: 425, transferWindowSeconds: 7200,
                transferTable: ConfigTransferTable(
                    subway: ConfigTransferRow(subway: .pay, localBus: .free, expressBus: .stepUp),
                    localBus: ConfigTransferRow(subway: .free, localBus: .free, expressBus: .stepUp),
                    expressBus: ConfigTransferRow(subway: .free, localBus: .free, expressBus: .free)
                ),
                outOfSystemTransfers: [ConfigStationPair("S:A1", "S:B1")],
                inSystemTransfers: [ConfigStationPair("S:C1", "S:D1")],
                statenIslandRailway: ConfigStatenIslandRailway(routes: ["S:SI"], fareStations: ["S:S1"])
            ),
            path: ConfigPATHFares(fareCents: 325),
            lirr: ConfigLIRRFares(
                stations: [
                    ConfigLIRRStation(stop: "L:1", zone: 1, cityFare: .cityTicket),
                    ConfigLIRRStation(stop: "L:2", zone: 3, cityFare: .cityTicket),
                    ConfigLIRRStation(stop: "L:3", zone: 4, cityFare: .farRockaway),
                ],
                zoneFares: [
                    ConfigLIRRZoneFare(fromZone: 1, toZone: 1, peakCents: 725, offPeakCents: 525),
                    ConfigLIRRZoneFare(fromZone: 1, toZone: 3, peakCents: 725, offPeakCents: 525),
                    ConfigLIRRZoneFare(fromZone: 1, toZone: 4, peakCents: 1350, offPeakCents: 1000),
                    ConfigLIRRZoneFare(fromZone: 3, toZone: 3, peakCents: 600, offPeakCents: 450),
                    ConfigLIRRZoneFare(fromZone: 3, toZone: 4, peakCents: 900, offPeakCents: 675),
                    ConfigLIRRZoneFare(fromZone: 4, toZone: 4, peakCents: 375, offPeakCents: 375),
                ],
                cityTicket: ConfigPeakFare(peakCents: 725, offPeakCents: 525),
                farRockawayTicket: ConfigFarRockawayTicket(peakCents: 725, offPeakCents: 525, destinationZone: 1),
                peakRule: ConfigLIRRPeakRule(terminalArrivals: ConfigMinuteWindow(startMinute: 360, endMinute: 600),
                                             terminalDepartures: ConfigMinuteWindow(startMinute: 960, endMinute: 1200)),
                nycTerminals: ["L:1"]
            ),
            citiBike: ConfigCitiBikeFares(
                plans: ConfigCitiBikePlans(
                    nonMember: ConfigCitiBikePlan(unlockFeeCents: 499, classicIncludedMinutes: 30, classicPerMinuteCents: 41,
                                                  ebikePerMinuteCents: 41, verified: true),
                    member: ConfigCitiBikePlan(unlockFeeCents: 0, classicIncludedMinutes: 45, classicPerMinuteCents: 27,
                                               ebikePerMinuteCents: 27, ebikeManhattanCap: ConfigManhattanCap(amountCents: 540, maxRideMinutes: 45),
                                               planPriceCents: 23_900, verified: true),
                    dayPass: ConfigCitiBikePlan(unlockFeeCents: 0, classicIncludedMinutes: 30, classicPerMinuteCents: 41,
                                                ebikePerMinuteCents: 41, planPriceCents: 2500, verified: false),
                    reducedFare: ConfigCitiBikePlan(unlockFeeCents: 0, classicIncludedMinutes: 45, classicPerMinuteCents: 27,
                                                    ebikePerMinuteCents: 27, verified: false)
                ),
                taxConfirmed: false
            )
        ),
        transit: ConfigTransit(
            sameStopChangeSeconds: ConfigSystemValues(subway: 30, bus: 60, lirr: 180, ferry: 60, path: 30),
            guaranteedTransferSeconds: 0, minimumPlatformChangeSeconds: 30,
            accessSlack: ConfigAccessSlack(baseSeconds: 30, walkPercent: 5),
            afterBikeChange: ConfigAfterBikeChange(minSeconds: 60, ridePercent: 10),
            extraLeg: ConfigExtraLeg(pruneRound: 4, minSavingSeconds: 480),
            maxJourneySeconds: 21_600, accessWalkLimitSeconds: 1200, directWalkLimitSeconds: 3600, originSnapMeters: 250,
            links: ConfigLinks(
                stationAccessSeconds: ConfigSystemValues(subway: 120, bus: 30, lirr: 240, ferry: 120, path: 120),
                maxSnapMeters: ConfigSystemValues(subway: 150, bus: 150, lirr: 150, ferry: 250, path: 150),
                maxFootpathWalkSeconds: 480, minTransferSeconds: 30, stationLinkMaxWalkMeters: 350, walkSpeedHundredthsMph: 350,
                streetAccessOnlyInsideServiceArea: [.path],
                fixedTransfers: [ConfigFixedTransfer(from: "P:place_A", to: "S:A1", seconds: 240)]
            )
        ),
        bikeShare: ConfigBikeShare(
            regions: ConfigBikeShareRegions(nyc: ["158", "71"], newJersey: ["70"]),
            excludedRegions: ["189"],
            vehicleTypes: ConfigVehicleTypes(classic: ["1"], ebike: ["2"]),
            maxStatusAgeSeconds: 600,
            valet: [ConfigValetStation(stationID: "abc-123", latE6: 40_750_000, lonE6: -73_990_000)]
        ),
        alerts: ConfigAlerts(pathKeywords: [
            ConfigPathKeywordRule(keywords: ["no service", "suspend"], severity: .suspended),
            ConfigPathKeywordRule(keywords: ["delay"], severity: .delays),
        ])
    )

    static func artifact(_ document: ConfigDocument = document, dataVersion: String = "hand-built") throws -> Data {
        ConfigArtifactWriter.artifact(json: try ConfigArtifactWriter.json(document), dataVersion: dataVersion)
    }

    /// `json` wrapped as a config file (header + payload with an empty tail).
    static func file(json: Data) -> Data {
        ArtifactHeader(kind: .config, formatVersion: ArtifactKind.config.currentFormatVersion, dataVersion: "test",
                       builderSwiftVersion: BuildInfo.swiftVersion).assemble(payload: ConfigArtifactWriter.payload(json: json))
    }

    /// The document as a mutable JSON tree.
    static func tree(_ document: ConfigDocument = document) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: ConfigArtifactWriter.json(document)) as! [String: Any]
    }

    static func json(_ tree: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys])
    }
}

func sha256Hex(_ data: Data) throws -> String {
    #if canImport(CryptoKit)
    return CryptoKitHasher().sha256(of: data).hex
    #else
    return try ProcessHasher(runner: ProcessToolRunner()).sha256(of: data).hex
    #endif
}

extension Dictionary where Key == String, Value == Any {
    /// Sets `value` at a dotted path of object keys, creating nothing: every parent must exist.
    mutating func set(_ path: String, _ value: Any?) {
        var keys = path.split(separator: ".").map(String.init)
        let last = keys.removeLast()
        func update(_ object: inout [String: Any], _ rest: ArraySlice<String>) {
            guard let key = rest.first else {
                object[last] = value
                return
            }
            var child = object[key] as! [String: Any]
            update(&child, rest.dropFirst())
            object[key] = child
        }
        update(&self, keys[...])
    }
}
