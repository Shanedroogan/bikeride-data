import BRGeo
import BRStreetCore
import Foundation

/// The New Jersey side of the service area: Hudson County (from its OpenStreetMap boundary
/// relation) and the Newark Penn area (a disc around the station), plus the polygon the New
/// Jersey extract is clipped to. See `docs/osm-derivation.md`.
public enum ServiceArea {
    public enum ServiceAreaError: Error, Equatable, CustomStringConvertible {
        case hudsonCountyBoundaryNotFound

        public var description: String {
            switch self {
            case .hudsonCountyBoundaryNotFound:
                "no polygon tagged nist:fips_code=\(ServiceArea.hudsonCountyFIPS), admin_level=6 in the New Jersey extract"
            }
        }
    }

    /// Hudson County's county FIPS code, as the boundary relation's `nist:fips_code` tag.
    public static let hudsonCountyFIPS = "34017"
    /// Newark Penn Station (the PATH platforms).
    public static let newarkPennCenter = Coordinate(lat: 40.7345, lon: -74.1644)
    /// Reaches Harrison (across the Passaic, in Hudson County) and the streets around the station.
    public static let newarkPennRadiusMeters = 1500.0

    /// Hudson County from `osmium export -f geojsonseq` of the boundary relation, simplified like
    /// the borough polygons. Its holes (Liberty Island and Ellis Island's 1857 part, which are New
    /// York) are kept.
    public static func hudsonCounty(fromGeoJSONSequence data: Data, simplifyToleranceMeters: Double) throws -> StreetRegion {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            var record = line
            while let first = record.first, first == 0x1E || first == UInt8(ascii: " ") { record = record.dropFirst() }
            guard !record.isEmpty,
                  let feature = try JSONSerialization.jsonObject(with: Data(record)) as? [String: Any],
                  let properties = feature["properties"] as? [String: Any],
                  properties["nist:fips_code"].map({ "\($0)" }) == hudsonCountyFIPS,
                  properties["admin_level"].map({ "\($0)" }) == "6",
                  let geometry = feature["geometry"] as? [String: Any]
            else { continue }
            let polygons = try GeoJSONAreas.polygons(fromGeometry: geometry).compactMap {
                GeoJSONAreas.simplified($0, toleranceMeters: simplifyToleranceMeters)
            }
            guard !polygons.isEmpty else { continue }
            return StreetRegion(code: StreetRegion.hudsonCountyCode, name: "Hudson County", area: MultiPolygon(polygons))
        }
        throw ServiceAreaError.hudsonCountyBoundaryNotFound
    }

    /// A closed ring of `vertices` points `radiusMeters` from `center`.
    public static func disc(center: Coordinate, radiusMeters: Double, vertices: Int = 64) -> [Coordinate] {
        let projection = LocalProjection(origin: center)
        var ring = (0..<vertices).map { i -> Coordinate in
            let angle = Double(i) / Double(vertices) * 2 * .pi
            return projection.unproject(PlanarPoint(x: radiusMeters * sin(angle), y: radiusMeters * cos(angle)))
        }
        ring.append(ring[0])
        return ring
    }

    public static func newarkPennArea(center: Coordinate = newarkPennCenter, radiusMeters: Double = newarkPennRadiusMeters) -> StreetRegion {
        StreetRegion(
            code: StreetRegion.newarkPennAreaCode, name: "Newark Penn area",
            area: MultiPolygon([Polygon(exterior: disc(center: center, radiusMeters: radiusMeters))])
        )
    }

    /// The convex hull of `regions`' exterior points grown by `bufferMeters` (each hull vertex
    /// replaced by a 32-gon of that radius, then the hull of those): a closed ring that contains
    /// every point within `bufferMeters` of the regions, up to the 32-gon's 0.5 % shortfall.
    public static func bufferedHull(of regions: [StreetRegion], bufferMeters: Double) -> [Coordinate] {
        let points = regions.flatMap(\.area.polygons).flatMap(\.exterior)
        guard let bounds = BoundingBox(points) else { return [] }
        let projection = LocalProjection(origin: Coordinate(lat: (bounds.minLat + bounds.maxLat) / 2, lon: (bounds.minLon + bounds.maxLon) / 2))
        let hull = convexHull(points.map(projection.project))
        let grown = hull.flatMap { p in
            (0..<32).map { i -> PlanarPoint in
                let angle = Double(i) / 32 * 2 * .pi
                return PlanarPoint(x: p.x + bufferMeters * cos(angle), y: p.y + bufferMeters * sin(angle))
            }
        }
        var ring = convexHull(grown).map(projection.unproject)
        if let first = ring.first { ring.append(first) }
        return ring
    }

    /// Andrew's monotone chain, counterclockwise, without the closing point.
    static func convexHull(_ points: [PlanarPoint]) -> [PlanarPoint] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: PlanarPoint, _ a: PlanarPoint, _ b: PlanarPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [PlanarPoint] = [], upper: [PlanarPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// A GeoJSON Feature holding one Polygon, as `osmium extract --polygon` reads it. Positions are
    /// rounded to 10⁻⁶° so the file, and the command, are reproducible.
    public static func geoJSONPolygonFeature(_ ring: [Coordinate]) -> Data {
        let positions = ring.map { String(format: "[%.6f,%.6f]", $0.lon, $0.lat) }.joined(separator: ",")
        return Data(#"{"type":"Feature","properties":{},"geometry":{"type":"Polygon","coordinates":[[\#(positions)]]}}"#.utf8)
    }
}
