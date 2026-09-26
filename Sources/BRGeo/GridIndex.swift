/// A uniform grid of points for radius and k-nearest queries.
///
/// Distances are planar meters in ``projection``; see ``LocalProjection`` for accuracy.
/// Results are sorted by distance, ties broken by insertion order, so queries are deterministic.
public struct GridIndex<ID> {
    public struct Hit {
        public let id: ID
        public let coordinate: Coordinate
        /// Meters from the query point.
        public let distance: Double
    }

    public let projection: LocalProjection
    public let cellSizeMeters: Double

    fileprivate struct Entry {
        let id: ID
        let coordinate: Coordinate
        let point: PlanarPoint
    }

    private struct Cell: Hashable {
        var x: Int
        var y: Int
    }

    private struct CellRange {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    }

    private var entries: [Entry] = []
    private var cells: [Cell: [Int]] = [:]
    private var occupied = CellRange()

    public init(cellSizeMeters: Double, projection: LocalProjection) {
        precondition(cellSizeMeters > 0, "cellSizeMeters must be positive")
        self.cellSizeMeters = cellSizeMeters
        self.projection = projection
    }

    public var count: Int { entries.count }

    public mutating func insert(_ id: ID, at coordinate: Coordinate) {
        let point = projection.project(coordinate)
        let cell = cell(containing: point)
        cells[cell, default: []].append(entries.count)
        entries.append(Entry(id: id, coordinate: coordinate, point: point))
        occupied.minX = min(occupied.minX, cell.x); occupied.maxX = max(occupied.maxX, cell.x)
        occupied.minY = min(occupied.minY, cell.y); occupied.maxY = max(occupied.maxY, cell.y)
    }

    /// The `k` points closest to `coordinate`, nearest first.
    public func nearest(to coordinate: Coordinate, k: Int) -> [Hit] {
        guard k > 0, !entries.isEmpty else { return [] }
        let query = projection.project(coordinate)
        let center = cell(containing: query)
        // Rings before the first that reaches an occupied cell, or after the last, are empty.
        let firstRing = max(occupied.minX - center.x, center.x - occupied.maxX,
                            occupied.minY - center.y, center.y - occupied.maxY, 0)
        let lastRing = max(center.x - occupied.minX, occupied.maxX - center.x,
                           center.y - occupied.minY, occupied.maxY - center.y, 0)
        var best: [Candidate] = []
        var cellsVisited = 0
        for ring in firstRing...lastRing {
            cellsVisited += forEachCell(inRing: ring, around: center) { index in
                best.append(Candidate(distance: entries[index].point.distance(to: query), index: index))
            }
            // Far queries on fine grids cross many empty cells; past this point a scan of the
            // points themselves is cheaper, and exact.
            if cellsVisited > entries.count {
                return linearScan(from: query) { _ in true }.prefix(k).map(hit)
            }
            guard best.count >= k else { continue }
            best.sort()
            best.removeSubrange(k...)
            // The query lies in the center cell, so any cell outside rings 0...ring is at
            // least `ring` whole cells away.
            if best[k - 1].distance <= Double(ring) * cellSizeMeters { break }
        }
        best.sort()
        return best.prefix(k).map(hit)
    }

    /// Every point within `radiusMeters` of `coordinate`, nearest first.
    public func within(radiusMeters: Double, of coordinate: Coordinate) -> [Hit] {
        guard radiusMeters >= 0, !entries.isEmpty else { return [] }
        let query = projection.project(coordinate)
        let center = cell(containing: query)
        let reach = Int(min((radiusMeters / cellSizeMeters).rounded(.up), 1e9))
        guard let xs = Self.clamp(center.x - reach, center.x + reach, to: occupied.minX, occupied.maxX),
              let ys = Self.clamp(center.y - reach, center.y + reach, to: occupied.minY, occupied.maxY)
        else { return [] }
        let (cellCount, overflow) = xs.count.multipliedReportingOverflow(by: ys.count)
        if overflow || cellCount > entries.count {
            return linearScan(from: query) { $0 <= radiusMeters }.map(hit)
        }
        var found: [Candidate] = []
        for y in ys {
            for x in xs {
                for index in cells[Cell(x: x, y: y)] ?? [] {
                    let distance = entries[index].point.distance(to: query)
                    if distance <= radiusMeters { found.append(Candidate(distance: distance, index: index)) }
                }
            }
        }
        found.sort()
        return found.map(hit)
    }

    /// Every entry whose distance passes `include`, sorted.
    private func linearScan(from query: PlanarPoint, where include: (Double) -> Bool) -> [Candidate] {
        entries.indices.compactMap { index -> Candidate? in
            let distance = entries[index].point.distance(to: query)
            return include(distance) ? Candidate(distance: distance, index: index) : nil
        }.sorted()
    }

    private struct Candidate: Comparable {
        let distance: Double
        let index: Int

        static func < (a: Candidate, b: Candidate) -> Bool {
            (a.distance, a.index) < (b.distance, b.index)
        }
    }

    private func hit(_ candidate: Candidate) -> Hit {
        let entry = entries[candidate.index]
        return Hit(id: entry.id, coordinate: entry.coordinate, distance: candidate.distance)
    }

    private func cell(containing point: PlanarPoint) -> Cell {
        func index(_ meters: Double) -> Int {
            Int(max(-1e15, min(1e15, (meters / cellSizeMeters).rounded(.down))))
        }
        return Cell(x: index(point.x), y: index(point.y))
    }

    private static func clamp(_ lower: Int, _ upper: Int, to minimum: Int, _ maximum: Int) -> ClosedRange<Int>? {
        let lo = max(lower, minimum), hi = min(upper, maximum)
        return lo <= hi ? lo...hi : nil
    }

    /// Visits entries in cells at Chebyshev distance exactly `ring` from `center`, skipping
    /// cells outside the occupied range. Returns the number of cells looked up.
    private func forEachCell(inRing ring: Int, around center: Cell, _ body: (Int) -> Void) -> Int {
        var visited = 0
        func visit(_ x: Int, _ y: Int) {
            visited += 1
            for index in cells[Cell(x: x, y: y)] ?? [] { body(index) }
        }
        if ring == 0 {
            visit(center.x, center.y)
            return visited
        }
        let o = occupied
        if let columns = Self.clamp(center.x - ring, center.x + ring, to: o.minX, o.maxX) {
            for y in [center.y - ring, center.y + ring] where (o.minY...o.maxY).contains(y) {
                for x in columns { visit(x, y) }
            }
        }
        if let rows = Self.clamp(center.y - ring + 1, center.y + ring - 1, to: o.minY, o.maxY) {
            for x in [center.x - ring, center.x + ring] where (o.minX...o.maxX).contains(x) {
                for y in rows { visit(x, y) }
            }
        }
        return visited
    }
}

extension GridIndex: Sendable where ID: Sendable {}
extension GridIndex.Hit: Sendable where ID: Sendable {}
extension GridIndex.Hit: Equatable where ID: Equatable {}
extension GridIndex.Entry: Sendable where ID: Sendable {}
