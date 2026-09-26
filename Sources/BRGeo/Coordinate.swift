import Foundation

/// A WGS 84 position in degrees.
public struct Coordinate: Hashable, Sendable, Codable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

public enum Earth {
    /// IUGG mean radius. Every spherical formula in this package uses it, so haversine and
    /// ``LocalProjection`` distances agree at short range.
    public static let meanRadiusMeters = 6_371_008.8
}

extension Coordinate {
    /// Great-circle distance in meters.
    public func distance(to other: Coordinate, radius: Double = Earth.meanRadiusMeters) -> Double {
        let phi1 = lat.radians, phi2 = other.lat.radians
        let sinHalfDeltaPhi = sin((phi2 - phi1) / 2)
        let sinHalfDeltaLambda = sin((other.lon - lon).radians / 2)
        let h = sinHalfDeltaPhi * sinHalfDeltaPhi + cos(phi1) * cos(phi2) * sinHalfDeltaLambda * sinHalfDeltaLambda
        return 2 * radius * asin(min(1, h.squareRoot()))
    }

    /// Initial great-circle bearing toward `other`, in degrees clockwise from true north, `[0, 360)`.
    public func initialBearing(to other: Coordinate) -> Double {
        let phi1 = lat.radians, phi2 = other.lat.radians
        let deltaLambda = (other.lon - lon).radians
        let y = sin(deltaLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : (degrees >= 360 ? degrees - 360 : degrees)
    }
}

extension Double {
    @inline(__always) var radians: Double { self * .pi / 180 }
}
