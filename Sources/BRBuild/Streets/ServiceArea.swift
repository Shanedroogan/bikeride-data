import BRGeo
import BRStreetCore
import Foundation

/// The New Jersey side of the service area: Jersey City and Hoboken (from their OpenStreetMap
/// municipal boundary relations), plus the polygon the New Jersey extract is clipped to. See
/// `docs/osm-derivation.md`.
public enum ServiceArea {
    public enum ServiceAreaError: Error, Equatable, CustomStringConvertible {
        case municipalBoundaryNotFound(String)

        public var description: String {
            switch self {
            case .municipalBoundaryNotFound(let name):
                "no polygon for \(name) (admin_level=8 and its wikidata tag) in the New Jersey extract"
            }
        }
    }

    /// A New Jersey municipality in the service area, found by its boundary relation's tags.
    public struct Municipality: Sendable, Equatable {
        /// The Census place GEOID (state FIPS 34 + the 5-digit place code), stored as the region code.
        public var code: UInt32
        public var name: String
        /// The relation's `wikidata` tag, which selects it (with `admin_level=8`).
        public var wikidata: String
        /// The OSM relation id, for reference (the 2026-09 extract); selection is by tags.
        public var osmRelation: Int

        public init(code: UInt32, name: String, wikidata: String, osmRelation: Int) {
            self.code = code
            self.name = name
            self.wikidata = wikidata
            self.osmRelation = osmRelation
        }
    }

    public static let jerseyCity = Municipality(
        code: StreetRegion.jerseyCityCode, name: "Jersey City", wikidata: "Q26339", osmRelation: 170953
    )
    public static let hoboken = Municipality(
        code: StreetRegion.hobokenCode, name: "Hoboken", wikidata: "Q138578", osmRelation: 170708
    )
    /// The New Jersey municipalities in the service area, in code order.
    public static let municipalities = [hoboken, jerseyCity]

    /// The `osmium tags-filter` expression that pulls the municipalities' boundary relations.
    public static var municipalitiesFilter: String {
        "r/wikidata=" + municipalities.map(\.wikidata).joined(separator: ",")
    }

    /// Each of `municipalities` from `osmium export -f geojsonseq` of the boundary relations,
    /// simplified like the borough polygons. Holes (in Jersey City: Liberty Island and Ellis
    /// Island's 1857 part, which are New York) are kept. Other features, such as member ways that
    /// are areas of their own, are ignored.
    public static func municipalities(
        fromGeoJSONSequence data: Data, simplifyToleranceMeters: Double, municipalities: [Municipality] = municipalities
    ) throws -> [StreetRegion] {
        var found: [UInt32: StreetRegion] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            var record = line
            while let first = record.first, first == 0x1E || first == UInt8(ascii: " ") { record = record.dropFirst() }
            guard !record.isEmpty,
                  let feature = try JSONSerialization.jsonObject(with: Data(record)) as? [String: Any],
                  let properties = feature["properties"] as? [String: Any],
                  properties["admin_level"].map({ "\($0)" }) == "8",
                  let wikidata = properties["wikidata"].map({ "\($0)" }),
                  let municipality = municipalities.first(where: { $0.wikidata == wikidata }),
                  found[municipality.code] == nil,
                  let geometry = feature["geometry"] as? [String: Any]
            else { continue }
            let polygons = try GeoJSONAreas.polygons(fromGeometry: geometry).compactMap {
                GeoJSONAreas.simplified($0, toleranceMeters: simplifyToleranceMeters)
            }
            guard !polygons.isEmpty else { continue }
            found[municipality.code] = StreetRegion(code: municipality.code, name: municipality.name, area: MultiPolygon(polygons))
        }
        return try municipalities.map {
            guard let region = found[$0.code] else { throw ServiceAreaError.municipalBoundaryNotFound($0.name) }
            return region
        }.sorted { $0.code < $1.code }
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
