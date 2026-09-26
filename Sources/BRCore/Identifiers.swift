/// A transit system, with the one-letter code used in artifact names and qualified IDs.
public enum TransitSystem: String, CaseIterable, Codable, Sendable {
    case subway = "S"
    case bus = "B"
    case lirr = "L"
    case ferry = "F"
    case path = "P"
}

/// A string-backed identifier. Conformers get `Codable` as a bare string, literal syntax,
/// and ordering by raw value.
public protocol StringIdentifier: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral where RawValue == String
{
    init(rawValue: String)
}

extension StringIdentifier {
    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// An identifier that GTFS scopes to one feed. Qualified form: `"<system code>:<gtfs id>"`,
/// e.g. `S:127N`, so IDs from different systems never collide.
public protocol SystemScopedIdentifier: StringIdentifier {}

extension SystemScopedIdentifier {
    public init(system: TransitSystem, gtfsID: some StringProtocol) {
        self.init(rawValue: "\(system.rawValue):\(gtfsID)")
    }

    /// The system from the qualifier, or `nil` if the ID is unqualified.
    public var system: TransitSystem? {
        guard let colon = rawValue.firstIndex(of: ":") else { return nil }
        return TransitSystem(rawValue: String(rawValue[..<colon]))
    }

    /// The feed-local GTFS ID, without the system qualifier.
    public var gtfsID: Substring {
        guard system != nil, let colon = rawValue.firstIndex(of: ":") else { return rawValue[...] }
        return rawValue[rawValue.index(after: colon)...]
    }
}

public struct StopID: SystemScopedIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct TripID: SystemScopedIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct RouteID: SystemScopedIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A Citi Bike station, keyed by its GBFS `station_id` string.
public struct StationID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
