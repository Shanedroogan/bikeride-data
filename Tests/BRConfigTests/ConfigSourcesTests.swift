import BRBuild
import BRConfig
import BRCore
import Foundation
import Testing

/// The reviewed sources in `Data/` and their strict reader.
@Suite struct ConfigSourcesTests {
    let document: ConfigDocument

    init() throws {
        document = try ConfigSources(root: RepositoryData.root).load()
    }

    // MARK: - The values are the 2026 literals they replace

    /// Every value that moved out of Swift literals, typed again from the literal it replaces
    /// (BikeRideKit unless noted; paths at the 2026-09-27 move). The drift test that compiles
    /// `Data/` against the app's own fixtures comes with the engine switch (P3b); until then this
    /// is the check that nothing changed in transcription.
    @Test func faresEqualThe2026Literals() {
        let mta = document.fares.mta
        // BRPlanner/FareConfig.swift:89-110 (MTAFares.nyc2026, inSystemTransfers2026).
        #expect(mta.baseFareCents == 300 && mta.expressBusFareCents == 725 && mta.expressBusStepUpCents == 425)
        #expect(mta.transferWindowSeconds == 2 * 3600)
        #expect(mta.outOfSystemTransfers == [ConfigStationPair("S:254", "S:L26"), ConfigStationPair("S:629", "S:B08"),
                                             ConfigStationPair("S:B08", "S:R11")])
        #expect(mta.inSystemTransfers == [ConfigStationPair("S:142", "S:R27")])
        // FareConfig.swift:126-132 (StatenIslandRailwayFares.nyc2026).
        #expect(mta.statenIslandRailway == ConfigStatenIslandRailway(routes: ["S:SI"], fareStations: ["S:S30", "S:S31"]))
        // BRPlanner/FareEngine.swift:147-161 (the OMNY transfer rules).
        #expect(mta.transferTable == ConfigTransferTable(
            subway: ConfigTransferRow(subway: .pay, localBus: .free, expressBus: .stepUp),
            localBus: ConfigTransferRow(subway: .free, localBus: .free, expressBus: .stepUp),
            expressBus: ConfigTransferRow(subway: .free, localBus: .free, expressBus: .free)
        ))
        // FareConfig.swift:33 (PATHFares.panynj2026).
        #expect(document.fares.path == ConfigPATHFares(fareCents: 325))

        let lirr = document.fares.lirr
        // FareConfig.swift:172, 229-230 (CityTicket; the Far Rockaway Ticket costs the same);
        // FareEngine.swift:55 (farRockawayTicketZone). Not to Mets-Willets Point (L:199): the
        // user's TrainTime check, 2026-09-29.
        #expect(lirr.cityTicket == ConfigPeakFare(peakCents: 725, offPeakCents: 525))
        #expect(lirr.farRockawayTicket == ConfigFarRockawayTicket(peakCents: 725, offPeakCents: 525, destinationZone: 1,
                                                                  excludedDestinations: ["L:199"]))
        // LIRRPeakRule.swift:36-39 (weekdayCommute).
        #expect(lirr.peakRule == ConfigLIRRPeakRule(terminalArrivals: ConfigMinuteWindow(startMinute: 6 * 60, endMinute: 10 * 60),
                                                    terminalDepartures: ConfigMinuteWindow(startMinute: 16 * 60, endMinute: 20 * 60)))
        // FareConfig.swift:262-268 (nycTerminals2026).
        #expect(lirr.nycTerminals == ["L:118", "L:237", "L:241", "L:349", "L:90"])
        // The zone CSVs (Data/fares/lirr, the source LIRRZoneTable2026.swift was generated from).
        #expect(lirr.stations.count == 126 && lirr.zoneFares.count == 36)
        #expect(lirr.stations.first { $0.stop == "L:237" } == ConfigLIRRStation(stop: "L:237", zone: 1, cityFare: .cityTicket))
        #expect(lirr.stations.first { $0.stop == "L:24" } == ConfigLIRRStation(stop: "L:24", zone: 4, cityFare: .none))
        #expect(lirr.stations.filter { $0.cityFare == .farRockaway }.map(\.zone) == [4])
        #expect(lirr.stations.filter { $0.cityFare == .cityTicket }.count == 25)
        #expect(lirr.zoneFares.first { $0.fromZone == 1 && $0.toZone == 14 }
            == ConfigLIRRZoneFare(fromZone: 1, toZone: 14, peakCents: 3300, offPeakCents: 2450))
        #expect(lirr.zoneFares.first { $0.fromZone == 3 && $0.toZone == 3 }
            == ConfigLIRRZoneFare(fromZone: 3, toZone: 3, peakCents: 600, offPeakCents: 450))

        // BRPlanner/CitiBikePricing.swift:86-120 (CitiBikePrices.nyc2026).
        let member = ConfigCitiBikePlan(unlockFeeCents: 0, classicIncludedMinutes: 45, classicPerMinuteCents: 27, ebikePerMinuteCents: 27,
                                        ebikeManhattanCap: ConfigManhattanCap(amountCents: 540, maxRideMinutes: 45), planPriceCents: 23_900,
                                        verified: true)
        // Reduced Fare: the member's classic terms, $0.14/min e-bikes, no Manhattan cap, no plan price.
        var reducedFare = member
        reducedFare.ebikePerMinuteCents = 14
        reducedFare.ebikeManhattanCap = nil
        reducedFare.planPriceCents = nil
        reducedFare.verified = false
        #expect(document.fares.citiBike == ConfigCitiBikeFares(
            plans: ConfigCitiBikePlans(
                nonMember: ConfigCitiBikePlan(unlockFeeCents: 499, classicIncludedMinutes: 30, classicPerMinuteCents: 41,
                                              ebikePerMinuteCents: 41, verified: true),
                member: member,
                dayPass: ConfigCitiBikePlan(unlockFeeCents: 0, classicIncludedMinutes: 30, classicPerMinuteCents: 41,
                                            ebikePerMinuteCents: 41, planPriceCents: 25_00, verified: true),
                reducedFare: reducedFare
            ),
            taxConfirmed: false
        ))
    }

    @Test func transitEqualsThe2026Literals() {
        let transit = document.transit
        // BRTransit/RaptorConfig.swift:50-77 (RaptorConfig.standard).
        #expect(transit.sameStopChangeSeconds == ConfigSystemValues(subway: 30, bus: 60, lirr: 180, ferry: 60, path: 30))
        #expect(transit.guaranteedTransferSeconds == 0 && transit.minimumPlatformChangeSeconds == 30)
        #expect(transit.accessSlack == ConfigAccessSlack(baseSeconds: 30, walkPercent: 5))
        #expect(transit.afterBikeChange == ConfigAfterBikeChange(minSeconds: 60, ridePercent: 10))
        #expect(transit.extraLeg == ConfigExtraLeg(pruneRound: 4, minSavingSeconds: 480))
        #expect(transit.maxJourneySeconds == 6 * 3600)
        #expect(transit.accessWalkLimitSeconds == 20 * 60 && transit.directWalkLimitSeconds == 60 * 60)
        // RaptorConfig.stationAccessSeconds (:61) and footpathWalkLimitSeconds (:72) are the links
        // values below.
        #expect(transit.links.stationAccessSeconds == ConfigSystemValues(subway: 120, bus: 30, lirr: 240, ferry: 120, path: 120))
        #expect(transit.links.maxFootpathWalkSeconds == 8 * 60)
        // BRTransit/TransitPlanner.swift:92 (snapMeters).
        #expect(transit.originSnapMeters == 250)
    }

    // The links parameters against the literals they replaced (bikeride-data `LinkNetwork.swift`
    // at the move) are checked where those literals now live: BRLinksTests `LinksConfigTests`.

    @Test func bikeShareAlertsCalendarAndAppEqualTheLiterals() {
        // BRBikeShare/StationFilter.swift:26-33 and BikeType.swift:17.
        #expect(document.bikeShare == ConfigBikeShare(
            regions: ConfigBikeShareRegions(nyc: ["158", "185", "71"], newJersey: ["311", "70"]),
            excludedRegions: ["189", "190"],
            vehicleTypes: ConfigVehicleTypes(classic: ["1"], ebike: ["2"]),
            maxStatusAgeSeconds: 10 * 60,
            valet: []
        ))
        // BRTransit/Alerts/ServiceAlert.swift:111-118 (pathKeywords), keywords sorted within a rule.
        #expect(document.alerts.pathKeywords == [
            ConfigPathKeywordRule(keywords: ["no service", "no trains", "not operating", "not running", "suspend"], severity: .suspended),
            ConfigPathKeywordRule(keywords: ["extensive delay", "major delay", "severe delay", "significant delay"], severity: .severeDelays),
            ConfigPathKeywordRule(keywords: ["delay"], severity: .delays),
            ConfigPathKeywordRule(keywords: ["detour", "reroute"], severity: .reroute),
            ConfigPathKeywordRule(keywords: ["bypass", "skip"], severity: .stopsSkipped),
            ConfigPathKeywordRule(keywords: ["less frequent", "reduced service"], severity: .reducedService),
        ])
        // Data/config/calendar/holidays.csv, as is; no LIRR off-peak holiday yet (the engine's
        // LIRRPeakRule.weekdayCommute has none).
        let holidays = document.calendar.holidays
        #expect(holidays.count == 25 && holidays.allSatisfy { !$0.lirrOffPeak })
        #expect(holidays.first == ConfigHoliday(date: ServiceDate(year: 2026, month: 1, day: 1), name: "New Year's Day",
                                                bikeShareDayType: .weekend, lirrOffPeak: false))
        #expect(holidays.filter { $0.bikeShareDayType == .weekday }.count == 10)
        #expect(document.minAppFormat == 1 && document.flags.isEmpty)
    }

    // MARK: - Determinism

    /// The same sources in another order (rows shuffled, JSON keys and set-like lists reordered,
    /// pairs and zone columns swapped) compile to the same bytes: nothing depends on input order.
    @Test func reorderedSourcesCompileToIdenticalBytes() throws {
        let scratch = try ScratchDirectory()
        let root = try RepositoryData.copy(into: scratch)
        var random = SplitMix64(seed: 20_260_927)
        func shuffleRows(_ file: String, swapColumns: (Int, Int)? = nil) throws {
            let url = root.appendingPathComponent(file)
            var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
            let header = lines.removeFirst()
            if let (a, b) = swapColumns {
                lines = lines.enumerated().map { index, line in
                    guard index % 2 == 0 else { return line }
                    var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    fields.swapAt(a, b)
                    return fields.joined(separator: ",")
                }
            }
            lines.shuffle(using: &random)
            try ([header] + lines).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        }
        try shuffleRows("config/calendar/holidays.csv")
        try shuffleRows("config/fixed-transfers.csv")
        try shuffleRows("fares/lirr/lirr-stations-2026.csv")
        try shuffleRows("fares/lirr/lirr-zone-fares-2026.csv", swapColumns: (0, 1))
        // path-keywords.csv rows are ordered (first match wins): reverse the keywords instead.
        let keywordsURL = root.appendingPathComponent("config/alerts/path-keywords.csv")
        let keywords = try String(contentsOf: keywordsURL, encoding: .utf8).split(separator: "\n").enumerated().map { index, line in
            guard index > 0 else { return String(line) }
            let parts = line.split(separator: ",", maxSplits: 1)
            return "\(parts[0]),\(parts[1].split(separator: "|").reversed().joined(separator: "|"))"
        }
        try (keywords.joined(separator: "\n") + "\n").write(to: keywordsURL, atomically: true, encoding: .utf8)
        // JSON: reverse every array of strings or pairs, re-serialize with unsorted keys.
        func reversed(_ value: Any) -> Any {
            if let object = value as? [String: Any] { return object.mapValues(reversed) }
            if let array = value as? [Any] {
                let items = array.map(reversed)
                return items.allSatisfy { $0 is String || $0 is [String: Any] } ? Array(items.reversed()) : items
            }
            return value
        }
        for file in ["fares/mta.json", "config/bikeshare/bikeshare.json", "fares/lirr/lirr.json"] {
            let url = root.appendingPathComponent(file)
            let tree = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            try JSONSerialization.data(withJSONObject: reversed(tree), options: [.prettyPrinted]).write(to: url)
        }
        #expect(try String(contentsOf: root.appendingPathComponent("fares/mta.json"), encoding: .utf8)
            != String(contentsOf: RepositoryData.root.appendingPathComponent("fares/mta.json"), encoding: .utf8))

        let reordered = try ConfigSources(root: root).load()
        #expect(reordered == document)
        #expect(try ConfigArtifactWriter.json(reordered) == ConfigArtifactWriter.json(document))
    }

    // MARK: - Strictness

    /// Copies `Data/`, applies `edit` to one file's text, and returns the load error.
    func loadError(_ file: String, _ edit: (String) -> String) throws -> ConfigSourceError? {
        let scratch = try ScratchDirectory()
        let root = try RepositoryData.copy(into: scratch)
        let url = root.appendingPathComponent(file)
        let text = try String(contentsOf: url, encoding: .utf8)
        let edited = edit(text)
        #expect(edited != text, "the edit changed nothing in \(file)")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        do {
            _ = try ConfigSources(root: root).load()
            return nil
        } catch let error as ConfigSourceError {
            return error
        }
    }

    @Test func aMisspelledOptionalKeyFailsTheBuild() throws {
        // planPriceCents is optional: a lenient decoder would drop the misspelling silently.
        let error = try loadError("fares/citibike.json") { $0.replacingOccurrences(of: #""planPriceCents": 23900"#, with: #""planPriceCent": 23900"#) }
        #expect(error == .unknownKey(file: "fares/citibike.json", path: "$.plans.member.planPriceCent"))
    }

    @Test func anExtraKeyFailsTheBuild() throws {
        let error = try loadError("config/transit.json") {
            $0.replacingOccurrences(of: #""maxJourneySeconds": 21600,"#, with: #""maxJourneySeconds": 21600, "maxJourneySecondz": 1,"#)
        }
        #expect(error == .unknownKey(file: "config/transit.json", path: "$.maxJourneySecondz"))
        let nested = try loadError("config/transit.json") {
            $0.replacingOccurrences(of: #""minTransferSeconds": 30,"#, with: #""minTransferSeconds": 30, "bikeHop": {"pickups": 2},"#)
        }
        #expect(nested == .unknownKey(file: "config/transit.json", path: "$.links.bikeHop"))
    }

    @Test func aMisspelledRequiredKeyFailsTheBuild() throws {
        let error = try loadError("fares/mta.json") { $0.replacingOccurrences(of: #""baseFareCents""#, with: #""baseFare""#) }
        guard case .undecodable(let file, let message)? = error else {
            Issue.record("expected undecodable, got \(String(describing: error))")
            return
        }
        #expect(file == "fares/mta.json" && message.contains("missing key 'baseFareCents'"))
    }

    @Test func wrongTypesAndUnknownEnumValuesFailTheBuild() throws {
        let decimal = try loadError("fares/path.json") { $0.replacingOccurrences(of: "325", with: "3.25") }
        guard case .undecodable? = decimal else { Issue.record("\(String(describing: decimal))"); return }
        let charge = try loadError("fares/mta.json") { $0.replacingOccurrences(of: #""expressBus": "stepUp""#, with: #""expressBus": "halfFare""#) }
        guard case .undecodable(_, let message)? = charge else { Issue.record("\(String(describing: charge))"); return }
        #expect(message.contains("halfFare"))
    }

    @Test func aDuplicateKeyFailsTheBuild() throws {
        // The reviewed-edit mistake: the new fare added, the old one not deleted. A JSON decoder
        // keeps one of the two silently.
        let top = try loadError("fares/mta.json") {
            $0.replacingOccurrences(of: #""baseFareCents": 300,"#, with: #""baseFareCents": 300, "baseFareCents": 325,"#)
        }
        #expect(top == .duplicateKey(file: "fares/mta.json", path: "$.baseFareCents", line: 2))
        #expect(top?.description == "fares/mta.json:2: key $.baseFareCents is written twice in one object")

        // Inside an array element, with equal values (still ambiguous: which one was meant?).
        let element = try loadError("fares/mta.json") {
            $0.replacingOccurrences(of: #"{ "stations": ["S:629", "S:B08"], "note""#,
                                    with: #"{ "stations": ["S:629", "S:B08"], "stations": ["S:629", "S:B08"], "note""#)
        }
        #expect(element == .duplicateKey(file: "fares/mta.json", path: "$.outOfSystemTransfers[0].stations", line: 12))

        // An optional key, on its own line.
        let optional = try loadError("fares/citibike.json") {
            $0.replacingOccurrences(of: #""planPriceCents": 23900,"#, with: "\"planPriceCents\": 23900,\n      \"planPriceCents\": 24900,")
        }
        #expect(optional == .duplicateKey(file: "fares/citibike.json", path: "$.plans.member.planPriceCents", line: 17))
    }

    @Test func anIntegerWrittenAsADecimalFailsTheBuild() throws {
        // JSONDecoder reads each of these into an Int as 325; the strict reader keeps the form.
        for written in ["325.0", "3.25e2", "3.25E+2", "32500e-2"] {
            let error = try loadError("fares/path.json") { $0.replacingOccurrences(of: "325", with: written) }
            #expect(error == .changedValue(file: "fares/path.json", path: "$.fareCents"), "\(written)")
        }
        let nested = try loadError("config/transit.json") {
            $0.replacingOccurrences(of: #""minTransferSeconds": 30,"#, with: #""minTransferSeconds": 30.0,"#)
        }
        #expect(nested == .changedValue(file: "config/transit.json", path: "$.links.minTransferSeconds"))
        // (A fraction that isn't an integer, 3.25, is a type error: wrongTypesAndUnknownEnumValuesFailTheBuild.)
    }

    @Test func nullReadsAsAbsent() throws {
        let error = try loadError("fares/citibike.json") {
            $0.replacingOccurrences(of: #""planPriceCents": 2500,"#, with: #""planPriceCents": null,"#)
        }
        #expect(error == nil)
    }

    @Test func csvHeadersMustBeExact() throws {
        let error = try loadError("config/fixed-transfers.csv") { $0.replacingOccurrences(of: "from,to,seconds,note", with: "from,to,secs,note") }
        #expect(error == .invalidCSV(file: "config/fixed-transfers.csv", message: "header is from,to,secs,note, expected from,to,seconds,note"))
        let fields = try loadError("config/fixed-transfers.csv") { $0 + "P:place_X,S:A,60\n" }
        #expect(fields == .invalidCSV(file: "config/fixed-transfers.csv", message: "record 8 has 3 fields, expected 4"))
        let number = try loadError("config/fixed-transfers.csv") { $0.replacingOccurrences(of: "S:138,240", with: "S:138,240s") }
        #expect(number == .invalidCSV(file: "config/fixed-transfers.csv", message: "record 2: seconds '240s' is not an integer"))
    }

    @Test func anLIRROffPeakDateMustBeAHoliday() throws {
        let error = try loadError("config/calendar/lirr-off-peak.csv") { $0 + "20261128,a Saturday\n" }
        #expect(error == .invalidCSV(file: "config/calendar/lirr-off-peak.csv", message: "record 2: 20261128 is not in config/calendar/holidays.csv"))
    }

    @Test func anLIRROffPeakDateSetsTheFlag() throws {
        let scratch = try ScratchDirectory()
        let root = try RepositoryData.copy(into: scratch)
        let url = root.appendingPathComponent("config/calendar/lirr-off-peak.csv")
        try "date,source_note\n20261126,test\n".write(to: url, atomically: true, encoding: .utf8)
        let holidays = try ConfigSources(root: root).load().calendar.holidays
        #expect(holidays.filter(\.lirrOffPeak).map(\.date) == [ServiceDate(year: 2026, month: 11, day: 26)])
    }

    @Test func canonicalRulesRunOnTheSources() throws {
        let error = try loadError("fares/lirr/lirr-stations-2026.csv") {
            $0.replacingOccurrences(of: "L:24,Belmont Park,4,none", with: "L:24,Belmont Park,4,cityTicket")
        }
        #expect(error == .invalidDocument(["fares.lirr.stations: L:24 is cityTicket in zone 4 (CityTicket covers zones 1 and 3)"]))
        let terminal = try loadError("fares/lirr/lirr.json") { $0.replacingOccurrences(of: #""L:118""#, with: #""L:1""#) }
        #expect(terminal == .invalidDocument(["fares.lirr.nycTerminals: L:1 is not a zone 1 station"]))
        let duplicate = try loadError("config/bikeshare/bikeshare.json") { $0.replacingOccurrences(of: #"["70", "311"]"#, with: #"["70", "311", "71"]"#) }
        #expect(duplicate == .invalidDocument(["bikeShare.regions: region 71 listed twice"]))
    }

    @Test func farRockawayExclusionsAreOptionalAndChecked() throws {
        let key = #""excludedDestinations""#
        func withExclusions(_ list: String?) -> (String) -> String {
            { text in
                let start = text.range(of: key)!.lowerBound
                let end = text.range(of: "]", range: start..<text.endIndex)!.upperBound
                guard let list else {
                    // Also drops the comma before the key.
                    let comma = text[..<start].lastIndex(of: ",")!
                    return String(text[..<comma]) + String(text[end...])
                }
                return text.replacingCharacters(in: start..<end, with: "\(key): \(list)")
            }
        }
        func load(_ list: String?) throws -> ConfigDocument {
            let scratch = try ScratchDirectory()
            let root = try RepositoryData.copy(into: scratch)
            let url = root.appendingPathComponent("fares/lirr/lirr.json")
            try withExclusions(list)(String(contentsOf: url, encoding: .utf8)).write(to: url, atomically: true, encoding: .utf8)
            return try ConfigSources(root: root).load()
        }
        // Absent or empty: none, and the document is otherwise the same, so it is written as
        // before the key existed.
        var none = document
        none.fares.lirr.farRockawayTicket.excludedDestinations = nil
        #expect(try load(nil) == none)
        #expect(try load("[]") == none)
        #expect(!String(decoding: try ConfigArtifactWriter.json(none), as: UTF8.self).contains("excludedDestinations"))
        // Written sorted, whatever the source order.
        let two = try load(#"[{ "stop": "L:237" }, { "stop": "L:199", "note": "x" }]"#)
        #expect(two.fares.lirr.farRockawayTicket.excludedDestinations == ["L:199", "L:237"])
        // Only stations in the destination zone (Jamaica is zone 3), each once.
        #expect(try loadError("fares/lirr/lirr.json", withExclusions(#"[{ "stop": "L:102" }]"#))
            == .invalidDocument(["fares.lirr.farRockawayTicket.excludedDestinations: L:102 is not a station in zone 1, the ticket's destination zone"]))
        let twice = try loadError("fares/lirr/lirr.json", withExclusions(#"[{ "stop": "L:199" }, { "stop": "L:199" }]"#))
        guard case .invalidDocument(let issues)? = twice else { Issue.record("\(String(describing: twice))"); return }
        #expect(issues.contains("fares.lirr.farRockawayTicket.excludedDestinations: stop L:199 listed twice"))
        // Strict like every source key.
        #expect(try loadError("fares/lirr/lirr.json") { $0.replacingOccurrences(of: key, with: #""excludedDestination""#) }
            == .unknownKey(file: "fares/lirr/lirr.json", path: "$.farRockawayTicket.excludedDestination"))
    }

    @Test func aMissingFileFailsTheBuild() throws {
        let scratch = try ScratchDirectory()
        let root = try RepositoryData.copy(into: scratch)
        try FileManager.default.removeItem(at: root.appendingPathComponent("config/bikeshare/valet.csv"))
        #expect(throws: ConfigSourceError.missingFile(root.appendingPathComponent("config/bikeshare/valet.csv").path)) {
            try ConfigSources(root: root).load()
        }
    }
}
