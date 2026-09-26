import BRGeo
import Foundation

/// A snapped position saved in another artifact (`stations`, `links`): the street segment and the
/// position along it, at stored precision. The app rebuilds the ``SnappedPoint`` with
/// ``MappedStreetGraph/snappedPoint(_:query:)`` instead of searching the snap grid again.
///
/// Only valid against the `streets` artifact it was computed on; artifacts that store snaps name
/// that artifact's rawSha256 in their header's `builtAgainst`.
public struct StoredSnap: Sendable, Hashable {
    public var segment: UInt32
    /// Position along the segment by length: 0 at its A node, 1 at B.
    public var fraction: Float
    /// Straight-line distance from the snapped coordinate to the segment, in decimeters.
    public var distanceDecimeters: UInt16

    public init(segment: UInt32, fraction: Float, distanceDecimeters: UInt16) {
        self.segment = segment
        self.fraction = fraction
        self.distanceDecimeters = distanceDecimeters
    }

    /// Quantizes a snap to stored precision. Distances beyond 6,553.5 m saturate.
    public init(_ point: SnappedPoint) {
        segment = point.segment
        fraction = Float(min(1, max(0, point.fraction)))
        distanceDecimeters = UInt16(min(Double(UInt16.max), (point.distanceMeters * 10).rounded()))
    }

    public var distanceMeters: Double { Double(distanceDecimeters) / 10 }
}

extension MappedStreetGraph {
    /// The snapped point a stored snap describes, with `query` as the coordinate that was snapped;
    /// `nil` when the segment is out of range (a snap made against another streets artifact).
    public func snappedPoint(_ stored: StoredSnap, query: Coordinate) -> SnappedPoint? {
        guard Int(stored.segment) < segmentCount, stored.fraction.isFinite else { return nil }
        let fraction = min(1, max(0, Double(stored.fraction)))
        let (a, b) = endpoints(ofSegment: stored.segment)
        let (forward, backward) = edges(ofSegment: stored.segment)
        return SnappedPoint(
            segment: stored.segment, nodeA: a, nodeB: b, forwardEdge: forward, backwardEdge: backward,
            fraction: fraction, distanceMeters: stored.distanceMeters,
            coordinate: coordinate(onSegment: stored.segment, fraction: fraction), query: query
        )
    }

    /// The point `fraction` of the way along a segment's geometry, by planar length.
    public func coordinate(onSegment segment: UInt32, fraction: Double) -> Coordinate {
        let points = shape(ofSegment: segment)
        guard points.count >= 2 else { return points.first ?? Coordinate(lat: 0, lon: 0) }
        let projection = LocalProjection(origin: points[0])
        let planar = points.map(projection.project)
        var lengths: [Double] = []
        lengths.reserveCapacity(planar.count - 1)
        for i in 1..<planar.count { lengths.append(planar[i - 1].distance(to: planar[i])) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return points[0] }
        var remaining = min(1, max(0, fraction)) * total
        for (i, length) in lengths.enumerated() {
            if remaining <= length || i == lengths.count - 1 {
                let t = length > 0 ? min(1, remaining / length) : 0
                let a = planar[i], b = planar[i + 1]
                return projection.unproject(PlanarPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
            remaining -= length
        }
        return points[points.count - 1]
    }
}
