import BRConfig
import BRCore
import Foundation

/// A reviewed config source that fails to parse, or a document that breaks a canonical rule.
public enum ConfigSourceError: Error, Equatable, CustomStringConvertible {
    case missingFile(String)
    /// The file does not decode into its source shape (a missing key, a wrong type, an unknown
    /// enum value, not JSON).
    case undecodable(file: String, message: String)
    /// A key the source shape doesn't have: a typo, or a key that belongs elsewhere.
    case unknownKey(file: String, path: String)
    /// A key written twice in one object (a JSON decoder would keep one of the values without
    /// a word). `line` is where the second one starts.
    case duplicateKey(file: String, path: String, line: Int)
    /// A value that changes when decoded and re-encoded: an integer written as a decimal or with
    /// an exponent (`325.0`, `3.25e2`), which the decoder reads as the integer.
    case changedValue(file: String, path: String)
    case invalidCSV(file: String, message: String)
    /// Values that parse but are wrong for their file (e.g. a date not in holidays.csv).
    case invalidValue(file: String, message: String)
    /// The assembled document breaks ``ConfigValidation/canonicalIssues(_:)``.
    case invalidDocument([String])

    public var description: String {
        switch self {
        case .missingFile(let path): "\(path) is missing"
        case .undecodable(let file, let message): "\(file): \(message)"
        case .unknownKey(let file, let path): "\(file): unknown key \(path)"
        case .duplicateKey(let file, let path, let line): "\(file):\(line): key \(path) is written twice in one object"
        case .changedValue(let file, let path): "\(file): \(path) is not in its canonical form (an integer written as a decimal or with an exponent?)"
        case .invalidCSV(let file, let message): "\(file): \(message)"
        case .invalidValue(let file, let message): "\(file): \(message)"
        case .invalidDocument(let issues): "config document is invalid:\n  " + issues.joined(separator: "\n  ")
        }
    }
}

/// The reviewed config sources under a `Data/` directory, read strictly, assembled into a
/// canonical ``ConfigDocument``. Layout and provenance: `Data/config/SOURCES.md`,
/// `Data/fares/SOURCES.md`.
///
/// JSON files are read by ``StrictJSON`` (RFC 8259, no key twice in one object), decoded into
/// their source shape, re-encoded and compared with what was read, so an unknown or misspelled
/// key fails (the app's reader, by contrast, ignores unknown keys), and so does an integer
/// written as `325.0` or `3.25e2`. `null` counts as absent. CSV files need exactly the documented
/// header. Set-like lists may be in any order in the sources: the document sorts them.
public struct ConfigSources: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The files read, relative to ``root`` (the LIRR CSVs are named in `lirr.json`).
    public static let fixedFiles = [
        "config/app.json",
        "config/calendar/holidays.csv",
        "config/calendar/lirr-off-peak.csv",
        "config/transit.json",
        "config/fixed-transfers.csv",
        "config/bikeshare/bikeshare.json",
        "config/bikeshare/valet.csv",
        "config/alerts/path-keywords.csv",
        "fares/mta.json",
        "fares/path.json",
        "fares/lirr/lirr.json",
        "fares/citibike.json",
    ]

    /// Every file ``load()`` reads, relative to ``root``, sorted.
    public func files() throws -> [String] {
        let lirr = try decodeJSON(LIRRSource.self, "fares/lirr/lirr.json")
        return (Self.fixedFiles + ["fares/lirr/\(lirr.stationsFile)", "fares/lirr/\(lirr.zoneFaresFile)"]).sorted()
    }

    public func load() throws -> ConfigDocument {
        let app = try decodeJSON(AppSource.self, "config/app.json")
        let document = ConfigDocument(
            minAppFormat: app.minAppFormat,
            flags: app.flags,
            calendar: ConfigCalendar(holidays: try holidays()),
            fares: ConfigFares(mta: try mta(), path: try decodeJSON(ConfigPATHFares.self, "fares/path.json"), lirr: try lirr(),
                               citiBike: try decodeJSON(ConfigCitiBikeFares.self, "fares/citibike.json")),
            transit: try transit(),
            bikeShare: try bikeShare(),
            alerts: ConfigAlerts(pathKeywords: try pathKeywords())
        )
        let issues = ConfigValidation.canonicalIssues(document)
        guard issues.isEmpty else { throw ConfigSourceError.invalidDocument(issues) }
        return document
    }

    // MARK: - Sections

    private func holidays() throws -> [ConfigHoliday] {
        let file = "config/calendar/holidays.csv"
        var holidays: [ConfigHoliday] = []
        for row in try readCSV(file, header: ["date", "name", "profile"]) {
            let date = try row.date("date")
            guard let dayType = ConfigDayType(rawValue: row["profile"]) else {
                throw row.error("profile '\(row["profile"])' is not weekday or weekend")
            }
            holidays.append(ConfigHoliday(date: date, name: row["name"], bikeShareDayType: dayType, lirrOffPeak: false))
        }
        let offPeakFile = "config/calendar/lirr-off-peak.csv"
        var offPeak = Set<ServiceDate>()
        for row in try readCSV(offPeakFile, header: ["date", "source_note"]) {
            let date = try row.date("date")
            guard offPeak.insert(date).inserted else { throw row.error("\(date.yyyymmdd) listed twice") }
            guard let index = holidays.firstIndex(where: { $0.date == date }) else {
                throw row.error("\(date.yyyymmdd) is not in config/calendar/holidays.csv")
            }
            holidays[index].lirrOffPeak = true
        }
        return holidays.sorted { $0.date < $1.date }
    }

    private func mta() throws -> ConfigMTAFares {
        let file = "fares/mta.json"
        let source = try decodeJSON(MTASource.self, file)
        func pairs(_ list: [PairSource], _ key: String) throws -> [ConfigStationPair] {
            try list.map { pair in
                guard pair.stations.count == 2 else {
                    throw ConfigSourceError.invalidValue(file: file, message: "\(key): \(pair.stations) is not two stations")
                }
                return ConfigStationPair(pair.stations[0], pair.stations[1])
            }.sorted { Self.precedes([$0.first.rawValue, $0.second.rawValue], [$1.first.rawValue, $1.second.rawValue]) }
        }
        return ConfigMTAFares(
            baseFareCents: source.baseFareCents, expressBusFareCents: source.expressBusFareCents,
            expressBusStepUpCents: source.expressBusStepUpCents, transferWindowSeconds: source.transferWindowSeconds,
            transferTable: source.transferTable,
            outOfSystemTransfers: try pairs(source.outOfSystemTransfers, "outOfSystemTransfers"),
            inSystemTransfers: try pairs(source.inSystemTransfers, "inSystemTransfers"),
            statenIslandRailway: ConfigStatenIslandRailway(
                routes: source.statenIslandRailway.routes.sorted(by: Self.bytes(\.rawValue)),
                fareStations: source.statenIslandRailway.fareStations.map(\.stop).sorted(by: Self.bytes(\.rawValue))
            )
        )
    }

    private func lirr() throws -> ConfigLIRRFares {
        let source = try decodeJSON(LIRRSource.self, "fares/lirr/lirr.json")
        for name in [source.stationsFile, source.zoneFaresFile] where name.isEmpty || name.contains("/") || name.hasPrefix(".") {
            throw ConfigSourceError.invalidValue(file: "fares/lirr/lirr.json", message: "'\(name)' must be a file name in fares/lirr")
        }
        var stations: [ConfigLIRRStation] = []
        for row in try readCSV("fares/lirr/\(source.stationsFile)", header: ["stop_id", "gtfs_name", "zone", "city_fare", "source_note"]) {
            guard let cityFare = ConfigLIRRCityFare(rawValue: row["city_fare"]) else {
                throw row.error("city_fare '\(row["city_fare"])' is not none, cityTicket or farRockaway")
            }
            stations.append(ConfigLIRRStation(stop: StopID(try row.identifier("stop_id")), zone: try row.int("zone"), cityFare: cityFare))
        }
        var zoneFares: [ConfigLIRRZoneFare] = []
        for row in try readCSV("fares/lirr/\(source.zoneFaresFile)", header: ["from_zone", "to_zone", "peak_cents", "offpeak_cents"]) {
            let a = try row.int("from_zone"), b = try row.int("to_zone")
            zoneFares.append(ConfigLIRRZoneFare(fromZone: min(a, b), toZone: max(a, b), peakCents: try row.int("peak_cents"),
                                                offPeakCents: try row.int("offpeak_cents")))
        }
        return ConfigLIRRFares(
            stations: stations.sorted(by: Self.bytes(\.stop.rawValue)),
            zoneFares: zoneFares.sorted { ($0.fromZone, $0.toZone) < ($1.fromZone, $1.toZone) },
            cityTicket: source.cityTicket,
            farRockawayTicket: source.farRockawayTicket,
            peakRule: source.peakRule,
            nycTerminals: source.nycTerminals.map(\.stop).sorted(by: Self.bytes(\.rawValue))
        )
    }

    private func transit() throws -> ConfigTransit {
        let source = try decodeJSON(TransitSource.self, "config/transit.json")
        var fixed: [ConfigFixedTransfer] = []
        for row in try readCSV("config/fixed-transfers.csv", header: ["from", "to", "seconds", "note"]) {
            fixed.append(ConfigFixedTransfer(from: StopID(try row.identifier("from")), to: StopID(try row.identifier("to")),
                                             seconds: try row.int("seconds")))
        }
        let links = source.links
        return ConfigTransit(
            sameStopChangeSeconds: source.sameStopChangeSeconds,
            guaranteedTransferSeconds: source.guaranteedTransferSeconds,
            minimumPlatformChangeSeconds: source.minimumPlatformChangeSeconds,
            accessSlack: source.accessSlack,
            afterBikeChange: source.afterBikeChange,
            extraLeg: source.extraLeg,
            maxJourneySeconds: source.maxJourneySeconds,
            accessWalkLimitSeconds: source.accessWalkLimitSeconds,
            directWalkLimitSeconds: source.directWalkLimitSeconds,
            originSnapMeters: source.originSnapMeters,
            links: ConfigLinks(
                stationAccessSeconds: links.stationAccessSeconds, maxSnapMeters: links.maxSnapMeters,
                maxFootpathWalkSeconds: links.maxFootpathWalkSeconds, minTransferSeconds: links.minTransferSeconds,
                stationLinkMaxWalkMeters: links.stationLinkMaxWalkMeters, walkSpeedHundredthsMph: links.walkSpeedHundredthsMph,
                streetAccessOnlyInsideServiceArea: links.streetAccessOnlyInsideServiceArea.sorted(by: Self.bytes(\.rawValue)),
                fixedTransfers: fixed.sorted { Self.precedes([$0.from.rawValue, $0.to.rawValue], [$1.from.rawValue, $1.to.rawValue]) }
            )
        )
    }

    private func bikeShare() throws -> ConfigBikeShare {
        let source = try decodeJSON(BikeShareSource.self, "config/bikeshare/bikeshare.json")
        var valet: [ConfigValetStation] = []
        for row in try readCSV("config/bikeshare/valet.csv", header: ["station_id", "lat_e6", "lon_e6", "name", "source_note"]) {
            valet.append(ConfigValetStation(stationID: try row.identifier("station_id"), latE6: try row.int("lat_e6"),
                                            lonE6: try row.int("lon_e6")))
        }
        let sorted: ([String]) -> [String] = { $0.sorted(by: Self.bytes(\.self)) }
        return ConfigBikeShare(
            regions: ConfigBikeShareRegions(nyc: sorted(source.regions.nyc), newJersey: sorted(source.regions.newJersey)),
            excludedRegions: sorted(source.excludedRegions),
            vehicleTypes: ConfigVehicleTypes(classic: sorted(source.vehicleTypes.classic), ebike: sorted(source.vehicleTypes.ebike)),
            maxStatusAgeSeconds: source.maxStatusAgeSeconds,
            valet: valet.sorted(by: Self.bytes(\.stationID))
        )
    }

    private func pathKeywords() throws -> [ConfigPathKeywordRule] {
        try readCSV("config/alerts/path-keywords.csv", header: ["severity", "keywords"]).map { row in
            guard let severity = ConfigAlertSeverity(rawValue: row["severity"]) else {
                throw row.error("severity '\(row["severity"])' is not an alert severity")
            }
            let keywords = row["keywords"].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return ConfigPathKeywordRule(keywords: keywords.sorted(by: Self.bytes(\.self)), severity: severity)
        }
    }

    // MARK: - Strict JSON

    func decodeJSON<T: Codable>(_ type: T.Type, _ file: String) throws -> T {
        try Self.strictDecode(type, from: read(file), file: file)
    }

    /// Reads `data` strictly (``StrictJSON``: a repeated key is an error), decodes it as `T`,
    /// then requires that re-encoding the value gives back what was read (`null` counting as
    /// absent), so an unknown or misspelled key, or an integer written as a decimal, is an error
    /// naming its path. Both sides of the comparison are read by ``StrictJSON``, which keeps
    /// number forms apart.
    public static func strictDecode<T: Codable>(_ type: T.Type, from data: Data, file: String) throws -> T {
        let source: JSONValue
        do {
            source = try StrictJSON.parse(data)
        } catch let failure as StrictJSON.Failure {
            switch failure {
            case .duplicateKey(let path, let line): throw ConfigSourceError.duplicateKey(file: file, path: path, line: line)
            case .syntax(let line, let column, let message):
                throw ConfigSourceError.undecodable(file: file, message: "not valid JSON at line \(line), column \(column): \(message)")
            }
        }
        let value: T
        do {
            value = try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw ConfigSourceError.undecodable(file: file, message: MappedConfig.describe(error))
        }
        let reencoded = try StrictJSON.parse(JSONEncoder().encode(value))
        if let difference = source.firstDifference(from: reencoded, path: "$") {
            switch difference {
            case .unknownKey(let path): throw ConfigSourceError.unknownKey(file: file, path: path)
            case .changed(let path): throw ConfigSourceError.changedValue(file: file, path: path)
            }
        }
        return value
    }

    // MARK: - CSV

    struct Row {
        let file: String
        let line: Int
        let fields: [String: String]

        subscript(column: String) -> String { fields[column] ?? "" }

        func error(_ message: String) -> ConfigSourceError {
            .invalidCSV(file: file, message: "record \(line): \(message)")
        }

        func int(_ column: String) throws -> Int {
            guard let value = Int(self[column]), String(value) == self[column] else { throw error("\(column) '\(self[column])' is not an integer") }
            return value
        }

        func date(_ column: String) throws -> ServiceDate {
            guard let date = ServiceDate(yyyymmdd: self[column]) else { throw error("\(column) '\(self[column])' is not YYYYMMDD") }
            return date
        }

        /// A non-empty id without surrounding or inner whitespace.
        func identifier(_ column: String) throws -> String {
            let value = self[column]
            guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { throw error("\(column) '\(value)' is not an id") }
            return value
        }
    }

    /// Records of a CSV whose header must be exactly `header`; every record has exactly that
    /// many fields, in UTF-8.
    func readCSV(_ file: String, header expected: [String]) throws -> [Row] {
        var reader = CSVReader(bytes: try read(file))
        do {
            guard let first = try reader.next() else { throw ConfigSourceError.invalidCSV(file: file, message: "empty (needs the header)") }
            let header = first.fields.map(\.string)
            guard header == expected else {
                throw ConfigSourceError.invalidCSV(file: file, message: "header is \(header.joined(separator: ",")), expected \(expected.joined(separator: ","))")
            }
            var rows: [Row] = []
            while let record = try reader.next() {
                guard record.count == expected.count else {
                    throw ConfigSourceError.invalidCSV(file: file, message: "record \(reader.recordCount) has \(record.count) fields, expected \(expected.count)")
                }
                var fields: [String: String] = [:]
                for (index, name) in expected.enumerated() {
                    guard let text = String(bytes: record[index].bytes, encoding: .utf8) else {
                        throw ConfigSourceError.invalidCSV(file: file, message: "record \(reader.recordCount): \(name) is not UTF-8")
                    }
                    fields[name] = text
                }
                rows.append(Row(file: file, line: reader.recordCount, fields: fields))
            }
            return rows
        } catch let error as CSVError {
            throw ConfigSourceError.invalidCSV(file: file, message: "\(error)")
        }
    }

    private func read(_ file: String) throws -> Data {
        let url = root.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConfigSourceError.missingFile(url.path) }
        return try Data(contentsOf: url)
    }

    // MARK: - Ordering

    /// Orders by the UTF-8 bytes of `key`.
    static func bytes<T>(_ key: KeyPath<T, String>) -> (T, T) -> Bool {
        { $0[keyPath: key].utf8.lexicographicallyPrecedes($1[keyPath: key].utf8) }
    }

    /// Orders key tuples field by field, each by UTF-8 bytes.
    static func precedes(_ a: [String], _ b: [String]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x.utf8.lexicographicallyPrecedes(y.utf8) }
        return a.count < b.count
    }
}

// MARK: - Source shapes

/// `config/app.json`.
struct AppSource: Codable {
    var minAppFormat: Int
    var flags: [String: Bool]
}

/// `fares/mta.json`: the wire section, with notes on the station lists.
struct MTASource: Codable {
    var baseFareCents: Int
    var expressBusFareCents: Int
    var expressBusStepUpCents: Int
    var transferWindowSeconds: Int
    var transferTable: ConfigTransferTable
    var outOfSystemTransfers: [PairSource]
    var inSystemTransfers: [PairSource]
    var statenIslandRailway: SIRSource
}

struct PairSource: Codable {
    var stations: [StopID]
    var note: String?
}

struct NotedStop: Codable {
    var stop: StopID
    var note: String?
}

struct SIRSource: Codable {
    var routes: [RouteID]
    var fareStations: [NotedStop]
}

/// `fares/lirr/lirr.json`: the LIRR section apart from the two CSV tables it names.
struct LIRRSource: Codable {
    var stationsFile: String
    var zoneFaresFile: String
    var cityTicket: ConfigPeakFare
    var farRockawayTicket: ConfigFarRockawayTicket
    var peakRule: ConfigLIRRPeakRule
    var nycTerminals: [NotedStop]
}

/// `config/transit.json`: the transit section without `links.fixedTransfers` (a CSV).
struct TransitSource: Codable {
    var sameStopChangeSeconds: ConfigSystemValues
    var guaranteedTransferSeconds: Int
    var minimumPlatformChangeSeconds: Int
    var accessSlack: ConfigAccessSlack
    var afterBikeChange: ConfigAfterBikeChange
    var extraLeg: ConfigExtraLeg
    var maxJourneySeconds: Int
    var accessWalkLimitSeconds: Int
    var directWalkLimitSeconds: Int
    var originSnapMeters: Int
    var links: LinksSource

    struct LinksSource: Codable {
        var stationAccessSeconds: ConfigSystemValues
        var maxSnapMeters: ConfigSystemValues
        var maxFootpathWalkSeconds: Int
        var minTransferSeconds: Int
        var stationLinkMaxWalkMeters: Int
        var walkSpeedHundredthsMph: Int
        var streetAccessOnlyInsideServiceArea: [ConfigTransitSystem]
    }
}

/// `config/bikeshare/bikeshare.json`: the bike-share section without `valet` (a CSV).
struct BikeShareSource: Codable {
    var regions: ConfigBikeShareRegions
    var excludedRegions: [String]
    var vehicleTypes: ConfigVehicleTypes
    var maxStatusAgeSeconds: Int
}
