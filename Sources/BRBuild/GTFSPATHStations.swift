import BRGeo
import Foundation

/// How the PATH feed's missing station structure is synthesized (see
/// ``GTFSFeed/synthesizePATHStations(_:)``).
public struct PATHStationOptions: Sendable, Equatable {
    /// Rows whose `stop_id` starts with this are the feed's station-level places
    /// (`place_JSQ`, …); the rest of the id is the station code.
    public var placePrefix = "place_"
    /// A boarding stop joins a place with the same name within this distance, or else the
    /// nearest place within it.
    public var maxParentDistanceMeters = 150.0
    /// Platform-to-platform change inside one station (cross-platform or across the tracks).
    public var platformTransferSeconds: UInt32 = 60
    /// Stations whose platforms lie on different levels or far apart, by station code: at
    /// Journal Square (NWK–WTC vs. JSQ–33 platforms) and World Trade Center.
    public var stationTransferSeconds: [String: UInt32] = ["JSQ": 120, "WTC": 120]

    public init() {}

    /// The change time between two platforms of the station with this code.
    public func transferSeconds(station code: String) -> UInt32 {
        stationTransferSeconds[code] ?? platformTransferSeconds
    }
}

/// What ``GTFSFeed/synthesizePATHStations(_:)`` changed.
public struct PATHStationSynthesis: Codable, Sendable, Equatable {
    /// Places turned into `location_type` 1 stations (those with at least one platform).
    public var parentStations = 0
    /// Boarding stops given a parent, by name (and distance) or by distance alone.
    public var platformsMappedByName = 0
    public var platformsMappedByDistance = 0
    /// Places no boarding stop maps to (left as they are; the compiler drops uncalled stops).
    public var placesWithoutPlatforms: [String] = []
    /// Platform-to-platform rows added (both directions of every pair in a station).
    public var transfers = 0
    /// The feed already had stations or `transfers.txt` rows, so that part was left alone.
    public var keptFeedStations = false
    public var keptFeedTransfers = false

    public init() {}
}

extension GTFSFeed {
    /// The PATH feed has no parent stations and no `transfers.txt`: each station is one
    /// `place_XXX` row (no `location_type`, no children) plus two boarding stops (four at
    /// Journal Square) with the same name and coordinate. This makes every place a station,
    /// gives each boarding stop its place as `parent_station`, and adds a `transfer_type` 2 row
    /// with ``PATHStationOptions/transferSeconds(station:)`` between every two platforms of one
    /// station, stored like the subway's `transfers.txt` rows.
    ///
    /// Deterministic: places and stops are taken in `stop_id` order, ties go to the nearer place,
    /// then the smaller id. Throws when a boarding stop maps to no place (or to two equally good
    /// ones), so a changed feed fails the build rather than silently losing transfers.
    @discardableResult
    public mutating func synthesizePATHStations(_ options: PATHStationOptions = PATHStationOptions()) throws -> PATHStationSynthesis {
        var result = PATHStationSynthesis()
        let isPlace = stops.map { $0.id.hasPrefix(options.placePrefix) }
        let places = stops.indices.filter { isPlace[$0] }.sorted { stops[$0].id < stops[$1].id }
        var childrenOf: [Int: [Int]] = [:]

        if stops.contains(where: { $0.locationType == 1 || !$0.parentID.isEmpty }) {
            result.keptFeedStations = true
            for (index, stop) in stops.enumerated() where !stop.parentID.isEmpty {
                if let parent = stopIDs.lookup(stop.parentID) { childrenOf[Int(parent), default: []].append(index) }
            }
        } else {
            guard !places.isEmpty else {
                throw GTFSError.unmappedPlatforms(feed: source.name, stops: ["(no \(options.placePrefix)* rows)"])
            }
            func normalized(_ name: String) -> String {
                name.trimmingCharacters(in: .whitespaces).lowercased()
            }
            func coordinate(_ index: Int) -> Coordinate {
                Coordinate(lat: Double(stops[index].latE6) / 1e6, lon: Double(stops[index].lonE6) / 1e6)
            }
            var unmapped: [String] = []
            let platforms = stops.indices.filter { !isPlace[$0] && stops[$0].locationType == 0 }.sorted { stops[$0].id < stops[$1].id }
            for platform in platforms {
                let here = coordinate(platform)
                let near = places.map { (place: $0, meters: coordinate($0).distance(to: here)) }
                    .filter { $0.meters <= options.maxParentDistanceMeters }
                let named = near.filter { normalized(stops[$0.place].name) == normalized(stops[platform].name) }
                let pool = named.isEmpty ? near : named
                let ranked = pool.sorted { ($0.meters, stops[$0.place].id) < ($1.meters, stops[$1.place].id) }
                guard let best = ranked.first else {
                    unmapped.append("\(stops[platform].id) \(stops[platform].name)")
                    continue
                }
                // Without a name to decide, two places at the same distance are ambiguous.
                if named.isEmpty, ranked.count > 1, ranked[1].meters - best.meters < 1 {
                    unmapped.append("\(stops[platform].id) \(stops[platform].name) (ambiguous)")
                    continue
                }
                if named.isEmpty { result.platformsMappedByDistance += 1 } else { result.platformsMappedByName += 1 }
                stops[platform].parentID = stops[best.place].id
                childrenOf[best.place, default: []].append(platform)
            }
            guard unmapped.isEmpty else { throw GTFSError.unmappedPlatforms(feed: source.name, stops: unmapped) }
            for place in places {
                if childrenOf[place] == nil {
                    result.placesWithoutPlatforms.append(stops[place].id)
                } else {
                    stops[place].locationType = 1
                    result.parentStations += 1
                }
            }
        }

        if !transfers.isEmpty {
            result.keptFeedTransfers = true
            return result
        }
        for station in childrenOf.keys.sorted(by: { stops[$0].id < stops[$1].id }) {
            let id = stops[station].id
            let code = id.hasPrefix(options.placePrefix) ? String(id.dropFirst(options.placePrefix.count)) : id
            let seconds = Int(options.transferSeconds(station: code))
            let children = childrenOf[station]!.map { stops[$0].id }.sorted()
            for from in children {
                for to in children where to != from {
                    transfers.append(Transfer(fromStop: from, toStop: to, fromTrip: "", toTrip: "", type: 2, minTransferSeconds: seconds))
                    result.transfers += 1
                }
            }
        }
        return result
    }
}
