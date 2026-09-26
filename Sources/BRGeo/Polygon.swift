/// An axis-aligned box in degrees.
public struct BoundingBox: Hashable, Sendable {
    public var minLat: Double
    public var minLon: Double
    public var maxLat: Double
    public var maxLon: Double

    /// The smallest box containing `coordinates`, or `nil` if there are none.
    public init?(_ coordinates: some Sequence<Coordinate>) {
        var iterator = coordinates.makeIterator()
        guard let first = iterator.next() else { return nil }
        minLat = first.lat; maxLat = first.lat
        minLon = first.lon; maxLon = first.lon
        while let c = iterator.next() {
            minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon)
        }
    }

    public func contains(_ c: Coordinate) -> Bool {
        c.lat >= minLat && c.lat <= maxLat && c.lon >= minLon && c.lon <= maxLon
    }
}

/// A polygon with optional holes. Rings may be open or closed (first point repeated).
///
/// Containment uses even–odd ray casting in degree space, which is exact for the straight-edged
/// rings we store at city scale. Points exactly on an edge may land either side.
public struct Polygon: Hashable, Sendable {
    public let exterior: [Coordinate]
    public let holes: [[Coordinate]]
    public let bounds: BoundingBox?

    public init(exterior: [Coordinate], holes: [[Coordinate]] = []) {
        self.exterior = exterior
        self.holes = holes
        bounds = BoundingBox(exterior)
    }

    public func contains(_ point: Coordinate) -> Bool {
        guard let bounds, bounds.contains(point), Self.ring(exterior, contains: point) else { return false }
        return !holes.contains { Self.ring($0, contains: point) }
    }

    static func ring(_ ring: [Coordinate], contains p: Coordinate) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.lat > p.lat) != (b.lat > p.lat) {
                let crossingLon = a.lon + (p.lat - a.lat) * (b.lon - a.lon) / (b.lat - a.lat)
                if p.lon < crossingLon { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

public struct MultiPolygon: Hashable, Sendable {
    public let polygons: [Polygon]

    public init(_ polygons: [Polygon]) {
        self.polygons = polygons
    }

    public func contains(_ point: Coordinate) -> Bool {
        polygons.contains { $0.contains(point) }
    }
}
