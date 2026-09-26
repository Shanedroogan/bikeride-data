import BRGeo

/// Shape geometry helpers for the timetable compiler: stop-to-vertex matching and
/// Douglas–Peucker simplification in a local planar projection.
enum ShapeGeometry {
    /// A projection centered on New York City; error is well under 1% across the region.
    static let projection = LocalProjection(origin: Coordinate(lat: 40.73, lon: -73.95))

    static func planar(latE6: Int32, lonE6: Int32) -> PlanarPoint {
        projection.project(Coordinate(lat: Double(latE6) / 1e6, lon: Double(lonE6) / 1e6))
    }

    /// For each stop, in order, the index of a nearby vertex of `line`, never decreasing.
    ///
    /// Scans forward from the previous stop's vertex and takes the closest vertex, stopping
    /// early once the line has come within `closeMeters` of the stop and then moved more than
    /// `leaveMeters` farther away than that best, so a line that later loops back past the
    /// stop is not matched to its second pass.
    static func stopVertices(stops: [PlanarPoint], line: [PlanarPoint],
                             closeMeters: Double = 60, leaveMeters: Double = 250) -> [Int] {
        guard !line.isEmpty else { return [Int](repeating: 0, count: stops.count) }
        var result: [Int] = []
        result.reserveCapacity(stops.count)
        var start = 0
        for stop in stops {
            var best = start
            var bestDistance = Double.infinity
            var index = start
            while index < line.count {
                let distance = line[index].distance(to: stop)
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                } else if bestDistance <= closeMeters && distance > bestDistance + leaveMeters {
                    break
                }
                index += 1
            }
            result.append(best)
            start = best
        }
        return result
    }

    /// Indices of the vertices kept by Douglas–Peucker at `tolerance` meters. Vertices marked in
    /// `keep` (and both ends) are always kept; each span between kept vertices is simplified on
    /// its own. Ascending.
    static func simplify(_ points: [PlanarPoint], keep: [Bool], tolerance: Double) -> [Int] {
        let count = points.count
        guard count > 2 else { return Array(0..<count) }
        var kept = [Bool](repeating: false, count: count)
        kept[0] = true
        kept[count - 1] = true
        for index in 0..<count where keep[index] { kept[index] = true }
        let anchors = (0..<count).filter { kept[$0] }
        var stack: [(Int, Int)] = []
        for (a, b) in zip(anchors, anchors.dropFirst()) where b - a > 1 { stack.append((a, b)) }
        while let (first, last) = stack.popLast() {
            var farthest = -1
            var farthestDistance = tolerance
            for index in (first + 1)..<last {
                let distance = points[index].projection(ontoSegmentFrom: points[first], to: points[last]).distance
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthest = index
                }
            }
            if farthest >= 0 {
                kept[farthest] = true
                if farthest - first > 1 { stack.append((first, farthest)) }
                if last - farthest > 1 { stack.append((farthest, last)) }
            }
        }
        return (0..<count).filter { kept[$0] }
    }
}
