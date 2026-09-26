/// The parts of an NYCT subway trip id that static and real-time feeds share.
///
/// Static ids end in `_<origin>_<route>.<dots…><N|S><path>`, e.g.
/// `ASP26GEN-1038-Sunday-00_000600_1..S03R` (origin 6.00 min, route `1`, south, path `03R`) or
/// `…_086700_GS.S04R`. Real-time ids are the same suffix without the leading underscore:
/// `000600_1..S03R`. The patterns (as regular expressions, hand-parsed here) are
/// `_(-?\d{6})_([A-Z0-9]+)\.+([NS])(.*)$` and `^(-?\d{6})_([A-Z0-9]+)\.+([NS])(.*)$`.
public struct SubwayTripKey: Hashable, Sendable, CustomStringConvertible {
    /// Minutes past the service day's origin × 100, e.g. `000600` → 600 (00:06:00).
    public var originHundredths: Int32
    public var route: String
    /// ASCII `N` or `S`.
    public var direction: UInt8
    /// Whatever follows the direction letter, e.g. `03R`. May be empty.
    public var path: String

    public init(originHundredths: Int32, route: String, direction: UInt8, path: String) {
        self.originHundredths = originHundredths
        self.route = route
        self.direction = direction
        self.path = path
    }

    /// The canonical real-time form, e.g. `000600_1.S03R` (six-digit origin, one dot), which
    /// ``init(realtimeTripID:)`` parses back to an equal key.
    public var description: String {
        let digits = String(originHundredths.magnitude)
        let origin = (originHundredths < 0 ? "-" : "") + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
        return "\(origin)_\(route).\(Character(Unicode.Scalar(direction)))\(path)"
    }

    /// Seconds after the service day's origin that the origin time denotes (hundredths of a
    /// minute × 0.6, rounded to the nearest second).
    public var originSeconds: Int32 {
        (originHundredths * 60 + (originHundredths >= 0 ? 50 : -50)) / 100
    }

    /// Parses a static GTFS trip id. Returns `nil` if no `_origin_route.dir…` suffix matches.
    public init?(staticTripID: String) {
        guard let key = Self.parse(Array(staticTripID.utf8), anchored: false) else { return nil }
        self = key
    }

    /// Parses a GTFS-RT `trip_id`, which must start with the origin.
    public init?(realtimeTripID: String) {
        guard let key = Self.parse(Array(realtimeTripID.utf8), anchored: true) else { return nil }
        self = key
    }

    public init?(staticTripID bytes: some Collection<UInt8>) {
        guard let key = Self.parse(Array(bytes), anchored: false) else { return nil }
        self = key
    }

    /// Regex semantics: for the unanchored form, the leftmost `_` from which the rest matches.
    static func parse(_ bytes: [UInt8], anchored: Bool) -> SubwayTripKey? {
        if anchored { return match(bytes, from: 0) }
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "_"), let key = match(bytes, from: index + 1) { return key }
            index += 1
        }
        return nil
    }

    /// Matches `-?\d{6}_([A-Z0-9]+)\.+([NS])(.*)$` starting exactly at `start`.
    private static func match(_ bytes: [UInt8], from start: Int) -> SubwayTripKey? {
        var index = start
        var negative = false
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
            negative = true
            index += 1
        }
        var value: Int32 = 0
        for _ in 0..<6 {
            guard index < bytes.count, isDigit(bytes[index]) else { return nil }
            value = value * 10 + Int32(bytes[index] - UInt8(ascii: "0"))
            index += 1
        }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "_") else { return nil }
        index += 1
        let routeStart = index
        while index < bytes.count, isDigit(bytes[index]) || isUpper(bytes[index]) { index += 1 }
        let routeEnd = index
        // `[A-Z0-9]+` cannot give back characters to `\.+`, so the run must be followed by a dot.
        guard routeEnd > routeStart, index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return nil }
        while index < bytes.count, bytes[index] == UInt8(ascii: ".") { index += 1 }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "N") || bytes[index] == UInt8(ascii: "S") else {
            return nil
        }
        let direction = bytes[index]
        index += 1
        return SubwayTripKey(
            originHundredths: negative ? -value : value,
            route: String(decoding: bytes[routeStart..<routeEnd], as: UTF8.self),
            direction: direction,
            path: String(decoding: bytes[index...], as: UTF8.self)
        )
    }

    @inline(__always) private static func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
    @inline(__always) private static func isUpper(_ b: UInt8) -> Bool { b >= 65 && b <= 90 }
}
