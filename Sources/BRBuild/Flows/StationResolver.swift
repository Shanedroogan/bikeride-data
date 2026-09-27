import BRCore
import BRFlows
import BRStreetCore
import Foundation

/// Why a flows build refused its inputs before counting a trip.
public enum FlowsInputError: Error, Equatable, CustomStringConvertible {
    /// Two GBFS stations share a `short_name`: trip ends could not be told apart.
    case duplicateShortName(String)
    /// A one-decimal key `X` and `X0` are both GBFS short names, so the pad-0 repair of a
    /// trip id `X` would be ambiguous.
    case ambiguousPadZero([String])
    case tooManyKeys(Int)
    case malformedDepots(String)
    case malformedHolidays(String)
    /// The trip window reaches days `holidays.csv` does not cover.
    case holidaysDoNotCover(first: ServiceDate, last: ServiceDate, covered: ClosedRange<ServiceDate>)

    public var description: String {
        switch self {
        case .duplicateShortName(let key): "two GBFS stations share short_name '\(key)'"
        case .ambiguousPadZero(let keys): "GBFS has both X and X0 for \(keys.joined(separator: ", ")): the pad-0 repair would be ambiguous"
        case .tooManyKeys(let count): "\(count) GBFS stations, more than a flows file can key (\(FlowsFormat.maxKeys))"
        case .malformedDepots(let why): "depots.csv: \(why)"
        case .malformedHolidays(let why): "holidays.csv: \(why)"
        case .holidaysDoNotCover(let first, let last, let covered):
            "the trip window \(first)…\(last) is not covered by holidays.csv (\(covered.lowerBound)…\(covered.upperBound)); extend the file"
        }
    }
}

/// The flows key universe: every GBFS `station_information` station with a `short_name`, whatever
/// its capacity (0 included, unlike `stations`), except the test regions. Keyed by `short_name`,
/// which is what the trip data's station id columns hold; strictly ascending by bytes.
public struct FlowUniverse: Sendable {
    public struct Station: Sendable, Equatable {
        public var key: String
        public var stationID: String
        public var name: String
        public var latE6: Int32
        public var lonE6: Int32
        /// GBFS `capacity`, clamped to `u16`; 0 when absent.
        public var capacity: UInt16
    }

    /// Citi Bike's test regions.
    public static let testRegions: Set<String> = ["189", "190"]

    public let stations: [Station]
    /// GBFS `station_id`s of every feed station: a trip id equal to one of them is reported as a
    /// "station_id-style" id (the trip data uses short names).
    public let stationIDs: Set<String>
    public var feedStations = 0
    public var droppedTestRegion = 0
    public var droppedNoShortName = 0
    /// Later entries repeating a `station_id` (the first is kept, as in `stations`).
    public var droppedDuplicateStationID = 0
    public var capacityZero = 0

    public init(gbfs: [GBFSStation]) throws {
        feedStations = gbfs.count
        var seenIDs = Set<String>()
        var byKey: [String: Station] = [:]
        for station in gbfs {
            if let region = station.regionID, Self.testRegions.contains(region) {
                droppedTestRegion += 1
                continue
            }
            guard seenIDs.insert(station.stationID).inserted else {
                droppedDuplicateStationID += 1
                continue
            }
            guard !station.shortName.isEmpty else {
                droppedNoShortName += 1
                continue
            }
            let capacity = UInt16(clamping: max(0, station.capacity ?? 0))
            if capacity == 0 { capacityZero += 1 }
            guard byKey[station.shortName] == nil else { throw FlowsInputError.duplicateShortName(station.shortName) }
            byKey[station.shortName] = Station(
                key: station.shortName, stationID: station.stationID, name: station.name,
                latE6: StreetsFormat.microdegrees(station.lat), lonE6: StreetsFormat.microdegrees(station.lon), capacity: capacity
            )
        }
        guard byKey.count <= FlowsFormat.maxKeys else { throw FlowsInputError.tooManyKeys(byKey.count) }
        let ambiguous = byKey.keys.filter { StationResolver.isOneDecimal(Array($0.utf8)[...]) && byKey[$0 + "0"] != nil }
        guard ambiguous.isEmpty else {
            throw FlowsInputError.ambiguousPadZero(ambiguous.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        }
        stations = byKey.values.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        stationIDs = seenIDs
    }
}

/// Trip ids that are Citi Bike depots, warehouses and other staff locations, not stations
/// (`Data/flows/depots.csv`): their trip ends are neither counted nor unmatched.
public struct DepotList: Sendable, Equatable {
    public var exact: Set<[UInt8]>
    public var prefixes: [[UInt8]]

    public init(exact: [String] = [], prefixes: [String] = []) {
        self.exact = Set(exact.map { Array($0.utf8) })
        self.prefixes = prefixes.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// `id,match,name,note` with a header row; `match` is `exact` or `prefix`. Ids are taken
    /// byte for byte (quote one with a trailing space).
    public init(csv: Data) throws {
        var reader = CSVReader(bytes: csv)
        guard let headerRecord = try reader.next() else { throw FlowsInputError.malformedDepots("empty file") }
        let header = CSVHeader(headerRecord)
        guard let idColumn = header.index(of: "id"), let matchColumn = header.index(of: "match") else {
            throw FlowsInputError.malformedDepots("needs id and match columns")
        }
        var exact: [String] = [], prefixes: [String] = []
        while let record = try reader.next() {
            let id = record[idColumn].string
            guard !id.isEmpty else { throw FlowsInputError.malformedDepots("row \(reader.recordCount): empty id") }
            switch record[matchColumn].string {
            case "exact": exact.append(id)
            case "prefix": prefixes.append(id)
            case let other: throw FlowsInputError.malformedDepots("row \(reader.recordCount): match '\(other)' is not exact or prefix")
            }
        }
        self.init(exact: exact, prefixes: prefixes)
    }

    public func contains<Bytes: Collection<UInt8>>(_ id: Bytes) -> Bool {
        if exact.contains(Array(id)) { return true }
        return prefixes.contains { id.starts(with: $0) }
    }
}

/// How one trip end's station id resolved.
public enum StationResolution: Equatable, Sendable {
    /// The id is a key, byte for byte.
    case exact(Int)
    /// A one-decimal id `X` that is no key while `X0` is: the trip data drops trailing zeros from
    /// some end ids (`5343.1` for `5343.10`).
    case repaired(Int)
    /// Empty id: an e-bike left outside a dock.
    case dockless
    /// A depot or staff location (``DepotList``).
    case depot
    case unmatched
}

/// Resolves trip-data station ids against the key universe: exact bytes, then the pad-0 repair,
/// then dockless (empty), then depot, else unmatched. Rows are keys' indices in byte order.
public struct StationResolver: Sendable {
    private let rows: [[UInt8]: Int]
    public let depots: DepotList

    public init(keys: [String], depots: DepotList) {
        var rows: [[UInt8]: Int] = [:]
        for (row, key) in keys.enumerated() { rows[Array(key.utf8)] = row }
        self.rows = rows
        self.depots = depots
    }

    public func resolve<Bytes: Collection<UInt8>>(_ id: Bytes) -> StationResolution {
        let bytes = Array(id)
        if let row = rows[bytes] { return .exact(row) }
        if Self.isOneDecimal(bytes[...]), let row = rows[bytes + [UInt8(ascii: "0")]] { return .repaired(row) }
        if bytes.isEmpty { return .dockless }
        if depots.contains(bytes) { return .depot }
        return .unmatched
    }

    /// `^[0-9]+\.[0-9]$`.
    static func isOneDecimal(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.count >= 3, bytes[bytes.endIndex - 2] == UInt8(ascii: "."), isDigit(bytes[bytes.endIndex - 1]) else { return false }
        return bytes.dropLast(2).allSatisfy(isDigit)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
}

/// A per-worker memo of ``StationResolver/resolve(_:)``: about 2,600 distinct ids recur millions of
/// times. Ids of up to 16 bytes are keyed by two words (no allocation); longer ones by their bytes.
struct ResolutionCache {
    private struct ShortID: Hashable {
        let low: UInt64
        let high: UInt64
        let count: UInt8
    }

    let resolver: StationResolver
    private var short: [ShortID: StationResolution] = [:]
    private var long: [[UInt8]: StationResolution] = [:]

    init(resolver: StationResolver) {
        self.resolver = resolver
    }

    mutating func resolve(_ id: ArraySlice<UInt8>) -> StationResolution {
        guard id.count <= 16 else {
            let bytes = Array(id)
            if let cached = long[bytes] { return cached }
            let resolution = resolver.resolve(bytes)
            long[bytes] = resolution
            return resolution
        }
        var low: UInt64 = 0, high: UInt64 = 0
        for (offset, byte) in id.enumerated() {
            if offset < 8 { low |= UInt64(byte) << UInt64(offset * 8) } else { high |= UInt64(byte) << UInt64((offset - 8) * 8) }
        }
        let key = ShortID(low: low, high: high, count: UInt8(id.count))
        if let cached = short[key] { return cached }
        let resolution = resolver.resolve(id)
        short[key] = resolution
        return resolution
    }
}
