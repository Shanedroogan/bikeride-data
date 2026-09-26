import Foundation

/// A point in a ``LocalProjection``'s plane, in meters east (`x`) and north (`y`) of its origin.
public struct PlanarPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: PlanarPoint) -> Double {
        let dx = other.x - x, dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The closest point to `self` on the segment `a`–`b`.
    public func projection(ontoSegmentFrom a: PlanarPoint, to b: PlanarPoint) -> SegmentProjection {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        var fraction = 0.0
        if lengthSquared > 0 {
            fraction = min(1, max(0, ((x - a.x) * dx + (y - a.y) * dy) / lengthSquared))
        }
        let closest = PlanarPoint(x: a.x + fraction * dx, y: a.y + fraction * dy)
        return SegmentProjection(point: closest, fraction: fraction, distance: distance(to: closest))
    }
}

/// Where a point lands on a segment.
public struct SegmentProjection: Sendable, Equatable {
    /// The closest point on the segment.
    public var point: PlanarPoint
    /// Position of ``point`` along the segment: 0 at the start, 1 at the end.
    public var fraction: Double
    /// Meters from the query point to ``point``.
    public var distance: Double

    public init(point: PlanarPoint, fraction: Double, distance: Double) {
        self.point = point
        self.fraction = fraction
        self.distance = distance
    }
}

/// An equirectangular projection around a reference coordinate, for fast planar math over
/// city-sized areas.
///
/// East–west scale is fixed at the origin's latitude, so distance error grows with north–south
/// separation from the origin: under 0.5% across the five boroughs from a Midtown origin.
public struct LocalProjection: Sendable, Equatable {
    public let origin: Coordinate
    public let metersPerDegreeLat: Double
    public let metersPerDegreeLon: Double

    public init(origin: Coordinate) {
        self.origin = origin
        metersPerDegreeLat = Earth.meanRadiusMeters * .pi / 180
        metersPerDegreeLon = metersPerDegreeLat * cos(origin.lat.radians)
    }

    public func project(_ coordinate: Coordinate) -> PlanarPoint {
        PlanarPoint(
            x: (coordinate.lon - origin.lon) * metersPerDegreeLon,
            y: (coordinate.lat - origin.lat) * metersPerDegreeLat
        )
    }

    public func unproject(_ point: PlanarPoint) -> Coordinate {
        Coordinate(lat: origin.lat + point.y / metersPerDegreeLat, lon: origin.lon + point.x / metersPerDegreeLon)
    }

    public func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        project(a).distance(to: project(b))
    }

    public func projection(of coordinate: Coordinate, ontoSegmentFrom a: Coordinate, to b: Coordinate) -> SegmentProjection {
        project(coordinate).projection(ontoSegmentFrom: project(a), to: project(b))
    }
}
