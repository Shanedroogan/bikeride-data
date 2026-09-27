import BRConfig
import BRCore
import BRData
import Foundation
import Testing

/// The `config` envelope and JSON reader (docs/formats.md, "config").
@Suite struct ConfigFormatTests {
    /// SHA-256 of the writer's payload for ``HandBuiltConfig`` (the header is left out: it embeds
    /// builderSwiftVersion). Every test run is a fresh process with a fresh `Hasher` seed, so this
    /// golden passing run after run, on macOS and Linux, is the cross-process determinism check.
    /// While the format is the draft 0 a deliberate layout or schema change re-pins it; from
    /// format 1 on a change that moves it needs a new formatVersion.
    static let payloadGolden = "4bd407281fa1e40f6c091141f400a2b1ddddeb381989b48aa7f7a61a924b864f"

    @Test func payloadMatchesTheGolden() throws {
        let payload = try ConfigArtifactWriter.payload(HandBuiltConfig.document)
        let digest = try sha256Hex(payload)
        print("CONFIG hand-built payload \(payload.count) bytes, sha256 \(digest)")
        #expect(digest == Self.payloadGolden)
        let file = try HandBuiltConfig.artifact()
        #expect(Data(try ArtifactHeader.decode(from: file).payload) == payload)
        // The header's dataVersion does not reach the payload.
        #expect(try sha256Hex(Data(ArtifactHeader.decode(from: HandBuiltConfig.artifact(dataVersion: "other")).payload)) == digest)
    }

    @Test func theJSONIsCanonical() throws {
        let json = try ConfigArtifactWriter.json(HandBuiltConfig.document)
        let text = try #require(String(data: json, encoding: .utf8))
        // Sorted keys, no whitespace, slashes unescaped, integers only.
        #expect(text.hasPrefix(#"{"alerts":{"pathKeywords":[{"keywords":["no service","suspend"],"severity":"suspended"}"#))
        #expect(text.contains(#""flags":{"alpha":true,"zeta":false}"#))
        #expect(text.contains(#""outOfSystemTransfers":[["S:A1","S:B1"]]"#))
        #expect(!text.contains("\n") && !text.contains(": ") && !text.contains("\\/") && !text.contains("."))
        // Encoding again, from a copy built another way, gives the same bytes.
        var copy = HandBuiltConfig.document
        copy.flags = Dictionary(uniqueKeysWithValues: copy.flags.sorted { $0.key > $1.key })
        #expect(try ConfigArtifactWriter.json(copy) == json)
    }

    @Test func roundTripsThroughTheReader() throws {
        let config = try MappedConfig(fileBytes: HandBuiltConfig.artifact())
        #expect(config.document == HandBuiltConfig.document)
        #expect(config.header.kind == .config && config.header.formatVersion == 0 && config.header.builtAgainst.isEmpty)
        #expect(config.extensions == .empty)
        #expect(config.json == (try ConfigArtifactWriter.json(HandBuiltConfig.document)))
        #expect(ConfigValidation.canonicalIssues(HandBuiltConfig.document).isEmpty)
    }

    @Test func opensAMappedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try HandBuiltConfig.artifact().write(to: url)
        #expect(try MappedConfig(contentsOf: url).document == HandBuiltConfig.document)
    }

    @Test func ignoresUnknownKeysAtAnyDepth() throws {
        var tree = try HandBuiltConfig.tree()
        tree["futureSection"] = ["anything": [1, 2, 3]]
        tree.set("fares.mta.futureKey", "x")
        tree.set("transit.links.bikeHop", ["pickups": 2])
        tree.set("fares.citiBike.plans.member.futurePerk", true)
        var alerts = tree["alerts"] as! [String: Any]
        var rules = alerts["pathKeywords"] as! [[String: Any]]
        rules[0]["futureWeight"] = 7
        alerts["pathKeywords"] = rules
        tree["alerts"] = alerts
        var lirr = (tree["fares"] as! [String: Any])["lirr"] as! [String: Any]
        var stations = lirr["stations"] as! [[String: Any]]
        stations[1]["name"] = "Somewhere"
        lirr["stations"] = stations
        tree.set("fares.lirr", lirr)
        let config = try MappedConfig(fileBytes: HandBuiltConfig.file(json: HandBuiltConfig.json(tree)))
        #expect(config.document == HandBuiltConfig.document)
    }

    @Test func readsNullAsAbsent() throws {
        var tree = try HandBuiltConfig.tree()
        tree.set("fares.citiBike.plans.member.ebikeManhattanCap", NSNull())
        tree.set("fares.citiBike.plans.member.planPriceCents", NSNull())
        let config = try MappedConfig(fileBytes: HandBuiltConfig.file(json: HandBuiltConfig.json(tree)))
        #expect(config.document.fares.citiBike.plans.member.ebikeManhattanCap == nil)
        #expect(config.document.fares.citiBike.plans.member.planPriceCents == nil)
        // The writer omits a nil optional rather than writing null.
        let json = try ConfigArtifactWriter.json(config.document)
        #expect(!(String(data: json, encoding: .utf8) ?? "").contains("null"))
    }

    /// Each value is JSON text.
    @Test(arguments: [
        ("fares.mta.transferTable.subway.expressBus", #""halfFare""#),
        ("bikeShare.valet", #""not-an-array""#),
        ("transit.links.streetAccessOnlyInsideServiceArea", #"["P"]"#),
        ("fares.lirr.stations", #"[{"stop":"L:1","zone":1,"cityFare":"zoneOnly"}]"#),
        ("calendar.holidays", #"[{"date":"20261126","name":"x","bikeShareDayType":"holiday","lirrOffPeak":true}]"#),
        ("calendar.holidays", #"[{"date":"2026-11-26","name":"x","bikeShareDayType":"weekend","lirrOffPeak":true}]"#),
        ("alerts.pathKeywords", #"[{"keywords":["x"],"severity":"catastrophic"}]"#),
        ("fares.path.fareCents", "3.25"),
        ("fares.mta.outOfSystemTransfers", #"[["S:A1","S:B1","S:C1"]]"#),
    ])
    func rejectsUnknownEnumValuesAndWrongTypes(path: String, value: String) throws {
        var tree = try HandBuiltConfig.tree()
        tree.set(path, try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed))
        let file = HandBuiltConfig.file(json: try HandBuiltConfig.json(tree))
        #expect(throws: ConfigFormatError.self) { try MappedConfig(fileBytes: file) }
        do {
            _ = try MappedConfig(fileBytes: file)
        } catch let error as ConfigFormatError {
            guard case .undecodableDocument(let message) = error else {
                Issue.record("expected undecodableDocument, got \(error)")
                return
            }
            print("CONFIG rejects \(path) = \(value): \(message)")
        }
    }

    @Test(arguments: ["fares", "minAppFormat", "fares.lirr.nycTerminals", "transit.links.fixedTransfers",
                      "fares.citiBike.plans.reducedFare", "bikeShare.valet", "fares.mta.transferTable.localBus.subway"])
    func rejectsAMissingRequiredKey(path: String) throws {
        var tree = try HandBuiltConfig.tree()
        tree.set(path, nil)
        let file = HandBuiltConfig.file(json: try HandBuiltConfig.json(tree))
        #expect {
            try MappedConfig(fileBytes: file)
        } throws: { error in
            guard case .undecodableDocument(let message)? = error as? ConfigFormatError else { return false }
            return message.contains("missing key")
        }
    }

    @Test func rejectsBadEnvelopes() throws {
        let file = try HandBuiltConfig.artifact()
        let (header, payload) = try ArtifactHeader.decode(from: file)
        let payloadBytes = Data(payload)

        var magic = payloadBytes
        magic[0] = UInt8(ascii: "X")
        #expect(throws: ConfigFormatError.badPayloadMagic) { try MappedConfig(fileBytes: header.assemble(payload: magic)) }

        for revision: UInt32 in [0, 2] {
            var bytes = payloadBytes
            withUnsafeBytes(of: revision) { bytes.replaceSubrange(4..<8, with: $0) }
            #expect(throws: ConfigFormatError.unsupportedPayloadRevision(revision)) {
                try MappedConfig(fileBytes: header.assemble(payload: bytes))
            }
        }

        // The draft reader accepts only format 0.
        for version: UInt16 in [1, 2] {
            var other = header
            other.formatVersion = version
            #expect(throws: ConfigFormatError.unsupportedFormatVersion(version)) {
                try MappedConfig(fileBytes: other.assemble(payload: payloadBytes))
            }
        }

        // Anything after the extension tail.
        #expect(throws: DataFormatError.trailingBytes(1)) {
            try MappedConfig(fileBytes: header.assemble(payload: payloadBytes + [0]))
        }

        // Another kind's header.
        var stations = header
        stations.kind = .stations
        #expect(throws: DataFormatError.kindMismatch(expected: .config, found: .stations)) {
            try MappedConfig(fileBytes: stations.assemble(payload: payloadBytes))
        }

        // Not JSON.
        let garbage = ArtifactHeader(kind: .config, formatVersion: 0, dataVersion: "x", builderSwiftVersion: "6.4")
            .assemble(payload: ConfigArtifactWriter.payload(json: Data("{not json".utf8)))
        #expect(throws: ConfigFormatError.self) { try MappedConfig(fileBytes: garbage) }
    }

    @Test func skipsUnknownExtensionIDs() throws {
        let json = try ConfigArtifactWriter.json(HandBuiltConfig.document)
        var writer = BinaryWriter()
        writer.append(bytes: ConfigFormat.payloadMagic)
        writer.append(ConfigFormat.payloadRevision)
        writer.append(array: [UInt8](json))
        writer.appendExtensions([(id: 7, bytes: [1, 2, 3])])
        let header = ArtifactHeader(kind: .config, formatVersion: 0, dataVersion: "x", builderSwiftVersion: "6.4")
        let config = try MappedConfig(fileBytes: header.assemble(payload: writer.data))
        #expect(config.document == HandBuiltConfig.document)
        #expect(config.extensions.ids == [7] && config.extensions[7] == Data([1, 2, 3]))
    }

    @Test func rejectsStructuralIssues() throws {
        func issues(_ change: (inout ConfigDocument) -> Void) -> [String] {
            var document = HandBuiltConfig.document
            change(&document)
            let file = try! HandBuiltConfig.artifact(document)
            do {
                _ = try MappedConfig(fileBytes: file)
                return []
            } catch ConfigFormatError.invalidDocument(let issues) {
                return issues
            } catch {
                return ["unexpected \(error)"]
            }
        }
        #expect(issues { $0.fares.lirr.zoneFares.removeLast() } == ["fares.lirr.zoneFares: no fare for zones 4–4"])
        #expect(issues { $0.fares.lirr.zoneFares.append($0.fares.lirr.zoneFares[0]) } == ["fares.lirr.zoneFares: zones 1–1 listed twice"])
        #expect(issues { $0.fares.lirr.peakRule.terminalArrivals.endMinute = 360 }
            == ["fares.lirr.peakRule.terminalArrivals: needs 0 ≤ startMinute < endMinute ≤ 1440"])
        #expect(issues { $0.transit.links.maxFootpathWalkSeconds = 3601 } == ["transit.links.maxFootpathWalkSeconds: must be 1…3600"])
        #expect(issues { $0.fares.mta.inSystemTransfers = $0.fares.mta.outOfSystemTransfers }
            == ["fares.mta: S:A1–S:B1 is both an in-system and an out-of-system transfer"])
        #expect(issues { $0.bikeShare.vehicleTypes.ebike = ["1"] } == ["bikeShare.vehicleTypes: vehicle type 1 listed twice"])
        #expect(issues { $0.fares.citiBike.plans.dayPass.classicPerMinuteCents = -1 }
            == ["fares.citiBike.plans.dayPass.classicPerMinuteCents: must not be negative"])
        #expect(issues {
            $0.transit.links.fixedTransfers.append(ConfigFixedTransfer(from: "S:A1", to: "P:place_A", seconds: 60))
        } == ["transit.links.fixedTransfers: P:place_A–S:A1 listed twice (each applies both ways)"])
        // Writer conventions are not the reader's business: an unsorted list still opens.
        #expect(issues { $0.fares.lirr.stations.reverse() }.isEmpty)
        #expect(issues { $0.calendar.holidays[0].date = ServiceDate(year: 2026, month: 11, day: 28) }.isEmpty) // a Saturday
    }

    @Test func canonicalRulesCatchWriterMistakes() throws {
        func issues(_ change: (inout ConfigDocument) -> Void) -> [String] {
            var document = HandBuiltConfig.document
            change(&document)
            return ConfigValidation.canonicalIssues(document)
        }
        #expect(issues { $0.fares.lirr.stations.reverse() }.count == 1)
        #expect(issues { $0.calendar.holidays[0].date = ServiceDate(year: 2026, month: 11, day: 25) }.isEmpty)
        #expect(issues { $0.calendar.holidays[1].date = ServiceDate(year: 2026, month: 11, day: 28) }
            == ["calendar.holidays: 20261128 is not a Monday–Friday (list the observed day)"])
        #expect(issues { $0.fares.lirr.stations[2].cityFare = .cityTicket }
            .contains("fares.lirr.stations: L:3 is cityTicket in zone 4 (CityTicket covers zones 1 and 3)"))
        #expect(issues { $0.fares.lirr.nycTerminals = ["L:2"] } == ["fares.lirr.nycTerminals: L:2 is not a zone 1 station"])
        #expect(issues { $0.alerts.pathKeywords[1].keywords = ["Delay"] } == ["alerts.pathKeywords: 'Delay' must be lowercase"])
        #expect(issues { $0.alerts.pathKeywords[1].keywords = ["suspend"] } == ["alerts.pathKeywords: 'suspend' is in two rules"])
        #expect(issues { $0.bikeShare.excludedRegions = ["71"] } == ["bikeShare.excludedRegions: 71 is also a service-area region"])
        #expect(issues { $0.fares.mta.outOfSystemTransfers = [ConfigStationPair("S:A1", "L:1")] }
            == ["fares.mta.outOfSystemTransfers: L:1 is not a S:… id"])
        #expect(issues { $0.transit.links.streetAccessOnlyInsideServiceArea = [.path, .bus] }.count == 1)
    }

    @Test func stationPairsOrderTheirIDs() throws {
        let pair = ConfigStationPair("S:B08", "S:629")
        #expect(pair.first == "S:629" && pair.second == "S:B08")
        let decoded = try JSONDecoder().decode(ConfigStationPair.self, from: Data(#"["S:R11","S:B08"]"#.utf8))
        #expect(decoded == ConfigStationPair("S:B08", "S:R11"))
    }
}
