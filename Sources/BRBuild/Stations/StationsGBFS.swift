import Foundation

/// One `station_information` entry, as the stations compiler needs it.
public struct GBFSStation: Sendable, Equatable {
    public var stationID: String
    public var name: String
    public var shortName: String
    public var lat: Double
    public var lon: Double
    public var regionID: String?
    /// `nil` when the feed omits it; such stations are dropped like capacity 0.
    public var capacity: Int?
    public var isCharging: Bool

    public init(stationID: String, name: String, shortName: String = "", lat: Double, lon: Double,
                regionID: String? = nil, capacity: Int? = nil, isCharging: Bool = false) {
        self.stationID = stationID
        self.name = name
        self.shortName = shortName
        self.lat = lat
        self.lon = lon
        self.regionID = regionID
        self.capacity = capacity
        self.isCharging = isCharging
    }
}

/// Citi Bike's GBFS 2.3 feeds: discovery, then `station_information`. Decoding is tolerant in
/// the same ways as the app's `BRBikeShare`: ids may be strings or integers, flags booleans or
/// 0/1, and a malformed station is skipped and counted rather than failing the feed.
public enum GBFSStations {
    public static let discoveryURL = "https://gbfs.citibikenyc.com/gbfs/2.3/gbfs.json"

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case noFeed(name: String, language: String)
        case malformed(String)

        public var description: String {
            switch self {
            case .noFeed(let name, let language): "GBFS discovery lists no '\(name)' feed for language '\(language)'"
            case .malformed(let what): "malformed GBFS: \(what)"
            }
        }
    }

    /// The `station_information` URL from a `gbfs.json` discovery document.
    public static func stationInformationURL(discovery: Data, language: String = "en") throws -> String {
        struct Discovery: Decodable {
            struct Language: Decodable { let feeds: [Feed] }
            struct Feed: Decodable { let name: String; let url: String }
            let data: [String: Language]
        }
        let decoded: Discovery
        do {
            decoded = try JSONDecoder().decode(Discovery.self, from: discovery)
        } catch {
            throw ParseError.malformed("discovery: \(error)")
        }
        guard let url = decoded.data[language]?.feeds.first(where: { $0.name == "station_information" })?.url else {
            throw ParseError.noFeed(name: "station_information", language: language)
        }
        return url
    }

    public struct StationInformation: Sendable, Equatable {
        /// The feed's `last_updated` (POSIX seconds).
        public var lastUpdated: Int64?
        public var stations: [GBFSStation]
        /// Entries skipped because they failed to decode.
        public var dropped: Int
    }

    public static func parseStationInformation(_ json: Data) throws -> StationInformation {
        let feed: Feed
        do {
            feed = try JSONDecoder().decode(Feed.self, from: json)
        } catch {
            throw ParseError.malformed("station_information: \(error)")
        }
        return StationInformation(lastUpdated: feed.lastUpdated, stations: feed.data.stations.compactMap { $0.value?.value },
                                  dropped: feed.data.stations.filter { $0.value == nil }.count)
    }

    private struct Feed: Decodable {
        struct Payload: Decodable { let stations: [Lossy<Entry>] }
        let lastUpdated: Int64?
        let data: Payload

        enum CodingKeys: String, CodingKey { case lastUpdated = "last_updated", data }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let seconds = try? container.decodeIfPresent(Int64.self, forKey: .lastUpdated) {
                lastUpdated = seconds
            } else if let seconds = try? container.decodeIfPresent(Double.self, forKey: .lastUpdated) {
                lastUpdated = Int64(seconds)
            } else {
                lastUpdated = nil
            }
            data = try container.decode(Payload.self, forKey: .data)
        }
    }

    /// Decodes an element, or records `nil` if it fails, so one bad station never loses the feed.
    private struct Lossy<Wrapped: Decodable>: Decodable {
        let value: Wrapped?
        init(from decoder: any Decoder) throws { value = try? Wrapped(from: decoder) }
    }

    private struct Entry: Decodable {
        let value: GBFSStation

        enum CodingKeys: String, CodingKey {
            case stationID = "station_id", name, shortName = "short_name", lat, lon, regionID = "region_id", capacity
            case isCharging = "is_charging", isChargingStation = "is_charging_station"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func id(_ key: CodingKeys) throws -> String? {
                guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
                if let text = try? c.decode(String.self, forKey: key) { return text }
                return String(try c.decode(Int64.self, forKey: key))
            }
            func flag(_ key: CodingKeys) -> Bool? {
                if let value = try? c.decodeIfPresent(Bool.self, forKey: key) { return value }
                if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value != 0 }
                return nil
            }
            guard let stationID = try id(.stationID), !stationID.isEmpty else {
                throw ParseError.malformed("station without station_id")
            }
            let lat = try c.decode(Double.self, forKey: .lat), lon = try c.decode(Double.self, forKey: .lon)
            guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { throw ParseError.malformed("coordinates") }
            var capacity: Int?
            if let value = try? c.decodeIfPresent(Int.self, forKey: .capacity) {
                capacity = value
            } else if let value = try? c.decodeIfPresent(Double.self, forKey: .capacity) {
                capacity = Int(value)
            }
            value = GBFSStation(
                stationID: stationID,
                name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "",
                shortName: try id(.shortName) ?? "",
                lat: lat, lon: lon,
                regionID: try id(.regionID),
                capacity: capacity,
                isCharging: flag(.isChargingStation) ?? flag(.isCharging) ?? false
            )
        }
    }
}
