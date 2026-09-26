import BRGeo
import BRStreetCore
import Foundation

/// Planar geometry helpers used while compiling streets.
public enum StreetGeometry {
    /// Indices of the points Douglas–Peucker keeps at `toleranceMeters` (always the first and
    /// last). Iterative, so long polylines cannot overflow the stack.
    public static func douglasPeucker(_ points: [PlanarPoint], toleranceMeters: Double) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first, farthestDistance = -1.0
            for i in (first + 1)..<last {
                let d = points[i].projection(ontoSegmentFrom: points[first], to: points[last]).distance
                if d > farthestDistance {
                    farthestDistance = d
                    farthest = i
                }
            }
            if farthestDistance > toleranceMeters {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    /// Simplifies a ring or line of coordinates, projecting around its first point.
    public static func simplify(_ coordinates: [Coordinate], toleranceMeters: Double) -> [Coordinate] {
        guard coordinates.count > 2 else { return coordinates }
        let projection = LocalProjection(origin: coordinates[0])
        let kept = douglasPeucker(coordinates.map(projection.project), toleranceMeters: toleranceMeters)
        return kept.map { coordinates[$0] }
    }

    /// Position along a Hilbert curve of order 16 through `(x, y)`: nearby points get nearby
    /// indices, so ordering nodes by it keeps graph neighbors close in memory.
    public static func hilbertIndex(x: UInt16, y: UInt16) -> UInt32 {
        var rx: UInt32 = 0, ry: UInt32 = 0, d: UInt32 = 0
        var x = UInt32(x), y = UInt32(y)
        var s: UInt32 = 1 << 15
        while s > 0 {
            rx = (x & s) > 0 ? 1 : 0
            ry = (y & s) > 0 ? 1 : 0
            d += s * s * ((3 * rx) ^ ry)
            // Rotate the quadrant.
            if ry == 0 {
                if rx == 1 {
                    x = s &* 2 &- 1 &- x
                    y = s &* 2 &- 1 &- y
                }
                swap(&x, &y)
            }
            x &= s &- 1
            y &= s &- 1
            s >>= 1
        }
        return d
    }

    /// Great-circle meters between two positions in 10⁻⁷ degrees.
    @inline(__always)
    static func distanceMeters(latE7 lat1: Int32, lonE7 lon1: Int32, latE7 lat2: Int32, lonE7 lon2: Int32) -> Double {
        Coordinate(lat: Double(lat1) * 1e-7, lon: Double(lon1) * 1e-7)
            .distance(to: Coordinate(lat: Double(lat2) * 1e-7, lon: Double(lon2) * 1e-7))
    }
}

/// A raster of "near the service area" cells: every cell within `bufferMeters` of the regions'
/// polygons. Used to drop ways the extracts let in (the rest of New Jersey, Westchester, Nassau)
/// while keeping streets that leave and re-enter the service area.
public struct CityMask: Sendable {
    public let bufferMeters: Double
    private let originLat: Double, originLon: Double
    private let cellLat: Double, cellLon: Double
    private let columns: Int, rows: Int
    private let cells: [Bool]

    public init(regions: [MultiPolygon], bufferMeters: Double, cellMeters: Double = 100) {
        self.bufferMeters = bufferMeters
        let polygons = regions.flatMap(\.polygons)
        let rings = polygons.flatMap { [$0.exterior] + $0.holes }
        let bounds = BoundingBox(rings.flatMap { $0 }) ?? BoundingBox([Coordinate(lat: 0, lon: 0)])!
        let metersPerDegree = Earth.meanRadiusMeters * .pi / 180
        let midLat = (bounds.minLat + bounds.maxLat) / 2
        cellLat = cellMeters / metersPerDegree
        cellLon = cellMeters / (metersPerDegree * cos(midLat * .pi / 180))
        let margin = Int((bufferMeters / cellMeters).rounded(.up)) + 1
        originLat = bounds.minLat - Double(margin) * cellLat
        originLon = bounds.minLon - Double(margin) * cellLon
        rows = Int(((bounds.maxLat - bounds.minLat) / cellLat).rounded(.up)) + 2 * margin + 1
        columns = Int(((bounds.maxLon - bounds.minLon) / cellLon).rounded(.up)) + 2 * margin + 1

        var inside = [Bool](repeating: false, count: rows * columns)
        let grid = RasterGrid(originLat: originLat, originLon: originLon, cellLat: cellLat, cellLon: cellLon, columns: columns, rows: rows)
        for polygon in polygons {
            grid.fill(polygon) { inside[$0] = true }
        }

        // Dilate by a disc of the buffer radius.
        let radius = Int((bufferMeters / cellMeters).rounded(.up))
        var offsets: [(Int, Int)] = []
        for dy in -radius...radius {
            for dx in -radius...radius where Double(dx * dx + dy * dy) * cellMeters * cellMeters <= bufferMeters * bufferMeters + 1e-9 {
                offsets.append((dx, dy))
            }
        }
        var dilated = inside
        for row in 0..<rows {
            for column in 0..<columns where inside[row * columns + column] {
                // Only boundary cells can extend the mask.
                let interior = row > 0 && row < rows - 1 && column > 0 && column < columns - 1
                    && inside[(row - 1) * columns + column] && inside[(row + 1) * columns + column]
                    && inside[row * columns + column - 1] && inside[row * columns + column + 1]
                if interior { continue }
                for (dx, dy) in offsets {
                    let r = row + dy, c = column + dx
                    if r >= 0, r < rows, c >= 0, c < columns { dilated[r * columns + c] = true }
                }
            }
        }
        cells = dilated
    }

    public func contains(latE7: Int32, lonE7: Int32) -> Bool {
        contains(Coordinate(lat: Double(latE7) * 1e-7, lon: Double(lonE7) * 1e-7))
    }

    public func contains(_ coordinate: Coordinate) -> Bool {
        let row = Int(((coordinate.lat - originLat) / cellLat).rounded(.down))
        let column = Int(((coordinate.lon - originLon) / cellLon).rounded(.down))
        guard row >= 0, row < rows, column >= 0, column < columns else { return false }
        return cells[row * columns + column]
    }
}

/// A latitude/longitude raster: cell (column, row) covers `originLon + column·cellLon ..<` one cell
/// on, and likewise for latitude. Shared by ``CityMask`` and ``RegionRaster``.
struct RasterGrid: Sendable {
    let originLat: Double, originLon: Double
    let cellLat: Double, cellLon: Double
    let columns: Int, rows: Int

    /// Calls `body` with the index (`row × columns + column`) of every cell whose center lies in
    /// `polygon` (even–odd over the exterior and holes): a scanline fill.
    func fill(_ polygon: Polygon, _ body: (Int) -> Void) {
        let polygonRings = [polygon.exterior] + polygon.holes
        for row in 0..<rows {
            let lat = originLat + (Double(row) + 0.5) * cellLat
            var crossings: [Double] = []
            for ring in polygonRings where ring.count >= 3 {
                var j = ring.count - 1
                for i in ring.indices {
                    let a = ring[i], b = ring[j]
                    if (a.lat > lat) != (b.lat > lat) {
                        crossings.append(a.lon + (lat - a.lat) * (b.lon - a.lon) / (b.lat - a.lat))
                    }
                    j = i
                }
            }
            crossings.sort()
            var k = 0
            while k + 1 < crossings.count {
                let first = max(0, Int(((crossings[k] - originLon) / cellLon - 0.5).rounded(.up)))
                let last = min(columns - 1, Int(((crossings[k + 1] - originLon) / cellLon - 0.5).rounded(.down)))
                if first <= last { for column in first...last { body(row * columns + column) } }
                k += 2
            }
        }
    }

    func index(of coordinate: Coordinate) -> Int? {
        let row = Int(((coordinate.lat - originLat) / cellLat).rounded(.down))
        let column = Int(((coordinate.lon - originLon) / cellLon).rounded(.down))
        guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
        return row * columns + column
    }
}

/// Which region each point lies in, on a raster of the regions' polygons (no buffer): the
/// component filter uses it to keep every region's own largest network (see
/// ``StreetBuildOptions/keepLargestComponentPerRegion``). Where regions overlap, the first wins.
public struct RegionRaster: Sendable {
    public let regionCount: Int
    private let grid: RasterGrid
    private let labels: [Int16]

    public init(regions: [MultiPolygon], cellMeters: Double = 100) {
        regionCount = regions.count
        let rings = regions.flatMap(\.polygons).flatMap { [$0.exterior] + $0.holes }
        guard let bounds = BoundingBox(rings.flatMap { $0 }) else {
            grid = RasterGrid(originLat: 0, originLon: 0, cellLat: 1, cellLon: 1, columns: 0, rows: 0)
            labels = []
            return
        }
        let metersPerDegree = Earth.meanRadiusMeters * .pi / 180
        let cellLat = cellMeters / metersPerDegree
        let cellLon = cellMeters / (metersPerDegree * cos((bounds.minLat + bounds.maxLat) / 2 * .pi / 180))
        let raster = RasterGrid(
            originLat: bounds.minLat - cellLat, originLon: bounds.minLon - cellLon, cellLat: cellLat, cellLon: cellLon,
            columns: Int(((bounds.maxLon - bounds.minLon) / cellLon).rounded(.up)) + 3,
            rows: Int(((bounds.maxLat - bounds.minLat) / cellLat).rounded(.up)) + 3
        )
        var labels = [Int16](repeating: -1, count: raster.columns * raster.rows)
        for (index, region) in regions.enumerated().reversed() {
            for polygon in region.polygons { raster.fill(polygon) { labels[$0] = Int16(index) } }
        }
        grid = raster
        self.labels = labels
    }

    /// The index of the region containing the point, or `nil` outside every region.
    public func region(latE7: Int32, lonE7: Int32) -> Int? {
        guard let cell = grid.index(of: Coordinate(lat: Double(latE7) * 1e-7, lon: Double(lonE7) * 1e-7)) else { return nil }
        let label = labels[cell]
        return label >= 0 ? Int(label) : nil
    }
}

/// Park areas for the ``BRStreetCore/EdgeFlags/park`` flag, bucketed by bounding box.
public struct ParkIndex: Sendable {
    private let polygons: [Polygon]
    private let cellDegrees = 0.0025
    private var buckets: [Int64: [Int32]] = [:]

    public var count: Int { polygons.count }

    public init(polygons: [Polygon]) {
        self.polygons = polygons
        for (index, polygon) in polygons.enumerated() {
            guard let bounds = polygon.bounds else { continue }
            let (x0, y0) = cell(bounds.minLat, bounds.minLon), (x1, y1) = cell(bounds.maxLat, bounds.maxLon)
            for y in y0...y1 {
                for x in x0...x1 { buckets[key(x, y), default: []].append(Int32(index)) }
            }
        }
    }

    public func contains(_ coordinate: Coordinate) -> Bool {
        let (x, y) = cell(coordinate.lat, coordinate.lon)
        guard let candidates = buckets[key(x, y)] else { return false }
        return candidates.contains { polygons[Int($0)].contains(coordinate) }
    }

    private func cell(_ lat: Double, _ lon: Double) -> (Int, Int) {
        (Int((lon / cellDegrees).rounded(.down)), Int((lat / cellDegrees).rounded(.down)))
    }

    private func key(_ x: Int, _ y: Int) -> Int64 {
        Int64(x) << 32 | Int64(UInt32(truncatingIfNeeded: y))
    }
}

/// Reads the GeoJSON the pipeline consumes.
public enum GeoJSONAreas {
    public enum ParseError: Error, Equatable, Sendable {
        case notAFeatureCollection
        case unsupportedGeometry(String)
        case missingProperty(String)
    }

    /// The polygons of a `Polygon` or `MultiPolygon` geometry object (GeoJSON positions are
    /// `[lon, lat]`).
    public static func polygons(fromGeometry geometry: [String: Any]) throws -> [Polygon] {
        let type = geometry["type"] as? String ?? ""
        func ring(_ value: Any) -> [Coordinate] {
            (value as? [[Double]] ?? []).compactMap { $0.count >= 2 ? Coordinate(lat: $0[1], lon: $0[0]) : nil }
        }
        func polygon(_ value: Any) -> Polygon? {
            let rings = (value as? [Any] ?? []).map(ring).filter { $0.count >= 3 }
            guard let exterior = rings.first else { return nil }
            return Polygon(exterior: exterior, holes: Array(rings.dropFirst()))
        }
        switch type {
        case "Polygon":
            return polygon(geometry["coordinates"] as Any).map { [$0] } ?? []
        case "MultiPolygon":
            return (geometry["coordinates"] as? [Any] ?? []).compactMap(polygon)
        default:
            throw ParseError.unsupportedGeometry(type)
        }
    }

    /// NYC borough boundaries (NYC Open Data "Borough Boundaries", GeoJSON export), simplified.
    /// Properties `borocode` and `boroname` name each region.
    public static func boroughs(from data: Data, simplifyToleranceMeters: Double) throws -> [StreetRegion] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]]
        else { throw ParseError.notAFeatureCollection }
        var regions: [StreetRegion] = []
        for feature in features {
            let properties = feature["properties"] as? [String: Any] ?? [:]
            guard let codeValue = properties["borocode"] ?? properties["BoroCode"] else { throw ParseError.missingProperty("borocode") }
            guard let code = UInt16("\(codeValue)") else { throw ParseError.missingProperty("borocode") }
            let name = (properties["boroname"] ?? properties["BoroName"]).map { "\($0)" } ?? "Borough \(code)"
            let polygons = try Self.polygons(fromGeometry: feature["geometry"] as? [String: Any] ?? [:]).compactMap {
                simplified($0, toleranceMeters: simplifyToleranceMeters)
            }
            regions.append(StreetRegion(code: code, name: name, area: MultiPolygon(polygons)))
        }
        return regions.sorted { $0.code < $1.code }
    }

    /// `polygon` with each ring simplified by Douglas–Peucker; `nil` when the exterior collapses.
    /// Holes that collapse are dropped.
    public static func simplified(_ polygon: Polygon, toleranceMeters: Double) -> Polygon? {
        let exterior = StreetGeometry.simplify(polygon.exterior, toleranceMeters: toleranceMeters)
        guard exterior.count >= 4 else { return nil }
        let holes = polygon.holes.map { StreetGeometry.simplify($0, toleranceMeters: toleranceMeters) }.filter { $0.count >= 4 }
        return Polygon(exterior: exterior, holes: holes)
    }

    /// Park polygons from `osmium export -f geojsonseq` output (records separated by newlines,
    /// each optionally prefixed with the RS byte 0x1E).
    public static func parks(fromGeoJSONSequence data: Data) throws -> [Polygon] {
        var polygons: [Polygon] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            var record = line
            while let first = record.first, first == 0x1E || first == UInt8(ascii: " ") { record = record.dropFirst() }
            guard !record.isEmpty else { continue }
            guard let feature = try JSONSerialization.jsonObject(with: Data(record)) as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any]
            else { continue }
            polygons += (try? Self.polygons(fromGeometry: geometry)) ?? []
        }
        return polygons
    }
}
